# Contributing to Pine

Thank you for your interest in contributing to Pine! This guide will help you set up the development environment and follow project conventions.

## Prerequisites

| Tool | Version | Install |
|------|---------|---------|
| macOS | 26 (Tahoe)+ | -- |
| Xcode | 26+ | Mac App Store or [developer.apple.com](https://developer.apple.com/xcode/) |
| Homebrew | latest | [brew.sh](https://brew.sh) |
| SwiftLint | latest | `brew install swiftlint` |
| Git | latest | Included with Xcode Command Line Tools |

## Clone & Setup

```bash
git clone https://github.com/batonogov/pine.git
cd pine

# Configure git hooks (required -- runs once)
git config core.hooksPath .githooks
git config merge.ours.driver true
```

The pre-commit hook auto-unstages cosmetic-only changes to `Localizable.xcstrings` (Xcode build artifacts). The `ours` merge driver prevents xcstrings merge conflicts.

SPM dependencies (SwiftTerm, Sparkle, swift-markdown) are resolved automatically when you open `Pine.xcodeproj` in Xcode.

## Build & Run

**Xcode (recommended):** Open `Pine.xcodeproj` and press Cmd+R.

**CLI:**

```bash
# Set Xcode developer directory (once)
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer

# Build
xcodebuild -project Pine.xcodeproj -scheme Pine build
```

New `.swift` files placed in `Pine/`, `PineTests/`, or `PineUITests/` are automatically picked up by Xcode (file system synchronized groups). No manual `project.pbxproj` edits needed.

## Running Tests

### Unit Tests

Uses [Swift Testing](https://developer.apple.com/xcode/swift-testing/) framework. 50+ test files covering git parsing, grammar models, file tree, syntax highlighting, find & replace, code folding, minimap, status bar, project search, and more.

```bash
# Run all unit tests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild test -project Pine.xcodeproj -scheme Pine \
  -destination 'platform=macOS' -only-testing:PineTests

# Run a single test class
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild test -project Pine.xcodeproj -scheme Pine \
  -destination 'platform=macOS' -only-testing:PineTests/GoToLineTests
```

### UI Tests

Uses XCUITest. 18+ test files covering Welcome window, editor tabs, terminal, multi-window, minimap, git blame, branch switcher, and more.

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild test -project Pine.xcodeproj -scheme Pine \
  -destination 'platform=macOS' -only-testing:PineUITests
```

### Performance Tests

XCTest `measure {}` benchmarks for FoldRange, SyntaxHighlighter, ProjectSearch, GitStatus. Skipped in CI by default; run on demand:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild test -project Pine.xcodeproj -scheme Pine \
  -destination 'platform=macOS' -only-testing:PinePerformanceTests
```

## Project Architecture

Pine follows **MVVM** with SwiftUI views backed by AppKit via `NSViewRepresentable`.

- **`ProjectManager`** (`@Observable`) is the central state object managing file tree, editor tabs, terminal tabs, and git status
- **`CodeEditorView`** wraps NSScrollView + custom `GutterTextView` (NSTextView subclass) for the code editor
- **`TerminalContentView`** wraps SwiftTerm's `LocalProcessTerminalView` for the integrated terminal
- **`SyntaxHighlighter`** loads JSON grammar files from `Pine/Grammars/` and highlights asynchronously
- Menu commands are defined in `PineApp.swift` and flow through NotificationCenter

For full architecture details, see [CLAUDE.md](CLAUDE.md).

## Code Style

### SwiftLint

SwiftLint runs as an Xcode build phase. Configuration is in `.swiftlint.yml`.

**Run before every commit:**

```bash
swiftlint
```

If SwiftLint crashes with a `sourcekitdInProc` error:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swiftlint
```

### Naming & Patterns

- Use `@Observable` macro (Swift 5.9+), **not** `ObservableObject`/`@Published`
- Models: structs for value types (`EditorTab`), `@Observable` classes for identity types (`FileNode`, `TerminalTab`)
- UI uses semantic system colors (not hardcoded color values)
- Strings go in `Strings.swift`, menu icons in `MenuIcons.swift`
- All UI updates on main thread; CPU-intensive work dispatched to background queues
- Generation tokens prevent stale async results from overwriting newer ones

## Commit Conventions

All commits **must** follow [Conventional Commits](https://www.conventionalcommits.org/):

| Prefix | Use case |
|--------|----------|
| `feat:` | New feature |
| `fix:` | Bug fix |
| `docs:` | Documentation only |
| `refactor:` | Code restructuring without behavior change |
| `perf:` | Performance improvement |
| `test:` | Adding or updating tests |
| `chore:` | Build, CI, tooling changes |

For breaking changes, use `feat!:` or add a `BREAKING CHANGE:` footer.

Examples:

```
feat: add Python syntax grammar
fix: prevent crash when opening empty file
docs: update CONTRIBUTING.md with test instructions
```

Release Please uses these prefixes to auto-generate changelog and version bumps.

## Pull Request Process

### Branch Naming

Use descriptive branch names with a prefix and issue number:

```
feat/feature-name-123
fix/bug-description-456
docs/topic-789
refactor/area-101
test/what-is-tested-202
```

### Requirements

1. **Tests required** -- every new feature or bug fix must include unit tests (and UI tests where applicable). Cover public API, edge cases, error paths, and boundary conditions. Do not submit a PR without corresponding tests
2. **SwiftLint clean** -- no warnings or errors
3. **CI must pass** -- lint, build, unit tests, all 6 UI test shards
4. **Coverage threshold** -- 70% logic-only (SwiftUI view files excluded)
5. **Branch up-to-date** with `main` before merge

### CI Pipeline

The CI pipeline runs automatically on every PR:

1. **Lint** -- SwiftLint
2. **Build** -- Xcode build
3. **Unit Tests** -- with code coverage
4. **UI Tests** -- 6 parallel shards (must be balanced within +/-3 tests)
5. **Flaky Test Summary** -- flaky tests auto-retry once and are reported separately

## Localization

Localized strings live in `Pine/Localizable.xcstrings`.

**Important:** Never use `json.dump` or standard JSON serializers to write this file. Xcode uses non-standard formatting (`"key" : "value"` with a space before the colon). Reserializing the entire file creates thousands of lines of whitespace noise in diffs.

Instead, insert new translations by reading the file as text and making targeted insertions preserving the existing format.

## Adding a New Language Grammar

Grammar files are JSON in `Pine/Grammars/`. To add support for a new language:

1. Create a new JSON file in `Pine/Grammars/` following the format of existing grammars
2. Define regex rules with scopes (`comment`, `string`, `keyword`, etc.)
3. The `SyntaxHighlighter` will pick it up automatically at startup

## Getting Help

- Browse [open issues](https://github.com/batonogov/pine/issues) -- look for the `good first issue` label
- Read [CLAUDE.md](CLAUDE.md) for detailed architecture and key file descriptions
- Open a new issue if you have questions or ideas
