# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Pine is a minimal native macOS code editor built with SwiftUI + AppKit. Targets macOS 26 (Tahoe) with Liquid Glass UI. The only external dependency is [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) for the terminal emulator.

## Build & Run

- **Xcode 26+** required, macOS 26+ deployment target
- Open `Pine.xcodeproj` in Xcode, build and run (Cmd+R)
- CLI build: `xcodebuild -project Pine.xcodeproj -scheme Pine build` (requires `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`)
- Type-check a single file (no sudo needed): `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc -typecheck -target arm64-apple-macos26.0 -sdk /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk <file.swift>`
- **Dependency:** SwiftTerm added via Xcode SPM (File > Add Package Dependencies > `https://github.com/migueldeicaza/SwiftTerm.git`)
- No other third-party dependencies
- **SwiftLint:** `brew install swiftlint` — runs as a build phase; config in `.swiftlint.yml`. Run `swiftlint` before every commit and fix all warnings/errors. If `swiftlint` crashes with `sourcekitdInProc` error, prefix with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`
- **Unit Tests:** `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project Pine.xcodeproj -scheme Pine -destination 'platform=macOS' -only-testing:PineTests`
- Unit test target: `PineTests` (Swift Testing framework) — covers git parsing, grammar models, file tree
- **UI Tests:** `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project Pine.xcodeproj -scheme Pine -destination 'platform=macOS' -only-testing:PineUITests`
- UI test target: `PineUITests` (XCTest/XCUITest) — end-to-end tests for Welcome window, editor tabs, terminal, multi-window
- Launch arguments for UI testing: `--reset-state` (clears persisted sessions), `-ApplePersistenceIgnoreState YES` (ignores macOS saved window state), `-AppleLanguages (en)`, `-AppleLocale en_US` (force English locale so menu item names are predictable)
- Environment variable for UI testing: `PINE_OPEN_PROJECT=<path>` (opens project without file dialog — uses env var because macOS interprets bare paths in launch arguments as files to open)
- **Known issue:** On macOS 26, `XCUIApplication.launch()` bypasses LaunchServices, so SwiftUI `.defaultLaunchBehavior(.presented)` does not create windows. The app includes an AppKit fallback (`createWelcomeWindowViaAppKit`) that activates after 0.5s if no windows appear.
- **Known issue:** `GutterTextView` (NSTextView inside NSViewRepresentable) does not receive keyboard input from XCUITest's `typeText()`/`typeKey()`. UI tests that need to verify editor content changes should use alternative approaches (e.g., verifying menu item availability, checking tab state).
- To interact with menu items in UI tests, use `app.menuBars.menuBarItems["File"].click()` then `app.menuItems["Item Name"].click()` with English names (locale is forced to `en`)
- Accessibility identifiers defined in `Pine/AccessibilityIdentifiers.swift` — used by both app views and UI tests

## Architecture

**Pattern:** MVVM with SwiftUI views backed by AppKit via `NSViewRepresentable`.

**State management:** `ProjectManager` (@Observable) is the central state object managing file tree, editor tabs, terminal tabs, and git status. It communicates with views via SwiftUI observation and with menu commands via NotificationCenter.

**AppKit bridges:**
- `CodeEditorView` — wraps NSScrollView + custom `GutterTextView` (NSTextView subclass) + `LineNumberView` for the code editor
- `TerminalContentView` — wraps SwiftTerm's `LocalProcessTerminalView` (NSView) for the terminal

**Text system stack:** NSTextStorage → NSLayoutManager → NSTextContainer → GutterTextView (shifts text right for line number gutter)

**Terminal:** Uses [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) — a full VT100/xterm terminal emulator in pure Swift. `TerminalTab` wraps `LocalProcessTerminalView` which handles PTY creation, escape sequence parsing, keyboard input, and rendering. Supports colors, cursor positioning, TUI apps (vim, htop), oh-my-zsh, and all standard terminal features. Terminal tabs use a custom tab bar with shared state across editor windows.

**Git integration:** `GitStatusProvider` runs `git status` and `git diff` to show file status indicators in the sidebar and diff markers (added/modified/deleted) in the editor gutter. Branch switching is available in the UI.

**Syntax highlighting:** `SyntaxHighlighter` singleton loads JSON grammar files from `Pine/Grammars/` at startup. Each grammar defines regex rules with scopes (comment, string, keyword, etc.) and a priority system prevents nested matches (comments > strings > keywords).

**Window & tab management:** Uses `WindowGroup(for: URL.self)` where URL identifies the project directory (not individual files). Each project gets one native macOS window with an internal editor tab bar (`EditorTabBar`). `ProjectRegistry` (owned by `AppDelegate`, shared with `PineApp` via computed property) deduplicates open projects — opening the same directory twice returns the same `ProjectManager`. A `Welcome` window (`WelcomeView`) shows on launch with a recent projects list and an Open Folder button. `FocusedProjectKey` passes the active `ProjectManager` to menu commands via `@FocusedValue`. On macOS 26, XCUITest and direct binary launches bypass LaunchServices, causing SwiftUI to skip window creation despite `.defaultLaunchBehavior(.presented)`. `AppDelegate.createWelcomeWindowViaAppKit()` uses `NSHostingController` as a fallback to guarantee the Welcome window appears.

**Document lifecycle:** `TabManager` manages save operations — `saveTab(at:)` writes to disk with NSAlert on failure, `trySaveTab(at:)` throws without UI. `saveAllTabs()` / `trySaveAllTabs()` save all dirty tabs. `saveActiveTabAs(to:)` implements Save As — writes to new URL and updates tab in-place preserving identity. `duplicateActiveTab()` creates a copy with Finder-like naming ("file copy.ext", "file copy 2.ext"). Close/quit dialogs list unsaved files with `dirtyTabs` and use "Save All" button. Failed saves cancel close/quit.

**Session persistence:** `SessionState` (Codable struct) saves project path + open file paths to UserDefaults. `AppDelegate` triggers save on app termination for all open projects. `ContentView.restoreSessionIfNeeded()` restores tabs on first load if the saved session matches the current project.

## Key Files

- `PineApp.swift` — @main entry point, AppDelegate (window tabbing config, session save on terminate), keyboard shortcuts (Cmd+S, Cmd+Option+S, Cmd+Shift+S, Cmd+Shift+D, Cmd+Shift+O, Cmd+`), project WindowGroup + Welcome Window scenes, CloseDelegate for unsaved-changes dialogs
- `ContentView.swift` — NavigationSplitView layout: sidebar (file tree) + detail (editor tabs + terminal), session restoration
- `SessionState.swift` — Codable session persistence (project path + open file paths) via UserDefaults
- `ProjectManager.swift` — Central state: file tree, terminal tabs, git provider, project I/O, saveSession()
- `FileNode.swift` — Recursive tree model for filesystem
- `CodeEditorView.swift` — NSViewRepresentable editor with GutterTextView and LineNumberView
- `SyntaxHighlighter.swift` — Grammar loading, regex compilation, theme colors, highlighting application
- `LineNumberGutter.swift` — Line number rendering (enumerates only visible line fragments)
- `TerminalSession.swift` — SwiftTerm integration: TerminalTab, TerminalContentView (NSViewRepresentable), TerminalTabDelegate
- `GitStatusProvider.swift` — Git status/diff parsing for sidebar indicators and gutter markers
- `ProjectRegistry.swift` — Manages open projects and recent project history, deduplicates by URL
- `WelcomeView.swift` — Welcome window with recent projects list and Open Folder button
- `FocusedProjectKey.swift` — FocusedValueKey for passing active ProjectManager to menu commands
- `AccessibilityIdentifiers.swift` — Shared accessibility ID constants for UI testing
- `Pine/TabManager.swift` — Editor tab lifecycle: open, close, save, saveAll, saveAs, duplicate, dirty tracking, external change detection
- `PineTests/` — Unit tests: GitStatusParserTests, GitDiffParserTests, FileNodeTests, GrammarModelTests, TabManagerTests
- `PineUITests/` — XCUITest suite: WelcomeWindowTests, EditorWindowTests, TerminalTests, MultiWindowTests

## Release & CI

- **Release Please** (`.github/workflows/release-please.yml`) automates versioning and changelog via [Conventional Commits](https://www.conventionalcommits.org/):
  - On every push to `main`, Release Please creates/updates a Release PR with version bump in `version.txt` and auto-generated `CHANGELOG.md`
  - When the Release PR is merged, Release Please creates a git tag (e.g. `v0.13.0`) which triggers the build workflow
  - Config: `release-please-config.json`, manifest: `.release-please-manifest.json`
  - Requires `RELEASE_PLEASE_TOKEN` secret (PAT with `contents: write` + `pull-requests: write`) — default `GITHUB_TOKEN` won't trigger downstream workflows
- **Build workflow** (`.github/workflows/release.yml`) triggers on `v*` tags
- Pipeline: build → code sign → notarize → create DMG → GitHub Release → update Homebrew Tap
- Secrets: `CERTIFICATE_P12`, `CERTIFICATE_PASSWORD`, `APPLE_ID`, `APPLE_ID_PASSWORD`, `APPLE_TEAM_ID`, `TAP_GITHUB_TOKEN`, `RELEASE_PLEASE_TOKEN`
- Homebrew: `brew tap batonogov/tap && brew install --cask pine-editor`

## Conventions

- Uses `@Observable` macro (Swift 5.9+), not ObservableObject/Published
- Models are either structs (EditorTab) or @Observable classes (FileNode, TerminalTab) depending on identity semantics
- Grammar files are JSON in `Pine/Grammars/` — add new languages by adding a new JSON file following the existing format
- Keyboard shortcuts: Save (Cmd+S), Save All (Cmd+Option+S), Save As (Cmd+Shift+S), Duplicate (Cmd+Shift+D), Open Folder (Cmd+Shift+O), Toggle Terminal (Cmd+`). Menu commands flow through `@FocusedValue(\.projectManager)` to `TabManager`
- UI uses semantic system colors (migrated from hardcoded dark theme values)
- macOS 26 SDK renamed `NSColor(sRGBRed:)` → `NSColor(srgbRed:)` (lowercase)
- Editor features: auto-indent on newline, current line highlight, git diff gutter markers
- Editor tabs use an internal SwiftUI tab bar (`EditorTabBar`), not native macOS window tabs
- Project windows use `WindowGroup(for: URL.self)` where URL = project directory; `ProjectRegistry` prevents duplicate windows for the same project
- **Conventional Commits** — all commit messages must follow the format: `feat:`, `fix:`, `chore:`, `docs:`, `refactor:`, `perf:`, `test:`. Use `feat!:` or `BREAKING CHANGE:` footer for breaking changes

## GitHub Issues

When creating issues, always:
- Add appropriate labels from the repo's label set (e.g. `enhancement`, `bug`, `editor`, `UX`, `priority: high/medium/low`, etc.)
- Use a clear, concise title
- Include **Summary**, **Motivation**, and **Implementation ideas** sections in the body
