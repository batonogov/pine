# Terminal in Split Panes — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Integrate terminal tabs into the split pane tree so they can be dragged, split, and positioned alongside editor panes — like Zed editor.

**Architecture:** `PaneContent.terminal` is restored. Each terminal leaf owns a `TerminalPaneState` (per-pane terminal tabs). `TerminalManager` becomes a coordinator routing Cmd+T/Cmd+` to the right pane. The global bottom terminal panel (VSplitView in ContentView) is removed — all rendering goes through PaneTreeView.

**Tech Stack:** SwiftUI, AppKit (NSViewRepresentable), SwiftTerm, Swift Testing

**Spec:** `docs/superpowers/specs/2026-04-04-terminal-in-split-panes-design.md`

---

### Task 1: Restore PaneContent.terminal and update PaneNode

**Files:**
- Modify: `Pine/PaneNode.swift:23-25`
- Test: `PineTests/PaneNodeTests.swift`

- [ ] **Step 1: Write failing test for .terminal content type**

In `PineTests/PaneNodeTests.swift`, add:

```swift
@Test func terminalContentType_encodeDecode() throws {
    let id = PaneID()
    let node = PaneNode.leaf(id, .terminal)
    let data = try JSONEncoder().encode(node)
    let decoded = try JSONDecoder().decode(PaneNode.self, from: data)
    #expect(decoded.content(for: id) == .terminal)
}

@Test func splitEditorAndTerminal_leafCount() {
    let editorID = PaneID()
    let terminalID = PaneID()
    let tree = PaneNode.split(
        .vertical,
        first: .leaf(editorID, .editor),
        second: .leaf(terminalID, .terminal),
        ratio: 0.7
    )
    #expect(tree.leafCount == 2)
    #expect(tree.content(for: editorID) == .editor)
    #expect(tree.content(for: terminalID) == .terminal)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project Pine.xcodeproj -scheme Pine -destination 'platform=macOS' -only-testing:PineTests/PaneNodeTests/terminalContentType_encodeDecode`

Expected: FAIL — `.terminal` case does not exist

- [ ] **Step 3: Add .terminal case to PaneContent**

In `Pine/PaneNode.swift`, line 24, change:

```swift
enum PaneContent: String, Hashable, Codable, Sendable {
    case editor
    case terminal
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project Pine.xcodeproj -scheme Pine -destination 'platform=macOS' -only-testing:PineTests/PaneNodeTests/terminalContentType_encodeDecode`

Expected: PASS

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project Pine.xcodeproj -scheme Pine -destination 'platform=macOS' -only-testing:PineTests/PaneNodeTests/splitEditorAndTerminal_leafCount`

Expected: PASS

- [ ] **Step 5: Run all existing PaneNode tests to check no regressions**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project Pine.xcodeproj -scheme Pine -destination 'platform=macOS' -only-testing:PineTests/PaneNodeTests`

Expected: All PASS

- [ ] **Step 6: Commit**

```bash
git add Pine/PaneNode.swift PineTests/PaneNodeTests.swift
git commit -m "feat: restore PaneContent.terminal case for split pane integration"
```

---

### Task 2: Create TerminalPaneState

**Files:**
- Create: `Pine/TerminalPaneState.swift`
- Test: `PineTests/TerminalPaneStateTests.swift`

- [ ] **Step 1: Write failing tests**

Create `PineTests/TerminalPaneStateTests.swift`:

```swift
//
//  TerminalPaneStateTests.swift
//  PineTests
//

import Testing
import Foundation
@testable import Pine

@Suite("TerminalPaneState Tests")
@MainActor
struct TerminalPaneStateTests {

    @Test func init_startsEmpty() {
        let state = TerminalPaneState()
        #expect(state.terminalTabs.isEmpty)
        #expect(state.activeTerminalID == nil)
    }

    @Test func addTab_createsTabAndSetsActive() {
        let state = TerminalPaneState()
        let tab = state.addTab(workingDirectory: nil)
        #expect(state.terminalTabs.count == 1)
        #expect(state.activeTerminalID == tab.id)
    }

    @Test func addMultipleTabs_activeIsLast() {
        let state = TerminalPaneState()
        _ = state.addTab(workingDirectory: nil)
        let second = state.addTab(workingDirectory: nil)
        #expect(state.terminalTabs.count == 2)
        #expect(state.activeTerminalID == second.id)
    }

    @Test func removeTab_updatesActive() {
        let state = TerminalPaneState()
        let first = state.addTab(workingDirectory: nil)
        let second = state.addTab(workingDirectory: nil)
        state.removeTab(id: second.id)
        #expect(state.terminalTabs.count == 1)
        #expect(state.activeTerminalID == first.id)
    }

    @Test func removeLastTab_activeBecomesNil() {
        let state = TerminalPaneState()
        let tab = state.addTab(workingDirectory: nil)
        state.removeTab(id: tab.id)
        #expect(state.terminalTabs.isEmpty)
        #expect(state.activeTerminalID == nil)
    }

    @Test func activeTab_returnsCorrectTab() {
        let state = TerminalPaneState()
        let tab = state.addTab(workingDirectory: nil)
        #expect(state.activeTab?.id == tab.id)
    }

    @Test func activeTab_nilWhenEmpty() {
        let state = TerminalPaneState()
        #expect(state.activeTab == nil)
    }

    @Test func pendingFocusTabID_setOnAdd() {
        let state = TerminalPaneState()
        let tab = state.addTab(workingDirectory: nil)
        #expect(state.pendingFocusTabID == tab.id)
    }

    @Test func tabCount_returnsCorrectCount() {
        let state = TerminalPaneState()
        #expect(state.tabCount == 0)
        _ = state.addTab(workingDirectory: nil)
        #expect(state.tabCount == 1)
        _ = state.addTab(workingDirectory: nil)
        #expect(state.tabCount == 2)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project Pine.xcodeproj -scheme Pine -destination 'platform=macOS' -only-testing:PineTests/TerminalPaneStateTests`

Expected: FAIL — TerminalPaneState does not exist

- [ ] **Step 3: Implement TerminalPaneState**

Create `Pine/TerminalPaneState.swift`:

```swift
//
//  TerminalPaneState.swift
//  Pine
//
//  Per-pane terminal state. Each terminal leaf in the PaneNode tree
//  owns one TerminalPaneState managing its terminal tabs.
//

import SwiftUI

@MainActor
@Observable
final class TerminalPaneState {
    var terminalTabs: [TerminalTab] = []
    var activeTerminalID: UUID?
    var pendingFocusTabID: UUID?

    // MARK: - Search state (per-pane)

    var isSearchVisible = false
    var terminalSearchQuery = ""
    var isSearchCaseSensitive = false

    // MARK: - Computed

    var activeTab: TerminalTab? {
        guard let id = activeTerminalID else { return nil }
        return terminalTabs.first { $0.id == id }
    }

    var tabCount: Int { terminalTabs.count }

    // MARK: - Tab management

    @discardableResult
    func addTab(workingDirectory: URL?) -> TerminalTab {
        let number = terminalTabs.count + 1
        let tab = TerminalTab(name: Strings.terminalNumberedName(number))
        tab.configure(workingDirectory: workingDirectory)
        terminalTabs.append(tab)
        activeTerminalID = tab.id
        pendingFocusTabID = tab.id
        return tab
    }

    func removeTab(id: UUID) {
        guard let tab = terminalTabs.first(where: { $0.id == id }) else { return }
        tab.stop()
        terminalTabs.removeAll { $0.id == id }
        if activeTerminalID == id {
            activeTerminalID = terminalTabs.last?.id
        }
    }

    func startTabs(workingDirectory: URL?) {
        for tab in terminalTabs {
            tab.configure(workingDirectory: workingDirectory)
        }
        if activeTerminalID == nil {
            activeTerminalID = terminalTabs.first?.id
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project Pine.xcodeproj -scheme Pine -destination 'platform=macOS' -only-testing:PineTests/TerminalPaneStateTests`

Expected: All PASS

- [ ] **Step 5: Commit**

```bash
git add Pine/TerminalPaneState.swift PineTests/TerminalPaneStateTests.swift
git commit -m "feat: add TerminalPaneState for per-pane terminal tab management"
```

---

### Task 3: Extend PaneManager with terminal pane support

**Files:**
- Modify: `Pine/PaneManager.swift`
- Test: `PineTests/PaneManagerTests.swift`

- [ ] **Step 1: Write failing tests for terminal pane operations**

Add to `PineTests/PaneManagerTests.swift`:

```swift
// MARK: - Terminal pane operations

@Test func createTerminalPane_splitsBelowEditor() {
    let manager = PaneManager()
    let editorPane = manager.activePaneID

    let terminalPaneID = manager.createTerminalPane(
        relativeTo: editorPane,
        axis: .vertical,
        workingDirectory: nil
    )
    #expect(terminalPaneID != nil)
    #expect(manager.root.leafCount == 2)
    #expect(manager.root.content(for: terminalPaneID!) == .terminal)
    #expect(manager.terminalStates[terminalPaneID!] != nil)
}

@Test func createTerminalPane_hasOneTab() {
    let manager = PaneManager()
    let editorPane = manager.activePaneID

    guard let terminalPaneID = manager.createTerminalPane(
        relativeTo: editorPane,
        axis: .vertical,
        workingDirectory: nil
    ) else {
        Issue.record("createTerminalPane failed")
        return
    }

    let state = manager.terminalState(for: terminalPaneID)
    #expect(state?.tabCount == 1)
}

@Test func removeTerminalPane_cleansUpState() {
    let manager = PaneManager()
    let editorPane = manager.activePaneID

    guard let terminalPaneID = manager.createTerminalPane(
        relativeTo: editorPane,
        axis: .vertical,
        workingDirectory: nil
    ) else {
        Issue.record("createTerminalPane failed")
        return
    }

    manager.removePane(terminalPaneID)
    #expect(manager.terminalStates[terminalPaneID] == nil)
    #expect(manager.root.leafCount == 1)
}

@Test func terminalPaneIDs_returnsOnlyTerminalLeaves() {
    let manager = PaneManager()
    let editorPane = manager.activePaneID

    _ = manager.createTerminalPane(
        relativeTo: editorPane,
        axis: .vertical,
        workingDirectory: nil
    )

    #expect(manager.terminalPaneIDs.count == 1)
    #expect(manager.root.leafCount == 2)
}

@Test func allTerminalTabs_collectsFromAllPanes() {
    let manager = PaneManager()
    let editorPane = manager.activePaneID

    guard let tp1 = manager.createTerminalPane(
        relativeTo: editorPane, axis: .vertical, workingDirectory: nil
    ) else {
        Issue.record("createTerminalPane failed")
        return
    }
    guard let tp2 = manager.createTerminalPane(
        relativeTo: tp1, axis: .horizontal, workingDirectory: nil
    ) else {
        Issue.record("createTerminalPane failed")
        return
    }

    // Each terminal pane starts with 1 tab
    #expect(manager.allTerminalTabs.count == 2)
}

@Test func maximize_hidesOtherPanes() {
    let manager = PaneManager()
    let editorPane = manager.activePaneID

    guard let terminalPane = manager.createTerminalPane(
        relativeTo: editorPane, axis: .vertical, workingDirectory: nil
    ) else {
        Issue.record("createTerminalPane failed")
        return
    }

    manager.maximize(paneID: terminalPane)
    #expect(manager.isMaximized)
    #expect(manager.root.leafCount == 1)
    #expect(manager.root.content(for: terminalPane) == .terminal)
}

@Test func restoreFromMaximize_restoresLayout() {
    let manager = PaneManager()
    let editorPane = manager.activePaneID

    guard let terminalPane = manager.createTerminalPane(
        relativeTo: editorPane, axis: .vertical, workingDirectory: nil
    ) else {
        Issue.record("createTerminalPane failed")
        return
    }

    manager.maximize(paneID: terminalPane)
    manager.restoreFromMaximize()
    #expect(!manager.isMaximized)
    #expect(manager.root.leafCount == 2)
}

@Test func maximize_alreadyMaximized_doesNothing() {
    let manager = PaneManager()
    let editorPane = manager.activePaneID

    guard let terminalPane = manager.createTerminalPane(
        relativeTo: editorPane, axis: .vertical, workingDirectory: nil
    ) else {
        Issue.record("createTerminalPane failed")
        return
    }

    manager.maximize(paneID: terminalPane)
    let rootAfterFirst = manager.root
    manager.maximize(paneID: terminalPane)
    #expect(manager.root == rootAfterFirst)
}

@Test func moveTerminalTab_betweenTerminalPanes() {
    let manager = PaneManager()
    let editorPane = manager.activePaneID

    guard let tp1 = manager.createTerminalPane(
        relativeTo: editorPane, axis: .vertical, workingDirectory: nil
    ) else {
        Issue.record("createTerminalPane failed")
        return
    }

    // Add second tab to tp1
    let state1 = manager.terminalState(for: tp1)!
    _ = state1.addTab(workingDirectory: nil)
    #expect(state1.tabCount == 2)

    guard let tp2 = manager.createTerminalPane(
        relativeTo: tp1, axis: .horizontal, workingDirectory: nil
    ) else {
        Issue.record("createTerminalPane failed")
        return
    }

    let tabToMove = state1.terminalTabs.first!
    manager.moveTerminalTab(tabToMove.id, from: tp1, to: tp2)

    #expect(manager.terminalState(for: tp1)?.tabCount == 1)
    #expect(manager.terminalState(for: tp2)?.tabCount == 2)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project Pine.xcodeproj -scheme Pine -destination 'platform=macOS' -only-testing:PineTests/PaneManagerTests/createTerminalPane_splitsBelowEditor`

Expected: FAIL — method does not exist

- [ ] **Step 3: Implement terminal pane support in PaneManager**

In `Pine/PaneManager.swift`, add the `terminalStates` dictionary and new methods. After line 20 (`tabManagers`):

```swift
    /// Per-pane terminal states, keyed by PaneID.
    private(set) var terminalStates: [PaneID: TerminalPaneState] = [:]

    /// Saved root before maximize, for restore.
    private var savedRootBeforeMaximize: PaneNode?

    /// ID of the currently maximized pane, if any.
    private(set) var maximizedPaneID: PaneID?

    /// Whether a pane is currently maximized.
    var isMaximized: Bool { maximizedPaneID != nil }
```

Add after the `removePane` method (after line 119):

```swift
    // MARK: - Terminal pane operations

    /// Returns the TerminalPaneState for a given pane.
    func terminalState(for paneID: PaneID) -> TerminalPaneState? {
        terminalStates[paneID]
    }

    /// IDs of all terminal-type leaves.
    var terminalPaneIDs: [PaneID] {
        root.leafIDs.filter { root.content(for: $0) == .terminal }
    }

    /// All terminal tabs across all terminal panes.
    var allTerminalTabs: [TerminalTab] {
        terminalStates.values.flatMap(\.terminalTabs)
    }

    /// Creates a new terminal pane by splitting the target pane.
    /// Returns the new pane's ID, or nil if split failed.
    @discardableResult
    func createTerminalPane(
        relativeTo targetID: PaneID,
        axis: SplitAxis,
        workingDirectory: URL?
    ) -> PaneID? {
        let newID = PaneID()
        guard let newRoot = root.splitting(
            targetID,
            axis: axis,
            newPaneID: newID,
            newContent: .terminal
        ) else { return nil }

        root = newRoot
        let state = TerminalPaneState()
        state.addTab(workingDirectory: workingDirectory)
        terminalStates[newID] = state
        activePaneID = newID
        return newID
    }

    /// Moves a terminal tab from one terminal pane to another.
    func moveTerminalTab(_ tabID: UUID, from sourceID: PaneID, to targetID: PaneID) {
        guard let srcState = terminalStates[sourceID],
              let dstState = terminalStates[targetID],
              let tab = srcState.terminalTabs.first(where: { $0.id == tabID }) else { return }

        // Add to destination first
        dstState.terminalTabs.append(tab)
        dstState.activeTerminalID = tab.id

        // Remove from source (don't stop the process — we're moving, not closing)
        srcState.terminalTabs.removeAll { $0.id == tabID }
        if srcState.activeTerminalID == tabID {
            srcState.activeTerminalID = srcState.terminalTabs.last?.id
        }

        activePaneID = targetID

        // Clean up empty terminal panes
        if srcState.terminalTabs.isEmpty {
            removePane(sourceID)
        }
    }

    // MARK: - Maximize

    /// Maximizes a pane to fill the entire editor area.
    func maximize(paneID: PaneID) {
        guard maximizedPaneID == nil else { return }
        guard let content = root.content(for: paneID) else { return }
        savedRootBeforeMaximize = root
        root = .leaf(paneID, content)
        maximizedPaneID = paneID
    }

    /// Restores the layout from before maximize.
    func restoreFromMaximize() {
        guard let saved = savedRootBeforeMaximize else { return }
        root = saved
        savedRootBeforeMaximize = nil
        maximizedPaneID = nil
    }
```

Also update `removePane` to also clean up terminal states (modify existing method at line 108-119):

```swift
    func removePane(_ paneID: PaneID) {
        guard root.leafCount > 1,
              let newRoot = root.removing(paneID) else { return }

        tabManagers[paneID] = nil
        terminalStates[paneID] = nil
        root = newRoot

        if activePaneID == paneID {
            activePaneID = root.firstLeafID ?? activePaneID
        }
    }
```

Also update `restoreLayout` (line 140-164) to handle terminal leaves:

```swift
    func restoreLayout(
        from node: PaneNode,
        activePaneUUID: UUID?
    ) {
        let leafIDs = node.leafIDs

        var newTabManagers: [PaneID: TabManager] = [:]
        var newTerminalStates: [PaneID: TerminalPaneState] = [:]
        for leafID in leafIDs {
            switch node.content(for: leafID) {
            case .editor:
                newTabManagers[leafID] = TabManager()
            case .terminal:
                newTerminalStates[leafID] = TerminalPaneState()
            case nil:
                break
            }
        }

        root = node
        tabManagers = newTabManagers
        terminalStates = newTerminalStates

        if let uuid = activePaneUUID,
           let paneID = leafIDs.first(where: { $0.id == uuid }) {
            activePaneID = paneID
        } else if let firstLeaf = root.firstLeafID {
            activePaneID = firstLeaf
        }
    }
```

- [ ] **Step 4: Run new tests**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project Pine.xcodeproj -scheme Pine -destination 'platform=macOS' -only-testing:PineTests/PaneManagerTests/createTerminalPane_splitsBelowEditor`

Expected: PASS

Run all new terminal pane tests one by one to verify each passes.

- [ ] **Step 5: Run all PaneManager tests for regressions**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project Pine.xcodeproj -scheme Pine -destination 'platform=macOS' -only-testing:PineTests/PaneManagerTests`

Expected: All PASS

- [ ] **Step 6: Commit**

```bash
git add Pine/PaneManager.swift PineTests/PaneManagerTests.swift
git commit -m "feat: add terminal pane support to PaneManager with maximize/restore"
```

---

### Task 4: Extend TabDragInfo with contentType

**Files:**
- Modify: `Pine/TabDragInfo.swift`
- Test: `PineTests/TabDragInfoTests.swift`

- [ ] **Step 1: Write failing tests**

Add to `PineTests/TabDragInfoTests.swift`:

```swift
@Test func encode_includesContentType() {
    let info = TabDragInfo(
        paneID: UUID(),
        tabID: UUID(),
        fileURL: URL(fileURLWithPath: "/tmp/test.swift"),
        contentType: "editor"
    )
    let encoded = info.encoded
    #expect(encoded.contains("contentType"))
    #expect(encoded.contains("editor"))
}

@Test func decode_terminalContentType() {
    let info = TabDragInfo(
        paneID: UUID(),
        tabID: UUID(),
        fileURL: URL(fileURLWithPath: "/tmp/test"),
        contentType: "terminal"
    )
    let decoded = TabDragInfo.decode(from: info.encoded)
    #expect(decoded?.contentType == "terminal")
}

@Test func contentType_defaultsToEditor() {
    // Backwards compatibility: old encoded data without contentType
    let paneUUID = UUID()
    let tabUUID = UUID()
    let json = """
    {"paneID":"\(paneUUID.uuidString)","tabID":"\(tabUUID.uuidString)","fileURL":"file:///tmp/test.swift"}
    """
    let decoded = TabDragInfo.decode(from: json)
    #expect(decoded?.contentType == "editor")
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project Pine.xcodeproj -scheme Pine -destination 'platform=macOS' -only-testing:PineTests/TabDragInfoTests/encode_includesContentType`

Expected: FAIL — TabDragInfo has no contentType parameter

- [ ] **Step 3: Add contentType to TabDragInfo**

In `Pine/TabDragInfo.swift`, modify the struct:

```swift
struct TabDragInfo: Codable, Sendable {
    let paneID: UUID
    let tabID: UUID
    let fileURL: URL
    /// "editor" or "terminal". Defaults to "editor" for backwards compatibility.
    var contentType: String = "editor"

    var encoded: String {
        guard let data = try? JSONEncoder().encode(self),
              let string = String(data: data, encoding: .utf8) else {
            return ""
        }
        return string
    }

    static func decode(from string: String) -> TabDragInfo? {
        guard let data = string.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(TabDragInfo.self, from: data)
    }
}
```

- [ ] **Step 4: Run tests**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project Pine.xcodeproj -scheme Pine -destination 'platform=macOS' -only-testing:PineTests/TabDragInfoTests`

Expected: All PASS

- [ ] **Step 5: Commit**

```bash
git add Pine/TabDragInfo.swift PineTests/TabDragInfoTests.swift
git commit -m "feat: add contentType to TabDragInfo for terminal drag validation"
```

---

### Task 5: Refactor TerminalManager into coordinator

**Files:**
- Modify: `Pine/TerminalManager.swift`
- Test: `PineTests/TerminalManagerTests.swift` (create if not exists)

- [ ] **Step 1: Write failing tests for coordinator behavior**

Create or extend `PineTests/TerminalManagerTests.swift`:

```swift
//
//  TerminalManagerTests.swift
//  PineTests
//

import Testing
import Foundation
@testable import Pine

@Suite("TerminalManager Coordinator Tests")
@MainActor
struct TerminalManagerCoordinatorTests {

    @Test func createTerminalTab_noTerminalPane_createsOne() {
        let paneManager = PaneManager()
        let terminal = TerminalManager()
        terminal.paneManager = paneManager

        let editorPane = paneManager.activePaneID
        terminal.createTerminalTab(relativeTo: editorPane, workingDirectory: nil)

        #expect(paneManager.terminalPaneIDs.count == 1)
        let tpID = paneManager.terminalPaneIDs.first!
        #expect(paneManager.terminalState(for: tpID)?.tabCount == 1)
    }

    @Test func createTerminalTab_existingPane_addsTab() {
        let paneManager = PaneManager()
        let terminal = TerminalManager()
        terminal.paneManager = paneManager

        let editorPane = paneManager.activePaneID
        guard let tpID = paneManager.createTerminalPane(
            relativeTo: editorPane, axis: .vertical, workingDirectory: nil
        ) else {
            Issue.record("createTerminalPane failed")
            return
        }
        terminal.lastActiveTerminalPaneID = tpID

        terminal.createTerminalTab(relativeTo: editorPane, workingDirectory: nil)
        #expect(paneManager.terminalState(for: tpID)?.tabCount == 2)
    }

    @Test func focusOrCreateTerminal_existingPane_focusesIt() {
        let paneManager = PaneManager()
        let terminal = TerminalManager()
        terminal.paneManager = paneManager

        let editorPane = paneManager.activePaneID
        guard let tpID = paneManager.createTerminalPane(
            relativeTo: editorPane, axis: .vertical, workingDirectory: nil
        ) else {
            Issue.record("createTerminalPane failed")
            return
        }
        terminal.lastActiveTerminalPaneID = tpID

        // Switch focus to editor
        paneManager.activePaneID = editorPane

        terminal.focusOrCreateTerminal(relativeTo: editorPane, workingDirectory: nil)
        #expect(paneManager.activePaneID == tpID)
    }

    @Test func focusOrCreateTerminal_noPane_createsOne() {
        let paneManager = PaneManager()
        let terminal = TerminalManager()
        terminal.paneManager = paneManager

        let editorPane = paneManager.activePaneID
        terminal.focusOrCreateTerminal(relativeTo: editorPane, workingDirectory: nil)

        #expect(paneManager.terminalPaneIDs.count == 1)
    }

    @Test func allTerminalTabs_delegatesToPaneManager() {
        let paneManager = PaneManager()
        let terminal = TerminalManager()
        terminal.paneManager = paneManager

        let editorPane = paneManager.activePaneID
        _ = paneManager.createTerminalPane(
            relativeTo: editorPane, axis: .vertical, workingDirectory: nil
        )

        #expect(terminal.allTerminalTabs.count == 1)
    }

    @Test func hasActiveProcesses_checksAllPanes() {
        let paneManager = PaneManager()
        let terminal = TerminalManager()
        terminal.paneManager = paneManager

        // No terminal panes → no active processes
        #expect(!terminal.hasActiveProcesses)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project Pine.xcodeproj -scheme Pine -destination 'platform=macOS' -only-testing:PineTests/TerminalManagerCoordinatorTests`

Expected: FAIL

- [ ] **Step 3: Rewrite TerminalManager as coordinator**

Replace `Pine/TerminalManager.swift`:

```swift
//
//  TerminalManager.swift
//  Pine
//
//  Coordinator for terminal panes. Routes Cmd+T and Cmd+` to the
//  appropriate terminal pane via PaneManager.
//

import SwiftUI

@MainActor
@Observable
final class TerminalManager {
    /// Reference to the pane manager for creating/finding terminal panes.
    weak var paneManager: PaneManager?

    /// ID of the last-focused terminal pane (for Cmd+T routing).
    var lastActiveTerminalPaneID: PaneID?

    // MARK: - Tab creation

    /// Creates a terminal tab in the last-used terminal pane.
    /// If no terminal pane exists, creates one below the given editor pane.
    func createTerminalTab(relativeTo editorPaneID: PaneID, workingDirectory: URL?) {
        guard let pm = paneManager else { return }

        if let tpID = lastActiveTerminalPaneID,
           pm.terminalState(for: tpID) != nil {
            // Add tab to existing pane
            pm.terminalState(for: tpID)?.addTab(workingDirectory: workingDirectory)
            pm.activePaneID = tpID
        } else {
            // Create new terminal pane below
            if let newID = pm.createTerminalPane(
                relativeTo: editorPaneID,
                axis: .vertical,
                workingDirectory: workingDirectory
            ) {
                lastActiveTerminalPaneID = newID
            }
        }
    }

    /// Focuses the nearest terminal pane, or creates one.
    func focusOrCreateTerminal(relativeTo editorPaneID: PaneID, workingDirectory: URL?) {
        guard let pm = paneManager else { return }

        if let tpID = lastActiveTerminalPaneID,
           pm.terminalState(for: tpID) != nil {
            pm.activePaneID = tpID
        } else {
            // Find any terminal pane
            if let firstTP = pm.terminalPaneIDs.first {
                pm.activePaneID = firstTP
                lastActiveTerminalPaneID = firstTP
            } else {
                createTerminalTab(relativeTo: editorPaneID, workingDirectory: workingDirectory)
            }
        }
    }

    // MARK: - Queries (delegate to PaneManager)

    /// All terminal tabs across all terminal panes.
    var allTerminalTabs: [TerminalTab] {
        paneManager?.allTerminalTabs ?? []
    }

    /// Whether any terminal tab has a foreground child process running.
    var hasActiveProcesses: Bool {
        allTerminalTabs.contains { $0.hasForegroundProcess }
    }

    /// Terminal tabs that currently have a foreground child process.
    var tabsWithForegroundProcesses: [TerminalTab] {
        allTerminalTabs.filter { $0.hasForegroundProcess }
    }

    /// Terminates all terminal processes across all panes.
    func terminateAll() {
        for tab in allTerminalTabs {
            tab.stop()
        }
    }

    /// Starts all terminal tabs across all panes.
    func startTerminals(workingDirectory: URL?) {
        guard let pm = paneManager else { return }
        for state in pm.terminalStates.values {
            state.startTabs(workingDirectory: workingDirectory)
        }
    }
}
```

- [ ] **Step 4: Run tests**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project Pine.xcodeproj -scheme Pine -destination 'platform=macOS' -only-testing:PineTests/TerminalManagerCoordinatorTests`

Expected: All PASS

- [ ] **Step 5: Commit**

```bash
git add Pine/TerminalManager.swift PineTests/TerminalManagerTests.swift
git commit -m "refactor: convert TerminalManager from tab owner to coordinator"
```

---

### Task 6: Wire TerminalManager to PaneManager in ProjectManager

**Files:**
- Modify: `Pine/ProjectManager.swift`

- [ ] **Step 1: Connect TerminalManager.paneManager**

In `Pine/ProjectManager.swift`, after the `paneManager` lazy var declaration, add wiring in an initializer or in the existing setup. Find where `paneManager` is first used and ensure `terminal.paneManager = paneManager` is set.

After the existing line `private(set) lazy var paneManager = PaneManager(existingTabManager: tabManager)`, add:

```swift
    /// Connects TerminalManager to PaneManager. Called lazily on first access.
    private func ensureTerminalWired() {
        if terminal.paneManager == nil {
            terminal.paneManager = paneManager
        }
    }
```

And update `activeTabManager` computed property to also wire:

```swift
    var activeTabManager: TabManager {
        ensureTerminalWired()
        return paneManager.activeTabManager ?? tabManager
    }
```

- [ ] **Step 2: Update allTerminalTabs and terminal-related properties**

Add to `ProjectManager.swift`:

```swift
    /// All terminal tabs across all panes (for process management, session save).
    var allTerminalTabs: [TerminalTab] {
        ensureTerminalWired()
        return terminal.allTerminalTabs
    }
```

- [ ] **Step 3: Verify build succeeds**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Pine.xcodeproj -scheme Pine build 2>&1 | tail -5`

Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add Pine/ProjectManager.swift
git commit -m "feat: wire TerminalManager to PaneManager in ProjectManager"
```

---

### Task 7: Create TerminalPaneContent view

**Files:**
- Create: `Pine/TerminalPaneContent.swift`

- [ ] **Step 1: Create TerminalPaneContent view**

Create `Pine/TerminalPaneContent.swift`:

```swift
//
//  TerminalPaneContent.swift
//  Pine
//
//  Renders terminal tab bar + terminal view for a single terminal pane leaf.
//

import SwiftUI

struct TerminalPaneContent: View {
    let paneID: PaneID
    @Environment(PaneManager.self) private var paneManager

    private var terminalState: TerminalPaneState? {
        paneManager.terminalState(for: paneID)
    }

    var body: some View {
        if let state = terminalState {
            VStack(spacing: 0) {
                TerminalPaneTabBar(
                    paneID: paneID,
                    terminalState: state
                )
                TerminalSearchBarContainer(terminalState: state)
                TerminalPaneTerminalView(terminalState: state)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
    }
}
```

- [ ] **Step 2: Verify build**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Pine.xcodeproj -scheme Pine build 2>&1 | tail -5`

Note: This will fail because `TerminalPaneTabBar`, updated `TerminalSearchBarContainer`, and `TerminalPaneTerminalView` don't exist yet. That's expected — they are created in Task 8.

- [ ] **Step 3: Commit (WIP)**

```bash
git add Pine/TerminalPaneContent.swift
git commit -m "feat: add TerminalPaneContent view (WIP — depends on tab bar)"
```

---

### Task 8: Create TerminalPaneTabBar with drag-and-drop

**Files:**
- Create: `Pine/TerminalPaneTabBar.swift`
- Modify: `Pine/TerminalBarView.swift` (update TerminalSearchBarContainer to accept TerminalPaneState)

- [ ] **Step 1: Create TerminalPaneTabBar**

Create `Pine/TerminalPaneTabBar.swift`:

```swift
//
//  TerminalPaneTabBar.swift
//  Pine
//
//  Tab bar for a terminal pane leaf with drag-and-drop support.
//

import SwiftUI
import UniformTypeIdentifiers

struct TerminalPaneTabBar: View {
    let paneID: PaneID
    let terminalState: TerminalPaneState
    @Environment(PaneManager.self) private var paneManager
    @Environment(WorkspaceManager.self) private var workspace

    @State private var draggingTabID: UUID?

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(terminalState.terminalTabs, id: \.id) { tab in
                        TerminalPaneTabItem(
                            tab: tab,
                            isActive: terminalState.activeTerminalID == tab.id,
                            canClose: terminalState.tabCount > 1,
                            onSelect: {
                                terminalState.activeTerminalID = tab.id
                                terminalState.pendingFocusTabID = tab.id
                                paneManager.activePaneID = paneID
                            },
                            onClose: {
                                closeTabWithConfirmation(tab)
                            }
                        )
                        .onDrag {
                            draggingTabID = tab.id
                            let info = TabDragInfo(
                                paneID: paneID.id,
                                tabID: tab.id,
                                fileURL: URL(fileURLWithPath: "/terminal/\(tab.id.uuidString)"),
                                contentType: "terminal"
                            )
                            let provider = NSItemProvider()
                            provider.registerDataRepresentation(
                                forTypeIdentifier: UTType.paneTabDrag.identifier,
                                visibility: .ownProcess
                            ) { completion in
                                let data = info.encoded.data(using: .utf8) ?? Data()
                                completion(data, nil)
                                return nil
                            }
                            paneManager.activeDrag = info
                            return provider
                        }
                    }
                }
                .padding(.horizontal, 4)
            }

            Spacer()

            // Plus button — add terminal tab
            Button {
                terminalState.addTab(workingDirectory: workspace.rootURL)
                paneManager.activePaneID = paneID
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .padding(.trailing, 4)

            // Maximize/restore button
            Button {
                if paneManager.isMaximized {
                    paneManager.restoreFromMaximize()
                } else {
                    paneManager.maximize(paneID: paneID)
                }
            } label: {
                Image(systemName: paneManager.isMaximized
                      ? "arrow.down.right.and.arrow.up.left"
                      : "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .padding(.trailing, 4)
        }
        .frame(height: 28)
        .background(.bar)
    }

    private func closeTabWithConfirmation(_ tab: TerminalTab) {
        if tab.hasForegroundProcess {
            let alert = NSAlert()
            alert.messageText = Strings.terminalProcessRunningTitle
            alert.informativeText = Strings.terminalProcessRunningMessage
            alert.addButton(withTitle: Strings.dialogTerminate)
            alert.addButton(withTitle: Strings.dialogCancel)
            alert.alertStyle = .warning

            let response = alert.runModal()
            guard response == .alertFirstButtonReturn else { return }
        }
        terminalState.removeTab(id: tab.id)
        if terminalState.terminalTabs.isEmpty {
            paneManager.removePane(paneID)
        }
    }
}
```

- [ ] **Step 2: Create TerminalPaneTabItem**

Add to the same file or create separate. Add at the bottom of `Pine/TerminalPaneTabBar.swift`:

```swift
struct TerminalPaneTabItem: View {
    let tab: TerminalTab
    let isActive: Bool
    let canClose: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "terminal")
                .font(.system(size: 10))
            Text(tab.name)
                .font(.system(size: 11))
                .lineLimit(1)
            if canClose && (isHovering || isActive) {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(isActive ? Color.accentColor.opacity(0.2) : (isHovering ? Color.primary.opacity(0.05) : Color.clear))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .onTapGesture { onSelect() }
        .onHover { isHovering = $0 }
    }
}
```

- [ ] **Step 3: Create TerminalPaneTerminalView**

Create `Pine/TerminalPaneTerminalView.swift`:

```swift
//
//  TerminalPaneTerminalView.swift
//  Pine
//
//  NSViewRepresentable wrapper for SwiftTerm in a terminal pane.
//  Adapts TerminalContainerView to work with TerminalPaneState.
//

import SwiftUI

struct TerminalPaneTerminalView: NSViewRepresentable {
    let terminalState: TerminalPaneState

    func makeNSView(context: Context) -> TerminalContainerView {
        let container = TerminalContainerView()
        container.terminalPaneState = terminalState
        container.showTab(terminalState.activeTab)
        return container
    }

    func updateNSView(_ container: TerminalContainerView, context: Context) {
        container.terminalPaneState = terminalState
        container.showPaneTab(terminalState.activeTab)
    }
}
```

Note: This requires adding `terminalPaneState` property and `showPaneTab` method to `TerminalContainerView` — will be done in Task 9.

- [ ] **Step 4: Commit**

```bash
git add Pine/TerminalPaneTabBar.swift Pine/TerminalPaneTerminalView.swift
git commit -m "feat: add TerminalPaneTabBar with DnD and TerminalPaneTerminalView"
```

---

### Task 9: Adapt TerminalContainerView for per-pane usage

**Files:**
- Modify: `Pine/TerminalSession.swift`

- [ ] **Step 1: Add TerminalPaneState support to TerminalContainerView**

In `Pine/TerminalSession.swift`, in the `TerminalContainerView` class (around line 86), add:

```swift
    /// Per-pane terminal state (new split pane path).
    var terminalPaneState: TerminalPaneState?
```

Add a new method alongside `showTab`:

```swift
    /// Shows a terminal tab from a TerminalPaneState.
    func showPaneTab(_ tab: TerminalTab?) {
        guard let tab, tab.id != currentTabID else { return }
        currentTabID = tab.id

        // Remove existing terminal view
        scrollInterceptor.removeFromSuperview()
        subviews.forEach { $0.removeFromSuperview() }

        tab.startIfNeeded()
        let terminalView = tab.terminalView
        terminalView.frame = bounds
        addSubview(terminalView)

        scrollInterceptor.terminalView = terminalView
        addSubview(scrollInterceptor)
        scrollInterceptor.frame = bounds

        installScrollMonitor()

        // Handle pending focus
        if let state = terminalPaneState,
           let pending = state.pendingFocusTabID,
           pending == tab.id {
            state.pendingFocusTabID = nil
            focusTerminalView(terminalView)
        }
    }
```

- [ ] **Step 2: Verify build**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Pine.xcodeproj -scheme Pine build 2>&1 | tail -5`

Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add Pine/TerminalSession.swift
git commit -m "feat: adapt TerminalContainerView for per-pane terminal state"
```

---

### Task 10: Update PaneLeafView and PaneTreeView for terminal content

**Files:**
- Modify: `Pine/PaneLeafView.swift`
- Modify: `Pine/PaneTreeView.swift`

- [ ] **Step 1: Update PaneTreeView to pass content type**

In `Pine/PaneTreeView.swift`, update the leaf case (around line 20):

```swift
        case .leaf(let paneID, let content):
            PaneLeafView(paneID: paneID, content: content)
```

- [ ] **Step 2: Update PaneLeafView to accept content type and switch**

In `Pine/PaneLeafView.swift`, add the content parameter at line 12:

```swift
    let paneID: PaneID
    let content: PaneContent
```

Update the body (line 36) to switch on content:

```swift
    var body: some View {
        switch content {
        case .editor:
            editorBody
        case .terminal:
            terminalBody
        }
    }

    @ViewBuilder
    private var terminalBody: some View {
        TerminalPaneContent(paneID: paneID)
            .background {
                PaneFocusDetector(paneID: paneID, paneManager: paneManager)
            }
            .overlay {
                GeometryReader { geometry in
                    Color.clear
                        .preference(key: PaneSizePreferenceKey.self, value: geometry.size)
                }
            }
            .onPreferenceChange(PaneSizePreferenceKey.self) { paneSize = $0 }
            .overlay {
                PaneDropOverlay(dropZone: dropZone)
            }
            .onDrop(of: [.paneTabDrag], delegate: PaneSplitDropDelegate(
                paneID: paneID,
                paneManager: paneManager,
                paneSize: paneSize,
                dropZone: $dropZone
            ))
            .border(
                isActive && paneManager.root.leafCount > 1
                    ? Color.accentColor.opacity(0.5)
                    : Color.clear,
                width: 1
            )
            .accessibilityIdentifier(AccessibilityID.paneLeaf(paneID.id.uuidString))
    }
```

Rename the existing body content to `editorBody`:

```swift
    @ViewBuilder
    private var editorBody: some View {
        if let tabManager {
            // ... existing editor body code ...
        }
    }
```

- [ ] **Step 3: Update drop delegate to validate content types**

In `Pine/PaneDropZone.swift`, update `PaneSplitDropDelegate.performDrop` to check content types. In the `case .center:` block, verify that source and target have matching content types before allowing the move.

- [ ] **Step 4: Verify build**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Pine.xcodeproj -scheme Pine build 2>&1 | tail -5`

Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```bash
git add Pine/PaneLeafView.swift Pine/PaneTreeView.swift Pine/PaneDropZone.swift
git commit -m "feat: render terminal panes in PaneLeafView with drop validation"
```

---

### Task 11: Remove global terminal panel from ContentView

**Files:**
- Modify: `Pine/ContentView.swift`

- [ ] **Step 1: Replace VSplitView with PaneTreeView-only layout**

In `Pine/ContentView.swift`, replace the detail section (lines 66-83):

```swift
        } detail: {
            VStack(spacing: 0) {
                PaneTreeView(node: paneManager.root)
                    .frame(maxHeight: .infinity)
                StatusBarView(
                    gitProvider: workspace.gitProvider,
                    terminal: terminal,
                    tabManager: tabManager,
                    progress: projectManager.progress
                )
            }
```

Remove `editorArea` computed property that conditionally switches between PaneTreeView and EditorAreaView (lines 246-265). Always use PaneTreeView.

Remove `terminalArea` computed property (lines 269-278).

- [ ] **Step 2: Update keyboard shortcuts**

In `Pine/PineApp.swift`, update Cmd+T handler to use `TerminalManager.createTerminalTab()`:

```swift
Button {
    guard let pm = focusedProject else { return }
    pm.terminal.createTerminalTab(
        relativeTo: pm.paneManager.activePaneID,
        workingDirectory: pm.workspace.rootURL
    )
} label: {
    Label(Strings.menuNewTerminalTab, systemImage: MenuIcons.newTerminalTab)
}
.keyboardShortcut("t", modifiers: .command)
```

Update Cmd+\` handler:

```swift
// In AppDelegate keyboard monitor for Cmd+`
pm.terminal.focusOrCreateTerminal(
    relativeTo: pm.paneManager.activePaneID,
    workingDirectory: pm.workspace.rootURL
)
```

- [ ] **Step 3: Remove isTerminalVisible / isTerminalMaximized from TerminalManager**

These are now handled by PaneManager. Remove references in ContentView, PineApp.swift, and SessionState.

- [ ] **Step 4: Verify build**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Pine.xcodeproj -scheme Pine build 2>&1 | tail -5`

Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```bash
git add Pine/ContentView.swift Pine/PineApp.swift
git commit -m "refactor: remove global terminal panel, terminal lives in split panes"
```

---

### Task 12: Update session persistence for terminal panes

**Files:**
- Modify: `Pine/SessionState.swift`
- Modify: `Pine/ProjectManager.swift` (saveSession)
- Modify: `Pine/ContentView+Helpers.swift` (restoreSessionIfNeeded)

- [ ] **Step 1: Add terminal pane fields to SessionState**

In `Pine/SessionState.swift`, replace old terminal fields (lines 42-45) with:

```swift
    /// Maps terminal pane ID (UUID string) to number of tabs to recreate.
    var terminalPaneTabCounts: [String: Int]?
    /// Maps terminal pane ID (UUID string) to active tab index.
    var terminalPaneActiveIndices: [String: Int]?
```

Remove `terminalTabCount`, `activeTerminalIndex`, `isTerminalVisible`, `isTerminalMaximized`.

Update `save()` signature accordingly.

- [ ] **Step 2: Update ProjectManager.saveSession() for terminal panes**

In `Pine/ProjectManager.swift`, in `saveSession()`, replace terminal state saving with:

```swift
        // Terminal pane state
        var terminalPaneTabCounts: [String: Int]?
        var terminalPaneActiveIndices: [String: Int]?
        let terminalPaneIDs = paneManager.terminalPaneIDs
        if !terminalPaneIDs.isEmpty {
            var counts: [String: Int] = [:]
            var indices: [String: Int] = [:]
            for tpID in terminalPaneIDs {
                guard let state = paneManager.terminalState(for: tpID) else { continue }
                counts[tpID.id.uuidString] = state.tabCount
                if let activeID = state.activeTerminalID,
                   let idx = state.terminalTabs.firstIndex(where: { $0.id == activeID }) {
                    indices[tpID.id.uuidString] = idx
                }
            }
            terminalPaneTabCounts = counts.isEmpty ? nil : counts
            terminalPaneActiveIndices = indices.isEmpty ? nil : indices
        }
```

- [ ] **Step 3: Update ContentView+Helpers restore for terminal panes**

In `Pine/ContentView+Helpers.swift`, in `restoreSessionIfNeeded()`, after restoring editor tabs in panes, add terminal pane restoration:

```swift
            // Restore terminal tabs for terminal panes
            if let tabCounts = session.terminalPaneTabCounts {
                for (paneIDStr, count) in tabCounts {
                    guard let uuid = UUID(uuidString: paneIDStr),
                          let paneID = paneManager.root.leafIDs.first(where: { $0.id == uuid }),
                          let state = paneManager.terminalState(for: paneID) else { continue }
                    // First tab was created during restoreLayout, add remaining
                    for _ in 1..<count {
                        state.addTab(workingDirectory: workspace.rootURL)
                    }
                    // Restore active index
                    if let activeIdx = session.terminalPaneActiveIndices?[paneIDStr],
                       activeIdx < state.terminalTabs.count {
                        state.activeTerminalID = state.terminalTabs[activeIdx].id
                    }
                }
            }
```

- [ ] **Step 4: Verify build**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Pine.xcodeproj -scheme Pine build 2>&1 | tail -5`

Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```bash
git add Pine/SessionState.swift Pine/ProjectManager.swift Pine/ContentView+Helpers.swift
git commit -m "feat: update session persistence for terminal panes"
```

---

### Task 13: Update TerminalSearchBarContainer for TerminalPaneState

**Files:**
- Modify: `Pine/TerminalBarView.swift`

- [ ] **Step 1: Add TerminalPaneState overload to TerminalSearchBarContainer**

In `Pine/TerminalBarView.swift`, add an initializer or a parallel struct that accepts `TerminalPaneState` instead of `TerminalManager`:

```swift
struct TerminalSearchBarContainer: View {
    var terminalState: TerminalPaneState

    var body: some View {
        if terminalState.isSearchVisible {
            TerminalSearchBar(
                searchText: Binding(
                    get: { terminalState.terminalSearchQuery },
                    set: { terminalState.terminalSearchQuery = $0 }
                ),
                isCaseSensitive: Binding(
                    get: { terminalState.isSearchCaseSensitive },
                    set: { terminalState.isSearchCaseSensitive = $0 }
                ),
                matchCount: terminalState.activeTab?.searchMatches.count ?? 0,
                currentMatch: terminalState.activeTab?.currentMatchIndex ?? -1,
                onNext: { terminalState.activeTab?.nextMatch() },
                onPrevious: { terminalState.activeTab?.previousMatch() },
                onDismiss: {
                    terminalState.isSearchVisible = false
                    terminalState.activeTab?.clearSearch()
                }
            )
        }
    }
}
```

Note: If the existing `TerminalSearchBarContainer` uses `TerminalManager`, either make it generic or create a new version. The old one referencing global `TerminalManager` can be removed once ContentView no longer uses it.

- [ ] **Step 2: Verify build**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Pine.xcodeproj -scheme Pine build 2>&1 | tail -5`

Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add Pine/TerminalBarView.swift
git commit -m "refactor: adapt TerminalSearchBarContainer for TerminalPaneState"
```

---

### Task 14: Update Cmd+W and close delegate for terminal tabs

**Files:**
- Modify: `Pine/PineApp.swift` (CloseDelegate)

- [ ] **Step 1: Update CloseDelegate.closeActiveTab for terminal panes**

In `Pine/PineApp.swift`, in `CloseDelegate.closeActiveTab()` (around line 717), add terminal pane handling:

```swift
    func closeActiveTab() {
        let pane = projectManager.paneManager
        let activePaneID = pane.activePaneID

        // Check pane content type
        guard let content = pane.root.content(for: activePaneID) else { return }

        switch content {
        case .editor:
            let activeTM = projectManager.activeTabManager
            guard let tab = activeTM.activeTab else { return }
            // ... existing editor close logic ...

        case .terminal:
            guard let state = pane.terminalState(for: activePaneID),
                  let tab = state.activeTab else { return }
            if tab.hasForegroundProcess {
                let alert = NSAlert()
                alert.messageText = Strings.terminalProcessRunningTitle
                alert.informativeText = Strings.terminalProcessRunningMessage
                alert.addButton(withTitle: Strings.dialogTerminate)
                alert.addButton(withTitle: Strings.dialogCancel)
                alert.alertStyle = .warning
                guard alert.runModal() == .alertFirstButtonReturn else { return }
            }
            state.removeTab(id: tab.id)
            if state.terminalTabs.isEmpty {
                pane.removePane(activePaneID)
            }
        }
    }
```

- [ ] **Step 2: Update windowShouldClose for terminal dirty checks**

In `windowShouldClose`, also check for running terminal processes:

```swift
        let terminalProcessTabs = projectManager.terminal.tabsWithForegroundProcesses
        // Show warning if terminal has foreground processes
```

- [ ] **Step 3: Verify build**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Pine.xcodeproj -scheme Pine build 2>&1 | tail -5`

Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add Pine/PineApp.swift
git commit -m "feat: handle terminal tab close in CloseDelegate with process check"
```

---

### Task 15: Update CI coverage exclusions and SwiftLint

**Files:**
- Modify: `.github/workflows/ci.yml`

- [ ] **Step 1: Add new view files to coverage exclusions**

In `.github/workflows/ci.yml`, add to both SwiftUI view exclusion lists:

```yaml
              'TerminalPaneContent.swift',
              'TerminalPaneTabBar.swift',
              'TerminalPaneTerminalView.swift',
```

- [ ] **Step 2: Run SwiftLint**

Run: `swiftlint`

Fix any warnings/errors.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/ci.yml
git commit -m "chore: add new terminal pane views to CI coverage exclusions"
```

---

### Task 16: Integration testing and build verification

**Files:**
- Create: `PineTests/TerminalPaneIntegrationTests.swift`

- [ ] **Step 1: Write integration tests**

Create `PineTests/TerminalPaneIntegrationTests.swift`:

```swift
//
//  TerminalPaneIntegrationTests.swift
//  PineTests
//

import Testing
import Foundation
@testable import Pine

@Suite("Terminal Pane Integration Tests")
@MainActor
struct TerminalPaneIntegrationTests {

    @Test func cmdT_createsTerminalPaneBelowEditor() {
        let pm = ProjectManager()
        pm.terminal.paneManager = pm.paneManager
        let editorPane = pm.paneManager.activePaneID

        pm.terminal.createTerminalTab(
            relativeTo: editorPane,
            workingDirectory: nil
        )

        #expect(pm.paneManager.terminalPaneIDs.count == 1)
        #expect(pm.paneManager.root.leafCount == 2)

        let tpID = pm.paneManager.terminalPaneIDs.first!
        #expect(pm.paneManager.root.content(for: tpID) == .terminal)
        #expect(pm.paneManager.root.content(for: editorPane) == .editor)
    }

    @Test func cmdT_secondCall_addsTabToExistingPane() {
        let pm = ProjectManager()
        pm.terminal.paneManager = pm.paneManager
        let editorPane = pm.paneManager.activePaneID

        pm.terminal.createTerminalTab(relativeTo: editorPane, workingDirectory: nil)
        let tpID = pm.paneManager.terminalPaneIDs.first!
        pm.terminal.lastActiveTerminalPaneID = tpID

        pm.terminal.createTerminalTab(relativeTo: editorPane, workingDirectory: nil)

        #expect(pm.paneManager.terminalPaneIDs.count == 1)
        #expect(pm.paneManager.terminalState(for: tpID)?.tabCount == 2)
    }

    @Test func closeLastTerminalTab_removesPaneFromTree() {
        let pm = ProjectManager()
        pm.terminal.paneManager = pm.paneManager
        let editorPane = pm.paneManager.activePaneID

        pm.terminal.createTerminalTab(relativeTo: editorPane, workingDirectory: nil)
        let tpID = pm.paneManager.terminalPaneIDs.first!
        let tab = pm.paneManager.terminalState(for: tpID)!.terminalTabs.first!

        pm.paneManager.terminalState(for: tpID)?.removeTab(id: tab.id)
        pm.paneManager.removePane(tpID)

        #expect(pm.paneManager.root.leafCount == 1)
        #expect(pm.paneManager.terminalPaneIDs.isEmpty)
    }

    @Test func maximize_terminal_then_restore() {
        let pm = ProjectManager()
        pm.terminal.paneManager = pm.paneManager
        let editorPane = pm.paneManager.activePaneID

        pm.terminal.createTerminalTab(relativeTo: editorPane, workingDirectory: nil)
        let tpID = pm.paneManager.terminalPaneIDs.first!

        pm.paneManager.maximize(paneID: tpID)
        #expect(pm.paneManager.isMaximized)
        #expect(pm.paneManager.root.leafCount == 1)

        pm.paneManager.restoreFromMaximize()
        #expect(!pm.paneManager.isMaximized)
        #expect(pm.paneManager.root.leafCount == 2)
    }

    @Test func dragValidation_terminalToEditor_rejected() {
        let dragInfo = TabDragInfo(
            paneID: UUID(),
            tabID: UUID(),
            fileURL: URL(fileURLWithPath: "/terminal/test"),
            contentType: "terminal"
        )
        // Terminal content type should not match editor pane
        #expect(dragInfo.contentType != "editor")
    }

    @Test func sessionSave_includesTerminalPanes() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PineTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: dir)
            SessionState.clear(for: dir)
        }

        let pm = ProjectManager()
        pm.workspace.loadDirectory(url: dir)
        pm.terminal.paneManager = pm.paneManager
        let editorPane = pm.paneManager.activePaneID

        pm.terminal.createTerminalTab(relativeTo: editorPane, workingDirectory: dir)

        pm.saveSession()

        let session = SessionState.load(for: dir)
        #expect(session != nil)
        #expect(session?.paneLayoutData != nil)
        #expect(session?.terminalPaneTabCounts != nil)
        #expect(session?.terminalPaneTabCounts?.values.first == 1)
    }
}
```

- [ ] **Step 2: Run integration tests**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project Pine.xcodeproj -scheme Pine -destination 'platform=macOS' -only-testing:PineTests/TerminalPaneIntegrationTests`

Expected: All PASS

- [ ] **Step 3: Run full test suite**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project Pine.xcodeproj -scheme Pine -destination 'platform=macOS' -only-testing:PineTests`

Expected: All PASS

- [ ] **Step 4: Build and launch for visual verification**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Pine.xcodeproj -scheme Pine build`

Then: `open /path/to/DerivedData/Build/Products/Debug/Pine.app`

Manual checks:
- Cmd+T creates terminal pane below editor
- Cmd+\` focuses terminal pane
- Cmd+W closes terminal tab
- Drag terminal tab to edge creates split
- Maximize/restore works
- Quit and reopen — terminal pane restored

- [ ] **Step 5: Commit**

```bash
git add PineTests/TerminalPaneIntegrationTests.swift
git commit -m "test: add terminal pane integration tests"
```
