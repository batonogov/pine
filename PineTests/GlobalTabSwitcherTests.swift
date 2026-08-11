//
//  GlobalTabSwitcherTests.swift
//  PineTests
//
//  Tests for the all-pane MRU tab switcher (issue #1168). The switcher cycles
//  through tabs across ALL panes in most-recently-used order, independent of
//  each pane's local active-tab selection. Closed/stale identities are excluded.
//

import Foundation
import Testing

@testable import Pine

@Suite("Global Tab Switcher Tests")
@MainActor
struct GlobalTabSwitcherTests {

    // MARK: - Helpers

    /// A fully-resolved two-editor-pane setup so tests never force-unwrap.
    private struct TwoPaneSetup {
        let manager: PaneManager
        let leftPane: PaneID
        let rightPane: PaneID
        let leftTM: TabManager
        let rightTM: TabManager
    }

    /// Creates a PaneManager with two editor panes side by side, each with the
    /// given number of tabs. Returns non-optional references for every pane/tab.
    private func makeTwoEditorPaneManager(leftCount: Int, rightCount: Int) -> TwoPaneSetup {
        let pm = PaneManager()
        let leftPane = pm.activePaneID
        guard let leftTM = pm.tabManager(for: leftPane),
              let rightPane = pm.splitPane(leftPane, axis: .horizontal),
              let rightTM = pm.tabManager(for: rightPane) else {
            fatalError("Test setup failed: could not create two-pane layout")
        }
        for i in 0..<leftCount {
            leftTM.tabs.append(EditorTab(
                url: URL(fileURLWithPath: "/tmp/left\(i).swift"),
                content: "// left \(i)", savedContent: "// left \(i)"
            ))
        }
        if leftCount > 0 { leftTM.activeTabID = leftTM.tabs[0].id }

        for i in 0..<rightCount {
            rightTM.tabs.append(EditorTab(
                url: URL(fileURLWithPath: "/tmp/right\(i).swift"),
                content: "// right \(i)", savedContent: "// right \(i)"
            ))
        }
        if rightCount > 0 { rightTM.activeTabID = rightTM.tabs[0].id }

        return TwoPaneSetup(
            manager: pm, leftPane: leftPane, rightPane: rightPane,
            leftTM: leftTM, rightTM: rightTM
        )
    }

    // MARK: - Recording and order

    @Test("recordTabActivation moves the most recent to the front")
    func recordMovesToFront() {
        let s = makeTwoEditorPaneManager(leftCount: 2, rightCount: 2)

        s.manager.selectEditorTab(s.leftTM.tabs[1].id, in: s.leftPane)
        s.manager.selectEditorTab(s.leftTM.tabs[0].id, in: s.leftPane)

        let order = s.manager.globalTabSwitchOrder
        #expect(order.first?.tabID == s.leftTM.tabs[0].id)
    }

    @Test("recordTabActivation deduplicates identities")
    func recordDeduplicates() {
        let s = makeTwoEditorPaneManager(leftCount: 1, rightCount: 1)
        let tabID = s.leftTM.tabs[0].id

        s.manager.recordTabActivation(paneID: s.leftPane, tabID: tabID, contentType: .editor)
        s.manager.recordTabActivation(paneID: s.leftPane, tabID: tabID, contentType: .editor)

        let count = s.manager.globalTabSwitchOrder.filter { $0.tabID == tabID }.count
        #expect(count == 1)
    }

    @Test("Direct TabManager activations are tracked by their owning pane")
    func directEditorActivationIsTracked() throws {
        let pm = PaneManager()
        let paneID = pm.activePaneID
        let tabManager = try #require(pm.tabManager(for: paneID))
        let url = URL(fileURLWithPath: "/tmp/global-mru-direct.swift")

        tabManager.openTab(url: url)

        #expect(pm.globalTabSwitchOrder.first?.paneID == paneID)
        #expect(pm.globalTabSwitchOrder.first?.tabID == tabManager.activeTabID)
        #expect(pm.globalTabSwitchOrder.first?.contentType == .editor)
    }

    // MARK: - Separation from per-pane active history

    @Test("Global switch order is separate from per-pane active tab")
    func globalOrderSeparateFromPerPaneActive() {
        let s = makeTwoEditorPaneManager(leftCount: 3, rightCount: 1)

        // Build a known global order spanning both panes.
        s.manager.selectEditorTab(s.rightTM.tabs[0].id, in: s.rightPane)
        s.manager.selectEditorTab(s.leftTM.tabs[2].id, in: s.leftPane)
        s.manager.selectEditorTab(s.leftTM.tabs[0].id, in: s.leftPane)
        // 3 activated tabs (left[1] was never activated so it is absent).

        let order = s.manager.validGlobalTabSwitchOrder()
        #expect(order.count == 3)
        #expect(order.contains(where: { $0.paneID == s.rightPane }))
        #expect(order.contains(where: { $0.paneID == s.leftPane }))
    }

    // MARK: - Stale identity exclusion

    @Test("Closed tabs are excluded from the switch order")
    func closedTabsExcluded() {
        let s = makeTwoEditorPaneManager(leftCount: 2, rightCount: 1)

        // Activate all tabs so they appear in the global order.
        s.manager.selectEditorTab(s.rightTM.tabs[0].id, in: s.rightPane)
        s.manager.selectEditorTab(s.leftTM.tabs[0].id, in: s.leftPane)
        s.manager.selectEditorTab(s.leftTM.tabs[1].id, in: s.leftPane)
        let closedID = s.leftTM.tabs[1].id
        s.leftTM.closeTab(id: closedID)

        let order = s.manager.validGlobalTabSwitchOrder()
        #expect(order.count == 2) // left[0] + right[0]
        #expect(order.contains(where: { $0.tabID == closedID }) == false)
    }

    @Test("Removed panes are excluded from the switch order")
    func removedPanesExcluded() {
        let s = makeTwoEditorPaneManager(leftCount: 1, rightCount: 1)

        s.manager.selectEditorTab(s.leftTM.tabs[0].id, in: s.leftPane)
        s.manager.selectEditorTab(s.rightTM.tabs[0].id, in: s.rightPane)
        s.manager.removePane(s.rightPane)

        let order = s.manager.validGlobalTabSwitchOrder()
        #expect(order.allSatisfy { $0.paneID != s.rightPane })
        #expect(order.count == 1)
    }

    // MARK: - Forward / backward switching (same-pane matrix)

    @Test("switchToNextTabGlobally cycles forward within one pane")
    func switchForwardSamePane() throws {
        let pm = PaneManager()
        let pane = pm.activePaneID
        let tm = try #require(pm.tabManager(for: pane))
        for i in 0..<3 {
            tm.tabs.append(EditorTab(
                url: URL(fileURLWithPath: "/tmp/f\(i).swift"),
                content: "// \(i)", savedContent: "// \(i)"
            ))
        }
        // Activate in order 0→1→2; MRU becomes [tabs[2], tabs[1], tabs[0]].
        pm.selectEditorTab(tm.tabs[0].id, in: pane)
        pm.selectEditorTab(tm.tabs[1].id, in: pane)
        pm.selectEditorTab(tm.tabs[2].id, in: pane)
        // Active = tabs[2] (index 0 in MRU).

        pm.switchToNextTabGlobally()
        // Next from tabs[2] (index 0) → tabs[1] (index 1).
        #expect(tm.activeTabID == tm.tabs[1].id)
    }

    @Test("switchToPreviousTabGlobally cycles backward within one pane")
    func switchBackwardSamePane() throws {
        let pm = PaneManager()
        let pane = pm.activePaneID
        let tm = try #require(pm.tabManager(for: pane))
        for i in 0..<3 {
            tm.tabs.append(EditorTab(
                url: URL(fileURLWithPath: "/tmp/b\(i).swift"),
                content: "// \(i)", savedContent: "// \(i)"
            ))
        }
        // Activate in order 0→1→2; MRU becomes [tabs[2], tabs[1], tabs[0]].
        pm.selectEditorTab(tm.tabs[0].id, in: pane)
        pm.selectEditorTab(tm.tabs[1].id, in: pane)
        pm.selectEditorTab(tm.tabs[2].id, in: pane)
        // Active = tabs[2] (index 0 in MRU).

        pm.switchToPreviousTabGlobally()
        // Previous from tabs[2] (index 0) wraps to tabs[0] (index 2).
        #expect(tm.activeTabID == tm.tabs[0].id)
    }

    // MARK: - Cross-pane switching matrix

    @Test("switchToNextTabGlobally crosses pane boundaries")
    func switchForwardCrossPane() {
        let s = makeTwoEditorPaneManager(leftCount: 1, rightCount: 1)

        // Activate left first, then right. MRU: [right[0], left[0]], active=right.
        s.manager.selectEditorTab(s.leftTM.tabs[0].id, in: s.leftPane)
        s.manager.selectEditorTab(s.rightTM.tabs[0].id, in: s.rightPane)

        // Forward from right wraps to left.
        s.manager.switchToNextTabGlobally()
        #expect(s.manager.activePaneID == s.leftPane)
        #expect(s.leftTM.activeTabID == s.leftTM.tabs[0].id)
    }

    @Test("switchToPreviousTabGlobally crosses pane boundaries")
    func switchBackwardCrossPane() {
        let s = makeTwoEditorPaneManager(leftCount: 1, rightCount: 1)

        s.manager.selectEditorTab(s.leftTM.tabs[0].id, in: s.leftPane)
        s.manager.selectEditorTab(s.rightTM.tabs[0].id, in: s.rightPane)
        // MRU: [right[0], left[0]], active=right.

        // Backward from right goes to left.
        s.manager.switchToPreviousTabGlobally()
        #expect(s.manager.activePaneID == s.leftPane)
    }

    // MARK: - Terminal MRU integration

    @Test("Terminal tabs participate in the global switch order")
    func terminalTabsInGlobalOrder() throws {
        let s = makeTwoEditorPaneManager(leftCount: 1, rightCount: 0)
        let termPane = s.manager.createTerminalPaneAtBottom(workingDirectory: nil)
        let termState = try #require(s.manager.terminalState(for: termPane))
        let termTabID = try #require(termState.activeTerminalID)

        s.manager.selectEditorTab(s.leftTM.tabs[0].id, in: s.leftPane)
        termState.activeTerminalID = termTabID

        let order = s.manager.validGlobalTabSwitchOrder()
        #expect(order.count == 2)
        #expect(order.contains(where: { $0.contentType == .terminal }))
        #expect(order.contains(where: { $0.contentType == .editor }))
    }

    @Test("switchToNextTabGlobally switches between editor and terminal")
    func switchBetweenEditorAndTerminal() throws {
        let s = makeTwoEditorPaneManager(leftCount: 1, rightCount: 0)
        let termPane = s.manager.createTerminalPaneAtBottom(workingDirectory: nil)
        let termState = try #require(s.manager.terminalState(for: termPane))
        let termTabID = try #require(termState.activeTerminalID)

        // Activate editor then terminal. MRU: [term, editor], active=term.
        s.manager.selectEditorTab(s.leftTM.tabs[0].id, in: s.leftPane)
        s.manager.selectTerminalTab(termTabID, in: termPane)

        // Forward from terminal wraps to editor.
        s.manager.switchToNextTabGlobally()
        #expect(s.manager.activePaneID == s.leftPane)
    }

    // MARK: - Edge cases

    @Test("switchToNextTabGlobally is a no-op with fewer than two valid tabs")
    func switchNoOpWithOneTab() {
        let pm = PaneManager()
        let result = pm.switchToNextTabGlobally()
        #expect(result == false)
    }

    @Test("Cycling without a recorded current tab starts at the MRU head")
    func switchWithoutRecordedCurrentStartsAtHead() throws {
        let pm = PaneManager()
        let paneID = pm.activePaneID
        let tabManager = try #require(pm.tabManager(for: paneID))
        let first = EditorTab(
            url: URL(fileURLWithPath: "/tmp/unrecorded-first.swift"),
            content: "", savedContent: ""
        )
        let head = EditorTab(
            url: URL(fileURLWithPath: "/tmp/unrecorded-head.swift"),
            content: "", savedContent: ""
        )
        tabManager.tabs = [first, head]
        pm.recordTabActivation(paneID: paneID, tabID: first.id, contentType: .editor)
        pm.recordTabActivation(paneID: paneID, tabID: head.id, contentType: .editor)

        #expect(tabManager.activeTabID == nil)
        #expect(pm.switchToNextTabGlobally())
        #expect(tabManager.activeTabID == head.id)
    }

    @Test("switchToNextTabGlobally is deterministic across repeated calls")
    func switchDeterministic() {
        let s = makeTwoEditorPaneManager(leftCount: 2, rightCount: 1)

        // Record all three tabs in a known order: left[0], left[1], right[0].
        s.manager.selectEditorTab(s.leftTM.tabs[0].id, in: s.leftPane)
        s.manager.selectEditorTab(s.leftTM.tabs[1].id, in: s.leftPane)
        let startID = s.rightTM.tabs[0].id
        s.manager.selectEditorTab(startID, in: s.rightPane)
        // MRU: [right[0], left[1], left[0]], active = right[0].

        // Cycle through all three and return to start.
        var visited: [UUID] = []
        for _ in 0..<3 {
            s.manager.switchToNextTabGlobally()
            if let active = s.manager.activeTabManager?.activeTabID {
                visited.append(active)
            }
        }
        // After 3 forward switches (3 valid tabs), we return to start.
        #expect(visited.last == startID)
    }

    // MARK: - Visual switcher session

    @Test("Visual session advances without activating, then commits once")
    func visualSessionCommit() throws {
        let pm = PaneManager()
        let paneID = pm.activePaneID
        let tabManager = try #require(pm.tabManager(for: paneID))
        for index in 0..<3 {
            tabManager.tabs.append(EditorTab(
                url: URL(fileURLWithPath: "/tmp/session-\(index).swift"),
                content: "",
                savedContent: ""
            ))
            pm.selectEditorTab(tabManager.tabs[index].id, in: paneID)
        }
        let originalID = try #require(tabManager.activeTabID)
        let targetID = tabManager.tabs[1].id

        #expect(pm.beginGlobalTabSwitcherSession(initialOffset: 1))
        #expect(pm.globalTabSwitcherSession?.selectedIdentity?.tabID == targetID)
        #expect(tabManager.activeTabID == originalID)

        pm.commitGlobalTabSwitcher()

        #expect(pm.globalTabSwitcherSession == nil)
        #expect(tabManager.activeTabID == targetID)
        #expect(pm.globalTabSwitchOrder.first?.tabID == targetID)
    }

    @Test("Reverse visual session wraps to the oldest tab")
    func visualSessionReverse() throws {
        let pm = PaneManager()
        let paneID = pm.activePaneID
        let tabManager = try #require(pm.tabManager(for: paneID))
        for index in 0..<3 {
            tabManager.tabs.append(EditorTab(
                url: URL(fileURLWithPath: "/tmp/reverse-\(index).swift"),
                content: "",
                savedContent: ""
            ))
            pm.selectEditorTab(tabManager.tabs[index].id, in: paneID)
        }

        #expect(pm.beginGlobalTabSwitcherSession(initialOffset: -1))
        #expect(
            pm.globalTabSwitcherSession?.selectedIdentity?.tabID
                == tabManager.tabs[0].id
        )
    }

    @Test("Cancel ends the visual session without changing the active tab")
    func visualSessionCancel() throws {
        let pm = PaneManager()
        let paneID = pm.activePaneID
        let tabManager = try #require(pm.tabManager(for: paneID))
        for index in 0..<2 {
            tabManager.tabs.append(EditorTab(
                url: URL(fileURLWithPath: "/tmp/cancel-\(index).swift"),
                content: "",
                savedContent: ""
            ))
            pm.selectEditorTab(tabManager.tabs[index].id, in: paneID)
        }
        let originalID = try #require(tabManager.activeTabID)
        tabManager.pendingFocusTabID = originalID
        let originalFocusRequest = try #require(
            tabManager.pendingFocusRequestID
        )

        #expect(pm.beginGlobalTabSwitcherSession(initialOffset: 1))
        pm.cancelGlobalTabSwitcher()

        #expect(pm.globalTabSwitcherSession == nil)
        #expect(tabManager.activeTabID == originalID)
        #expect(tabManager.pendingFocusTabID == originalID)
        #expect(
            tabManager.pendingFocusRequestID == originalFocusRequest
        )
    }

    @Test("Cancel restores an original changed by an organic activation")
    func visualSessionCancelRestoresOrganicChange() throws {
        let pm = PaneManager()
        let paneID = pm.activePaneID
        let tabManager = try #require(pm.tabManager(for: paneID))
        for index in 0..<2 {
            tabManager.tabs.append(EditorTab(
                url: URL(
                    fileURLWithPath: "/tmp/cancel-restore-\(index).swift"
                ),
                content: "",
                savedContent: ""
            ))
            pm.selectEditorTab(tabManager.tabs[index].id, in: paneID)
        }
        let originalID = try #require(tabManager.activeTabID)
        let alternateID = tabManager.tabs[0].id

        #expect(pm.beginGlobalTabSwitcherSession(initialOffset: 1))
        #expect(pm.selectEditorTab(alternateID, in: paneID))
        let organicFocusRequest = try #require(
            tabManager.pendingFocusRequestID
        )

        pm.cancelGlobalTabSwitcher()

        #expect(tabManager.activeTabID == originalID)
        #expect(tabManager.pendingFocusTabID == originalID)
        #expect(tabManager.pendingFocusRequestID != organicFocusRequest)
    }

    @Test("Visual session requires two eligible tabs")
    func visualSessionNeedsTwoTabs() throws {
        let pm = PaneManager()
        let paneID = pm.activePaneID
        let tabManager = try #require(pm.tabManager(for: paneID))
        tabManager.tabs.append(EditorTab(
            url: URL(fileURLWithPath: "/tmp/only.swift"),
            content: "",
            savedContent: ""
        ))
        pm.selectEditorTab(tabManager.tabs[0].id, in: paneID)

        #expect(!pm.beginGlobalTabSwitcherSession(initialOffset: 1))
        #expect(pm.globalTabSwitcherSession == nil)
    }

    @Test("Visual session without a current tab starts at the MRU head")
    func visualSessionWithoutCurrentStartsAtHead() throws {
        let pm = PaneManager()
        let paneID = pm.activePaneID
        let tabManager = try #require(pm.tabManager(for: paneID))
        let older = EditorTab(
            url: URL(fileURLWithPath: "/tmp/no-current-older.swift"),
            content: "",
            savedContent: ""
        )
        let head = EditorTab(
            url: URL(fileURLWithPath: "/tmp/no-current-head.swift"),
            content: "",
            savedContent: ""
        )
        tabManager.tabs = [older, head]
        pm.recordTabActivation(
            paneID: paneID,
            tabID: older.id,
            contentType: .editor
        )
        pm.recordTabActivation(
            paneID: paneID,
            tabID: head.id,
            contentType: .editor
        )
        tabManager.activeTabID = nil

        #expect(pm.beginGlobalTabSwitcherSession(initialOffset: 1))
        #expect(pm.globalTabSwitcherSession?.selectedIdentity?.tabID == head.id)
    }

    @Test("Reverse visual session without a current tab starts at the MRU tail")
    func visualSessionWithoutCurrentReverseStartsAtTail() throws {
        let pm = PaneManager()
        let paneID = pm.activePaneID
        let tabManager = try #require(pm.tabManager(for: paneID))
        let tail = EditorTab(
            url: URL(fileURLWithPath: "/tmp/no-current-tail.swift"),
            content: "",
            savedContent: ""
        )
        let head = EditorTab(
            url: URL(fileURLWithPath: "/tmp/no-current-reverse-head.swift"),
            content: "",
            savedContent: ""
        )
        tabManager.tabs = [tail, head]
        pm.recordTabActivation(
            paneID: paneID,
            tabID: tail.id,
            contentType: .editor
        )
        pm.recordTabActivation(
            paneID: paneID,
            tabID: head.id,
            contentType: .editor
        )
        tabManager.activeTabID = nil

        #expect(pm.beginGlobalTabSwitcherSession(initialOffset: -1))
        #expect(pm.globalTabSwitcherSession?.selectedIdentity?.tabID == tail.id)
    }

    @Test("Closing the selected tab reconciles display and commit")
    func visualSessionReconcilesClosedSelection() throws {
        let pm = PaneManager()
        let paneID = pm.activePaneID
        let tabManager = try #require(pm.tabManager(for: paneID))
        for index in 0..<3 {
            tabManager.tabs.append(EditorTab(
                url: URL(fileURLWithPath: "/tmp/stale-\(index).swift"),
                content: "",
                savedContent: ""
            ))
            pm.selectEditorTab(tabManager.tabs[index].id, in: paneID)
        }
        let expectedID = tabManager.tabs[0].id

        #expect(pm.beginGlobalTabSwitcherSession(initialOffset: 1))
        let removedID = try #require(
            pm.globalTabSwitcherSession?.selectedIdentity?.tabID
        )
        tabManager.closeTab(id: removedID)

        // Inventory changes reconcile the stored session immediately; the
        // overlay is a consumer, not the mechanism that repairs model state.
        #expect(pm.globalTabSwitcherSession?.identities.count == 2)
        #expect(
            pm.globalTabSwitcherSession?.selectedIdentity?.tabID
                == expectedID
        )
        let presentation = pm.globalTabSwitcherPresentation(projectRoot: nil)
        #expect(presentation.entries.count == 2)
        #expect(
            presentation.entries[presentation.selectedIndex].id.tabID
                == expectedID
        )

        pm.commitGlobalTabSwitcher()
        #expect(tabManager.activeTabID == expectedID)
    }

    @Test("Removing the original pane preserves a valid selected identity")
    func visualSessionReconcilesRemovedPane() throws {
        let setup = makeTwoEditorPaneManager(leftCount: 2, rightCount: 1)
        setup.manager.selectEditorTab(
            setup.leftTM.tabs[0].id,
            in: setup.leftPane
        )
        setup.manager.selectEditorTab(
            setup.leftTM.tabs[1].id,
            in: setup.leftPane
        )
        setup.manager.selectEditorTab(
            setup.rightTM.tabs[0].id,
            in: setup.rightPane
        )
        let expectedID = setup.leftTM.tabs[1].id

        #expect(
            setup.manager.beginGlobalTabSwitcherSession(initialOffset: 1)
        )
        #expect(
            setup.manager.globalTabSwitcherSession?.selectedIdentity?.tabID
                == expectedID
        )
        setup.manager.removePane(setup.rightPane)

        #expect(
            setup.manager.globalTabSwitcherSession?.identities
                .allSatisfy { $0.paneID != setup.rightPane } == true
        )
        setup.manager.commitGlobalTabSwitcher()
        #expect(setup.leftTM.activeTabID == expectedID)
    }

    @Test("Stale removal below two entries ends the visual session")
    func visualSessionEndsWhenTooFewRemain() throws {
        let pm = PaneManager()
        let paneID = pm.activePaneID
        let tabManager = try #require(pm.tabManager(for: paneID))
        for index in 0..<2 {
            tabManager.tabs.append(EditorTab(
                url: URL(fileURLWithPath: "/tmp/end-\(index).swift"),
                content: "",
                savedContent: ""
            ))
            pm.selectEditorTab(tabManager.tabs[index].id, in: paneID)
        }

        #expect(pm.beginGlobalTabSwitcherSession(initialOffset: 1))
        tabManager.closeTab(id: tabManager.tabs[0].id)

        #expect(pm.globalTabSwitcherSession == nil)
        #expect(!pm.reconcileGlobalTabSwitcherSession())
        #expect(pm.globalTabSwitcherSession == nil)
    }

    @Test("Reconciliation chooses the nearest surviving forward neighbour")
    func reconciliationDoesNotSkipAfterEarlierRemoval() throws {
        let paneID = PaneID()
        let identities = (0..<5).map { _ in
            GlobalTabIdentity(
                paneID: paneID,
                tabID: UUID(),
                contentType: .editor
            )
        }
        let session = GlobalTabSwitcherSession(
            identities: identities,
            originalIdentity: identities[0],
            selectedIndex: 2
        )
        let valid = Set([
            identities[1],
            identities[3],
            identities[4],
        ])

        let reconciled = try #require(session.reconciled(keeping: valid))

        #expect(reconciled.identities == [
            identities[1],
            identities[3],
            identities[4],
        ])
        #expect(reconciled.selectedIdentity == identities[3])
    }

    @Test("Replacing the pane layout discards a live visual session")
    func layoutRestoreDiscardsVisualSession() throws {
        let pm = PaneManager()
        let paneID = pm.activePaneID
        let tabManager = try #require(pm.tabManager(for: paneID))
        for index in 0..<2 {
            let tab = EditorTab(
                url: URL(
                    fileURLWithPath: "/tmp/layout-restore-\(index).swift"
                ),
                content: "",
                savedContent: ""
            )
            tabManager.tabs.append(tab)
            pm.selectEditorTab(tab.id, in: paneID)
        }
        #expect(pm.beginGlobalTabSwitcherSession(initialOffset: 1))

        let restoredPaneID = PaneID()
        #expect(pm.restoreLayout(
            from: .leaf(restoredPaneID, .editor),
            activePaneUUID: restoredPaneID.id
        ))

        #expect(pm.globalTabSwitcherSession == nil)
        #expect(pm.activePaneID == restoredPaneID)
    }

    @Test("Switcher projection performs linear inventory work")
    func switcherProjectionIsLinear() throws {
        let pm = PaneManager()
        let paneID = pm.activePaneID
        let tabManager = try #require(pm.tabManager(for: paneID))
        let tabCount = 1_000
        tabManager.tabs = (0..<tabCount).map { index in
            EditorTab(
                url: URL(
                    fileURLWithPath: "/tmp/linear/file-\(index).swift"
                ),
                content: "",
                savedContent: ""
            )
        }
        let identities = tabManager.tabs.map {
            GlobalTabIdentity(
                paneID: paneID,
                tabID: $0.id,
                contentType: .editor
            )
        }
        tabManager.activeTabID = tabManager.tabs[0].id
        pm.restoreGlobalTabSwitchOrder(identities)

        #expect(pm.beginGlobalTabSwitcherSession(initialOffset: 1))
        let presentation = pm.globalTabSwitcherPresentation(
            projectRoot: URL(fileURLWithPath: "/tmp/linear")
        )
        let metrics = pm.lastGlobalTabInventoryMetrics

        #expect(presentation.entries.count == tabCount)
        #expect(metrics.paneVisits == 1)
        #expect(metrics.tabVisits == tabCount)
        #expect(metrics.orderLookups == tabCount)
        #expect(metrics.entryLookups == tabCount)
        #expect(metrics.totalOperations == 3 * tabCount + 1)
    }

    @Test("Duplicate editor titles receive deterministic path details")
    func duplicateEditorTitlesAreDisambiguated() throws {
        let pm = PaneManager()
        let paneID = pm.activePaneID
        let tabManager = try #require(pm.tabManager(for: paneID))
        let root = URL(fileURLWithPath: "/tmp/Pine Demo")
        let urls = [
            root.appendingPathComponent("Sources/A/main.swift"),
            root.appendingPathComponent("Sources/B/main.swift"),
            URL(fileURLWithPath: "/external/C/main.swift"),
        ]
        for url in urls {
            let tab = EditorTab(
                url: url,
                content: "",
                savedContent: ""
            )
            tabManager.tabs.append(tab)
            pm.selectEditorTab(tab.id, in: paneID)
        }

        #expect(pm.beginGlobalTabSwitcherSession(initialOffset: 1))
        let entries = pm.globalTabSwitcherEntries(projectRoot: root)
        let details = entries.compactMap(\.detail)

        #expect(entries.allSatisfy { $0.title == "main.swift" })
        #expect(Set(details).count == urls.count)
        #expect(details.contains("Sources/A/main.swift"))
        #expect(details.contains("Sources/B/main.swift"))
        #expect(details.contains("/external/C"))
    }

    @Test("Terminal duplicate titles include stable labels and working directory")
    func duplicateTerminalTitlesAreDisambiguated() throws {
        let pm = PaneManager()
        let editorPane = pm.activePaneID
        let editorManager = try #require(pm.tabManager(for: editorPane))
        let editor = EditorTab(
            url: URL(fileURLWithPath: "/tmp/project/main.swift"),
            content: "",
            savedContent: ""
        )
        editorManager.tabs.append(editor)
        pm.selectEditorTab(editor.id, in: editorPane)

        let projectRoot = URL(fileURLWithPath: "/tmp/project")
        let terminalPane = pm.createTerminalPaneAtBottom(
            workingDirectory: projectRoot
        )
        let state = try #require(pm.terminalState(for: terminalPane))
        let first = try #require(state.terminalTabs.first)
        let second = state.addTab(
            workingDirectory: projectRoot.appendingPathComponent("Sources")
        )
        first.name = "shell"
        second.name = "shell"
        pm.selectTerminalTab(first.id, in: terminalPane)
        pm.selectTerminalTab(second.id, in: terminalPane)

        #expect(pm.beginGlobalTabSwitcherSession(initialOffset: 1))
        let terminalEntries = pm.globalTabSwitcherEntries(
            projectRoot: projectRoot
        ).filter { $0.id.contentType == .terminal }
        let details = terminalEntries.compactMap(\.detail)

        #expect(terminalEntries.count == 2)
        #expect(terminalEntries.allSatisfy { $0.title == "shell" })
        #expect(Set(details).count == 2)
        #expect(details.contains { $0.contains(first.stableLabel) })
        #expect(details.contains { $0.contains(second.stableLabel) })
        #expect(details.contains { $0.contains("Sources") })
    }

    @Test("Global switch to a terminal updates the command destination")
    func terminalSwitchUpdatesDestinationWithoutReorderingMRU() throws {
        let paneManager = PaneManager()
        let terminalManager = TerminalManager()
        terminalManager.paneManager = paneManager
        let editorPane = paneManager.activePaneID
        let editorManager = try #require(
            paneManager.tabManager(for: editorPane)
        )
        let editor = EditorTab(
            url: URL(fileURLWithPath: "/tmp/global-routing.swift"),
            content: "",
            savedContent: ""
        )
        editorManager.tabs.append(editor)
        #expect(paneManager.selectEditorTab(editor.id, in: editorPane))
        let firstPane = paneManager.createTerminalPaneAtBottom(
            workingDirectory: nil
        )
        let secondPane = try #require(paneManager.createTerminalPane(
            relativeTo: firstPane,
            axis: .horizontal,
            workingDirectory: nil
        ))
        let firstTab = try #require(
            paneManager.terminalState(for: firstPane)?.activeTab
        )
        let secondTab = try #require(
            paneManager.terminalState(for: secondPane)?.activeTab
        )
        #expect(paneManager.selectTerminalTab(
            secondTab.id,
            in: secondPane
        ))
        #expect(paneManager.selectTerminalTab(firstTab.id, in: firstPane))
        #expect(terminalManager.lastActiveTerminalPaneID == firstPane)
        let originalOrder = paneManager.globalTabSwitchOrder

        #expect(paneManager.beginGlobalTabSwitcherSession(initialOffset: 1))

        // Overlay preview is selection-only: it must not move real focus,
        // destination bookkeeping, or MRU until commit.
        #expect(paneManager.activePaneID == firstPane)
        #expect(terminalManager.lastActiveTerminalPaneID == firstPane)
        #expect(paneManager.globalTabSwitchOrder == originalOrder)
        paneManager.commitGlobalTabSwitcher()

        #expect(paneManager.activePaneID == secondPane)
        #expect(
            paneManager.terminalState(for: secondPane)?.activeTerminalID
                == secondTab.id
        )
        #expect(
            paneManager.terminalState(for: secondPane)?.pendingFocusTabID
                == secondTab.id
        )
        #expect(terminalManager.lastActiveTerminalPaneID == secondPane)
        #expect(paneManager.globalTabSwitchOrder.first == GlobalTabIdentity(
            paneID: secondPane,
            tabID: secondTab.id,
            contentType: .terminal
        ))
        #expect(paneManager.globalTabSwitchOrder.count == originalOrder.count)
        #expect(Set(paneManager.globalTabSwitchOrder).count == originalOrder.count)
    }

    @Test("Path normalization is lexical and respects component boundaries")
    func lexicalRelativePathNormalization() {
        let root = URL(fileURLWithPath: "/nonexistent/project")

        #expect(PaneManager.relativePath(
            from: URL(
                fileURLWithPath:
                    "/nonexistent/project/Sources/../main.swift"
            ),
            root: root
        ) == "main.swift")
        #expect(PaneManager.relativePath(
            from: URL(
                fileURLWithPath:
                    "/nonexistent/project-sibling/main.swift"
            ),
            root: root
        ) == nil)
    }

    @Test("Committing to a hidden pane swaps the maximized projection")
    func switcherCommitSurfacesHiddenMaximizedPane() {
        let setup = makeTwoEditorPaneManager(leftCount: 1, rightCount: 1)
        setup.manager.selectEditorTab(
            setup.rightTM.tabs[0].id,
            in: setup.rightPane
        )
        setup.manager.selectEditorTab(
            setup.leftTM.tabs[0].id,
            in: setup.leftPane
        )
        setup.manager.maximize(paneID: setup.leftPane)

        #expect(setup.manager.beginGlobalTabSwitcherSession(initialOffset: 1))
        #expect(
            setup.manager.globalTabSwitcherSession?.selectedIdentity?.paneID
                == setup.rightPane
        )
        setup.manager.commitGlobalTabSwitcher()

        #expect(setup.manager.isMaximized)
        #expect(setup.manager.activePaneID == setup.rightPane)
        #expect(setup.manager.root.content(for: setup.rightPane) == .editor)
        #expect(
            setup.rightTM.activeTabID == setup.rightTM.tabs[0].id
        )
    }

    @Test("Maximizing an inactive pane makes it the switcher anchor")
    func maximizedPaneBecomesCurrentSwitcherAnchor() throws {
        let manager = PaneManager()
        let editorPane = manager.activePaneID
        let editorManager = try #require(
            manager.tabManager(for: editorPane)
        )
        let editorTab = EditorTab(
            url: URL(fileURLWithPath: "/tmp/max-anchor.swift"),
            content: "",
            savedContent: ""
        )
        editorManager.tabs = [editorTab]
        manager.selectEditorTab(editorTab.id, in: editorPane)

        let terminalPane = manager.createTerminalPaneAtBottom(
            workingDirectory: nil
        )
        let terminalState = try #require(
            manager.terminalState(for: terminalPane)
        )
        let terminalTabID = try #require(terminalState.activeTerminalID)

        // Deliberately leave the editor active, then invoke the same model
        // operation as the terminal pane's maximize button.
        manager.selectEditorTab(editorTab.id, in: editorPane)
        #expect(manager.activePaneID == editorPane)
        manager.maximize(paneID: terminalPane)

        #expect(manager.activePaneID == terminalPane)
        #expect(manager.beginGlobalTabSwitcherSession(initialOffset: 1))
        #expect(
            manager.globalTabSwitcherSession?.originalIdentity
                == GlobalTabIdentity(
                    paneID: terminalPane,
                    tabID: terminalTabID,
                    contentType: .terminal
                )
        )
        #expect(
            manager.globalTabSwitcherSession?.selectedIdentity?.paneID
                == editorPane
        )

        manager.commitGlobalTabSwitcher()
        #expect(manager.isMaximized)
        #expect(manager.activePaneID == editorPane)
        #expect(manager.root.content(for: editorPane) == .editor)
        #expect(manager.persistableRoot.contains(terminalPane))

        manager.restoreFromMaximize()
        #expect(Set(manager.root.leafIDs) == Set([editorPane, terminalPane]))
    }
}
