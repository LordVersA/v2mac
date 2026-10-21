# V2Mac Secure Sandbox — Implementation Plan (no code yet)

## Context
Opt-in **Secure Sandbox**: the user adds **mini VMs**, installs apps into each, and every app shows on
macOS as **its own Mac app** (own window, Dock icon, ⌘-Tab entry, "V2Mac Protected" badge). Each mini
VM has its own Xray exit, is fail-closed and is separate from every other mini VM. The user never sees
a Linux desktop. Nothing is downloaded until the user turns the sandbox on.

**V2Mac v1 is the platform only**: runtime, mini VMs, per-VM exits, display bridges, the trust chain,
a mini store and plugin API v1. Firefox, Chromium, Terminal, SSH, RDP… are **separate plugin repos**
built later on top of it; the privacy profile (timezone, geolocation, WebRTC) lives in the Firefox
plugin, not in V2Mac. Two tiny sample plugins prove the platform.

Decisions from the grill (2026-10-22):
| Topic | Decision |
|---|---|
| Mini VM | A container group (one Podman pod) inside **one shared hidden Linux VM**, shown to the user as a VM. No merge, ever. |
| Add | **Empty**, **Template** (a store list of plugin ids), or **Clone** (apps + data). Layers come from a shared cache or are downloaded. |
| Exit | Picked at creation (default: active server or Fastest), changeable live. When it stops working: stays blocked, red capsule, one notification with "Switch server". Never switches on its own. |
| Data | Persistent per mini VM. Per-VM **Disposable** switch (tmpfs homes) and **Wipe data**. |
| UI | Separate **Sandbox window**. One Mac app **per app per mini VM** (`Firefox — Work.app`), icon tinted in the VM's colour. |
| Files | Visible `~/V2Mac Sandbox/<VM>/Shared` folder per VM (= `~/Shared` in its apps). Files written by the VM get `com.apple.quarantine`. |
| Clipboard | Mac→VM only on ⌘V in a sandbox window; VM→Mac on copy. Text + images. Per-VM switch per direction. |
| Terminal/SSH | `pty` plugins open in the Mac's Terminal through a pty bridge over vsock (native fonts, IME, Persian text). |
| SSH keys | Mac's ssh-agent forwarded over vsock, only while that terminal is open, only if the plugin's permission was approved. Keys never enter the VM. |
| Store | Separate GitHub repo, one `index.json`, **signed offline** with Ed25519 (public key pinned in V2Mac). No server. |
| Publishing | Release builds install only what the index lists; dev builds can sideload a local plugin folder. |
| Builds | Each plugin repo's CI builds its OCI layers at a tag; the index pins commit + every layer's SHA-256. |
| SDK | Template repo (Containerfile, `plugin.json`, CI) + versioned base images + docs page. No CLI tool. |
| API versioning | Integer `api` in `plugin.json`, additive only; plugins with a newer `api` are hidden with "Update V2Mac". |
| Display | Software path first (cage + wayvnc + Swift RFB). libkrun GPU spike **only if** M0 misses the target. |
| Resources | RAM cap = ¼ of the Mac's memory (2–8 GB, changeable); boot on first app, shut down 5 min after the last closes; cgroup limits per mini VM. |
| Other VPNs | Later (§9). v1 only keeps the gateway's upstream slot generic. |

Everything marked **[verify]** is an unconfirmed assumption; M0 measures it before anything is built on it.

## 1. What V2Mac already has (reuse, don't rebuild)
| Need | Existing piece |
|---|---|
| Run/stop an xray, state + logs as streams | `CoreRunner` (`Packages/V2MacCore/Sources/V2MacCore/CoreRunner/CoreRunner.swift`) |
| Swap one outbound live, no restart | `CoreRunner.replaceOutbound(tag:with:apiPort:)` (`xray api rmo/ado`) |
| Build an outbound from a stored server | `ConfigBuilder.proxyOutbound` (strips `allowInsecure`, `InsecureTLS` pinning) |
| Bind core outbounds to the physical NIC so they skip the host TUN | `Tun.binding(_:to:)` (`XrayConfig/Tun.swift`) |
| Exit IP/country through a proxy | `ExitLookup`; country → coordinates and zone.tab timezone: `CountryPlaces` |
| SHA-256-pinned downloads, download routes | `CoreUpdater`, `RegionPackInstaller`, `FetchRoute`, `BoundedFetch` |
| Kill switch allowlist of server IPs | `KillSwitch.allowFile` (sandbox core's servers must be added) |
| Data folder per build (dev vs release) | `AppPaths` (`App/Support/AppPaths.swift`); sandbox lives in `<data>/sandbox/` |
| Notifications, settings, prefs pattern | `NotificationKind`, `Prefs.registerDefaults`, `Features/Settings/` |

The app is not App-Sandboxed. It needs `com.apple.security.virtualization`; whether an ad-hoc signed
build (CI DMG, local DMG) may use it is **[verify]**.

## 2. Runtime
**VM OS: Debian 13 minimal arm64** (glibc, so third-party plugin binaries just work; Alpine's musl and
Buildroot's upkeep rejected). Also the base of plugin images.

**Hypervisor: Apple Virtualization.framework**, `VZLinuxBootLoader` (our kernel + initrd, ~2 s boot
**[verify]**). Devices: virtio-blk ×2 (read-only rootfs + data disk), virtio-vsock, virtio-fs (one share:
`<data>/sandbox/exchange`, holding each mini VM's `Shared` folder), virtio-sound, entropy, balloon.
**No network device at all.** Note: VZ has no 3D GPU for Linux guests; GPU rendering would mean
libkrun/krunkit (Venus over MoltenVK), only if M0 forces it.

**Isolation inside the VM: rootless Podman + crun.** Plugins are OCI images (shared, content-addressed
layers, `podman load` from a file, no registry, no network in the VM). **One pod per mini VM**: its apps
share one netns, one `Shared` folder and one exit; different pods share nothing. Every container:
user namespace, `--cap-drop=all`, `no-new-privileges`, read-only rootfs, seccomp profile that **denies
`socket(AF_VSOCK)`** (vsock is not network-namespaced; this is what stops an app from reaching the host
**[verify] Podman's default**), cgroup memory/CPU limits per pod, pod netns created by the gateway.

## 3. Network: gateway and per-VM exits
Server credentials stay on the host; the VM only steers packets.
```
Mini VM pod A (netns, 10.77.A.2, only veth, IPv6 off, default route = gateway)
   │ veth
Gateway netns (VM, root, apps can't touch it)
   nftables: default DROP; per-veth TPROXY → xray-in-vm inbound "vm-A" (TCP+UDP); DNS → xray fakedns
   xray-in-vm: inbound vm-A → outbound "host-A" = VLESS-plain to 127.0.0.1:<relay port A>
   relay (socat TCP→VSOCK-CONNECT 2:<port A>)            ← only the gateway owns vsock
   │ virtio-vsock
Host V2Mac: VZVirtioSocketListener port A → 127.0.0.1:<sandbox core inbound vm-A>
Sandbox core (2nd xray on host, CoreRunner): inbound vm-A (VLESS, per-VM UUID)
   routing inboundTag vm-A → outboundTag vm-A
   outbound vm-A = chosen server (ConfigBuilder.proxyOutbound + Tun.binding to physical NIC)
```
- **Independent of the main connection**: the sandbox core is a separate process; the main VPN can be
  off, on another server, or in TUN mode. Changing a VM's exit = `replaceOutbound(tag: "vm-A")`.
  Adding/removing a mini VM = new inbound + rule via `xray api adi/adrules` **[verify in 26.10.21]**;
  fallback: restart only the sandbox core.
- **Fail closed by construction**: no NIC in the VM, so nothing can fall back to direct. Sandbox core,
  relay or gateway down → packets have nowhere to go. ICMP and other IP protocols dropped. IPv6 off.
  Host resolver never used. QUIC/WebRTC are UDP through TPROXY → same exit, never direct.
- **Exit down**: `ExitLookup` through the VM's path fails → capsule red, `NotificationKind.sandboxExitDown`.
- **Host interplay**: sandbox core outbounds bind to the physical NIC (skip host TUN); their server IPs
  go into `KillSwitch.allowFile`.
- **Kept open for later** (§9): the gateway's per-VM upstream is "a VLESS/SOCKS endpoint over vsock",
  not hard-wired to one Xray inbound shape.

## 4. Display: Linux apps as Mac apps
Two display kinds, declared by the plugin:
- **`gui`**: per-app headless compositor + VNC over vsock + our own Swift RFB client. In the app's
  container `cage` (wlroots kiosk, headless, pixman) runs only that app; `wayvnc` serves it (damage-only
  updates, input, clipboard, resize via ExtendedDesktopSize **[verify]**). The gateway forwards the VNC
  socket over vsock (app containers have no vsock). Host RFB client lives in the package (parsing = pure
  value code, fuzz-tested): Raw/CopyRect/ZRLE first, then Tight-JPEG (ImageIO), drawn into a
  `CALayer`. Xpra, Waypipe, Weston RAIL and `VZVirtualMachineView` were rejected (deps or one screen).
- **`pty`**: the runtime runs `launch.cmd` under a pty; the generated Mac app opens the user's Terminal
  running `V2Mac.app/Contents/Helpers/v2mac-pty`, which bridges the pty over a Unix socket in
  `<data>/run/` → V2Mac → vsock. Window size, signals and (if allowed) ssh-agent go through it.
- **One Mac app per app per mini VM**: installing generates `~/Applications/V2Mac Sandbox/<App> — <VM>.app`:
  a copy of the tiny `SandboxAppHost` stub shipped inside V2Mac.app, its own `Info.plist`
  (`io.github.lordversa.v2mac.sandbox.<vm>.<plugin>`), an `.icns` (plugin icon tinted in the VM colour +
  V2Mac glyph), re-signed ad-hoc locally. The stub owns window, Dock icon and menu, gets frames from
  V2Mac over a Unix socket, and asks V2Mac to start the app (V2Mac boots the VM on demand).
- **Title capsule**: `NSTitlebarAccessoryViewController` "🛡 V2Mac Protected · <VM> · 🇩🇪 Frankfurt";
  red "Not connected" when the exit is down.
- **Input** **[verify]**: keysyms for non-Latin layouts (Persian), IME text, ⌘→Ctrl shortcuts, smooth
  trackpad scrolling.
- **Audio**: virtio-sound + PipeWire in the VM; per-app mute in V2Mac.
- **Target**: smooth scrolling at 2× under ~1 core **[verify]**. Plan B: render at 1× and let macOS
  scale. Plan C (only if both miss): libkrun GPU spike.

## 5. Plugin API v1
`plugin.json` (published in the plugin's repo, copied into the index):
```
api: 1                     # integer, additive only
id, name, version, icon, publisher, source {repo, commit}
layers [{url, sha256, size}], depends [base-gui@>=x | base-cli@>=x]
display: gui | pty
launch {cmd, env}
permissions [clipboard, shared, ssh-agent]   # user approves at install, runtime enforces
changelog, securityNotes
```
What the runtime gives every app:
- **Exit facts**: `/run/v2mac/exit.json` (country, city, lat/lon, IANA timezone, exit IP), read-only,
  replaced atomically on exit change (plugins watch it with inotify); `TZ` set at launch. The Firefox
  plugin builds its own privacy profile from it.
- `~/Shared` (only with `shared`), a home on the data disk (tmpfs when the VM is Disposable).
- Nothing else: no vsock, no nft, no other pods, no host paths.

Rules: V2Mac runs every plugin with `api ≤` its own and hides newer ones ("Update V2Mac"). A breaking
change means `api: 2`, and V2Mac keeps `api: 1` working.

## 6. Store, trust, SDK
- **Store repo** `LordVersA/v2mac-store`: `index.json` + `index.json.sig`. Signed **offline** on the
  maintainer's Mac with Ed25519; the public key is pinned in V2Mac (CryptoKit `Curve25519.Signing`).
  Fields: `version` (monotonic, rollback refused), `expires` (freeze refused), `minApi`, `plugins[]`
  (full manifests with pinned commit + layer hashes), `templates[]` (name + list of plugin ids).
- **Plugin repos** (one per app) build layers in their own CI at a tag and attach them to a GitHub
  Release. Accepting a plugin = reviewing that commit, copying its manifest and hashes into the
  index, signing.
- **Install**: download layers (or take them from the shared cache in `<data>/sandbox/cache`), check
  every SHA-256 against the signed index, `podman load`. Dev builds also accept a local plugin folder
  ("Unverified", never in release builds).
- **Verify Installation** per plugin: source repo + commit, version, layer hashes, signature status,
  permissions, re-hash on demand. Copy says "verified" means "unchanged since published", not "safe".
- **Base images** (`base`, `base-cli`, `base-gui` = cage, wayvnc, PipeWire client, fonts, gtk3, mesa
  llvmpipe) are built and released by the runtime repo; plugins `FROM` them and share their layers.
- **SDK** = `LordVersA/v2mac-plugin-template` (Containerfile, `plugin.json`, icon, CI workflow) + a
  docs page for the API + the two samples: `hello-gui` (GTK window: input, resize, clipboard, exit
  facts) and `hello-pty` (a shell).
- **VM image** (`v2mac-sandbox-runtime` repo): `vmlinuz`, `initrd`, `rootfs.erofs`, `.sha256` + Ed25519
  signature, A/B rootfs swap on update; the data disk persists. Built with `mmdebstrap` +
  `SOURCE_DATE_EPOCH`.

## 7. Threat model (summary)
| Asset / actor | Threat | Control |
|---|---|---|
| Malicious site → app | escape container | user ns, seccomp, cap drop, ro rootfs, no vsock |
| Compromised app | reach another mini VM, change routes, reach host | own pod netns, nft in gateway netns, AF_VSOCK denied, no host mounts |
| Compromised VM kernel | reach internet directly | no NIC; only vsock ports V2Mac listens on |
| Compromised VM kernel | reach other mini VMs | **not prevented**: all pods share one kernel (accepted trade-off) |
| Compromised VM | steal server secrets | secrets only on host; VM sees per-VM relay UUIDs |
| Compromised VM | plant files for the user | `Shared` files carry `com.apple.quarantine`; Gatekeeper checks before open |
| Compromised VM | read Mac clipboard | Mac→VM only on explicit ⌘V |
| Compromised VM | use SSH keys | agent forwarded only during an approved pty session; keys stay on Mac |
| Compromised VM → host | abuse bridges | host parses only RFB, pty and fixed control messages, length-limited, fuzz-tested |
| Other Mac processes | hijack per-VM inbounds | 127.0.0.1 + per-VM VLESS UUIDs |
| Supply chain | swapped image/plugin | offline-signed index with version + expiry, pinned key, SHA-256 per layer, pinned commits |
| Network change, sleep, main VPN toggle | direct leak | no direct path exists; sandbox core rebinds NIC like main core |
| Later: L3 VPN adapters (§9) | VPN credentials in the VM | stated in UI; only for those adapters |

## 8. Automated security tests
- **Package (`swift test`)**: manifest/index parsing, signature/rollback/expiry/`api` checks; gateway
  nft + xray config generation (golden tests); RFB and control-message parser fuzzing.
- **In-VM probe container** (`.integration`, needs the runtime): asserts failure of direct TCP/UDP,
  DNS to 8.8.8.8, IPv6, ICMP, STUN public IP ≠ exit IP, reaching another mini VM, nft/route change
  (EPERM), `socket(AF_VSOCK)` (EPERM); success through the assigned exit.
- **Host-level**: tcpdump on the physical NIC while probes run (only sandbox core → its server IPs);
  debug-hook scenarios: kill sandbox core / relay / gateway mid-download, swap exit mid-transfer,
  Wi-Fi change, sleep/wake, toggle main VPN and TUN, crash V2Mac (stubs show "Disconnected").
  Script next to `Scripts/check-tun.sh`.
- Results are reproducible evidence, never a "100% secure" claim.

## 9. Later (not v1)
- **Plugin repos**: Firefox (with the privacy profile from exit facts: TZ, geolocation in exit city,
  `media.peerconnection.ice.no_host`, fingerprinting protection without forced UTC, telemetry off),
  Chromium, Terminal, SSH, RDP. Templates such as "Private browsing".
- **Other VPNs as Xray outbounds**: WireGuard needs nothing (Xray has a `wireguard` outbound).
  OpenVPN / OpenConnect / IPsec run in their own netns in the VM with a tiny SOCKS server inside; the
  host Xray uses it as a `socks` outbound over vsock, and its transport leaves through the host Xray
  bound to the NIC. Then the main connection's TUN mode, system proxy and kill switch can use them
  too. Cost: those VPN credentials live in the VM.
- **GPU rendering** (libkrun) if users need video beyond the software path.
- More API: audio permissions, per-app network rules, notifications from plugins.

## 10. Milestones (each behind a "Sandbox (beta)" setting, dev build first)

### M0 — Spikes (research; nothing user-facing)
| # | Task | Go | No-go → |
|---|---|---|---|
| 0.1 | Ad-hoc signed build with `com.apple.security.virtualization` boots a VM | works | sandbox only in Developer ID builds; decide signing before M1 |
| 0.2 | `VZLinuxBootLoader` Debian boot time + idle RAM | < 3 s, < 250 MB | trim initrd/rootfs, retest |
| 0.3 | vsock relay throughput + latency (TCP and UDP-in-VLESS) | ≥ 300 Mbit/s, < 1 ms added | replace socat with a small Go/C relay |
| 0.4 | Rootless Podman pods on a gateway-made netns; seccomp denies AF_VSOCK | both work | custom seccomp profile / bubblewrap |
| 0.5 | `xray api adi/adrules` in 26.10.21 | exists | restart sandbox core on add/remove |
| 0.6 | cage headless + wayvnc + prototype Swift RFB, `hello-gui` + a heavy web page, 1× and 2× | smooth at 2× < 1 core | 1× + macOS scaling; still bad → libkrun spike |
| 0.7 | Input: Persian layout, IME, ⌘ mapping, trackpad scroll through RFB | all usable | extended keysym/text messages in our RFB |
| 0.8 | virtio-sound + PipeWire | audio plays | defer audio to after v1 |
| 0.9 | Generated ad-hoc `.app` stubs: launch, own Dock identity, LaunchServices registration | works | one stub with per-window Dock tiles |
| 0.10 | pty bridge prototype in Terminal.app, ssh-agent forward | works | own minimal terminal window |

*Done when:* numbers and outcomes in `docs/SPEC.md` new section 19, this plan updated.

### M1 — Runtime
1. `v2mac-sandbox-runtime` repo: mmdebstrap image, kernel, initrd, erofs rootfs, signing, CI release.
2. Package `SandboxRuntime`: manifest + signature check (tests).
3. `SandboxController`: download/verify/install/remove runtime, `<data>/sandbox/` layout, data disk.
4. Boot/stop VM, vsock control agent (fixed message set, length-limited), RAM cap, idle shutdown.
5. Settings → Sandbox: enable, RAM cap, remove (frees all disk). Prefs keys + defaults.
6. `-debugSandbox install|boot|stop` hooks.
*Done when:* VM boots on demand in the dev build and removal frees all disk.

### M2 — Mini VMs, gateway, exits
1. Package `GatewayConfig` (nft + in-VM xray JSON) and `SandboxCoreConfig` (host xray), golden tests.
2. Sandbox core via a second `CoreRunner`; NIC binding; kill switch allowlist.
3. Gateway netns, per-VM pod netns, TPROXY, fakedns, vsock relays.
4. Mini VM model (name, colour, exit, Disposable) + Empty / Clone / Wipe / Delete.
5. Exit picker, live exit swap, exit-down detection + `NotificationKind.sandboxExitDown`.
6. Dev sideload of a local plugin folder; probe container; `-debugSandbox probe`.
*Done when:* all in-VM leak probes pass; exit swap without restart; works with main VPN off/on/TUN.

### M3 — pty display + permissions
1. `v2mac-pty` helper, Unix socket bridge, resize/signals.
2. Permission model: approve at install, enforce in runtime (clipboard, shared, ssh-agent).
3. ssh-agent forwarding per session.
4. `hello-pty` sample.
*Done when:* `hello-pty — Work` opens in Terminal, SSH with agent works, through the VM's exit.

### M4 — gui display
1. Package RFB parser (Raw/CopyRect/ZRLE, then Tight-JPEG) + fuzz tests.
2. `SandboxAppHost` target, bundle generation, icon tint + badge, re-sign, title capsule.
3. Clipboard rules, `Shared` folder + quarantine flag, audio.
4. `hello-gui` sample.
*Done when:* `hello-gui — Work.app` is its own Mac app; input, resize, clipboard and Shared work.

### M5 — Store and templates
1. `v2mac-store` repo: index format, offline signing script, review checklist.
2. Package `StoreIndex` + `PluginManifest`: signature, rollback, expiry, `api` checks (tests).
3. `PluginService`: install from store or cache, update (changed layers only), remove, Verify Installation.
4. Add sheet: Empty / Template / Clone. Sandbox window: VMs, apps, sizes, actions.
*Done when:* tampered layer or index is refused; a template creates a working mini VM.

### M6 — SDK
1. Base images `base`, `base-cli`, `base-gui` released by the runtime repo.
2. `v2mac-plugin-template` repo with CI; the two samples built from it.
3. Plugin API docs page (`docs/` + wiki).
*Done when:* a new plugin made from the template installs through the store on a clean Mac.

### M7 — Hardening and release
1. Host leak script (tcpdump), sleep/wake/Wi-Fi/main-VPN scenarios, resource monitor.
2. Spec, wiki (en/fa/zh/ru), README ×4, String Catalogs ×3.
*Done when:* every §8 scenario passes on a clean Mac; Sandbox (beta) ships.

## Files (host side)
- Package `Packages/V2MacCore/Sources/V2MacCore/Sandbox/`: `PluginManifest`, `StoreIndex`,
  `GatewayConfig`, `SandboxCoreConfig`, `RFB/`, control messages. Tests in `Tests/V2MacCoreTests/Sandbox*`.
- App: `App/State/SandboxController.swift` (VM, vsock listeners, second `CoreRunner`),
  `App/State/PluginService.swift`, `App/Features/Sandbox/` (Sandbox window, Add sheet, Verify),
  `App/Features/Settings/SandboxSettings.swift`; wiring in `AppModel`; `Prefs` keys + defaults;
  `NotificationKind` cases (sandbox exit down, plugin update).
- New targets `SandboxAppHost/` and `v2mac-pty` in `project.yml`; entitlement in `App/Resources/v2mac.entitlements`.
- Separate repos: `v2mac-sandbox-runtime`, `v2mac-store`, `v2mac-plugin-template`, one per plugin later.

## Verification
- `cd Packages/V2MacCore && swift test --filter Sandbox`.
- Dev build only (`V2MacDev.app`, data in `v2mac-dev`); never touch the installed V2Mac or its core.
- `-debugSandbox install|boot|probe|launch <plugin>` hooks print `[v2mac-debug]` lines;
  `-debugSnapshot` checks the Sandbox window, badges and capsule.
