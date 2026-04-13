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
            #expect(abs(ratio - 0.7) < 0.001 || abs(ratio - 0.3) < 0.001)
        }
    }

    @Test func updateSplitRatio_changesRatio() {
        let manager = PaneManager()
        let first = manager.activePaneID
        _ = manager.splitPane(first, axis: .horizontal)

        manager.updateSplitRatio(containing: first, ratio: 0.8)
        // Just verify it doesn't crash
        #expect(manager.root.leafCount == 2)
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

    @Test func openFileInPane_opensFile() {
        let manager = PaneManager()
        let paneID = manager.activePaneID
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("test.swift")
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? "test".write(to: url, atomically: true, encoding: .utf8)

        manager.openFileInPane(url: url, paneID: paneID)
        #expect(manager.activeTabManager?.tabs.count == 1)
    }

    // MARK: - splitAndOpenFile

    @Test func splitAndOpenFile_createsNewPaneWithFile() {
        let manager = PaneManager()
        let paneID = manager.activePaneID
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("test.swift")
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? "test".write(to: url, atomically: true, encoding: .utf8)

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
