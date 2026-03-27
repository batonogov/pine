//
//  PaneManagerTests.swift
//  PineTests
//

import Testing
import Foundation
@testable import Pine

// swiftlint:disable type_body_length file_length

@Suite("PaneManager Tests")
struct PaneManagerTests {

    // MARK: - Initialization

    @Test func init_createsOnePaneWithTabManager() {
        let manager = PaneManager()
        #expect(manager.paneCount == 1)
        #expect(manager.activeTabManager != nil)
        #expect(manager.tabManagers.count == 1)
        #expect(manager.allPaneIDs.count == 1)
        #expect(manager.allPaneIDs.contains(manager.activePaneID))
    }

    @Test func init_rootNodeIsLeafWithEditor() {
        let manager = PaneManager()
        if case .leaf(let id, let content) = manager.rootNode {
            #expect(id == manager.activePaneID)
            #expect(content == .editor)
        } else {
            Issue.record("Expected leaf node")
        }
    }

    @Test func init_restore_preservesState() {
        let id1 = PaneID()
        let id2 = PaneID()
        let root = PaneNode.split(
            .horizontal,
            first: .leaf(id1, .editor),
            second: .leaf(id2, .terminal),
            ratio: 0.5
        )
        let tm1 = TabManager()
        let tm2 = TabManager()

        let manager = PaneManager(
            rootNode: root,
            activePaneID: id2,
            tabManagers: [id1: tm1, id2: tm2]
        )

        #expect(manager.paneCount == 2)
        #expect(manager.activePaneID == id2)
        #expect(manager.tabManagers[id1] === tm1)
        #expect(manager.tabManagers[id2] === tm2)
        #expect(manager.activeTabManager === tm2)
    }

    // MARK: - Split

    @Test func splitPane_createsTwoPanesWithTabManagers() {
        let manager = PaneManager()
        let originalID = manager.activePaneID
        let originalTabManager = manager.activeTabManager

        manager.splitPane(originalID, axis: .horizontal)

        #expect(manager.paneCount == 2)
        #expect(manager.tabManagers.count == 2)
        // Original pane's TabManager is preserved
        #expect(manager.tabManagers[originalID] === originalTabManager)
        // New pane becomes active
        #expect(manager.activePaneID != originalID)
        // New pane has its own TabManager
        #expect(manager.activeTabManager != nil)
        #expect(manager.activeTabManager !== originalTabManager)
    }

    @Test func splitPane_verticalAxis() {
        let manager = PaneManager()
        let originalID = manager.activePaneID

        manager.splitPane(originalID, axis: .vertical)

        #expect(manager.paneCount == 2)
        if case .split(let axis, _, _, _) = manager.rootNode {
            #expect(axis == .vertical)
        } else {
            Issue.record("Expected split node")
        }
    }

    @Test func splitPane_withTerminalContent() {
        let manager = PaneManager()
        let originalID = manager.activePaneID

        manager.splitPane(originalID, axis: .horizontal, content: .terminal)

        #expect(manager.paneCount == 2)
        let newID = manager.activePaneID
        #expect(manager.rootNode.content(for: newID) == .terminal)
    }

    @Test func splitPane_atMaxDepth_isNoOp() {
        let manager = PaneManager()

        // Split repeatedly to reach max depth
        for _ in 0..<(paneMaxDepth - 1) {
            let activeID = manager.activePaneID
            manager.splitPane(activeID, axis: .horizontal)
        }

        let countBefore = manager.paneCount
        let activeBefore = manager.activePaneID

        // This split should be a no-op (max depth reached)
        manager.splitPane(activeBefore, axis: .horizontal)

        #expect(manager.paneCount == countBefore)
        #expect(manager.activePaneID == activeBefore)
    }

    @Test func splitPane_unknownPaneID_isNoOp() {
        let manager = PaneManager()
        let bogusID = PaneID()

        manager.splitPane(bogusID, axis: .horizontal)

        #expect(manager.paneCount == 1)
    }

    // MARK: - Close

    @Test func closePane_lastPane_isNoOp() {
        let manager = PaneManager()
        let onlyID = manager.activePaneID

        manager.closePane(onlyID)

        #expect(manager.paneCount == 1)
        #expect(manager.activePaneID == onlyID)
        #expect(manager.tabManagers[onlyID] != nil)
    }

    @Test func closePane_removesPaneAndTabManager() {
        let manager = PaneManager()
        let firstID = manager.activePaneID
        manager.splitPane(firstID, axis: .horizontal)
        let secondID = manager.activePaneID

        #expect(manager.paneCount == 2)

        manager.closePane(secondID)

        #expect(manager.paneCount == 1)
        #expect(manager.tabManagers[secondID] == nil)
        #expect(manager.tabManagers[firstID] != nil)
    }

    @Test func closePane_activePane_switchesFocusToRemaining() {
        let manager = PaneManager()
        let firstID = manager.activePaneID
        manager.splitPane(firstID, axis: .horizontal)
        let secondID = manager.activePaneID

        // secondID is active; close it
        manager.closePane(secondID)

        #expect(manager.activePaneID == firstID)
    }

    @Test func closePane_inactivePane_preservesFocus() {
        let manager = PaneManager()
        let firstID = manager.activePaneID
        manager.splitPane(firstID, axis: .horizontal)
        let secondID = manager.activePaneID

        // secondID is active; close the inactive firstID
        manager.closePane(firstID)

        #expect(manager.activePaneID == secondID)
    }

    @Test func closePane_unknownID_isNoOp() {
        let manager = PaneManager()
        let originalID = manager.activePaneID
        manager.splitPane(originalID, axis: .horizontal)

        let countBefore = manager.paneCount
        manager.closePane(PaneID())

        #expect(manager.paneCount == countBefore)
    }

    // MARK: - Focus

    @Test func focusPane_setsActivePane() {
        let manager = PaneManager()
        let firstID = manager.activePaneID
        manager.splitPane(firstID, axis: .horizontal)
        let secondID = manager.activePaneID

        manager.focusPane(firstID)
        #expect(manager.activePaneID == firstID)

        manager.focusPane(secondID)
        #expect(manager.activePaneID == secondID)
    }

    @Test func focusPane_unknownID_isNoOp() {
        let manager = PaneManager()
        let originalID = manager.activePaneID

        manager.focusPane(PaneID())

        #expect(manager.activePaneID == originalID)
    }

    @Test func focusNextPane_cyclesThroughLeaves() {
        let manager = PaneManager()
        let firstID = manager.activePaneID
        manager.splitPane(firstID, axis: .horizontal)
        let secondID = manager.activePaneID

        // Focus first, then cycle
        manager.focusPane(firstID)
        #expect(manager.activePaneID == firstID)

        manager.focusNextPane()
        #expect(manager.activePaneID == secondID)

        manager.focusNextPane()
        #expect(manager.activePaneID == firstID) // wraps around
    }

    @Test func focusPreviousPane_cyclesThroughLeaves() {
        let manager = PaneManager()
        let firstID = manager.activePaneID
        manager.splitPane(firstID, axis: .horizontal)
        let secondID = manager.activePaneID

        manager.focusPane(firstID)

        manager.focusPreviousPane()
        #expect(manager.activePaneID == secondID) // wraps around

        manager.focusPreviousPane()
        #expect(manager.activePaneID == firstID)
    }

    @Test func focusNextPane_singlePane_isNoOp() {
        let manager = PaneManager()
        let originalID = manager.activePaneID

        manager.focusNextPane()

        #expect(manager.activePaneID == originalID)
    }

    @Test func focusPreviousPane_singlePane_isNoOp() {
        let manager = PaneManager()
        let originalID = manager.activePaneID

        manager.focusPreviousPane()

        #expect(manager.activePaneID == originalID)
    }

    @Test func focusNextPane_threePanes_fullCycle() {
        let manager = PaneManager()
        let firstID = manager.activePaneID

        manager.splitPane(firstID, axis: .horizontal)
        let secondID = manager.activePaneID

        manager.splitPane(secondID, axis: .vertical)
        let thirdID = manager.activePaneID

        let leafIDs = manager.rootNode.leafIDs
        #expect(leafIDs.count == 3)

        // Start from first
        manager.focusPane(leafIDs[0])
        manager.focusNextPane()
        #expect(manager.activePaneID == leafIDs[1])
        manager.focusNextPane()
        #expect(manager.activePaneID == leafIDs[2])
        manager.focusNextPane()
        #expect(manager.activePaneID == leafIDs[0])
    }

    // MARK: - Resize

    @Test func resizePane_updatesRatio() {
        let manager = PaneManager()
        let firstID = manager.activePaneID
        manager.splitPane(firstID, axis: .horizontal)

        manager.resizePane(firstID, ratio: 0.7)

        if case .split(_, _, _, let ratio) = manager.rootNode {
            #expect(abs(ratio - 0.7) < 1e-6)
        } else {
            Issue.record("Expected split node")
        }
    }

    @Test func resizePane_clampedToMinimum() {
        let manager = PaneManager()
        let firstID = manager.activePaneID
        manager.splitPane(firstID, axis: .horizontal)

        manager.resizePane(firstID, ratio: 0.01)

        if case .split(_, _, _, let ratio) = manager.rootNode {
            #expect(abs(ratio - 0.1) < 1e-6)
        } else {
            Issue.record("Expected split node")
        }
    }

    @Test func resizePane_clampedToMaximum() {
        let manager = PaneManager()
        let firstID = manager.activePaneID
        manager.splitPane(firstID, axis: .horizontal)

        manager.resizePane(firstID, ratio: 0.99)

        if case .split(_, _, _, let ratio) = manager.rootNode {
            #expect(abs(ratio - 0.9) < 1e-6)
        } else {
            Issue.record("Expected split node")
        }
    }

    @Test func resizePane_unknownID_isNoOp() {
        let manager = PaneManager()
        let firstID = manager.activePaneID
        manager.splitPane(firstID, axis: .horizontal)

        let rootBefore = manager.rootNode
        manager.resizePane(PaneID(), ratio: 0.7)

        #expect(manager.rootNode == rootBefore)
    }

    @Test func resizePane_singlePane_isNoOp() {
        let manager = PaneManager()
        let id = manager.activePaneID

        manager.resizePane(id, ratio: 0.7)

        // Should still be a leaf (no split to resize)
        #expect(manager.paneCount == 1)
    }

    // MARK: - Open file

    @Test func openFile_opensInActivePane() throws {
        let manager = PaneManager()
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let fileURL = tmpDir.appendingPathComponent("test.swift")
        try "let x = 1".write(to: fileURL, atomically: true, encoding: .utf8)

        manager.openFile(fileURL)

        #expect(manager.activeTabManager?.tabs.count == 1)
        #expect(manager.activeTabManager?.activeTab?.url == fileURL)
    }

    @Test func openFile_opensInSpecificPane() throws {
        let manager = PaneManager()
        let firstID = manager.activePaneID
        manager.splitPane(firstID, axis: .horizontal)

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let fileURL = tmpDir.appendingPathComponent("test.swift")
        try "let x = 1".write(to: fileURL, atomically: true, encoding: .utf8)

        // Open in the first pane (not active)
        manager.openFile(fileURL, in: firstID)

        #expect(manager.tabManagers[firstID]?.tabs.count == 1)
        #expect(manager.tabManagers[firstID]?.activeTab?.url == fileURL)
        // Active pane should have no tabs
        #expect(manager.activeTabManager?.tabs.isEmpty == true)
    }

    @Test func openFile_unknownPaneID_isNoOp() throws {
        let manager = PaneManager()

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let fileURL = tmpDir.appendingPathComponent("test.swift")
        try "let x = 1".write(to: fileURL, atomically: true, encoding: .utf8)

        manager.openFile(fileURL, in: PaneID())

        #expect(manager.activeTabManager?.tabs.isEmpty == true)
    }

    // MARK: - TabManager lookup

    @Test func tabManager_forValidPaneID_returnsManager() {
        let manager = PaneManager()
        let id = manager.activePaneID

        let tm = manager.tabManager(for: id)
        #expect(tm != nil)
        #expect(tm === manager.activeTabManager)
    }

    @Test func tabManager_forInvalidPaneID_returnsNil() {
        let manager = PaneManager()

        let tm = manager.tabManager(for: PaneID())
        #expect(tm == nil)
    }

    // MARK: - Edge cases: split, close, split again

    @Test func splitCloseAndSplitAgain_producesUniqueIDs() {
        let manager = PaneManager()
        let firstID = manager.activePaneID

        // Split
        manager.splitPane(firstID, axis: .horizontal)
        let secondID = manager.activePaneID
        let allIDsAfterFirstSplit = manager.allPaneIDs

        // Close second
        manager.closePane(secondID)
        #expect(manager.paneCount == 1)

        // Split again
        manager.splitPane(firstID, axis: .vertical)
        let thirdID = manager.activePaneID
        let allIDsAfterSecondSplit = manager.allPaneIDs

        // Third ID should be new (not reusing secondID)
        #expect(thirdID != secondID)
        #expect(thirdID != firstID)
        #expect(allIDsAfterSecondSplit.count == 2)
        // All IDs across both splits should be unique
        #expect(!allIDsAfterFirstSplit.contains(thirdID))
    }

    @Test func multipleSplitsAndCloses_maintainsConsistency() {
        let manager = PaneManager()
        let id1 = manager.activePaneID

        // Split to create id2
        manager.splitPane(id1, axis: .horizontal)
        let id2 = manager.activePaneID

        // Split id2 to create id3
        manager.splitPane(id2, axis: .vertical)
        let id3 = manager.activePaneID

        #expect(manager.paneCount == 3)
        #expect(manager.tabManagers.count == 3)

        // Close middle pane
        manager.closePane(id2)

        #expect(manager.paneCount == 2)
        #expect(manager.tabManagers.count == 2)
        #expect(manager.tabManagers[id2] == nil)
        #expect(manager.tabManagers[id1] != nil)
        #expect(manager.tabManagers[id3] != nil)
    }

    @Test func closeAllButOne_leavesExactlyOnePane() {
        let manager = PaneManager()
        let firstID = manager.activePaneID

        // Create 4 panes total
        manager.splitPane(firstID, axis: .horizontal)
        let secondID = manager.activePaneID
        manager.splitPane(secondID, axis: .vertical)
        let thirdID = manager.activePaneID
        manager.splitPane(thirdID, axis: .horizontal)

        #expect(manager.paneCount == 4)

        // Close until one remains
        let allIDs = Array(manager.rootNode.leafIDs)
        for id in allIDs.dropFirst() {
            manager.closePane(id)
        }

        #expect(manager.paneCount == 1)
        #expect(manager.tabManagers.count == 1)

        // Last pane can't be closed
        let lastID = manager.activePaneID
        manager.closePane(lastID)
        #expect(manager.paneCount == 1)
    }

    // MARK: - AllPaneIDs consistency

    @Test func allPaneIDs_matchesTabManagerKeys() {
        let manager = PaneManager()
        let firstID = manager.activePaneID

        manager.splitPane(firstID, axis: .horizontal)
        manager.splitPane(manager.activePaneID, axis: .vertical)

        let paneIDs = manager.allPaneIDs
        let tmKeys = Set(manager.tabManagers.keys)

        #expect(paneIDs == tmKeys)
    }

    @Test func allPaneIDs_afterCloses_matchesTabManagerKeys() {
        let manager = PaneManager()
        let firstID = manager.activePaneID

        manager.splitPane(firstID, axis: .horizontal)
        let secondID = manager.activePaneID
        manager.splitPane(secondID, axis: .vertical)

        manager.closePane(secondID)

        let paneIDs = manager.allPaneIDs
        let tmKeys = Set(manager.tabManagers.keys)

        #expect(paneIDs == tmKeys)
    }

    // MARK: - Focus after close

    @Test func closingActivePane_focusesFirstLeaf() {
        let manager = PaneManager()
        let firstID = manager.activePaneID

        manager.splitPane(firstID, axis: .horizontal)
        let secondID = manager.activePaneID

        // Second is active, close it
        manager.closePane(secondID)

        // Should focus firstID (the only remaining leaf)
        #expect(manager.activePaneID == firstID)
        #expect(manager.activeTabManager === manager.tabManagers[firstID])
    }

    @Test func closingInactivePane_doesNotChangeFocus() {
        let manager = PaneManager()
        let firstID = manager.activePaneID

        manager.splitPane(firstID, axis: .horizontal)
        let secondID = manager.activePaneID
        manager.splitPane(secondID, axis: .vertical)
        let thirdID = manager.activePaneID

        // thirdID is active, close firstID
        manager.closePane(firstID)

        #expect(manager.activePaneID == thirdID)
    }
}

// swiftlint:enable type_body_length file_length
