# Root-Level Drop Zones Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add root-level drop zones so terminal tabs can be dragged to window edges to create full-width/height terminal panes.

**Architecture:** A new `RootPaneSplitDropDelegate` overlay on `PaneTreeView` detects drops in 10% edge zones. On drop, `PaneManager.wrapRootWithTerminal()` wraps the entire root in a new split. Only terminal tabs are accepted.

**Tech Stack:** SwiftUI, AppKit (NSEvent monitor), Swift Testing

---

### Task 1: RootDropZone enum and detection logic

**Files:**
- Create: `Pine/RootDropZone.swift`
- Test: `PineTests/RootDropZoneTests.swift`

- [ ] **Step 1: Write failing tests for zone detection**

```swift
//
//  RootDropZoneTests.swift
//  PineTests
//

import Testing
import Foundation
@testable import Pine

@Suite("RootDropZone Tests")
struct RootDropZoneTests {

    let size = CGSize(width: 1000, height: 800)

    @Test func detectTopZone() {
        let zone = RootDropZone.detect(location: CGPoint(x: 500, y: 40), in: size)
        #expect(zone == .top)
    }

    @Test func detectBottomZone() {
        let zone = RootDropZone.detect(location: CGPoint(x: 500, y: 760), in: size)
        #expect(zone == .bottom)
    }

    @Test func detectLeftZone() {
        let zone = RootDropZone.detect(location: CGPoint(x: 50, y: 400), in: size)
        #expect(zone == .left)
    }

    @Test func detectRightZone() {
        let zone = RootDropZone.detect(location: CGPoint(x: 950, y: 400), in: size)
        #expect(zone == .right)
    }

    @Test func detectNoZone_center() {
        let zone = RootDropZone.detect(location: CGPoint(x: 500, y: 400), in: size)
        #expect(zone == nil)
    }

    @Test func cornerResolution_topLeft_closerToLeft() {
        // x=30 is 3% from left, y=50 is 6.25% from top — left wins
        let zone = RootDropZone.detect(location: CGPoint(x: 30, y: 50), in: size)
        #expect(zone == .left)
    }

    @Test func cornerResolution_topLeft_closerToTop() {
        // x=60 is 6% from left, y=20 is 2.5% from top — top wins
        let zone = RootDropZone.detect(location: CGPoint(x: 60, y: 20), in: size)
        #expect(zone == .top)
    }

    @Test func exactBoundary_10percent() {
        // x=100 is exactly 10% of 1000 — should be the boundary
        let zoneAt = RootDropZone.detect(location: CGPoint(x: 100, y: 400), in: size)
        #expect(zoneAt == nil) // at 10% boundary, not inside
        let zoneInside = RootDropZone.detect(location: CGPoint(x: 99, y: 400), in: size)
        #expect(zoneInside == .left)
    }

    @Test func zeroSize_returnsNil() {
        let zone = RootDropZone.detect(location: CGPoint(x: 50, y: 50), in: .zero)
        #expect(zone == nil)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project Pine.xcodeproj -scheme Pine -destination 'platform=macOS' -only-testing:PineTests/RootDropZoneTests 2>&1 | tail -20`
Expected: FAIL — `RootDropZone` not found

- [ ] **Step 3: Implement RootDropZone enum**

Create `Pine/RootDropZone.swift`:

```swift
//
//  RootDropZone.swift
//  Pine
//
//  Root-level drop zone types, overlay, and drop delegate for full-width/height pane splits.
//

import SwiftUI
import UniformTypeIdentifiers

// MARK: - Root Drop Zone

/// Represents a drop zone at the window edge for creating full-width/height splits.
enum RootDropZone: Equatable, Sendable {
    case top
    case bottom
    case left
    case right

    /// Fraction of container size that triggers root edge drop zones.
    /// Narrower than leaf zones (10% vs 25%) to avoid conflicts.
    static let edgeThreshold: CGFloat = 0.10

    /// Determines the root drop zone based on cursor location.
    /// Returns nil if the cursor is not within the edge threshold.
    static func detect(location: CGPoint, in size: CGSize) -> RootDropZone? {
        let width = size.width
        let height = size.height
        guard width > 0, height > 0 else { return nil }

        let relX = location.x / width
        let relY = location.y / height

        let inLeft = relX < edgeThreshold
        let inRight = relX > (1 - edgeThreshold)
        let inTop = relY < edgeThreshold
        let inBottom = relY > (1 - edgeThreshold)

        guard inLeft || inRight || inTop || inBottom else { return nil }

        // Corner conflict: pick the axis where cursor is closer to the edge
        let distToEdgeX = min(relX, 1 - relX)
        let distToEdgeY = min(relY, 1 - relY)

        if inLeft && (!inTop && !inBottom || distToEdgeX <= distToEdgeY) {
            return .left
        } else if inRight && (!inTop && !inBottom || distToEdgeX <= distToEdgeY) {
            return .right
        } else if inTop {
            return .top
        } else if inBottom {
            return .bottom
        }

        return nil
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project Pine.xcodeproj -scheme Pine -destination 'platform=macOS' -only-testing:PineTests/RootDropZoneTests 2>&1 | tail -20`
Expected: All tests PASS

- [ ] **Step 5: Commit**

```bash
git add Pine/RootDropZone.swift PineTests/RootDropZoneTests.swift
git commit -m "feat: add RootDropZone enum with edge detection logic (#712)"
```

---

### Task 2: PaneManager.wrapRootWithTerminal method

**Files:**
- Modify: `Pine/PaneManager.swift` — add `rootDropZone` property and `wrapRootWithTerminal()` method
- Test: `PineTests/PaneManagerRootDropTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
//
//  PaneManagerRootDropTests.swift
//  PineTests
//

import Testing
import Foundation
@testable import Pine

@Suite("PaneManager Root Drop Tests")
@MainActor
struct PaneManagerRootDropTests {

    // MARK: - Helpers

    /// Creates a PaneManager with one editor pane and one terminal pane at the bottom,
    /// returning (manager, editorPaneID, terminalPaneID, terminalTabID).
    private func managerWithTerminal() -> (PaneManager, PaneID, PaneID, UUID) {
        let manager = PaneManager()
        let editorID = manager.activePaneID
        let terminalID = manager.createTerminalPaneAtBottom(workingDirectory: nil)
        let tabID = manager.terminalState(for: terminalID)!.terminalTabs.first!.id
        return (manager, editorID, terminalID, tabID)
    }

    // MARK: - wrapRootWithTerminal

    @Test func wrapBottom_createsVerticalSplitWithTerminalSecond() {
        let (manager, _, terminalID, tabID) = managerWithTerminal()
        let originalRoot = manager.root

        manager.wrapRootWithTerminal(at: .bottom, from: terminalID, tabID: tabID)

        if case .split(let axis, _, let second, let ratio) = manager.root {
            #expect(axis == .vertical)
            #expect(ratio == 0.7)
            if case .leaf(_, let content) = second {
                #expect(content == .terminal)
            } else {
                Issue.record("Expected terminal leaf as second child")
            }
        } else {
            Issue.record("Expected split node at root")
        }
    }

    @Test func wrapTop_createsVerticalSplitWithTerminalFirst() {
        let (manager, _, terminalID, tabID) = managerWithTerminal()

        manager.wrapRootWithTerminal(at: .top, from: terminalID, tabID: tabID)

        if case .split(let axis, let first, _, let ratio) = manager.root {
            #expect(axis == .vertical)
            #expect(ratio == 0.3)
            if case .leaf(_, let content) = first {
                #expect(content == .terminal)
            } else {
                Issue.record("Expected terminal leaf as first child")
            }
        } else {
            Issue.record("Expected split node at root")
        }
    }

    @Test func wrapRight_createsHorizontalSplitWithTerminalSecond() {
        let (manager, _, terminalID, tabID) = managerWithTerminal()

        manager.wrapRootWithTerminal(at: .right, from: terminalID, tabID: tabID)

        if case .split(let axis, _, let second, let ratio) = manager.root {
            #expect(axis == .horizontal)
            #expect(ratio == 0.7)
            if case .leaf(_, let content) = second {
                #expect(content == .terminal)
            } else {
                Issue.record("Expected terminal leaf as second child")
            }
        } else {
            Issue.record("Expected split node at root")
        }
    }

    @Test func wrapLeft_createsHorizontalSplitWithTerminalFirst() {
        let (manager, _, terminalID, tabID) = managerWithTerminal()

        manager.wrapRootWithTerminal(at: .left, from: terminalID, tabID: tabID)

        if case .split(let axis, let first, _, let ratio) = manager.root {
            #expect(axis == .horizontal)
            #expect(ratio == 0.3)
            if case .leaf(_, let content) = first {
                #expect(content == .terminal)
            } else {
                Issue.record("Expected terminal leaf as first child")
            }
        } else {
            Issue.record("Expected split node at root")
        }
    }

    @Test func wrapRoot_movesTerminalTabToNewPane() {
        let (manager, _, terminalID, tabID) = managerWithTerminal()

        manager.wrapRootWithTerminal(at: .bottom, from: terminalID, tabID: tabID)

        // Source pane should be gone (it had only one tab)
        #expect(manager.terminalState(for: terminalID) == nil)

        // New terminal pane should have the tab
        let newTerminalPanes = manager.terminalPaneIDs.filter { $0 != terminalID }
        #expect(newTerminalPanes.count == 1)
        let newState = manager.terminalState(for: newTerminalPanes[0])!
        #expect(newState.terminalTabs.count == 1)
        #expect(newState.terminalTabs[0].id == tabID)
    }

    @Test func wrapRoot_sourcePaneKeptWhenMultipleTabs() {
        let manager = PaneManager()
        let terminalID = manager.createTerminalPaneAtBottom(workingDirectory: nil)
        let state = manager.terminalState(for: terminalID)!
        state.addTab(workingDirectory: nil) // second tab
        let firstTabID = state.terminalTabs[0].id

        manager.wrapRootWithTerminal(at: .right, from: terminalID, tabID: firstTabID)

        // Source pane should still exist with 1 remaining tab
        #expect(manager.terminalState(for: terminalID) != nil)
        #expect(manager.terminalState(for: terminalID)!.terminalTabs.count == 1)
    }

    @Test func wrapRoot_setsActivePaneToNewTerminal() {
        let (manager, _, terminalID, tabID) = managerWithTerminal()

        manager.wrapRootWithTerminal(at: .bottom, from: terminalID, tabID: tabID)

        let newTerminalPanes = manager.terminalPaneIDs
        #expect(newTerminalPanes.contains(manager.activePaneID))
    }

    @Test func rootDropZone_clearedByDefault() {
        let manager = PaneManager()
        #expect(manager.rootDropZone == nil)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project Pine.xcodeproj -scheme Pine -destination 'platform=macOS' -only-testing:PineTests/PaneManagerRootDropTests 2>&1 | tail -20`
Expected: FAIL — `rootDropZone` and `wrapRootWithTerminal` not found

- [ ] **Step 3: Add rootDropZone property to PaneManager**

In `Pine/PaneManager.swift`, after the `dropZones` property (line 47), add:

```swift
/// Active root-level drop zone — set by RootPaneSplitDropDelegate.
var rootDropZone: RootDropZone?
```

Update `clearAllDropZones()` to also clear the root zone:

```swift
func clearAllDropZones() {
    dropZones.removeAll()
    rootDropZone = nil
}
```

- [ ] **Step 4: Add wrapRootWithTerminal method**

In `Pine/PaneManager.swift`, after `splitAndMoveTerminalTab` (after line 317), add:

```swift
/// Wraps the entire root in a new split, creating a full-width/height terminal pane.
/// Moves the specified terminal tab from the source pane to the new pane.
/// Removes the source pane if it becomes empty.
func wrapRootWithTerminal(at zone: RootDropZone, from sourcePaneID: PaneID, tabID: UUID) {
    guard let srcState = terminalStates[sourcePaneID],
          let tab = srcState.terminalTabs.first(where: { $0.id == tabID }) else { return }

    // Remove tab from source BEFORE modifying the tree
    srcState.terminalTabs.removeAll { $0.id == tabID }
    if srcState.activeTerminalID == tabID {
        srcState.activeTerminalID = srcState.terminalTabs.last?.id
    }

    // Remove source pane if empty (this modifies root)
    if srcState.terminalTabs.isEmpty {
        removePane(sourcePaneID)
    }

    // Create new terminal pane and wrap root
    let newID = PaneID()
    let terminalLeaf = PaneNode.leaf(newID, .terminal)

    switch zone {
    case .bottom:
        root = .split(.vertical, first: root, second: terminalLeaf, ratio: 0.7)
    case .top:
        root = .split(.vertical, first: terminalLeaf, second: root, ratio: 0.3)
    case .right:
        root = .split(.horizontal, first: root, second: terminalLeaf, ratio: 0.7)
    case .left:
        root = .split(.horizontal, first: terminalLeaf, second: root, ratio: 0.3)
    }

    let newState = TerminalPaneState()
    newState.terminalTabs.append(tab)
    newState.activeTerminalID = tab.id
    terminalStates[newID] = newState
    activePaneID = newID
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project Pine.xcodeproj -scheme Pine -destination 'platform=macOS' -only-testing:PineTests/PaneManagerRootDropTests 2>&1 | tail -20`
Expected: All tests PASS

- [ ] **Step 6: Run existing PaneManager tests to check for regressions**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project Pine.xcodeproj -scheme Pine -destination 'platform=macOS' -only-testing:PineTests/PaneManagerTests 2>&1 | tail -20`
Expected: All tests PASS

- [ ] **Step 7: Commit**

```bash
git add Pine/PaneManager.swift PineTests/PaneManagerRootDropTests.swift
git commit -m "feat: add PaneManager.wrapRootWithTerminal for root-level splits (#712)"
```

---

### Task 3: RootDropOverlay and RootPaneSplitDropDelegate

**Files:**
- Modify: `Pine/RootDropZone.swift` — add `RootDropOverlay` view and `RootPaneSplitDropDelegate`

- [ ] **Step 1: Add RootDropOverlay view**

Append to `Pine/RootDropZone.swift`:

```swift
// MARK: - Root Drop Overlay

/// Visual overlay showing the full-width/height drop zone indicator at window edges.
struct RootDropOverlay: View {
    let dropZone: RootDropZone?

    var body: some View {
        if let zone = dropZone {
            GeometryReader { geometry in
                let rect = dropRect(zone: zone, size: geometry.size)
                Rectangle()
                    .fill(Color.accentColor.opacity(0.15))
                    .border(Color.accentColor.opacity(0.4), width: 2)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
            }
            .allowsHitTesting(false)
        }
    }

    private func dropRect(zone: RootDropZone, size: CGSize) -> CGRect {
        let fraction: CGFloat = 0.3
        switch zone {
        case .top:
            let h = size.height * fraction
            return CGRect(x: size.width / 2, y: h / 2, width: size.width, height: h)
        case .bottom:
            let h = size.height * fraction
            return CGRect(x: size.width / 2, y: size.height - h / 2, width: size.width, height: h)
        case .left:
            let w = size.width * fraction
            return CGRect(x: w / 2, y: size.height / 2, width: w, height: size.height)
        case .right:
            let w = size.width * fraction
            return CGRect(x: size.width - w / 2, y: size.height / 2, width: w, height: size.height)
        }
    }
}
```

- [ ] **Step 2: Add RootPaneSplitDropDelegate**

Append to `Pine/RootDropZone.swift`:

```swift
// MARK: - Root Drop Delegate

/// Handles drop events at window edges for root-level pane splits.
/// Only accepts terminal tab drags.
struct RootPaneSplitDropDelegate: DropDelegate {
    let paneManager: PaneManager
    let containerSize: CGSize

    func validateDrop(info: DropInfo) -> Bool {
        guard info.hasItemsConforming(to: [.paneTabDrag]) else { return false }
        guard let drag = paneManager.activeDrag,
              drag.contentType == .terminal else { return false }
        // Must have more than 1 leaf (need somewhere to move from)
        return paneManager.root.leafCount > 1
    }

    func dropEntered(info: DropInfo) {
        updateZone(info: info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        updateZone(info: info)
        let zone = RootDropZone.detect(location: info.location, in: containerSize)
        if zone != nil {
            // Clear leaf overlays when root zone is active
            paneManager.clearLeafDropZones()
            return DropProposal(operation: .move)
        }
        // Outside root edge — let leaf delegates handle it
        paneManager.rootDropZone = nil
        return nil
    }

    func dropExited(info: DropInfo) {
        paneManager.rootDropZone = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let zone = paneManager.rootDropZone else { return false }
        paneManager.rootDropZone = nil
        paneManager.clearAllDropZones()

        guard let dragInfo = paneManager.activeDrag,
              dragInfo.contentType == .terminal else { return false }
        paneManager.activeDrag = nil

        let sourcePaneID = PaneID(id: dragInfo.paneID)
        paneManager.wrapRootWithTerminal(at: zone, from: sourcePaneID, tabID: dragInfo.tabID)
        return true
    }

    private func updateZone(info: DropInfo) {
        paneManager.rootDropZone = RootDropZone.detect(location: info.location, in: containerSize)
    }
}
```

- [ ] **Step 3: Add clearLeafDropZones helper to PaneManager**

In `Pine/PaneManager.swift`, after `clearAllDropZones()`, add:

```swift
/// Clears leaf-level drop zone overlays without touching rootDropZone.
func clearLeafDropZones() {
    dropZones.removeAll()
}
```

- [ ] **Step 4: Run swiftlint**

Run: `swiftlint Pine/RootDropZone.swift Pine/PaneManager.swift`
Expected: No warnings or errors

- [ ] **Step 5: Commit**

```bash
git add Pine/RootDropZone.swift Pine/PaneManager.swift
git commit -m "feat: add RootDropOverlay and RootPaneSplitDropDelegate (#712)"
```

---

### Task 4: Integrate into PaneTreeView

**Files:**
- Modify: `Pine/PaneTreeView.swift` — add root overlay and onDrop delegate

- [ ] **Step 1: Add root overlay and drop delegate to PaneTreeView**

Replace the `PaneTreeView` body in `Pine/PaneTreeView.swift` (lines 18-31):

```swift
struct PaneTreeView: View {
    let node: PaneNode
    @Environment(PaneManager.self) private var paneManager
    @State private var containerSize: CGSize = .zero

    var body: some View {
        nodeContent
            .overlay {
                GeometryReader { geometry in
                    Color.clear
                        .preference(key: RootContainerSizeKey.self, value: geometry.size)
                }
            }
            .onPreferenceChange(RootContainerSizeKey.self) { containerSize = $0 }
            .overlay {
                RootDropOverlay(dropZone: paneManager.rootDropZone)
            }
            .onDrop(of: [.paneTabDrag], delegate: RootPaneSplitDropDelegate(
                paneManager: paneManager,
                containerSize: containerSize
            ))
    }

    @ViewBuilder
    private var nodeContent: some View {
        switch node {
        case .leaf(let paneID, let content):
            PaneLeafView(paneID: paneID, content: content)

        case .split(let axis, let first, let second, let ratio):
            PaneSplitView(
                axis: axis,
                first: first,
                second: second,
                ratio: ratio
            )
        }
    }
}
```

- [ ] **Step 2: Add RootContainerSizeKey preference key**

Append to `Pine/RootDropZone.swift`:

```swift
// MARK: - Preference Key

/// Captures the root container size for root drop zone calculations.
struct RootContainerSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}
```

- [ ] **Step 3: Run swiftlint**

Run: `swiftlint Pine/PaneTreeView.swift Pine/RootDropZone.swift`
Expected: No warnings or errors

- [ ] **Step 4: Build to verify compilation**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Pine.xcodeproj -scheme Pine build 2>&1 | tail -10`
Expected: BUILD SUCCEEDED

- [ ] **Step 5: Run all pane-related tests for regressions**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project Pine.xcodeproj -scheme Pine -destination 'platform=macOS' -only-testing:PineTests/PaneManagerTests 2>&1 | tail -20`

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project Pine.xcodeproj -scheme Pine -destination 'platform=macOS' -only-testing:PineTests/PaneNodeTests 2>&1 | tail -20`

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project Pine.xcodeproj -scheme Pine -destination 'platform=macOS' -only-testing:PineTests/RootDropZoneTests 2>&1 | tail -20`

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project Pine.xcodeproj -scheme Pine -destination 'platform=macOS' -only-testing:PineTests/PaneManagerRootDropTests 2>&1 | tail -20`

Expected: All tests PASS

- [ ] **Step 6: Commit**

```bash
git add Pine/PaneTreeView.swift Pine/RootDropZone.swift
git commit -m "feat: integrate root drop zones into PaneTreeView (#712)"
```

---

### Task 5: SwiftLint, full build, and final verification

**Files:**
- All modified files

- [ ] **Step 1: Run swiftlint on all changed files**

Run: `swiftlint Pine/RootDropZone.swift Pine/PaneManager.swift Pine/PaneTreeView.swift`
Expected: No warnings or errors

- [ ] **Step 2: Full build**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Pine.xcodeproj -scheme Pine build 2>&1 | tail -10`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Run all unit tests**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project Pine.xcodeproj -scheme Pine -destination 'platform=macOS' -only-testing:PineTests/RootDropZoneTests 2>&1 | tail -20`

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project Pine.xcodeproj -scheme Pine -destination 'platform=macOS' -only-testing:PineTests/PaneManagerRootDropTests 2>&1 | tail -20`

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project Pine.xcodeproj -scheme Pine -destination 'platform=macOS' -only-testing:PineTests/PaneManagerTests 2>&1 | tail -20`

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project Pine.xcodeproj -scheme Pine -destination 'platform=macOS' -only-testing:PineTests/PaneNodeTests 2>&1 | tail -20`

Expected: All tests PASS

- [ ] **Step 4: Create PR branch and push**

```bash
git checkout -b feat/root-drop-zones-712
git push -u origin feat/root-drop-zones-712
```

- [ ] **Step 5: Create PR**

```bash
gh pr create --title "feat: root-level drop zones for full-width/height pane splits" --body "$(cat <<'EOF'
## Summary

- Add root-level drop zones at window edges (10% threshold) for creating full-width/height terminal panes
- New `RootDropZone` enum with edge detection logic
- New `PaneManager.wrapRootWithTerminal()` method wraps entire root in a new split
- Visual overlay distinguishes root drops from leaf drops
- Only terminal tabs accepted for root-level drops

Closes #712

## Test plan

- [ ] Run `RootDropZoneTests` — zone detection for all 4 edges, corners, center, boundaries
- [ ] Run `PaneManagerRootDropTests` — tree structure verification for all 4 directions, tab movement, source cleanup
- [ ] Run existing `PaneManagerTests` and `PaneNodeTests` — no regressions
- [ ] Manual: drag terminal tab to window edge → full-width/height terminal pane created
- [ ] Manual: drag terminal tab to leaf interior → normal leaf-level split (unchanged behavior)
- [ ] Manual: drag editor tab to window edge → rejected (no root overlay shown)
EOF
)" --label "editor,enhancement"
```
