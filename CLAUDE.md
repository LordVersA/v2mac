# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

V2Mac is a native macOS (26+, Apple Silicon) menu bar client for Xray-core: SwiftUI + SwiftData app,
Swift 6 with strict concurrency, no third-party Swift dependencies. Spec: `docs/SPEC.md` (code
comments cite it as "spec 6.4" etc.; read the section before changing the behavior it describes).

## Commit after every finished task (do not forget)
- When a change is done and builds, **commit it**. Don't leave finished work uncommitted and
  don't wait to be reminded. Push when the user asks, or when CI needs to see it.
- **The commit message is the changelog.** Release notes are generated from the commit messages
  between the previous release tag and the new one (`Scripts/changelog.sh`), so write them for
  users, not for yourself:
  - Subject line: one plain sentence in the imperative, saying what changed for the user
    ("Show traffic usage in the group header"). No ticket numbers or file names.
  - Optional body: extra user-visible points as **single-line** bullets starting with `- `.
    A bullet that wraps onto a second line is cut off in the notes.
  - Purely internal commits (CI, docs, tests, refactors) start with `ci:`, `docs:`, `test:` or
    `chore:` and are left out of the release notes.
  - End with the `Co-Authored-By` trailer given in the session.

## Never close the installed app
- The V2Mac in `/Applications` (bundle id `io.github.lordversa.v2mac`) is the user's own running VPN.
  **Never quit, kill or restart it, or its `xray` core**, not even "just to test a rebuild".
- Test only with the dev instance: every Debug build is a separate app, **`V2MacDev.app`**
  (bundle id `io.github.lordversa.v2mac.dev`, data folder `~/Library/Application Support/v2mac-dev`,
  default port 10818, "Dev build" under the window title). Open and close only that one.
- Address it by its own name or bundle id: `pkill -f "V2MacDev.app/Contents/"`,
  `osascript -e 'tell application id "io.github.lordversa.v2mac.dev" to quit'`, System Events
  `process "V2MacDev"`. Never `pkill V2Mac`, `tell application "V2Mac"`, or the release bundle id.
- If a check really needs the installed app restarted, ask the user to do it.
- The dev instance shares `/var/run/v2mac-tun-<uid>` with the installed app: do not turn TUN mode on in it.

## Releasing
- A release is made by pushing a tag, not by a normal commit. The user says when:
  `Scripts/release.sh X.Y.Z` (checks main is clean and pushed, shows the notes, tags `vX.Y.Z`,
  pushes the tag). CI (`.github/workflows/release.yml`) then runs the package tests, builds the DMG
  with the version taken from the tag, and publishes a GitHub Release with the generated notes,
  the DMG and its `.sha256`.
- Never create or push release tags on your own. Run `Scripts/release.sh` only when asked.
- "Actions → Release → Run workflow" is a dry run: it builds and attaches the DMG and notes as an
  artifact and publishes nothing.

## Building and testing
- `Scripts/fetch-core.sh` once, then `xcodegen generate` (the `.xcodeproj` is generated and git-ignored;
  rerun `xcodegen generate` after adding, moving or deleting files under `App/`, or editing `project.yml`).
- App: `xcodebuild -project v2mac.xcodeproj -scheme v2mac -configuration Debug -destination 'platform=macOS' build`
- Package tests: `cd Packages/V2MacCore && swift test`
  - One suite or test: `swift test --filter RoutingTests` / `swift test --filter RoutingTests/bypassRules`
  - Tests use Swift Testing (`@Suite`, `@Test`, `#expect`), not XCTest.
  - Suites tagged `.integration` start the real `Vendor/core/xray` and are silently skipped when it
    is missing, so a green run without `fetch-core.sh` has not exercised them. Some need the network.
- There is no linter and no app-target test bundle. All testable logic belongs in the package.
- Local DMG: `Scripts/make-dmg.sh` (ad-hoc signed, output in `dist/`).
- The scheme and project are still named `v2mac`; the Release product is `V2Mac.app`. Its data folder
  (`~/Library/Application Support/v2mac`) and bundle id (`io.github.lordversa.v2mac`) must not change.
  The Debug product is `V2MacDev.app` (see "Never close the installed app"); it starts with an empty
  data folder, so copy `default.store*` into `v2mac-dev` when a check needs real servers.
- The Xray version is pinned in `Scripts/core.lock`; change `VERSION` and `SHA256` together.
- Debug builds accept launch arguments for scripted checks (`-debugAddSubscription <url>`,
  `-debugActivateFirst YES`, `-debugConnect YES`, `-debugTest tcp|real`, `-debugSwitchTest YES`,
  `-debugLoginItem on|off|status`, `-debugNotices YES`, `-debugListDelivered <seconds>`, …) and print
  `[v2mac-debug]` lines to stdout. See `AppModel.runDebugHooks`.
  - To see that output, run the binary itself instead of `open`:
    `~/Library/Developer/Xcode/DerivedData/v2mac-*/Build/Products/Debug/V2MacDev.app/Contents/MacOS/V2MacDev -debugConnect YES`
  - `-debugDemoData YES` uses an in-memory store filled with made-up servers. Use it for UI checks
    and README screenshots, so no real server ever appears on screen.
  - `-debugSnapshot <path prefix>` makes the app draw each of its open windows, toolbar included,
    into `<prefix>-<n>.png` after 4 seconds (`-debugSnapshotDelay` for longer). Use it to look at a
    UI change: it needs no screen recording permission and works with `-debugDemoData YES`. Glass
    effects are not drawn, but layout, sizes and spacing are exact (2 pixels per point).
- CI (`.github/workflows/ci.yml`, every push) runs the package tests and an unsigned Debug build on
  `macos-26`. Watch it with `gh run watch` after pushing.
- The menu bar glyph PDFs in the asset catalog are generated: edit the SVGs in `Design/` and run
  `Scripts/make-glyphs.sh` (needs `rsvg-convert`).
- `README.fa.md` is the Persian translation of `README.md`. Change both together.

## Architecture

Two layers, with a hard rule between them:

- **`Packages/V2MacCore`**: no UI, no SwiftData, no main-actor code. Only `Sendable` value types
  and `JSONValue` (the package's own JSON tree, used for every Xray config). Everything here is
  covered by `swift test`.
- **`App/`**: SwiftUI views (`Features/`), `@MainActor @Observable` state objects (`State/`),
  SwiftData `@Model`s and `@ModelActor` writers (`Models/`). It maps package value types to models
  and never builds Xray JSON itself.

**From link to running core.** `SubscriptionFetcher` downloads a body, `SubscriptionParser` detects
its shape and hands share links to `ShareLinkParser` (`StreamBuilder` makes `streamSettings`). The
result is a `ParsedProfile`: either one Xray *outbound* object (`.outbound`) or a whole Xray config
(`.custom`), plus a fingerprint that ignores display names. The app stores it as a `Profile` with
the JSON in `configJSON`; `SubscriptionStore` (a `@ModelActor`) reconciles a re-fetch against
existing rows by fingerprint so identity, selection and the active server survive an update. On
connect, `ConfigBuilder` wraps the outbound with the `mixed-in` inbound, routing (`Routing.swift`,
region packs), metrics and, in TUN mode, the `tun-in` inbound (`XrayConfig/Tun.swift`); custom
configs are patched rather than rebuilt. `CoreRunner` writes `run/config.json`, launches `xray` and
publishes state and log lines as `AsyncStream`s.

**Connection settings** (spec 8.4). `RunOptions` also carries `dialer` (TLS fragment and noise:
a `v2mac-dialer` freedom outbound that proxy outbounds reach through `sockopt.dialerProxy`), `dns`
(the core's own resolver) and `apiPort`. Links that say `allowInsecure` keep that flag in the stored
outbound as a marker only: `InsecureTLS` (spec 8.5) pins the server's certificate at connect time when
the setting is on, and `ConfigBuilder.proxyOutbound` always strips the flag, because Xray refuses it. With an API port, picking another share-link server swaps
the `proxy` outbound in the running core (`CoreRunner.replaceOutbound`, which shells out to
`xray api rmo/ado`) instead of restarting it; any other change, and every full config, restarts.

**State objects.** `AppModel` owns the `ModelContainer` and all services and wires them together
with closures in its `init` (e.g. download routes, "reconnect if running"); services do not hold
references to each other. `ConnectionController` is the only owner of `CoreRunner`: it derives the
UI `Phase` from core state, serialises connect/switch/disconnect, restarts after crashes with
backoff, reacts to sleep/network changes via `LifecycleMonitor`, and polls `StatsClient` for rates.
Anything that needs a new config (routing mode, port, region pack, TUN switch) calls
`reconnectIfRunning()`. Settings live in `UserDefaults` behind `Prefs` (`App/Support/AppPaths.swift`),
whose keys must match the `@AppStorage` keys in the settings views (`Features/Settings/`). A new
setting also needs its default in `Prefs.registerDefaults`, or the view and the getter disagree
until the user first changes it.

**Exit check** (spec 9.6). After every connect and live switch `ConnectionController.checkExit` asks
a public IP service through the local proxy (`ExitLookup`) and publishes `exit`; no answer means
traffic is not passing. The bar, the menu bar panel and the menu bar badge (`MenuBarBadge`, one
non-template image, because a menu bar label lays out nothing else) all read that one value.

**Notifications** (spec 12.6). Services never post one themselves: each reports events through a
closure (`onNotice`, `onFailure`, `onFound`, `onFinished`), and `AppModel.wireNotifications` turns
them into text and posts through `NotificationService`. Every kind is a `NotificationKind` case with
its own switch (`notify_<kind>`) in Settings → Notifications. A new one needs the case, a row in
`NotificationSettings`, and a row in the spec table.

**TUN mode** (spec 9.5) runs two Xray processes: the normal core as the user, and a root
*forwarder* with a fixed config (TUN inbound → SOCKS to the core's `tun-in` port). The root helper
is a shell script started once per app session through `osascript`; it only runs root-owned copies
in `/var/run/v2mac-tun-<uid>/` and is controlled by two empty flag files in `run/`. Subscription
and server configs must never reach the root process. Core outbounds are bound to the physical
interface so they do not loop back into the tunnel. `TunHelper` (package) generates the script and
config; `TunController` (app) drives the session.

**Files.** The bundled core is `V2Mac.app/Contents/Helpers/xray` (copied and signed by
`Scripts/embed-core.sh` as a build phase); an in-app core update in
`~/Library/Application Support/v2mac/core/xray` takes precedence (`AppPaths.coreExecutable`).
Layout of the data folder: spec section 14.

**Windows.** `MenuBarExtra` panel, a `main` window, a `logs` window and Settings. The app switches
between `.regular` and `.accessory` activation policy as windows open and close, and quitting goes
through `applicationShouldTerminate` so the core and TUN helper are shut down first.

## Gotchas
- A view in the detail column must not report a minimum width that depends on how much room it was
  given (a `ViewThatFits` in a `safeAreaInset` did): with the inspector open the split view then
  never settles, resizing crawls, and narrow windows crash with "needing another Update Constraints
  pass". `ConnectionBar` takes `minWidth: 0` and picks its tier from measured widths for this reason.
- The table's column state changes on every step of a window resize. Keep it inside `ServerTable`,
  not in `ServerListView`, or the whole list view is rebuilt several times per step.
- A toolbar `Menu` draws its own indicator off-centre and at a different size in a split button, and
  keeps a minimum width whatever its label's frame says. `ToolbarSplitButton` (`ServerListView`)
  lays out icon, divider and chevron by hand for this reason; reuse it for any new toolbar menu.
  Items next to a custom toolbar view merge into one glass capsule unless a `ToolbarSpacer(.fixed)`
  separates them.
- The filesystem is case-insensitive: `v2mac` and `V2Mac` are the same path. Don't `rm` an "old name"
  after a rename. It deletes the new file.
- A running app does not pick up a rebuild. Quit it (⌘Q) and reopen it before judging a change.
- CI uses Xcode 26.6, older than the Xcode 27 used locally. It once crashed on a Bool-taking method
  reference passed to `Binding(set:)`. Prefer closures there, and check CI after pushing.
- Never put subscription URLs, tokens or server details in the repo, commits or tests. Test links
  come from `Tests/V2MacCoreTests/Fixtures.swift` (made-up hosts and keys); add new ones there.
