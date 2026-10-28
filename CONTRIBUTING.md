# Contributing to Xenia

Thanks for helping. Bug reports, fixes and features are all welcome. For anything large (a new
screen, a change to how the core and the apps talk), open an issue first so we can agree on the
shape before you build it.

Be kind and assume good intent. The [Contributor Covenant](https://www.contributor-covenant.org/version/2/1/code_of_conduct/)
applies here.

## What you need

- A Mac with Apple silicon (the apps build for arm64 only) and **Xcode 27**.
- **Rust** through [rustup](https://rustup.rs), 1.96 or later, with the Apple targets:

  ```bash
  rustup target add aarch64-apple-ios aarch64-apple-ios-sim
  ```

- **XcodeGen**, which writes the Xcode project from `apple/project.yml`: `brew install xcodegen`.
- **Node 22** or later, for the test server's scripts and the push gateway.
- For the local test server: [uv](https://docs.astral.sh/uv/) (`brew install uv`), or Python 3.10
  or later. `scripts/dev/homeserver.sh` installs Synapse with it the first time it runs, into
  `~/.cache/matrix-client/synapse`.

## Building

```bash
scripts/dev/homeserver.sh             # Synapse on http://localhost:8008
node scripts/dev/seed-homeserver.mjs  # test accounts and conversations
cd apple && xcodegen                  # generates Xenia.xcodeproj
open Xenia.xcodeproj                  # run "Xenia macOS" or "Xenia iOS"
```

Xcode builds the Rust core as the first step of every build, so there's nothing to run by hand.
The first build takes a few minutes. Debug builds start at `localhost:8008`; sign in as `luke`
with the password in `scripts/dev/seed-homeserver.mjs`.

Your Apple developer team stays out of the repository: copy `apple/Local.xcconfig.example` to
`apple/Local.xcconfig` (git ignores it), set your team ID and a bundle ID your team owns, and run
`xcodegen` again. Xenia's push gateway only delivers to Xenia's own bundle ID, so builds under
yours notify while the app runs. On the simulator, run the local gateway with
`XENIA_BUNDLE_ID=<your bundle ID> node scripts/dev/push-gateway.mjs` to test pushes.

Run `xcodegen` whenever you add, move or remove a Swift file. The Xcode project itself isn't
committed.

### TestFlight

```bash
scripts/apple/testflight.sh             # archives both apps and uploads them to App Store Connect
scripts/apple/testflight.sh ios         # just the iPhone app
scripts/apple/testflight.sh --no-upload # signs and exports to target/testflight, uploads nothing
```

It signs with the team in `apple/Local.xcconfig` and uploads as the account signed in to Xcode,
or with an App Store Connect API key when `ASC_KEY_PATH`, `ASC_KEY_ID` and `ASC_ISSUER_ID` are
set. Xcode picks each upload's build number, so there's nothing to bump. The app record has to
exist in App Store Connect first, under the bundle ID being built.

## Tests

```bash
cargo test -p xenia-core
cargo clippy --workspace --all-targets -- -D warnings
xcodebuild test -project apple/Xenia.xcodeproj -scheme "Xenia macOS"
(cd services/push-gateway && npm test)
```

CI runs all of these except the Swift tests, plus `cargo fmt --check` and a build of the Mac app.
New rules in the core come with tests in the same file; new copy comes with a test in
`apple/Tests/CopyTests.swift` when its wording depends on data (counts, names, lists).

## How the code is organized

Read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) first. Three rules matter most:

- **Decisions live in Rust.** If both platforms would write the same `if`, it belongs in
  `crates/xenia-core`, and the apps receive records that are ready to draw.
- **Words live in Swift.** The core never builds a sentence. Every string a person reads is in
  `apple/Shared/Copy/` (or `SettingsCopy.swift` for Settings), never inline in a view. Use
  formatters for lists, counts, dates and sizes instead of joining strings.
- **Platform services come in through traits** such as `SecretStore`. The core never calls a
  platform API.

## Style

- Rust: `cargo fmt` (settings in `rustfmt.toml`) and `cargo clippy` with no warnings.
- Swift: Swift 6 with strict concurrency. Match the code around you: its naming, its structure,
  how much it comments.
- Comments are few and short, and explain why, not what. No commented-out code or leftover
  logging.
- Copy reads like Apple wrote it: plain, specific, and in sentence case. Errors say what happened
  and what to do next.
- Mind the details: light and dark, larger text sizes, VoiceOver labels, Reduce Motion, and
  nothing animating while the app is idle.

## Pull requests

1. Fork the repository and make a branch from `main`.
2. Keep each pull request to one change. Refactors go in their own.
3. Write commit messages as a short imperative sentence ("Add read receipts to threads").
4. Fill in the template: what changes, why, and how you tested it. Screenshots for anything
   visible, on iPhone and Mac if both changed.
5. Make sure CI passes.

By contributing, you agree that your work is released under the [GNU General Public License v3.0](LICENSE).
