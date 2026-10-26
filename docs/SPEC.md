# v2mac — Implementation Spec (v1)

Status: agreed design, ready for implementation
Date: 2026-10-09
Target: macOS 26+, Apple Silicon, Swift 6 / SwiftUI, Xray-core v26.10.21

v2mac is a small, native macOS menu bar app that acts as a shell around
[Xray-core](https://github.com/XTLS/Xray-core). It imports subscription links,
shows their servers in groups, lets the user activate one, and serves the
connection as a local SOCKS5 + HTTP proxy. It does not reimplement any proxy
protocol. An optional TUN mode (section 9.5, added after v1) routes all traffic
on the Mac through the same connection.

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
| TUN / system-wide VPN | Excluded from v1; added later as TUN mode (section 9.5). |
| Setting the macOS system proxy | Added later as a switch (section 9.9). |
| QR import, file import, URL schemes | Added later: links from other apps, dropped files and QR pictures (section 12.3, Importing). |
| Editing a server | Not in v1; added later as the server editor (section 12.7). |
| Custom routing rules, rule-set manager | Custom rules came later (section 8.6); no remote rule-set manager. |
| Viewing outbound JSON / exporting generated config | Not selected. |
| Per-server usage history, speed text in the menu bar | Not selected. |
| Localisation | Added later: English, Persian, Simplified Chinese and Russian (section 13, Language). |
| Intel Macs, macOS 15 and earlier | arm64, macOS 26+ only. |
| Developer ID signing, notarization, Sparkle | Planned after v1. |
| Mux, global sniffing options | Outbounds are used as provided. TLS fragment, noise packets and DNS came later (section 8.4). |
| Auto-select fastest server, global hotkeys | Auto-selection is optional (9.7); hotkeys through Shortcuts actions (12.4). |

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
| 14 | Region bypass | Generic list of region packs: Iran, China, Russia; not enabled by default; downloaded on enable; auto-updatable. |
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
| 33 | TUN mode | Off by default. Apple-signed builds use an approved SMAppService daemon; ad-hoc builds use the macOS administrator dialog each session. No Network Extension. |

### 2.1 Defaults chosen by the author (not asked; change freely)

These were filled in to make the spec complete. Each is isolated enough to
change without affecting the rest.

1. **Port collision.** `10808` is also v2rayN's default. On the development
   Mac, v2rayN currently holds `10808` and another client holds `10809`. The app
   checks the port before starting and, if busy, shows an error with a one-click
   "Use <next free port>" action.
2. **`allowInsecure` links.** Xray v26.9.30 refuses to start with
   `allowInsecure: true`. The parser keeps the flag as a marker and attaches a
   warning to the server instead of rejecting it; the flag never reaches the core
   (section 8.5).
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
7. **Secrets.** Server and subscription secrets stay with the app data (owner-only
   directory). The local proxy password and WARP credentials use a local
   AES-GCM encrypted file by default; its random 256-bit key is stored beside it.
   Keychain storage is optional and off by default (section 13), because ad-hoc
   builds can trigger new access prompts after updates.
8. **Helper location.** The core lives in `Contents/Helpers/xray` rather than
   `Contents/Resources/core/`, which is the bundle location code signing expects
   for executables. Geo data stays in `Resources`.
9. **Subscription info.** When the provider sends `subscription-userinfo`, the
   group header shows used / total data and the expiry date.
10. **Latency defaults.** URL `https://www.wikipedia.org`, timeout
    8 s, 32 concurrent requests, 32 servers per throwaway core.

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
  names). `echConfigList` is a string. The hash is the SHA-256 of the leaf
  certificate's DER bytes (`xray tls hash --cert`). Checked 2026-10-10 against a
  self-signed server over TLS and Hysteria 2: the right pin connects, with any
  `serverName`; no pin fails with "unknown authority"; a wrong pin fails with
  "peer cert is unrecognized".
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
    var isStale: Bool                    // removed upstream but still active or a favorite
    var isFavorite: Bool
    var keptAfterRemoval: Bool           // a favorite the user chose to keep (6.6)
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
5. Else fail with "Unrecognised subscription format".

Before these steps, a Clash / Mihomo YAML body (a line starting `proxies:` or
`proxy-groups:`) is read with `MiniYAML` (no anchors or multi-line scalars), and
JSON whose `outbounds` use `type` instead of `protocol` is sing-box. Each of their
servers becomes a share link (`ForeignConfig`) and goes through `ShareLinkParser`;
kinds without a link form (TUIC, WireGuard, …) are skipped and counted.

A response that yields zero profiles is a failure, not an empty group.

### 6.4 Reconcile (in a `@ModelActor`)

Given the new ordered list for a group:

1. Index existing profiles by fingerprint (keeping duplicates in order).
2. For each new entry, in order: reuse the first unused existing profile with
   the same fingerprint (update `name`, `sortIndex`, `originalLink`, `warnings`,
   clear `isStale`; keep `id` and delay fields); otherwise insert a new one.
3. Existing profiles not reused are deleted, except the active one and the
   favorites (6.6), which are kept with `isStale = true`, sorted last and
   badged "Removed from subscription". The active one is deleted as soon as
   another server is activated, unless it is a favorite.
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

### 6.6 Favorites

Any server can be marked as a favorite, from the table's context menu or the
inspector ("Add to Favorites" / "Remove from Favorites"). The sidebar row
"Favorites" lists them across all groups; a star marks them in every list.

A favorite is never deleted by an update. When its subscription no longer
lists it, it stays in its group as a stale row:

- **Automatic update:** nothing else happens.
- **Manual update:** the main window shows a message, "N favorite servers are
  no longer in their subscriptions", with **Remove** and **Keep**. Remove
  deletes them (the active one only loses its star and goes when another
  server is activated). Keep sets `keptAfterRemoval`, and later updates do not
  ask about them again. Favorites that went missing in an automatic update are
  asked about at the next manual update of their group.

A stale favorite that comes back in a later update is an ordinary favorite
again. Removing the star from a stale favorite deletes it, unless it is the
active server. The store is told which profiles are favorites by the caller:
the flag is written on the main context.

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
| `ss://` | SIP002 (`base64(method:password)@host:port`, plain userinfo for 2022 ciphers) and legacy fully-base64 form. `plugin`: `v2ray-plugin` / `xray-plugin` become the `ws` (or `grpc`) transport with optional TLS, `obfs-local` / `simple-obfs` with `obfs=http` becomes the raw HTTP header; any other plugin or mode → skipped as unsupported. |
| `hysteria2://`, `hy2://` | `auth@host:port[,port-range]`, `sni`, `alpn`, `obfs`; multi-port authority as in libXray. `pinSHA256` (hex, colons allowed) → `tlsSettings.pinnedPeerCertSha256`; a malformed value → skipped. |
| `socks://`, `socks5://` | `base64(user:pass)@host:port` or plain userinfo. |
| `http://`, `https://` (as a server line) | `user:pass@host:port`; `https` implies TLS. Only recognised inside a subscription body. |
| `wireguard://privkey@host:port?publickey=&address=&mtu=&reserved=&presharedkey=#name` | Maps to the `wireguard` outbound (`secretKey`, `address`, `peers`, `mtu`, `reserved`). |

Rules that apply to all schemes:

- Name: URL fragment, percent-decoded; fallback `host:port`.
- IPv6 hosts in brackets; ports validated to 1–65535.
- `allowInsecure=1` / `insecure=1`: kept as `tlsSettings.allowInsecure: true` in
  the stored outbound (a marker for section 8.5, left out of the fingerprint) and
  a warning is added that points at the "Allow insecure servers" setting. No
  marker and no warning when the link also pins the certificate
  (`pcs`, Hysteria 2 `pinSHA256`): a pinned certificate is accepted whoever issued it.
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

With Allow LAN on, every `freedom` outbound (also in full configs) starts its
`finalRules` with a block of `127.0.0.0/8`, `0.0.0.0/32`, `::1/128` and `::/128`,
so another device cannot use the proxy to reach the API, the metrics or any
other service that listens only on this Mac. Freedom checks the address it
dials, so a domain that resolves to loopback is refused as well.

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
- **Rules only** — the user's rules as in Global, then a catch-all `network: "tcp,udp"`
  → `direct`: only traffic matching a Proxy rule reaches the server, plus the exit check's sources so it reports the server's country.

### 8.2 Custom profiles

Take the stored config and:

1. Replace `inbounds` with the single mixed inbound above.
2. Replace `log`; set `metrics`; ensure `stats: {}`; merge the two
   `policy.system.statsInbound*` flags.
   Remove `api`: its `listen` would open a control port for the core, possibly
   to the network.
3. In `routing.rules`, rewrite any `inboundTag` that named a removed
   `socks` / `http` / `mixed` inbound to `mixed-in`; drop rules that referenced
   only other removed inbounds.
4. Apply the app's mode and custom rules before the rewritten imported rules.
   Keep the imported outbounds in their original order, tagging the first proxy
   outbound if needed so app Proxy rules can name it. Append separate, uniquely
   tagged freedom and blackhole outbounds for app Direct and Block rules; never
   reuse an imported Direct outbound that may itself chain through a proxy.
   The imported rules and first outbound remain the fallback. Direct mode's
   catch-all wins before that fallback. The mode picker is available for both
   profile kinds. Preserve imported DNS; add mode DNS only when none is supplied.
   Latency probes omit the app plan and test the imported config as written.

### 8.3 Output

Written to `run/config.json` with mode `0600`, replaced atomically, deleted when
the core stops.

### 8.4 Connection settings

All off by default except live switching; each is a switch in Settings → Connection.

**TLS fragment and noise packets.** When either is on, the config gains

```json
{ "tag": "v2mac-dialer", "protocol": "freedom",
  "settings": { "fragment": { "packets": "tlshello", "length": "100-200", "interval": "10-20" },
                "noises": [ { "type": "rand", "packet": "10-20", "delay": "10-16" } ] } }
```

(`fragment` and `noises` each only while its switch is on; `packets` is `tlshello` or `1-3`) and
the proxy outbound gets `streamSettings.sockopt.dialerProxy: "v2mac-dialer"`. Left alone: outbounds
that already name a `dialerProxy` or `proxySettings.tag`, servers on loopback, and `freedom`,
`blackhole`, `dns`, `loopback` and `wireguard` outbounds. In a custom config the same is applied to
every eligible outbound and the helper is appended only if one of them uses it. In TUN mode the
helper is bound to the physical interface, because it is the one that dials. Latency and speed
tests use the same settings. A range that is not `N` or `N-M` falls back to the default.
Fragmenting helps on some networks and stops TLS handshakes on others, hence off by default.

**Find Settings…** (`FragmentTuner`, under the fragment switch) tries eight
candidates against the active server: no fragment, four `tlshello` and three `1-3`
settings, each through its own throwaway core (`RealDelayTester` with that dialer,
the user's noise and timeout), two at a time and twice; a candidate that fails a
round is dropped. The fastest that answered both rounds is offered, or no fragment
when that answered within 20% of it. "Use These Settings" writes the fragment
switch and values, which restarts a running core like any change here.
shortcut: one result for all networks; a per-network memory would need the Wi-Fi's identity.

**DNS.** When on, the config's `dns` is `{"servers": [...], "queryStrategy": "UseIP" | "UseIPv4" |
"UseIPv6", "enableParallelQuery": true}` with the user's servers (default: the two DoH servers of
the bypass mode, which it then replaces), and the `direct` outbound gets
`settings.domainStrategy` set to the same strategy so direct traffic is resolved there too.
Traffic through the server is still resolved by the server. A custom config that has a `dns`
section keeps it; one without gets this one.

**Outgoing network.** A picker, not a switch: Automatic (the default) or one of the networks
that can carry traffic now (`NetworkInterfaces.outgoing`: up, running, with an address that is not
link-local; the default one first, the app's own TUN left out). Each is shown as its kind in the
app's language with its BSD name, then the hardware's name and addresses ("Ethernet (en7) · USB
10/100/1000 LAN · 10.0.0.5"). A chosen network is stored by BSD name (`outboundInterface`) and bound
like the physical interface in TUN mode (`streamSettings.sockopt.interface` on every outbound that
dials out, `RunOptions.outboundInterface`); in TUN mode it replaces the default network, and the
core asks that network's own resolvers for the server's name. Delay, speed and TCP tests use it too.
Picking one restarts a running core. When the chosen network is no longer connected, at connect
time or on a network change, the setting goes back to Automatic, a running core restarts on the
default network and the "Chosen network disconnected" notification says so.

**Switching without a restart.** When on, configs for outbound profiles gain
`"api": {"tag": "api", "listen": "127.0.0.1:<free port>", "services": ["HandlerService"]}`.
Activating another outbound profile while connected, with every other setting unchanged, runs
`xray api rmo --server=127.0.0.1:<port> proxy` and then `xray api ado ... <file>` with the new
outbound (tagged, dialled and bound as above). The core, its ports and the traffic counters stay;
connections already open finish on the old server. If either command fails the core is restarted
as before. Custom configs, any switch while TUN mode is on (section 9.5, DNS), and any change of
port, mode, TUN, log or the settings above, always restart. The API port is loopback-only and unauthenticated, like the metrics port.

### 8.5 Servers that ask for `allowInsecure`

Xray has no way left to skip the certificate check, only to pin a certificate.
`InsecureTLS` (package) handles outbounds that carry the marker:

- **Setting off (default):** the marker is removed and the certificate is checked
  normally, so a self-signed server fails with "unknown authority".
- **Setting on ("Allow insecure servers"):** before connecting, switching live or
  testing delay, the app opens a TLS (or QUIC, for Hysteria 2 and `alpn: h3`)
  handshake to the server's address with the outbound's `serverName` and ALPN,
  reads the leaf certificate, refuses the handshake, and sets
  `pinnedPeerCertSha256` to its SHA-256. Nothing is stored: the pin is taken
  again on every connect, which is what the flag means (accept whatever the
  server shows). If the server cannot be asked, the marker is only removed.

`ConfigBuilder.proxyOutbound` and the latency config remove the marker in every
case, so it cannot reach the core. Limits: the extra handshake comes from the
system TLS stack and does not go through the TLS fragment dialer; Hysteria 2
with Salamander obfuscation cannot be asked; full Xray configs are not touched.
Checked 2026-10-10 in the Debug app against a local self-signed Trojan and
Hysteria 2 server: both connect with the setting on, Trojan fails with it off.

---

### 8.6 Rules

One ordered list (`Rule`, stored as `{"version":2,"rules":[…]}` under `rules`),
edited in the Rules window. Rules are checked top to bottom and the first match
wins. Each rule has a name, an on/off switch, an action and items:

- **Action:** Proxy (the connected server), **Via** a chosen server or a group's
  fastest live server, Direct or Block.
- **Items** are OR: apps, domains (and subdomains), exact names, keywords,
  regular expressions, IP addresses and ranges, countries and service lists
  (`geosite:`/`geoip:`). A rule matches when any item does.
- **Only when** is AND with every item: ports (`443`, `8000-8100`), TCP or UDP,
  sniffed protocol (TLS, HTTP, QUIC, BitTorrent) and apps. A rule with no items
  matches all traffic that meets its conditions.

`Rule.xrayRules` turns one rule into adjacent Xray rules (process, domain, ip)
that each carry the conditions, all with `ruleTag` `rule-<uuid>-<part>`, so the
access log and `RuleTester` can name the rule. Invalid ports, or "Only when" apps
that match nothing installed, leave the rule out. A country item gives
`geoip:<cc>`, `domain:<tld>` (`uk` for GB) and the site lists the files have.

**Migration.** The 1.1 list (`customRuleList`, `CustomRule`) is read once into
v2: hosts become items; apps become items, or "Only when" apps when the rule
also had hosts (a 1.1 rule with both needed both). The old key is never written,
so 1.1 still finds its rules after a downgrade. Rule profiles move the same way
to `ruleProfilesV2`. Backups carry both keys.

**Via** (`Via.swift`). Each Via target gets its own outbounds: a server's
outbound (with its own dialer chain), or one per live member of a group plus an
Xray balancer `via-g<n>` with `leastPing` and an observatory probing every 30 s.
Every balancer has a `fallbackTag`, because without one Xray sends an all-dead
balancer's traffic to the first outbound. "If its servers fail, use the current
server" sets it to `proxy`; off (the default) it is `block`, so the traffic
fails closed. A target no longer on this Mac blocks (or uses Proxy when falling
back). The kill switch allows the Via servers' addresses. `StatsClient` reads
the observatory; when a target's members all fail the rule shows a warning and
the menu bar panel says so.

Hosts are one entry per line (commas, spaces and `;` also separate entries;
`#`, `//` and `!` start a comment). `RuleMatchers` turns them into Xray
`domain` and `ip` entries:

- Xray notation as written: `domain:`, `full:`, `keyword:`, `regexp:`,
  `geosite:`, `geoip:`, `ext:<file>:<tag>` (a file whose name contains "ip" is
  an IP list).
- IP addresses and CIDR ranges, v4 and v6, and Proxifier ranges `a-b`, turned
  into the fewest CIDR blocks.
- Proxifier keywords `*word*` → `keyword:word`.
- Plain domains with at least one dot, and `*.`, `+.`, `.` wildcards →
  `domain:<name>` (the domain and its subdomains). A lone word is skipped.
- Clash rules `DOMAIN`, `DOMAIN-SUFFIX`, `DOMAIN-KEYWORD`, `DOMAIN-REGEX`,
  `IP-CIDR`, `IP-CIDR6`, `GEOIP`, `GEOSITE`, also as `- ` payload lines; the
  policy column is ignored, the list decides.
- hosts lines (`0.0.0.0 a.example b.example` → `full:`) and Adblock `||name^`.

Anything else is skipped and named under the editor.

Apps (`AppMatchers`) become an Xray `process` field, which matches process
names, absolute paths, and path prefixes ending in `/`. A full path is kept (an
`.app` path becomes its folder, so helpers match too); a lone word is a process
name, plus the folder of `<word>.app` when installed; `Name.app`, a bundle id
and `*word*` (name or bundle id) are looked up at connect time among the apps
in `/Applications`, `/System/Applications`, `/System/Library/CoreServices`,
`~/Applications` and the running apps (`InstalledApps`). A bundle id with no
installed app is kept as a process name; a rule whose apps all match nothing is
left out. App rules see the app only for connections that reach the core
directly (system proxy or app settings); in TUN mode the core sees the root
forwarder (9.5). TUN config generation excludes `tun-in` from process rules,
including imported JSON rules, before Xray attempts process lookup. Rules without
inbound tags (or with an empty tag list) are restricted to `mixed-in`; rules
targeting only `tun-in` are omitted. Host/IP-only rules remain available to TUN.

Local names (`localhost`, `.local`, `.test`, `.internal`, `.lan`, `.home.arpa`,
dotless names) always go direct, ahead of the rules. **Block QUIC (UDP 443)**
(`blockQUIC`, off by default) adds a first rule sending UDP 443 to Block, so
browsers fall back to TCP and their host names reach the rules.

Local names and private addresses always go direct, ahead of the rules
(built-in "Local network"). **Block QUIC (UDP 443)** (`blockQUIC`, off by default)
adds a first rule sending UDP 443 to Block, so browsers fall back to TCP and their
host names reach the rules.

**Import Rules…** reads the file with `RuleImport`, which tells the formats apart:
Proxifier (below); Clash / Mihomo `rules:` and Shadowrocket / Surge `[Rule]` lines
(`TYPE,value,POLICY`: `DIRECT` → Direct, `REJECT*` → Block, any other policy →
Proxy; neighbouring lines with the same policy become one rule named after it;
`MATCH`/`FINAL` is left to the routing mode; `DST-PORT` and `NETWORK` lines and `AND`
of plain conditions become "Only when"; `RULE-SET`, `OR` and `NOT` are skipped and listed); sing-box `route.rules` (domain, suffix, keyword, regex, CIDR,
geosite, geoip, process fields; port, port_range, network and protocol become "Only when"; the outbound's type gives the action, `reject`
blocks; rule sets skipped); Xray / v2rayN / v2rayNG rule JSON (`outboundTag`
`direct`, `block` or anything else → Proxy, with `remarks` and `enabled` kept).

A Proxifier `.ppx` file (`ProxifierProfile`): each
rule to a proxy on 127.0.0.1 or localhost becomes a Proxy rule, Direct and
Block rules keep their action, `enabled` is kept, `<Ports>` becomes "Only when" ports, rules to other proxies or
chains are skipped and named, the default rule is left to the routing mode,
`ExclusionList` becomes a Direct rule at the top and `BlockUDP443` turns on
Block QUIC. Imported rules are a draft until Apply. Export writes the v2 JSON, which Import reads back.

The rules come before the mode's own rules. In Global mode, IP
entries switch `domainStrategy` to `IPOnDemand` with the DoH `dns` section of
Bypass mode, so later domain rules or a catch-all cannot preempt an IP rule.
Direct mode uses only Block rules. Full configs (8.2) use app routing first,
then their imported routing as fallback. IP-based app modes use `IPOnDemand`
ahead of that fallback. Apply restarts a running core; a live switch keeps the core only
when the rules are unchanged.

With System Proxy off, the mixed proxy inbound goes to `proxy` (or `direct`,
per Settings → Proxy → Apps using the proxy port; "Follow rules" turns this off)
before custom and region rules in Global and Bypass modes (`proxyClientsRoute`). Local
names and private addresses still go direct first, and Block QUIC stays first
when enabled. Direct mode keeps its Block rules and direct catch-all. With
System Proxy on, the exception is disabled: manual and system proxy traffic
share the inbound and cannot be distinguished. Changing System Proxy restarts
the running core to apply this policy. This also applies to full configs.

"Traffic that matches no rule" (Settings → Routing, `unmatchedRoute`) can send
everything no rule matched to Proxy, Direct or Block with one catch-all after
the custom and region rules, replacing the mode's own default and a full
config's imported fallback. "Follow mode" leaves them as they are; Direct mode
ignores the setting.

The rules come before the mode's own rules. In Global mode, IP
entries switch `domainStrategy` to `IPOnDemand` with the DoH `dns` section of
Bypass mode, so later domain rules or a catch-all cannot preempt an IP rule.
Direct mode uses only Block rules. Full configs (8.2) use app routing first,
then their imported routing as fallback, with Via outbounds and balancers added
and the config's own observatory merged. Apply restarts a running core.

With System Proxy off, the mixed proxy inbound goes to `proxy` (or `direct`,
per Settings → Proxy → Apps using the proxy port; "Follow rules" turns this off)
before custom and region rules in Global and Bypass modes (`proxyClientsRoute`).
With System Proxy on this is disabled: manual and system proxy traffic share the
inbound and cannot be told apart.

"Everything else" (`unmatchedRoute`) can send everything no rule matched to
Proxy, Direct or Block with one catch-all after the custom and region rules,
replacing the mode's own default and a full config's imported fallback. "Follow
mode" leaves them as they are; Direct mode ignores it.

**Rules window** (`rules`, `RulesWindow`), opened from the sidebar's glass
button, Settings → Routing ("Open Rules…"), the Connections window and the menu
bar. Notifications from 1.1 that name `rule-editor` or `rule-builder` open it.

- Sidebar: built-ins before the rules (Local network, Block QUIC, Apps using the
  proxy port), the user's rules (drag to reorder, switch, warnings badge), then
  the routing mode and Everything else, and Discovered. A filter by action.
- Search filters the list and answers where a host, URL, address or app goes:
  `RuleTester` follows the compiled routing (domainStrategy included, geo lists
  read from the files with `GeoLists`) and names the rule, built-in or mode, and
  the item that matched.
- Detail: name, switch, action menu (Proxy · Via ▸ group ▸ fastest or a server ·
  Direct · Block), the fallback switch and live server count for Via, one smart
  field for every item kind (installed apps, services with entry counts,
  countries, the text as its detected kind; pasted lines in any import format;
  on-device "Suggest domains" when Apple Intelligence is available), tokens
  grouped by kind with a menu to read a domain as exact/keyword/regex, an app
  token's popover listing what it matches on this Mac, Browse (app checklist,
  service tiles, country map) and "Only when".
- Discovered: apps and hosts seen while this window or Connections is open that
  no rule or built-in covers, a host offered as its registered domain. "Add to"
  (recent rules first), New Rule, Ignore (`ignoredDiscoveries`), and drag onto a
  rule.
- Edits are a draft with undo; Apply (⌘S) saves and restarts a running core
  once; closing with changes asks to Apply, Cancel or Discard.
- New Rule menu: empty, or a template (AI services, developer tools, Apple
  services, social, streaming, region sites direct, torrents direct, ads), each
  using only lists the installed files have.
- Profiles: named rule lists; switching needs no unapplied changes. New,
  Duplicate, Rename, Delete (not the last).
- Tidy Up (`TidyUp`): merge an app-only and a host-only rule with the same
  action into one, drop rules an earlier rule fully covers, collapse spellings
  of one app, drop repeated or local-network entries. Each is a checkbox; only
  collapsing spellings can change what matches, and the sheet says so.

The Connections window's row menu offers Add App/Host to Rule ▸ and Show Rule
(the tester names the rule from the rules the connection opened under). The
menu bar panel shows the frontmost app, where it goes and Add to Rule. The
Shortcuts action "Add to Rule" adds items to a saved rule and applies it.

## 9. Core process management

### 9.1 Locating the core

### 8.7 Command line tool

V2Mac embeds a signed `v2mac` executable in `Contents/Helpers`. Settings → About can link it at
`/usr/local/bin/v2mac`; it never replaces an unrelated file or link. Homebrew installs that same binary.

`version`, `status`, `connect` and idempotent `disconnect` control the app. `rules` exposes list/show,
CRUD and ordering, items, targets, testing, validation, v2 export/atomic apply, reviewed foreign import,
Tidy Up, templates, profiles and the editable Block QUIC/Everything Else built-ins. UUIDs and exact unique
names identify rules and profiles. `--profile` edits an inactive profile without switching it.

Every write needs the SHA-256 `revision` returned by reads. The revision covers canonical saved rules,
profiles, the active profile and editable built-ins. Stale writes and active-profile writes while the Rules
window has a draft fail without changes. `--dry-run` validates and returns the proposed difference without
saving or reconnecting. Active rule/profile/built-in changes reconnect a running core once; inactive-profile
changes do not. The app validates the complete proposed state and accepts app/process tokens even when the
program is not installed.

The CLI uses an anonymous NSXPC endpoint stored mode 0600 in the private Application Support folder.
Production and debug endpoints differ. The app accepts only its embedded executable at its resolved bundle
path with the expected signature and exact binary hash; the CLI verifies the containing app hash. A rules
command cold-launches the app without a window or connection and waits at most ten seconds. `status` does not
launch it. `--json` is a stable v1 envelope (`apiVersion`, `ok`, `command`, `revision`, `data`, `warnings`,
`error`); failures use `sysexits` categories.

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

### 9.5 TUN mode

**Asking for access.** TUN mode defaults off and keeps its choice across launches
(`tunEnabled`). The active server and previous running state are restored too;
with Reconnect on launch enabled, a previously running connection resumes with
the saved TUN setting. The system proxy starts off (`Prefs.registerDefaults`
clears `systemProxy`); the kill switch keeps its setting. Apple-signed builds use
`SMAppService.daemon`: a cancellable notice precedes registration, followed by
approval in System Settings → General → Login Items & Extensions. Approval is
retained across launches. Ad-hoc builds retain the macOS administrator dialog;
`AdminConsent` explains it first, links to the source, and offers Not Now and
"Don't show this again" (`adminConsentShown`). Neither path collects a password.

Off by default. A switch in the connection bar and in the menu bar panel turns
it on; the choice is remembered (`tunEnabled`). Changing it while connected
restarts the core.

**Two processes.** The core keeps running as the user. A second Xray, the
*forwarder*, runs as root with a fixed config: one `tun` inbound
(`autoSystemRoutingTable` for `0.0.0.0/0` and `::/0`, `autoOutboundsInterface:
auto`, sniffing that overrides the destination) and a SOCKS outbound to a
loopback port of the core, bound to `lo0`: left to `autoOutboundsInterface` it is bound
to the physical interface, where UDP to loopback is dropped. The forwarder always runs the bundled
Xray, never an in-app core update: Xray 26.10.17 lost all UDP in the TUN inbound. The
integration test `forwarderCarriesUDPAndTCPThroughARealTun` runs the forwarder as root
(CI has password-free `sudo`; it is skipped elsewhere) with routes for TEST-NET-1 only and
sends a DNS query and an HTTP request through the real TUN; it fails on 26.10.17, so a core
pin must pass it. Server and subscription configs never run as root.

**Core side.** While TUN mode is on the core config gets a second inbound,
`tun-in` (SOCKS, `127.0.0.1`, no auth, UDP on, port fixed for the session), and
every outbound that dials out is bound to the physical interface (the
outgoing network of section 8.4 when one is chosen) with
`streamSettings.sockopt.interface`, so the core's own connections do not
re-enter the TUN. Outbounds that already name an interface, that target this
Mac, or that never dial (`blackhole`, `dns`, `loopback`) are left alone. Rules
of a custom profile that named its proxy inbounds also apply to `tun-in`.
Traffic counters are the sum of `mixed-in` and `tun-in`.

**Managed root helper.** `V2MacPrivilegedHelper` is embedded at
`Contents/Library/HelperTools/`, with its launchd plist in
`Contents/Library/LaunchDaemons/`. The Mach service and plist label are the app's
bundle identifier plus `.privileged`; Debug has its own identifier and files.
`SMAppService` launches it on demand after macOS approval. Its XPC listener and
the app's XPC connection enforce the exact peer identifier and the same Apple
certificate Team ID on every message; Release also rejects debugging entitlements.
No caller-supplied command, executable path, configuration JSON, UID or PID is accepted.
The UID and PID come from the authenticated connection; the PID is used only for
session lifetime, never for code-signing authorization.

The daemon accepts only validated ports, `utun100`–`utun65535` names, booleans,
and at most 4096 literal IP addresses in a bounded message. It builds the fixed
forwarder and firewall configuration itself. It copies the bundled Xray into a
root-owned 0700 staging directory, rejects symlinks, enforces root ownership and
checks the copy's signature against the same publisher and the app's `.xray`
identifier before hashing or executing it. In-app downloaded cores remain
unprivileged; managed root sessions always use the signed bundled core.

The app sends snapshots of controller state held in memory over authenticated XPC;
it never imports privilege requests from user-writable files in the managed path.
The daemon writes them to its own root-owned request directory; root never
reads or writes the app's mutable run directory. A heartbeat propagates changes
and detects transport or firewall failures. Only one managed session per app flavor
may run at a time, avoiding conflicting system proxy or firewall updates between users.

**Shared session implementation.** Both the daemon and ad-hoc fallback run the existing
shell helper. The fallback uses `osascript` ("with administrator privileges") and one
macOS password dialog per app session, preserving support for unsigned releases.
The shell helper:

- is passed inline (`sh -c`), together with the fixed forwarder config's JSON, so no
  script or config file that a process without root could change is run;
- copies the core binary to `/var/run/v2mac-tun-<uid>/` (root-owned), checks
  its SHA-256 against the daemon's verified root copy (the app's pre-prompt hash in the fallback), writes the
  config next to it, and only ever runs those copies;
- takes its orders from two flag files: `tun.session` (stay alive) and
  `tun.on` (forwarder up). They carry no data, so a process without root can
  only switch the TUN on or off, not change what runs as root;
- stops the forwarder and exits when the app's process is gone or `tun.session`
  is removed. Routes belong to the `utun` interface and vanish with it, also
  after a crash. Managed-helper approval survives a reboot; live network requests do not.
  Explicit stop and unregister clear the TUN, proxy and firewall requests before shutdown.
  Loss of the XPC client stops its session while preserving an armed kill switch;
  an idle daemon exits and is relaunched on demand for the next signed app session.

**Lifecycle.** The TUN is up while the core is connecting, switching or
connected, and comes down on disconnect, on a core that stays failed, and on
quit. Settings → Connection → "If TUN fails" chooses between keeping the local
proxy (default) and stopping the connection. This applies to cancelled administrator
access, preparation/start failure, and loss of the helper/forwarder. The requested
TUN setting remains enabled, so a later reconnect can retry. "Stop connection"
invalidates pending automatic selection and connect operations, stops the local
core, and clears reconnect-on-launch intent. Status distinguishes "Local proxy
connected", "System tunnel active", and an unavailable/starting tunnel. A
network change always restarts the core in TUN mode, because the binding names
one interface; the app's own `utun` is not counted as a network change.

**DNS.** Every lookup goes through the tunnel too. Three parts:

- *Forwarder:* it has one outbound, the core. Port 53 is not an exception.
- *Core* (`ConfigBuilder.tunDNS`): the first rules send `tun-in` traffic on port 53,
  whatever resolver it was addressed to, to a `dns` outbound (`v2mac-dns-out`). A and AAAA
  queries go to the core's resolver; other types get an empty answer. The resolver asks
  the configured servers (custom DNS, the mode's DoH pair, a full config's own, or else
  the DoH pair) through the routing, so through the proxy. `localhost` servers are
  dropped: the system resolver is the TUN, so they would ask themselves.
- *Server names:* the core cannot use the system resolver for its own server, because
  that lookup would come back through the TUN and wait for the server. Outbounds that dial
  a name, and freedom outbounds others dial through, get `sockopt.domainStrategy:
  UseIPv4v6`. The resolver asks the network's resolvers (`State:/Network/Global/DNS`, read
  at connect; 1.1.1.1 and 8.8.8.8 when there are none) for exactly those names
  (`full:`, `skipFallback`), through a freedom outbound bound to the physical interface.
  A server switch restarts the core in TUN mode, since that list is part of the config.
- *System resolver:* a resolver on the local network (the usual router) is reached
  without the TUN. While the forwarder runs, the root helper therefore sets the primary
  service's `ServerAddresses` to `1.1.1.1 8.8.8.8` in `Setup:/Network/Service/<id>/DNS`,
  in the dynamic store only. It checks again every 3 seconds (service or setting
  changed). When the forwarder stops and when the session ends it copies the value of the
  saved network settings (`scutil --prefs`) back, or removes the key when they have none.
  The saved settings are never written, so a reboot or a change in System Settings drops
  the change too. A helper killed before it can undo it leaves public resolvers that
  still answer, and the next session's restore puts the saved value back.

`Scripts/check-tun.sh` checks a running tunnel: routes, resolvers, and a capture on the
physical interface while lookups and connections run.

**Protection contract.** Neither TUN failure policy is a kill switch. Removing a TUN
interface removes its routes; direct traffic may resume during a failure or after the
app/helper crashes. "Stop connection" prevents the app from continuing with only a local
proxy, but cannot block other apps' direct traffic. The kill switch (section 9.8) does.

**One session, three uses.** The same root helper also sets the system proxy (9.9) and
holds the kill switch (9.8); whichever needs it first starts it. Signed builds reuse
managed-helper approval; ad-hoc builds use one administrator prompt per app session.
macOS handles all approval and password dialogs;
V2Mac never receives, stores or supplies it. There is no administrator-account form
in Settings. The helper's
folder is named after the data folder (`/var/run/v2mac-dev-tun-<uid>` for the
development build), so the two apps never share one.

**Known limits.** "Without proxy" downloads (subscriptions, updates) still go
through the tunnel while it is up. Latency tests are bound to the physical
interface so they keep measuring the servers. The local network stays local
(more specific routes), and a program that binds its own sockets to the
physical interface, as some system services do, is not captured.

### 9.6 Exit check

Each time the core reaches `running`, and after a live switch, `ConnectionController.checkExit`
asks a public service through the local proxy where traffic comes out (`ExitLookup`, package):
`https://ipwho.is/`, then `https://ipinfo.io/json`, then `https://www.cloudflare.com/cdn-cgi/trace`
(country only), the first that answers. Up to three rounds, 2 s apart. The services see the
server's address, not the user's; in Direct mode the check is skipped, because there the answer
would be the user's own address.

- **Answer:** the connection bar's status line becomes flag, city, country and address; the menu
  bar panel shows the same with a copy button; the menu bar icon gets the two-letter country code
  in a green capsule over its lower edge (`MenuBarBadge`).
- **No answer from any source:** the core is running but traffic is not passing. The bar and the
  panel say "No answer through this server" and the log records it.
- Settings → Connection: "Show where traffic comes out" (on) and "Country badge on the menu bar
  icon" (on). Nothing is stored; the result is dropped when the core stops.

The badge has a colour, so the menu bar image cannot be a template image. It is one `NSImage`
whose drawing handler picks a black or a white glyph from the appearance it is drawn in.
Checked 2026-10-10 on a dark menu bar; a light one was not available to check.

### 9.7 Optional automatic server selection

Settings → Connection → "Automatically select a working server" defaults to off.
When enabled, connecting/reconnecting tests non-stale candidates in the active
profile's group with `RealDelayTester`. Only fresh successful HTTP responses
qualify; TCP ping and saved row delays never influence selection. An initial
connection chooses the lowest real delay. Direct routing skips automation for
both outbound and full custom profiles.

Every 30 seconds a request through the actual running SOCKS proxy (including its
credentials) checks the configured latency URL. No direct retry is allowed.
Two consecutive failures trigger a fresh group test and ordered fallback to the
first responding peer in group order. Exhausted core crash recovery also tries
fallback. If no peer responds, show a failure and retry while the user still
wants a connection; port conflicts retain their explicit user fix.

Automatic switches have a 60-second cooldown. A failed node is excluded for
120 seconds. Every 180 seconds, fresh group tests can choose a faster node only
if it improves delay by at least 100 ms and 25%; these tests are skipped in
Low Power Mode, where only a failing or slow server switches. A manual activation pins the
chosen server until its health fails, or automation is reset/disconnected.
Disabling automation, disconnecting, quitting or activating another server
cancels outstanding tests and invalidates late connect results. Automatic tests
use physical-interface binding while TUN is up, and save real-delay row results
without triggering manual-test notifications. Existing flows may be interrupted
by switching; automatic selection does not promise session migration.

**Conditions.** Two more reasons to switch, each off by default and used only with
automatic selection on (Settings → Connection → "Switch conditions"):

- *Delay is high*: two health checks in a row answer slower than the limit (default
  1000 ms). Failed checks neither count nor reset; they have their own rule.
- *Download is slow*: in the last N minutes (default 2) the live download rate never
  reached the floor (default 100 KB/s), and at least a quarter of those seconds carried
  traffic (1 KB/s or more), so an idle connection never counts (`SlowSpeedWatch`).

A met condition tests the group and takes the fastest other server that answers
(`AutoSelectionPolicy.Reason.degraded`), a manually chosen one included. It honours the
switch cooldown and excludes the server it leaves for the failure cooldown. When nothing
else answers the connection stays as it is, and the condition has to be met again from
the start.

The test URL must be HTTP(S) with a public destination; local/private literals,
IPv6 literals and embedded credentials are rejected to avoid URLSession's SOCKS
bypass. The first 2xx/3xx response headers count as a response; redirects are not
followed, so a redirect cannot turn a local direct request into a health result.

### 9.8 Kill switch

Settings → Connection → "Kill switch", off by default. While it is on and a
connection is wanted, this Mac can reach only the connection: everything else that
leaves is refused, also while the core restarts, after it failed and when V2Mac
stops unexpectedly.

**Rules.** The root helper (9.5) loads them into the pf anchor `com.apple/<data folder
name>`; the system's own `/etc/pf.conf` evaluates every anchor under `com.apple`, so
the main ruleset is not touched. Before loading, the helper checks that the main
ruleset still has `anchor "com.apple/*"` and refuses otherwise. It enables pf with a
token of its own (`pfctl -E`) and keeps the token in a marker file,
`/var/run/<name>-killswitch-<uid>`, outside its own folder. The rules
(`KillSwitch.rules`), all stateless (nothing inbound is filtered, so replies need no
state and connections open before the block keep working):

- pass loopback, and everything out on the session's `utun`;
- pass DHCP (v4 and v6), name lookups (port 53, TCP and UDP), the local network
  (private, link-local and multicast ranges, v4 and v6);
- pass the table `v2mac_allow`;
- `block return out quick all`.

**Allowed servers.** Before each connect and switch the app resolves the server
addresses the core dials (every outbound's, for a full config) and writes the
addresses to `run/killswitch.allow`; latency, speed and TCP tests and automatic
selection add the servers they test. The list only grows during a session. The
helper copies only lines that look like an address into a root-only file and replaces
the table with it. A server behind a CDN may answer the core with an address the app
did not see; that connection is then refused, not leaked.

**Lifetime.** The app writes `run/killswitch.on` before the session starts; the helper
arms and writes the marker, or writes `killswitch.error`, removes the flag, and the
connect stops with "The kill switch could not be turned on … V2Mac did not connect".
Disconnecting, turning the setting off and quitting remove the flag: the helper
flushes the anchor's rules and tables (never `-F all`, which would clear pf's states
for everyone) and releases its token. A helper that ends because the app died with
the flag in place leaves the block up. On the next launch the marker without a helper
shows "Kill switch is blocking all traffic" with "Allow Traffic", which starts a helper
without the flag, and that helper lifts the block; connecting again replaces it with a
new one. Nothing survives a reboot.

**What it means for routing.** Direct mode, bypassed regions and "without proxy"
downloads cannot reach the internet while the block is up. Name lookups and the local
network stay reachable, so a network can still see which names are looked up.

### 9.9 System proxy

A switch in the connection bar ("Proxy"), the menu bar panel ("System Proxy") and
Settings → Proxy, off by default. While it is on and the core runs, the root helper
(9.5) points the web, secure web and SOCKS proxies of every enabled network service
that has a device (Wi-Fi, Ethernet, …; VPN services are left alone) at
`127.0.0.1:<port>` with `networksetup`, with local addresses and `*.local` bypassed.
The app asks for it by writing the port to `run/proxy.on`; the helper reads it with
shell builtins on each turn of its loop and takes only a port between 1024 and 65535.
Disconnecting, turning the switch off, quitting and a helper that ends turn the three
proxies off again. With credentials set (section 13) apps must send them too; browsers
ask once.

Beside each switch a dot shows where the system's settings point now
(`SCDynamicStoreCopyProxies`, read every two seconds while it is on screen): green when
every enabled proxy is this app's port, red for anything else (another address or port,
automatic configuration), grey when none is set.

### 9.10 Cloudflare WARP

Settings → WARP registers a Cloudflare WARP device for MASQUE (`WarpClient`). The calls are
the ones the WARP apps make to `api.cloudflareclient.com/v0a4471`; Cloudflare does not document
them, so they follow the open-source clients (wgcf, usque):

| Step | Call |
|---|---|
| Register | `POST /reg` with a random placeholder WireGuard key; returns the device ID and token |
| Switch to MASQUE | `PATCH /reg/<id>` with a new ECDSA P-256 public key (`key_type` `secp256r1`, `tunnel_type` `masque`); returns the endpoint's public key, its addresses and the tunnel addresses |
| Account | `GET /reg/<id>/account`: type, WARP+ data, the account's license key |
| WARP+ | `PUT /reg/<id>/account` with `{"license": …}` joins the device to that account |
| Remove | `DELETE /reg/<id>`; the device is forgotten on this Mac even when this fails |

Requests go through the local proxy while the core runs and direct otherwise, since the API is
often blocked where the app is needed. Registering accepts Cloudflare's terms, which the button's
note links to. The device (keys, token, endpoint, account) is kept in the selected secret store as JSON.
Cloudflare's `warp_plus` flag is true on free accounts too, so the plan comes from
`account_type` alone: `free`, `limited` (WARP+ with a data allowance), `unlimited`, `team`.

The device becomes Xray's `masque` outbound: `settings.address` the endpoint (IPv4 first), port
443, `streamSettings.network` `masque` with `security` `tls`, SNI
`consumer-masque.cloudflareclient.com`, and `masqueSettings.warp` with the device's private key,
the endpoint's public key (Xray pins it) and the tunnel addresses. It is used in two ways:

- **Add WARP to Servers** puts it in Custom Configs as its own server ("Cloudflare WARP" or
  "Cloudflare WARP+"), which connects directly. It is a copy: removing the device leaves it.
- **Send traffic out through WARP** (`warpExit`, off by default) makes WARP the exit behind the
  active share-link server: `ConfigBuilder` tags the server `warp-upstream` and adds the WARP
  outbound as `proxy` with `sockopt.dialerProxy` set to it, so routing and custom rules are
  unchanged. A live switch replaces `warp-upstream` (`ConfigBuilder.serverTag`). Full Xray
  configs retain their own outbound chains (with app routing ahead of imported routing).
  Changing the switch, or the device while it is on, restarts the core.

Some servers refuse WARP: one checked on 2026-10-16 reset every TLS connection whose SNI was
under `cloudflareclient.com`, so traffic through WARP never started.

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
4. With 32 concurrent requests, send `GET <test URL>` through each port using an
   ephemeral `URLSession` with `ProxyConfiguration(socksv5Proxy:)`, timeout 8 s.
   A first request opens the connection; the time to response headers of a second one on the same session is the delay. Any error or non-2xx/3xx →
   `timeout`.
5. Stop the throwaway core; write results in one batch.

`custom` profiles are tested one per throwaway core, using the transformation
from 8.2 with a temporary port.

The live connection is never touched. Cancelling stops outstanding requests and
kills the throwaway core.

Tests run one request at a time. A test asked for while another runs (from the
menu bar, the toolbar, a context menu or the inspector) is queued after it rather
than replacing it; a server already waiting for that kind of result is not queued
twice. Stop cancels the running test and everything queued.

### 10.2 TCP ping (secondary)

`NWConnection` TCP connect to `address:port`, 3 s timeout, 32 concurrent. Shown
as "n/a" for UDP-based servers (`hysteria`, `wireguard`, `kcp`) and for custom
profiles.

### 10.3 Presentation

The Delay column shows the latest result of either kind: green under 300 ms,
amber under 800 ms, red above, "timeout", "invalid", or a spinner. Sorting by
Delay puts untested and failed rows last.

During a speed test the Speed column shows a spinner while the server waits its
turn, "Connecting…" once its download starts, then the current speed (latest
one-second window) a few times a second in a fixed format and width, without
animation, until the top stable speed replaces it.

---

### 10.4 Clean IP scan

**Find Clean IP…** in a server's context menu, for share-link servers that the CDN can
carry: VLESS, VMess or Trojan over `ws`, `grpc`, `xhttp` or `httpupgrade`, not
REALITY, with a host name in the TLS `serverName`, the transport's host or the
address (`CleanIPScanner.hostName`). The scan:

1. samples 200 addresses from Cloudflare's published IPv4 ranges, at most one per
   /24, weighted by range size, and lets them past the kill switch;
2. TCP-pings them on the server's port (2 s, 48 at a time, on the physical
   interface in TUN mode) and keeps the 16 fastest;
3. tests each as the server (`pointing`: the address replaced, the host name written
   as SNI and as the transport's host where those were empty) with `RealDelayTester`.

Results list address, ping and delay, best delay first. "Add as New Server" adds the
server at the chosen address to Custom Configs, named "<server> · <address>"; the
original server is left alone, so a subscription update cannot undo the choice.
shortcut: IPv4 and Cloudflare only.

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

Shipped packs: Iran (Chocolate4U lite files, tag `ir`), China and Russia
(Loyalsoldier/v2ray-rules-dat, GPL-3.0: geosite `cn` / `category-ru` + `tld-ru`,
geoip `cn` / `ru`). Loyalsoldier's files hold every country, so they are large
(about 11 MB geosite, 17 MB geoip); each pack keeps its own copy.

- Checksum URL is `<url>.sha256sum`; the first whitespace-separated token is
  the hash.
- **Enable** downloads both files into `assets/`, verifies them, then marks the
  pack enabled. Nothing region-specific ships in the app bundle.
- **Auto-update** per pack: Never / Daily / Weekly (default Weekly), plus
  "Update Now". A successful update restarts the core if the pack is in use.
- "Bypass regions" cannot be selected until at least one pack is enabled.

### 11.3 App update check

Once per 24 h (and on demand), read the latest release of the app's own repo
(GitHub API; the releases Atom feed when the API cannot be read, which is common
behind a shared proxy address). If its version is higher, show it in the menu
bar panel and in Settings with an **Update Now** button. The check can be
turned off; nothing is downloaded until the button is pressed.

**Update Now** downloads `V2Mac-<version>.dmg`, its `.sha256` and its `.sig`
from the release, checks the hash and the signature, copies the app out of the
image to a temporary
folder and verifies its code signature, bundle identifier and version. Only
then does the app quit; a detached shell script waits for the process to exit,
moves the old bundle aside, moves the new one into place (putting the old one
back if that fails) and opens it. The app reconnects on launch as usual. Any
failure before the quit leaves the installed app untouched and offers the
release page instead. The app must be in a folder the user can write to; a
translocated or read-only copy is refused. Releases are ad-hoc signed, so the
code signature proves nothing about who made them, and the `.sha256` comes
from the same release. Origin is proved by the `.sig`: an Ed25519 signature of
the DMG by the project's key, made by `Scripts/sign-update.swift` in the
release workflow (secret `UPDATE_SIGNING_KEY`, refused if missing). The public
key is built into the app (`AppInstaller.updateKey`); a DMG without a valid
signature is never installed.

**Homebrew installs.** When the release build runs from
`/Applications/V2Mac.app` and finds its cask installed
(`<prefix>/Caskroom/v2mac` with `<prefix>/bin/brew`, prefix `/opt/homebrew` or
`/usr/local`), Update Now goes through `brew` instead, so Homebrew keeps track
of the version: while the app still runs, `brew update`, then `brew info` must
show the release's version or a newer one in `lordversa/tap/v2mac` (else
"Homebrew does not offer it yet"), then `brew fetch` puts the DMG in Homebrew's
cache. Each route is tried in turn (`brew update` only until it has succeeded
once), the local proxy through `all_proxy`/`https_proxy`; the direct route clears
those variables. Each `brew` call is stopped after 10 minutes. The app then
quits, and a detached script waits for it to exit (`brew` will not quit an app
it runs inside), runs `brew upgrade --cask` from the cache, writes the exit
status to `run/brew-upgrade.status` and opens the app again. A failed upgrade
leaves the old version, which reports it on launch in Settings and as a
notification, with the last line of `brew`'s output. Debug builds never use this
path.

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

The panel is as tall as its content where the screen has room. On a small
display (under 860 points below the menu bar) the lists are shorter (two
recent servers, three in the switch list), and whatever still does not fit
scrolls. Panel, top to bottom. Related rows share a translucent rounded card (a
hierarchical fill, so the panel's glass shows through), as the modules of
Control Centre do; the connect control and the last row stand outside one:

When the kill switch blocks traffic while nothing is connected (9.8), a card under the
connect control says so with "Allow Traffic".

1. Connect control (dimmed and disabled with no server selected) with state text ("Connected", "Connecting…", "Off", error),
   the active server's name, group and last delay beside it. The control is a
   tinted glass button in a ring: faint while off, a turning arc while starting
   or switching, a closed glowing circle once connected.
2. Exit location, then the traffic graph of the last minute (download as a
   filled curve, upload as a faint line, as in the connection bar) and the live
   download and upload rate.
3. "Subscription" of the active server's group, when the provider sends any of
   it: days left, usage bar with used, total and remaining, Support and Account
   links.
4. "Recent": the last three other servers a connection came up on, newest
   first, from any group (the app remembers six), each with its subscription's
   name on a second line. Click = activate.
5. The active group's name as the title of the switch list: up to six rows — the active server, then the fastest
   tested servers of the active server's group. Click = activate. "Test" runs
   a real delay test of the whole group and turns into progress with "Stop".
6. Routing mode picker, TUN switch, System Proxy switch with its dot (9.9).
7. Local address with a copy button.
8. "Update available" row when relevant.
9. Open v2mac · Settings… · Quit.

With "Speed in the menu bar" (Connection, off by default) the connected icon,
badge included, is followed by the upload rate over the download rate in a
column of fixed width (`MenuBarSpeed`), redrawn with each metrics poll.

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

**Subscription colours.** Every group has one of eleven system colours
(`GroupColor`), chosen in the Add and Edit sheets from a row of swatches. Until
one is chosen a subscription takes a colour by its position and Custom Configs
is blue. The colour tints the group's sidebar icon, its tag in the table's
Subscription column, and the dot beside its name in the Recent lists and the
menu bar panel.

**Sidebar.** "All", "Favorites" (6.6) plus one row per group: name, server count, a spinner while
updating, a warning glyph when the last update failed (tooltip shows the
error). Drag to reorder. Context menu: Update via Proxy, Update without Proxy,
Rename, Edit URL…, Copy URL, Auto-update (toggle), Delete…. Deleting the group
that owns the active server asks for confirmation and disconnects. At the end, "Recent":
the last five servers a connection came up on, newest first, each with its
subscription's name on a second line and the active one marked with a dot
(green while connected). Click = activate.

**Group header** (above the table, when a group is selected): last updated time
and route, "N skipped" if any, and when available a thin usage bar with
"12.4 of 50 GB · expires 2 Nov 2026".

**Server table.** SwiftUI `Table`, multi-selection. Columns: Name (flag and
active marker inside the cell; a server whose last test failed is dimmed),
Subscription (only in "All" and "Favorites"), Type (the protocol, then
transport and security as small tags), Address (hidden by default), Delay and
Speed (both right-aligned). Default order is subscription order; columns sort; `.searchable` filters
by name, address and type. Single click selects (drives the inspector).
Double-click or Return activates. Context menu: Connect, Test Delay, TCP Ping,
Copy Share Link, Show QR Code. A warning glyph on rows that carry `warnings`.

**Inspector.** For the selected server, top to bottom: flag, name and its
subscription's tag; Connect; a row of round buttons (favorite, copy share
link, QR code, edit). "Live", only for the active server while connected: exit
location, traffic graph and rates. "Performance": delay in the table's colours
with when it was tested, speed, and "Test Now" (real delay of this server).
"Connection": Type as in the table, the address with a copy button on hover,
and "More" (protocol, transport, security, SNI / host, fingerprint, flow).
Warnings last.

**Toolbar.** Add (＋). Update menu button (via proxy / without proxy; acts on
the selected group, or all groups in "All"). Test menu button (Real Delay as
the primary action, TCP Ping in the menu; acts on the selection, or on all
visible rows when nothing is selected). Log panel toggle. Inspector toggle.

**Connection bar.** A floating glass capsule pinned to the bottom of the
content column with `safeAreaInset(edge: .bottom)`: connect button, active
server name, routing mode menu, local address with a copy menu
(`127.0.0.1:10808`, `socks5://…`, `http://…`, and shell `export` lines), live
rates. In a failed state it turns red and shows the one-line cause with
"Show Logs". A click on the server name opens the list that server belongs to
(its subscription or Custom Configs), clears the search, selects its row and
scrolls it into view.

**Inspector** (read-only; "Edit…" opens the server editor, section 12.7). Name, protocol, transport, security, address and
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

A "Type" pop-up at the top switches the sheet between "Subscription URL" and
"Custom Config". Custom Config shows one large text box that takes one or many
share links or Xray JSON configs (an array, or objects one after another). They
go into a single manual group, "Custom Configs", which has an empty
`subscriptionURL`, is never updated, and sits above the Subscriptions section
of the sidebar. Configs already in it are not added twice. Its servers can be
deleted one by one from the table's context menu.

⌘V in the main window (outside a text field) adds configs from the clipboard
straight to that group and selects it. An http(s) URL without credentials opens
the sheet as a subscription instead; text that is not a config opens the sheet
on Custom Config with the error shown.

**Importing.** The same goes for a picture on the clipboard (a screenshot): the
text of every QR code in it is added as if it had been pasted (`QRCodeReader`);
a picture without one opens the sheet with that error. Files dropped on the
window or opened with V2Mac are read as config text, or as a QR picture, up to
5 MB. Links dragged from a browser are treated as pasted text. The app is the
handler of `vless`, `vmess`, `trojan`, `ss`, `hysteria2` and `hy2` links, and of
`v2mac://install-config?url=<subscription URL>&name=<name>` (both percent-encoded)
for providers' "add to app" buttons. A link from another app always opens the
sheet filled in, never adds anything by itself.

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

**Shortcuts actions** (`App/Support/Intents.swift`): Connect, Disconnect, Turn
Connection On or Off, Set TUN Mode, Set Routing Mode, Set System Proxy, Set Kill
Switch, Get Connection Status (returns a line of text), Connect to Server, Connect to
Fastest Server, Test Server Delay (returns the servers that answered, fastest first),
Update Subscriptions and Get Exit IP Address (the address of the last exit check). They
appear in Shortcuts, Spotlight and Siri; the Shortcuts app can bind any of them to a
keyboard shortcut that works in every app. Servers are `ServerEntity` (favorites first,
servers a subscription dropped left out unless favorite) and groups `GroupEntity`, so
Siri phrases name a server ("Connect V2Mac to …"). Fastest and Test Server Delay measure
real delay with the list's tester (`AppModel.measureDelays`), a group's servers or all,
and store the results as a list test would. Servers are indexed in Spotlight
(`IndexedEntity`); picking one runs `ShowServerIntent`, which opens the main window with
it selected. The index and Siri's server names are rebuilt three seconds after a save
that changed the list (`AppModel.watchServerIndex`).

**Widget.** The same extension offers a small desktop and Notification Center widget
(`StatusWidget`): the glyph, Off / Connecting… / Connected / Failed, the active server,
the exit (flag, city, IP) and a power button that runs `SetConnectionIntent`. The app
keeps the state in its own defaults (`widgetStatus`, `ControlBridge.status`) and reloads
the widget when it changes; the sandboxed extension reads that one domain through the
`temporary-exception.shared-preference.read-only` entitlement (release and dev ids). It
shows Off when the app no longer holds the Darwin state name, so a quit or crashed app
does not read as connected.

**Control Center.** The widget extension `V2MacControl` (`Extensions/Control`, sandboxed,
as WidgetKit requires; signed with its entitlements by `make-dmg.sh`) offers one switch,
"V2Mac", for Control Center and the menu bar, drawn with a custom symbol made from the
filled menu bar glyph (`v2mac.glyph.symbolset`). It is on while V2Mac is connecting,
switching or connected. `ControlBridge` (`App/Support`, part of both targets) carries the
state: the app publishes on/off as the state of the Darwin notification
`<bundle id>.control.state` and reloads the control on every change; the switch's
`SetConnectionIntent` calls the app directly when the system runs it in the app, and
otherwise posts `<bundle id>.control.request` with the time and the wish in its state. A
request older than 30 seconds is ignored. When V2Mac is not running, turning the switch on
opens `v2mac://connect`, which starts V2Mac and connects without opening a window (the one
action such a link can ask for). An app that is not running reads as off.

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

### 12.6 Notifications

Local notifications through `UNUserNotificationCenter`; they need no entitlement and
work on the ad-hoc signed build (checked 2026-10-10). Permission is asked on first
launch. Each kind has a switch in Settings → Notifications:

| Kind | Sent when | Default |
|---|---|---|
| Connection lost or failed | A connect fails, the core stops and all restart attempts fail, or the port is busy (with a "Use Port N" button) | On |
| Reconnected | The core is running again after a crash, sleep or network change | Off |
| TUN mode stopped | TUN could not start or went down by itself | On |
| Chosen network disconnected | The outgoing network picked in Settings → Connection went away, so V2Mac went back to Automatic (section 8.4) | On |
| Subscription expiring | 3 days and 1 day before the expiry date, and when it passes | On |
| Traffic running out | 80%, 95% and 100% of the quota | On |
| Automatic update failed | A scheduled update fails (first failure in a row only) | Off |
| Servers added or removed | A scheduled update changed the server list | Off |
| V2Mac update available | The background check finds a release, once per release; also a Homebrew upgrade that failed after the app quit for it | On |
| Delay test finished | A test ends while the app is in the background | Off |
| Sandbox downloaded | The sandbox download is checked and installed (section 12.11) | On |
| Sandbox exit stopped working | A mini VM's exit stops passing traffic; sent by the sandbox helper | On |

Rules:

- Services do not know about notifications: each reports events through a closure
  (`onNotice`, `onFailure`, `onFound`, `onFinished`) and `AppModel.wireNotifications`
  decides the wording and posts through `NotificationService`.
- Connection, TUN and test notifications show no banner while a V2Mac window is in
  front (they still reach Notification Center). The three connection kinds share one
  identifier, so the newest replaces the one before it.
- Expiry and traffic levels come from `UsageAlert` (package). A level is announced
  once per subscription; `UsageAlert.step` keeps a marker per group in `UserDefaults`
  (`notifiedExpiry`, `notifiedTraffic`) that resets when the date or quota changes.
  Groups are checked after every update and on each 15-minute scheduler tick.
- A click opens the main window, or Settings on the tab that fits (updates,
  subscriptions). The click sets `AppModel.windowRequest`; `WindowRequestHandler`, a
  view in the menu bar label, opens the window, because only a view has `openWindow`.

### 12.7 Server editor

A sheet that adds a server by hand or changes one, field by field.

- **Opened from:** "Enter Details Manually…" in the Add sheet, File → New Server… (⇧⌘N),
  "Edit…" in a row's menu and in the inspector, Servers → Edit Server… (⌘E).
- **Where it saves.** A new server goes to Custom Configs. A pasted server is changed in
  place and stays the same row; when it is the active server, the core is restarted with
  the new details. A subscription's server is replaced by the next update, so its menu
  item reads "Edit a Copy…" and the result is saved in Custom Configs.
- **Fields.** Name, protocol, address and port for every server, then per protocol:

  | Protocol | Fields |
  |---|---|
  | VLESS | User ID (with a button for a random UUID), flow, encryption |
  | VMess | User ID, encryption |
  | Trojan | Password |
  | Shadowsocks | Method, password |
  | Hysteria 2 | Password, Salamander obfuscation, port hopping (ports, interval), SNI, ALPN, certificate pin, allow insecure |
  | WireGuard | Private key, addresses, MTU, reserved; peer public key, pre-shared key, allowed IPs, keep-alive |
  | SOCKS5, HTTP | Username, password; HTTP also TLS with its SNI |

  VLESS, VMess, Trojan and Shadowsocks also have **Transport** (raw with an optional HTTP
  header, WebSocket, gRPC, HTTPUpgrade, XHTTP with mode and extra JSON, mKCP with header and
  seed), **Security** (none; TLS with SNI, fingerprint, ALPN, allow insecure, certificate
  pin, name to verify, ECH; REALITY with SNI, fingerprint, public key, short ID, spider X,
  ML-DSA-65 key) and **Mux** (connections, XUDP connections, what to do with UDP port 443).
- **`ServerDraft`** (package) is the form's model. It reads a stored outbound, also in
  Xray's older `vnext` / `servers` layout, and builds the outbound in the layout the link
  parser writes. Opening a server and saving it untouched leaves it byte for byte the same.
  Keys the form has no field for (`sockopt`, other transport options) are kept as long as
  the protocol does not change.
- **Share link.** `ShareLinkWriter` writes the link of the result, so Copy Share Link and
  the QR code work for edited servers. The link is kept only when `ShareLinkParser` reads
  it back as the same outbound (Mux aside, which no link carries); otherwise the server has
  no link. VMess uses the v2rayN base64 form when it can hold the server.
- **Checks.** Save lists what is missing or malformed under the form and saves nothing.
- **JSON.** A full Xray config, and an outbound of a protocol the form does not know, are
  edited as text and read back through `SubscriptionParser`.

### 12.8 Traffic usage

While "Count traffic usage" (General) is on, each metrics poll adds the bytes the
core counted since the last one (a new core starts from zero) to this session
and to a total. A session starts when the user connects from off; reconnects,
restarts and server switches continue it. Both are kept in UserDefaults
(`trafficUsage`), so the total survives quitting until **Reset Total**.

This session's amount sits next to the rates in the menu bar panel and in the
connection bar (inline layout only). Clicking it opens a popover with the
session's and the total's download and upload, since when, and Reset Total.
With the setting off nothing is counted or shown.

### 12.9 Backup

Settings → General → "Backup": "Export Backup…" and "Restore Backup…". A `.v2m` file
(type `io.github.lordversa.v2mac.backup`, declared in Info.plist; V2Mac opens it from Finder
too) is base64 text, 76 characters a line, of one JSON object (`Backup`, package):

- `format` (`v2mac-backup`), `version` (1), `app`, `created`;
- `groups`: name, subscription URL (empty for Custom Configs), auto-update, interval,
  colour, User-Agent, and `servers`: each server's name, kind, protocol, address, port,
  transport, security, config, share link, warnings and favorite. Servers a subscription
  dropped are left out unless they are favorites;
- `settings`: every setting that has a default (section 13), the notification switches,
  routing mode, TUN switch, pack intervals, User-Agent and the enabled region packs.

Not in it: the local proxy password, the registered WARP credentials,
the Keychain storage choice, the Touch ID setting, the active and recent servers, traffic totals, delays.

A restore asks first, saying when and with which version the file was made and how many
subscriptions and servers it holds. It adds and never removes: a subscription that is not
here comes with its servers, so it works before its first update; one that is here only
gets its favorites back; pasted configs are added unless one with the same fingerprint is
here. Only the settings listed above are taken; region packs it names are downloaded and
enabled; the connection restarts when it runs. A newer `version` is refused with "made by a
newer V2Mac".

---

### 12.10 Connections

Two tabs, switched by a glass segmented control in the toolbar (`connectionsTab`):
Connections (below) and Map, the globe that used to be a tab of the main window.
On the map, the Requests card lists the latest real connections with their app and
action colour, and a Top apps card the apps that moved the most data. Every open
connection that has moved data is placed by country, one arc per country labelled
with its flag, name and number of connections, which stays while they are open:
by its real address with the core's own `geoip.dat` (`GeoIPIndex`) when that is
known (TUN mode, or a target that is an address), else by the site's country
ending (`.de`, `.co.uk`; not endings used anywhere, such as `.io`). Countries are
placed from the system's `zone.tab` (`CountryPlaces`). Nothing is asked outside
the Mac, so a proxy-mode `.com` site has no arc.

A `connections` window, opened from the second glass button at the foot of the
sidebar (beside the Rules button), lists every connection through the core,
sorted by a click on any column (newest first until changed; the choice is kept across launches as `connectionsSort`): the app (icon and name), the target `host:port`, the time it has
been open (a green dot) or how long it lasted, the outbound the core chose
(tinted Proxy, Direct or Block) with the custom rule that most likely sent it
there (else "No rule · <mode>"), and bytes sent and received. Imported fallback
routes show a purple "Config fallback" label. Outbound tags from full configs
are classified by their protocol for the Proxy, Direct and Block badges.
Connections that skip rules through the proxy-port exception show an orange
"App's proxy setting" label. Each row keeps the mode and custom rules from its
running configuration, so later edits do not relabel its history. Manually
proxied connections remain in Connections but do not add discovered apps or
hosts to Discovered; existing user rules are preserved. Below it, a log of
opens and closes with the same details. The toolbar filters All or Open,
searches apps and targets, and clears closed rows and the log; the subtitle
sums the open connections.

The Group by section of the route filter menu (`connectionsGrouping`, default `none`) adds By Host
and By Application alongside No grouping. It reuses `EntryGroups` from the rule
editor: related domains and installed apps from the same vendor share an
expandable table row. IP addresses and named command-line processes keep their
own groups; unidentified apps share an Unknown app group. All modes keep the
same six columns and single-line rows.
Collapsed group rows show connection/open counts and summed traffic in those columns.
Search, All/Open and an All/Proxy/Direct/Block route filter apply before grouping
and totals; children
keep their individual app, target, time, routing label and traffic. Groups are
collapsed by default. Column sorting applies to both groups and children, using
aggregate traffic and the latest start time for group rows.
Expanding a group stays stable as its connections update. No grouping retains
individual rows without group headers. The event log stays below the table.

Right-clicking a connection opens a menu built only when it opens. Under the app's name:
open the app, show it (or the executable of a command-line tool) in Finder, and Add
App to Rule ▸. Under the target: Open in Browser (ports 443 and 80 only), Add Host to
Rule ▸ and Show Rule. Add to Rule lists the rules (recent first) and New Rule…; it
edits the Rules window's draft and opens it at that rule. Show Rule opens the rule
that matched, or the routing mode.
Details lists every known field (app, target, IP address, status, opened and closed
times, duration, bytes, route, rule, inbound and outbound tags, source port, process,
pid, executable and app paths); choosing one copies its value. Copy has the target,
host, IP address, paths, pid and All Details as text. A group row offers Add to Rule and
Copy Name; several selected rows offer Copy Targets and Copy Details.

`ConnectionWatcher` records only while this window or the Rules window
is open (`watch()` / `unwatch()`). Access log lines from the `mixed-in` and
`tun-in` inbounds make the rows (the core's own DNS lookups, and those TUN mode hands to its resolver, are left out). Once a
second it runs `nettop` (`ProxyFlow`, no privileges needed) for every TCP
connection to the proxy port: its source port links it to a row and gives the
process, whose path (`proc_pidpath`) names the app, and the bytes each way. A
row whose connection is gone is closed. In TUN mode the core sees only the root
forwarder, so a `tun-in` row is linked instead to the app's own connection
through the tunnel (`NetFlow.tunClient`): same port, to an address the site
resolves to (V2Mac looks the name up once, which in TUN mode asks the core's
resolver, as the app did), not linked to another row, and not the core's own.
A row never linked (very short connections close first; a TUN app may have used
another address) has no app or bytes. At most 1,000 rows and 2,000 log lines are kept.

### 12.11 Secure Sandbox (beta)

The sandbox's design and plan live in the sandbox repo (`../sandbox/docs/PLAN.md`); this
section covers only V2Mac's part, which is all the sandbox code V2Mac has (`SandboxService`,
`SandboxLink`, `SandboxFiles`).

- **Pin.** A V2Mac build accepts exactly one sandbox release, a `SandboxPin` (the URL and
  SHA-256 of the release's manifest `files.json`, the full download size, and the SHA-256 of the
  helper's executable). V2Mac 1.0.x pinned a whole-bundle zip instead and cannot read manifests. Without a pin nothing of the
  sandbox is shown. The pin is set in `SandboxService.loadPin` (V2Mac 1.0.0: sandbox v1.0.0); Debug builds can take
  one from `-debugSandboxPin <pin.json>` (written by the sandbox repo's `Scripts/package.sh`).
- **Entry.** "Sandbox" in the main window toolbar and the menu bar panel. Before it is installed
  (or when it needs an update) a sheet in the main window says what it is, the download size and the memory it may use, with
  Download (progress, Cancel). Once installed, the button opens the helper's Sandbox window.
- **Download** (sandbox repo, `docs/delta-updates.md`). The manifest must match the pin; it lists
  every file of the bundle with its SHA-256, its own zip and bsdiff patches keyed by the SHA-256 of
  the old file (paths stay inside `Contents/`, names beside the manifest). Each file is planned
  against the installed bundle: the same hash is copied (an APFS clone), a patch's `from` hash is
  patched with `/usr/bin/bspatch`, anything else comes in full. For an update the sheet shows what
  that plan downloads. Downloads go to `sandbox/download/<sha256>` through the usual routes (local
  proxy if connected, then direct; spec 11), resuming with a `Range` request, and each is checked
  against the manifest before use. A failed patch falls back to that file's zip; any other failure
  keeps the installed sandbox. The new bundle is built in a staging folder and replaces the old one
  only after its executable matches the pin too.
- **Launch.** Before every launch the executable is hashed again. V2Mac starts it with
  `posix_spawn`, one end of a socketpair as fd 3, stdout/stderr inherited and every other
  descriptor closed. There is no listening socket, so no other process can talk to the helper.
- **Link.** `SandboxLink`: 4-byte big-endian length + JSON, at most 1 MB a frame; anything that
  does not decode closes the link, and V2Mac then terminates the helper. The helper exits when the
  link closes, so it never outlives V2Mac. Helper notices may only use the sandbox's own
  notification kinds.
- **Store downloads** (sandbox plan §7). `download(url, sha256)`: a plugin layer, fetched through
  the usual routes (resumed) into `sandbox/cache/<sha256>` and handed back only when its SHA-256
  matches; at most 4 GB. `fetch(url)`: the store index or its signature, at most 1 MB, into
  `sandbox/cache/fetch-<n>` (the helper checks the signature). Both take https only (debug builds
  also `http://127.0.0.1`) and answer with `downloaded(path)`, or no path on any failure.
- **Quit.** On quit V2Mac asks the helper whether sandbox apps are open (2 seconds to answer);
  if so it asks "Quit the sandbox apps too?" (Quit All / Cancel). It then sends `quit` and waits
  up to 15 seconds for the helper to stop its VM before killing it.
- **Settings → Sandbox** (only with a pin): memory limit (2 GB up to half the Mac's memory,
  default a quarter, 2–8 GB; applies from the VM's next start), disk space used, and Remove,
  which after one confirm stops the helper and deletes `sandbox/` and
  `~/Applications/V2Mac Sandbox/`.

## 13. Settings

**Reset.** Every tab with settings ends with "Reset to Defaults…", and General also has
"Reset All Settings…"; both ask first. A reset removes the tab's keys
(`Prefs.resetKeys`), so the registered defaults apply again, and then restarts a running
connection once. Proxy also turns the system proxy off and clears the username and
password; Routing goes back to Global; Connection turns the kill switch off. Kept: servers
and subscriptions, rules and rule profiles, Block QUIC, region packs and their update
intervals, the TUN switch, the WARP account, language, the Keychain and Touch ID choices
and the login item (`Prefs.keptOnReset`; a test checks that every setting with a default
is in one list or the other).

| Tab | Setting | Default |
|---|---|---|
| General | Language: Same as the system / English / فارسی / 简体中文 / Русский. Stored as the app's own `AppleLanguages`; takes effect when V2Mac opens again ("Restart Now"). Persian lays the app out right to left: macOS does not do that for a language it does not offer itself, so `AppLanguage.applyLayoutDirection` sets `AppleTextDirection` and `NSForceRightToLeftWritingDirection` in the argument domain at launch | Same as the system |
| | Launch at login (`SMAppService.mainApp`) | Off |
| | Reconnect on launch | On |
| | Restart core after sleep or network change | On |
| | Count traffic usage (section 12.8) | On |
| | Check for app updates | On |
| | Privileged helper: status, Enable Helper…, Open Login Items, Remove Helper. Removal stops the current connection; ad-hoc builds explain the per-session fallback | Not registered |
| | Store secrets in Apple Keychain: opt in after a notice about the macOS password prompt; otherwise use the encrypted local file | Off |
| | Ask for Touch ID before sharing servers: copying a share link, showing its QR code and exporting a backup ask for Touch ID or the login password first (`OwnerCheck`, LocalAuthentication); one check covers a minute, and turning it off needs one too. Not in backups | Off |
| | Backup: Export Backup…, Restore Backup… (section 12.9) | — |
| Proxy | Port | 10808 |
| | Set as system proxy, with its dot (section 9.9) | Off |
| | Username / Password, optional; the password uses the selected secret store (an older plaintext preference moves there on launch, and is removed only after a successful save) | Empty |
| | Allow connections from LAN (shows the Mac's LAN address; warning when it is on and there are no credentials) | Off |
| Routing | Mode: Global / Bypass regions / Direct / Rules only | Global |
| | Bypass regions list: enable, status, Update Now, auto-update interval | None enabled |
| | Open Rules… (the rules themselves are in the Rules window, section 8.6) | Empty |
| Subscriptions | Auto-update subscriptions | On |
| | Auto-update route: Without proxy / Via proxy | Without proxy |
| | Default interval when the provider sends none | 12 h |
| | User-Agent | `v2mac/<version>` |
| Latency | Test URL | `https://www.wikipedia.org` |
| | Timeout | 8 s |
| | Concurrency | 32 |
| Connection | Switch servers without restarting | On |
| | Automatically select a working server | Off |
| | Switch conditions: delay over (ms); download under (KB/s) for (min) (section 9.7) | Off; 1000 ms; 100 KB/s for 2 min |
| | If TUN fails: Keep local proxy running / Stop connection | Keep local proxy running |
| | Kill switch (section 9.8) | Off |
| Connection | Allow insecure servers | Off |
| Notifications | One switch per kind | See section 12.6 |
| Connection | Show where traffic comes out | On |
| Connection | Country badge on the menu bar icon | On |
| Connection | Speed in the menu bar (section 12.2) | Off |
| | TLS fragment: split (TLS hello / first packets), piece size, pause | Off; `100-200` bytes, `10-20` ms |
| | Noise packets: packet size, pause | Off; `10-20` bytes, `10-16` ms |
| | Use custom DNS: servers, addresses (IPv4 and IPv6 / IPv4 only / IPv6 only) | Off; Cloudflare and Google DoH |
| WARP | Register a WARP device; plan, WARP+ data, device ID, license key; WARP+ license key; Send traffic out through WARP; Add WARP to Servers (section 9.10) | Not registered; exit off |
| Core | Version, Check for Update, Revert to Bundled | — |
| Advanced | Log level: error / warning / info / debug | warning |
| | Log connections | Off |
| About | Version, Share V2Mac and Copy Link, project links (repository, release notes, new issue), developer links, licences and attributions | — |

Changing Port, LAN, credentials, Mode, Log level, Log connections, fragment, noise
or DNS while connected restarts the core.

---

### Secret storage

`useKeychain` is a device-local preference, false when absent and excluded from backups.
With it off, startup and secret reads/writes avoid Keychain entirely. `SecretStore`
encrypts the local proxy password and WARP JSON with CryptoKit
AES-GCM, using a random 256-bit key stored in the same 0700 directory; both files are
0600. No built-in/shared password is used. This hides plaintext at rest but does not
protect against software running as the same user, since it can read the key too.

Settings → General → Secret storage explains these limits. Enabling Keychain first
shows a cancellable notice, like the TUN consent notice; macOS handles any login
password request in its own dialog. Only then are legacy Keychain secrets read and
merged with local values (local values, including explicitly forgotten secrets, win).
After all target writes succeed, the choice is committed and local secret files are
removed. A failure preserves the source and reports the error; a cleanup failure
after commit keeps Keychain selected and reports the remaining local-copy error.
Turning the option off first saves the secrets locally, then commits the preference.
Old Keychain entries are left intact, avoiding extra access prompts; with the option
off they are never accessed. Old installations default to local storage too: users
must re-enter secrets or enable Keychain to recover the old values.

Reads, including denied Keychain reads, are cached for the app session to avoid
repeated prompts. Settings exposes read/write errors and an explicit retry. A corrupt
encrypted file or a missing key is never silently replaced, and connection startup
refuses to run with unreadable secrets rather than dropping proxy authentication.
Successful storage changes refresh the WARP account and reconnect a running core.

Administrator-password storage is retired. Local encrypted files are scrubbed of the
old `adminPassword` field when opened, preserving the other secrets. Keychain reads
and migrations never read or copy that item. For accounts saved by an older version,
Secret storage offers an explicit cleanup button that deletes only the old Keychain
item and removes the old `adminUser` preference after success. This can require macOS
permission; it is never run automatically at launch. Failed cleanup stays visible
and can be retried. These legacy credentials are never reused to authorize the helper.

## 14. Files on disk

```
~/Library/Application Support/v2mac/        (0700)
├─ default.store                 SwiftData
├─ secrets/                      0700, default secret storage
│  ├─ secrets.enc                0600, AES-GCM encrypted secrets
│  └─ secrets.key                0600, random local encryption key
├─ core/xray                     only after an in-app core update
├─ assets/
│  ├─ geoip.dat, geosite.dat     symlinks to the bundle, or updated copies
│  └─ region-<id>-geoip.dat, region-<id>-geosite.dat
├─ run/
│  ├─ config.json                0600, exists only while running
│  ├─ xray.pid
│  ├─ tun.session, tun.on        flag files for the root helper (section 9.5)
│  ├─ proxy.on                   the port the system proxy should use (section 9.9)
│  └─ killswitch.on, killswitch.allow   the kill switch's request and servers (section 9.8)
└─ sandbox/                      0700, only once the sandbox is downloaded (section 12.11)
   ├─ download/<sha256>          partial and finished downloads, kept for resuming
   ├─ V2Mac Sandbox.app          the helper (its kernel and rootfs inside)
   ├─ data.img                   the VM's data disk, sparse
   └─ vm.log                     the VM's console

/var/run/v2mac-tun-<uid>/        root-owned, exists only while the root helper runs
├─ xray, config.json             the copies the helper runs
├─ pf.rules, allow               the kill switch's rules and servers (allow: root only)
├─ killswitch.error              why the kill switch could not go up
└─ pid, xray.log

/var/run/v2mac-killswitch-<uid>  pf's enable token while the kill switch is up

/var/run/v2mac-privileged-<uid>/  0700, managed-session staging
├─ xray                          root-owned, signature verified before execution
└─ requests/                     0700, validated XPC state only

Keychain (login, opt-in only): service = bundle id; accounts proxyPassword and
warpAccount. The retired adminPassword item is only deleted on explicit request.
Debug uses its own bundle id and data directory.

v2mac.app/Contents/
├─ MacOS/v2mac
├─ Library/HelperTools/V2MacPrivilegedHelper
├─ Library/LaunchDaemons/io.github.lordversa.v2mac.privileged.plist
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
- Build the managed daemon as a separate tool, embed its Info.plist, and sign it
  and the bundled core before the outer app, using the same Apple identity.
  `Scripts/embed-privileged-helper.sh` emits the matching per-flavor launchd plist.
  `Scripts/make-dmg.sh` also signs the daemon and assigns the core its app-specific
  `.xray` identifier. The existing ad-hoc release pipeline remains supported via
  the system-dialog fallback. No signing identity or trust setting is created by the app.

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
- The root helper (TUN mode, system proxy, kill switch) is the only part that
  runs as root, and only after managed-helper approval or the system's administrator
  prompt. What runs as root is a fixed forwarder
  config, fixed firewall rules and a copy of the core in a root-owned directory;
  see section 9.5. From the app it takes only flags, a port and a list of
  addresses, each checked. The helper also changes the system's DNS servers to
  fixed public addresses while the tunnel is up, in memory only, and the system
  proxy while asked to.
- Administrator passwords are handled only by macOS, never by V2Mac. Default local
  encryption of proxy and WARP credentials keeps its key on disk and does not isolate
  those secrets from other apps run by the same user.

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
| `SMAppService.mainApp` registration works for an ad-hoc signed build. **Checked 2026-10-10** with the ad-hoc signed Debug build (`-debugLoginItem on|off|status`): status starts as `notFound`, `register()` succeeds without an approval prompt and gives `enabled`, which survives a relaunch; `unregister()` gives `notRegistered`. Not checked: that macOS actually starts the app after a logout and login. | M5 |
| ~~DoH-through-proxy DNS in Bypass mode adds acceptable first-connection latency; routing log shows the expected outbound per domain~~ **Done (M4):** a single DoH server cost ~4 s per domain on this network; two servers in parallel cost 0.8 s first lookup, 0.3 s after. Routing log confirmed. | M4 |
| Liquid Glass modifier signatures in the Xcode 27 SDK | M3 |
| `wireguard://` and `vmess://` base64-JSON field coverage against real provider output | M2 |
| Inbound-tag rewriting covers the custom configs real providers send. M4 covers socks/http/mixed/other inbounds with unit tests and one live run; real provider configs are still untested. | M4 |
| How common `allowInsecure` links are in practice, and whether offering `verifyPeerCertByName` as a remedy is worthwhile | After M2 |
