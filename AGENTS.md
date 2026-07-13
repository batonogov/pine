# AGENTS.md

Guidance for AI coding agents (Claude Code, pi, and others) working in this repository.

## Project Overview

Pine is a minimal native macOS code editor built with SwiftUI + AppKit. Targets macOS 26 (Tahoe) with Liquid Glass UI.

**Dependencies** (via Xcode SPM):
- [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) — terminal emulator
- [Sparkle](https://sparkle-project.org/Sparkle) — auto-updates
- [swift-markdown](https://github.com/swiftlang/swift-markdown) — markdown preview rendering

## Build & Run

- **Xcode 26+** required, macOS 26+ deployment target
- Open `Pine.xcodeproj` in Xcode, build and run (Cmd+R)
- CLI build: `xcodebuild -project Pine.xcodeproj -scheme Pine build` (requires `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`)
- Type-check a single file (no sudo needed): `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc -typecheck -target arm64-apple-macos26.0 -sdk /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk <file.swift>`
- **Dependency:** SwiftTerm added via Xcode SPM (File > Add Package Dependencies > `https://github.com/migueldeicaza/SwiftTerm.git`)
- No other third-party dependencies
- **Xcode project format:** Uses `PBXFileSystemSynchronizedRootGroup` (objectVersion 77) — new `.swift` files placed in `Pine/`, `PineTests/`, or `PineUITests/` are automatically picked up by Xcode. No manual `project.pbxproj` edits needed
- **Git hooks:** Run once after cloning: `git config core.hooksPath .githooks && git config merge.ours.driver true`. Enables pre-commit hook that auto-unstages cosmetic-only changes to `Localizable.xcstrings` (Xcode build artifacts) and `ours` merge driver for xcstrings conflicts
- **SwiftLint:** `brew install swiftlint` — runs as a build phase; config in `.swiftlint.yml`. CI pins SwiftLint 0.63.2. Run `swiftlint` before every commit and fix all warnings/errors. If `swiftlint` crashes with `sourcekitdInProc` error, prefix with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`
- **Unit Tests:** `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project Pine.xcodeproj -scheme Pine -destination 'platform=macOS' -only-testing:PineTests`
- Run a single test class: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project Pine.xcodeproj -scheme Pine -destination 'platform=macOS' -only-testing:PineTests/GoToLineTests`
- Unit test target: `PineTests` (Swift Testing framework) — 180+ test files covering git parsing, grammar models, file tree, syntax highlighting, find & replace, code folding, minimap, status bar, project search, external formatters, and more
- **UI Tests:** `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project Pine.xcodeproj -scheme Pine -destination 'platform=macOS' -only-testing:PineUITests`
- UI test target: `PineUITests` (XCTest/XCUITest) — 30 test files, base class `PineUITestCase`. CI runs 7 parallel shards (Terminal, Welcome & Session, Navigation, Editor Chrome, Files & Save, Search & Panes, Security & Layout)
- Launch arguments for UI testing: `--reset-state` (clears persisted sessions), `--disable-agent-detection` (disables the `ps`-polling agent detector — avoids the macOS-26 fork/spawn hang #1060), `--disable-metal` (pins the terminal to SwiftTerm's CoreGraphics renderer — Metal may be unavailable on CI virtual displays #1108), `--disable-quick-terminal` (disables the global ⌃⌥Space hotkey so it does not grab key events on CI #1113), `-ApplePersistenceIgnoreState YES` (ignores macOS saved window state), `-AppleLanguages (en)`, `-AppleLocale en_US` (force English locale so menu item names are predictable)
- Environment variable for UI testing: `PINE_OPEN_PROJECT=<path>` (opens project without file dialog — uses env var because macOS interprets bare paths in launch arguments as files to open)
- **Performance Tests:** `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project Pine.xcodeproj -scheme Pine -destination 'platform=macOS' -only-testing:PinePerformanceTests` — XCTest `measure {}` benchmarks for FoldRange, SyntaxHighlighter, ProjectSearch, GitStatus. Enabled in default scheme but excluded from CI (opt-in via `perf` label on PR or `workflow_dispatch`)
- **Known issue:** On macOS 26, `XCUIApplication.launch()` bypasses LaunchServices, so SwiftUI `.defaultLaunchBehavior(.presented)` does not create windows. The app includes an AppKit fallback (`createWelcomeWindowViaAppKit`) that activates after 0.5s if no windows appear.
- **Known issue:** `GutterTextView` (NSTextView inside NSViewRepresentable) does not receive keyboard input from XCUITest's `typeText()`/`typeKey()`. UI tests that need to verify editor content changes should use alternative approaches (e.g., verifying menu item availability, checking tab state).
- **Known issue:** XCUITest's `typeKey()` bypasses the app's `NSEvent.addLocalMonitorForEvents` — synthetic key events go through Accessibility APIs, not the app's event queue. Keyboard shortcuts handled via local event monitors (e.g., Cmd+W for tab closing, Cmd+Shift+B for branch switcher) cannot be reliably UI-tested with `typeKey()`. Use mouse clicks on UI elements instead.
- **Known issue:** SwiftUI's `toolbarTitleMenu` does not work on macOS 26 with Liquid Glass — the title/subtitle area is not clickable. Branch switching uses an AppKit workaround (`BranchSubtitleClickHandler`) that attaches an `NSClickGestureRecognizer` to the subtitle `NSTextField` in the window view hierarchy.
- **Known issue:** UI tests that use `Process()` to run shell commands (e.g., `git init`) need `DEVELOPER_DIR` set in the process environment, otherwise `xcrun` fails with "cannot be used within an App Sandbox".
- **Quick terminal:** a system-wide ⌃⌥Space hotkey (`Carbon RegisterEventHotKey`, no Accessibility permission required, works in the App Sandbox) toggles a floating drop-down terminal over any application (#1113). The session is keep-alive — scrollback survives toggles; Esc and ⌘W hide it. The working directory resolves to an open Pine project (current implementation picks `openProjects.keys.first` — Dictionary order, not the key window; key-window resolution is a follow-up), else the most-recent project, else `$HOME`. Disable with `--disable-quick-terminal` or `PINE_DISABLE_QUICK_TERMINAL` (used by UI tests). Agent detection (#950) does NOT cover the quick-terminal tab (it lives outside the pane tree) — a follow-up wires it in. A menu item, Settings UI (custom hotkey, screen edge, height), and per-pane quick terminals are follow-ups — v1 ships the hotkey + window only.
- **Known issue:** XCUITest launch arguments (`-key YES`) store values as strings in NSArgumentDomain. `UserDefaults.object(forKey:) as? Bool` returns nil for strings. To set boolean UserDefaults for UI tests, use `defaults write <bundle-id> <key> -bool YES` via `Process` in setUp, and `defaults delete` in tearDown
- **Known issue:** Pine's terminal opts into SwiftTerm's Metal renderer (`setUseMetal(true)`) once the view lands in a window, replacing the layer-backed CoreGraphics raster with a GPU swapchain and eliminating the entire black-screen class (#64, #661, #871, #918, #923, #966, #1094, #1108). On failure (headless CI VM, old GPU, virtual display without a Metal device) it silently falls back to CoreGraphics. UI tests pass `--disable-metal` to pin CoreGraphics on macOS-26 virtual displays; production users can opt out with `--disable-metal` or `PINE_DISABLE_METAL`.
- To interact with menu items in UI tests, use `app.menuBars.menuBarItems["File"].click()` then `app.menuItems["Item Name"].click()` with English names (locale is forced to `en`)
- Accessibility identifiers defined in `Pine/AccessibilityIdentifiers.swift` — used by both app views and UI tests

## Architecture

**Pattern:** MVVM with SwiftUI views backed by AppKit via `NSViewRepresentable`.

**State management:** `ProjectManager` (@Observable) is the central state object managing file tree, editor tabs, terminal tabs, and git status. It owns `PaneManager` (split pane tree), `TabManager` (primary editor tabs), `TerminalManager` (terminal coordinator), and `WorkspaceManager` (file tree + git). It communicates with views via SwiftUI observation and with menu commands via NotificationCenter.

**AppKit bridges:**
- `CodeEditorView` — wraps NSScrollView + custom `GutterTextView` (NSTextView subclass) + `LineNumberView` for the code editor
- `TerminalContentView` — wraps SwiftTerm's `LocalProcessTerminalView` (NSView) for the terminal

**Text system stack:** NSTextStorage → NSLayoutManager → NSTextContainer → GutterTextView (shifts text right for line number gutter)

**Split panes:** `PaneNode` is a recursive enum (`.leaf` or `.split`) forming a binary tree of editor/terminal panes. `PaneManager` (@MainActor @Observable) manages the tree, per-pane TabManagers (for editor leaves), and per-pane `TerminalPaneState` (for terminal leaves). `PaneTreeView` recursively renders the tree; `PaneLeafView` switches on `PaneContent` (.editor/.terminal) to render the appropriate content. `PaneDividerView` handles resize. Drag-and-drop between panes uses `TabDragInfo` with `contentType` field for type validation (editor tabs can only drop on editor panes, terminal tabs on terminal panes). `PaneSplitDropDelegate` detects drop zones (right/bottom/center) based on cursor position. `TabCloseHelper` provides shared close-with-confirmation dialogs used by both ContentView and PaneLeafView.

**Terminal:** Uses [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) — a full VT100/xterm terminal emulator in pure Swift. Terminal tabs live inside the split pane tree as `.terminal` leaf panes — there is no separate bottom panel. `TerminalPaneState` (@Observable) manages per-pane terminal tabs (array of `TerminalTab`, active tab, search state). `TerminalManager` is a coordinator that routes Cmd+T and Cmd+\` to the appropriate terminal pane via `PaneManager`. When creating a new terminal pane, it wraps the entire editor tree in a vertical split (terminal at bottom, full width). `TerminalPaneTabBar` provides the tab bar with drag-and-drop, maximize/restore, and close buttons. `TerminalContainerView` (AppKit) handles SwiftTerm view lifecycle. Supports colors, cursor positioning, TUI apps (vim, htop), oh-my-zsh, and all standard terminal features.

**Git integration:** `GitStatusProvider` runs `git status` and `git diff` to show file status indicators in the sidebar and diff markers (added/modified/deleted) in the editor gutter. Branch switching is available via clickable subtitle in the title bar (shows NSMenu with all branches) and via Cmd+Shift+B (opens `BranchSwitcherView` sheet with search). The subtitle click is implemented via AppKit (`BranchSubtitleClickHandler`) because SwiftUI's `toolbarTitleMenu` does not work on macOS 26 with Liquid Glass. Git blame display shows per-line commit info (hash, author, timestamp, message) alongside code; toggled via menu. `GitBlameInfo` holds the parsed blame data structures.

**Syntax highlighting:** `SyntaxHighlighter` singleton loads JSON grammar files from `Pine/Grammars/` at startup. Each grammar defines regex rules with scopes (comment, string, keyword, etc.) and a priority system prevents nested matches (comments > strings > keywords). Highlighting runs asynchronously using generation tokens to discard stale results.

**Minimap:** `MinimapView` renders a scaled-down (12%) document overview on the right edge of the editor showing syntax colors and git diff markers. Click or drag to scroll the editor proportionally. A viewport indicator rectangle shows the visible region. Toggle visibility via menu.

**Code folding:** `FoldRangeCalculator` identifies foldable ranges by scanning matched bracket pairs (`{}`, `[]`, `()`). `FoldState` tracks which ranges are folded for the active tab using a sorted set for O(1) hidden-line lookups. Fold/unfold/toggle operations are available via menu and gutter clicks.

**Adding menu commands:** Menu items are defined in `PineApp.swift` inside `CommandGroup`. They post notifications via `NotificationCenter.default.post(name:)`. Notification names are defined as static properties in `extension Notification.Name` (bottom of `PineApp.swift`). `ContentView` listens via `.onReceive()` inside `GitAndNotificationObserver` ViewModifier. Strings go in `Strings.swift`, icons in `MenuIcons.swift`, localization in `Localizable.xcstrings` (targeted text insertion, not json.dump).

**Find & Replace:** Uses NSTextView's native find bar (`usesFindBar = true`) triggered via NotificationCenter. Notifications: `findInFile` (Cmd+F), `findAndReplace` (Cmd+Option+F), `findNext` (Cmd+G), `findPrevious` (Cmd+Shift+G), `useSelectionForFind` (Cmd+E). The find bar is presented by `GutterTextView`'s coordinator in response to menu commands.

**Project-wide search:** `ProjectSearchProvider` performs async full-project text search with debounce, `.gitignore` support, binary file detection, and a 1 MB per-file limit. Results are grouped by file and displayed in `SearchResultsView` with match highlighting and case-sensitivity toggle.

**Status bar:** `StatusBarInfo` computes cursor position (line:column, 1-based), line ending style (LF/CRLF), indentation style (spaces/tabs with width), and human-readable file size. These values are displayed in `StatusBarView` at the bottom of the editor.

**Format on Save:** `FileFormatterRegistry` applies language-aware formatters when `EditorSettings.formatOnSave` is enabled. Pure-Swift formatters (e.g. `JSONFileFormatter`) run synchronously. External tool formatters (`ExternalFileFormatter`) delegate to CLI tools (terraform, tofu, shfmt, prettier) via stdin/stdout — `ExternalFileFormatter.format()` dispatches `processRunner.run()` to a background queue via `DispatchGroup` so the main-thread `precondition` in `RealProcessRunner` is satisfied. `ExternalToolResolver` discovers tools by searching PATH + well-known directories (`/opt/homebrew/bin`, `/usr/local/bin`). `HCLFileFormatter` resolves terraform (preferred) or tofu for `.tf`/`.tfvars`/`.hcl` files. When neither tool is found, the formatter becomes a no-op (`toolPath: nil`). The registry is injectable via `TabManager.fileFormatters` for testing with `MockProcessRunner`.

**Smart list continuation:** `SmartListContinuation` auto-continues Markdown list bullets/numbers/tasks on Enter. Wired into `GutterTextView` key handling. Enabled by default via `EditorSettings.smartListContinuation`.

**Auto-save:** Auto-save support is accessible via menu (menu icon defined in `MenuIcons.autoSave`, string in `Strings.menuAutoSave`).

**File system watching:** `FileSystemWatcher` uses FSEvents to monitor a directory tree and fires a debounced callback on the main thread when changes occur. Generation tokens prevent stale callbacks from firing after `stop()` is called.

**Async file tree:** `WorkspaceManager` loads the project file tree in two phases — a shallow pass renders immediately for responsiveness, followed by a full async load. Generation tokens prevent stale async results from overwriting newer ones.

**Window & tab management:** Uses `WindowGroup(for: URL.self)` where URL identifies the project directory (not individual files). Each project gets one native macOS window with an internal editor tab bar (`EditorTabBar`). `ProjectRegistry` (owned by `AppDelegate`, shared with `PineApp` via computed property) deduplicates open projects — opening the same directory twice returns the same `ProjectManager`. A `Welcome` window (`WelcomeView`) shows on launch with a recent projects list and an Open Folder button. `FocusedProjectKey` passes the active `ProjectManager` to menu commands via `@FocusedValue`. On macOS 26, XCUITest and direct binary launches bypass LaunchServices, causing SwiftUI to skip window creation despite `.defaultLaunchBehavior(.presented)`. `AppDelegate.createWelcomeWindowViaAppKit()` uses `NSHostingController` as a fallback to guarantee the Welcome window appears.

**Document lifecycle:** `TabManager` manages save operations — `saveTab(at:)` writes to disk with NSAlert on failure, `trySaveTab(at:)` throws without UI. `saveAllTabs()` / `trySaveAllTabs()` save all dirty tabs. `saveActiveTabAs(to:)` implements Save As — writes to new URL and updates tab in-place preserving identity. `duplicateActiveTab()` creates a copy with Finder-like naming ("file copy.ext", "file copy 2.ext"). Close/quit dialogs list unsaved files with `dirtyTabs` and use "Save All" button. Failed saves cancel close/quit.

**Quick Open:** `QuickOpenProvider` builds a file index from the `FileNode` tree and performs fuzzy subsequence matching with scoring (filename exact/prefix/substring bonuses, recent files boost). `QuickOpenView` is a sheet overlay with live search, arrow key navigation, and file icons. Triggered via Cmd+P.

**Symbol Navigator:** `SymbolNavigatorView` shows functions, classes, and structs in the current file with fuzzy search. Triggered via Cmd+R. Uses regex-based symbol extraction per language.

**Markdown preview:** Renders markdown using [swift-markdown](https://github.com/swiftlang/swift-markdown). Three modes: source-only, rendered, and side-by-side. Toggled via Cmd+Shift+P. The rendered view converts Markdown AST to NSAttributedString for display in a native text view.

**Session persistence:** `SessionState` (Codable struct) saves project path, open file paths, pane layout tree (PaneNode), per-pane terminal tab counts, and editor state to UserDefaults. `AppDelegate` triggers save on app termination for all open projects. `ContentView.restoreSessionIfNeeded()` restores tabs and pane layout on first load if the saved session matches the current project. Terminal pane positions are preserved; terminal processes are recreated (scrollback lost).

## Key Entry Points

- `PineApp.swift` — @main, AppDelegate, menu commands, `CloseDelegate`
- `ContentView.swift` — NavigationSplitView: sidebar + PaneTreeView
- `ProjectManager.swift` — Central state: pane manager, tab manager, terminal coordinator, git provider
- `CodeEditorView.swift` — NSViewRepresentable editor (GutterTextView + LineNumberView)
- `PaneManager.swift` / `PaneNode.swift` — Split pane tree (binary tree of editor/terminal leaves)
- `TabManager.swift` — Editor tab lifecycle (open, close, save, saveAs, duplicate, dirty tracking)
- `WorkspaceManager.swift` — Async file tree loading, git integration, file watching
- `GitStatusProvider.swift` — Git status/diff parsing, branch listing and checkout
- `SyntaxHighlighter.swift` — Grammar loading, regex compilation, async highlighting
- `TerminalSession.swift` / `TerminalManager.swift` — SwiftTerm integration and terminal coordination
- `SessionState.swift` — Codable session persistence via UserDefaults
- `PineTests/` — Unit tests (180+ files, Swift Testing framework)
- `PineUITests/` — XCUITest suite (30 files), base class `PineUITestCase`
- `PinePerformanceTests/` — XCTest `measure {}` benchmarks; enabled in default scheme but excluded from CI (opt-in via `perf` label or `workflow_dispatch`)

## Concurrency Model

Pine uses GCD for background work, bridged to async/await via `withCheckedContinuation` at API boundaries.

**Threading rules:**
- All UI updates on main thread (SwiftUI observation + `DispatchQueue.main.async`)
- CPU-intensive work dispatched to background: syntax highlighting (`com.pine.syntax-highlight` serial queue), git operations (`DispatchQueue.global` with `DispatchGroup` for parallel branch/status/branches), project search (`TaskGroup` with sliding-window concurrency), file tree loading (`DispatchQueue.global`)
- **Never block main thread** with file I/O, regex computation, or git process execution
- Generation tokens (`HighlightGeneration`, `WorkspaceManager.loadGeneration`, `FileSystemWatcher.activeGeneration`) prevent stale async results from overwriting newer ones — always check generation before applying results

**Debounce values** (centralised in `UITimings.Debounce` / `UITimings.Render`):
- Syntax highlight on edit: 100ms (`Debounce.edit`)
- Syntax highlight on scroll: 50ms (`Debounce.scroll`)
- Fold range recalculation: 150ms (`Debounce.foldRecalc`)
- Project search: 300ms (`Debounce.projectSearch`)
- File system watcher: 150ms (`Debounce.fileWatcher`, `WorkspaceManager.watcherDebounce`)
- Config validator (yamllint / shellcheck / hadolint / terraform validate): 300ms (`Debounce.configValidation`, `ConfigValidator.debounceInterval`)
- Minimap redraw: 25ms with trailing coalesce (`Render.minimapRedraw`)

**Performance thresholds:**
- Viewport-only highlighting: files > 50 000 characters (`viewportHighlightThreshold`; lowered from 100KB in #637)
- Large file dialog (disable highlighting?): files > 1MB (`largeFileThreshold`)
- Partial load (first 1MB only): files > 10MB (`hugeFileThreshold`)
- Project search skips files > 1MB
- Target: <4ms main thread work per scroll frame for 120Hz ProMotion

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
- **CI pipeline** (`.github/workflows/ci.yml`): Lint → Build → Unit Tests (with code coverage) + 7 UI Test shards (parallel) + Flaky Test Summary. All UI tests always run (no conditional skip). Coverage threshold: 70% logic-only (SwiftUI view files excluded). Flaky tests auto-retry once and are reported separately. UI test shards must be balanced (±3 tests, currently 24-27 per shard); verify script checks all test classes are assigned to a shard
- **Branch protection**: requires all checks to pass. Does NOT require the branch to be up-to-date with main, and does NOT use a merge queue — multiple PRs can be merged in parallel/sequence without re-running CI on each. GitHub recomputes mergeability after each merge, but stale branches merge cleanly (3-way merge handles shared files)
- **Action pinning** — all third-party GitHub Actions are pinned by full commit SHA (not mutable tags) for supply-chain safety. To update: find the new version's commit SHA on GitHub (Tags → verify the commit), replace the SHA in the workflow file, and keep the `# vX` comment in sync
- **Nightly performance** (`.github/workflows/nightly-perf.yml`) — runs performance tests nightly and on schedule, uploads `PerformanceResults.xcresult` artifact, detects regressions via `scripts/check_perf_regression.py`
- **Nightly fuzz** (`.github/workflows/nightly-fuzz.yml`) — scheduled fuzz testing
- **Screenshots** (`.github/workflows/screenshots.yml`) — regenerates GitHub/landing page screenshots in `assets/` on demand

## Conventions

- Uses `@Observable` macro (Swift 5.9+), not ObservableObject/Published
- Models are either structs (EditorTab) or classes depending on identity semantics. `FileNode` is a plain `nonisolated final class` (not @Observable) — it's a recursive tree data structure, not reactive state. `TerminalTab` is `@Observable` because it drives SwiftUI updates
- Grammar files are JSON in `Pine/Grammars/` — add new languages by adding a new JSON file following the existing format
- **Keyboard shortcuts** — menu commands flow through `@FocusedValue(\.projectManager)` to `TabManager`. Notable exceptions: Cmd+W is intercepted via `NSEvent.addLocalMonitorForEvents` in AppDelegate (closes active tab, not window); Cmd+\` focuses terminal pane or creates one; Cmd+T creates a new terminal tab in the last-used terminal pane or creates a full-width terminal pane at the bottom
- UI uses semantic system colors (migrated from hardcoded dark theme values)
- macOS 26 SDK renamed `NSColor(sRGBRed:)` → `NSColor(srgbRed:)` (lowercase)
- Editor tabs use an internal SwiftUI tab bar (`EditorTabBar`), not native macOS window tabs
- Project windows use `WindowGroup(for: URL.self)` where URL = project directory; `ProjectRegistry` prevents duplicate windows for the same project
- **Conventional Commits** — all commit messages must follow the format: `feat:`, `fix:`, `chore:`, `docs:`, `refactor:`, `perf:`, `test:`. Use `feat!:` or `BREAKING CHANGE:` footer for breaking changes
- **Test coverage** — every new feature or bug fix must include unit tests (and UI tests where applicable). Aim for comprehensive coverage: test public API, edge cases, error paths, boundary conditions, and integration between components. Cover the maximum number of cases — not just the happy path. Do not merge code without corresponding tests
- **Localizable.xcstrings** — never use `json.dump` or standard JSON serializers to write this file. Xcode uses non-standard formatting (`"key" : "value"` with a space before the colon). Reserializing the entire file creates thousands of lines of whitespace noise in diffs. Instead, insert new translations by reading the file as text and making targeted insertions preserving the existing format
- **Localization** — 9 languages supported (en, de, es, fr, ja, ko, pt-BR, ru, zh-Hans). All user-facing strings go through `Localizable.xcstrings`. To add a new language: add the language key to the xcstrings dict with translations for every existing key
- **Utility scripts** — `scripts/` directory contains `normalize-xcstrings.sh` (called by pre-commit hook to unstage cosmetic xcstrings changes), `reset-cosmetic-xcstrings.sh` (reverts cosmetic-only xcstrings diffs), `test-normalize-xcstrings.sh` (tests for the normalizer), `update-screenshots.sh` (regenerates GitHub/landing page screenshots), `check-no-post-under-inout.py` (pre-commit + CI guard that blocks the exclusivity-abort reentrancy class), and `tests/test-check-no-post-under-inout.sh` (tests for that guard)
- **Reentrancy / exclusivity** — never post a `NotificationCenter` notification inside a function that holds an `inout` (e.g. `tabs: inout [EditorTab]`) exclusive access. `NotificationCenter.post` delivers observers synchronously on the main queue; an observer that writes the same store re-enters the live access and Swift aborts the process (`_swift_reportExclusivityConflict`, Pine #1066 and the #1047/#1051/#1056/#1058 family). Safe pattern: RETURN the payload (e.g. `SaveOutcome.reload` / `ReloadedTab`) and let the caller post AFTER the `inout` scope ends — see `TabExternalChangeDetector.reloadTab` and `TabPersistence.saveTabContent`. For `.onReceive` / `@objc` observers, defer `@State`/`@Observable` mutations to the next runloop via `DispatchQueue.main.async`. The `check-no-post-under-inout.py` guard enforces the `inout`-post sub-pattern at pre-commit and CI; if you legitimately defer a post inside an `inout` function, mark the line `// reentrancy-safe`

## Snapshot Testing

Pine uses a minimal zero-dependency visual snapshot harness for SwiftUI views. Reference PNGs live under `PineTests/SnapshotTests/__Snapshots__/`. No third-party packages, no pbxproj edits.

- **Harness:** `PineTests/SnapshotTests/SnapshotHarness.swift` — renders a SwiftUI view via `NSHostingView` into an `NSBitmapImageRep` under a given `NSAppearance` (`.light` / `.dark`), encodes to PNG, and compares against the reference using a mean-absolute per-pixel RGBA diff normalized to `[0, 1]`. Default tolerance is `0.01` to absorb trivial anti-aliasing noise.
- **Backing scale independence:** the bitmap is allocated explicitly at 1× the logical size (`pixelsWide == Int(size.width)`) so output is identical on Retina (2×) developer machines and on macOS CI runners' 1× virtual displays. Without this, baselines recorded on a Retina Mac differ in pixel dimensions from CI output and the diff short-circuits to `1.0` (dimension mismatch). The bitmap is also pre-filled with `NSColor.windowBackgroundColor` under the requested appearance so semi-transparent system colors (e.g. `.secondary` text in dark mode) composite onto a realistic backdrop instead of a transparent canvas.
- **Writing a test:** import the harness (it lives in the `PineTests` target) and call `try assertSnapshot(of: MyView(), size: NSSize(width: W, height: H), appearance: .light, named: "MyView.light")`. Cover both `.light` and `.dark` for every view. Use local `Harness` wrapper views for SwiftUI bindings.
- **Stability:** stub out any data source that can vary between machines (e.g. populate `ProjectRegistry.recentProjects` and `GitStatusProvider.branches` manually). Never snapshot a view that depends on real git state, real filesystem contents, or network.
- **Running:** `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project Pine.xcodeproj -scheme Pine -destination 'platform=macOS' -only-testing:PineTests/WelcomeViewSnapshotTests` (one suite at a time).
- **Updating snapshots:** run tests with `PINE_RECORD_SNAPSHOTS=1` in the test environment (set it via the Pine scheme's Test action, or pass as the final positional `KEY=VALUE` arg to `xcodebuild test`). In record mode the harness always overwrites the reference PNG and passes. Review the PNG diff in the PR before merging.
- **First run:** if no reference exists the harness writes a baseline and fails the test so new baselines can never sneak in silently. A failing test also writes an `<name>.actual.png` alongside the reference for visual inspection.
- **Current coverage:** 8 view suites / 32 reference PNGs — `WelcomeView`, `BranchSwitcherView`, `GoToLineView`, `NavigationOverlay` (GoToLine overlay via `CommandOverlayView`), `BreadcrumbPathBar`, `EditorTabItem`, `IndentGuidesYAML`, `StatusBarView` (each in light + dark; `BreadcrumbPathBar`, `EditorTabItem`, and `StatusBarView` also snapshot multiple states). Remaining scope from issue #796 (editor gutter, sidebar file tree, minimap, diagnostic popover, inline diff) is tracked as follow-ups — the tab bar is now partially covered via `EditorTabItem` snapshots.

## GitHub Issues

When creating issues, always:
- Add appropriate labels from the repo's label set (e.g. `enhancement`, `bug`, `editor`, `UX`, `priority: high/medium/low`, etc.)
- Use a clear, concise title
- Include **Summary**, **Motivation**, and **Implementation ideas** sections in the body
- **Always assign the issue to a milestone.** Work is milestone-driven: pick the next task from the current milestone, prioritizing by the `priority:` labels. No milestone = no work.

## Workflow

How the maintainer works day-to-day. Documents intent and handoff conventions for contributors and AI agents.

### Prioritization
- Work is driven by **milestones**. The next task is picked from the active milestone, prioritized by labels (`priority: high` first).
- An issue is filed **before or alongside** implementation and always assigned to a milestone (see `## GitHub Issues`).

### Branches & PRs
- **One task = one short-lived branch**, named by type with no issue number: `feat/terminal-scroll`, `fix/gutter-bug`.
- No long-lived feature branches. Nothing is committed directly to `main`.
- PRs are **squash-merged** into `main` (one commit per PR).
- The PR description states **when the branch is ready to merge** — do not merge before that.
- **All CI checks must be green before a PR can be merged.** This is enforced by repository branch protection ("requires all checks to pass", see `## Release & CI`) — GitHub will refuse the merge button on any non-green PR. Red PRs are never merged. When CI fails due to flakiness or a runner/infrastructure issue that is provably not the diff's fault (e.g. an identical hang reproduces on a screenshots-only PR), the fix is to resolve the failure — rerun, mitigate the flakiness, or fix the code — until a fully green run exists. Do not hand-wave a red check as "not our fault" and call the PR mergeable; a green run is a hard prerequisite, not a judgment call.

### Local development loop
- Code is edited **inside Pine itself**, or via AI agents in the terminal.
- Fast feedback loop: **single-file typecheck** (`swiftc -typecheck`, see `## Build & Run`) — not a full build on every change.
- A full `xcodebuild build` is run **before opening a PR**.
- Run locally: `swiftlint` + the unit tests in `PineTests` that cover the touched area.
- **UI tests (`PineUITests`, 7 shards) run only on CI** — almost never locally.

### Working with AI agents
- Typical handoff: **"реши issue #N"** (solve issue #N) — the agent reads the issue **and all its comments** in full, then plans, implements, writes tests, and opens a PR.
- Agents may freely, without asking: edit code, run single-file typecheck, run unit tests, create branches, open PRs.
- **Explicit confirmation required** for: merging a PR, and anything in the destructive-command list in `AGENTS.md` (deletions, force-pushes, infrastructure changes).
- Agents should run unit tests themselves — no need to ask first.

### Milestone orchestration with subagents

For a milestone with multiple issues, the maintainer (or a parent agent) orchestrates implementation across subagents instead of doing all the work in one session. Used for parallelizable issues, large features, or when strict adversarial review is wanted. The full loop runs inside the agent; the human only merges at the end.

Flow:
1. **Scope first.** Read every issue in the milestone end-to-end, identify shared files, and note dependencies (`blocked-by`, or an explicit "depends on #X" in the body). Order implementation and merge accordingly.
2. **One issue = one worker = one PR.** Delegate each issue to a worker subagent in an isolated worktree (`worktree: true`). Each worker creates its own branch and opens its own PR against `main`. Pass each worker explicit permissions in the task (which `git` / `gh` / `xcodebuild` commands are allowed) and an `acceptance` contract with `verify` commands and `stopRules` (notably: never merge, never force-push, never amend).
3. **Respect cross-issue boundaries.** Tell each worker exactly which files/branches it may touch so sibling PRs stay mergeable (e.g. add a dedicated accumulator field per branch instead of repurposing a shared one). When an issue depends on siblings not yet merged, the dependent worker merges those sibling branches into its own branch and documents it in the PR body — GitHub auto-shrinks the diff once the siblings land.
4. **Strict review from fresh context.** Once PRs are open, run fresh-context `reviewer` subagents with distinct angles (e.g. correctness/regressions, tests/validation) against the actual diff. Reviewers are read-only — they must not edit.
5. **Fix on the existing branch.** Synthesize reviewer findings and hand them to a fix-worker that checks out the **existing** PR branch and adds a follow-up commit. Never amend, force-push, or open a new branch for fixes. Repeat the review/fix loop until reviewers return a clean verdict (typically ~2 rounds).
6. **Verify before handoff.** Confirm every PR is `MERGEABLE` and **fully green** — every required CI check passing, no exceptions. Pending checks must be explicitly noted. There is no "red but mergeable" state: branch protection blocks the merge button on any failing check, so a red PR is not ready regardless of why it failed. State the merge order.
7. **Never merge.** The agent opens and reviews PRs; only the human merges them.

Operational notes:
- Worktree isolation requires a clean main tree — remove stray artifacts (e.g. a `reviews/` folder written by reviewers) before launching new worktree runs.
- "needs attention" control signals from a finished run are stale noise; trust `gh pr checks` / `gh pr view` as ground truth.
- Acceptance-gate / parse-report errors in the subagent harness do not mean the work failed — check the PR and CI; the code usually landed.

### Releases
- **No fixed cadence** — release when ready, by merging the Release Please PR.
- Manual work before tagging is kept to a minimum; Release Please handles `version.txt` and `CHANGELOG.md` automatically (see `## Release & CI`).
