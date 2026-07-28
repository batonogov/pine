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

    // MARK: - #971: close*WithConfirmation routing (review F3)
    //
    // ContentView's closeOther/All/ToTheRight/Tab helpers all delegate to
    // `TabCloseHelper.<op>(in: activeTabManager, gitProvider:)`. TabCloseHelper
    // is not a SwiftUI view, so we exercise it directly with the active pane's
    // TabManager and assert the primary pane is never touched — pinning the
    // routing contract the view relies on. Clean tabs are used so no modal
    // confirmation alert blocks the test.

    @Test("closeAllTabsWithConfirmation closes only the active pane (TabCloseHelper contract)")
    func closeAllTabsRoutesToActivePaneOnly() async throws {
        let f = try makeSplitWithTwoPanes()
        let pm = f.pm
        let firstTM = f.firstTM
        let secondTM = f.secondTM

        // Both panes hold one clean tab each.
        #expect(firstTM.tabs.count == 1)
        #expect(secondTM.tabs.count == 1)

        // Mirror the active-pane close-all contract (TabCloseHelper):
        //   TabCloseHelper.closeAllTabs(in: activeTabManager, gitProvider:)
        let provider = GitStatusProvider()
        await TabCloseHelper.closeAllTabs(in: pm.activeTabManager, gitProvider: provider)

        #expect(secondTM.tabs.isEmpty, "close-all must affect only the active pane")
        #expect(firstTM.tabs.count == 1, "primary pane must be untouched by active-pane close-all")
    }

    @Test("closeOtherTabsWithConfirmation closes only the active pane's other tabs")
    func closeOtherTabsRoutesToActivePaneOnly() async throws {
        let f = try makeSplitWithTwoPanes()
        let pm = f.pm
        let firstTM = f.firstTM
        let secondTM = f.secondTM

        // Add two extra clean tabs to the active (second) pane.
        let extra1 = URL(fileURLWithPath: "/tmp/pine-close-other-1-\(UUID().uuidString).swift")
        let extra2 = URL(fileURLWithPath: "/tmp/pine-close-other-2-\(UUID().uuidString).swift")
        try "a".write(to: extra1, atomically: true, encoding: .utf8)
        try "b".write(to: extra2, atomically: true, encoding: .utf8)
        secondTM.openTab(url: extra1)
        secondTM.openTab(url: extra2)
        #expect(secondTM.tabs.count == 3)
        #expect(firstTM.tabs.count == 1)

        guard let keepID = secondTM.tabs.first?.id else {
            Issue.record("keep tab missing")
            return
        }
        let provider = GitStatusProvider()
        await TabCloseHelper.closeOtherTabs(keeping: keepID, in: pm.activeTabManager, gitProvider: provider)

        #expect(secondTM.tabs.count == 1)
        #expect(secondTM.tabs.first?.id == keepID)
        #expect(firstTM.tabs.count == 1, "primary pane must be untouched by active-pane close-other")
    }

    @Test("closeTabsToTheRightWithConfirmation closes only the active pane's right tabs")
    func closeTabsToTheRightRoutesToActivePaneOnly() async throws {
        let f = try makeSplitWithTwoPanes()
        let pm = f.pm
        let firstTM = f.firstTM
        let secondTM = f.secondTM

        let extra1 = URL(fileURLWithPath: "/tmp/pine-close-right-1-\(UUID().uuidString).swift")
        let extra2 = URL(fileURLWithPath: "/tmp/pine-close-right-2-\(UUID().uuidString).swift")
        try "a".write(to: extra1, atomically: true, encoding: .utf8)
        try "b".write(to: extra2, atomically: true, encoding: .utf8)
        secondTM.openTab(url: extra1)
        secondTM.openTab(url: extra2)
        #expect(secondTM.tabs.count == 3)

        guard let keepID = secondTM.tabs.first?.id else {
            Issue.record("keep tab missing")
            return
        }
        let provider = GitStatusProvider()
        await TabCloseHelper.closeTabsToTheRight(of: keepID, in: pm.activeTabManager, gitProvider: provider)

        #expect(secondTM.tabs.count == 1, "only the kept tab plus those left of it survive in the active pane")
        #expect(secondTM.tabs.first?.id == keepID)
        #expect(firstTM.tabs.count == 1, "primary pane must be untouched by active-pane close-to-the-right")
    }

    @Test("closeTabWithConfirmation closes only the active pane's tab")
    func closeTabRoutesToActivePaneOnly() throws {
        let f = try makeSplitWithTwoPanes()
        let pm = f.pm
        let firstTM = f.firstTM
        let secondTM = f.secondTM

        guard let activeTab = secondTM.activeTab else {
            Issue.record("active tab missing")
            return
        }
        let provider = GitStatusProvider()
        let closed = TabCloseHelper.closeTab(activeTab, in: pm.activeTabManager, gitProvider: provider)

        #expect(closed)
        #expect(secondTM.tabs.isEmpty, "the active pane's tab must be closed")
        #expect(firstTM.tabs.count == 1, "primary pane must be untouched by active-pane single close")
    }

    // MARK: - #971: navigateToChange result routing (review F1)
    //
    // ContentView.navigateToChange resolves the active tab, fetches fresh diffs
    // via diffForFileAsync, computes the next/previous change region through
    // GitLineDiff, then writes `activeTabManager.pendingGoToLine`. The async
    // fetch + re-entry guard (`currentTab.url == fileURL`) require a live git
    // repo and are integration/UI-test territory. Here we pin the routing
    // contract that the computed line lands in the active pane, never primary.

    @Test("navigateToChange routes its result to the active pane's pendingGoToLine")
    func navigateToChangeResultRoutesToActivePane() throws {
        let f = try makeSplitWithTwoPanes()
        let pm = f.pm
        let firstTM = f.firstTM
        let secondTM = f.secondTM

        // Simulate the freshly-fetched diffs + computation navigateToChange
        // performs, then mirror its final routing step.
        let diffs = [
            GitLineDiff(line: 5, kind: .added),
            GitLineDiff(line: 20, kind: .modified)
        ]
        let starts = GitLineDiff.changeRegionStarts(diffs)
        let target = GitLineDiff.nextChangeLine(from: 1, regionStarts: starts, diffs: diffs)

        #expect(target == 5, "from line 1 the next change region starts at line 5")

        if let line = target {
            pm.activeTabManager.pendingGoToLine = line
        }

        #expect(secondTM.pendingGoToLine == 5,
                "change-navigation result must land in the active pane")
        #expect(firstTM.pendingGoToLine == nil,
                "primary pane must not receive change-navigation (#971/#998)")
    }

    // MARK: - #971: handleInlineDiffAction routing (review F2)
    //
    // The .revert/.revertAll branches mutate `activeTabManager` via
    // updateContent(newContent) + reloadTab(url:). reloadTab re-syncs from disk
    // (an integration concern), so we assert the updateContent routing step in
    // isolation: mutating the active pane's content must not touch the primary.
    // The .accept/.acceptAll branches write through git and do not mutate any
    // TabManager, so they have no pane-routing surface to test at this layer.

    @Test("inline diff revert mutates only the active pane's tab content")
    func inlineDiffRevertRoutesToActivePaneOnly() throws {
        let f = try makeSplitWithTwoPanes()
        let pm = f.pm
        let firstTM = f.firstTM
        let secondTM = f.secondTM

        let originalFirst = firstTM.activeTab?.content
        #expect(secondTM.activeTab?.content == "second")
        #expect(originalFirst == "first")

        // Mirror handleInlineDiffAction(.revert)'s updateContent routing step.
        pm.activeTabManager.updateContent("reverted content")

        #expect(secondTM.activeTab?.content == "reverted content",
                "inline-diff revert must mutate the active pane's tab")
        #expect(firstTM.activeTab?.content == originalFirst,
                "primary pane's tab content must be untouched by active-pane inline diff")
    }

    // MARK: - #971: GoToLineView.onGoTo + symbolNavigate routing (review F4)
    //
    // Both the GoToLineView onGoTo closure and the .symbolNavigate handler end
    // with `activeTabManager.pendingGoToLine = line`. Pin the routing contract.

    @Test("Go-to-Line onGoTo routes to the active pane's pendingGoToLine")
    func goToLineOnGoToRoutesToActivePane() throws {
        let f = try makeSplitWithTwoPanes()
        let pm = f.pm
        let firstTM = f.firstTM
        let secondTM = f.secondTM

        // Mirror the onGoTo closure body: `activeTabManager.pendingGoToLine = line`.
        pm.activeTabManager.pendingGoToLine = 17

        #expect(secondTM.pendingGoToLine == 17, "go-to-line must land in the active pane")
        #expect(firstTM.pendingGoToLine == nil, "primary pane must not receive go-to-line")
    }

    // MARK: - #971: Go-to-Line column-discard contract (review F5)
    //
    // The Go-to-Line sheet still routes through the line-only compatibility
    // facade. Revision-owned diagnostic navigation uses
    // `pendingGoToLocation` and preserves its column independently.

    @Test("pendingGoToLine is line-only; column is discarded on go-to-line")
    func goToLineRoutesLineOnlyDiscardsColumn() throws {
        let f = try makeSplitWithTwoPanes()
        let pm = f.pm
        let secondTM = f.secondTM

        // The onGoTo closure writes only `line`; the compatibility setter
        // intentionally clears any previously pending column.
        pm.activeTabManager.pendingGoToLine = 9
        #expect(secondTM.pendingGoToLine == 9)
        #expect(secondTM.pendingGoToLocation?.column == nil)
        #expect(secondTM.pendingGoToLine == Optional(9),
                "pendingGoToLine remains the line-only compatibility facade")
    }

    @Test("cursorOffset(forLine:column:) honors column")
    func cursorOffsetHonorsColumnCapability() {
        let content = "abcdef\nghijkl\n"
        // Line 2 starts at offset 7 ('g'); column 4 lands on 'j' (offset 10).
        let lineStart = ContentView.cursorOffset(forLine: 2, in: content)
        let withColumn = ContentView.cursorOffset(forLine: 2, column: 4, in: content)

        #expect(lineStart == 7)
        #expect(withColumn == 10, "column-aware offset must point past the line start")
        #expect(withColumn != lineStart,
                "proves the exact diagnostic route can preserve its column")
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
