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
- **Git hooks:** Run once after cloning: `git config core.hooksPath .githooks && git config merge.ours.driver true`. Enables pre-commit hook that auto-unstages cosmetic-only changes to `Localizable.xcstrings` (Xcode build artifacts) and `ours` merge driver for xcstrings conflicts
- **SwiftLint:** `brew install swiftlint` — runs as a build phase; config in `.swiftlint.yml`. Run `swiftlint` before every commit and fix all warnings/errors. If `swiftlint` crashes with `sourcekitdInProc` error, prefix with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`
- **Unit Tests:** `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project Pine.xcodeproj -scheme Pine -destination 'platform=macOS' -only-testing:PineTests`
- Unit test target: `PineTests` (Swift Testing framework) — covers git parsing, grammar models, file tree, syntax highlighting, tab management, folding, find/replace, minimap, status bar, bracket matching, comment toggling, project search, markdown rendering, and more
- **UI Tests:** `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project Pine.xcodeproj -scheme Pine -destination 'platform=macOS' -only-testing:PineUITests`
- UI test target: `PineUITests` (XCTest/XCUITest) — end-to-end tests for Welcome window, editor tabs, terminal, multi-window
- Launch arguments for UI testing: `--reset-state` (clears persisted sessions), `-ApplePersistenceIgnoreState YES` (ignores macOS saved window state), `-AppleLanguages (en)`, `-AppleLocale en_US` (force English locale so menu item names are predictable)
- Environment variable for UI testing: `PINE_OPEN_PROJECT=<path>` (opens project without file dialog — uses env var because macOS interprets bare paths in launch arguments as files to open)
- **Known issue:** On macOS 26, `XCUIApplication.launch()` bypasses LaunchServices, so SwiftUI `.defaultLaunchBehavior(.presented)` does not create windows. The app includes an AppKit fallback (`createWelcomeWindowViaAppKit`) that activates after 0.5s if no windows appear.
- **Known issue:** `GutterTextView` (NSTextView inside NSViewRepresentable) does not receive keyboard input from XCUITest's `typeText()`/`typeKey()`. UI tests that need to verify editor content changes should use alternative approaches (e.g., verifying menu item availability, checking tab state).
- **Known issue:** XCUITest's `typeKey()` bypasses the app's `NSEvent.addLocalMonitorForEvents` — synthetic key events go through Accessibility APIs, not the app's event queue. Keyboard shortcuts handled via local event monitors (e.g., Cmd+W for tab closing, Cmd+Shift+B for branch switcher) cannot be reliably UI-tested with `typeKey()`. Use mouse clicks on UI elements instead.
- **Known issue:** SwiftUI's `toolbarTitleMenu` does not work on macOS 26 with Liquid Glass — the title/subtitle area is not clickable. Branch switching uses an AppKit workaround (`BranchSubtitleClickHandler`) that attaches an `NSClickGestureRecognizer` to the subtitle `NSTextField` in the window view hierarchy.
- **Known issue:** UI tests that use `Process()` to run shell commands (e.g., `git init`) need `DEVELOPER_DIR` set in the process environment, otherwise `xcrun` fails with "cannot be used within an App Sandbox".
- To interact with menu items in UI tests, use `app.menuBars.menuBarItems["File"].click()` then `app.menuItems["Item Name"].click()` with English names (locale is forced to `en`)
- Accessibility identifiers defined in `Pine/AccessibilityIdentifiers.swift` — used by both app views and UI tests

## Architecture

**Pattern:** MVVM with SwiftUI views backed by AppKit via `NSViewRepresentable`.

**State management:** `ProjectManager` (@Observable) is a thin coordinator that owns `WorkspaceManager` (file tree + git), `TerminalManager` (terminal tabs), `TabManager` (editor tabs), and `ProjectSearchProvider` (project-wide search). It communicates with views via SwiftUI observation and with menu commands via NotificationCenter.

**AppKit bridges:**
- `CodeEditorView` — wraps NSScrollView + custom `GutterTextView` (NSTextView subclass) + `LineNumberView` for the code editor
- `TerminalContentView` — wraps SwiftTerm's `LocalProcessTerminalView` (NSView) for the terminal

**Text system stack:** NSTextStorage → NSLayoutManager → NSTextContainer → GutterTextView (shifts text right for line number gutter)

**Terminal:** Uses [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) — a full VT100/xterm terminal emulator in pure Swift. `TerminalTab` wraps `LocalProcessTerminalView` which handles PTY creation, escape sequence parsing, keyboard input, and rendering. Supports colors, cursor positioning, TUI apps (vim, htop), oh-my-zsh, and all standard terminal features. Terminal tabs use a custom tab bar with shared state across editor windows.

**Git integration:** `GitStatusProvider` runs `git status` and `git diff` to show file status indicators in the sidebar and diff markers (added/modified/deleted) in the editor gutter. Branch switching is available via clickable subtitle in the title bar (shows NSMenu with all branches) and via Cmd+Shift+B (opens `BranchSwitcherView` sheet with search). The subtitle click is implemented via AppKit (`BranchSubtitleClickHandler`) because SwiftUI's `toolbarTitleMenu` does not work on macOS 26 with Liquid Glass.

**Syntax highlighting:** `SyntaxHighlighter` singleton loads JSON grammar files from `Pine/Grammars/` at startup. Each grammar defines regex rules with scopes (comment, string, keyword, etc.) and a priority system prevents nested matches (comments > strings > keywords). Highlighting runs asynchronously off the main thread; large files (>500 KB) disable highlighting automatically.

**Minimap:** `MinimapView` (NSView subclass) renders a scaled-down read-only representation of the file alongside the editor. Visibility is persisted via `MinimapSettings` (UserDefaults). Toggle with Cmd+Shift+M or the View menu.

**Code folding:** `FoldRangeCalculator` detects foldable regions (braces, brackets, block comments) by scanning character pairs. `FoldState` tracks folded ranges and a `hiddenLines` cache for O(1) line-visibility checks. Fold/unfold via Cmd+Option+←/→; fold/unfold all via Cmd+Option+Shift+←/→.

**Git blame:** `GitBlameInfo.swift` defines `GitBlameLine` parsed from `git blame --porcelain`. Blame annotations are shown in the gutter alongside line numbers. Toggle with Ctrl+Cmd+B.

**Find & replace:** In-editor find bar with regex support. Find (Cmd+F), Find & Replace (Cmd+Option+F), Find Next (Cmd+G), Find Previous (Cmd+Shift+G), Use Selection for Find (Cmd+E). Implemented in `CodeEditorView`.

**Project-wide search:** `ProjectSearchProvider` (@Observable) asynchronously greps all text files under the project root and aggregates `SearchMatch` results. Results are displayed in `SearchResultsView` in the sidebar. Open with Cmd+Shift+F.

**Status bar:** `StatusBarInfo.swift` provides `CursorLocation` (1-based line/col from UTF-16 offset using `LineStartsCache`), file encoding, line endings, and file size. Displayed at the bottom of the editor window.

**Font size:** `FontSizeSettings` (@Observable singleton) persists editor font size to UserDefaults. Increase (Cmd++), Decrease (Cmd+-), Reset (Cmd+0).

**Async file tree:** `WorkspaceManager` loads directory trees asynchronously using a generation counter to discard stale results. `FileSystemWatcher` uses FSEvents to detect external changes and triggers debounced sidebar refreshes.

**Shell settings:** `ShellSettings` (@Observable singleton) persists the selected terminal shell (bash/zsh/fish/etc.) to UserDefaults.

**Markdown preview:** `MarkdownPreviewView` (NSViewRepresentable) renders Markdown as attributed text via `MarkdownRenderer`. Toggle between source and preview modes with Cmd+Shift+P.

**Window & tab management:** Uses `WindowGroup(for: URL.self)` where URL identifies the project directory (not individual files). Each project gets one native macOS window with an internal editor tab bar (`EditorTabBar`). `ProjectRegistry` (owned by `AppDelegate`, shared with `PineApp` via computed property) deduplicates open projects — opening the same directory twice returns the same `ProjectManager`. A `Welcome` window (`WelcomeView`) shows on launch with a recent projects list and an Open Folder button. `FocusedProjectKey` passes the active `ProjectManager` to menu commands via `@FocusedValue`. On macOS 26, XCUITest and direct binary launches bypass LaunchServices, causing SwiftUI to skip window creation despite `.defaultLaunchBehavior(.presented)`. `AppDelegate.createWelcomeWindowViaAppKit()` uses `NSHostingController` as a fallback to guarantee the Welcome window appears.

**Document lifecycle:** `TabManager` manages save operations — `saveTab(at:)` writes to disk with NSAlert on failure, `trySaveTab(at:)` throws without UI. `saveAllTabs()` / `trySaveAllTabs()` save all dirty tabs. `saveActiveTabAs(to:)` implements Save As — writes to new URL and updates tab in-place preserving identity. `duplicateActiveTab()` creates a copy with Finder-like naming ("file copy.ext", "file copy 2.ext"). Close/quit dialogs list unsaved files with `dirtyTabs` and use "Save All" button. Failed saves cancel close/quit.

**Session persistence:** `SessionState` (Codable struct) saves project path + open file paths to UserDefaults. `AppDelegate` triggers save on app termination for all open projects. `ContentView.restoreSessionIfNeeded()` restores tabs on first load if the saved session matches the current project.

## Key Files

- `PineApp.swift` — @main entry point, AppDelegate (window tabbing config, session save on terminate, Cmd+W event monitor), keyboard shortcuts, project WindowGroup + Welcome Window scenes, `CloseDelegate` (top-level class for testability) handles window close with dirty-tabs dialog
- `ContentView.swift` — NavigationSplitView layout: sidebar (file tree + search results) + detail (editor tabs + terminal), session restoration
- `SessionState.swift` — Codable session persistence (project path + open file paths + preview modes) via UserDefaults
- `ProjectManager.swift` — Thin coordinator owning WorkspaceManager, TerminalManager, TabManager, ProjectSearchProvider; saveSession()
- `WorkspaceManager.swift` — @Observable class: async file tree loading with generation counter, git integration via GitStatusProvider, FileSystemWatcher for external change detection
- `FileSystemWatcher.swift` — FSEvents-based watcher for directory tree changes with debounced main-thread callback
- `FileNode.swift` — Recursive tree model for filesystem
- `CodeEditorView.swift` — NSViewRepresentable editor with GutterTextView, LineNumberView, minimap, find bar, and blame annotations
- `SyntaxHighlighter.swift` — Grammar loading, regex compilation, theme colors, async highlighting application
- `LineNumberGutter.swift` — Line number rendering (enumerates only visible line fragments)
- `LineStartsCache.swift` — Binary-search cache mapping UTF-16 offsets to line numbers in O(log n)
- `MinimapView.swift` — NSView subclass rendering a scaled-down read-only code overview; `MinimapSettings` persists visibility to UserDefaults
- `StatusBarInfo.swift` — `CursorLocation` (Ln/Col from UTF-16 offset), file encoding, line endings, and file size for the status bar
- `FoldState.swift` — Tracks folded ranges and a `hiddenLines` set for O(1) line-visibility checks
- `FoldRangeCalculator.swift` — Detects foldable regions (`FoldableRange`, `FoldKind`) by scanning brace/bracket/comment pairs
- `GitBlameInfo.swift` — `GitBlameLine` model parsed from `git blame --porcelain` output
- `BracketMatcher.swift` — Finds matching `()`, `{}`, `[]` pairs in editor text using a stack algorithm
- `CommentToggler.swift` — Pure logic for toggling line comments; no AppKit dependencies
- `ProjectSearchProvider.swift` — @Observable async project-wide text search; produces `SearchMatch` results
- `SearchResultsView.swift` — SwiftUI view listing project search matches in the sidebar
- `MarkdownPreviewView.swift` — NSViewRepresentable rendering Markdown as attributed text (read-only NSTextView)
- `MarkdownRenderer.swift` — Converts Markdown to NSAttributedString
- `MarkdownPreviewMode.swift` — Enum for source / preview / split view modes
- `FontSizeSettings.swift` — @Observable singleton persisting editor font size to UserDefaults
- `ShellSettings.swift` — @Observable singleton persisting terminal shell selection to UserDefaults
- `RepresentedFileTracker.swift` — NSViewRepresentable setting NSWindow.representedURL for proxy icon and path menu
- `TerminalSession.swift` — SwiftTerm integration: TerminalTab, TerminalContentView (NSViewRepresentable), TerminalTabDelegate
- `TerminalManager.swift` — @Observable manager for terminal tabs, sessions, and visibility/maximized state
- `GitStatusProvider.swift` — Git status/diff parsing for sidebar indicators and gutter markers, async branch listing and checkout
- `BranchSubtitleClickHandler.swift` — NSViewRepresentable that makes the window subtitle clickable for branch switching (AppKit workaround for broken `toolbarTitleMenu`)
- `BranchSwitcherView.swift` — SwiftUI sheet with search field for branch switching (opened via Cmd+Shift+B)
- `ProjectRegistry.swift` — Manages open projects and recent project history, deduplicates by URL
- `WelcomeView.swift` — Welcome window with recent projects list and Open Folder button
- `FocusedProjectKey.swift` — FocusedValueKey for passing active ProjectManager to menu commands
- `AccessibilityIdentifiers.swift` — Shared accessibility ID constants for UI testing
- `Pine/TabManager.swift` — Editor tab lifecycle: open, close, save, saveAll, saveAs, duplicate, dirty tracking, external change detection
- `PineTests/` — Unit tests (45 files): GitStatusParserTests, GitDiffParserTests, GitBlameParserTests, FileNodeTests, GrammarModelTests, TabManagerTests, WindowLifecycleTests, URLAbbreviatedPathTests, BracketMatcherTests, CommentTogglerTests, FoldRangeCalculatorTests, FoldStateTests, FindReplaceTests, MinimapViewTests, StatusBarInfoTests, LineStartsCacheTests, ProjectSearchProviderTests, WorkspaceManagerTests, MarkdownRendererTests, FontSizeSettingsTests, ShellSettingsTests, AsyncSyntaxHighlighterTests, and more
- `PineUITests/` — XCUITest suite (17 files): WelcomeWindowTests, EditorWindowTests, TerminalTests, MultiWindowTests, BranchSwitcherTests, BlameViewTests, MinimapTests, FontSizeTests, DiffNavigationUITests, SidebarSearchTests, ToggleCommentTests, DeleteTests, DuplicateTests, GitignoreFilterTests, SymlinkSecurityUITests, CheckForUpdatesTests, PineUITestCase (base class)

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
- **Action pinning** — all third-party GitHub Actions are pinned by full commit SHA (not mutable tags) for supply-chain safety. To update: find the new version's commit SHA on GitHub (Tags → verify the commit), replace the SHA in the workflow file, and keep the `# vX` comment in sync

## Conventions

- Uses `@Observable` macro (Swift 5.9+), not ObservableObject/Published
- Models are either structs (EditorTab) or @Observable classes (FileNode, TerminalTab) depending on identity semantics
- Grammar files are JSON in `Pine/Grammars/` — add new languages by adding a new JSON file following the existing format
- Keyboard shortcuts: Save (Cmd+S), Save All (Cmd+Option+S), Save As (Cmd+Shift+S), Duplicate (Cmd+Shift+D), Open Folder (Cmd+Shift+O), Close Tab (Cmd+W), Toggle Terminal (Cmd+`), New Terminal Tab (Cmd+T), Switch Branch (Cmd+Shift+B), Next Change (Ctrl+Opt+↓), Previous Change (Ctrl+Opt+↑), Toggle Comment (Cmd+/), Find (Cmd+F), Find & Replace (Cmd+Option+F), Find Next (Cmd+G), Find Previous (Cmd+Shift+G), Use Selection for Find (Cmd+E), Find in Project (Cmd+Shift+F), Fold Code (Cmd+Option+←), Unfold Code (Cmd+Option+→), Fold All (Cmd+Option+Shift+←), Unfold All (Cmd+Option+Shift+→), Toggle Minimap (Cmd+Shift+M), Toggle Blame (Ctrl+Cmd+B), Toggle Preview (Cmd+Shift+P), Reveal in Finder (Cmd+Shift+R), Increase Font Size (Cmd++), Decrease Font Size (Cmd+-), Reset Font Size (Cmd+0). Menu commands flow through `@FocusedValue(\.projectManager)` to `TabManager`. Cmd+W is intercepted via `NSEvent.addLocalMonitorForEvents` in AppDelegate (not a SwiftUI menu command) to close the active tab; the window close button goes through `CloseDelegate.windowShouldClose` to close the entire window
- UI uses semantic system colors (migrated from hardcoded dark theme values)
- macOS 26 SDK renamed `NSColor(sRGBRed:)` → `NSColor(srgbRed:)` (lowercase)
- Editor features: auto-indent on newline, current line highlight, git diff gutter markers, minimap, code folding, git blame annotations, find & replace (in-editor), project-wide search, status bar (Ln/Col/encoding/line endings/size), configurable font size, markdown preview, bracket matching, comment toggling, async syntax highlighting
- Editor tabs use an internal SwiftUI tab bar (`EditorTabBar`), not native macOS window tabs
- Project windows use `WindowGroup(for: URL.self)` where URL = project directory; `ProjectRegistry` prevents duplicate windows for the same project
- **Conventional Commits** — all commit messages must follow the format: `feat:`, `fix:`, `chore:`, `docs:`, `refactor:`, `perf:`, `test:`. Use `feat!:` or `BREAKING CHANGE:` footer for breaking changes
- **Test coverage** — every new feature or bug fix must include unit tests (and UI tests where applicable). Aim for comprehensive coverage: test public API, edge cases, error paths, boundary conditions, and integration between components. Cover the maximum number of cases — not just the happy path. Do not merge code without corresponding tests
- **Localizable.xcstrings** — never use `json.dump` or standard JSON serializers to write this file. Xcode uses non-standard formatting (`"key" : "value"` with a space before the colon). Reserializing the entire file creates thousands of lines of whitespace noise in diffs. Instead, insert new translations by reading the file as text and making targeted insertions preserving the existing format

## GitHub Issues

When creating issues, always:
- Add appropriate labels from the repo's label set (e.g. `enhancement`, `bug`, `editor`, `UX`, `priority: high/medium/low`, etc.)
- Use a clear, concise title
- Include **Summary**, **Motivation**, and **Implementation ideas** sections in the body
