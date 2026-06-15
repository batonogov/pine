# Code Context

Read-only recon of the Pine macOS code editor. No files modified.

## Files Retrieved

1. `Pine/PineApp.swift` (lines 1-804) — `@main` entry point. Defines `PineApp: App`, `AppDelegate: NSObject, NSApplicationDelegate, SPUUpdaterDelegate` (Sparkle), and `CloseDelegate`. Owns menu commands (delegated to `PineAppMenuCommands.swift`) and `ProjectRegistry`.
2. `Pine/ContentView.swift` (lines 1-287) — `NavigationSplitView` (sidebar + `PaneTreeView`). Hosts `GitAndNotificationObserver` view modifier for NotificationCenter routing. `ContentView+Helpers.swift` (491 lines) supplements.
3. `Pine/ProjectManager.swift` (lines 1-316) — `final class ProjectManager` (`@Observable`-style via `@Observation` macro inferred from usage). Central state: owns `PaneManager`, `TabManager`, `TerminalManager`, `WorkspaceManager`, `GitStatusProvider`.
4. `Pine/CodeEditorView.swift` (lines 1-514) — `NSViewRepresentable` wrapping `NSScrollView` + custom `GutterTextView` (588 lines) + `LineNumberGutter` (807 lines). Sets `textView.usesFindBar = true` (line 131). Companion: `CodeEditorView+Coordinator.swift` (1108 lines, largest app file).
5. `Pine/PaneManager.swift` (lines 1-724) — `final class PaneManager` manages the recursive split-pane binary tree.
6. `Pine/PaneNode.swift` (lines 1-399) — `indirect enum PaneNode` (`.leaf` / `.split`), `enum PaneContent` (`.editor` / `.terminal`), `struct PaneID`.
7. `Pine/TabManager.swift` (lines 1-411) — `final class TabManager`. Editor tab lifecycle (open/close/save/saveAs/duplicate), dirty tracking, delegates auto-save to `Tabs/TabAutoSave.swift` (`final class TabAutoSave`).
8. `Pine/WorkspaceManager.swift` (lines 1-458) — `final class WorkspaceManager`. Async two-phase file tree loading (shallow → full), git integration, `FileSystemWatcher`.
9. `Pine/GitStatusProvider.swift` (lines 1-356) — `final class GitStatusProvider`. Runs `git status`/`git diff`/branch listing. Delegates parsing to `Git/GitParser.swift`, commands to `Git/GitCommand.swift`, fetching to `Git/GitFetcher.swift`.
10. `Pine/SyntaxHighlighter.swift` (lines 1-312) — `nonisolated final class SyntaxHighlighter: @unchecked Sendable`. Singleton; loads JSON grammars from `Pine/Grammars/` (37 files). Engine lives in `Pine/Syntax/SyntaxHighlightEngine.swift` (451 lines).
11. `Pine/SessionState.swift` (lines 1-226) — `struct SessionState: Codable, Sendable`. Persists project path, open tabs, pane tree, terminal counts to UserDefaults.
12. `Pine/TerminalSession.swift` (lines 1-1075) — SwiftTerm `LocalProcessTerminalView` lifecycle (2nd largest app file).
13. `Pine/TerminalManager.swift` (lines 1-90) — `final class TerminalManager`. Routes Cmd+T / Cmd+\` to terminal panes.
14. `Pine/PineAppNotifications.swift` — `extension Notification.Name` with all notification constants (`openFolder`, `closeTab`, `findInFile`, `findAndReplace`, etc.).
15. `Pine/FocusedProjectKey.swift` — `FocusedValueKey` passing active `ProjectManager` to menu commands.

## Key Code

### Entry points
- `PineApp.swift:17` — `struct PineApp: App` (`@main`)
- `PineApp.swift:381` — `class AppDelegate: NSObject, NSApplicationDelegate, SPUUpdaterDelegate`
- `ContentView.swift` — SwiftUI root, `NavigationSplitView`
- `ProjectManager.swift:14` — `final class ProjectManager` (central state hub)

### Core type signatures (verified)
```swift
final class ProjectManager         // ProjectManager.swift:14 — owns pane/tab/terminal/workspace/git
final class PaneManager            // PaneManager.swift:14 — split-pane tree owner
indirect enum PaneNode             // PaneNode.swift:45 — .leaf / .split binary tree
enum PaneContent                  // PaneNode.swift:23 — .editor / .terminal
final class TabManager            // TabManager.swift:23 — editor tab lifecycle
final class WorkspaceManager      // WorkspaceManager.swift:17 — file tree + git + watcher
final class GitStatusProvider     // GitStatusProvider.swift:14 — git status/diff/branch
nonisolated final class SyntaxHighlighter: @unchecked Sendable  // SyntaxHighlighter.swift:14
final class ProjectSearchProvider // ProjectSearchProvider.swift:34
nonisolated final class FileSystemWatcher                        // FileSystemWatcher.swift:12
final class TerminalManager       // TerminalManager.swift:90
final class TabAutoSave           // Tabs/TabAutoSave.swift:13 — auto-save coordinator
final class MinimapView: NSView   // MinimapView.swift:39
enum FoldRangeCalculator          // FoldRangeCalculator.swift — bracket-pair fold detection
struct FoldState                  // FoldState.swift — folded-range set
final class MarkdownRenderer      // MarkdownRenderer.swift — AST → NSAttributedString
struct MarkdownPreviewView: NSViewRepresentable                  // MarkdownPreviewView.swift
final class QuickOpenProvider     // QuickOpenProvider.swift:13 — fuzzy file finder
enum SymbolParser                 // SymbolParser.swift — regex symbol extraction
final class ExternalFileFormatter: FileFormatter, Sendable       // ExternalFileFormatter.swift:126
struct FileFormatterRegistry: Sendable                           // FileFormatter.swift:281
enum SmartListContinuation        // SmartListContinuation.swift:32
```

### Notification routing
`PineAppMenuCommands.swift` posts to `NotificationCenter.default`; `ContentView` receives via `GitAndNotificationObserver`. All names in `PineAppNotifications.swift` (e.g. `Notification.Name.findInFile`, `.findAndReplace`, `.openFolder`, `.closeTab`).

### Find & Replace
`CodeEditorView.swift:131` sets `textView.usesFindBar = true`. Coordinator registers handlers (`CodeEditorView.swift:285-286`) for `.findInFile` / `.findAndReplace`. Cmd+F / Cmd+Option+F / Cmd+G / Cmd+Shift+G wired in `PineAppMenuCommands.swift:185-193`.

### Auto-save
`TabManager.swift:320` holds `private let autoSaveCoordinator = TabAutoSave()`. Toggle via `@AppStorage(TabManager.autoSaveKey)` in `PineAppMenuCommands.swift:34`. UserDefaults key `"autoSaveEnabled"`.

## Architecture

**Pattern:** MVVM with SwiftUI views backed by AppKit via `NSViewRepresentable`. `@Observable` macro throughout.

**State hub:** `ProjectManager` (one per open project, deduplicated by `ProjectRegistry`). It composes:
```
ProjectManager
├── PaneManager          (split-pane binary tree)
│   ├── editor leaves  → per-pane TabManager
│   └── terminal leaves → per-pane TerminalPaneState
├── TabManager           (primary editor tabs; format-on-save, auto-save)
├── TerminalManager      (routes Cmd+T / Cmd+`)
├── WorkspaceManager     (file tree + FileSystemWatcher + git delegation)
└── GitStatusProvider    (git status/diff/branch)
```

**AppKit bridges:**
- `CodeEditorView` → `NSScrollView` + `GutterTextView` (NSTextView subclass) + `LineNumberGutter`
- `TerminalContentView` / `TerminalSession` → SwiftTerm `LocalProcessTerminalView`
- `MinimapView` → `NSView` (12% scaled overview)
- `MarkdownPreviewView` → `NSViewRepresentable`

**Text system:** `NSTextStorage → NSLayoutManager → NSTextContainer → GutterTextView`.

**Command flow:** Menu items (`PineAppMenuCommands.swift`) → `NotificationCenter.default.post` → `GitAndNotificationObserver` in `ContentView` → `TabManager` / `ProjectManager` via `@FocusedValue(\.projectManager)`.

**Concurrency:** GCD bridged to async/await. Generation tokens (`HighlightGeneration`, `WorkspaceManager.loadGeneration`, `FileSystemWatcher.activeGeneration`) prevent stale results. Debounce: syntax highlight 100ms (edit) / 50ms (scroll), fold recalc 150ms, project search 300ms, watcher ~0.5s, minimap 25ms.

**Session persistence:** `SessionState` (Codable) saved to UserDefaults on termination by `AppDelegate`; restored in `ContentView.restoreSessionIfNeeded()`.

**Subsystems → owner type:**
| Subsystem | Owner | File |
|---|---|---|
| Split panes | `PaneManager` | `PaneManager.swift` |
| Editor tabs | `TabManager` | `TabManager.swift` |
| Terminal | `TerminalManager` / `TerminalSession` / `TerminalPaneState` | `TerminalManager.swift` etc. |
| Git integration | `GitStatusProvider` (+ `Git/` subdir) | `GitStatusProvider.swift` |
| Syntax highlighting | `SyntaxHighlighter` (+ `Syntax/` engine) | `SyntaxHighlighter.swift` |
| Minimap | `MinimapView` | `MinimapView.swift` |
| Code folding | `FoldRangeCalculator` / `FoldState` | `FoldRangeCalculator.swift` |
| Find & Replace | `GutterTextView` (NSTextView find bar) | `CodeEditorView.swift:131` |
| Project search | `ProjectSearchProvider` | `ProjectSearchProvider.swift` |
| Status bar | `StatusBarInfo` / `StatusBarView` | `StatusBarInfo.swift` |
| Format-on-save | `FileFormatterRegistry` / `ExternalFileFormatter` | `FileFormatter.swift` |
| Smart list continuation | `SmartListContinuation` (enum) | `SmartListContinuation.swift` |
| Auto-save | `TabAutoSave` (via `TabManager`) | `Tabs/TabAutoSave.swift` |
| File system watching | `FileSystemWatcher` | `FileSystemWatcher.swift` |
| Session persistence | `SessionState` | `SessionState.swift` |
| Quick Open | `QuickOpenProvider` | `QuickOpenProvider.swift` |
| Symbol Navigator | `SymbolParser` / `SymbolNavigatorView` | `SymbolParser.swift` |
| Markdown preview | `MarkdownRenderer` / `MarkdownPreviewView` | `MarkdownRenderer.swift` |

## Dependencies (confirmed via `Pine.xcodeproj/project.pbxproj`)

All three via XCRemoteSwiftPackageReference (objectVersion 77, `PBXFileSystemSynchronizedRootGroup`):

| Package | Repository URL |
|---|---|
| SwiftTerm | `https://github.com/migueldeicaza/SwiftTerm.git` |
| Sparkle | `https://github.com/sparkle-project/Sparkle.git` |
| swift-markdown | `https://github.com/swiftlang/swift-markdown.git` |

Sparkle imported in `PineApp.swift:13` (`import Sparkle`); `AppDelegate` conforms to `SPUUpdaterDelegate`.

## Repository Layout

```
Pine.xcodeproj/          # objectVersion 77 (PBXFileSystemSynchronizedRootGroup)
Pine/                    # App target (147 .swift files, 28,662 LOC)
├── Git/                 # GitCheckout, GitCommand, GitFetcher, GitModels, GitParser (6 files)
├── Syntax/              # CompiledGrammar, GrammarRegistry, SyntaxHighlightEngine, etc. (5 files)
├── Tabs/                # TabAutoSave, TabCollection, TabDuplicator, TabFormatter, etc. (7 files)
├── Concurrency/         # BackgroundDispatch
├── Validators/          # Dockerfile/Shell/Terraform/YAML validators (6 files)
├── Grammars/            # 37 JSON grammar files
├── Assets.xcassets/ AppIcon.icon/ Resources/
PineTests/               # Unit tests (218 .swift files, 64,274 LOC) — Swift Testing
PineUITests/             # XCUITest (31 .swift files, 6,453 LOC)
PinePerformanceTests/    # XCTest measure{} (9 .swift files, 1,976 LOC)
scripts/                 # normalize-xcstrings.sh, update-screenshots.sh, tests/
.github/workflows/       # ci.yml, release.yml, release-please.yml, nightly-perf/fuzz, screenshots, claude.yml
assets/ docs/ build/
```

## LOC Summary

| Target | Files | LOC |
|---|---|---|
| `Pine` (app) | 147 | 28,662 |
| `PineTests` | 218 | 64,274 |
| `PineUITests` | 31 | 6,453 |
| `PinePerformanceTests` | 9 | 1,976 |
| **Total** | **405** | **101,365** |

Version: `1.27.2` (from `version.txt`).

## Start Here

Open **`Pine/PineApp.swift`** first — it is the `@main` entry, defines `AppDelegate` (Sparkle, window creation, `CloseDelegate`), and references all notification names and menu command wiring. Then **`Pine/ProjectManager.swift`** to see how the central state composes `PaneManager`, `TabManager`, `TerminalManager`, `WorkspaceManager`, and `GitStatusProvider`. For UI, **`Pine/ContentView.swift`** + **`Pine/PaneManager.swift`** + **`Pine/PaneNode.swift`** explain the split-pane tree and rendering.

## Supervisor coordination

No blocking issues. All requested files verified to exist with confirmed line counts and owner types. Dependencies confirmed in `project.pbxproj`. No file reads required from a supervisor.
