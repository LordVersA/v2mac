# v2mac — Implementation Spec (v1)

Status: agreed design, ready for implementation
Date: 2026-10-09
Target: macOS 26+, Apple Silicon, Swift 6 / SwiftUI, Xray-core v26.9.30

v2mac is a small, native macOS menu bar app that acts as a shell around
[Xray-core](https://github.com/XTLS/Xray-core). It imports subscription links,
shows their servers in groups, lets the user activate one, and serves the
connection as a local SOCKS5 + HTTP proxy. It does not reimplement any proxy
protocol and has no TUN mode.

---

## 1. Scope

### 1.1 Goals

- Add a subscription by pasting its URL; one group per subscription.
- List servers per group, sort and search them, test their latency.
- Activate a server: Xray starts (or restarts) and serves `127.0.0.1:10808`.
- Routing modes: Global, Bypass regions (data-driven list, Iran is the first
  entry), Direct.
- Live upload/download speed, a toggleable log panel, clear error states.
- Menu bar control panel; main window on demand.
- In-app update of the Xray core and of region rule files.
- Native Liquid Glass look, restrained use of colour.

### 1.2 Non-goals for v1

| Not in v1 | Note |
|---|---|
| TUN / system-wide VPN | Explicitly excluded. |
| Setting the macOS system proxy | The app only exposes local ports. |
| Adding single share links, QR import, file import, URL schemes | Subscription URL is the only input. |
| Manual (non-subscription) groups | Model allows them later; no UI. |
| Editing a server | Inspector is read-only. |
| Custom routing rules, rule-set manager | Presets only. |
| Viewing outbound JSON / exporting generated config | Not selected. |
| Per-server usage history, speed text in the menu bar | Not selected. |
| Localisation | English only, plain string literals. |
| Intel Macs, macOS 15 and earlier | arm64, macOS 26+ only. |
| Developer ID signing, notarization, Sparkle | Planned after v1. |
| Mux, TLS fragment, global sniffing options, DNS settings UI | Outbounds are used as provided. |
| Auto-select fastest server, notifications, global hotkeys | Future. |

---

## 2. Decision log

Answers given during the design interview.

| # | Topic | Decision |
|---|---|---|
| 1 | Distribution | Open source on GitHub. |
| 2 | Core integration | Official `xray` binary bundled in the app, run as a subprocess. |
| 3 | Stored form of a server | The Xray `outbound` JSON object is the source of truth, plus a few display fields and the original link. |
| 4 | Link formats | `vless`, `vmess`, `trojan`, `ss`, `hysteria2`/`hy2`, `socks`, `http`, `wireguard`, and raw Xray JSON. |
| 5 | Full Xray configs | Two profile kinds: `outbound` (app wraps it) and `custom` (run as written, app replaces inbounds/log/metrics). |
| 6 | Groups | A group is a subscription. Built-in "All" view. |
| 7 | Refresh reconcile | Replace, matching by fingerprint; active server survives; failed fetch never wipes a group. |
| 8 | Manual update | Two explicit actions: "Update via Proxy" and "Update without Proxy". |
| 9 | Auto-update | Respect `profile-update-interval`, else 12 h. Route for auto-update is one global setting (with / without proxy). |
| 10 | System proxy | Not controlled by the app. |
| 11 | Inbound | One `mixed` port (SOCKS5 + HTTP), default `127.0.0.1:10808`. |
| 12 | LAN | Localhost by default; "Allow LAN" toggle; optional username/password. |
| 13 | Routing | Presets only. Default is Global. |
| 14 | Region bypass | Generic list of region packs; v1 ships one (Iran); not enabled by default; downloaded on enable; auto-updatable. |
| 15 | Core delivery | Pinned core in the bundle + in-app updater with checksum verification and "Revert to bundled". |
| 16 | Latency | Real delay through a throwaway core (primary) + TCP ping (secondary). |
| 17 | Main window | Sidebar + server table + inspector, floating glass connection bar. |
| 18 | App presence | Menu bar only; Dock icon appears only while a window is open. |
| 19 | Activation | Activating a server connects to it immediately. |
| 20 | Lifecycle | Launch at login, reconnect on launch, auto-restart on crash, restart after sleep / network change. |
| 21 | Monitoring | Live speed only. |
| 22 | Logs | A log panel that slides in and out with a toggle; hidden by default; not a permanent part of the window. |
| 23 | Add flow | "+" opens a sheet: URL, optional Name, "Fetch via proxy" switch; Enter adds. |
| 24 | Inspector | Read-only summary + Copy share link + Show QR code. |
| 25 | Storage | SwiftData. |
| 26 | Platform | macOS 26+, Apple Silicon only. |
| 27 | Visual style | Native Liquid Glass, colour only for state. |
| 28 | Language | English only, hard-coded strings. |
| 29 | Name | `v2mac`, bundle ID `io.github.lordversa.v2mac`. |
| 30 | Licence | GPL-3.0. |
| 31 | Release | Ad-hoc signed DMG on GitHub Releases; update check via GitHub; notarization later. |
| 32 | Project layout | Thin app target + local Swift package `V2MacCore`; XcodeGen; Swift Testing. |

### 2.1 Defaults chosen by the author (not asked; change freely)

These were filled in to make the spec complete. Each is isolated enough to
change without affecting the rest.

1. **Port collision.** `10808` is also v2rayN's default. On the development
   Mac, v2rayN currently holds `10808` and another client holds `10809`. The app
   checks the port before starting and, if busy, shows an error with a one-click
   "Use <next free port>" action.
2. **`allowInsecure` links.** Xray v26.9.30 refuses to start with
   `allowInsecure: true`. The parser drops the flag and attaches a warning to the
   server instead of rejecting it.
3. **Unsupported entries** (removed transports `h2`/`http`/`quic`, unknown
   schemes) are skipped and counted; the group shows "N skipped".
4. **DNS in Bypass mode.** `IPIfNonMatch` with two DoH servers
   (`https://1.1.1.1/dns-query`, `https://8.8.8.8/dns-query`) queried in parallel
   (`enableParallelQuery`), sent through the proxy. A single DoH endpoint was
   found to stall ~4 s per new domain on some networks (see section 3). No DNS
   section in Global mode. No DNS UI.
5. **Log storage.** In-memory ring buffer of 5,000 lines; nothing written to
   disk. "Copy All" in the panel.
6. **Subscription User-Agent.** `v2mac/<version>`, editable in Settings.
7. **Secrets.** Stored with the rest of the app data (owner-only directory), not
   in the Keychain, because ad-hoc builds change signature on every release and
   would trigger Keychain prompts. Revisit when Developer ID signing arrives.
8. **Helper location.** The core lives in `Contents/Helpers/xray` rather than
   `Contents/Resources/core/`, which is the bundle location code signing expects
   for executables. Geo data stays in `Resources`.
9. **Subscription info.** When the provider sends `subscription-userinfo`, the
   group header shows used / total data and the expiry date.
10. **Latency defaults.** URL `https://www.gstatic.com/generate_204`, timeout
    8 s, 8 concurrent requests, 32 servers per throwaway core.

---

## 3. Verified facts

Checked on 2026-10-09 against the real v26.9.30 arm64 binary and upstream
sources. Re-check these when bumping the pinned core.

**Environment:** macOS 27.0.1, Xcode 27.0, Swift 6.4, arm64. Go is not installed
and is not needed. Only an "Apple Development" signing identity is present.

**Releases**

- Xray-core newest: `v26.9.30` (2026-09-30). GitHub marks every release since
  `v26.3.27` as pre-release, so `/releases/latest` returns the March build. The
  updater must list releases, not follow `latest`.
- macOS assets: `Xray-macos-arm64-v8a.zip` (contains `xray` 35 MB, `geoip.dat`
  16 MB, `geosite.dat` 11 MB) and `Xray-macos-arm64-v8a.zip.dgst`.
- `.dgst` format: lines such as `SHA2-256= <hex>`. For v26.9.30 arm64 the value
  is `4b363bd924df5bf09f87bd445755ff8e5742b9a8a0480cda261061416c3c7dce`
  (matched a local download).
- The binary is ad-hoc linker-signed and runs as downloaded.
- Unauthenticated GitHub API calls can be rate-limited on shared IPs (observed
  during research). The updater needs a fallback (section 11.1).

**Runtime behaviour**

- `xray run -test -c <file>` prints `Configuration OK.` and exits 0 on success;
  on failure it prints `Failed to start: ...` with a causal chain.
- Readiness line on stdout: `[Warning] core: Xray 26.9.30 started`.
- `SIGTERM` stops the core cleanly (exit 0).
- A `mixed` inbound accepts SOCKS5 and HTTP on the same port (both returned 204
  for the test URL).
- Access log lines go to stdout unless `"access": "none"` is set.
- Metrics: with `"metrics": {"tag": "...", "listen": "127.0.0.1:<port>"}`,
  `"stats": {}` and the `policy.system.stats*` flags, `GET /debug/vars` returns
  JSON whose `stats` key has this shape:

  ```json
  { "inbound":  { "mixed-in": { "downlink": 12080, "uplink": 3965 } },
    "outbound": { "proxy":    { "downlink": 12029, "uplink": 3818 } },
    "user": {} }
  ```

- `XRAY_LOCATION_ASSET=<dir>` sets where geo files are loaded from, and
  `ext:<file>:<tag>` loads a tag from a non-default file in that directory
  (config test passed with `ext:region-ir-geosite.dat:ir`).

**Config shapes accepted by v26.9.30** (all passed `-test`)

- VLESS outbound, flat form: `settings: {address, port, id, encryption, flow}`.
  The older `vnext` form is also still accepted.
- VMess flat: `{address, port, id, security}`. Trojan flat:
  `{address, port, password}`. Shadowsocks flat:
  `{address, port, method, password}`.
- Hysteria 2: `protocol: "hysteria"`, `settings: {version: 2, address, port}`,
  `streamSettings: {network: "hysteria", security: "tls", hysteriaSettings:
  {version: 2, auth}}`.
- Transport names: `raw` (alias `tcp`), `xhttp` (alias `splithttp`), `kcp`,
  `grpc`, `ws`, `httpupgrade`, `hysteria`.

- TLS pinning fields are strings, not arrays: `tlsSettings.pinnedPeerCertSha256`
  (comma-separated 64-hex hashes) and `verifyPeerCertByName` (comma-separated
  names). `echConfigList` is a string.
- Hysteria 2 port hopping: `hysteriaSettings.udphop {port: "5000-6000",
  interval: 30}`; Salamander obfuscation: `streamSettings.finalmask.udp =
  [{type: "salamander", settings: {password}}]`.
- VLESS with `encryption: none` and no TLS/REALITY is rejected at config load
  (confirmed for both IP and domain addresses). The parser adds a warning.
- Checked 2026-10-09 (M2): `URLSession` never sends loopback or private
  destinations through `proxyConfigurations`; tests that prove proxy routing
  must use a public URL.

- Access log shows rule-matched routing as `[mixed-in -> direct]` (single arrow) and
  default-outbound routing as `[mixed-in >> proxy]`. (M4, 2026-10-09)
- DoH latency (M4, 2026-10-09, checked from Iran): with only `https://1.1.1.1/dns-query`
  every non-matching domain took 4.3 s ("context deadline exceeded"), also with
  `https+local://`; `https://8.8.8.8/dns-query` answered in 0.3 s, plain UDP
  `1.1.1.1` too. Two DoH servers with `enableParallelQuery` gave 0.8 s for the
  first lookup and 0.3 s after, independent of which one is filtered.

**Removed or deprecated in this core**

- `tlsSettings.allowInsecure: true` is a hard error (replaced by
  `pinnedPeerCertSha256` and `verifyPeerCertByName`).
- Transports `h2` / `http` and `quic` are hard errors.
- `ws`, `grpc`, `httpupgrade`, and the VMess / Trojan / Shadowsocks protocols
  print deprecation warnings but work.

**Region rules (Iran)**

- Source: `Chocolate4U/Iran-v2ray-rules`, published daily, GPL-3.0 data.
- `geoip-lite.dat` (38 KB) contains `ir` and `private`;
  `geosite-lite.dat` (1.9 MB) contains `ir` and `category-ir`.
- Checksums: `<file>.sha256sum`, format `<hex>  release/<file>`.

**Reference parser:** `XTLS/libXray`, directory `share/` (MIT). It covers
`vless`, `vmess` (URL form only), `trojan`, `ss`, `socks`, `hysteria2`. It does
not cover the v2rayN base64-JSON `vmess://` form or `wireguard://`.

---

## 4. Architecture

```
┌──────────────────────────── v2mac.app ────────────────────────────┐
│  App target (SwiftUI, SwiftData)                                  │
│   MenuBarExtra panel · Main window · Settings · Log panel         │
│   AppModel ─ ConnectionController ─ SubscriptionService           │
│            ─ LatencyService ─ UpdateService ─ LogStore            │
│                         │ uses                                     │
│  V2MacCore (Swift package, no UI, no SwiftData)                   │
│   ShareLinks · Subscription · XrayConfig · CoreRunner             │
│   Latency · Stats · Updater · JSONValue                           │
└───────────────┬───────────────────────────────────────────────────┘
                │ Process (stdout/stderr pipes), SIGTERM
                ▼
        xray run -c run/config.json          ← XRAY_LOCATION_ASSET=assets/
          ├─ mixed inbound  127.0.0.1:10808  ← user's apps
          └─ metrics        127.0.0.1:<random> ← app polls /debug/vars
```

- Swift 6 language mode, strict concurrency.
- `V2MacCore` works only with value types (`Sendable` structs and `JSONValue`).
  The app maps them to SwiftData models. This keeps the package testable with
  `swift test` and free of main-actor constraints.
- UI state lives in `@MainActor @Observable` objects. Database writes that touch
  many rows (subscription reconcile, latency results) run in a `@ModelActor`.

---

## 5. Data model

### 5.1 Package value types

```swift
public enum JSONValue: Sendable, Hashable, Codable {
    case null, bool(Bool), number(Double), string(String)
    case array([JSONValue]), object([String: JSONValue])
}

public enum ProfileKind: String, Sendable, Codable { case outbound, custom }

public struct ParsedProfile: Sendable, Hashable {
    public var name: String
    public var kind: ProfileKind
    public var protocolName: String   // vless, vmess, trojan, shadowsocks,
                                      // hysteria, wireguard, socks, http, custom
    public var address: String
    public var port: Int
    public var transport: String      // raw, xhttp, ws, grpc, httpupgrade,
                                      // kcp, hysteria, "" for custom
    public var security: String       // none, tls, reality
    public var config: JSONValue      // outbound object, or full config
    public var originalLink: String?
    public var fingerprint: String    // see 5.3
    public var warnings: [String]
}
```

### 5.2 SwiftData models (app target)

```swift
@Model final class ServerGroup {
    @Attribute(.unique) var id: UUID
    var name: String
    var subscriptionURL: String
    var sortIndex: Int
    var createdAt: Date
    var autoUpdateEnabled: Bool          // default true
    var serverIntervalHours: Int?        // from profile-update-interval
    var lastUpdatedAt: Date?
    var lastUpdateViaProxy: Bool?
    var lastUpdateError: String?
    var lastSkippedCount: Int
    var usedBytes: Int64?                // upload + download
    var totalBytes: Int64?
    var expiresAt: Date?
    @Relationship(deleteRule: .cascade, inverse: \Profile.group)
    var profiles: [Profile]
}

@Model final class Profile {
    @Attribute(.unique) var id: UUID
    var group: ServerGroup?
    var sortIndex: Int                   // order in the subscription
    var name: String
    var kindRaw: String
    var protocolName: String
    var address: String
    var port: Int
    var transport: String
    var security: String
    var configJSON: Data                 // source of truth
    var originalLink: String?
    var fingerprint: String
    var warnings: [String]
    var isStale: Bool                    // removed upstream but still active
    var delayMs: Int?
    var delayStateRaw: String            // untested | ok | timeout | invalid
    var delayKindRaw: String?            // real | tcp
    var delayTestedAt: Date?
}
```

"Testing in progress" is transient UI state held in memory, not persisted.
The active server ID, "was running" flag and all settings live in
`UserDefaults`.

### 5.3 Fingerprint

SHA-256 (hex) of the profile's config serialised with sorted keys, after
removing naming fields: `tag` for outbounds; `remarks` and `tag` of the first
outbound for custom configs. Two entries with the same connection parameters but
different display names share a fingerprint.

---

## 6. Subscriptions

### 6.1 Fetch

- `GET` with `User-Agent: v2mac/<version>` (configurable), 15 s timeout,
  redirects followed, 10 MB body cap, any 2xx accepted.
- Route **without proxy**: default `URLSession`.
- Route **via proxy**: `URLSessionConfiguration.proxyConfigurations =
  [ProxyConfiguration(socksv5Proxy: 127.0.0.1:<port>)]`, with credentials if
  inbound auth is on. Only possible while the core is running.

### 6.2 Response metadata

| Header | Use |
|---|---|
| `profile-title` | Group name when the user left Name empty. Plain text or `base64:<...>`. |
| `content-disposition` filename | Fallback name. Final fallback: URL host. |
| `profile-update-interval` | Hours between automatic updates for this group. |
| `subscription-userinfo` | `upload=..; download=..; total=..; expire=..` → used / total / expiry. |

Body lines of the form `#profile-title: ...` / `#profile-update-interval: ...`
are accepted as a fallback for the same fields.

### 6.3 Body detection

1. Strip BOM, normalise line endings, trim.
2. If it starts with `[` or `{`, parse as JSON:
   - array of objects with `outbounds` → one `custom` profile each (name from
     `remarks`, else "Config N");
   - single object with `outbounds` → one `custom` profile;
   - object with `protocol` → one `outbound` profile.
3. Else, if any line starts with a known scheme, parse as a link list (one per
   line; blank lines and lines starting with `#` or `//` ignored).
4. Else, try base64 (standard and URL-safe, missing padding and embedded
   whitespace tolerated) and repeat steps 2–3 on the decoded text.
5. Else fail with "Unrecognised subscription format". Clash YAML and sing-box
   JSON get a specific "format not supported" message.

A response that yields zero profiles is a failure, not an empty group.

### 6.4 Reconcile (in a `@ModelActor`)

Given the new ordered list for a group:

1. Index existing profiles by fingerprint (keeping duplicates in order).
2. For each new entry, in order: reuse the first unused existing profile with
   the same fingerprint (update `name`, `sortIndex`, `originalLink`, `warnings`,
   clear `isStale`; keep `id` and delay fields); otherwise insert a new one.
3. Existing profiles not reused are deleted, except the active one, which is
   kept with `isStale = true`, sorted last and badged "Removed from
   subscription". It is deleted as soon as another server is activated.
4. Update the group's metadata, `lastUpdatedAt`, `lastUpdateViaProxy`,
   `lastSkippedCount`, and clear `lastUpdateError`.

On any failure the group's profiles are left untouched and only
`lastUpdateError` is set.

### 6.5 Update triggers

- **Add:** the sheet fetches first; the group is created only on success.
- **Manual:** "Update via Proxy" / "Update without Proxy" on a group, or on all
  groups from the "All" view. "Via Proxy" is disabled while disconnected.
- **Automatic:** while the app runs, a group is due when
  `now - lastUpdatedAt ≥ (serverIntervalHours ?? 12 h)` and
  `autoUpdateEnabled` and the global auto-update switch are on. Overdue groups
  are also refreshed shortly after launch. The route is the global setting
  "Auto-update route". If it is "via proxy" and the core is not running, the
  update is skipped silently and retried at the next check (every 15 min).

---

## 7. Share-link parsing

Port the mapping from libXray `share/` at tag `v26.9.30` (MIT, attribute in
`THIRD_PARTY.md`), then add what it lacks. Output is always an Xray outbound in
the flat settings form listed in section 3.

| Scheme | Notes |
|---|---|
| `vless://uuid@host:port?...#name` | Query: `type`, `security`, `encryption`, `flow`, `sni`, `fp`, `alpn`, `pbk`, `sid`, `spx`, `pqv`, `ech`, `pcs`, `vcn`, `path`, `host`, `serviceName`, `mode`, `headerType`, `seed`, `extra`. |
| `vmess://<base64 JSON>` | v2rayN form: `v, ps, add, port, id, aid, scy, net, type, host, path, tls, sni, alpn, fp`. Not in libXray; implement from the v2rayN format description. |
| `vmess://uuid@host:port?...` | URL form, same query handling as VLESS. |
| `trojan://password@host:port?...#name` | `security` defaults to `tls`. |
| `ss://` | SIP002 (`base64(method:password)@host:port`, plain userinfo for 2022 ciphers) and legacy fully-base64 form. `plugin` parameter → skipped as unsupported. |
| `hysteria2://`, `hy2://` | `auth@host:port[,port-range]`, `sni`, `alpn`, `obfs`; multi-port authority as in libXray. `pinSHA256` → skipped as unsupported. |
| `socks://`, `socks5://` | `base64(user:pass)@host:port` or plain userinfo. |
| `http://`, `https://` (as a server line) | `user:pass@host:port`; `https` implies TLS. Only recognised inside a subscription body. |
| `wireguard://privkey@host:port?publickey=&address=&mtu=&reserved=&presharedkey=#name` | Maps to the `wireguard` outbound (`secretKey`, `address`, `peers`, `mtu`, `reserved`). |

Rules that apply to all schemes:

- Name: URL fragment, percent-decoded; fallback `host:port`.
- IPv6 hosts in brackets; ports validated to 1–65535.
- `allowInsecure=1` / `insecure=1`: flag dropped, warning
  "allowInsecure is not supported by this Xray version; the server must present
  a valid certificate" added.
- `type=h2`, `type=http`, `type=quic`: skipped with reason "transport removed
  from Xray".
- `type=tcp` is written as `raw`; `splithttp` as `xhttp`.
- The outbound never contains a `tag`; the config builder assigns it.
- A parse failure skips that line with a reason; it never fails the whole
  subscription.

**Test strategy:** a fixture corpus of real-shaped links per scheme and
transport. Unit tests assert the produced JSON. An integration test wraps every
produced outbound in a minimal config and runs `xray run -test` against the
vendored binary; this is the guard against upstream format drift.

---

## 8. Xray config generation

### 8.1 Outbound profiles

```json
{
  "log": { "loglevel": "<setting>", "access": "none" },
  "stats": {},
  "policy": { "system": { "statsInboundUplink": true,
                          "statsInboundDownlink": true } },
  "metrics": { "tag": "metrics", "listen": "127.0.0.1:<free port>" },
  "inbounds": [ <mixed inbound> ],
  "outbounds": [
    { ...profile outbound..., "tag": "proxy" },
    { "tag": "direct", "protocol": "freedom" },
    { "tag": "block",  "protocol": "blackhole" }
  ],
  "routing": <per mode>,
  "dns": <Bypass mode only>
}
```

`"access"` is omitted (so connections are logged to stdout) when the
"Log connections" setting is on.

**Mixed inbound**

```json
{ "tag": "mixed-in",
  "listen": "127.0.0.1",            // "0.0.0.0" when Allow LAN is on
  "port": 10808,
  "protocol": "mixed",
  "settings": { "auth": "noauth", "udp": true },
  "sniffing": { "enabled": true, "routeOnly": true,
                "destOverride": ["http", "tls", "quic"] } }
```

With credentials: `"auth": "password", "accounts": [{"user": "...",
"pass": "..."}]`.

**Routing per mode**

- **Global** — `domainStrategy: "AsIs"`, one rule: `ip: ["geoip:private"]` →
  `direct`. Everything else falls through to `proxy` (first outbound).
- **Bypass regions** — `domainStrategy: "IPIfNonMatch"`; rules in order:
  `geoip:private` → `direct`; then, for each enabled and downloaded pack, its
  domain tags → `direct` and its IP tags → `direct`, written as
  `ext:<file>:<tag>`. Plus `"dns": {"servers": ["https://1.1.1.1/dns-query",
  "https://8.8.8.8/dns-query"], "queryStrategy": "UseIP", "enableParallelQuery":
  true}`. Without that DNS entry, non-matching domains
  would be resolved by the local resolver, which leaks queries and, on networks
  that poison DNS with private addresses, would wrongly match `geoip:private`.
  If no pack is usable, the builder produces the Global routing.
- **Direct** — one catch-all rule `network: "tcp,udp"` → `direct`.

### 8.2 Custom profiles

Take the stored config and:

1. Replace `inbounds` with the single mixed inbound above.
2. Replace `log`; set `metrics`; ensure `stats: {}`; merge the two
   `policy.system.statsInbound*` flags.
3. In `routing.rules`, rewrite any `inboundTag` that named a removed
   `socks` / `http` / `mixed` inbound to `mixed-in`; drop rules that referenced
   only other removed inbounds.
4. Leave `outbounds`, the rest of `routing`, `dns` and everything else as
   written. The routing mode picker is disabled ("Managed by this config").

### 8.3 Output

Written to `run/config.json` with mode `0600`, replaced atomically, deleted when
the core stops.

---

## 9. Core process management

### 9.1 Locating the core

Use `~/Library/Application Support/v2mac/core/xray` if present and executable,
otherwise `v2mac.app/Contents/Helpers/xray`. The version shown in Settings comes
from `xray version`.

### 9.2 Asset directory

`XRAY_LOCATION_ASSET` always points at
`~/Library/Application Support/v2mac/assets/`. On launch the app makes sure it
contains `geoip.dat` and `geosite.dat` (symlinks to the bundled files unless a
core update installed newer copies) and any downloaded region pack files.

### 9.3 State machine

```
stopped ──start──▶ starting ──ready──▶ running ──stop──▶ stopping ──▶ stopped
                      │                   │
                      └──── failed(reason) ◀── unexpected exit (after retries)
```

- **Start:** check the port is free (try to bind, then release) → build config
  → launch `xray run -c run/config.json` with pipes on stdout and stderr → wait
  up to 5 s for a line containing `core: Xray` and `started`, or for the mixed
  port to accept a TCP connection. Exit before readiness → `failed`.
- **Stop:** `SIGTERM`; `SIGKILL` after 2 s.
- **Switch server / change mode / change port:** stop, then start; the UI shows
  "Switching…" rather than a disconnected state.
- **Unexpected exit while running:** restart after 1 s, 3 s, 10 s. The counter
  resets after 60 s of stable running. After the third failure → `failed` with
  the last error line.
- **App quit (⌘Q, logout, SIGTERM/SIGINT):** stop the core. Closing the main
  window does not.
- **Orphans:** the app writes `run/xray.pid`. On launch, if that PID is alive
  and its executable path (`proc_pidpath`) is one of the two core locations, it
  is terminated. The app never signals an `xray` process by name; other clients
  on the same Mac run their own.
- **Wake from sleep** (`NSWorkspace.didWakeNotification`) and **network path
  change** (`NWPathMonitor`, debounced 2 s): restart the core if it was running
  and the setting is on.
- **Reconnect on launch:** if "was running" is set and the active server still
  exists, start automatically.

### 9.4 Error mapping

| Condition | Message |
|---|---|
| Port busy (pre-check, or `address already in use` in output) | "Port 10808 is already in use." + "Use <free port>" |
| Core missing / not executable | "Xray core not found. Reinstall the app or revert to the bundled core." |
| Exit before ready with `Failed to start:` | Last segment of the causal chain, e.g. "…\"allowInsecure\" has been removed…" |
| Three consecutive crashes | "Xray stopped unexpectedly (exit N)." |

Every failed state offers "Show Logs", which opens the log panel.

---

## 10. Latency testing

### 10.1 Real delay (primary)

1. Split the selected `outbound` profiles into batches of 32.
2. For each batch, obtain free local ports (bind to port 0, read, release) and
   generate a config with one `socks` inbound `in-i` per profile on
   `127.0.0.1`, one outbound `out-i` per profile, and one routing rule
   `inboundTag: [in-i]` → `out-i`. Log level `none`, no metrics, no geo rules.
3. Start a throwaway core with this config. If it exits before ready, split the
   batch in half and retry each half; a batch of one that still fails marks that
   profile `invalid` with the core's error line.
4. With 8 concurrent requests, send `GET <test URL>` through each port using an
   ephemeral `URLSession` with `ProxyConfiguration(socksv5Proxy:)`, timeout 8 s.
   Elapsed time to response headers is the delay. Any error or non-2xx/3xx →
   `timeout`.
5. Stop the throwaway core; write results in one batch.

`custom` profiles are tested one per throwaway core, using the transformation
from 8.2 with a temporary port.

The live connection is never touched. Cancelling stops outstanding requests and
kills the throwaway core.

### 10.2 TCP ping (secondary)

`NWConnection` TCP connect to `address:port`, 3 s timeout, 32 concurrent. Shown
as "n/a" for UDP-based servers (`hysteria`, `wireguard`, `kcp`) and for custom
profiles.

### 10.3 Presentation

The Delay column shows the latest result of either kind: green under 300 ms,
amber under 800 ms, red above, "timeout", "invalid", or a spinner. Sorting by
Delay puts untested and failed rows last.

---

## 11. Updates and downloads

All downloads try the local proxy first when the core is running, then fall
back to a direct connection.

### 11.1 Xray core

- **Discover:** `GET api.github.com/repos/XTLS/Xray-core/releases?per_page=10`,
  take the newest by `published_at`, pre-releases included. On HTTP 403/429
  fall back to parsing `github.com/XTLS/Xray-core/releases.atom`.
- **Install:** download `Xray-macos-arm64-v8a.zip` and its `.dgst`; compare the
  `SHA2-256=` value; unpack with `/usr/bin/ditto -x -k` into a temp directory;
  run `xray version` and `xray run -test` on the current config with the new
  binary; then move `xray` to `core/` and the two `.dat` files to `assets/`.
  Restart the core if it was running.
- **Revert to bundled:** delete `core/xray` and restore the asset symlinks.
- Manual only ("Check for Update" in Settings). The UI shows current version,
  available version and its date.

### 11.2 Region packs

Defined in a bundled `RegionPacks.json`; adding a region is a data change.

```json
[ { "id": "ir",
    "name": "Iran",
    "attribution": "Chocolate4U/Iran-v2ray-rules (GPL-3.0)",
    "geosite": { "url": "https://github.com/Chocolate4U/Iran-v2ray-rules/releases/latest/download/geosite-lite.dat",
                 "file": "region-ir-geosite.dat", "tags": ["ir"] },
    "geoip":   { "url": "https://github.com/Chocolate4U/Iran-v2ray-rules/releases/latest/download/geoip-lite.dat",
                 "file": "region-ir-geoip.dat",  "tags": ["ir"] } } ]
```

- Checksum URL is `<url>.sha256sum`; the first whitespace-separated token is
  the hash.
- **Enable** downloads both files into `assets/`, verifies them, then marks the
  pack enabled. Nothing region-specific ships in the app bundle.
- **Auto-update** per pack: Never / Daily / Weekly (default Weekly), plus
  "Update Now". A successful update restarts the core if the pack is in use.
- "Bypass regions" cannot be selected until at least one pack is enabled.

### 11.3 App update check

Once per 24 h (and on demand), read the latest release of the app's own repo.
If its version is higher, show "Update available" in the menu bar panel and in
Settings, linking to the release page. No automatic install in v1. Can be
turned off.

---

## 12. User interface

### 12.1 Presence and windows

- `LSUIElement = YES`. A `MenuBarExtra` with `.menuBarExtraStyle(.window)` is
  always present.
- The main window (`Window`, single instance) opens on first launch and from
  the menu bar panel. Opening the main or Settings window switches the
  activation policy to `.regular` (Dock icon, ⌘Tab, normal menus) and activates
  the app; closing the last window switches back to `.accessory`.

### 12.2 Menu bar item

Icon by state: outline (stopped), animated (starting / switching), filled
(running), filled with warning badge (failed).

Panel, top to bottom:

1. Connect toggle with state text ("Connected", "Connecting…", "Off", error).
2. Active server name, group, last delay.
3. Live download and upload rate.
4. "Switch Server": up to six rows — the active server, then the fastest
   tested servers of the active server's group. Click = activate.
5. Routing mode picker.
6. Local address with a copy button.
7. "Update available" row when relevant.
8. Open v2mac · Settings… · Quit.

### 12.3 Main window

```
┌────────────┬──────────────────────────────────┬──────────────┐
│            │ 🔍 Search   ＋  ↻▾  ⚡▾  ▤  ⓘ    │              │
│ All     42 ├──────────────────────────────────┤ DE-Frankfurt │
│ ↻ Prov A 18│   Name           Type      Delay │ VLESS        │
│ ↻ Prov B 24│ ● DE-Frankfurt   vless     142ms │ xhttp·reality│
│            │   NL-Amsterdam   vless ws  188ms │ 1.2.3.4:443  │
│            │   FI-Helsinki    trojan    231ms │ 142 ms       │
│            │   TR-Istanbul    vmess   timeout │              │
│            │ ╭──────────────────────────────╮ │ [Copy Link]  │
│            │ │ ⏻ DE-Frankfurt · Global ▾     │ │ [Show QR]    │
│            │ │ 127.0.0.1:10808 ⧉ ↓1.2M ↑80K  │ │              │
│            │ ╰──────────────────────────────╯ │              │
│            │ ▁▁▁▁▁▁▁ log panel (toggle) ▁▁▁▁▁ │              │
└────────────┴──────────────────────────────────┴──────────────┘
```

Structure: `NavigationSplitView` (sidebar, content) with `.inspector` on the
content column.

**Sidebar.** "All" plus one row per group: name, server count, a spinner while
updating, a warning glyph when the last update failed (tooltip shows the
error). Drag to reorder. Context menu: Update via Proxy, Update without Proxy,
Rename, Edit URL…, Copy URL, Auto-update (toggle), Delete…. Deleting the group
that owns the active server asks for confirmation and disconnects.

**Group header** (above the table, when a group is selected): last updated time
and route, "N skipped" if any, and when available a thin usage bar with
"12.4 of 50 GB · expires 2 Nov 2026".

**Server table.** SwiftUI `Table`, multi-selection. Columns: active marker,
Name, Type (`protocol · transport · security`), Address (hidden by default),
Delay. Default order is subscription order; columns sort; `.searchable` filters
by name, address and type. Single click selects (drives the inspector).
Double-click or Return activates. Context menu: Connect, Test Delay, TCP Ping,
Copy Share Link, Show QR Code. A warning glyph on rows that carry `warnings`.

**Toolbar.** Add (＋). Update menu button (via proxy / without proxy; acts on
the selected group, or all groups in "All"). Test menu button (Real Delay as
the primary action, TCP Ping in the menu; acts on the selection, or on all
visible rows when nothing is selected). Log panel toggle. Inspector toggle.

**Connection bar.** A floating glass capsule pinned to the bottom of the
content column with `safeAreaInset(edge: .bottom)`: connect button, active
server name, routing mode menu, local address with a copy menu
(`127.0.0.1:10808`, `socks5://…`, `http://…`, and shell `export` lines), live
rates. In a failed state it turns red and shows the one-line cause with
"Show Logs".

**Inspector** (read-only). Name, protocol, transport, security, address and
port, SNI/host when present, last delay with its time and kind, any warnings.
Buttons: Copy Share Link, Show QR Code (popover rendered with CoreImage's QR
generator). Both are disabled for profiles without an original link (custom
configs).

**Log panel.** A bottom drawer inside the content column, hidden by default,
toggled from the toolbar, View menu and ⇧⌘L. Monospaced lines from the core's
stdout/stderr plus app events prefixed `[v2mac]`. Controls: level filter,
search field, auto-scroll that pauses when scrolled up, Clear, Copy All.
Resizable; height remembered.

**Add Subscription sheet.**

```
╭─ Add Subscription ───────────────────────────╮
│  URL   [ https://sub.example.com/abc123    ] │
│  Name  [ (auto)                            ] │
│  [ ] Fetch via proxy                         │
│                      Cancel    [ Add  ↵ ]    │
╰──────────────────────────────────────────────╯
```

URL is pre-filled when the clipboard holds an http(s) URL. "Fetch via proxy" is
off by default and disabled while disconnected. Enter fetches; a spinner
replaces the button; errors appear inline and the sheet stays open. On success
the group is created, selected, and the sheet closes. A URL that already exists
offers to update that group instead.

**Empty states.** No groups: centred prompt with an "Add Subscription" button.
Empty search: "No servers match".

### 12.4 Keyboard

| Shortcut | Action |
|---|---|
| ⌘N | Add subscription |
| ⌘R / ⌥⌘R | Update without proxy / via proxy |
| ⌘T | Test real delay |
| Return | Activate selected server |
| ⌘F | Search |
| ⌘I | Toggle inspector |
| ⇧⌘L | Toggle log panel |
| ⌘, | Settings |

### 12.5 Liquid Glass guidance

- Build against the macOS 26+ SDK and let the system supply glass for the
  sidebar, toolbar, sheets, popovers and the menu bar panel. Do not add custom
  backgrounds that would defeat it.
- Custom glass is used in two places only: the connection bar and the connect
  control. Group the bar's elements in a `GlassEffectContainer`; apply
  `.glassEffect(...)` after layout modifiers; use an interactive, state-tinted
  glass for the connect button and `glassEffectID` with a namespace to morph it
  between off / connecting / connected.
- Standard buttons use the system glass button styles.
- Glass belongs to the control layer. Table rows, the inspector body and the
  log text stay on plain content backgrounds.
- Colour carries meaning only: green connected, amber connecting, red failed,
  and the delay thresholds. Everything else follows the user's accent colour
  and appearance.
- Check the exact modifier signatures in the Xcode 27 SDK before use; they
  changed during the macOS 26 betas.

---

## 13. Settings

| Tab | Setting | Default |
|---|---|---|
| General | Launch at login (`SMAppService.mainApp`) | Off |
| | Reconnect on launch | On |
| | Restart core after sleep or network change | On |
| | Check for app updates | On |
| Proxy | Port | 10808 |
| | Allow connections from LAN (shows the Mac's LAN address) | Off |
| | Username / Password (warning shown when LAN is on and these are empty) | Empty |
| Routing | Mode: Global / Bypass regions / Direct | Global |
| | Bypass regions list: enable, status, Update Now, auto-update interval | None enabled |
| Subscriptions | Auto-update subscriptions | On |
| | Auto-update route: Without proxy / Via proxy | Without proxy |
| | Default interval when the provider sends none | 12 h |
| | User-Agent | `v2mac/<version>` |
| Latency | Test URL | `https://www.gstatic.com/generate_204` |
| | Timeout | 8 s |
| | Concurrency | 8 |
| Core | Version, Check for Update, Revert to Bundled | — |
| Advanced | Log level: error / warning / info / debug | warning |
| | Log connections | Off |
| About | Version, source link, licences and attributions | — |

Changing Port, LAN, credentials, Mode, Log level or Log connections while
connected restarts the core.

---

## 14. Files on disk

```
~/Library/Application Support/v2mac/        (0700)
├─ default.store                 SwiftData
├─ core/xray                     only after an in-app core update
├─ assets/
│  ├─ geoip.dat, geosite.dat     symlinks to the bundle, or updated copies
│  └─ region-<id>-geoip.dat, region-<id>-geosite.dat
└─ run/
   ├─ config.json                0600, exists only while running
   └─ xray.pid

v2mac.app/Contents/
├─ MacOS/v2mac
├─ Helpers/xray
└─ Resources/geoip.dat, geosite.dat, RegionPacks.json
```

---

## 15. Project structure and tooling

```
v2mac/
├─ project.yml                     XcodeGen
├─ App/
│  ├─ V2MacApp.swift
│  ├─ Models/                      SwiftData @Model, ModelActor services
│  ├─ State/                       AppModel, ConnectionController, LogStore,
│  │                               SettingsStore, UpdateService
│  ├─ Features/                    Sidebar, ServerList, Inspector,
│  │                               ConnectionBar, AddSubscription, Logs,
│  │                               MenuBar, Settings
│  └─ Resources/                   Assets, RegionPacks.json, Info.plist
├─ Packages/V2MacCore/
│  ├─ Package.swift
│  ├─ Sources/V2MacCore/
│  │  ├─ JSON/  ShareLinks/  Subscription/  XrayConfig/
│  │  └─ CoreRunner/  Latency/  Stats/  Updater/
│  └─ Tests/V2MacCoreTests/        Fixtures/ (links, bodies, expected JSON)
├─ Scripts/
│  ├─ core.lock                    version + sha256 of the pinned zip
│  ├─ fetch-core.sh                download, verify, unpack to Vendor/core/
│  └─ make-dmg.sh
├─ Vendor/                         git-ignored
├─ docs/SPEC.md
├─ LICENSE                         GPL-3.0
└─ THIRD_PARTY.md
```

- No binaries are committed. `fetch-core.sh` downloads the pinned release,
  checks it against `core.lock`, and unpacks into `Vendor/core/`; the Xcode
  project copies `xray` to `Contents/Helpers` and the `.dat` files to
  `Resources`, and signs the helper with the app.
- No third-party Swift dependencies in v1.
- Tests use Swift Testing. Unit tests run with `swift test` in the package.
  Integration tests that need the real binary are tagged and skipped when
  `Vendor/core/xray` is absent.
- CI (GitHub Actions, macOS runner with Xcode 26 or later): fetch core, run
  package tests, build the app.

### 15.1 Build, signing, release

- Development: sign with the local Apple Development identity.
- Release: ad-hoc sign (`codesign --force --sign -`, helper first, then the
  app), package as a DMG, attach to a GitHub Release with its SHA-256.
- The README must explain the first-launch step for unsigned apps: open the app
  once, then System Settings → Privacy & Security → "Open Anyway" (the
  right-click → Open shortcut no longer works on current macOS), or
  `xattr -dr com.apple.quarantine /Applications/v2mac.app`.
- Homebrew is not a workaround: it quarantines casks too and is retiring casks
  that fail Gatekeeper.
- Keep signing identity and notarization as script parameters so Developer ID
  can be added later without restructuring.

### 15.2 Licensing

- App code: GPL-3.0.
- Xray-core: MPL-2.0, shipped unmodified as a separate executable; include its
  licence and a link to the source.
- libXray `share/`: MIT; the Swift port carries its copyright notice.
- Iran rule files: GPL-3.0 data downloaded at the user's request; credited in
  About and next to the pack.

---

## 16. Security and privacy

- Listeners bind to `127.0.0.1` unless "Allow LAN" is on. The metrics endpoint
  and latency-test inbounds are always loopback-only on random ports.
- With LAN on and no credentials the app shows a persistent warning: anyone on
  the network can use the proxy.
- Generated configs contain server credentials; they are `0600` and removed on
  stop. The data directory is `0700`.
- Subscription URLs usually embed a token. They are shown only in the edit
  sheet and via "Copy URL", and are never written to the log.
- Network requests the app itself makes: subscription URLs, the latency test
  URL, GitHub (app update check, core releases), and region pack downloads. No
  analytics, no telemetry.
- Downloads of executables and rule files are verified against published
  SHA-256 values before use. These checksums come from the same host as the
  files, so they protect against corruption, not against a compromised
  upstream.
- The app only ever terminates a process whose PID it recorded and whose
  executable path matches its own core.

---

## 17. Milestones

Each milestone ends in something runnable and tested.

**M0 — Scaffold.** Repo, licence, `project.yml`, empty app that shows a menu bar
icon, `V2MacCore` package, `fetch-core.sh` + `core.lock`, CI.
*Done when:* `swift test` and an Xcode build pass from a clean clone.

**M1 — Engine (package only).** `JSONValue`, config builder for Global mode,
`CoreRunner` (start, readiness, stop, log stream, port pre-check, PID file),
stats client.
*Done when:* an integration test starts the real core with a `freedom`
outbound, fetches the test URL through the mixed port over both SOCKS5 and
HTTP, reads non-zero counters from `/debug/vars`, and stops cleanly.

**M2 — Parsing and subscriptions.** All link schemes, body detection, header
parsing, fetcher with both routes, fingerprinting.
*Done when:* every fixture produces the expected outbound and every produced
outbound passes `xray run -test`; removed features are skipped or warned as
specified.

**M3 — App shell.** SwiftData models, reconcile actor, main window (sidebar,
table, inspector), Add Subscription sheet, activation → connect, connection
bar, menu bar panel, Dock policy.
*Done when:* a real subscription can be added, a server activated, and
`curl -x socks5h://127.0.0.1:10808` works; closing the window keeps it running.

**M4 — Latency, routing, region packs.** Real delay with bisection, TCP ping,
mode picker, pack download/enable, Bypass routing and DNS, custom-profile
transformation.
*Done when:* testing a 100-server group completes and sorts correctly without
disturbing the live connection; with the Iran pack enabled, a domain in the
pack is logged as `[mixed-in -> direct]` and another as `[mixed-in >> proxy]`.

**M5 — Lifecycle, logs, settings.** Settings window, launch at login, reconnect
on launch, crash restart, sleep/network restart, log panel, error mapping, LAN
and credentials, subscription auto-update.
*Done when:* killing the core process externally recovers within seconds; a
busy port produces the specific error and the one-click fix works.

**M6 — Updaters, polish, release.** Core updater with fallback discovery and
revert, pack auto-update, app update check, glass transitions, QR popover,
empty states, VoiceOver labels, DMG script, README with install steps.
*Done when:* a clean Mac can install the DMG following the README and reach a
connected state.

---

## 18. To confirm during implementation

| Item | When |
|---|---|
| Exact text Xray prints when the port is taken (pre-check should make it rare) | M1 |
| `SMAppService.mainApp` registration works for an ad-hoc signed build. **Open (M5):** the Settings toggle calls `register()` and surfaces errors and the "requires approval" state, but I have not toggled it in a running GUI session. | M5 |
| ~~DoH-through-proxy DNS in Bypass mode adds acceptable first-connection latency; routing log shows the expected outbound per domain~~ **Done (M4):** a single DoH server cost ~4 s per domain on this network; two servers in parallel cost 0.8 s first lookup, 0.3 s after. Routing log confirmed. | M4 |
| Liquid Glass modifier signatures in the Xcode 27 SDK | M3 |
| `wireguard://` and `vmess://` base64-JSON field coverage against real provider output | M2 |
| Inbound-tag rewriting covers the custom configs real providers send. M4 covers socks/http/mixed/other inbounds with unit tests and one live run; real provider configs are still untested. | M4 |
| How common `allowInsecure` links are in practice, and whether offering `verifyPeerCertByName` as a remedy is worthwhile | After M2 |
