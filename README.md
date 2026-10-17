<p align="center"><img src="docs/images/banner.jpg" alt="V2Mac, a native macOS Xray-core client for VLESS, VMess, Trojan, Shadowsocks and Hysteria2" width="720"></p>

<h1 align="center">V2Mac</h1>

<p align="center"><b>A native macOS client for Xray-core and V2Ray.</b><br>
VLESS, REALITY, VMess, Trojan, Shadowsocks, Hysteria2 and WireGuard in a fast SwiftUI menu bar app for Apple Silicon.</p>

<p align="center">
  <a href="https://github.com/LordVersA/v2mac/releases/latest"><img src="https://img.shields.io/github/v/release/LordVersA/v2mac?label=release&color=0A84FF" alt="Latest release"></a>
  <a href="https://github.com/LordVersA/v2mac/releases"><img src="https://img.shields.io/github/downloads/LordVersA/v2mac/total?color=34C759" alt="Total downloads"></a>
  <a href="https://github.com/LordVersA/v2mac/actions/workflows/ci.yml"><img src="https://img.shields.io/github/actions/workflow/status/LordVersA/v2mac/ci.yml?branch=main&label=CI" alt="CI status"></a>
  <img src="https://img.shields.io/badge/macOS-26%2B-000000?logo=apple" alt="macOS 26 or later">
  <img src="https://img.shields.io/badge/Apple%20Silicon-arm64-555555" alt="Apple Silicon">
  <img src="https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white" alt="Swift 6">
  <a href="LICENSE"><img src="https://img.shields.io/github/license/LordVersA/v2mac?color=blue" alt="GPL-3.0 license"></a>
  <a href="https://github.com/LordVersA/v2mac/stargazers"><img src="https://img.shields.io/github/stars/LordVersA/v2mac?style=flat&color=FFCC00" alt="GitHub stars"></a>
</p>

<p align="center">English | <a href="README.fa.md">فارسی</a> | <a href="README.zh.md">简体中文</a> | <a href="README.ru.md">Русский</a></p>

<p align="center">
  <a href="#install">Install</a> ·
  <a href="#features">Features</a> ·
  <a href="#screenshots">Screenshots</a> ·
  <a href="docs/routing-rules.md">Routing rules</a> ·
  <a href="#faq">FAQ</a> ·
  <a href="#build-from-source">Build</a>
</p>

<p align="center"><img src="docs/images/screenshots/server-browsing.gif" alt="V2Mac main window: sorting servers by delay, opening Favorites and searching" width="760"></p>

Paste a subscription link, pick a server, and you have a local SOCKS5 + HTTP proxy, or turn on TUN mode to send the whole Mac through it. V2Mac is a free, open-source **v2rayN / V2RayX alternative for macOS**, written natively in SwiftUI with Liquid Glass. No Electron, no analytics, no telemetry.

## Install

Requires **macOS 26 or later** on **Apple Silicon** (M1 and newer).

**Homebrew** (recommended, skips the Gatekeeper prompt):

```sh
brew install --cask lordversa/tap/v2mac
```

Update later with `brew upgrade --cask v2mac`.

**Manual download:**

1. Download `V2Mac-<version>.dmg` from the [latest release](https://github.com/LordVersA/v2mac/releases/latest) and drag **V2Mac** to **Applications**.
2. The app is not notarized, so macOS blocks the first launch. Open it once, then click **Open Anyway** in **System Settings → Privacy & Security**, or run:
   ```sh
   xattr -dr com.apple.quarantine /Applications/V2Mac.app
   ```

**First connection:**

1. Click **Add Subscription** and paste your link (or a `vless://`, `vmess://`, `trojan://`, `ss://`, `hy2://` link).
2. Double-click a server to connect.
3. Point your apps at `socks5://127.0.0.1:10808` or `http://127.0.0.1:10808`, or switch on **System Proxy** or **TUN**.

Closing the window keeps the proxy running. Quit with ⌘Q to stop it.

## Features

### Protocols and import

| | |
|---|---|
| **Protocols** | VLESS (incl. REALITY, XTLS Vision), VMess, Trojan, Shadowsocks, Hysteria2, WireGuard, SOCKS, HTTP, and full Xray JSON configs |
| **Subscriptions** | Auto-update, with traffic usage and expiry date when the provider sends them |
| **Quick import** | Click a share link anywhere, a provider's `v2mac://install-config?url=…` button, paste a QR screenshot, or drop config files and QR images on the window |
| **Server editor** | Every option by hand: transport, TLS or REALITY, Mux. Edit imported servers without touching the original |
| **Favorites** | Star servers; a subscription update never removes them without asking |

### Connection

- **Latency tests:** real-delay and TCP ping for a whole group at once, sorted by speed, plus download speed.
- **Automatic server selection** (optional): picks a working server by real HTTP delay, watches it, and falls back in group order when it stalls or gets slow.
- **TUN mode:** one switch routes every app and every DNS lookup through the proxy. No paid developer account or system extension needed; `Scripts/check-tun.sh` verifies nothing leaks.
- **System proxy:** one switch points the macOS system proxy at V2Mac, with a status dot that shows who owns it.
- **Kill switch** (optional): blocks everything except the server and local network while connected, even if the connection drops, using the macOS firewall (pf).
- **Cloudflare WARP:** register a free WARP device (MASQUE), use a WARP+ key, and add WARP as a server or chain it behind your own.
- **Reliable:** restarts the core after a crash, sleep or network change, and reconnects on launch.
- **Live switching:** picking another server swaps it inside the running core instead of restarting it.

### Routing

- **Modes:** Global, Rules Only, Direct, or **Bypass** regions (Iran, China, Russia) so local sites go direct.
- **Custom rules, like Proxifier:** ordered Proxy / Direct / Block rules by site and by app. Imports Proxifier `.ppx` profiles, Clash rules, hosts files, Adblock lists, geosite and geoip tags.
- **Rule Builder:** pick countries on a world map and services (Google, Telegram, OpenAI, Netflix, ads…) from a list.
- **Connections view:** every connection, grouped by host or app, with the rule that routed it.

→ Full guide: **[Custom routing rules](docs/routing-rules.md)**

### macOS integration

- **Menu bar control:** connect, switch servers, live upload/download speed, exit IP and country.
- **Control Center, Shortcuts, Spotlight and Siri:** connect, disconnect, and toggle TUN, routing mode, system proxy or kill switch.
- **Privileged helper:** Apple-signed builds use an `SMAppService` helper you approve once; V2Mac never sees or stores your administrator password.
- **Backup:** export subscriptions, servers, favorites and settings to a `.v2m` file and restore on another Mac.
- **Also:** password-protected LAN sharing, QR codes, log viewer, notifications, launch at login, and one-click updates for the app and the Xray core.
- **Languages:** English, Persian (RTL), Simplified Chinese and Russian.
- **Private:** no analytics, no telemetry. Secrets stay in an encrypted local file or, if you choose, the Keychain.

## Per-app routing: a Proxifier alternative for macOS

V2Mac decides, connection by connection, which app and which site goes **through the proxy**, goes **direct**, or is **blocked**, the way Proxifier does, but with Xray's protocols built in, so you no longer need two apps.

- **Rules by app and by host.** An app can be written as `Telegram.app`, a bundle id (`com.example.chat`), a pattern (`*code*`), a process name (`curl`) or a full path. Hosts take domains, wildcards (`*google*`), IP ranges, geosite/geoip tags, Clash rules, hosts files and Adblock lists. A rule with both needs both to match.
- **First match wins.** Rules are checked from the top; drag to reorder. Local names (`localhost`, `*.local`) and the local network always go direct.
- **Simple editor.** One row per app or host with a Proxy / Direct / Block menu, saved groups, bulk changes, and a **Discovered** inbox of new apps and hosts seen in your traffic, ready to route with one click.
- **Import your Proxifier profile.** **Import…** reads a `.ppx` file and shows every rule before adding it. Rules that use V2Mac's port become Proxy rules, Direct and Block rules stay as they are, and rules to other proxies or chains are skipped and listed. **Block QUIC (UDP 443)** works like Proxifier's option, so browsers fall back to TCP and their host names reach the rules.
- **Rule profiles.** Keep several named rule sets (home, work, travel) and switch between them from the toolbar.

<p align="center"><img src="docs/images/screenshots/rule-editor-simple.png" alt="Rule Editor, Simple view: apps such as Telegram, Discord, Xcode and Safari, each with a Proxy or Direct route" width="720"></p>

<p align="center"><img src="docs/images/screenshots/rule-editor-advanced.png" alt="Rule Editor, Advanced view: ordered rules with Add Rule, Rule Builder and Import Proxifier Profile buttons and the Block QUIC switch" width="720"></p>

App rules apply to apps that use the system proxy or connect to V2Mac's port. In TUN mode the app name is not known, so host and IP rules apply instead. More in the **[routing rules guide](docs/routing-rules.md)**.

## Connections: see where every request goes

The **Connections** window lists every request live: the app that made it, the target host and port, how long it has been open, the bytes sent and received, and the **rule** that routed it (Proxy, Direct or Block, plus the rule's name).

- **Group** by application or by host to see which apps talk most and where, or show every connection on its own.
- **Filter** by All / Open and by route, and search apps and targets.
- **Colour-coded reasons:** orange for apps that use the proxy port by their own setting, purple for traffic that fell back to an imported config's own routing.
- **Event log** at the bottom shows each connection as it opens and closes.
- **Map** view shows your requests and top apps on a globe.
- Right-click a connection to jump straight to the rule (or server config) behind it, or to add a new rule for that app or host.

<p align="center"><img src="docs/images/screenshots/connections.png" alt="Connections window: Mail, Safari, curl and Music requests with their targets, durations, Proxy, Direct and Block routes, rule names and traffic" width="720"></p>

## Screenshots

All screenshots use made-up demo servers.

<p align="center"><img src="docs/images/screenshots/main.png" alt="V2Mac main window with subscription groups, server delay and speed, inspector and connection bar" width="760"></p>

<table>
  <tr>
    <td align="center"><img src="docs/images/screenshots/add-subscription.png" alt="Add Subscription dialog" width="380"><br><sub>Add a subscription</sub></td>
    <td align="center"><img src="docs/images/screenshots/server-editor.png" alt="VLESS server editor" width="380"><br><sub>Edit any server</sub></td>
  </tr>
  <tr>
    <td align="center"><img src="docs/images/screenshots/rule-builder-countries.png" alt="Rule Builder world map with selected countries" width="380"><br><sub>Rule Builder: pick countries on a map</sub></td>
    <td align="center"><img src="docs/images/screenshots/custom-rules.png" alt="Custom routing rules in settings" width="380"><br><sub>Custom routing rules</sub></td>
  </tr>
</table>

<details>
<summary><b>More screenshots</b></summary>

<p align="center"><img src="docs/images/screenshots/settings-tour.gif" alt="Animated tour of all V2Mac settings tabs" width="560"></p>
<p align="center"><img src="docs/images/screenshots/connection-settings.png" alt="Connection settings: automatic server selection and TUN failure policy" width="560"></p>
<p align="center"><img src="docs/images/screenshots/routing-settings.png" alt="Routing settings with Bypass Iran" width="560"></p>
<p align="center"><img src="docs/images/screenshots/sharing.png" alt="Server QR code for sharing" width="328"></p>

</details>

## Leak protection in Chrome: noleaker

A proxy alone does not stop the browser from leaking: WebRTC can expose your real IP, DNS and QUIC can bypass the proxy, and timezone and language reveal your location. [**noleaker**](https://github.com/LordVersA/noleaker), a free extension from the same author, pairs with V2Mac for Chrome and Chromium browsers: it forces traffic and DNS through V2Mac's SOCKS5 proxy, blocks WebRTC and QUIC leaks, matches timezone, language and geolocation to your server, and blocks requests if the proxy goes down.

Setup: install the [latest release](https://github.com/LordVersA/noleaker/releases/latest), add proxy `127.0.0.1:10808`, and switch **Protection** on. Leave V2Mac's proxy username and password empty.

## FAQ

<details>
<summary><b>Is V2Mac a V2Ray client for Mac?</b></summary>

Yes. V2Mac runs [Xray-core](https://github.com/XTLS/Xray-core), the actively developed successor of V2Ray core, so it reads V2Ray and Xray share links and subscriptions (VLESS, VMess, Trojan, Shadowsocks) plus Hysteria2 and WireGuard.
</details>

<details>
<summary><b>Does it support VLESS REALITY and XTLS Vision?</b></summary>

Yes, both from share links and in the server editor, along with TCP, WebSocket, gRPC, HTTPUpgrade, XHTTP (SplitHTTP) and mKCP transports.
</details>

<details>
<summary><b>How do I proxy all apps, including ones without proxy settings?</b></summary>

Turn on **TUN** next to the routing menu. It routes every app and DNS lookup through the server. Approve the helper once (Apple-signed builds) or enter your administrator password once per session (ad-hoc builds).
</details>

<details>
<summary><b>Does it work on Intel Macs or older macOS?</b></summary>

No. V2Mac needs macOS 26 or later on Apple Silicon.
</details>

<details>
<summary><b>Why does macOS say the app cannot be opened?</b></summary>

The DMG is not notarized. Use **Open Anyway** in Privacy & Security, the `xattr` command above, or install with Homebrew.
</details>

<details>
<summary><b>Does V2Mac collect any data?</b></summary>

No. There is no analytics or telemetry. Besides your own traffic, V2Mac only contacts your subscription URLs, GitHub for updates and rule files, and a public IP service to check the exit after connecting.
</details>

## Build from source

```sh
Scripts/fetch-core.sh
xcodegen generate
xcodebuild -project v2mac.xcodeproj -scheme v2mac -configuration Debug build
```

Needs Xcode 26+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen). The design is in [docs/SPEC.md](docs/SPEC.md). Package tests: `cd Packages/V2MacCore && swift test`.

Bug reports and pull requests are welcome in [Issues](https://github.com/LordVersA/v2mac/issues).

## License

[GPL-3.0](LICENSE). Bundles [Xray-core](https://github.com/XTLS/Xray-core) (MPL-2.0); see [THIRD_PARTY.md](THIRD_PARTY.md).

<p align="center"><sub>If V2Mac helps you, a ⭐ helps others find it.</sub></p>
