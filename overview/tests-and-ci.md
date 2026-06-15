# Pine — Build, Test & CI Cheat-Sheet

> Read-only recon. All commands verified against the repo at
> `/Users/fedor/Documents/github.com/batonogov/pine` (commit on 2026-06-15).
> Scheme: **`Pine`** · Project: **`Pine.xcodeproj`** · Deployment: macOS 26+.

---

## 1. Build

| Purpose | Command |
|---|---|
| **Xcode GUI** | Open `Pine.xcodeproj`, ⌘R (run) / ⌘B (build) |
| **CLI build** | `xcodebuild -project Pine.xcodeproj -scheme Pine build` |
| **Select Xcode first (required for CLI on this machine)** | `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` |
| **Type-check a single file (no sudo)** | `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc -typecheck -target arm64-apple-macos26.0 -sdk /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk <file.swift>` |
| **CI-style build (no signing)** | `xcodebuild build -project Pine.xcodeproj -scheme Pine -destination "platform=macOS" -derivedDataPath DerivedData CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=NO` |

Notes:
- SwiftTerm 1.13+ ships Metal shaders; CI runs `xcodebuild -downloadComponent MetalToolchain` before building on GitHub runners.
- CI uses the composite action `.github/actions/select-xcode/action.yml` which sets `DEVELOPER_DIR` and runs `sudo xcode-select -s`. Locally, the `DEVELOPER_DIR=...` prefix achieves the same without sudo.

---

## 2. Unit Tests — `PineTests`

- **Framework:** Swift Testing (`import Testing`, `@Test`, `#expect`).
- **File count:** 218 `.swift` files in `PineTests/`.
- **Test target:** `PineTests.xctest` (enabled in scheme, `skipped="NO"`).

```bash
# Full unit-test suite (DEVELOPER_DIR avoids sudo)
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild test \
    -project Pine.xcodeproj \
    -scheme Pine \
    -destination 'platform=macOS' \
    -only-testing:PineTests

# Single test class (example: GoToLineTests)
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild test \
    -project Pine.xcodeproj \
    -scheme Pine \
    -destination 'platform=macOS' \
    -only-testing:PineTests/GoToLineTests
```

CI quirks (from `.github/workflows/ci.yml` `unit-tests` job):
- Fuzz suites are **skipped** in blocking CI via repeated `-skip-testing:PineTests/Fuzz*Tests` flags (8 classes); they run nightly.
- `-retry-tests-on-failure` is enabled; a post-step parses `TestResults.xcresult` to distinguish real failures from crash-then-retry-all-passed (exit 65).
- Code coverage threshold: **70%** (logic-only; 25 pure-SwiftUI view files excluded from the calculation — listed in `ci.yml`).
- Flaky tests auto-retried once; reported via `.github/scripts/detect_flaky_tests.py` and a PR comment.

---

## 3. UI Tests — `PineUITests`

- **Framework:** XCTest / XCUITest.
- **Base class:** `PineUITestCase` (`PineUITests/PineUITestCase.swift`).
- **File count:** 31 `.swift` files; **30** concrete test classes (all extend `PineUITestCase`).
- **Test target:** `PineUITests.xctest`.

**Launch arguments** (set in `PineUITestCase.setUp`):

| Argument | Purpose |
|---|---|
| `--reset-state` | Clears persisted sessions on launch |
| `-ApplePersistenceIgnoreState YES` | Ignores macOS saved window state |
| `-AppleLanguages (en)` | Forces English locale (predictable menu names) |
| `-AppleLocale en_US` | Forces US English locale |

**Environment variable** (set per-test, not in base `setUp`):

| Variable | Purpose |
|---|---|
| `PINE_OPEN_PROJECT=<path>` | Opens a project without the file dialog (used because macOS treats bare launch-arg paths as files to open) |
| `PINE_SEARCH_QUERY=<q>` | Pre-fills project search (used by `launchWithProjectAndSearch`) |

```bash
# Full UI suite locally
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild test \
    -project Pine.xcodeproj \
    -scheme Pine \
    -destination 'platform=macOS' \
    -only-testing:PineUITests
```

**7 CI shards** (matrix in `ci.yml`, `ui-tests` job; balanced ±3 tests):

| # | Shard name | Test classes |
|---|---|---|
| 1 | Terminal | TerminalTests, SidebarFolderClickTests, TerminalMenuTests |
| 2 | Welcome & Session | WelcomeWindowTests, ToggleCommentTests, BlameViewTests, MinimapTests, DiffNavigationUITests, SessionRestoreTests |
| 3 | Navigation | GoToLineTabOverflowExternalChangesUITests, QuickOpenUITests, EditorTabNavigationTests |
| 4 | Editor Chrome | EditorWindowTests, ScreenshotTests, BranchSwitcherTests, CheckForUpdatesTests |
| 5 | Files & Save | EditorSaveFlowTests, HCLFormatOnSaveTests, DeleteTests, SidebarRenameTests, SidebarFileOperationsTests |
| 6 | Search & Panes | SidebarSearchTests, DuplicateTests, SplitPaneLifecycleTests, FontSizeTests |
| 7 | Security & Layout | GitignoreFilterTests, SymlinkSecurityUITests, MultiWindowTests, InlineRenameAlignmentTests, LineNumberGutterUITests |

A `verify-ui-shards` job (ubuntu-latest) fails CI if a new `PineUITestCase` subclass is added but not assigned to a shard (`ScreenshotTests` is exempted from the check but is actually sharded in #4).

---

## 4. Performance Tests — `PinePerformanceTests`

- **Framework:** XCTest `measure {}` blocks.
- **File count:** 9 `.swift` files (8 test classes + `PerformanceTestHelpers.swift`).
- **Test target:** `PinePerformanceTests.xctest` (enabled in scheme, `skipped="NO"`, so ⌘U runs it locally).
- **Baselines:** `PinePerformanceTests/baselines.json` (threshold: 15% regression).
- **Regression detector:** `.github/scripts/check_perf_regression.py`.

```bash
# Run locally
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild test \
    -project Pine.xcodeproj \
    -scheme Pine \
    -destination 'platform=macOS' \
    -only-testing:PinePerformanceTests
```

**CI triggers** (all opt-in; excluded from blocking CI because `-only-testing:` filters skip it):
- **On-demand in `ci.yml`:** `workflow_dispatch` with `run_performance_tests: true`, or PR labeled `perf`.
- **Nightly:** `.github/workflows/nightly-perf.yml` — cron `0 3 * * *` UTC; uploads `PerformanceResults.xcresult` (30-day retention); auto-creates a `bug,performance,testing` issue on regression.

Test classes: `FoldRangeCalculatorPerformanceTests`, `SyntaxHighlighterPerformanceTests`, `ProjectSearchPerformanceTests`, `GitStatusParserPerformanceTests`, `MinimapRenderPerformanceTests`, `ScrollPerformanceTests`, `EditorStressTests`, `EditRehighlightPerformanceTests`.

---

## 5. SwiftLint

- **Config:** `.swiftlint.yml` (repo root).
- **Pinned version:** `0.63.2` (CI env `SWIFTLINT_VERSION`, with SHA256 pin `dd1017c...`).
- **CI runs:** `swiftlint --strict` on `ubuntu-latest` (native Linux binary).
- **Local:** `brew install swiftlint`; runs as a build phase.

```bash
# Local lint
swiftlint

# If sourcekitd crashes, prefix DEVELOPER_DIR:
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swiftlint
```

Notable config: `line_length` warning 150 / error 200; `trailing_comma`, `todo`, `file_length`, `cyclomatic_complexity` disabled; opt-ins include `force_unwrapping`, `empty_count`, `closure_spacing`.

CI also runs `.github/scripts/check_nonisolated.py` (and its own unit tests) to enforce `nonisolated` on background-queue types (issues #693/#699).

---

## 6. Git Hooks

```bash
# Run once after cloning:
git config core.hooksPath .githooks
git config merge.ours.driver true
```

- **Hook:** `.githooks/pre-commit` — runs `scripts/normalize-xcstrings.sh`, which unstages cosmetic-only (whitespace/key-reorder) changes to `Pine/Localizable.xcstrings`.
- **`merge.ours.driver true`** — makes `Localizable.xcstrings` conflicts auto-resolve to the local side.
- Helper scripts in `scripts/`: `normalize-xcstrings.sh` (check/unstage), `reset-cosmetic-xcstrings.sh` (revert cosmetic diffs), `test-normalize-xcstrings.sh` (tests), `update-screenshots.sh`.

---

## 7. Snapshot Testing

- **Harness:** `PineTests/SnapshotTests/SnapshotHarness.swift` (zero-dependency; renders via `NSHostingView` → `NSBitmapImageRep` at 1× backing scale; mean-absolute RGBA diff, tolerance `0.01`).
- **Reference PNGs:** `PineTests/SnapshotTests/__Snapshots__/` — **30 PNGs** across light/dark/deep variants.
- **Test suites (7):** `WelcomeViewSnapshotTests`, `BranchSwitcherSnapshotTests`, `GoToLineViewSnapshotTests`, `BreadcrumbPathBarSnapshotTests`, `EditorTabItemSnapshotTests`, `StatusBarViewSnapshotTests`, `IndentGuidesYAMLSnapshotTests` (+ `MeanAbsoluteDiffTests` for the diff math).

```bash
# Run one snapshot suite
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild test \
    -project Pine.xcodeproj \
    -scheme Pine \
    -destination 'platform=macOS' \
    -only-testing:PineTests/WelcomeViewSnapshotTests

# Update / record baselines (overwrites references, always passes):
#   Set PINE_RECORD_SNAPSHOTS=1 in the Pine scheme's Test action, or pass as trailing KEY=VALUE:
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild test ... PINE_RECORD_SNAPSHOTS=1
```

On failure the harness writes `<name>.actual.png` next to the reference; first-ever run writes a baseline and fails (no silent baseline adoption).

---

## 8. CI Workflows (`.github/workflows/`)

| File | Name | Trigger | What it does |
|---|---|---|---|
| `ci.yml` | CI | PR/push to `main`, `workflow_dispatch`, PR `labeled` | **Main pipeline.** Jobs: `lint` (SwiftLint + nonisolated check), `build` (build-for-testing + smoke test + archive), `unit-tests` (coverage ≥70%, flaky detection, PR comment), `verify-ui-shards`, `ui-tests` (7 parallel shards + flaky summary), `performance-tests` (opt-in via `perf` label / dispatch), `fuzz-tests` (opt-in via `fuzz` label). All third-party actions pinned by SHA. |
| `release-please.yml` | Release Please | Push to `main` | `googleapis/release-please-action@v4` opens/updates a Release PR using `release-please-config.json` + `.release-please-manifest.json` (Conventional Commits). Uses `RELEASE_PLEASE_TOKEN` PAT. |
| `release.yml` | Release | Tag `v*` | Build → code-sign (Developer ID) → notarize (`notarytool`) → staple → DMG → Sparkle `sign_update` (EdDSA) → `appcast.xml` → GitHub Release upload → Homebrew tap bump. |
| `nightly-perf.yml` | Nightly Performance Tests | Cron `0 3 * * *` UTC, `workflow_dispatch` | Runs `PinePerformanceTests`, uploads xcresult (30-day), regression check vs `baselines.json`, opens issue on regression/failure. |
| `nightly-fuzz.yml` | Nightly Fuzz Tests | Cron `0 4 * * *` UTC, `workflow_dispatch` | Runs 8 `Fuzz*Tests` suites (2-min time limit each), uploads xcresult (14-day), opens issue on failure. |
| `screenshots.yml` | Update Screenshots | `workflow_dispatch`, `release: published` | Runs `scripts/update-screenshots.sh` (UI screenshot tests), commits canonical PNGs to `assets/`. |
| `docs.yml` | Docs | PR touching `*.md` / `docs/**` | No-op check (skips build for docs-only PRs). |
| `claude.yml` | Claude Code | `@claude` mention in issues/PRs/comments | Runs `anthropics/claude-code-action@v1`. |
| `claude-code-review.yml` | Claude Code Review | PR opened/synchronize/ready/reopened | Auto code review via Claude plugin. |

Reusable composite action: `.github/actions/select-xcode/action.yml` — selects newest stable Xcode under `/Applications`, sets `DEVELOPER_DIR`, runs `sudo xcode-select -s`.

---

## 9. Release Pipeline

**Flow:** Conventional Commit on `main` → **Release Please** opens a Release PR (bumps `version.txt` + `.release-please-manifest.json`, updates `CHANGELOG.md`) → merge the Release PR → Release Please creates tag `v<x.y.z>` (current: **1.27.2**) → tag triggers **`release.yml`**.

**`release.yml` steps:**
1. Checkout + select Xcode + download Metal toolchain.
2. Import signing cert (`CERTIFICATE_P12` / `CERTIFICATE_PASSWORD`) into temp keychain.
3. Set `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` from tag + run number.
4. `xcodebuild archive` (Developer ID Application, Manual signing, Hardened Runtime).
5. `xcodebuild -exportArchive` (developer-id method).
6. Notarize via `xcrun notarytool submit --wait`, then `xcrun stapler staple`.
7. Create DMG (`hdiutil`, UDZO, with `/Applications` symlink).
8. Sign DMG with Sparkle EdDSA (`sign_update`, `SPARKLE_PRIVATE_KEY`).
9. Generate release-notes HTML (`changelog_to_html.py`) + `appcast.xml` (validated).
10. Upload DMG + `appcast.xml` to GitHub Release (`gh release`).
11. Clone `batonogov/homebrew-tap`, bump `Casks/pine-editor.rb` version + sha256, push.
12. Cleanup keychain (`always()`).

**Required secrets:**

| Secret | Used for |
|---|---|
| `CERTIFICATE_P12` | Developer ID signing certificate (base64) |
| `CERTIFICATE_PASSWORD` | P12 password |
| `APPLE_ID` | Notarization |
| `APPLE_ID_PASSWORD` | App-specific password for notarytool |
| `APPLE_TEAM_ID` | Signing team + notarization |
| `TAP_GITHUB_TOKEN` | Push to `batonogov/homebrew-tap` |
| `RELEASE_PLEASE_TOKEN` | PAT (`contents: write` + `pull-requests: write`) — default `GITHUB_TOKEN` won't trigger downstream `release.yml` |
| `SPARKLE_PRIVATE_KEY` | EdDSA DMG signature for auto-update `appcast.xml` |
| `CLAUDE_CODE_OAUTH_TOKEN` | Claude GitHub Actions (not release) |

**Install (end users):** `brew tap batonogov/tap && brew install --cask pine-editor`

---

## Quick Reference — Most-Used Commands

```bash
# ── Setup (once) ──
git config core.hooksPath .githooks && git config merge.ours.driver true
brew install swiftlint

# ── Build ──
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project Pine.xcodeproj -scheme Pine build

# ── Unit tests ──
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild test -project Pine.xcodeproj -scheme Pine \
    -destination 'platform=macOS' -only-testing:PineTests

# ── One unit-test class ──
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild test -project Pine.xcodeproj -scheme Pine \
    -destination 'platform=macOS' -only-testing:PineTests/GoToLineTests

# ── UI tests ──
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild test -project Pine.xcodeproj -scheme Pine \
    -destination 'platform=macOS' -only-testing:PineUITests

# ── Performance tests ──
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild test -project Pine.xcodeproj -scheme Pine \
    -destination 'platform=macOS' -only-testing:PinePerformanceTests

# ── Lint ──
swiftlint            # or: DEVELOPER_DIR=... swiftlint

# ── Type-check one file ──
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc \
  -typecheck -target arm64-apple-macos26.0 \
  -sdk /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk \
  <file.swift>

# ── Update snapshot baselines ──
# Add PINE_RECORD_SNAPSHOTS=1 to the scheme Test action, or as trailing arg:
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild test -project Pine.xcodeproj -scheme Pine \
    -destination 'platform=macOS' -only-testing:PineTests/WelcomeViewSnapshotTests \
    PINE_RECORD_SNAPSHOTS=1
```
