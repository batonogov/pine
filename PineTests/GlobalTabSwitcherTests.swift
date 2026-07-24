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
}
