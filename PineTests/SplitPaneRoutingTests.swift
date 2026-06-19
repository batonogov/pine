//
//  SplitPaneRoutingTests.swift
//  PineTests
//
//  Regression coverage for issues #971 and #998: commands, search results,
//  status bar, inline diff, change navigation, and go-to requests must
//  route through the *active* editor pane's TabManager — never the
//  project's primary TabManager — when a split layout is active.
//
//  These tests verify the underlying routing primitives and project-level
//  helpers that ContentView, PaneLeafView, GitAndNotificationObserver, and
//  SearchResultsView rely on. SwiftUI view bodies themselves are not
//  instantiated here; instead we exercise the data-flow contracts the
//  views consume so regressions in routing surface as unit-test failures
//  rather than only as UI misbehavior.
//

import Foundation
import Testing

@testable import Pine

@Suite("Split-Pane Active-TabManager Routing (#971, #998)")
@MainActor
struct SplitPaneRoutingTests {

    // MARK: - Helpers

    /// Snapshot of a freshly-built 2-editor-pane layout. After `makeSplitWithTwoPanes`,
    /// `pm.activeTabManager` resolves to `secondTM` (the newly split pane becomes active).
    struct SplitFixture {
        let pm: ProjectManager
        let firstPane: PaneID
        let secondPane: PaneID
        let firstTM: TabManager
        let secondTM: TabManager
        let firstURL: URL
        let secondURL: URL
    }

    @discardableResult
    private func makeSplitWithTwoPanes() throws -> SplitFixture {
        let pm = ProjectManager()
        let firstPane = pm.paneManager.activePaneID
        guard let firstTM = pm.paneManager.tabManager(for: firstPane) else {
            Issue.record("Primary TabManager missing")
            throw SplitTestError.setupFailed
        }

        let firstURL = URL(fileURLWithPath: "/tmp/pine-routing-first-\(UUID().uuidString).swift")
        let secondURL = URL(fileURLWithPath: "/tmp/pine-routing-second-\(UUID().uuidString).swift")
        try "first".write(to: firstURL, atomically: true, encoding: .utf8)
        try "second".write(to: secondURL, atomically: true, encoding: .utf8)

        firstTM.openTab(url: firstURL)

        guard let secondPane = pm.paneManager.splitPane(firstPane, axis: .horizontal) else {
            Issue.record("Split failed")
            throw SplitTestError.setupFailed
        }
        guard let secondTM = pm.paneManager.tabManager(for: secondPane) else {
            Issue.record("Second pane TabManager missing")
            throw SplitTestError.setupFailed
        }
        secondTM.openTab(url: secondURL)

        return SplitFixture(
            pm: pm,
            firstPane: firstPane,
            secondPane: secondPane,
            firstTM: firstTM,
            secondTM: secondTM,
            firstURL: firstURL,
            secondURL: secondURL
        )
    }

    private enum SplitTestError: Error { case setupFailed }

    // MARK: - #998: primary vs active TabManager distinction

    @Test("ProjectManager.activeTabManager diverges from primary in split layouts")
    func activeTabManagerDiffersFromPrimaryInSplit() throws {
        let f = try makeSplitWithTwoPanes()
        let pm = f.pm
        let firstTM = f.firstTM
        let secondTM = f.secondTM

        // Primary stays the original root TabManager (firstTM).
        #expect(pm.primaryTabManager === firstTM)

        // Active is the newly-split pane's TabManager (secondTM).
        #expect(pm.activeTabManager === secondTM)
        #expect(pm.activeTabManager !== pm.primaryTabManager,
                "active must diverge from primary after a split — the leak #998 describes")
    }

    @Test("activeTabManager follows focus as activePaneID changes")
    func activeTabManagerTracksFocus() throws {
        let f = try makeSplitWithTwoPanes()
        let pm = f.pm
        let firstPane = f.firstPane
        let firstTM = f.firstTM
        let secondTM = f.secondTM

        // Initially the split target is active.
        #expect(pm.activeTabManager === secondTM)

        // Move focus back to the first pane.
        pm.paneManager.activePaneID = firstPane
        #expect(pm.activeTabManager === firstTM)

        // Move focus to the second pane again.
        pm.paneManager.activePaneID = pm.paneManager.root.leafIDs
            .first(where: { $0 != firstPane }) ?? firstPane
        #expect(pm.activeTabManager === secondTM)
    }

    @Test("activeTabManager falls back to primary in single-pane layout (backward compat)")
    func activeTabManagerSinglePaneFallback() {
        let pm = ProjectManager()
        // No split yet — active must equal primary (backward compat).
        #expect(pm.activeTabManager === pm.primaryTabManager)
    }

    // MARK: - #971: pendingGoToLine routing reaches active pane

    @Test("SearchResultsView target resolves to active pane's TabManager")
    func searchResultsTargetActivePane() throws {
        let f = try makeSplitWithTwoPanes()
        let pm = f.pm
        let secondTM = f.secondTM

        // Simulate SearchResultsView.openMatch → openTabAndGoToLine on active.
        let newURL = URL(fileURLWithPath: "/tmp/pine-search-result-\(UUID().uuidString).swift")
        try "x".write(to: newURL, atomically: true, encoding: .utf8)
        pm.activeTabManager.openTabAndGoToLine(url: newURL, line: 7)

        // The tab and pending line must land in the active (second) pane.
        #expect(secondTM.tabs.contains(where: { $0.url == newURL }))
        #expect(secondTM.pendingGoToLine == 7)
        // Primary must not have received the request.
        #expect(pm.primaryTabManager.tabs.contains(where: { $0.url == newURL }) == false)
        #expect(pm.primaryTabManager.pendingGoToLine == nil)
    }

    @Test("pendingGoToLine on active pane is observable per-pane (PaneLeafView contract)")
    func pendingGoToLineObservablePerPane() throws {
        let f = try makeSplitWithTwoPanes()
        let pm = f.pm
        let firstTM = f.firstTM
        let secondTM = f.secondTM

        // Setting pendingGoToLine on the active pane must NOT propagate to
        // the primary pane — PaneLeafView observes only its own TabManager.
        pm.activeTabManager.pendingGoToLine = 42

        #expect(secondTM.pendingGoToLine == 42)
        #expect(firstTM.pendingGoToLine == nil,
                "pendingGoToLine must be per-TabManager; cross-pane leak would re-introduce #998")
    }

    // MARK: - #971: handleFileRenamed covers every pane

    @Test("ProjectManager.handleFileRenamed updates tabs in every pane")
    func handleFileRenamedAcrossPanes() throws {
        let f = try makeSplitWithTwoPanes()
        let pm = f.pm
        let firstTM = f.firstTM
        let secondTM = f.secondTM
        let firstURL = f.firstURL

        // Open the SAME file in both panes — rename must hit both copies.
        secondTM.openTab(url: firstURL)
        #expect(firstTM.tabs.contains(where: { $0.url == firstURL }))
        #expect(secondTM.tabs.contains(where: { $0.url == firstURL }))

        let newURL = firstURL.deletingLastPathComponent()
            .appendingPathComponent("renamed-\(UUID().uuidString).swift")

        pm.handleFileRenamed(oldURL: firstURL, newURL: newURL)

        #expect(firstTM.tabs.contains(where: { $0.url == newURL }))
        #expect(secondTM.tabs.contains(where: { $0.url == newURL }))
        #expect(firstTM.tabs.contains(where: { $0.url == firstURL }) == false)
        #expect(secondTM.tabs.contains(where: { $0.url == firstURL }) == false)
    }

    @Test("handleFileRenamed touches a non-primary pane even when primary is empty")
    func handleFileRenamedNonPrimaryOnly() throws {
        let pm = ProjectManager()
        let firstPane = pm.paneManager.activePaneID
        // Split before opening any tabs — primary stays empty.
        guard let secondPane = pm.paneManager.splitPane(firstPane, axis: .horizontal),
              let secondTM = pm.paneManager.tabManager(for: secondPane) else {
            Issue.record("Split failed")
            return
        }

        let url = URL(fileURLWithPath: "/tmp/pine-rename-nonprimary-\(UUID().uuidString).swift")
        try "x".write(to: url, atomically: true, encoding: .utf8)
        secondTM.openTab(url: url)
        #expect(pm.primaryTabManager.tabs.isEmpty)

        let newURL = url.deletingLastPathComponent()
            .appendingPathComponent("moved.swift")
        pm.handleFileRenamed(oldURL: url, newURL: newURL)

        #expect(secondTM.tabs.first?.url == newURL,
                "rename must update non-primary pane even when primary holds no tabs")
    }

    // MARK: - #971: inline diff / change navigation target active pane

    @Test("active pane's cursor and content drive change navigation, not primary")
    func changeNavigationUsesActivePaneCursor() throws {
        let f = try makeSplitWithTwoPanes()
        let pm = f.pm
        let firstPane = f.firstPane
        let firstTM = f.firstTM
        let secondTM = f.secondTM
        let secondURL = f.secondURL

        // Place distinct cursor positions in each pane.
        guard let firstTab = firstTM.activeTab,
              let secondTab = secondTM.activeTab else {
            Issue.record("Active tabs missing")
            return
        }
        firstTM.updateEditorState(cursorPosition: 1, scrollOffset: 0)
        secondTM.updateEditorState(cursorPosition: 2, scrollOffset: 0)

        // Focus the second pane.
        pm.paneManager.activePaneID = firstPane
        pm.paneManager.activePaneID = pm.paneManager.root.leafIDs
            .first(where: { $0 != firstPane }) ?? firstPane

        // The active pane's tab is the second one — navigateToChange reads
        // `activeTabManager.activeTab` (verified indirectly here by checking
        // that the active pane exposes the second tab/URL).
        #expect(pm.activeTabManager === secondTM)
        #expect(pm.activeTabManager.activeTab?.url == secondURL)
        #expect(pm.activeTabManager.activeTab?.cursorPosition == 2)

        // And the primary is untouched — its tab/URL/cursor are different.
        #expect(pm.primaryTabManager === firstTM)
        #expect(pm.primaryTabManager.activeTab?.url != secondURL)
        #expect(pm.primaryTabManager.activeTab?.cursorPosition == 1)

        _ = firstTab
    }

    @Test("inline diff action target tab resolves from active pane")
    func inlineDiffTargetActiveTab() throws {
        let f = try makeSplitWithTwoPanes()
        let pm = f.pm
        let secondTM = f.secondTM
        let secondURL = f.secondURL

        // The active pane is the second one — the inline diff helper reads
        // `activeTabManager.activeTab.url`. Confirm the resolved URL is the
        // second pane's URL, not the primary's.
        #expect(pm.activeTabManager === secondTM)
        #expect(pm.activeTabManager.activeTab?.url == secondURL)
        #expect(secondURL != pm.primaryTabManager.activeTab?.url)
    }

    // MARK: - #971: status bar receives the active pane's TabManager

    @Test("StatusBarView receives active pane's TabManager (URL matches focused pane)")
    func statusBarReceivesActiveTabManager() throws {
        let f = try makeSplitWithTwoPanes()
        let pm = f.pm
        let firstTM = f.firstTM
        let secondTM = f.secondTM

        // The contract from ContentView.swift is: StatusBarView is constructed
        // with `tabManager: activeTabManager`. Verify that the active TM is
        // the second pane (so the status bar will read its tab's cursor,
        // indentation, line ending, encoding, and file size — not primary's).
        let statusTabManager = pm.activeTabManager
        #expect(statusTabManager === secondTM)
        #expect(statusTabManager !== firstTM)
        #expect(statusTabManager !== pm.primaryTabManager)
    }

    // MARK: - #971: close/quit dirty tracking reaches every pane (existing behavior preserved)

    @Test("allDirtyTabs collects from active and non-active panes")
    func allDirtyTabsAcrossPanes() throws {
        let f = try makeSplitWithTwoPanes()
        let pm = f.pm
        let firstTM = f.firstTM
        let secondTM = f.secondTM

        // Dirty a tab in the non-active (primary) pane only.
        firstTM.updateContent("dirty primary")

        #expect(pm.hasUnsavedChanges)
        #expect(pm.allDirtyTabs.count == 1)
        #expect(pm.allDirtyTabs.first?.content == "dirty primary")

        // Dirty a tab in the active (second) pane too.
        secondTM.updateContent("dirty active")
        #expect(pm.allDirtyTabs.count == 2)
    }

    // MARK: - #971: openFileAtLine notification lands in the active pane

    @Test("openFileAtLine routes through active TabManager (terminal Cmd+Click contract)")
    func openFileAtLineLandsInActivePane() throws {
        let f = try makeSplitWithTwoPanes()
        let pm = f.pm
        let secondTM = f.secondTM

        // Simulate GitAndNotificationObserver's .openFileAtLine handler.
        let url = URL(fileURLWithPath: "/tmp/pine-open-at-line-\(UUID().uuidString).swift")
        try "line1\nline2\nline3\n".write(to: url, atomically: true, encoding: .utf8)
        pm.activeTabManager.openTabAndGoToLine(url: url, line: 3)

        #expect(secondTM.tabs.contains(where: { $0.url == url }))
        #expect(secondTM.pendingGoToLine == 3)
        #expect(pm.primaryTabManager.tabs.contains(where: { $0.url == url }) == false)
    }

    // MARK: - #971: symbol navigator posts an offset that resolves via active pane

    @Test("symbolNavigate offset resolves to active pane's tab content")
    func symbolNavigateUsesActiveTabContent() throws {
        let f = try makeSplitWithTwoPanes()
        let pm = f.pm
        let firstTM = f.firstTM
        let secondTM = f.secondTM

        // Give each pane distinct content so the offset→line mapping differs.
        firstTM.updateContent("a\nb\nc\nd\n")
        secondTM.updateContent("x\ny\nz\n")

        // Active pane is the second; the resolver (mirroring ContentView's
        // symbolNavigate handler) must use secondTM's active tab content.
        guard let activeTab = pm.activeTabManager.activeTab else {
            Issue.record("Active tab missing")
            return
        }
        #expect(activeTab.content == "x\ny\nz\n")

        let line = ContentView.lineNumber(forOffset: 2, in: activeTab.content)
        #expect(line == 2)
        // The same offset in the primary pane's content would also map to
        // line 2 here, but the resolver must read active content — verified
        // by the `activeTab.content == "x\ny\nz\n"` assertion above.
        pm.activeTabManager.pendingGoToLine = line
        #expect(secondTM.pendingGoToLine == 2)
        #expect(firstTM.pendingGoToLine == nil)
    }

    // MARK: - #998: primary remains usable when active diverges

    @Test("Primary TabManager remains intact when active routes elsewhere")
    func primaryIntactWhenActiveDiffers() throws {
        let f = try makeSplitWithTwoPanes()
        let pm = f.pm
        let firstTM = f.firstTM
        let secondTM = f.secondTM
        let firstURL = f.firstURL
        let secondURL = f.secondURL

        // Even though activeTabManager routes to the second pane, primary
        // still owns its tabs and can be operated on directly (e.g. session
        // restore writes here for the legacy single-pane path).
        #expect(pm.primaryTabManager === firstTM)
        #expect(firstTM.tabs.contains(where: { $0.url == firstURL }))
        #expect(secondTM.tabs.contains(where: { $0.url == secondURL }))
        #expect(firstTM !== secondTM)
    }

    // MARK: - #971: activeEditorTabManager survives orphan primary

    @Test("activeTabManager resolves even when primary is orphaned (terminals-only edge)")
    func activeTabManagerWithOrphanedPrimary() throws {
        let f = try makeSplitWithTwoPanes()
        let pm = f.pm
        let firstPane = f.firstPane
        let firstURL = f.firstURL

        // Open the file in the first pane (primary) too.
        pm.primaryTabManager.openTab(url: firstURL)

        // Now create a terminal pane and focus it. activeEditorTabManager
        // must fall back to the nearest editor pane's TabManager — never nil.
        guard let terminalID = pm.paneManager.createTerminalPane(
            relativeTo: firstPane, axis: .vertical, workingDirectory: nil
        ) else {
            Issue.record("Terminal split failed")
            return
        }
        pm.paneManager.activePaneID = terminalID

        let resolved = pm.activeTabManager
        #expect(resolved.activeTab != nil,
                "active TabManager must resolve even when focus is on a terminal pane")
    }
}

// MARK: - Recovery routing into the active pane

@Suite("Recovery Tab Routing (#971)")
@MainActor
struct RecoveryRoutingTests {

    @Test("Recovery opens into the active pane, not the primary")
    func recoveryOpensIntoActivePane() throws {
        let pm = ProjectManager()
        let firstPane = pm.paneManager.activePaneID

        // Split before any tabs — primary is empty and the second pane is active.
        guard let secondPane = pm.paneManager.splitPane(firstPane, axis: .horizontal),
              let secondTM = pm.paneManager.tabManager(for: secondPane) else {
            Issue.record("Split failed")
            return
        }

        // Mirrors ContentView.recoverTabs(): open into `activeTabManager`.
        let url = URL(fileURLWithPath: "/tmp/pine-recovery-\(UUID().uuidString).swift")
        try "recovered".write(to: url, atomically: true, encoding: .utf8)

        let target = pm.activeTabManager
        target.openTab(url: url)

        #expect(target === secondTM)
        #expect(secondTM.tabs.contains(where: { $0.url == url }))
        #expect(pm.primaryTabManager.tabs.isEmpty,
                "Recovery must not leak into the primary pane when an editor pane is focused")
    }
}
