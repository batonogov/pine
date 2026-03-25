# Contributing to Pine

Thank you for your interest in contributing to Pine! This guide will help you set up the development environment and understand the project workflow.

## Prerequisites

- **macOS 26** (Tahoe) or later
- **Xcode 26+** (includes Swift 5.9+ with `@Observable` macro)
- **SwiftLint** — install via Homebrew:

  ```bash
  brew install swiftlint
  ```

## Getting Started

### 1. Clone the repository

```bash
git clone https://github.com/batonogov/pine.git
cd pine
```

### 2. Set up git hooks

Run once after cloning to enable the pre-commit hook and merge driver:

```bash
git config core.hooksPath .githooks
git config merge.ours.driver true
```

The pre-commit hook auto-unstages cosmetic-only changes to `Localizable.xcstrings` (Xcode build artifacts). The `ours` merge driver avoids conflicts in xcstrings files.

### 3. Open in Xcode

Open `Pine.xcodeproj` in Xcode. SPM dependencies (SwiftTerm, Sparkle, swift-markdown) resolve automatically.

### 4. Build and run

Press **Cmd+R** in Xcode, or build from the command line:

```bash
xcodebuild -project Pine.xcodeproj -scheme Pine build
```

> If `xcodebuild` can't find the SDK, run `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` first.

New `.swift` files placed in `Pine/`, `PineTests/`, or `PineUITests/` are automatically picked up by Xcode (the project uses `PBXFileSystemSynchronizedRootGroup`). No manual `project.pbxproj` edits needed.

## Running Tests

### Unit tests

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild test -project Pine.xcodeproj -scheme Pine \
  -destination 'platform=macOS' -only-testing:PineTests
```

Run a single test class:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild test -project Pine.xcodeproj -scheme Pine \
  -destination 'platform=macOS' -only-testing:PineTests/GoToLineTests
```

### UI tests

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild test -project Pine.xcodeproj -scheme Pine \
  -destination 'platform=macOS' -only-testing:PineUITests
```

### Linting

Run SwiftLint before every commit and fix all warnings and errors:

```bash
swiftlint
```

If SwiftLint crashes with a `sourcekitdInProc` error, prefix the command:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swiftlint
```

## Project Architecture

Pine follows **MVVM** with SwiftUI views backed by AppKit via `NSViewRepresentable`.

- **`ProjectManager`** (`@Observable`) is the central state object managing file tree, editor tabs, terminal tabs, and git status
- **`CodeEditorView`** wraps NSScrollView + custom `GutterTextView` (NSTextView subclass) for the code editor
- **`TerminalContentView`** wraps SwiftTerm's `LocalProcessTerminalView` for the integrated terminal
- **`SyntaxHighlighter`** loads JSON grammar files from `Pine/Grammars/` for syntax highlighting
- Menu commands are defined in `PineApp.swift` and dispatched via `NotificationCenter`

For more details, see the Architecture section in [CLAUDE.md](CLAUDE.md).

## Making Changes

### Branching

Create a feature branch from `main`:

```bash
git checkout -b feat/my-feature
```

### Commit conventions

All commits must follow [Conventional Commits](https://www.conventionalcommits.org/):

| Prefix | Use case |
|---|---|
| `feat:` | New feature |
| `fix:` | Bug fix |
| `docs:` | Documentation only |
| `refactor:` | Code restructuring without behavior change |
| `perf:` | Performance improvement |
| `test:` | Adding or updating tests |
| `chore:` | Build, CI, tooling changes |

Use `feat!:` or a `BREAKING CHANGE:` footer for breaking changes.

Examples:

```
feat: add Python syntax grammar
fix: prevent crash when opening empty file
docs: update CONTRIBUTING.md with test instructions
```

### Test requirements

Every new feature or bug fix **must** include tests:

- **Unit tests** (`PineTests/`) using Swift Testing framework — cover public API, edge cases, error paths, and boundary conditions
- **UI tests** (`PineUITests/`) using XCTest/XCUITest where applicable

Do not submit a PR without corresponding tests. Aim for comprehensive coverage, not just the happy path.

### Code style

- Use `@Observable` macro, not `ObservableObject`/`@Published`
- Use semantic system colors, not hardcoded color values
- Strings go in `Strings.swift`, menu icons in `MenuIcons.swift`
- Never reserialize `Localizable.xcstrings` with JSON serializers — make targeted text insertions to preserve Xcode formatting

### Adding a new language grammar

Add a JSON file to `Pine/Grammars/` following the format of existing grammars. It will be picked up automatically by `SyntaxHighlighter` at startup.

## Submitting a Pull Request

1. Make sure all tests pass and `swiftlint` reports no issues
2. Push your branch and open a PR against `main`
3. Fill in the PR description: what changed, why, and how to test it
4. CI will run lint, build, unit tests, and UI tests automatically
5. All checks must pass before merge

### CI pipeline

The CI runs: Lint -> Build -> Unit Tests (with coverage) -> UI Tests (6 parallel shards). Code coverage threshold is 70% (logic-only, SwiftUI view files excluded).

## Finding Work

Check the [issue tracker](https://github.com/batonogov/pine/issues) for open issues. Issues labeled [`good first issue`](https://github.com/batonogov/pine/labels/good%20first%20issue) are a great starting point for new contributors.

## Questions?

Open a [discussion](https://github.com/batonogov/pine/discussions) or comment on the relevant issue. We are happy to help!
