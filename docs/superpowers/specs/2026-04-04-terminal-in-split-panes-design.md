# Terminal in Split Panes

## Overview

Integrate terminal tabs into the split pane system so they live alongside editor panes in the same PaneNode tree. The current global bottom terminal panel is removed. Terminal panes are first-class citizens in the split layout — they can be created, moved, resized, and closed just like editor panes.

**Closes:** #543 (extends split panes to terminal)

## Requirements

1. **Terminal as pane type.** Each leaf in PaneNode is either `.editor` or `.terminal`. Terminal-panели contain only terminal tabs, editor-панели contain only editor tabs. Types never mix in one tab bar.

2. **Drag-and-drop.** Terminal tabs support drag between terminal-панелей and drag-to-edge to create new terminal-панели. Drag validation prevents dropping terminal tabs into editor-панели and vice versa.

3. **Cmd+T** creates a new terminal tab in the last-used terminal-панель. If no terminal-панель exists, creates one via vertical split below the active editor-панель.

4. **Cmd+\`** focuses the nearest terminal-панель. If none exists, creates one (same as Cmd+T).

5. **Cmd+W** closes the active tab (editor or terminal). Closing the last tab in a pane removes the pane from the tree.

6. **Maximize** — a button in the terminal tab bar expands that terminal-панель to fill the entire editor area, hiding all other panes. Toggle again to restore the previous layout.

7. **Session persistence** — terminal-панель positions are saved/restored via PaneNode tree serialization. Terminal processes are recreated on restore (scrollback lost, as today).

8. **No bottom panel** — the current VSplitView-based terminal area in ContentView is removed. All terminal rendering goes through PaneTreeView.

## Architecture

### Data Model

#### PaneContent (existing, modified)

```swift
enum PaneContent: String, Hashable, Codable, Sendable {
    case editor
    case terminal  // restored — was removed in PR #704
}
```

#### TerminalPaneState (new)

Per-pane terminal state. Replaces the global TerminalManager's tab ownership.

```swift
@MainActor
@Observable
final class TerminalPaneState {
    var terminalTabs: [TerminalTab] = []
    var activeTerminalID: UUID?
    var pendingFocusTabID: UUID?
    var isSearchVisible: Bool = false
    var terminalSearchQuery: String = ""

    func addTab(workingDirectory: URL?) -> TerminalTab
    func removeTab(id: UUID)
    func activeTab() -> TerminalTab?
}
```

#### PaneManager (existing, extended)

Gains a second dictionary for terminal pane state:

```swift
@MainActor
@Observable
final class PaneManager {
    private(set) var root: PaneNode
    private(set) var tabManagers: [PaneID: TabManager] = [:]          // editor leaves
    private(set) var terminalStates: [PaneID: TerminalPaneState] = [:] // terminal leaves

    var activePaneID: PaneID

    // Maximize support
    private var savedRootBeforeMaximize: PaneNode?
    private var maximizedPaneID: PaneID?
    var isMaximized: Bool { maximizedPaneID != nil }

    func maximize(paneID: PaneID)
    func restoreFromMaximize()
}
```

When splitting to create a terminal pane, PaneManager creates a `TerminalPaneState` instead of a `TabManager`, based on `PaneContent`.

#### TerminalManager (existing, refactored)

Becomes a coordinator/facade. No longer owns terminal tabs directly.

```swift
@MainActor
@Observable
final class TerminalManager {
    weak var paneManager: PaneManager?

    /// ID of the last-focused terminal pane (for Cmd+T routing).
    var lastActiveTerminalPaneID: PaneID?

    /// Creates a terminal tab in the appropriate pane.
    /// If no terminal pane exists, creates one via split.
    func createTerminalTab(workingDirectory: URL?)

    /// Focuses the nearest terminal pane, or creates one.
    func focusOrCreateTerminal(workingDirectory: URL?)

    /// All terminal tabs across all panes (for session save, etc.).
    var allTerminalTabs: [TerminalTab]

    /// Starts terminals on app launch for restored panes.
    func startTerminals(workingDirectory: URL?)
}
```

#### TabDragInfo (existing, extended)

Add content type for drag validation:

```swift
struct TabDragInfo: Codable, Sendable {
    let paneID: UUID
    let tabID: UUID
    let fileURL: URL
    let contentType: String  // "editor" or "terminal"
}
```

### UI Rendering

#### PaneLeafView (existing, extended)

Switches on `PaneContent`:

```swift
struct PaneLeafView: View {
    let paneID: PaneID
    let content: PaneContent  // new parameter

    var body: some View {
        switch content {
        case .editor:
            EditorPaneContent(paneID: paneID)
        case .terminal:
            TerminalPaneContent(paneID: paneID)
        }
    }
}
```

#### TerminalPaneContent (new)

Renders terminal tab bar + terminal view for a single pane:

```swift
struct TerminalPaneContent: View {
    let paneID: PaneID
    @Environment(PaneManager.self) private var paneManager

    var body: some View {
        VStack(spacing: 0) {
            TerminalPaneTabBar(paneID: paneID)  // with DnD support
            TerminalSearchBarContainer(...)
            TerminalContentView(...)
        }
    }
}
```

#### TerminalPaneTabBar (new, based on TerminalNativeTabBar)

Same visual style as current terminal tab bar, but with:
- `.onDrag()` support using `TabDragInfo` with `contentType: "terminal"`
- Maximize/restore button
- Plus button (add tab to this pane)
- Close button per tab

#### Drop Validation

`PaneSplitDropDelegate` and `EditorAreaUnifiedDropDelegate` check `contentType`:
- Drop on existing pane: only accept if content types match
- Drop on edge (split): always accept — creates new pane of matching type

### Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| Cmd+T | New terminal tab → last-used terminal pane, or create terminal pane below active editor |
| Cmd+\` | Focus terminal pane, or create if none |
| Cmd+W | Close active tab (editor or terminal). Empty pane → remove from tree |
| Ctrl+Tab | Next tab within active pane |
| Ctrl+Shift+Tab | Previous tab within active pane |

### Maximize

PaneManager stores the current `root` tree and replaces it with a single leaf containing the maximized terminal pane. All other panes are hidden but their state (TabManagers, TerminalPaneStates) is preserved. Restore swaps back the saved root.

```swift
func maximize(paneID: PaneID) {
    guard maximizedPaneID == nil else { return }
    savedRootBeforeMaximize = root
    root = .leaf(paneID, root.content(for: paneID) ?? .terminal)
    maximizedPaneID = paneID
}

func restoreFromMaximize() {
    guard let saved = savedRootBeforeMaximize else { return }
    root = saved
    savedRootBeforeMaximize = nil
    maximizedPaneID = nil
}
```

### Session Persistence

SessionState already serializes PaneNode tree. Since `PaneContent` is Codable (`.editor` / `.terminal`), terminal pane positions are saved automatically.

Additional fields in SessionState:
```swift
/// Maps terminal pane ID to number of terminal tabs to recreate.
var terminalPaneTabCounts: [String: Int]?
/// Maps terminal pane ID to active terminal tab index.
var terminalPaneActiveIndices: [String: Int]?
```

On restore:
1. Decode PaneNode tree (terminal leaves are preserved)
2. Create TerminalPaneState for each terminal leaf
3. Create N terminal tabs per pane from `terminalPaneTabCounts`
4. Start terminal processes with project working directory

### Migration from Current Architecture

1. **ContentView** — remove `VSplitView` with separate `terminalArea`. The entire detail area becomes `PaneTreeView(node: paneManager.root)`. No conditional `if paneManager.root.leafCount > 1` — always use PaneTreeView.

2. **TerminalManager** — gut tab ownership. Keep as coordinator with `lastActiveTerminalPaneID` and routing logic. Remove `terminalTabs` array, `isTerminalVisible`, replace `isTerminalMaximized` with PaneManager's maximize.

3. **TerminalBarView** — split into `TerminalPaneTabBar` (per-pane, with DnD) and remove old `TerminalNativeTabBar`.

4. **TerminalSession** — `TerminalContainerView` and `TerminalTab` stay mostly unchanged. They move from being managed by global TerminalManager to per-pane TerminalPaneState.

5. **Old sessions** — if a restored session has no terminal panes in the tree, Cmd+T creates one normally. No crash, no data loss.

## Out of Scope

- Mixed tabs (terminal + editor in one tab bar)
- Drag editor tab into terminal pane or vice versa
- Multiple simultaneous maximizes
- Scrollback persistence between sessions
- Terminal search redesign (stays per-tab as-is)

## Test Plan

### Unit Tests
- TerminalPaneState: add/remove tabs, active tab tracking
- PaneManager: create terminal pane, split, move terminal tabs between panes, maximize/restore
- PaneNode: `.terminal` content serialization/deserialization
- TabDragInfo: contentType encoding/decoding
- Drop validation: reject cross-type drops
- Cmd+T routing: last-used pane, fallback to create
- Session restore with terminal panes

### UI Tests
- Create terminal via Cmd+T, verify pane appears
- Cmd+\` focuses terminal pane
- Close last terminal tab → pane removed
- Maximize/restore terminal pane
- Session restore preserves terminal pane layout

### Manual Tests
- Drag terminal tab to edge → split creates terminal pane
- Drag terminal tab between terminal panes → tab moves
- Drag terminal tab to editor pane → rejected (no drop zone highlight)
- Resize divider between editor and terminal panes
- TUI apps (vim, htop) work in split terminal pane
- oh-my-zsh renders correctly in split pane
