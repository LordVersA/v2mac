# V2Mac — instructions for Claude

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
- `Scripts/fetch-core.sh` once, then `xcodegen generate` (the `.xcodeproj` is generated and git-ignored).
- App: `xcodebuild -project v2mac.xcodeproj -scheme v2mac -configuration Debug -destination 'platform=macOS' build`
- Package tests: `cd Packages/V2MacCore && swift test`
- The scheme and project are still named `v2mac`; the product is `V2Mac.app`. The data folder
  (`~/Library/Application Support/v2mac`) and bundle id (`io.github.lordversa.v2mac`) must not change.
- Spec: `docs/SPEC.md`.

## Gotchas
- The filesystem is case-insensitive: `v2mac` and `V2Mac` are the same path. Don't `rm` an "old name"
  after a rename. It deletes the new file.
- A running app does not pick up a rebuild. Quit it (⌘Q) and reopen it before judging a change.
- CI uses Xcode 26.6, older than the Xcode 27 used locally. It once crashed on a Bool-taking method
  reference passed to `Binding(set:)`. Prefer closures there, and check CI after pushing.
- Never put subscription URLs, tokens or server details in the repo, commits or tests.
