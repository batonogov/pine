---
paths:
  - "Pine/**/*.swift"
---

# Pine architecture

How the app is put together. Read this guide before architecture changes under `Pine/`; tool-independent discovery starts in `AGENTS.md`.

**Pattern:** MVVM with SwiftUI views backed by AppKit via `NSViewRepresentable`.

**State management:** `ProjectManager` (@Observable) is the central state object managing file tree, editor tabs, terminal tabs, and git status. It owns `PaneManager` (fixed editor/adjacent-terminal layout), `TabManager` (primary editor tabs), `TerminalManager` (terminal coordinator), and `WorkspaceManager` (file tree + git). It communicates with views via SwiftUI observation and with menu commands via NotificationCenter.

**AppKit bridges:**
- `CodeEditorView` — wraps NSScrollView + custom `GutterTextView` (NSTextView subclass) + `LineNumberView` for the code editor
- `TerminalContentView` — wraps SwiftTerm's `LocalProcessTerminalView` (NSView) for the terminal

**Text system stack:** NSTextStorage → NSLayoutManager → NSTextContainer → GutterTextView (shifts text right for line number gutter)

**Fixed editor/terminal layout:** `PaneManager` owns one editor `TabManager` and at most one adjacent `TerminalPaneState`. `PaneTreeView` renders either the editor alone, the terminal alone, or one vertical editor/terminal divider; terminal zoom is a presentation-only projection. There are no split commands, edge-drop targets, nested pane mutations, cross-pane tab moves, or tab drag coordinators. Sidebar/Finder file drops open in the existing editor. `PaneNode` remains Codable only for the fixed projection and migration of legacy free-form trees; `ProjectSessionRestorer` merges all legacy editor assignments and terminal tab counts without dropping documents. `TabCloseHelper` provides shared close-with-confirmation dialogs.

**Sidebar file navigation:** Treat the left file tree as a Finder-style, keyboard-first surface, not as a mouse-only list. `SidebarTreeNavigation` owns one selection over the flattened visible rows: Up/Down move by row; Left collapses an expanded folder or selects its parent; Right expands a collapsed folder or selects its first child; Home/End and Page Up/Page Down navigate the visible tree; typing performs Unicode-aware prefix selection with repeated-character cycling. Selection, opening, and focus are distinct states. Space opens a transient preview and keeps focus in the sidebar; Return starts inline rename; Cmd+Return permanently opens the file and moves focus to the editor. A single file click previews, a double-click permanently opens, and a folder-row click toggles disclosure. Keyboard selection must preserve spatial orientation: while the selected row is visible, do not move the viewport; once it leaves the viewport, reveal it by the smallest necessary amount at the nearest edge. With `ScrollViewProxy`, call `scrollTo(id)` without an anchor or animation for routine navigation — never use `.center` there. Intentional reveal after create/duplicate may use `.center` and animation, but must become immediate under Reduce Motion; a rename commit reveals at the nearest edge with no animation because the row never left the viewport (#1537). The same nearest-edge rule covers the editor and terminal tab strips: switching the active tab must not re-centre a tab that is already visible. Page Up/Down step by the rendered row height (`SidebarTreeNavigation.rowHeight`, synced from `FontSizeSettings`), not the minimum row metric. Row context-menu file operations (New Folder, Rename, Duplicate, Move to Trash, Reveal in Finder) also exist in File ▸ Sidebar, acting on the selected row via the `sidebarFileOperation` notification; ⌘⌫ Move to Trash is handled locally by the sidebar responder rather than as a menu key equivalent so it cannot shadow delete-to-beginning-of-line in text editors. Tab context-menu commands (Pin, Close Other Tabs ⌥⌘W, Close Tabs to the Right, Close All Tabs, Reveal in Sidebar ⇧⌘J) live in the Window menu via `ProjectManager`'s menu-tab-command methods. Unit tests must lock the minimal-vs-centered request policy; an XCUITest that only asserts `isSelected` does not verify scroll geometry. Before release, manually check a tall tree with single and held arrow presses, both viewport boundaries, type-to-select to an off-screen row, Home/End, Page Up/Page Down, create/duplicate centering, and Reduce Motion.

**Terminal:** Uses [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) — the upstream VT100/xterm terminal emulator in pure Swift. The current full revision pin is a descendant of v1.99.3 in `batonogov/SwiftTerm`, adding exact-generation TERM-to-KILL escalation while SwiftTerm retains root reaping (#1786); return to an upstream tag when that API is released. Pine's rendering patches were upstreamed in 1.99.2 (e.g. #1650 bright-foreground slots). Terminal tabs live in the single adjacent terminal destination. `TerminalPaneState` (@Observable) manages the adjacent terminal tabs (array of `TerminalTab`, active tab, search state). `TerminalManager` is a coordinator that routes Cmd+T and Cmd+\` to the appropriate terminal pane via `PaneManager`. The terminal sits full width below the editor when both are visible. `TerminalPaneTabBar` provides tab selection/reordering, maximize/restore, and close buttons. `TerminalContainerView` (AppKit) handles SwiftTerm view lifecycle. Supports colors, cursor positioning, TUI apps (vim, htop), oh-my-zsh, and all standard terminal features.

**Terminal hyperlinks:** two independent click paths, both on ⌘+click. (1) Implicit `path:line[:col]` references in any terminal cell are parsed by `TerminalOutputParser` (#949) — the `TerminalScrollInterceptor` overlay resolves them against the working directory, verifies the file exists, and posts `.openFileAtLine` to open it in the editor. (2) Explicit OSC 8 hyperlinks and implicit URLs are handled by SwiftTerm itself (`linkReporting = .implicit`, `linkHighlightMode = .hoverWithModifier` — hover-underline is built in) → `TerminalTabDelegate.requestOpenLink` → `TerminalLinkOpener` (#1114): `file://` (local host) reveals in Finder via `NSWorkspace.activateFileViewerSelecting` WITHOUT launching — safe even if the link points at a `.app`/`.command` bundle a hostile program sneaked into its output; `http(s)`/`mailto` open in the system handler; `file://` with a foreign host is ignored to avoid Finder network mounts. The `path:line` path runs first (the overlay consumes the event); OSC 8 is the fallback when no `file:line` reference is under the cursor.

**Git integration:** `GitStatusProvider` runs `git status` and `git diff` to show file status indicators in the sidebar and diff markers in the editor gutter. Current branch identity remains available to task environment details; there is no branch-switching picker or built-in blame presentation. Shared Git/environment primitives remain for task ownership and verification.

**Syntax highlighting:** `SyntaxHighlighter` singleton loads JSON grammar files from `Pine/Grammars/` at startup. Each grammar defines regex rules with scopes (comment, string, keyword, etc.) and a priority system prevents nested matches (comments > strings > keywords). Highlighting runs asynchronously using generation tokens to discard stale results.

**Adding menu commands:** Scene wiring lives in `PineApp.swift`; menu definitions live in `PineAppMenuCommands.swift`. Notification-based commands use names in `PineAppNotifications.swift` and post via `NotificationCenter.default.post(name:)`. `ContentView` listens via `.onReceive()` inside `GitAndNotificationObserver` ViewModifier. Strings go in `Strings.swift`, icons in `MenuIcons.swift`, localization in `Localizable.xcstrings` (targeted text insertion, not json.dump).

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

## Key entry points

- `PineApp.swift` — @main, AppDelegate, menu commands, `CloseDelegate`
- `ContentView.swift` — NavigationSplitView: sidebar + PaneTreeView
- `ProjectManager.swift` — Central state: pane manager, tab manager, terminal coordinator, git provider
- `CodeEditorView.swift` — NSViewRepresentable editor (GutterTextView + LineNumberView)
- `PaneManager.swift` / `PaneNode.swift` — Fixed editor/adjacent-terminal layout and legacy-layout decoding
- `TabManager.swift` — Editor tab lifecycle (open, close, save, saveAs, duplicate, dirty tracking)
- `WorkspaceManager.swift` — Async file tree loading, git integration, file watching
- `GitStatusProvider.swift` — Git status/diff parsing, branch listing and checkout
- `SyntaxHighlighter.swift` — Grammar loading, regex compilation, async highlighting
- `TerminalSession.swift` / `TerminalManager.swift` — SwiftTerm integration and terminal coordination
- `SessionState.swift` — Codable session persistence via UserDefaults
- `PineTests/` — Unit tests (180+ files, Swift Testing framework)
- `PineUITests/` — XCUITest suite (30 files), base class `PineUITestCase`
- `PinePerformanceTests/` — XCTest `measure {}` benchmarks; enabled in default scheme but excluded from CI (opt-in via `perf` label or `workflow_dispatch`)

## Type and view conventions

- Models are either structs (EditorTab) or classes depending on identity semantics. `FileNode` is a plain `nonisolated final class` (not @Observable) — it's a recursive tree data structure, not reactive state. `TerminalTab` is `@Observable` because it drives SwiftUI updates
- Grammar files are JSON in `Pine/Grammars/` — add new languages by adding a new JSON file following the existing format
- **Keyboard shortcuts** — menu commands flow through `@FocusedValue(\.projectManager)` to `TabManager`. Notable exceptions: Cmd+W is intercepted via `NSEvent.addLocalMonitorForEvents` in AppDelegate (closes active tab, not window); Cmd+\` focuses terminal pane or creates one; Cmd+T creates a new terminal tab in the last-used terminal pane or creates a full-width terminal pane at the bottom
- Editor tabs use an internal SwiftUI tab bar (`EditorTabBar`), not native macOS window tabs
- Project windows use `WindowGroup(for: URL.self)` where URL = project directory; `ProjectRegistry` prevents duplicate windows for the same project
