//
//  PaneManagerTests.swift
//  PineTests
//

import Testing
import Foundation
@testable import Pine

@Suite("PaneManager Tests")
@MainActor
struct PaneManagerTests {

    // MARK: - Initialization

    @Test func init_createsOnePaneWithTabManager() {
        let manager = PaneManager()
        #expect(manager.root.leafCount == 1)
        #expect(manager.activeTabManager != nil)
        #expect(manager.tabManagers.count == 1)
    }

    @Test func initWithExistingTabManager_preservesTabManager() {
        let existingTM = TabManager()
        let testURL = URL(fileURLWithPath: "/tmp/test.swift")
        existingTM.openTab(url: testURL)
        let manager = PaneManager(existingTabManager: existingTM)
        #expect(manager.activeTabManager === existingTM)
        #expect(manager.activeTabManager?.tabs.count == 1)
    }

    // MARK: - Split operations

    @Test func splitPane_horizontal_createsNewPane() {
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

    @Test func splitPane_vertical_createsNewPane() {
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

    @Test func splitPane_newPaneHasOwnTabManager() {
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

    @Test func splitPane_invalidTarget_returnsNil() {
        let manager = PaneManager()
        let fakePaneID = PaneID()

        let result = manager.splitPane(fakePaneID, axis: .horizontal)
        #expect(result == nil)
        #expect(manager.root.leafCount == 1)
    }

    @Test func multipleSplits_createDeepTree() {
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

    @Test func removePane_collapsesTree() {
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

    @Test func removePane_singlePane_doesNothing() {
        let manager = PaneManager()
        let onlyPane = manager.activePaneID

        manager.removePane(onlyPane)
        #expect(manager.root.leafCount == 1)
        #expect(manager.tabManagers.count == 1)
    }

    @Test func removeActivePane_switchesToRemainingPane() {
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

    @Test func moveTabBetweenPanes_movesTab() {
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

    @Test func moveTabBetweenPanes_emptySource_removesPane() {
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

    @Test func updateRatio_changesTreeRatio() {
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

    @Test func updateRatio_clampsToRange() {
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

    @Test func tabManager_forInvalidPaneID_returnsNil() {
        let manager = PaneManager()
        let fakePaneID = PaneID()
        #expect(manager.tabManager(for: fakePaneID) == nil)
    }

    @Test func activeTabManager_matchesActivePaneID() {
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

    @Test func splitPane_withTabURL_movesTabToNewPane() {
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

    // MARK: - Focus cycle

    @Test func focusCycle_threePanes_cyclesThroughAll() {
        let manager = PaneManager()
        let firstPane = manager.activePaneID

        guard let secondPane = manager.splitPane(firstPane, axis: .horizontal) else {
            Issue.record("Split failed")
            return
        }
        guard let thirdPane = manager.splitPane(secondPane, axis: .vertical) else {
            Issue.record("Split failed")
            return
        }

        #expect(manager.activePaneID == thirdPane)

        let allLeafIDs = manager.root.leafIDs
        #expect(allLeafIDs.count == 3)
        #expect(allLeafIDs.contains(firstPane))
        #expect(allLeafIDs.contains(secondPane))
        #expect(allLeafIDs.contains(thirdPane))

        for paneID in allLeafIDs {
            manager.activePaneID = paneID
            #expect(manager.activePaneID == paneID)
            #expect(manager.activeTabManager === manager.tabManager(for: paneID))
        }
    }

    // MARK: - updateSplitRatio

    @Test func updateSplitRatio_changesParentOfNestedPane() {
        let manager = PaneManager()
        let firstPane = manager.activePaneID

        guard let secondPane = manager.splitPane(firstPane, axis: .horizontal) else {
            Issue.record("Split failed")
            return
        }
        guard let thirdPane = manager.splitPane(secondPane, axis: .vertical) else {
            Issue.record("Split failed")
            return
        }

        manager.updateSplitRatio(containing: thirdPane, ratio: 0.3)
        #expect(manager.root.leafCount == 3)
        #expect(manager.tabManagers.count == 3)
    }

    // MARK: - Move tab edge cases

    @Test func moveTabBetweenPanes_invalidSourcePane_doesNothing() {
        let manager = PaneManager()
        let firstPane = manager.activePaneID
        let testURL = URL(fileURLWithPath: "/tmp/test.swift")
        manager.tabManager(for: firstPane)?.openTab(url: testURL)

        guard let secondPane = manager.splitPane(firstPane, axis: .horizontal) else {
            Issue.record("Split failed")
            return
        }

        let fakePaneID = PaneID()
        manager.moveTabBetweenPanes(tabURL: testURL, from: fakePaneID, to: secondPane)
        #expect(manager.tabManager(for: firstPane)?.tabs.count == 1)
    }

    @Test func moveTabBetweenPanes_nonExistentTab_doesNothing() {
        let manager = PaneManager()
        let firstPane = manager.activePaneID
        let testURL = URL(fileURLWithPath: "/tmp/test.swift")
        let ghostURL = URL(fileURLWithPath: "/tmp/ghost.swift")
        manager.tabManager(for: firstPane)?.openTab(url: testURL)

        guard let secondPane = manager.splitPane(firstPane, axis: .horizontal) else {
            Issue.record("Split failed")
            return
        }

        manager.moveTabBetweenPanes(tabURL: ghostURL, from: firstPane, to: secondPane)
        // Source pane retains its tab — ghost URL was a no-op move.
        #expect(manager.tabManager(for: firstPane)?.tabs.count == 1)
        // The empty destination pane is now collapsed by `pruneEmptyEditorLeaves`,
        // since `firstPane` still holds a tab and the invariant (≥1 editor leaf
        // in the tree) is preserved.
        #expect(manager.tabManager(for: secondPane) == nil)
        #expect(manager.root.leafCount == 1)
    }

    @Test func moveTabBetweenPanes_preservesAllTabState() {
        let manager = PaneManager()
        let firstPane = manager.activePaneID
        let testURL = URL(fileURLWithPath: "/tmp/test.swift")
        manager.tabManager(for: firstPane)?.openTab(url: testURL)

        let testContent = "func hello() { print(\"world\") }"
        manager.tabManager(for: firstPane)?.updateContent(testContent)

        // Set various tab state properties
        if let srcTM = manager.tabManager(for: firstPane),
           let idx = srcTM.tabs.firstIndex(where: { $0.url == testURL }) {
            srcTM.tabs[idx].cursorPosition = 42
            srcTM.tabs[idx].scrollOffset = 123.5
            srcTM.tabs[idx].cursorLine = 3
            srcTM.tabs[idx].cursorColumn = 7
            srcTM.tabs[idx].isPinned = true
            srcTM.tabs[idx].foldState.toggle(FoldableRange(startLine: 1, endLine: 5, startCharIndex: 0, endCharIndex: 10, kind: .braces))
            srcTM.tabs[idx].syntaxHighlightingDisabled = true
            srcTM.tabs[idx].encoding = .utf16
        }

        let anotherURL = URL(fileURLWithPath: "/tmp/another.swift")
        manager.tabManager(for: firstPane)?.openTab(url: anotherURL)

        guard let secondPane = manager.splitPane(firstPane, axis: .horizontal) else {
            Issue.record("Split failed")
            return
        }

        manager.moveTabBetweenPanes(tabURL: testURL, from: firstPane, to: secondPane)
        let destTab = manager.tabManager(for: secondPane)?.tabs.first(where: { $0.url == testURL })
        #expect(destTab != nil)
        #expect(destTab?.content == testContent)
        #expect(destTab?.cursorPosition == 42)
        #expect(destTab?.scrollOffset == 123.5)
        #expect(destTab?.cursorLine == 3)
        #expect(destTab?.cursorColumn == 7)
        #expect(destTab?.isPinned == true)
        #expect(destTab?.foldState.isLineHidden(2) == true)
        #expect(destTab?.syntaxHighlightingDisabled == true)
        #expect(destTab?.encoding == .utf16)
    }

    // MARK: - Remove pane edge cases

    @Test func removePane_fromThreePanes_keepsTwo() {
        let manager = PaneManager()
        let firstPane = manager.activePaneID

        guard let secondPane = manager.splitPane(firstPane, axis: .horizontal) else {
            Issue.record("Split failed")
            return
        }
        guard let thirdPane = manager.splitPane(secondPane, axis: .vertical) else {
            Issue.record("Split failed")
            return
        }

        manager.removePane(secondPane)
        #expect(manager.root.leafCount == 2)
        #expect(manager.tabManagers[secondPane] == nil)
        #expect(manager.tabManagers[firstPane] != nil)
        #expect(manager.tabManagers[thirdPane] != nil)
    }

    @Test func removePane_invalidPaneID_doesNothing() {
        let manager = PaneManager()
        let firstPane = manager.activePaneID
        _ = manager.splitPane(firstPane, axis: .horizontal)

        let fakePaneID = PaneID()
        manager.removePane(fakePaneID)
        #expect(manager.root.leafCount == 2)
    }

    // MARK: - Split with nil tabURL

    @Test func splitPane_withNilTabURL_createsEmptyPane() {
        let manager = PaneManager()
        let firstPane = manager.activePaneID
        manager.tabManager(for: firstPane)?.openTab(url: URL(fileURLWithPath: "/tmp/test.swift"))

        let newID = manager.splitPane(firstPane, axis: .horizontal, tabURL: nil, sourcePane: nil)
        guard let newID else {
            Issue.record("Split failed")
            return
        }

        #expect(manager.tabManager(for: newID)?.tabs.isEmpty == true)
        #expect(manager.tabManager(for: firstPane)?.tabs.count == 1)
    }

    // MARK: - Multiple rapid splits

    @Test func rapidSplits_allPanesHaveTabManagers() {
        let manager = PaneManager()
        var lastPaneID = manager.activePaneID

        for idx in 0..<5 {
            let axis: SplitAxis = idx % 2 == 0 ? .horizontal : .vertical
            guard let newID = manager.splitPane(lastPaneID, axis: axis) else {
                Issue.record("Split \(idx) failed")
                return
            }
            lastPaneID = newID
        }

        #expect(manager.root.leafCount == 6)
        #expect(manager.tabManagers.count == 6)

        for leafID in manager.root.leafIDs {
            #expect(manager.tabManager(for: leafID) != nil)
        }
    }

    // MARK: - updateRatio edge cases

    @Test func updateRatio_onSinglePane_noChange() {
        let manager = PaneManager()
        let onlyPane = manager.activePaneID
        manager.updateRatio(for: onlyPane, ratio: 0.7)
        #expect(manager.root.leafCount == 1)
    }

    // MARK: - Terminal pane operations

    @Test func createTerminalPane_splitsBelowEditor() {
        let manager = PaneManager()
        let editorPane = manager.activePaneID
        let terminalPaneID = manager.createTerminalPane(
            relativeTo: editorPane, axis: .vertical, workingDirectory: nil
        )
        guard let tpID = terminalPaneID else {
            Issue.record("createTerminalPane returned nil")
            return
        }
        #expect(manager.root.leafCount == 2)
        #expect(manager.root.content(for: tpID) == .terminal)
        #expect(manager.terminalStates[tpID] != nil)
    }

    @Test func createTerminalPane_hasOneTab() {
        let manager = PaneManager()
        let editorPane = manager.activePaneID
        guard let terminalPaneID = manager.createTerminalPane(
            relativeTo: editorPane, axis: .vertical, workingDirectory: nil
        ) else {
            Issue.record("createTerminalPane failed")
            return
        }
        #expect(manager.terminalState(for: terminalPaneID)?.tabCount == 1)
    }

    @Test func removeTerminalPane_cleansUpState() {
        let manager = PaneManager()
        let editorPane = manager.activePaneID
        guard let terminalPaneID = manager.createTerminalPane(
            relativeTo: editorPane, axis: .vertical, workingDirectory: nil
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
        _ = manager.createTerminalPane(relativeTo: editorPane, axis: .vertical, workingDirectory: nil)
        #expect(manager.terminalPaneIDs.count == 1)
        #expect(manager.root.leafCount == 2)
    }

    @Test func allTerminalTabs_collectsFromAllPanes() {
        let manager = PaneManager()
        let editorPane = manager.activePaneID
        guard let tp1 = manager.createTerminalPane(
            relativeTo: editorPane, axis: .vertical, workingDirectory: nil
        ) else {
            Issue.record("failed")
            return
        }
        _ = manager.createTerminalPane(relativeTo: tp1, axis: .horizontal, workingDirectory: nil)
        #expect(manager.allTerminalTabs.count == 2)
    }

    @Test func maximize_hidesOtherPanes() {
        let manager = PaneManager()
        let editorPane = manager.activePaneID
        guard let terminalPane = manager.createTerminalPane(
            relativeTo: editorPane, axis: .vertical, workingDirectory: nil
        ) else {
            Issue.record("failed")
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
            Issue.record("failed")
            return
        }
        manager.maximize(paneID: terminalPane)
        manager.restoreFromMaximize()
        #expect(!manager.isMaximized)
        #expect(manager.root.leafCount == 2)
    }

    @Test func persistableRoot_returnsFullLayoutDuringMaximize() {
        let manager = PaneManager()
        let editorPane = manager.activePaneID
        guard let terminalPane = manager.createTerminalPane(
            relativeTo: editorPane, axis: .vertical, workingDirectory: nil
        ) else {
            Issue.record("failed")
            return
        }
        #expect(manager.persistableRoot.leafCount == 2)

        manager.maximize(paneID: terminalPane)
        // root is single leaf, but persistableRoot returns full layout
        #expect(manager.root.leafCount == 1)
        #expect(manager.persistableRoot.leafCount == 2)
        #expect(manager.persistableRoot.contains(editorPane))
        #expect(manager.persistableRoot.contains(terminalPane))
    }

    @Test func persistableRoot_equalsRootWhenNotMaximized() {
        let manager = PaneManager()
        #expect(manager.persistableRoot == manager.root)

        let editorPane = manager.activePaneID
        _ = manager.createTerminalPane(
            relativeTo: editorPane, axis: .vertical, workingDirectory: nil
        )
        #expect(manager.persistableRoot == manager.root)
    }

    @Test func maximize_alreadyMaximized_doesNothing() {
        let manager = PaneManager()
        let editorPane = manager.activePaneID
        guard let terminalPane = manager.createTerminalPane(
            relativeTo: editorPane, axis: .vertical, workingDirectory: nil
        ) else {
            Issue.record("failed")
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
            Issue.record("failed")
            return
        }
        guard let state1 = manager.terminalState(for: tp1) else {
            Issue.record("terminalState not found")
            return
        }
        _ = state1.addTab(workingDirectory: nil)
        #expect(state1.tabCount == 2)
        guard let tp2 = manager.createTerminalPane(
            relativeTo: tp1, axis: .horizontal, workingDirectory: nil
        ) else {
            Issue.record("failed")
            return
        }
        guard let tabToMove = state1.terminalTabs.first else {
            Issue.record("no tabs")
            return
        }
        manager.moveTerminalTab(tabToMove.id, from: tp1, to: tp2)
        #expect(manager.terminalState(for: tp1)?.tabCount == 1)
        #expect(manager.terminalState(for: tp2)?.tabCount == 2)
    }

    // MARK: - Last editor pane protection

    @Test func removePane_lastEditorPane_isRemovedLeavingTerminalsOnly() {
        let manager = PaneManager()
        let editorPane = manager.activePaneID
        let testURL = URL(fileURLWithPath: "/tmp/test.swift")
        manager.tabManager(for: editorPane)?.openTab(url: testURL)

        // Add a terminal pane so there are 2 leaves total
        guard let terminalPane = manager.createTerminalPane(
            relativeTo: editorPane, axis: .vertical, workingDirectory: nil
        ) else {
            Issue.record("createTerminalPane failed")
            return
        }
        #expect(manager.root.leafCount == 2)

        // Removing the only editor pane is now allowed: layout becomes
        // terminals-only and a new editor can be created on demand via
        // `ensureEditorPane()` when the user opens a file again.
        manager.removePane(editorPane)

        #expect(manager.root.leafCount == 1)
        #expect(manager.root.leafCount(ofType: .editor) == 0)
        #expect(manager.tabManagers[editorPane] == nil)
        #expect(manager.root.firstLeafID == terminalPane)
    }

    @Test func removePane_nonLastEditorPane_removesNormally() {
        let manager = PaneManager()
        let firstEditor = manager.activePaneID

        // Create a second editor pane
        guard let secondEditor = manager.splitPane(firstEditor, axis: .horizontal) else {
            Issue.record("Split failed")
            return
        }
        #expect(manager.root.leafCount(ofType: .editor) == 2)

        // Removing one of two editor panes should work normally
        manager.removePane(secondEditor)
        #expect(manager.root.leafCount == 1)
        #expect(manager.tabManagers[secondEditor] == nil)
    }

    @Test func removePane_terminalPane_whenOnlyOneEditor_removesTerminal() {
        let manager = PaneManager()
        let editorPane = manager.activePaneID

        guard let terminalPane = manager.createTerminalPane(
            relativeTo: editorPane, axis: .vertical, workingDirectory: nil
        ) else {
            Issue.record("createTerminalPane failed")
            return
        }

        // Removing terminal pane should work even if only 1 editor pane remains
        manager.removePane(terminalPane)
        #expect(manager.root.leafCount == 1)
        #expect(manager.root.content(for: editorPane) == .editor)
        #expect(manager.terminalStates[terminalPane] == nil)
    }

    @Test func moveTabBetweenPanes_lastTabInLastEditorPane_keepsPane() {
        let manager = PaneManager()
        let editorPane = manager.activePaneID
        let testURL = URL(fileURLWithPath: "/tmp/test.swift")
        manager.tabManager(for: editorPane)?.openTab(url: testURL)

        // Add terminal pane
        guard let terminalPane = manager.createTerminalPane(
            relativeTo: editorPane, axis: .vertical, workingDirectory: nil
        ) else {
            Issue.record("createTerminalPane failed")
            return
        }

        // Create a second editor pane via split and move the tab there
        guard let secondEditor = manager.splitPane(editorPane, axis: .horizontal) else {
            Issue.record("Split failed")
            return
        }

        // Now move the only tab from editorPane to secondEditor
        // This should try to removePane(editorPane) because it becomes empty,
        // but since that would leave secondEditor as the only editor, it works fine
        // (there are 2 editor panes, so removing one is OK)
        manager.moveTabBetweenPanes(tabURL: testURL, from: editorPane, to: secondEditor)
        #expect(manager.tabManager(for: secondEditor)?.tabs.count == 1)
    }

    @Test func leafCountOfType_countsCorrectly() {
        let manager = PaneManager()
        let editorPane = manager.activePaneID
        #expect(manager.root.leafCount(ofType: .editor) == 1)
        #expect(manager.root.leafCount(ofType: .terminal) == 0)

        _ = manager.createTerminalPane(
            relativeTo: editorPane, axis: .vertical, workingDirectory: nil
        )
        #expect(manager.root.leafCount(ofType: .editor) == 1)
        #expect(manager.root.leafCount(ofType: .terminal) == 1)

        _ = manager.splitPane(editorPane, axis: .horizontal)
        #expect(manager.root.leafCount(ofType: .editor) == 2)
        #expect(manager.root.leafCount(ofType: .terminal) == 1)
    }

    @Test func removePane_lastEditorWithMultipleTerminals_isRemoved() {
        let manager = PaneManager()
        let editorPane = manager.activePaneID

        // Create two terminal panes
        guard let tp1 = manager.createTerminalPane(
            relativeTo: editorPane, axis: .vertical, workingDirectory: nil
        ) else {
            Issue.record("failed")
            return
        }
        _ = manager.createTerminalPane(
            relativeTo: tp1, axis: .horizontal, workingDirectory: nil
        )

        #expect(manager.root.leafCount == 3)
        #expect(manager.root.leafCount(ofType: .editor) == 1)
        #expect(manager.root.leafCount(ofType: .terminal) == 2)

        // Removing the only editor pane is now allowed; the layout becomes
        // terminals-only.
        manager.removePane(editorPane)
        #expect(manager.root.leafCount == 2)
        #expect(manager.root.leafCount(ofType: .editor) == 0)
        #expect(manager.root.leafCount(ofType: .terminal) == 2)
        #expect(manager.tabManagers[editorPane] == nil)
    }
}
