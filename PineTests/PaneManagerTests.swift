//
//  PaneManagerTests.swift
//  PineTests
//

import Testing
import Foundation
@testable import Pine

@Suite("PaneManager Tests")
struct PaneManagerTests {

    // MARK: - Initialization

    @MainActor @Test func init_createsOnePaneWithTabManager() {
        let manager = PaneManager()
        #expect(manager.root.leafCount == 1)
        #expect(manager.activeTabManager != nil)
        #expect(manager.tabManagers.count == 1)
    }

    @MainActor @Test func initWithExistingTabManager_preservesTabManager() {
        let existingTM = TabManager()
        let testURL = URL(fileURLWithPath: "/tmp/test.swift")
        existingTM.openTab(url: testURL)
        let manager = PaneManager(existingTabManager: existingTM)
        #expect(manager.activeTabManager === existingTM)
        #expect(manager.activeTabManager?.tabs.count == 1)
    }

    // MARK: - Split operations

    @MainActor @Test func splitPane_horizontal_createsNewPane() {
        let manager = PaneManager()
        let originalPaneID = manager.activePaneID

        let newID = manager.splitPane(originalPaneID, axis: .horizontal)
        #expect(newID != nil)
        #expect(manager.root.leafCount == 2)
        #expect(manager.tabManagers.count == 2)
        if let newID {
            #expect(manager.activePaneID == newID)
        }
    }

    @MainActor @Test func splitPane_vertical_createsNewPane() {
        let manager = PaneManager()
        let originalPaneID = manager.activePaneID

        let newID = manager.splitPane(originalPaneID, axis: .vertical)
        #expect(newID != nil)
        #expect(manager.root.leafCount == 2)
        #expect(manager.tabManagers.count == 2)
        // Verify tree structure
        if case .split(let axis, _, _, _) = manager.root {
            #expect(axis == .vertical)
        } else {
            Issue.record("Expected split node")
        }
    }

    @MainActor @Test func splitPane_newPaneHasOwnTabManager() {
        let manager = PaneManager()
        let originalPaneID = manager.activePaneID
        let originalTM = manager.tabManager(for: originalPaneID)

        let newID = manager.splitPane(originalPaneID, axis: .horizontal)
        guard let newID else {
            Issue.record("Split returned nil")
            return
        }

        let newTM = manager.tabManager(for: newID)
        #expect(newTM != nil)
        #expect(newTM !== originalTM)
    }

    @MainActor @Test func splitPane_invalidTarget_returnsNil() {
        let manager = PaneManager()
        let fakePaneID = PaneID()

        let result = manager.splitPane(fakePaneID, axis: .horizontal)
        #expect(result == nil)
        #expect(manager.root.leafCount == 1)
    }

    @MainActor @Test func multipleSplits_createDeepTree() {
        let manager = PaneManager()
        let firstPane = manager.activePaneID

        let secondPaneID = manager.splitPane(firstPane, axis: .horizontal)
        guard let secondPaneID else {
            Issue.record("Split failed")
            return
        }

        let thirdPaneID = manager.splitPane(secondPaneID, axis: .vertical)
        #expect(thirdPaneID != nil)
        #expect(manager.root.leafCount == 3)
        #expect(manager.tabManagers.count == 3)
    }

    // MARK: - Remove pane

    @MainActor @Test func removePane_collapsesTree() {
        let manager = PaneManager()
        let firstPane = manager.activePaneID

        guard let secondPaneID = manager.splitPane(firstPane, axis: .horizontal) else {
            Issue.record("Split failed")
            return
        }

        manager.removePane(secondPaneID)
        #expect(manager.root.leafCount == 1)
        #expect(manager.tabManagers[secondPaneID] == nil)
        #expect(manager.activePaneID == firstPane)
    }

    @MainActor @Test func removePane_singlePane_doesNothing() {
        let manager = PaneManager()
        let onlyPane = manager.activePaneID

        manager.removePane(onlyPane)
        #expect(manager.root.leafCount == 1)
        #expect(manager.tabManagers.count == 1)
    }

    @MainActor @Test func removeActivePane_switchesToRemainingPane() {
        let manager = PaneManager()
        let firstPane = manager.activePaneID

        guard let secondPaneID = manager.splitPane(firstPane, axis: .horizontal) else {
            Issue.record("Split failed")
            return
        }

        // Active pane is the second (newly created)
        #expect(manager.activePaneID == secondPaneID)

        manager.removePane(secondPaneID)
        #expect(manager.activePaneID == firstPane)
    }

    // MARK: - Tab movement

    @MainActor @Test func moveTabBetweenPanes_movesTab() {
        let manager = PaneManager()
        let firstPane = manager.activePaneID

        // Add a tab to the first pane
        let testURL = URL(fileURLWithPath: "/tmp/test.swift")
        let anotherURL = URL(fileURLWithPath: "/tmp/another.swift")
        manager.tabManager(for: firstPane)?.openTab(url: testURL)
        manager.tabManager(for: firstPane)?.openTab(url: anotherURL)

        guard let secondPaneID = manager.splitPane(firstPane, axis: .horizontal) else {
            Issue.record("Split failed")
            return
        }

        // Move one tab from first to second
        manager.moveTabBetweenPanes(tabURL: testURL, from: firstPane, to: secondPaneID)

        let firstTabs = manager.tabManager(for: firstPane)?.tabs ?? []
        let secondTabs = manager.tabManager(for: secondPaneID)?.tabs ?? []

        #expect(firstTabs.count == 1)
        #expect(firstTabs.first?.url == anotherURL)
        #expect(secondTabs.count == 1)
        #expect(secondTabs.first?.url == testURL)
    }

    @MainActor @Test func moveTabBetweenPanes_emptySource_removesPane() {
        let manager = PaneManager()
        let firstPane = manager.activePaneID

        let testURL = URL(fileURLWithPath: "/tmp/test.swift")
        manager.tabManager(for: firstPane)?.openTab(url: testURL)

        guard let secondPaneID = manager.splitPane(firstPane, axis: .horizontal) else {
            Issue.record("Split failed")
            return
        }

        // Move the only tab from first pane -> should remove first pane
        manager.moveTabBetweenPanes(tabURL: testURL, from: firstPane, to: secondPaneID)

        // First pane should be removed since it's now empty
        #expect(manager.root.leafCount == 1)
        #expect(manager.tabManagers[firstPane] == nil)
    }

    // MARK: - Ratio updates

    @MainActor @Test func updateRatio_changesTreeRatio() {
        let manager = PaneManager()
        let firstPane = manager.activePaneID

        guard let secondPaneID = manager.splitPane(firstPane, axis: .horizontal) else {
            Issue.record("Split failed")
            return
        }

        manager.updateRatio(for: secondPaneID, ratio: 0.7)

        if case .split(_, _, _, let ratio) = manager.root {
            #expect(abs(ratio - 0.7) < 0.001)
        } else {
            Issue.record("Expected split node")
        }
    }

    @MainActor @Test func updateRatio_clampsToRange() {
        let manager = PaneManager()
        let firstPane = manager.activePaneID

        guard let secondPaneID = manager.splitPane(firstPane, axis: .horizontal) else {
            Issue.record("Split failed")
            return
        }

        manager.updateRatio(for: secondPaneID, ratio: 0.05)

        if case .split(_, _, _, let ratio) = manager.root {
            #expect(ratio >= 0.1)
        } else {
            Issue.record("Expected split node")
        }
    }

    // MARK: - Tab manager lookup

    @MainActor @Test func tabManager_forInvalidPaneID_returnsNil() {
        let manager = PaneManager()
        let fakePaneID = PaneID()
        #expect(manager.tabManager(for: fakePaneID) == nil)
    }

    @MainActor @Test func activeTabManager_matchesActivePaneID() {
        let manager = PaneManager()
        let firstPane = manager.activePaneID

        guard let secondPaneID = manager.splitPane(firstPane, axis: .horizontal) else {
            Issue.record("Split failed")
            return
        }

        #expect(manager.activeTabManager === manager.tabManager(for: secondPaneID))

        manager.activePaneID = firstPane
        #expect(manager.activeTabManager === manager.tabManager(for: firstPane))
    }

    // MARK: - Split with tab movement

    @MainActor @Test func splitPane_withTabURL_movesTabToNewPane() {
        let manager = PaneManager()
        let firstPane = manager.activePaneID

        let url1 = URL(fileURLWithPath: "/tmp/a.swift")
        let url2 = URL(fileURLWithPath: "/tmp/b.swift")
        manager.tabManager(for: firstPane)?.openTab(url: url1)
        manager.tabManager(for: firstPane)?.openTab(url: url2)

        let newID = manager.splitPane(
            firstPane,
            axis: .horizontal,
            tabURL: url2,
            sourcePane: firstPane
        )
        guard let newID else {
            Issue.record("Split failed")
            return
        }

        let firstTabs = manager.tabManager(for: firstPane)?.tabs ?? []
        let newTabs = manager.tabManager(for: newID)?.tabs ?? []

        #expect(firstTabs.count == 1)
        #expect(firstTabs.first?.url == url1)
        #expect(newTabs.count == 1)
        #expect(newTabs.first?.url == url2)
    }
}
