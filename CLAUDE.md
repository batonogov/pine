# CLAUDE.md

Guidance for AI coding agents (Claude Code, pi, and others) working in this repository.

## Project Overview

Pine is a minimal native macOS code editor built with SwiftUI + AppKit. Its minimum deployment target is macOS 26.0 (Tahoe), and compatibility work must cover both macOS 26 and the current macOS 27 beta.

**Dependencies** (via Xcode SPM):
- [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) — terminal emulator
- [Sparkle](https://sparkle-project.org/Sparkle) — auto-updates
- [swift-markdown](https://github.com/swiftlang/swift-markdown) — markdown preview rendering
- No other third-party dependencies

## Build & Run

- **Xcode 26+** required. Keep `MACOSX_DEPLOYMENT_TARGET` at `26.0`; macOS 27 is an additional compatibility target, not a new minimum requirement
- Test compatibility-sensitive changes on both macOS 26 and the current macOS 27 beta when those runtimes are available. Do not fix a macOS 27 regression by breaking or raising the macOS 26 baseline
- For OS- or SDK-specific reports, include the complete output of `sw_vers`, `xcodebuild -version`, `xcrun --sdk macosx --show-sdk-version`, and `xcrun --sdk macosx --show-sdk-build-version`; labels such as "macOS 27" or "Xcode beta" are not precise enough
- Open `Pine.xcodeproj` in Xcode, build and run (Cmd+R)
- CLI build: `xcodebuild -skipPackagePluginValidation -project Pine.xcodeproj -scheme Pine build` (requires `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`)
- Type-check a single file (no sudo needed): `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc -typecheck -target arm64-apple-macos26.0 -sdk /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk <file.swift>`
- **Package plugins:** SwiftTerm 1.19+ uses the pinned `SwiftTermBuildInfoPlugin`. Non-interactive `xcodebuild` invocations must pass `-skipPackagePluginValidation`; keep this flag on CI, nightly, release, screenshot, and release-smoke build paths. Because the flag applies to every package plugin, continue pinning and reviewing all SPM revisions in `Package.resolved`
- **Xcode project format:** Uses `PBXFileSystemSynchronizedRootGroup` (objectVersion 77) — new `.swift` files placed in `Pine/`, `PineTests/`, or `PineUITests/` are automatically picked up by Xcode. No manual `project.pbxproj` edits needed
- **Git hooks:** Run once after cloning: `git config core.hooksPath .githooks && git config merge.ours.driver true`. Enables pre-commit hook that auto-unstages cosmetic-only changes to `Localizable.xcstrings` (Xcode build artifacts) and `ours` merge driver for xcstrings conflicts
- **SwiftLint:** `brew install swiftlint` — runs as a build phase; config in `.swiftlint.yml`. CI pins SwiftLint 0.65.1 — the same version `brew install swiftlint` gives you locally, so a clean local run means a clean CI run (bump both `SWIFTLINT_VERSION` and `SWIFTLINT_SHA256` in `.github/workflows/ci.yml` together). Run `swiftlint` before every commit and fix all warnings/errors. If `swiftlint` crashes with `sourcekitdInProc` error, prefix with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`

## Testing

- **Unit Tests:** `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -skipPackagePluginValidation -project Pine.xcodeproj -scheme Pine -destination 'platform=macOS' -only-testing:PineTests`
- Run a single test class: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -skipPackagePluginValidation -project Pine.xcodeproj -scheme Pine -destination 'platform=macOS' -only-testing:PineTests/GoToLineTests`
- **UI Tests:** `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -skipPackagePluginValidation -project Pine.xcodeproj -scheme Pine -destination 'platform=macOS' -only-testing:PineUITests`
- **Performance Tests:** `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -skipPackagePluginValidation -project Pine.xcodeproj -scheme Pine -destination 'platform=macOS' -only-testing:PinePerformanceTests` — XCTest `measure {}` benchmarks for FoldRange, SyntaxHighlighter, ProjectSearch, GitStatus. Enabled in default scheme but excluded from CI (opt-in via `perf` label on PR or `workflow_dispatch`)
- Targets: `PineTests` (Swift Testing, 180+ files), `PineUITests` (XCUITest, 41 classes, base class `PineUITestCase`, 7 parallel CI shards), `PinePerformanceTests` (XCTest `measure {}`)
- XCUITest limitations, snapshot-harness details, and the SourceKit-LSP smoke test load from `.claude/rules/` when you open the matching files

## Non-negotiables

These hold before you open any file. The reasoning behind each is in
`.claude/rules/`, which loads when you touch the relevant code.

- **Never block the main thread** with file I/O, regex computation, or git process execution. Background work owns its autorelease pool — prefer `runOnBackground` (`Pine/Concurrency/BackgroundDispatch.swift`) over a raw `DispatchQueue.global().async` (#1509)
- **Never post a `NotificationCenter` notification inside a function holding an `inout` access.** Observers are delivered synchronously; one that writes the same store re-enters the live access and Swift aborts the process (#1066). Return the payload and let the caller post after the scope ends. `scripts/check-no-post-under-inout.py` enforces this at pre-commit and in CI
- **Never rewrite `Localizable.xcstrings` with `json.dump`** or any standard JSON serializer — Xcode's non-standard formatting turns the diff into thousands of lines of noise. Insert translations as targeted text edits
- **Never merge a red PR.** Branch protection blocks it, and a green run is a prerequisite, not a judgment call
- **Generation tokens** (`HighlightGeneration`, `WorkspaceManager.loadGeneration`, `FileSystemWatcher.activeGeneration`) guard every async result — check the token before applying one

## Conventions

- **Conventional Commits** — all commit messages must follow the format: `feat:`, `fix:`, `chore:`, `docs:`, `refactor:`, `perf:`, `test:`. Use `feat!:` or `BREAKING CHANGE:` footer for breaking changes
- **Test coverage** — every new feature or bug fix must include unit tests (and UI tests where applicable). Aim for comprehensive coverage: test public API, edge cases, error paths, boundary conditions, and integration between components. Cover the maximum number of cases — not just the happy path. Do not merge code without corresponding tests
- Uses `@Observable` macro (Swift 5.9+), not ObservableObject/Published
- UI uses semantic system colors (migrated from hardcoded dark theme values)
- macOS 26 SDK renamed `NSColor(sRGBRed:)` → `NSColor(srgbRed:)` (lowercase)

## GitHub Issues

When creating issues, always:
- Create the issue before opening a branch or starting implementation. Never create an issue alongside or after its PR
- Add appropriate labels from the repo's label set (e.g. `enhancement`, `bug`, `editor`, `UX`, `priority: high/medium/low`, etc.)
- Use a clear, concise title
- Include **Summary**, **Motivation**, and **Implementation ideas** sections in the body
- **Always assign the issue to a milestone.** Work is milestone-driven: pick the next task from the current milestone, prioritizing by the `priority:` labels. No milestone = no work.

## Workflow

How the maintainer works day-to-day. Documents intent and handoff conventions for contributors and AI agents.

### Prioritization

- Work is driven by **milestones**. The next task is picked from the active milestone, prioritized by labels (`priority: high` first).
- An issue is filed and assigned to a milestone **before** its branch is created or implementation begins (see `## GitHub Issues`). A PR may only be opened for an existing issue and must reference it.

### Branches & PRs

- **One task = one short-lived branch**, named by type with no issue number: `feat/terminal-scroll`, `fix/gutter-bug`.
- No long-lived feature branches. Nothing is committed directly to `main`.
- PRs are **squash-merged** into `main` (one commit per PR).
- The PR description states **when the branch is ready to merge** — do not merge before that.
- **All CI checks must be green before a PR can be merged.** This is enforced by repository branch protection ("requires all checks to pass", see `.claude/rules/ci-release.md`) — GitHub will refuse the merge button on any non-green PR. Red PRs are never merged. When CI fails due to flakiness or a runner/infrastructure issue that is provably not the diff's fault (e.g. an identical hang reproduces on a screenshots-only PR), the fix is to resolve the failure — rerun, mitigate the flakiness, or fix the code — until a fully green run exists. Do not hand-wave a red check as "not our fault" and call the PR mergeable; a green run is a hard prerequisite, not a judgment call.

### Local development loop

- Code is edited **inside Pine itself**, or via AI agents in the terminal.
- Fast feedback loop: **single-file typecheck** (`swiftc -typecheck`, see `## Build & Run`) — not a full build on every change.
- A full `xcodebuild build` is run **before opening a PR**.
- Run locally: `swiftlint` + the unit tests in `PineTests` that cover the touched area.
- **UI tests (`PineUITests`, 7 shards) run only on CI** — almost never locally.

**Local runs on the macOS 27 beta are not a pass/fail signal** — CI is (#1509). Two known standing differences on that runtime, both unrelated to whatever diff is in the tree: `AgentInboxToolbarButtonSnapshotTests` fails all four cases because the baselines are recorded on the macOS 26 CI runner and the beta renders that view ~3% differently; and `ApplicationLifecycleProcessTests.quitCrashAndRelaunchJourney()` fails with `terminal-child-unavailable` when several agents run `xcodebuild` at once, because its wait for the spawned terminal child is bounded at 5s. Confirm a local failure on an idle machine before blaming a diff for it.

For the crash-report workflow on that runtime, invoke the `macos27-crash-triage` skill.

### Working with AI agents

- Typical handoff: **"реши issue #N"** (solve issue #N) — the agent reads the issue **and all its comments** in full, then plans, implements, writes tests, and opens a PR.
- Agents may freely, without asking: edit code, run single-file typecheck, run unit tests, create branches, open PRs.
- **Explicit confirmation required** for: merging a PR, and anything in the destructive-command list in this file (deletions, force-pushes, infrastructure changes).
- Agents should run unit tests themselves — no need to ask first.
- For a milestone or backlog distributed across subagents, invoke the `agent-swarm` skill — it carries the issue-by-issue authorization flow, the independent review gate, and the merge rules

### Releases

- **No fixed cadence** — release when ready, by merging the Release Please PR.
- Manual work before tagging is kept to a minimum; Release Please handles `version.txt` and `CHANGELOG.md` automatically (see `.claude/rules/ci-release.md`).

## Where the rest of this guidance lives

This file holds what applies before you open a file. Everything else is
scoped so it enters context only when it is relevant.

`.claude/rules/` — loaded automatically when a matching file is read:

| Rule | Loads for | Covers |
|---|---|---|
| `architecture.md` | `Pine/**/*.swift` | Subsystem map, key entry points, type and view conventions |
| `concurrency.md` | `Pine/**`, `PineTests/**` | Threading contract, debounce values, performance thresholds, reentrancy |
| `terminal.md` | `Pine/Terminal/**`, `Pine/QuickTerminal/**` | Metal renderer and fallback, quick terminal, rendering-compatibility passes |
| `ui-tests.md` | `PineUITests/**` | Launch arguments and every XCUITest limitation that has already cost a debugging session |
| `snapshot-tests.md` | `PineTests/SnapshotTests/**` | Harness, backing-scale independence, recording baselines |
| `lsp.md` | `Pine/LSP/**` | SourceKit-LSP smoke test |
| `ci-release.md` | `.github/**`, `scripts/**` | Release Please, CI pipeline, action pinning, dependency maintenance |
| `localization.md` | `Localizable.xcstrings`, `Strings.swift` | The xcstrings format rule and the nine shipped locales |
| `marketing-surfaces.md` | `README.md`, `docs/**`, `assets/**` | Keeping the public product description consistent |

`.claude/skills/` — invoked by name when the task calls for it:

| Skill | Use when |
|---|---|
| `agent-swarm` | Distributing issues across subagents: authorization flow, review gate, merge rules |
| `macos27-crash-triage` | The test host crashes or hangs on the macOS 27 beta (#1509) |

Rules and skills are Claude Code mechanisms. Other agents working in this
repository should treat `.claude/rules/` and `.claude/skills/` as ordinary
markdown and read whichever file matches the work at hand.
