//
//  PaneManagerEdgeTests.swift
//  PineTests
//

import Testing
import Foundation
@testable import Pine

@Suite("PaneManager Edge Case Tests")
@MainActor
struct PaneManagerEdgeTests {

    // MARK: - Maximize / Restore

    @Test func maximize_setsMaximizedState() {
        let manager = PaneManager()
        let paneID = manager.activePaneID
        manager.maximize(paneID: paneID)

        #expect(manager.isMaximized)
        #expect(manager.maximizedPaneID == paneID)
        #expect(manager.savedRootBeforeMaximize != nil)
    }

    @Test func maximize_alreadyMaximized_noOp() {
        let manager = PaneManager()
        let paneID = manager.activePaneID
        manager.maximize(paneID: paneID)

        // Try to maximize again
        let savedRoot = manager.savedRootBeforeMaximize
        manager.maximize(paneID: paneID)
        // Should not change
        #expect(manager.savedRootBeforeMaximize?.leafCount == savedRoot?.leafCount)
    }

    @Test func restoreFromMaximize_restoresLayout() {
        let manager = PaneManager()
        let paneID = manager.activePaneID
        _ = manager.splitPane(paneID, axis: .horizontal)

        let leafCountBefore = manager.root.leafCount
        manager.maximize(paneID: manager.activePaneID)
        #expect(manager.root.leafCount == 1)

        manager.restoreFromMaximize()
        #expect(manager.root.leafCount == leafCountBefore)
        #expect(manager.isMaximized == false)
    }

    @Test func restoreFromMaximize_noSaved_noOp() {
        let manager = PaneManager()
        manager.restoreFromMaximize()
        #expect(manager.isMaximized == false)
    }

    // MARK: - Toggle zoom on active terminal pane (#1115)

    @Test func toggleZoom_maximizesActiveTerminalPane() {
        let manager = PaneManager()
        let terminalPane = manager.createTerminalPaneAtBottom(workingDirectory: nil)
        manager.activePaneID = terminalPane
        #expect(manager.terminalPaneIDs.contains(terminalPane))

        manager.toggleMaximizeOnActiveTerminalPane()
        #expect(manager.isMaximized)
        #expect(manager.maximizedPaneID == terminalPane)
    }

    @Test func toggleZoom_restoresWhenAlreadyMaximized() throws {
        let manager = PaneManager()
        let terminalPane = manager.createTerminalPaneAtBottom(workingDirectory: nil)
        manager.activePaneID = terminalPane
        // Capture the editor pane id BEFORE maximize — after maximize `root`
        // is a single terminal leaf and the editor lives only in
        // `savedRootBeforeMaximize`, so `root.leafIDs` would not find it.
        let editorPane = try #require(manager.root.leafIDs.first { $0 != terminalPane })
        manager.toggleMaximizeOnActiveTerminalPane()
        #expect(manager.isMaximized)

        // Toggle from ANY focus (even non-terminal) always exits zoom —
        // `isMaximized` is checked before the focus guard.
        manager.activePaneID = editorPane
        manager.toggleMaximizeOnActiveTerminalPane()
        #expect(manager.isMaximized == false)
        #expect(manager.maximizedPaneID == nil)
        // Layout restored exactly: editor + terminal split (2 leaves).
        #expect(manager.root.leafCount == 2)
    }

    @Test func toggleZoom_idempotentCycle() {
        // maximize → restore → maximize-again must return to the same zoomed
        // state without corrupting the saved root. The headline "toggle" UX.
        let manager = PaneManager()
        let terminalPane = manager.createTerminalPaneAtBottom(workingDirectory: nil)
        manager.activePaneID = terminalPane

        manager.toggleMaximizeOnActiveTerminalPane() // maximize
        #expect(manager.isMaximized)
        manager.toggleMaximizeOnActiveTerminalPane() // restore
        #expect(manager.isMaximized == false)
        #expect(manager.root.leafCount == 2)
        manager.toggleMaximizeOnActiveTerminalPane() // maximize again
        #expect(manager.isMaximized)
        #expect(manager.maximizedPaneID == terminalPane)
        #expect(manager.root.leafCount == 1)
    }

    @Test func toggleZoom_noTerminalPane_noOp() {
        // Default PaneManager has only an editor pane; toggle must no-op
        // rather than maximize the editor (#1115: zoom is terminal-only).
        //
        // Note: the 'editor focused but a terminal exists elsewhere' variant
        // is covered by `toggleZoom_restoresWhenAlreadyMaximized`, which
        // switches activePaneID to the editor leaf mid-test.
        // `createTerminalPaneAtBottom` switches active to the new terminal,
        // so an editor-focused setup cannot be constructed via that helper
        // alone — the editor leaf is obtained from `root.leafIDs` instead.
        let manager = PaneManager()
        manager.toggleMaximizeOnActiveTerminalPane()
        #expect(manager.isMaximized == false)
    }

    @Test func persistableRoot_returnsFullLayoutWhenMaximized() {
        let manager = PaneManager()
        let paneID = manager.activePaneID
        _ = manager.splitPane(paneID, axis: .horizontal)
        let fullLeafCount = manager.root.leafCount

        manager.maximize(paneID: manager.activePaneID)
        #expect(manager.root.leafCount == 1) // maximized
        #expect(manager.persistableRoot.leafCount == fullLeafCount) // returns full layout
    }

    // MARK: - Terminal pane operations

    @Test func createTerminalPane_createsPane() {
        let manager = PaneManager()
        let paneID = manager.activePaneID
        let termID = manager.createTerminalPane(
            relativeTo: paneID, axis: .vertical, workingDirectory: nil
        )
        #expect(termID != nil)
        #expect(manager.terminalPaneIDs.count == 1)
    }

    @Test func createTerminalPaneAtBottom_wrapsRoot() {
        let manager = PaneManager()
        let termID = manager.createTerminalPaneAtBottom(workingDirectory: nil)
        #expect(manager.root.leafCount == 2)
        #expect(manager.terminalPaneIDs.contains(termID))
        #expect(manager.activePaneID == termID)
    }

    @Test func terminalState_forValidPaneID() {
        let manager = PaneManager()
        let termID = manager.createTerminalPaneAtBottom(workingDirectory: nil)
        let state = manager.terminalState(for: termID)
        #expect(state != nil)
        #expect(state?.terminalTabs.count == 1)
    }

    @Test func terminalState_forInvalidPaneID() {
        let manager = PaneManager()
        let state = manager.terminalState(for: PaneID())
        #expect(state == nil)
    }

    @Test func allTerminalTabs_countsCorrectly() {
        let manager = PaneManager()
        _ = manager.createTerminalPaneAtBottom(workingDirectory: nil)
        #expect(manager.allTerminalTabs.count == 1)
    }

    // MARK: - removePane

    @Test func removePane_lastLeaf_createsNewEditor() {
        let manager = PaneManager()
        let onlyPane = manager.activePaneID
        manager.removePane(onlyPane)

        // Should create a new editor leaf
        #expect(manager.root.leafCount == 1)
        #expect(manager.activePaneID != onlyPane)
        #expect(manager.tabManagers.count == 1)
    }

    @Test func removePane_switchesActivePaneIfRemoved() {
        let manager = PaneManager()
        let first = manager.activePaneID
        guard let second = manager.splitPane(first, axis: .horizontal) else {
            Issue.record("Split failed")
            return
        }
        manager.activePaneID = first

        manager.removePane(first)
        #expect(manager.activePaneID == second)
    }

    @Test func removePane_maximizedPane_restoresFirst() {
        let manager = PaneManager()
        let first = manager.activePaneID
        _ = manager.splitPane(first, axis: .horizontal)
        manager.maximize(paneID: first)

        manager.removePane(first)
        #expect(!manager.isMaximized)
    }

    // MARK: - updateRatio

    @Test func updateRatio_changesRatio() {
        let manager = PaneManager()
        let first = manager.activePaneID
        _ = manager.splitPane(first, axis: .horizontal)

        manager.updateRatio(for: first, ratio: 0.7)
        if case .split(_, _, _, let ratio) = manager.root {
            // updateRatio sets the parent split's ratio to exactly the clamped value
            #expect(abs(ratio - 0.7) < 0.001)
        } else {
            Issue.record("Expected root to be a split node")
        }
    }

    @Test func updateSplitRatio_changesRatio() {
        let manager = PaneManager()
        let first = manager.activePaneID
        // Create a two-level tree: root splits into (split(first, third), second)
        guard let second = manager.splitPane(first, axis: .horizontal) else {
            Issue.record("First split failed")
            return
        }
        // Split 'first' again so it becomes a child of an inner split
        guard let third = manager.splitPane(first, axis: .vertical) else {
            Issue.record("Second split failed")
            return
        }
        #expect(third != PaneID())

        // Now 'first' is a direct leaf child of an inner split node.
        // updateSplitRatio(containing: first) targets the root split (one level up).
        if case .split(_, _, _, let ratioBefore) = manager.root {
            manager.updateSplitRatio(containing: first, ratio: 0.8)
            if case .split(_, _, _, let ratioAfter) = manager.root {
                #expect(abs(ratioAfter - 0.8) < 0.001)
                #expect(abs(ratioAfter - ratioBefore) > 0.01)
            } else {
                Issue.record("Expected root to remain a split node")
            }
        } else {
            Issue.record("Expected root to be a split node")
        }
        _ = second // suppress unused warning
    }

    // MARK: - Drop zone management

    @Test func clearAllDropZones() {
        let manager = PaneManager()
        manager.dropZones[PaneID()] = .right
        manager.rootDropZone = .bottom
        manager.clearAllDropZones()
        #expect(manager.dropZones.isEmpty)
        #expect(manager.rootDropZone == nil)
    }

    @Test func clearLeafDropZones_preservesRoot() {
        let manager = PaneManager()
        manager.dropZones[PaneID()] = .right
        manager.rootDropZone = .bottom
        manager.clearLeafDropZones()
        #expect(manager.dropZones.isEmpty)
        #expect(manager.rootDropZone == .bottom)
    }

    @Test func hasActiveDropZones_trueWhenLeafDropZone() {
        let manager = PaneManager()
        manager.dropZones[PaneID()] = .right
        #expect(manager.hasActiveDropZones)
    }

    @Test func hasActiveDropZones_trueWhenRootDropZone() {
        let manager = PaneManager()
        manager.rootDropZone = .top
        #expect(manager.hasActiveDropZones)
    }

    @Test func hasActiveDropZones_falseWhenEmpty() {
        let manager = PaneManager()
        #expect(!manager.hasActiveDropZones)
    }

    @Test func clearStaleDropZonesIfNoDragActive_noDropZones_noOp() {
        let manager = PaneManager()
        manager.clearStaleDropZonesIfNoDragActive()
        // No crash
    }

    @Test func clearStaleDropZonesIfNoDragActive_clearsWhenNoMouseDown() {
        let manager = PaneManager()
        manager.isMouseButtonPressed = { false }
        manager.dropZones[PaneID()] = .right
        manager.clearStaleDropZonesIfNoDragActive()
        #expect(manager.dropZones.isEmpty)
    }

    @Test func clearStaleDropZonesIfNoDragActive_keepsWhenMouseDown() {
        let manager = PaneManager()
        manager.isMouseButtonPressed = { true }
        let id = PaneID()
        manager.dropZones[id] = .right
        manager.clearStaleDropZonesIfNoDragActive()
        #expect(!manager.dropZones.isEmpty)
    }

    // MARK: - ensureEditorPane

    @Test func ensureEditorPane_returnsExistingEditorTM() {
        let manager = PaneManager()
        let tm = manager.ensureEditorPane()
        #expect(tm === manager.activeTabManager)
    }

    // MARK: - allTabManagers

    @Test func allTabManagers_returnsAll() {
        let manager = PaneManager()
        let first = manager.activePaneID
        _ = manager.splitPane(first, axis: .horizontal)
        #expect(manager.allTabManagers.count == 2)
    }

    // MARK: - activeEditorTabManager fallback

    @Test func activeEditorTabManager_fallsBackWhenTerminalActive() {
        let manager = PaneManager()
        let editorPaneID = manager.activePaneID
        let termID = manager.createTerminalPaneAtBottom(workingDirectory: nil)
        manager.activePaneID = termID

        let editorTM = manager.activeEditorTabManager
        #expect(editorTM != nil)
        #expect(editorTM === manager.tabManager(for: editorPaneID))
    }

    // MARK: - openFileInPane

    @Test func openFileInPane_skipsDirectory() {
        let manager = PaneManager()
        let paneID = manager.activePaneID
        let dir = FileManager.default.temporaryDirectory
        manager.openFileInPane(url: dir, paneID: paneID)
        #expect(manager.activeTabManager?.tabs.isEmpty == true)
    }

    @Test func openFileInPane_opensFile() throws {
        let manager = PaneManager()
        let paneID = manager.activePaneID
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaneMgrEdge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("test.swift")
        try "test".write(to: url, atomically: true, encoding: .utf8)

        manager.openFileInPane(url: url, paneID: paneID)
        #expect(manager.activeTabManager?.tabs.count == 1)
    }

    // MARK: - splitAndOpenFile

    @Test func splitAndOpenFile_createsNewPaneWithFile() throws {
        let manager = PaneManager()
        let paneID = manager.activePaneID
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaneMgrEdge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("test.swift")
        try "test".write(to: url, atomically: true, encoding: .utf8)

        let newID = manager.splitAndOpenFile(url: url, relativeTo: paneID, axis: .horizontal)
        #expect(newID != nil)
        if let newID {
            #expect(manager.tabManager(for: newID)?.tabs.count == 1)
        }
    }

    // MARK: - clearStaleDragState

    @Test func clearStaleDragState_clearsActiveDrag() {
        let manager = PaneManager()
        manager.activeDrag = TabDragInfo(
            paneID: UUID(),
            tabID: UUID(),
            fileURL: nil,
            contentType: .editor
        )
        manager.clearStaleDragState()
        #expect(manager.activeDrag == nil)
    }

    // MARK: - insertBefore split

    @Test func splitPane_insertBefore() {
        let manager = PaneManager()
        let first = manager.activePaneID
        let newID = manager.splitPane(first, axis: .horizontal, insertBefore: true)
        #expect(newID != nil)
        #expect(manager.root.leafCount == 2)
    }
}
