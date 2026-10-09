<p align="center"><img src="docs/images/banner.jpg" alt="V2Mac, a native macOS Xray-core client for VLESS, VMess, Trojan, Shadowsocks and Hysteria2" width="720"></p>

# V2Mac

**A native macOS client for [Xray-core](https://github.com/XTLS/Xray-core).** Paste a subscription link, pick a server, and get a local SOCKS5 + HTTP proxy. Built with SwiftUI and Liquid Glass, for Apple Silicon.

## Features

- **Subscriptions:** import VLESS, VMess, Trojan, Shadowsocks, Hysteria2, WireGuard and plain SOCKS/HTTP links, or full Xray JSON configs. Auto-update, and shows your traffic usage and expiry date when the provider sends them.
- **Latency tests:** real-delay and TCP ping for a whole group at once, sorted by speed.
- **Routing:** Global, Direct, or Bypass regions (Iran included) to send local traffic direct.
- **Menu bar control:** connect, switch server, live speed, and a local address you can copy.
- **Reliable:** restarts the core after a crash, sleep or network change, and reconnects on launch.
- **Also:** LAN sharing with a password, QR codes, a log viewer, launch at login, and in-app Xray core updates.
- **Private:** no analytics or telemetry.

## Install

Requires macOS 26 or later on Apple Silicon.

1. Download `V2Mac-<version>.dmg` from [Releases](../../releases) and drag **V2Mac** to **Applications**.
2. The app is not notarized, so macOS blocks the first launch. Open it once, then go to **System Settings → Privacy & Security** and click **Open Anyway**. Or run:
   ```sh
   xattr -dr com.apple.quarantine /Applications/V2Mac.app
   ```
3. Click **Add Subscription**, paste your link, and double-click a server to connect.
4. Point your apps at `socks5://127.0.0.1:10808` or `http://127.0.0.1:10808`.

Closing the window keeps the proxy running. Quit with ⌘Q to stop it.

## Build from source

```sh
Scripts/fetch-core.sh
xcodegen generate
xcodebuild -project v2mac.xcodeproj -scheme v2mac -configuration Debug build
```

Needs Xcode 26+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen). The design is in [docs/SPEC.md](docs/SPEC.md).

## License

GPL-3.0. See [LICENSE](LICENSE) and [THIRD_PARTY.md](THIRD_PARTY.md).
