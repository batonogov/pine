//
//  PaneSplitDropIntegrationTests.swift
//  PineTests
//
//  Integration coverage for `PaneSplitDropDelegate` (issue #1002).
//
//  Pine's split-pane drag/drop has rich data-layer coverage
//  (`TabDragInfoTests`, `TabDropDelegateTests`, `CrossTypeCenterDropTests`,
//  `PaneManagerRootDropTests`, etc.), but the SwiftUI `.onDrop` seam — the
//  glue inside `PaneSplitDropDelegate` that maps
//  (cursor location → zone → (axis, insertBefore) → PaneManager mutation) —
//  was previously untested.
//
//  SwiftUI's `DropInfo` has no public initializer, so `performDrop(info:)`
//  cannot be driven directly from a unit test. `PaneSplitDropDelegate`
//  exposes `performPaneTabDrop(zone:)` as a testable entry point that is
//  byte-for-byte equivalent to the pane-tab branch of `performDrop(info:)`.
//  These tests drive that entry point together with the public
//  `PaneDropZone.zone(for:in:)` cursor-mapping function, exercising the
//  full cursor → zone → mutation → resulting tree-shape pipeline end-to-end
//  without paying the cost of an unreliable XCUITest drag.
//

import CoreGraphics
import Foundation
import Testing

@testable import Pine

@Suite("PaneSplitDropDelegate Integration Tests")
@MainActor
struct PaneSplitDropIntegrationTests {

    // MARK: - Helpers

    /// Snapshot of the two-editor-pane setup used by many tests.
    struct TwoEditorPanes {
        let manager: PaneManager
        let paneA: PaneID
        let fileA: URL
        let paneB: PaneID
        let fileB: URL
    }

    /// Snapshot of the editor+terminal setup used by cross-type tests.
    struct EditorAndTerminal {
        let manager: PaneManager
        let editorID: PaneID
        let terminalID: PaneID
    }

    /// Pane size used for cursor → zone mapping. Large enough that the 25%
    /// edge threshold (see `PaneDropZone.edgeThreshold`) maps cleanly to
    /// integer cursor coordinates.
    private let paneSize = CGSize(width: 1000, height: 1000)

    /// Cursor positions inside `paneSize` for each of the 5 zones.
    private enum Cursor {
        static let left = CGPoint(x: 50, y: 500)      // 5% from left, mid-height
        static let right = CGPoint(x: 950, y: 500)    // 5% from right, mid-height
        static let top = CGPoint(x: 500, y: 50)       // mid-width, 5% from top
        static let bottom = CGPoint(x: 500, y: 950)   // mid-width, 5% from bottom
        static let center = CGPoint(x: 500, y: 500)   // dead center
    }

    /// Builds a delegate targeting `paneID` on `manager` with the suite's
    /// standard pane size.
    private func delegate(
        for paneID: PaneID,
        on manager: PaneManager,
        size: CGSize? = nil
    ) -> PaneSplitDropDelegate {
        PaneSplitDropDelegate(
            paneID: paneID,
            paneManager: manager,
            paneSize: size ?? paneSize
        )
    }

    /// Two editor panes side-by-side; each pane owns one tab.
    private func managerWithTwoEditorPanes() throws -> TwoEditorPanes {
        let manager = PaneManager()
        let paneA = manager.activePaneID
        let tmA = try #require(manager.tabManager(for: paneA))
        let fileA = URL(fileURLWithPath: "/tmp/a.swift")
        tmA.openTab(url: fileA)

        let paneB = try #require(manager.splitPane(paneA, axis: .horizontal))
        let tmB = try #require(manager.tabManager(for: paneB))
        let fileB = URL(fileURLWithPath: "/tmp/b.swift")
        tmB.openTab(url: fileB)

        return TwoEditorPanes(
            manager: manager, paneA: paneA, fileA: fileA, paneB: paneB, fileB: fileB
        )
    }

    /// One editor pane and one full-width terminal pane at the bottom.
    /// The terminal pane owns two tabs so it survives a single-tab move.
    private func managerWithEditorAndTerminalPane() throws -> EditorAndTerminal {
        let manager = PaneManager()
        let editorID = manager.activePaneID
        let editorTM = try #require(manager.tabManager(for: editorID))
        editorTM.openTab(url: URL(fileURLWithPath: "/tmp/a.swift"))

        let termID = manager.createTerminalPaneAtBottom(workingDirectory: nil)
        let termState = try #require(manager.terminalState(for: termID))
        // Add a second tab so the source survives after a single-tab move.
        termState.addTab(workingDirectory: nil)
        return EditorAndTerminal(manager: manager, editorID: editorID, terminalID: termID)
    }

    // MARK: - Zone Detection (cursor → PaneDropZone)

    // These mirror what `updateDropZone(info:)` does internally: it calls
    // `PaneDropZone.zone(for:in:)` with the cursor location and the pane size.
    // Verifying the mapping here confirms the cursor→zone seam that drives
    // the rest of `PaneSplitDropDelegate`.

    @Test("Cursor in right edge maps to .right zone")
    func zoneDetection_right() {
        let zone = PaneDropZone.zone(for: Cursor.right, in: paneSize)
        #expect(zone == .right)
    }

    @Test("Cursor in left edge maps to .left zone")
    func zoneDetection_left() {
        let zone = PaneDropZone.zone(for: Cursor.left, in: paneSize)
        #expect(zone == .left)
    }

    @Test("Cursor in top edge maps to .top zone")
    func zoneDetection_top() {
        let zone = PaneDropZone.zone(for: Cursor.top, in: paneSize)
        #expect(zone == .top)
    }

    @Test("Cursor in bottom edge maps to .bottom zone")
    func zoneDetection_bottom() {
        let zone = PaneDropZone.zone(for: Cursor.bottom, in: paneSize)
        #expect(zone == .bottom)
    }

    @Test("Cursor in dead center maps to .center zone")
    func zoneDetection_center() {
        let zone = PaneDropZone.zone(for: Cursor.center, in: paneSize)
        #expect(zone == .center)
    }

    @Test("Corner cursor resolves to the nearer edge axis")
    func zoneDetection_cornerResolution() {
        // Top-left corner: (5,5) in a 1000x1000 box. Both x and y are 0.5%
        // from their edges — equal under `distToEdgeX == distToEdgeY`, so
        // the implementation prefers the horizontal (left) axis.
        let corner = PaneDropZone.zone(for: CGPoint(x: 5, y: 5), in: paneSize)
        #expect(corner == .left)
    }

    @Test("Zero pane size falls back to .center")
    func zoneDetection_zeroSize_fallsBackToCenter() {
        let zone = PaneDropZone.zone(for: Cursor.right, in: .zero)
        #expect(zone == .center)
    }

    // MARK: - Edge drops: editor tab → editor pane (resulting tree shape)

    @Test("Right edge drop of editor tab creates horizontal split, new pane second")
    func editorToEditor_right_newPaneSecond() throws {
        let setup = try managerWithTwoEditorPanes()
        let manager = setup.manager
        let paneA = setup.paneA
        let fileA = setup.fileA
        let paneB = setup.paneB
        let delegate = delegate(for: paneB, on: manager)
        manager.activeDrag = TabDragInfo(
            paneID: paneA.id, tabID: UUID(), fileURL: fileA, contentType: .editor
        )
        let beforeLeafCount = manager.root.leafCount

        let ok = delegate.performPaneTabDrop(zone: .right)

        #expect(ok)
        // Tree grew by exactly one new editor leaf.
        #expect(manager.root.leafCount == beforeLeafCount + 1)
        #expect(manager.root.leafCount(ofType: .editor) == 3)
        // The new pane is the active pane and sits horizontally after paneB.
        if case .split(let axis, let first, let second, _) = manager.root {
            #expect(axis == .horizontal)
            // The root split is unchanged (paneA | paneB-tree); the new
            // horizontal split is nested inside the second child.
            #expect(first.contains(paneA))
            #expect(second.contains(paneB))
            #expect(manager.activePaneID != paneA && manager.activePaneID != paneB)
        } else {
            Issue.record("Expected root to remain a split after edge drop")
        }
        // Moved tab now lives in the new active pane.
        let newTM = try #require(manager.tabManager(for: manager.activePaneID))
        #expect(newTM.tabs.contains { $0.url == fileA })
        // activeDrag cleared after success.
        #expect(manager.activeDrag == nil)
    }

    @Test("Left edge drop of editor tab creates horizontal split, new pane first")
    func editorToEditor_left_newPaneFirst() throws {
        let setup = try managerWithTwoEditorPanes()
        let manager = setup.manager
        let paneA = setup.paneA
        let fileA = setup.fileA
        let paneB = setup.paneB
        let delegate = delegate(for: paneB, on: manager)
        manager.activeDrag = TabDragInfo(
            paneID: paneA.id, tabID: UUID(), fileURL: fileA, contentType: .editor
        )

        let ok = delegate.performPaneTabDrop(zone: .left)

        #expect(ok)
        #expect(manager.root.leafCount(ofType: .editor) == 3)
        // New pane is active and is the first child of paneB's split.
        let newID = manager.activePaneID
        #expect(newID != paneA && newID != paneB)
        let newTM = try #require(manager.tabManager(for: newID))
        #expect(newTM.tabs.contains { $0.url == fileA })
    }

    @Test("Bottom edge drop of editor tab creates vertical split, new pane second")
    func editorToEditor_bottom_newPaneSecond() throws {
        let setup = try managerWithTwoEditorPanes()
        let manager = setup.manager
        let paneA = setup.paneA
        let fileA = setup.fileA
        let paneB = setup.paneB
        let delegate = delegate(for: paneB, on: manager)
        manager.activeDrag = TabDragInfo(
            paneID: paneA.id, tabID: UUID(), fileURL: fileA, contentType: .editor
        )

        let ok = delegate.performPaneTabDrop(zone: .bottom)

        #expect(ok)
        #expect(manager.root.leafCount(ofType: .editor) == 3)
        let newID = manager.activePaneID
        let newTM = try #require(manager.tabManager(for: newID))
        #expect(newTM.tabs.contains { $0.url == fileA })
        // paneB's split axis is vertical (top/bottom edge → vertical).
        if case .split(.horizontal, _, let second, _) = manager.root,
           case .split(let axis, _, _, _) = second {
            #expect(axis == .vertical)
        } else {
            Issue.record("Expected vertical split under paneB after bottom drop")
        }
    }

    @Test("Top edge drop of editor tab creates vertical split, new pane first")
    func editorToEditor_top_newPaneFirst() throws {
        let setup = try managerWithTwoEditorPanes()
        let manager = setup.manager
        let paneA = setup.paneA
        let fileA = setup.fileA
        let paneB = setup.paneB
        let delegate = delegate(for: paneB, on: manager)
        manager.activeDrag = TabDragInfo(
            paneID: paneA.id, tabID: UUID(), fileURL: fileA, contentType: .editor
        )

        let ok = delegate.performPaneTabDrop(zone: .top)

        #expect(ok)
        #expect(manager.root.leafCount(ofType: .editor) == 3)
        let newID = manager.activePaneID
        let newTM = try #require(manager.tabManager(for: newID))
        #expect(newTM.tabs.contains { $0.url == fileA })
    }

    // MARK: - Edge drops: terminal tab → terminal pane

    @Test("Right edge drop of terminal tab creates horizontal terminal split")
    func terminalToTerminal_right() throws {
        let setup = try managerWithEditorAndTerminalPane()
        let manager = setup.manager
        let termID = setup.terminalID
        // Add a third terminal tab so the source survives after the move.
        let termState = try #require(manager.terminalState(for: termID))
        #expect(termState.terminalTabs.count >= 2)
        let movedTabID = termState.terminalTabs[0].id

        let delegate = delegate(for: termID, on: manager)
        manager.activeDrag = TabDragInfo(
            paneID: termID.id, tabID: movedTabID, fileURL: nil, contentType: .terminal
        )
        let beforeTermCount = manager.root.leafCount(ofType: .terminal)

        let ok = delegate.performPaneTabDrop(zone: .right)

        #expect(ok)
        #expect(manager.root.leafCount(ofType: .terminal) == beforeTermCount + 1)
        // New terminal pane is active and contains the moved tab.
        let newTermID = manager.activePaneID
        #expect(newTermID != termID)
        let newState = try #require(manager.terminalState(for: newTermID))
        #expect(newState.terminalTabs.contains { $0.id == movedTabID })
        // Source terminal pane still alive with remaining tabs.
        #expect(manager.terminalState(for: termID) != nil)
        #expect(manager.activeDrag == nil)
    }

    @Test("Bottom edge drop of terminal tab creates vertical terminal split")
    func terminalToTerminal_bottom() throws {
        let setup = try managerWithEditorAndTerminalPane()
        let manager = setup.manager
        let termID = setup.terminalID
        let termState = try #require(manager.terminalState(for: termID))
        let movedTabID = termState.terminalTabs[0].id

        let delegate = delegate(for: termID, on: manager)
        manager.activeDrag = TabDragInfo(
            paneID: termID.id, tabID: movedTabID, fileURL: nil, contentType: .terminal
        )

        let ok = delegate.performPaneTabDrop(zone: .bottom)

        #expect(ok)
        #expect(manager.root.leafCount(ofType: .terminal) == 2)
        let newState = try #require(manager.terminalState(for: manager.activePaneID))
        #expect(newState.terminalTabs.contains { $0.id == movedTabID })
    }

    // MARK: - Cross-type edge drops (no refusal — matching pane is created)

    // PaneSplitDropDelegate does not reject cross-type edge drops: an edge
    // drop always creates a new pane of the dragged tab's content type
    // adjacent to the target. Cross-type behavior is therefore
    // "auto-create matching pane", not "refuse". This differs from
    // RootPaneSplitDropDelegate which only accepts terminal tabs. We pin
    // the actual behavior so a regression (silent refusal or wrong-type
    // pane creation) is caught.

    @Test("Right edge drop of terminal tab on editor pane creates terminal pane on right")
    func terminalToEditor_right_createsTerminalPane() throws {
        let setup = try managerWithEditorAndTerminalPane()
        let manager = setup.manager
        let editorID = setup.editorID
        let termID = setup.terminalID
        let termState = try #require(manager.terminalState(for: termID))
        let movedTabID = termState.terminalTabs[0].id
        let beforeTermCount = manager.root.leafCount(ofType: .terminal)

        let delegate = delegate(for: editorID, on: manager)
        manager.activeDrag = TabDragInfo(
            paneID: termID.id, tabID: movedTabID, fileURL: nil, contentType: .terminal
        )

        let ok = delegate.performPaneTabDrop(zone: .right)

        #expect(ok)
        // A new terminal pane was created adjacent to the editor target.
        #expect(manager.root.leafCount(ofType: .terminal) == beforeTermCount + 1)
        let newTermID = try #require(
            manager.terminalPaneIDs.first { $0 != termID }
        )
        let newState = try #require(manager.terminalState(for: newTermID))
        #expect(newState.terminalTabs.contains { $0.id == movedTabID })
        // Editor pane still has its tab.
        let editorTM = try #require(manager.tabManager(for: editorID))
        #expect(editorTM.tabs.count == 1)
    }

    @Test("Right edge drop of editor tab on terminal pane creates editor pane on right")
    func editorToTerminal_right_createsEditorPane() throws {
        let setup = try managerWithEditorAndTerminalPane()
        let manager = setup.manager
        let editorID = setup.editorID
        let termID = setup.terminalID
        let editorTM = try #require(manager.tabManager(for: editorID))
        let fileA = URL(fileURLWithPath: "/tmp/a.swift")
        // Ensure the editor has the tab we'll drag (already opened by helper).
        #expect(editorTM.tabs.contains { $0.url == fileA })
        let beforeEditorCount = manager.root.leafCount(ofType: .editor)

        let delegate = delegate(for: termID, on: manager)
        manager.activeDrag = TabDragInfo(
            paneID: editorID.id, tabID: UUID(), fileURL: fileA, contentType: .editor
        )

        let ok = delegate.performPaneTabDrop(zone: .right)

        #expect(ok)
        // A new editor pane was created adjacent to the terminal target.
        #expect(manager.root.leafCount(ofType: .editor) == beforeEditorCount + 1)
        let newEditorID = try #require(
            manager.root.leafIDs.first {
                $0 != editorID && manager.root.content(for: $0) == .editor
            }
        )
        let newTM = try #require(manager.tabManager(for: newEditorID))
        #expect(newTM.tabs.contains { $0.url == fileA })
        // Terminal target pane is still alive.
        #expect(manager.terminalState(for: termID) != nil)
    }

    @Test("Bottom edge drop of terminal tab on editor pane creates terminal pane below")
    func terminalToEditor_bottom_createsTerminalPane() throws {
        let setup = try managerWithEditorAndTerminalPane()
        let manager = setup.manager
        let editorID = setup.editorID
        let termID = setup.terminalID
        let termState = try #require(manager.terminalState(for: termID))
        let movedTabID = termState.terminalTabs[0].id

        let delegate = delegate(for: editorID, on: manager)
        manager.activeDrag = TabDragInfo(
            paneID: termID.id, tabID: movedTabID, fileURL: nil, contentType: .terminal
        )

        let ok = delegate.performPaneTabDrop(zone: .bottom)

        #expect(ok)
        #expect(manager.root.leafCount(ofType: .terminal) == 2)
        let newTermID = try #require(
            manager.terminalPaneIDs.first { $0 != termID }
        )
        let newState = try #require(manager.terminalState(for: newTermID))
        #expect(newState.terminalTabs.contains { $0.id == movedTabID })
    }

    // MARK: - Center drops (dispatch through performCenterDrop)

    @Test("Center drop of editor tab on editor pane moves tab (no new pane)")
    func editorToEditor_center_movesTab() throws {
        let setup = try managerWithTwoEditorPanes()
        let manager = setup.manager
        let paneA = setup.paneA
        let fileA = setup.fileA
        let paneB = setup.paneB
        let delegate = delegate(for: paneB, on: manager)
        manager.activeDrag = TabDragInfo(
            paneID: paneA.id, tabID: UUID(), fileURL: fileA, contentType: .editor
        )
        let beforeLeafCount = manager.root.leafCount

        let ok = delegate.performPaneTabDrop(zone: .center)

        #expect(ok)
        // Same-type center: tab moves into target. paneA becomes empty and is
        // pruned, so leaf count drops by one.
        #expect(manager.root.leafCount == beforeLeafCount - 1)
        let tmB = try #require(manager.tabManager(for: paneB))
        #expect(tmB.tabs.contains { $0.url == fileA })
        #expect(manager.activeDrag == nil)
    }

    @Test("Center drop of terminal tab on editor pane triggers cross-type auto-split (#714)")
    func terminalToEditor_center_autoSplits() throws {
        let setup = try managerWithEditorAndTerminalPane()
        let manager = setup.manager
        let editorID = setup.editorID
        let termID = setup.terminalID
        let termState = try #require(manager.terminalState(for: termID))
        let movedTabID = termState.terminalTabs[0].id
        let beforeEditorCount = manager.root.leafCount(ofType: .editor)
        let beforeTermCount = manager.root.leafCount(ofType: .terminal)

        let delegate = delegate(for: editorID, on: manager)
        manager.activeDrag = TabDragInfo(
            paneID: termID.id, tabID: movedTabID, fileURL: nil, contentType: .terminal
        )

        let ok = delegate.performPaneTabDrop(zone: .center)

        #expect(ok)
        // Cross-type center auto-splits: editor pane preserved, new terminal
        // pane created adjacent to it.
        #expect(manager.root.leafCount(ofType: .editor) == beforeEditorCount)
        #expect(manager.root.leafCount(ofType: .terminal) == beforeTermCount + 1)
        let newTermPane = try #require(
            manager.terminalPaneIDs.first { $0 != termID }
        )
        let newState = try #require(manager.terminalState(for: newTermPane))
        #expect(newState.terminalTabs.contains { $0.id == movedTabID })
    }

    @Test("Center drop of editor tab on terminal pane triggers cross-type auto-split (#714)")
    func editorToTerminal_center_autoSplits() throws {
        let setup = try managerWithEditorAndTerminalPane()
        let manager = setup.manager
        let editorID = setup.editorID
        let termID = setup.terminalID
        let editorTM = try #require(manager.tabManager(for: editorID))
        let fileA = URL(fileURLWithPath: "/tmp/a.swift")
        // Open a second file so the source editor pane survives the move.
        let fileB = URL(fileURLWithPath: "/tmp/b.swift")
        editorTM.openTab(url: fileB)
        let beforeEditorCount = manager.root.leafCount(ofType: .editor)
        let beforeTermCount = manager.root.leafCount(ofType: .terminal)

        let delegate = delegate(for: termID, on: manager)
        manager.activeDrag = TabDragInfo(
            paneID: editorID.id, tabID: UUID(), fileURL: fileA, contentType: .editor
        )

        let ok = delegate.performPaneTabDrop(zone: .center)

        #expect(ok)
        // Editor count grows by one (new editor pane holds the moved tab);
        // terminal count unchanged.
        #expect(manager.root.leafCount(ofType: .editor) == beforeEditorCount + 1)
        #expect(manager.root.leafCount(ofType: .terminal) == beforeTermCount)
        let newEditor = try #require(
            manager.root.leafIDs.first {
                $0 != editorID && manager.root.content(for: $0) == .editor
            }
        )
        let newTM = try #require(manager.tabManager(for: newEditor))
        #expect(newTM.tabs.contains { $0.url == fileA })
        // Terminal target still alive.
        #expect(manager.terminalState(for: termID) != nil)
    }

    // MARK: - Rejection paths

    @Test("performPaneTabDrop with nil zone returns false and preserves tree")
    func nilZone_returnsFalse_preservesTree() throws {
        let setup = try managerWithTwoEditorPanes()
        let manager = setup.manager
        let paneA = setup.paneA
        let fileA = setup.fileA
        let paneB = setup.paneB
        let delegate = delegate(for: paneB, on: manager)
        manager.activeDrag = TabDragInfo(
            paneID: paneA.id, tabID: UUID(), fileURL: fileA, contentType: .editor
        )
        let beforeRoot = manager.root

        let ok = delegate.performPaneTabDrop(zone: nil)

        #expect(ok == false)
        #expect(manager.root == beforeRoot)
        // Failed drop must NOT clear the drag — caller may retry elsewhere.
        #expect(manager.activeDrag != nil)
    }

    @Test("performPaneTabDrop with no active drag returns false")
    func noActiveDrag_returnsFalse() throws {
        let setup = try managerWithTwoEditorPanes()
        let manager = setup.manager
        let paneB = setup.paneB
        let delegate = delegate(for: paneB, on: manager)
        // No activeDrag set.
        let beforeRoot = manager.root

        let ok = delegate.performPaneTabDrop(zone: .right)

        #expect(ok == false)
        #expect(manager.root == beforeRoot)
    }

    @Test("performPaneTabDrop with nil zone and no drag returns false")
    func nilZone_noDrag_returnsFalse() throws {
        let setup = try managerWithTwoEditorPanes()
        let manager = setup.manager
        let paneB = setup.paneB
        let delegate = delegate(for: paneB, on: manager)

        let ok = delegate.performPaneTabDrop(zone: nil)

        #expect(ok == false)
    }

    @Test("Edge drop of editor tab without fileURL is a no-op but returns true")
    func editorEdgeDrop_withoutFileURL_isNoOp() throws {
        // TabDragInfo.contentType == .editor with fileURL == nil cannot
        // dispatch to splitPane (which needs a URL). The delegate returns
        // true (drop accepted) but performs no tree mutation.
        let setup = try managerWithTwoEditorPanes()
        let manager = setup.manager
        let paneA = setup.paneA
        let paneB = setup.paneB
        let delegate = delegate(for: paneB, on: manager)
        manager.activeDrag = TabDragInfo(
            paneID: paneA.id, tabID: UUID(), fileURL: nil, contentType: .editor
        )
        let beforeRoot = manager.root

        let ok = delegate.performPaneTabDrop(zone: .right)

        #expect(ok == true)
        #expect(manager.root == beforeRoot)
        // activeDrag was consumed (cleared) even though no mutation happened.
        #expect(manager.activeDrag == nil)
    }

    // MARK: - State side-effects

    @Test("Successful edge drop clears activeDrag")
    func successfulDrop_clearsActiveDrag() throws {
        let setup = try managerWithTwoEditorPanes()
        let manager = setup.manager
        let paneA = setup.paneA
        let fileA = setup.fileA
        let paneB = setup.paneB
        let delegate = delegate(for: paneB, on: manager)
        manager.activeDrag = TabDragInfo(
            paneID: paneA.id, tabID: UUID(), fileURL: fileA, contentType: .editor
        )

        _ = delegate.performPaneTabDrop(zone: .right)

        #expect(manager.activeDrag == nil)
    }

    @Test("Successful center drop clears activeDrag")
    func successfulCenterDrop_clearsActiveDrag() throws {
        let setup = try managerWithTwoEditorPanes()
        let manager = setup.manager
        let paneA = setup.paneA
        let fileA = setup.fileA
        let paneB = setup.paneB
        let delegate = delegate(for: paneB, on: manager)
        manager.activeDrag = TabDragInfo(
            paneID: paneA.id, tabID: UUID(), fileURL: fileA, contentType: .editor
        )

        _ = delegate.performPaneTabDrop(zone: .center)

        #expect(manager.activeDrag == nil)
    }

    // MARK: - Complex tree shapes

    @Test("Edge drop on deeply nested target preserves tree integrity")
    func edgeDrop_deeplyNestedTarget_preservesIntegrity() throws {
        // Build a 3-level deep editor tree:
        //   root split (horizontal)
        //     ├─ paneA (editor, fileA)
        //     └─ child split (vertical)
        //         ├─ paneB (editor, fileB)
        //         └─ grandchild split (horizontal)
        //             ├─ paneC (editor, fileC)
        //             └─ paneD (editor, fileD)  <-- target for the drop
        let manager = PaneManager()
        let paneA = manager.activePaneID
        let tmA = try #require(manager.tabManager(for: paneA))
        let fileA = URL(fileURLWithPath: "/tmp/a.swift")
        tmA.openTab(url: fileA)

        let paneB = try #require(manager.splitPane(paneA, axis: .horizontal))
        let tmB = try #require(manager.tabManager(for: paneB))
        let fileB = URL(fileURLWithPath: "/tmp/b.swift")
        tmB.openTab(url: fileB)

        let paneC = try #require(manager.splitPane(paneB, axis: .vertical))
        let tmC = try #require(manager.tabManager(for: paneC))
        let fileC = URL(fileURLWithPath: "/tmp/c.swift")
        tmC.openTab(url: fileC)

        let paneD = try #require(manager.splitPane(paneC, axis: .horizontal))
        let tmD = try #require(manager.tabManager(for: paneD))
        let fileD = URL(fileURLWithPath: "/tmp/d.swift")
        tmD.openTab(url: fileD)

        let beforeEditorCount = manager.root.leafCount(ofType: .editor)
        #expect(beforeEditorCount == 4)

        // Drop fileA from paneA onto the right edge of the deeply nested paneD.
        let delegate = delegate(for: paneD, on: manager)
        manager.activeDrag = TabDragInfo(
            paneID: paneA.id, tabID: UUID(), fileURL: fileA, contentType: .editor
        )

        let ok = delegate.performPaneTabDrop(zone: .right)

        #expect(ok)
        // One new editor leaf created; original 4 panes all still present.
        #expect(manager.root.leafCount(ofType: .editor) == beforeEditorCount + 1)
        let allLeaves = manager.root.leafIDs
        #expect(allLeaves.contains(paneA))
        #expect(allLeaves.contains(paneB))
        #expect(allLeaves.contains(paneC))
        #expect(allLeaves.contains(paneD))
        // Original tabs are intact on their original panes (except fileA,
        // which was moved to the new pane adjacent to paneD).
        #expect(try #require(manager.tabManager(for: paneB)).tabs.first?.url == fileB)
        #expect(try #require(manager.tabManager(for: paneC)).tabs.first?.url == fileC)
        #expect(try #require(manager.tabManager(for: paneD)).tabs.first?.url == fileD)
        // fileA now lives in the new active pane.
        let newTM = try #require(manager.tabManager(for: manager.activePaneID))
        #expect(newTM.tabs.contains { $0.url == fileA })
        // Every leaf is still reachable via content(for:).
        for leaf in allLeaves {
            #expect(manager.root.content(for: leaf) != nil)
        }
    }

    @Test("Terminal edge drop with single source tab removes source pane")
    func terminalEdgeDrop_lastTab_removesSourcePane() throws {
        // Build two terminal panes (one editor pane + two terminal panes),
        // each terminal owning a single tab, so the source can become empty
        // without violating the "always at least one editor pane" invariant.
        let manager = PaneManager()
        let firstTermID = manager.createTerminalPaneAtBottom(workingDirectory: nil)
        // Split the existing terminal pane to create a second terminal pane.
        let secondTermID = try #require(
            manager.createTerminalPane(
                relativeTo: firstTermID, axis: .horizontal, workingDirectory: nil
            )
        )
        // Both terminal panes have exactly one tab (created by
        // createTerminalPane / createTerminalPaneAtBottom).
        let sourceID = firstTermID
        let targetID = secondTermID
        let srcState = try #require(manager.terminalState(for: sourceID))
        #expect(srcState.terminalTabs.count == 1)
        let movedTabID = srcState.terminalTabs[0].id

        let delegate = delegate(for: targetID, on: manager)
        manager.activeDrag = TabDragInfo(
            paneID: sourceID.id, tabID: movedTabID, fileURL: nil, contentType: .terminal
        )

        let ok = delegate.performPaneTabDrop(zone: .right)

        #expect(ok)
        // Source pane removed because its only tab was moved out.
        #expect(manager.terminalState(for: sourceID) == nil)
        // Moved tab landed in the new pane (active).
        let newState = try #require(manager.terminalState(for: manager.activePaneID))
        #expect(newState.terminalTabs.contains { $0.id == movedTabID })
        // Target pane still alive.
        #expect(manager.terminalState(for: targetID) != nil)
    }

    @Test("Cursor-to-zone-to-mutation end-to-end: right edge produces horizontal split")
    func endToEnd_cursorToMutation_rightEdge() throws {
        // Drive the full pipeline: pick a cursor location, derive the zone,
        // feed it through the delegate, and verify the resulting axis.
        let setup = try managerWithTwoEditorPanes()
        let manager = setup.manager
        let paneA = setup.paneA
        let fileA = setup.fileA
        let paneB = setup.paneB
        let delegate = delegate(for: paneB, on: manager)
        manager.activeDrag = TabDragInfo(
            paneID: paneA.id, tabID: UUID(), fileURL: fileA, contentType: .editor
        )

        // Cursor in the right edge → zone should be .right.
        let zone = PaneDropZone.zone(for: Cursor.right, in: paneSize)
        #expect(zone == .right)

        let ok = delegate.performPaneTabDrop(zone: zone)
        #expect(ok)

        // Right edge → horizontal split with new pane as the second child.
        // The root split (paneA horizontal paneB-tree) is preserved; the new
        // horizontal split is nested inside the second child of the root.
        guard case .split(.horizontal, _, let second, _) = manager.root,
              case .split(let nestedAxis, _, _, _) = second else {
            Issue.record("Expected nested horizontal split under paneB")
            return
        }
        #expect(nestedAxis == .horizontal)
    }

    @Test("Cursor-to-zone-to-mutation end-to-end: bottom edge produces vertical split")
    func endToEnd_cursorToMutation_bottomEdge() throws {
        let setup = try managerWithTwoEditorPanes()
        let manager = setup.manager
        let paneA = setup.paneA
        let fileA = setup.fileA
        let paneB = setup.paneB
        let delegate = delegate(for: paneB, on: manager)
        manager.activeDrag = TabDragInfo(
            paneID: paneA.id, tabID: UUID(), fileURL: fileA, contentType: .editor
        )

        let zone = PaneDropZone.zone(for: Cursor.bottom, in: paneSize)
        #expect(zone == .bottom)

        let ok = delegate.performPaneTabDrop(zone: zone)
        #expect(ok)

        // Bottom edge → vertical split.
        guard case .split(.horizontal, _, let second, _) = manager.root,
              case .split(let nestedAxis, _, _, _) = second else {
            Issue.record("Expected nested vertical split under paneB")
            return
        }
        #expect(nestedAxis == .vertical)
    }

    @Test("Cursor-to-zone-to-mutation end-to-end: center triggers same-type move")
    func endToEnd_cursorToMutation_center() throws {
        let setup = try managerWithTwoEditorPanes()
        let manager = setup.manager
        let paneA = setup.paneA
        let fileA = setup.fileA
        let paneB = setup.paneB
        let delegate = delegate(for: paneB, on: manager)
        manager.activeDrag = TabDragInfo(
            paneID: paneA.id, tabID: UUID(), fileURL: fileA, contentType: .editor
        )
        let beforeLeafCount = manager.root.leafCount

        let zone = PaneDropZone.zone(for: Cursor.center, in: paneSize)
        #expect(zone == .center)

        let ok = delegate.performPaneTabDrop(zone: zone)
        #expect(ok)
        // Same-type center: tab moved, source pruned → leaf count drops by 1.
        #expect(manager.root.leafCount == beforeLeafCount - 1)
        let tmB = try #require(manager.tabManager(for: paneB))
        #expect(tmB.tabs.contains { $0.url == fileA })
    }

    // MARK: - paneSize flows through to zone detection

    @Test("Delegate uses its paneSize for cursor→zone mapping consistency")
    func delegate_usesProvidedPaneSize() {
        // A delegate constructed with a tiny pane size still maps cursor
        // positions consistently because the percentage-based threshold
        // is independent of absolute size. Sanity check that the wiring is
        // correct: a cursor at 95% of a 200-wide pane is still in .right.
        let tiny = CGSize(width: 200, height: 200)
        let zone = PaneDropZone.zone(for: CGPoint(x: 195, y: 100), in: tiny)
        #expect(zone == .right)
    }
}
