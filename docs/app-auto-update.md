# App auto-update (workspace Phase 14)

**Goal:** V2Mac updates itself by default: it downloads a new release in the background, fetching only
the files that changed, and installs it on the next quit or with Restart Now. The Xray core follows its
own pinned range instead of riding along with every app update. The menu bar icon shows when an update
is available and when one is ready. Settings can turn automatic install off.

## Today
- Spec 11.3: a daily check shows **Update Now** in the panel and Settings. Pressing it downloads the full
  DMG (28 MB) with its `.sha256` and Ed25519 `.sig`, checks them, copies the app out, verifies code
  signature, bundle id and version, quits, and a detached script swaps the bundle and reopens it.
  Homebrew installs go through `brew upgrade` instead (`BrewUpdater`).
- Spec 11.1: the core (`Contents/Helpers/xray`, 31 MB, plus 6 MB of `.dat`) ships in the bundle, pinned
  in `Scripts/core.lock`. A manual "Check for Update" installs a newer core into `core/`, which is used
  in place of the bundled one.
- Phase 11 built per-file delta updates for the sandbox: `SandboxManifest` (`files.json`), plan
  copy/patch/full by the installed file's SHA-256, `ResumableDownload`, `/usr/bin/bspatch`.

## Decisions
| Topic | Decision |
|---|---|
| Default | Automatic install **on** for new and existing users. Settings → General: "Install updates automatically", under the existing check switch (and dimmed when that is off). Off = today's behaviour: notify, Update Now. |
| When | Download and verify in the background after the daily check. Stage the verified app in `updates/V2Mac.app`. Swap it in when the app quits (the existing detached script, without reopening). **Restart Now** in the panel and Settings does it immediately (quit, swap, reopen; the VPN drops for a few seconds). If the swap at quit didn't happen (logout killed the script), the next launch swaps before starting the core and relaunches. |
| Delta | Reuse the sandbox format and code: release CI publishes `files.json` for `V2Mac.app` with per-file zips and bsdiff patches from the last 3 releases for big files (main executable, `xray`). Generalize `SandboxManifest`/`SandboxFiles` into one bundle manifest type used by both; no second implementation. The rebuilt bundle is byte-identical to the release's, `_CodeSignature` included, so its signature stays valid. |
| Trust | `files.json` gets an Ed25519 `.sig` from the existing `UPDATE_SIGNING_KEY` and `AppInstaller.updateKey`. Every zip, patch and patch result is checked against the signed manifest before use, then the staged app gets the same code signature, bundle id and version checks as today. No new key. Unsigned or invalid → nothing is staged. |
| Fallback | A failed patch downloads that file in full. Any other failure → the full DMG path from today. Nothing is touched outside `updates/` until the swap. |
| Core split | The DMG keeps a bundled core so a fresh install works with no network. The app's Info.plist carries the pinned core (version, SHA-256) and a compatible range (`V2MacCoreMin`, `V2MacCoreMaxExclusive`). At launch, `core/xray` is used if its version is in range, else the bundled one. If neither is in range, the pinned core is downloaded in the background with the existing `CoreUpdater` (hash-checked, `xray run -test`). The delta planner also counts `core/xray` as an installed file, so a core already fetched on its own is copied, never downloaded twice. |
| Homebrew | The cask gets `auto_updates true`; the app updates itself like any other install. `BrewUpdater` and its spec paragraph are removed. |
| Icon | Two badges on the menu bar glyph (outline and filled each): **available** (found, not yet downloaded or auto-install off) and **ready** (staged, installs on quit). The failed-state warning badge wins over both. After an update installs, one notification: "V2Mac updated to X". |
| Debug builds | Never stage or swap. `-debugAppUpdate <files.json url>` drives the flow against a locally served release, and `-debugUpdateBadge available\|ready` shows a badge for snapshots. |

## Release files (per app tag, beside the DMG)
- `files.json` + `files.json.sig`, same shape as the sandbox manifest (`version`, `files[]` with `path`,
  `sha256`, `size`, `executable`, `zip`, `patches[]`).
- One `<file>.zip` per bundle file, `<file>.from-<old version>.bsdiff` per patch.
- The DMG, `.sha256` and `.sig` stay: fresh installs, Homebrew, the fallback.

## Tasks
| # | Task | Repo |
|---|---|---|
| U0 | **Spike.** (a) Two Release builds of the same commit give byte-identical bundles (main executable, `_CodeSignature`, `Assets.car`); fix what isn't. (b) Does the bundle hold only regular files (no symlinks)? (c) bsdiff size for the main executable and `xray` between two real releases. **Go for patches** if under 30 % of the zip; otherwise U2 ships per-file only. | app |
| U1 | Generalize `SandboxManifest`/`SandboxFiles` into a bundle manifest type (sandbox keeps working, its tests pass); add the manifest signature check. | app |
| U2 | Release CI: per-file zips, `files.json`, `.sig`, patches from the last 3 releases (skip a patch over 60 % of its zip). | app |
| U3 | `UpdateService`: auto-download and stage, apply on quit, Restart Now, swap-on-launch fallback, "updated" notification; Settings toggle (default on). Remove the Homebrew route. Package tests for planning and the state machine. | app |
| U4 | Core range: Info.plist keys written from `core.lock` at build time, launch-time selection, background fetch of the pinned core when out of range, `core/xray` as a delta source. | app |
| U5 | Menu bar badges: SVGs in `Design/`, `make-glyphs.sh`, panel and Settings rows for available/ready. | app |
| U6 | Spec 11.1/11.3/12.2, README ×4, wiki updates page ×4, String Catalogs ×3; cask `auto_updates true`. | app, wiki, homebrew-tap |
| U7 | End to end with the dev build: release N installed → N+1 served locally: only changed files and patches fetched, staged, swapped on quit; break a patch hash → full file; break the manifest sig → nothing staged; core out of range → pinned core fetched. | app |

## Status (2026-10-27)
Implemented locally; not released. The "Done when" needs the first release built with it (N) and the next one (N+1).
- **U0 spike**, on the real 1.2.0 and 1.2.1 DMGs: (a) two CI builds already agree on `xray`, `Assets.car`, the
  geo files, strings and `AppIcon.icns`; what differs is code (main executable, CLI, privileged helper, Control
  extension), `Info.plist`, `Metadata.appintents` and `_CodeSignature`, so nothing needed fixing. (b) Only
  regular files, no links, no empty folders. (c) Main executable: patch 355 KB against a 3.9 MB zip (9 %); the
  CLI, helper and extension patch to under 1 KB. **Go for patches.** From 1.0.0/1.1.0 the main executable
  patches to about 1.9 MB (48 %).
- **U1** `BundleManifest` (`Updater/BundleManifest.swift`) is the one manifest type and builder; `SandboxFiles`
  uses it. `AppInstaller.prepareDelta` checks `files.json.sig`.
- **U2** `Scripts/package-update.sh` (patches from the last 3 releases' DMGs, any changed file of 64 KB or more,
  skipped over 60 % of its zip); `release.yml` publishes `dist/update/*` with the signed `files.json`.
  On 1.2.1: 35 files, 20 patches.
- **U3** `UpdateService`: stage in `updates/`, swap on quit (`swapOnQuit`), Restart Now, swap on launch,
  "V2Mac updated to X", Settings toggle `installAppUpdates`. `BrewUpdater` removed.
- **U4** `Scripts/pin-core-info.sh` (post-build) writes the `V2MacCore…` keys from `core.lock` (`MIN`,
  `MAX_EXCLUSIVE` added there); `CorePin`; `core/xray.version`. Counting `core/xray` as a delta source rarely
  helps: an upstream core re-signed ad hoc is not byte-identical to the one in a release, so it only matches
  when the same bytes were installed.
- **U5** Four badged glyphs in `Design/` (`menubar-glyph-<outline|filled>-<available|ready>.svg`).
- **U6** spec 9.1, 11.1, 11.3, 12.2, 12.6, 13, 14; READMEs; wiki Installation ×4; cask `auto_updates true`
  (committed in the tap, not pushed: push it with the release).
- **U7** with `-debugAppUpdate`, real 1.2.0 → locally served 1.2.1 signed with a test key: 365 KB downloaded
  instead of the 27.5 MB DMG, result byte-identical to 1.2.1 with a valid code signature; a broken main-executable
  patch → that file in full (4.3 MB), still identical; a broken `files.json.sig` → nothing built; a dev copy whose
  range excludes the bundled core fetched and installed the pinned core once. The swap itself (on quit, without
  reopening) is covered by package tests; it is never run against the installed app.

## Done when
A release installed by DMG and one installed by Homebrew both update to the next release by themselves,
downloading less than the DMG when only app code changed, with the badges and toggle working, and U7 passes.
