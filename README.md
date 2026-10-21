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
  <a href="https://github.com/LordVersA/v2mac/wiki"><b>Documentation</b></a> ·
  <a href="#build-from-source">Build</a>
</p>

<p align="center"><img src="docs/images/screenshots/server-browsing.gif" alt="V2Mac main window: sorting servers by delay, opening Favorites and searching" width="760"></p>

Paste a subscription link, pick a server, and you have a local SOCKS5 + HTTP proxy, or turn on TUN mode to send the whole Mac through it. V2Mac is a free, open-source **v2rayN / V2RayX alternative for macOS**, written natively in SwiftUI with Liquid Glass. No Electron, no analytics, no telemetry.

## Install

Requires **macOS 26 or later** on **Apple Silicon**.

```sh
brew install --cask lordversa/tap/v2mac
```

Or download the DMG from the [latest release](https://github.com/LordVersA/v2mac/releases/latest). It is not notarized: on first launch use **Open Anyway** in System Settings → Privacy & Security. Details in the [installation guide](https://github.com/LordVersA/v2mac/wiki/Installation).

**Quick start:** click **Add Subscription** and paste your link, double-click a server, then use `127.0.0.1:10808` (SOCKS5 / HTTP) or switch on **System Proxy** or **TUN**.

## Features

- **Protocols:** VLESS (REALITY, XTLS Vision), VMess, Trojan, Shadowsocks, Hysteria2, WireGuard, SOCKS, HTTP and full Xray JSON configs.
- **Subscriptions:** auto-update, usage and expiry, favorites, QR and one-click import, a full server editor.
- **Connection:** real-delay and speed tests, automatic server selection, live switching without a restart, exit country in the menu bar.
- **Whole-Mac modes:** TUN, system proxy and a pf-based kill switch.
- **Routing:** Global, Bypass regions (Iran, China, Russia), Rules Only and Direct, plus Proxy / Direct / Block rules by site and by app.
- **Proxifier alternative:** per-app rules, `.ppx` profile import, a visual Rule Builder and a live Connections view.
- **Cloudflare WARP:** as its own server or chained behind yours.
- **macOS:** menu bar panel, Shortcuts, Siri, Spotlight, Control Center, a desktop widget, Apple Intelligence domain suggestions, Touch ID, notifications, backup and restore. English, Persian, Chinese and Russian.

## Screenshots

<p align="center"><img src="docs/images/screenshots/main.png" alt="V2Mac main window with subscription groups, server delay and speed, inspector and connection bar" width="760"></p>

<table>
  <tr>
    <td align="center"><img src="docs/images/screenshots/rule-editor-simple.png" alt="Rule Editor, Simple view" width="380"><br><sub>Per-app and per-site rules</sub></td>
    <td align="center"><img src="docs/images/screenshots/connections.png" alt="Connections window" width="380"><br><sub>Every connection and the rule behind it</sub></td>
  </tr>
  <tr>
    <td align="center"><img src="docs/images/screenshots/rule-builder-countries.png" alt="Rule Builder world map" width="380"><br><sub>Rule Builder</sub></td>
    <td align="center"><img src="docs/images/screenshots/proxifier-import.png" alt="Proxifier profile import" width="380"><br><sub>Proxifier import</sub></td>
  </tr>
</table>

## Documentation

The **[V2Mac Wiki](https://github.com/LordVersA/v2mac/wiki)** covers everything in detail:

| | |
|---|---|
| [Installation](https://github.com/LordVersA/v2mac/wiki/Installation) | Homebrew, DMG, first launch, updates |
| [Servers and Subscriptions](https://github.com/LordVersA/v2mac/wiki/Servers-and-Subscriptions) | Adding, updating, editing, latency tests |
| [Connecting](https://github.com/LordVersA/v2mac/wiki/Connecting) | TUN, system proxy, kill switch, exit check, WARP |
| [Routing](https://github.com/LordVersA/v2mac/wiki/Routing) | Modes, custom rules, Proxifier import, Rule Builder |
| [Connections](https://github.com/LordVersA/v2mac/wiki/Connections) | Live connection list and map |
| [Menu Bar and Shortcuts](https://github.com/LordVersA/v2mac/wiki/Menu-Bar-and-Shortcuts) | Panel, keyboard, Shortcuts, notifications |
| [Settings Reference](https://github.com/LordVersA/v2mac/wiki/Settings-Reference) | Every setting, backup, privacy |
| [Troubleshooting and FAQ](https://github.com/LordVersA/v2mac/wiki/Troubleshooting-and-FAQ) | Common problems and questions |

For leak protection in Chrome, pair V2Mac with [**noleaker**](https://github.com/LordVersA/noleaker), a free extension from the same author.

## Build from source

```sh
Scripts/fetch-core.sh
xcodegen generate
xcodebuild -project v2mac.xcodeproj -scheme v2mac -configuration Debug build
```

Needs Xcode 26+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen). Design: [docs/SPEC.md](docs/SPEC.md). Tests: `cd Packages/V2MacCore && swift test`. Bug reports and pull requests are welcome in [Issues](https://github.com/LordVersA/v2mac/issues).

## License

[GPL-3.0](LICENSE). Bundles [Xray-core](https://github.com/XTLS/Xray-core) (MPL-2.0); see [THIRD_PARTY.md](THIRD_PARTY.md).

<p align="center"><sub>If V2Mac helps you, a ⭐ helps others find it.</sub></p>
