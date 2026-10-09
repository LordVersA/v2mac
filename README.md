<p align="center"><img src="docs/images/banner.jpg" alt="v2mac" width="720"></p>

# V2Mac

Native macOS menu bar shell around [Xray-core](https://github.com/XTLS/Xray-core). It imports subscription links, runs the core, and exposes the connection as a local SOCKS5 + HTTP proxy on `127.0.0.1:10808`. It has no TUN mode and does not reimplement any proxy protocol. Design and behaviour are in [docs/SPEC.md](docs/SPEC.md).

Requires macOS 26 or later on Apple Silicon.

## Install

1. Download `V2Mac-<version>.dmg` from the Releases page and compare its SHA-256 with the `.sha256` file next to it:
   ```sh
   shasum -a 256 V2Mac-<version>.dmg
   ```
2. Open the DMG and drag **V2Mac** onto **Applications**.
3. **First launch.** The app is ad-hoc signed, not notarized, so macOS blocks it the first time:
   - Open V2Mac once (it will be refused), then go to **System Settings → Privacy & Security**, scroll to the message about V2Mac and click **Open Anyway**.
   - Or remove the quarantine flag from a terminal:
     ```sh
     xattr -dr com.apple.quarantine /Applications/V2Mac.app
     ```
   Right-click → Open no longer works on current macOS, and Homebrew does not avoid this step.
4. **Connect.** Click **Add Subscription**, paste the subscription URL, double-click a server (or select it and press the power button). The menu bar icon fills in when the proxy is up.
5. **Use the proxy.** Point apps at `socks5://127.0.0.1:10808` or `http://127.0.0.1:10808`. The connection bar's address menu copies both forms and ready-made shell `export` lines.

Closing the window keeps the proxy running; **Quit** (⌘Q) stops it. In Settings you can turn on launch at login, change the port, allow LAN access (set a username and password if you do), and pick the routing mode. **Bypass regions** sends traffic for a chosen region (Iran is included) directly and everything else through the proxy; its rule files are downloaded when you enable the region.

## Updates

- **App:** V2Mac checks its releases page once a day and shows "Update available" in the menu bar panel. It never installs anything by itself; download the new DMG and replace the app.
- **Xray core:** Settings → Core → Check for Update. Downloads are checked against the published SHA-256 and self-tested before they replace the bundled core. "Revert to Bundled" undoes it.
- **Region rule files:** each enabled region updates on its own schedule (Never / Daily / Weekly) or with Update Now.

Nothing else touches the network except your subscription URLs, the latency test URL and GitHub. There is no telemetry.

## Build

```sh
Scripts/fetch-core.sh
xcodegen generate
xcodebuild -project v2mac.xcodeproj -scheme v2mac -configuration Debug build
(cd Packages/V2MacCore && swift test)
```

Requires Xcode 26+ and XcodeGen.

### Release

```sh
Scripts/make-dmg.sh                    # ad-hoc signed DMG and .sha256 in dist/
SIGN_IDENTITY="Developer ID Application: …" NOTARY_PROFILE=profile Scripts/make-dmg.sh
```

To enable the app update check, set `V2MAC_REPOSITORY` (`owner/name` of the GitHub repository that hosts the releases) in `project.yml`.

## Licence

GPL-3.0, see [LICENSE](LICENSE). Third-party notices are in [THIRD_PARTY.md](THIRD_PARTY.md).
