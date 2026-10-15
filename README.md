<p align="center"><img src="docs/images/banner.jpg" alt="V2Mac, a native macOS Xray-core client for VLESS, VMess, Trojan, Shadowsocks and Hysteria2" width="720"></p>

<p align="center">English | <a href="README.fa.md">فارسی</a> | <a href="README.zh.md">简体中文</a></p>

# V2Mac

**A native macOS client for [Xray-core](https://github.com/XTLS/Xray-core).** Paste a subscription link, pick a server, and get a local SOCKS5 + HTTP proxy. Built with SwiftUI and Liquid Glass, for Apple Silicon.

## Features

- **Subscriptions:** import VLESS, VMess, Trojan, Shadowsocks, Hysteria2, WireGuard and plain SOCKS/HTTP links, or full Xray JSON configs. Auto-update, and shows your traffic usage and expiry date when the provider sends them.
- **Add and edit servers by hand:** fill in every option of a VLESS, VMess, Trojan, Shadowsocks, Hysteria2, WireGuard, SOCKS or HTTP server yourself (transport, TLS or REALITY, Mux), or change one you imported.
- **Favorites:** star the servers you like and find them in one list. A subscription update never removes them without asking.
- **Latency tests:** real-delay and TCP ping for a whole group at once, sorted by speed.
- **Optional automatic selection:** off by default; chooses a working server using real HTTP response delay, monitors the running proxy, and falls back to peers in group order. Manual choices stay selected while they respond.
- **Routing:** Global, Direct, or Bypass regions (Iran, China, Russia) to send local traffic direct.
- **Custom routing rules:** your own Proxy, Direct and Block lists on top of any mode. Paste domains, IP ranges, geosite/geoip tags, Clash rules, hosts files or Adblock lists, or build them in the **Rule Builder** by picking countries on a map and services from a list. [More below](#custom-routing-rules).
- **TUN mode:** one switch routes all traffic on the Mac through the proxy, including apps with no proxy setting and every DNS lookup. No paid developer account or system extension needed. `Scripts/check-tun.sh` checks that nothing leaks.
- **Explicit TUN failure behavior:** choose whether to keep the local proxy or stop the connection when TUN fails. Status distinguishes a local proxy from an active system tunnel. This is not a system kill switch: while the tunnel is down, traffic goes out directly.
- **Menu bar control:** connect, switch server, live speed, and a local address you can copy.
- **Reliable:** restarts the core after a crash, sleep or network change, and reconnects on launch.
- **Also:** LAN sharing with a password, QR codes, a log viewer, launch at login, and one-click updates for the app and the Xray core.
- **Private:** no analytics or telemetry.

## Screenshots

Captured from the current V2MacDev build with made-up demo servers. The development proxy uses port `10818`; the installed app defaults to `10808`.

**Server browsing:** sort by delay, open Favorites, and search for a server.

<p align="center"><img src="docs/images/screenshots/server-browsing.gif" alt="Animated walkthrough of sorting servers by delay, opening Favorites and searching for Frankfurt" width="720"></p>

<details>
<summary>More screenshots: import, editing, QR sharing, and settings</summary>

<p align="center"><img src="docs/images/screenshots/main.png" alt="V2Mac main window: subscription groups, servers with delay and speed, inspector and connection bar" width="720"></p>

The main window lists each subscription with its traffic usage and days left, plus every server's delay and top download speed. Select a server to see its details and copy its share link or QR code. The bar at the bottom shows the connection, the TUN switch, the routing mode and the local proxy address.

**Settings tour:** General, Proxy, Routing, Connection, Servers, Notifications, Core, and About.

<p align="center"><img src="docs/images/screenshots/settings-tour.gif" alt="Animated walkthrough of all eight V2Mac settings tabs" width="560"></p>

Automatic server selection is off by default. Connection settings explain real HTTP checks and let you choose what happens if TUN fails.

<p align="center"><img src="docs/images/screenshots/connection-settings.png" alt="Connection settings with automatic server selection off and the TUN failure policy set to keep the local proxy running" width="560"></p>

**Add a subscription** using its URL and an optional name.

<p align="center"><img src="docs/images/screenshots/add-subscription.png" alt="Add Subscription dialog with URL, optional name and proxy fetching controls" width="460"></p>

**Edit a server copy** in Custom Configs without changing the subscription's original entry.

<p align="center"><img src="docs/images/screenshots/server-editor.png" alt="Server editor showing demo VLESS address, port, user ID, flow and transport" width="520"></p>

**Share a server** using the inspector's QR code.

<p align="center"><img src="docs/images/screenshots/sharing.png" alt="Demo server inspector with its QR sharing popover fully visible" width="328"></p>

**General settings** cover startup, reconnecting, recovery after sleep or network changes, updates, and diagnostics.

<p align="center"><img src="docs/images/screenshots/settings.png" alt="General settings showing startup, connection recovery, updates and diagnostics" width="560"></p>

**Proxy settings** configure the local port and optional LAN access with authentication.

<p align="center"><img src="docs/images/screenshots/proxy-settings.png" alt="Proxy settings with the development port and LAN access disabled" width="560"></p>

**Routing settings** choose a routing mode, manage bypass regions and hold your [custom rules](#custom-routing-rules).

<p align="center"><img src="docs/images/screenshots/routing-settings.png" alt="Routing settings showing Global mode and the Iran bypass region" width="560"></p>

</details>

## Install

Requires macOS 26 or later on Apple Silicon.

With [Homebrew](https://brew.sh), one command installs it and skips the Gatekeeper prompt, so you can go straight to step 3:

```sh
brew install --cask lordversa/tap/v2mac
```

Update later with `brew upgrade --cask v2mac`. Or install by hand:

1. Download `V2Mac-<version>.dmg` from [Releases](../../releases) and drag **V2Mac** to **Applications**.
2. The app is not notarized, so macOS blocks the first launch. Open it once, then go to **System Settings → Privacy & Security** and click **Open Anyway**. Or run:
   ```sh
   xattr -dr com.apple.quarantine /Applications/V2Mac.app
   ```
3. Click **Add Subscription**, paste your link, and double-click a server to connect.
4. Point your apps at `socks5://127.0.0.1:10808` or `http://127.0.0.1:10808`.

To proxy the whole Mac instead, turn on the **TUN** switch next to the routing menu. macOS asks for an administrator password once each time V2Mac is opened; nothing is installed.

Closing the window keeps the proxy running. Quit with ⌘Q to stop it.

## Custom routing rules

The routing mode decides what happens to most traffic. Custom rules decide the exceptions: which sites, countries or addresses always go **through the proxy**, always go **direct**, or are **blocked**. They work in every mode and next to Bypass regions, so you can, for example, bypass Iran but still send one Iranian site through the proxy, or block ads whichever mode you use.

Open **Settings → Routing → Custom rules**. There are three lists, Proxy, Direct and Block, with one rule per line. Edit them and click **Apply**; a running connection restarts to use them.

<p align="center"><img src="docs/images/screenshots/custom-rules.png" alt="Custom rules section in Routing settings, showing a Proxy list with Telegram, AI services, a Clash rule and a wildcard domain" width="560"></p>

**How rules are checked**

1. **Block** list
2. **Proxy** list
3. **Direct** list
4. then the routing mode itself: local network addresses direct, then the Bypass region packs, then everything else to the proxy.

The first match wins, so a site in the Proxy list goes through the proxy even when its country is bypassed. In **Direct** mode only the Block list is used, since nothing there should reach the proxy. Full Xray JSON configs bring their own routing and ignore custom rules.

**What you can write**

You can paste lists in the formats most guides and rule sets online use. Commas and spaces also separate rules, and lines starting with `#`, `//` or `!` are comments.

| Write | Matches |
|---|---|
| `example.com`, `*.example.com`, `+.example.com`, `.ir` | the domain and all its subdomains (`.ir` covers every `.ir` site) |
| `full:www.example.com` | only that exact name |
| `keyword:shop` | any name containing the word |
| `regexp:^ads\d+\.` | names matching a regular expression |
| `1.2.3.4`, `10.0.0.0/8`, `2001:db8::/32` | an address or a range, IPv4 or IPv6 |
| `geosite:google`, `geosite:category-ads-all` | a site list from the core's `geosite.dat` (1,500+ lists) |
| `geoip:de`, `geoip:telegram` | a country's or service's addresses from `geoip.dat` |
| `ext:region-ir-geosite.dat:ir` | a list from a downloaded region pack |
| `DOMAIN-SUFFIX,example.com,DIRECT` | Clash rules: `DOMAIN`, `DOMAIN-SUFFIX`, `DOMAIN-KEYWORD`, `DOMAIN-REGEX`, `IP-CIDR`, `IP-CIDR6`, `GEOIP`, `GEOSITE` (the list you paste into decides the action) |
| `0.0.0.0 ads.example.com` | lines from a hosts file |
| `\|\|ads.example.com^` | Adblock domain lines |

Anything that is not a rule is skipped and named under the editor, so a typo never stops the connection.

### Rule Builder

Rather not type rules? Click **Rule Builder…** under the lists. It writes them for you in three steps.

**1. Action.** Choose what should happen: Proxy, Direct or Block. Or start from a common setup, such as keeping your own country direct, blocking ads and trackers, or sending AI services, Telegram or streaming through the proxy.

<p align="center"><img src="docs/images/screenshots/rule-builder-action.png" alt="Rule Builder first step with Proxy, Direct and Block cards and a list of common setups" width="720"></p>

**2. Choose.** Pick what to match from three tabs. The counts in the tabs and the footer show how much you have picked so far.

- **Countries:** search all 250 countries by name or code, or click a country on the map to add or remove it. Each picked country gets a flag on the map. For each country you choose what to add: its IP ranges (`geoip:ir`), its domain ending (`domain:ir`, every `.ir` site), and its list of known sites on other domains (`geosite:category-ir`) where the rule files have one.

<p align="center"><img src="docs/images/screenshots/rule-builder-countries.png" alt="Rule Builder country step: searchable country list on the left, a world map with flags on Germany, Iran and Japan on the right" width="720"></p>

- **Services:** one click for Google, YouTube, Telegram, Instagram, WhatsApp, X, Netflix, Spotify, OpenAI, Anthropic, Apple, Microsoft, ads and trackers, and more. On the right you can search every list in the core's rule files. The lists come from the files themselves, so the builder never writes a rule for a list the core does not have.

<p align="center"><img src="docs/images/screenshots/rule-builder-services.png" alt="Rule Builder services step with popular service tiles and a searchable list of every geosite and geoip list" width="720"></p>

- **Domains & IPs:** type or paste anything in the formats above. It is checked as you type, and a guide to the formats sits beside it.

<p align="center"><img src="docs/images/screenshots/rule-builder-domains.png" alt="Rule Builder domains step with a text editor, a live count and a guide to accepted formats" width="720"></p>

**3. Review.** See every rule that will be written and what kind it is. Rules already in the list are marked and not added twice. Choose **Add to the list** or **Replace the list**, then click **Add Rules**. The rules are saved under a dated `# Rule Builder` comment, so you can find and edit them later in Settings.

<p align="center"><img src="docs/images/screenshots/rule-builder-review.png" alt="Rule Builder review step listing thirteen rules for the Direct list" width="720"></p>

**Examples**

| Goal | List | Rules |
|---|---|---|
| Block ads everywhere | Block | `geosite:category-ads-all` |
| Use AI services through the proxy, even with Iran bypassed | Proxy | `geosite:openai`, `geosite:anthropic`, `geosite:category-ai-!cn` |
| Keep Apple and Microsoft updates off the proxy | Direct | `geosite:apple`, `geosite:microsoft` |
| Reach your office network directly | Direct | `10.0.0.0/8`, `full:intranet.example.com` |
| Use a downloaded Clash rule list | any | paste the `payload:` lines as they are |

A rule naming a list the files do not contain, say `geosite:nonexistent`, stops the core from starting; the log says which one. The Rule Builder only offers lists that exist.

## Leak protection in Chrome: noleaker

A proxy alone does not stop the browser from giving you away: WebRTC can expose your real IP, DNS and QUIC can go around the proxy, and your timezone and language still say where you are. For Chrome and other Chromium-based browsers, use [**noleaker**](https://github.com/LordVersA/noleaker), a free, open-source extension from the same author that pairs with V2Mac:

- Sends all browser traffic and DNS lookups through V2Mac's SOCKS5 proxy, and blocks WebRTC and QUIC leaks.
- Matches timezone, language and geolocation to the country of your server.
- Kill switch: if the proxy goes down, requests are blocked instead of going out directly.
- Built-in leak test that checks each of these and says which setting fixes a failure.
- Compatibility mode lets Iran-hosted sites skip the proxy.

Setup: install noleaker from its [latest release](https://github.com/LordVersA/noleaker/releases/latest), add a proxy with host `127.0.0.1` and port `10808`, and switch **Protection** on. noleaker cannot send a proxy username or password, so leave those empty in V2Mac's settings. It is tested on Chrome 120 and newer.

## Build from source

```sh
Scripts/fetch-core.sh
xcodegen generate
xcodebuild -project v2mac.xcodeproj -scheme v2mac -configuration Debug build
```

Needs Xcode 26+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen). The design is in [docs/SPEC.md](docs/SPEC.md).

## License

GPL-3.0. See [LICENSE](LICENSE) and [THIRD_PARTY.md](THIRD_PARTY.md).
