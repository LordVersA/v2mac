# V2Mac Secure Sandbox — Implementation Plan (no code yet)

## Context
Opt-in **Secure Sandbox**: run Firefox, Chromium, Terminal, SSH and an RDP client in one hidden Linux
VM, each app fully isolated, each with its own Xray exit, fail-closed, and each shown on macOS as
**its own Mac app** (own window, Dock icon, ⌘-Tab entry, "V2Mac Protected" badge). The user never
sees a Linux desktop. Nothing is downloaded until the user turns the sandbox on. Requirements come
from the user's brief ("Secure Sandbox & Plugin Ecosystem") plus the grill:
- **Single shared VM** (brief's firm decision; replaces the earlier "VM per app" answer).
- **Droplets**: Liquid Glass canvas; each droplet holds 1+ apps; drag an app between droplets or drop
  one droplet on another to merge. Apps in one droplet share a folder, a private LAN and one exit.
- Light, fast, reliable on Apple Silicon. Guest = Linux (macOS guest rejected: ~15 GB, 3–4 GB RAM, max 2).

Everything marked **[verify]** is an unconfirmed assumption that M0 must measure before it is built on.

## 1. What V2Mac already has (reuse, don't rebuild)
| Need | Existing piece |
|---|---|
| Run/stop an xray, state + logs as streams | `CoreRunner` (`Packages/V2MacCore/Sources/V2MacCore/CoreRunner/CoreRunner.swift`) |
| Swap one outbound live, no restart | `CoreRunner.replaceOutbound(tag:with:apiPort:)` (`xray api rmo/ado`) |
| Build an outbound from a stored server | `ConfigBuilder.proxyOutbound` (strips `allowInsecure`, `InsecureTLS` pinning) |
| Bind core outbounds to the physical NIC so they skip the host TUN | `Tun.binding(_:to:)` (`XrayConfig/Tun.swift`) |
| Exit IP/country through a proxy | `ExitLookup`; country → coordinates (and zone.tab timezone) `CountryPlaces` |
| SHA-256-pinned downloads, download routes | `CoreUpdater`, `RegionPackInstaller`, `FetchRoute`, `BoundedFetch` |
| Kill switch allowlist of server IPs | `KillSwitch.allowFile` (sandbox core's servers must be added) |
| Data folder per build (dev vs release) | `AppPaths` (`App/Support/AppPaths.swift`) — sandbox lives in `<data>/sandbox/` |
| Notifications, settings, prefs pattern | `NotificationKind`, `Prefs.registerDefaults`, `Features/Settings/` |
The app is not App-Sandboxed (entitlements file is empty). It needs `com.apple.security.virtualization`
added; ad-hoc signing with that entitlement **[verify]** (believed to work, as with vfkit/tart dev builds).

## 2. Runtime choices
**VM OS: Debian 13 minimal arm64** (for the VM *and* as the base of plugin images).
| | Debian minimal | Alpine | Buildroot |
|---|---|---|---|
| libc | glibc (runs every Linux binary) | musl (official Firefox/Chrome/most third-party binaries break) | any, but all hand-built |
| Packages | full arm64 archive, apt signatures, reproducible-builds effort | good, smaller | none; we maintain everything |
| Size | ~120–150 MB compressed VM | ~60–80 MB | ~40 MB |
| Verdict | **chosen**: third-party plugins and ports just work | saves ~60 MB, costs compatibility | too much upkeep |

**Hypervisor: Apple Virtualization.framework**, `VZLinuxBootLoader` (our kernel + initrd, no EFI/GRUB,
~2 s boot **[verify]**). Devices: virtio-blk ×2 (read-only rootfs image + data disk), virtio-vsock,
virtio-fs (one share: `<data>/sandbox/exchange`), virtio-sound output, entropy, balloon.
**No network device at all.** libkrun (GPU) rejected: third-party C stack, experimental.

**Container isolation inside the VM: rootless Podman + crun.**
| | Podman rootless | bubblewrap | systemd-nspawn | gVisor |
|---|---|---|---|---|
| Layers/images for plugins (shared deps, incremental updates, digest = hash) | yes (OCI) | no, we'd build it | partial | via runsc |
| User namespaces, seccomp, cap drop, cgroups v2 limits | yes | yes (no cgroups) | yes | yes |
| Size in VM | ~60–80 MB | ~0.1 MB | in systemd | ~50 MB + slow syscalls |
Podman wins because plugins become OCI images: shared base layers, content-addressed, `podman load`
from a file (no registry, no network in the VM). Every app container runs with: user namespace
(root in container ≠ root in VM), `--cap-drop=all`, `no-new-privileges`, read-only rootfs, seccomp
profile that **denies `socket(AF_VSOCK)`** (vsock is not network-namespaced, so this is what stops an
app from reaching the host directly — Docker's default profile already blocks family 40 **[verify] for Podman's**),
cgroup memory/CPU limits, `--network ns:/run/netns/app-<id>` (created by the gateway, see 3).

## 3. Network: gateway and per-app routing
**Choice: hybrid — server credentials stay on the host, the VM only steers packets.**
- Xray inside the VM holding real server configs → a VM compromise leaks subscription secrets. Rejected.
- Host-only (apps → vsock → host) → apps would need vsock, which can't be per-app policed. Rejected.

```
App netns A (10.77.A.2, only veth, IPv6 off, no default route but gateway)
   │ veth
Gateway netns (VM, root, apps can't touch it)
   nftables: default DROP; per-veth TPROXY → xray-in-vm inbound "app-A" (TCP+UDP); DNS → xray fakedns
   xray-in-vm: inbound app-A → outbound "host-A" = VLESS-plain to 127.0.0.1:<relay port A>
   relay (socat TCP→VSOCK-CONNECT 2:<port A>)            ← only the gateway owns vsock
   │ virtio-vsock
Host V2Mac: VZVirtioSocketListener port A → 127.0.0.1:<sandbox core inbound app-A>
Sandbox core (2nd xray on host, CoreRunner): inbound app-A (VLESS, per-app UUID)
   routing inboundTag app-A → outboundTag app-A (static rule)
   outbound app-A = chosen server (ConfigBuilder.proxyOutbound + Tun.binding to physical NIC)
```
- **Independent of the main connection** (brief §6): the sandbox core is a separate process; the main VPN
  can be off or on another server. Changing a droplet's exit = `replaceOutbound(tag: "app-A")`, no restart.
  Adding/removing an app = new inbound + rule via `xray api adi/adrules` **[verify CLI exists in 26.10.21]**;
  fallback: restart only the sandbox core.
- **Droplet = shared exit**: all apps in a droplet route to one outbound tag `drop-<id>`; moving an app
  rewrites its static rule (or its gateway TPROXY target port, which needs no Xray change).
- **Fail closed by construction**: the VM has no NIC, so there is no direct path to fall back to. If
  the sandbox core, relay or VM gateway dies, packets have nowhere to go. ICMP and other IP protocols are
  dropped (can't be proxied). IPv6 disabled in app netns + nft drop. Host resolver never used.
- **QUIC/HTTP3, WebRTC/STUN**: they're UDP through TPROXY → same exit. Not blocked, just never direct.
  If the server outbound has no UDP, QUIC falls back to TCP on its own.
- **Droplet LAN**: per-droplet Linux bridge in the gateway; member netns get a second veth on it. No
  forwarding off the bridge. Added/removed live (veth can be moved into a running netns).
- **Host interplay**: sandbox core outbounds bind to the physical NIC like the main core (skip host TUN);
  their server IPs are added to `KillSwitch.allowFile`; the pf kill switch allows them.

## 4. Showing Linux apps as Mac apps (no Linux desktop)
Options studied:
| Method | Per-app Mac windows | Host deps | Verdict |
|---|---|---|---|
| VZVirtualMachineView | no (one VM screen) | none | rejected |
| Xpra seamless | yes | big Python/GTK client | rejected (dependency, non-native) |
| Waypipe | yes | needs a Wayland compositor on macOS (none) | rejected |
| Weston RDP RAIL (WSLg model) | yes | FreeRDP RAIL client on Mac (weak) | rejected |
| **Per-app headless compositor + VNC over vsock + our own Swift RFB client** | **yes** | **none** | **chosen** |

- In each app container: `cage` (wlroots kiosk compositor, headless backend, pixman renderer, no GPU)
  runs only that app; `wayvnc` serves it (damage-only updates, input, clipboard, resize via
  ExtendedDesktopSize **[verify]**). The gateway forwards each app's VNC socket over vsock. App
  containers still have no vsock; the gateway owns the bridge (same rule as networking).
- **Host renderer**: our own RFB client in the package (protocol parsing = pure value code, tested):
  Raw/CopyRect/ZRLE (zlib from the SDK) first, then Tight-JPEG (ImageIO). Drawn into a `CALayer`/Metal
  texture. Retina via scale factor; window resize → remote desktop resize.
- **One Mac app per Linux app**: installing a plugin generates `~/Applications/V2Mac Sandbox/<Name>.app`:
  a copy of a tiny stub executable shipped inside V2Mac.app (`SandboxAppHost` target, ~0.5 MB), its own
  `Info.plist` (bundle id `io.github.lordversa.v2mac.sandbox.<plugin>`) and an `.icns`, re-signed ad-hoc
  locally. The stub owns the window, Dock icon and menu; it gets its frame stream from V2Mac over an
  XPC/Unix socket in `<data>/run/` and starts the app via V2Mac (which boots the VM on demand).
- **Badge**: icon = plugin icon + V2Mac glass glyph at bottom-right, composited at install (NSImage →
  icns). Title bar: `NSTitlebarAccessoryViewController` capsule "🛡 V2Mac Protected · 🇩🇪 Frankfurt"
  in the droplet colour; red "Not connected" when its exit is down. Dock tile badge via `NSDockTile`.
- **Audio**: virtio-sound (one device for the VM) with PipeWire in the VM; per-app mute in V2Mac.
- **Clipboard / files** (host bridges, all off unless allowed per app): clipboard via RFB cut-text, only
  on explicit paste; files in via drag onto the window or the droplet → copied to the droplet folder;
  files out via "Export…" in V2Mac. No macOS folder is ever mounted into a container.
- **Performance cost**: CPU rendering + encode. Target 1080p@30 at <1 core for normal browsing **[verify]**;
  video is the known weak spot.

## 5. Plugins, store, signing, updates
- **Store repo** `LordVersA/v2mac-store` (public): `plugins/<id>/plugin.json` + Containerfile + CI.
  CI builds each plugin image from Debian's signed apt repos (official sources only), exports an OCI
  archive per layer, uploads to GitHub Releases, writes digests into `index.json`.
- **index.json** signed with the store's Ed25519 key (offline; public key pinned in V2Mac; verified with
  CryptoKit `Curve25519.Signing` — no dependency). Fields: `version` (monotonic), `expires`,
  `minRuntime`, `plugins[]`. V2Mac refuses older `version` (rollback) and expired indexes (freeze).
- **plugin.json**: `id, name, version, publisher {name, key}, source (repo + commit), icon,
  layers [{url, sha256, size}], depends [base-gui@>=x], permissions {gui, audio, clipboard, files, lan},
  minRuntime, launch {cmd, env}, privacy {firefox|chromium profile}, changelog, securityNotes`.
  Publisher signs `plugin.json`; the store index lists accepted publisher keys. Third-party plugins
  arrive by PR, are reviewed, built by store CI (never uploaded binaries).
- Plugins only ever run inside the VM. They can't add nftables rules, vsock, host bridges or other
  plugins' settings: the gateway and permissions are enforced by the runtime, not by the plugin.
- **Shared layers**: `base` (Debian slim) → `base-gui` (cage, wayvnc, pipewire client, fonts, gtk3,
  mesa llvmpipe) → app layer. Updates download only changed layers.
- **VM image** (`v2mac-sandbox-runtime` release): `vmlinuz`, `initrd`, `rootfs.erofs` (read-only),
  `.sha256` + Ed25519 signature. A/B rootfs swap on update; data disk (container storage, droplet
  folders) persists. Built reproducibly with `mmdebstrap` + `SOURCE_DATE_EPOCH` **[verify reproducibility]**.
- **Verify Installation** screen per plugin: source repo + commit, version, layer hashes, signature
  status (index + publisher), permissions, last integrity check (re-hash on demand). Copy says that
  "verified" means "unchanged from what was published", not "safe".

## 6. Privacy profile (separate from routing security)
Applied per droplet from its exit (exit lookup through the droplet's path, reusing `ExitLookup`):
- `TZ` = zone.tab zone for the exit country (city when GeoIP gives one); `LANG`/`LC_*` and
  Accept-Language from the country's main language (user can override).
- **Firefox** `policies.json`/prefs: geolocation provider = fixed point in exit city (`CountryPlaces`),
  `media.peerconnection.ice.no_host=true`, `privacy.fingerprintingProtection` on with `-JSDateTimeUTC`
  (full `resistFingerprinting` forces UTC and would break the timezone match), telemetry off.
- **Chromium** managed policy: geolocation blocked, `WebRtcIPHandlingPolicy=default_public_interface_only`,
  `--lang`, telemetry off.
- **No traces**: home is tmpfs by default → every launch is a fresh profile, no cookies. "Keep data" is
  a per-app opt-in (stored on the data disk).
- Fonts: fixed common set (DejaVu, Liberation, Noto). Screen size: window size rounded to common sizes
  (optional letterboxing). Canvas/WebGL/audio: optional shields. UI and docs say plainly that matching
  timezone/locale does not make the user anonymous and that the fingerprint is "Linux desktop".

## 7. Threat model (summary)
| Asset / actor | Threat | Control |
|---|---|---|
| Malicious site → app | escape container | user ns, seccomp, cap drop, ro rootfs, no vsock |
| Compromised app container | reach other apps, change routes, reach host | own netns, nft in gateway netns, AF_VSOCK denied, no host mounts |
| Compromised VM (kernel) | reach internet directly | no NIC; only vsock ports V2Mac listens on |
| Compromised VM | steal server secrets | secrets only on host; VM sees per-app relay UUIDs |
| Compromised VM → host | abuse bridges | host side parses only RFB + fixed control messages, with length limits; fuzz-tested in the package |
| Other Mac processes | hijack per-app inbounds | inbounds on 127.0.0.1 with per-app VLESS UUIDs |
| Supply chain | swapped image/plugin | pinned Ed25519 key, signed index with expiry + version, SHA-256 per layer, CI-built from official apt |
| Host network change, sleep, main VPN toggle | direct leak | no direct path exists; sandbox core rebinds NIC like main core |

## 8. Automated security tests
- **Package (`swift test`)**: manifest/index parsing + signature/rollback/expiry checks; gateway nft and
  xray config generation (golden tests); RFB parser fuzzing; vsock control-message limits.
- **In-VM probe container** (`.integration`, needs the runtime): for each brief §9 scenario a probe
  asserts failure of: direct TCP/UDP to an IP, DNS to 8.8.8.8, IPv6, ICMP, STUN public IP ≠ exit IP,
  connect to another app's netns/LAN outside its droplet, `nft`/route change (EPERM), `socket(AF_VSOCK)`
  (EPERM), and success through the assigned exit.
- **Host-level**: tcpdump on the physical NIC while probes run: only the sandbox core → its server IPs
  may appear. Scenarios driven by debug hooks: kill sandbox core / relay / gateway mid-download,
  swap exit mid-transfer, Wi-Fi change, sleep/wake, toggle main VPN, crash V2Mac (VM dies with it;
  stubs show "Disconnected"). Script alongside `Scripts/check-tun.sh`.
- Results are reproducible evidence, never a "100% secure" claim.

## 9. Size and resource estimates (all **[verify]** in M0)
| Item | Download | Disk |
|---|---|---|
| Runtime (kernel+initrd ~25 MB, rootfs: Debian + podman/crun + nftables + xray-linux + socat) | ~150 MB | ~450 MB |
| `base-gui` layer (shared by all GUI apps) | ~150 MB | ~450 MB |
| Firefox ESR / Chromium layer | ~80 / ~100 MB | ~250 / ~300 MB |
| Terminal (foot) + SSH client | ~5 MB | ~15 MB |
| RDP client (Remmina/FreeRDP) | ~30 MB | ~90 MB |
| V2Mac.app growth (host code + stub) | ~1–2 MB | — |
RAM: VM base ~150–200 MB; per GUI app +30–40 MB (cage+wayvnc) + the app (Firefox 400–800 MB). VM RAM
cap set at boot (default 4 GB, configurable); macOS only commits pages the guest touches, but touched
pages don't come back (partial ballooning) → VM auto-shuts down N minutes after the last app closes.
CPU idle ~0–1%; browsing 0.5–1 core; video 1–2 cores. Lazy: nothing boots until an app is opened.

## 10. Milestones (each shippable behind a "Sandbox (beta)" setting)
- **M0 Spikes** — measure every [verify]: ad-hoc virtualization entitlement, VZLinuxBootLoader boot
  time + RAM, vsock throughput, Podman seccomp AF_VSOCK, `xray api adrules`, cage-headless + wayvnc +
  prototype Swift RFB at 1080p (latency, CPU), virtio-sound. *Done when:* numbers in `docs/SPEC.md`
  new section 19 and each decision above confirmed or changed.
- **M1 Runtime** — Settings → Sandbox: install/remove runtime (signed, hashed), boot/stop VM, vsock
  control agent, auto-shutdown, `<data>/sandbox/` layout. *Done when:* VM boots on demand in dev build,
  removal frees all disk.
- **M2 Gateway + per-app exits** — sandbox core on host, gateway netns, TPROXY, per-app netns,
  Terminal plugin (CLI over vsock exec). *Done when:* all in-VM leak probes pass in CI-runnable form;
  exit swap without restart; works with main VPN off/on/TUN.
- **M3 Window bridge** — Swift RFB client, `SandboxAppHost` stub, generated app bundles, badges, title
  capsule, clipboard/file bridges with permissions. *Done when:* Firefox appears as its own Mac app.
- **M4 Store** — `v2mac-store` repo + CI, signed index, layers, install/update/remove, Verify
  Installation; plugins Firefox, Chromium, Terminal, SSH, RDP. *Done when:* tampered layer/index is refused.
- **M5 Privacy profile** — TZ/locale/geo/WebRTC per exit, ephemeral homes, optional shields.
  *Done when:* NoLeaker's leak test page passes inside the sandboxed Firefox.
- **M6 Droplets** — Liquid Glass canvas, drag between/merge/split, live shared folder (mount
  propagation), droplet LAN, shared exit. *Done when:* download in Firefox, open with SSH app after merge.
- **M7 Hardening** — host-level leak script, sleep/wake/Wi-Fi scenarios, resource monitor, docs: spec,
  wiki (en/fa/zh/ru), README ×4, String Catalogs ×3.

## Files (host side)
- Package `Packages/V2MacCore/Sources/V2MacCore/Sandbox/`: `PluginManifest`, `StoreIndex` (+ signature
  checks), `GatewayConfig` (nft + in-VM xray JSON), `SandboxCoreConfig` (host xray), `RFB/` parser,
  `PrivacyProfile`. Tests in `Tests/V2MacCoreTests/Sandbox*`.
- App: `App/State/SandboxController.swift` (owns `VZVirtualMachine`, vsock listeners, second
  `CoreRunner`), `App/State/PluginService.swift`, `App/Features/Sandbox/` (droplet canvas, store, verify),
  `App/Features/Settings/SandboxSettings.swift`; wiring in `AppModel`; `Prefs` keys + defaults;
  `NotificationKind` cases (sandbox exit down, plugin update).
- New target `SandboxAppHost/` in `project.yml`; entitlement in `App/Resources/v2mac.entitlements`.
- Separate repos: `v2mac-sandbox-runtime` (image build), `v2mac-store` (plugins).

## Verification
- `cd Packages/V2MacCore && swift test --filter Sandbox` for manifests, signing, configs, RFB.
- Dev build only (`V2MacDev.app`, data in `v2mac-dev`); never touch the installed V2Mac or its core.
- `-debugSandbox install|boot|probe|launch <plugin>` debug hooks print `[v2mac-debug]` lines; probes
  run the §8 suite; `-debugSnapshot` checks windows, badges and the droplet canvas.
- Host leak script with tcpdump on the physical NIC during the probes.
