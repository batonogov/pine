//
//  TabCloseHelperBulkTests.swift
//  PineTests
//
//  Regression coverage for bulk-close outcomes and pane removal (#1169).
//

import AppKit
import Foundation
import Testing
@testable import Pine

@Suite("TabCloseHelper Bulk Close")
@MainActor
struct TabCloseHelperBulkTests {
    private struct PaneFixture {
        let paneManager: PaneManager
        let paneID: PaneID
        let tabManager: TabManager
    }

    private func makeDirtyPane(
        url: URL = URL(fileURLWithPath: "/tmp/pine-bulk-close-\(UUID().uuidString).swift"),
        content: String = "modified",
        savedContent: String = "original"
    ) -> PaneFixture? {
        let paneManager = PaneManager()
        let firstPaneID = paneManager.activePaneID
        guard let paneID = paneManager.splitPane(firstPaneID, axis: .horizontal),
              let tabManager = paneManager.tabManager(for: paneID) else {
            Issue.record("Failed to create the pane fixture")
            return nil
        }

        let tab = EditorTab(url: url, content: content, savedContent: savedContent)
        tabManager.tabs = [tab]
        tabManager.activeTabID = tab.id
        return PaneFixture(paneManager: paneManager, paneID: paneID, tabManager: tabManager)
    }

    private func removePaneAfterCompletedClose(_ didClose: Bool, fixture: PaneFixture) {
        if didClose && fixture.tabManager.tabs.isEmpty {
            fixture.paneManager.removePane(fixture.paneID)
        }
    }

    @Test("Don't Save completes close-all and permits empty-pane removal")
    func confirmedDiscardRemovesPane() async {
        guard let fixture = makeDirtyPane() else { return }
        var saveAttempted = false

        let didClose = await TabCloseHelper.closeAllTabs(
            in: fixture.tabManager,
            gitProvider: GitStatusProvider(),
            presentAlert: { .alertSecondButtonReturn },
            saveTab: { _ in
                saveAttempted = true
                return false
            }
        )
        removePaneAfterCompletedClose(didClose, fixture: fixture)

        #expect(didClose)
        #expect(!saveAttempted)
        #expect(fixture.tabManager.tabs.isEmpty)
        #expect(fixture.paneManager.tabManager(for: fixture.paneID) == nil)
        #expect(fixture.paneManager.root.leafCount == 1)
    }

    @Test("Save All persists changes, completes close-all, and permits pane removal")
    func saveSuccessRemovesPane() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-bulk-close-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("saved.swift")
        try "original".write(to: url, atomically: true, encoding: .utf8)
        guard let fixture = makeDirtyPane(url: url) else { return }

        guard let defaults = UserDefaults(
            suiteName: "TabCloseHelperBulkTests-\(UUID().uuidString)"
        ) else {
            Issue.record("Failed to create isolated defaults")
            return
        }
        let settings = EditorSettings(defaults: defaults)
        settings.insertFinalNewline = false
        settings.stripTrailingWhitespace = false
        settings.formatOnSave = false
        fixture.tabManager.editorSettings = settings

        let didClose = await TabCloseHelper.closeAllTabs(
            in: fixture.tabManager,
            gitProvider: GitStatusProvider(),
            presentAlert: { .alertFirstButtonReturn }
        )
        removePaneAfterCompletedClose(didClose, fixture: fixture)

        #expect(didClose)
        #expect(try String(contentsOf: url, encoding: .utf8) == "modified")
        #expect(fixture.paneManager.tabManager(for: fixture.paneID) == nil)
        #expect(fixture.paneManager.root.leafCount == 1)
    }

    @Test("Cancel aborts close-all and keeps the dirty pane accessible")
    func cancelPreservesPaneAndDirtyTab() async {
        guard let fixture = makeDirtyPane() else { return }

        let didClose = await TabCloseHelper.closeAllTabs(
            in: fixture.tabManager,
            gitProvider: GitStatusProvider(),
            presentAlert: { .alertThirdButtonReturn }
        )
        removePaneAfterCompletedClose(didClose, fixture: fixture)

        #expect(!didClose)
        #expect(fixture.paneManager.tabManager(for: fixture.paneID) === fixture.tabManager)
        #expect(fixture.paneManager.root.leafCount == 2)
        #expect(fixture.tabManager.tabs.count == 1)
        #expect(fixture.tabManager.tabs.first?.isDirty == true)
    }

    @Test("Save failure aborts close-all and keeps every tab accessible")
    func saveFailurePreservesPaneAndDirtyTabs() async {
        guard let fixture = makeDirtyPane() else { return }
        let secondTab = EditorTab(
            url: URL(fileURLWithPath: "/tmp/pine-bulk-close-\(UUID().uuidString).swift"),
            content: "second modified",
            savedContent: "second original"
        )
        fixture.tabManager.tabs.append(secondTab)
        var saveAttempts = 0

        let didClose = await TabCloseHelper.closeAllTabs(
            in: fixture.tabManager,
            gitProvider: GitStatusProvider(),
            presentAlert: { .alertFirstButtonReturn },
            saveTab: { index in
                saveAttempts += 1
                guard saveAttempts < 2 else { return false }
                let savedContent = fixture.tabManager.tabs[index].content
                fixture.tabManager.tabs[index].savedContent = savedContent
                return true
            }
        )
        removePaneAfterCompletedClose(didClose, fixture: fixture)

        #expect(!didClose)
        #expect(saveAttempts == 2)
        #expect(fixture.paneManager.tabManager(for: fixture.paneID) === fixture.tabManager)
        #expect(fixture.paneManager.root.leafCount == 2)
        #expect(fixture.tabManager.tabs.count == 2)
        #expect(fixture.tabManager.tabs[0].isDirty == false)
        #expect(fixture.tabManager.tabs[1].isDirty == true)
    }

    @Test("Clean close-all skips the alert and reports completion")
    func cleanTabsCloseWithoutAlert() async {
        let tabManager = TabManager()
        let tab = EditorTab(
            url: URL(fileURLWithPath: "/tmp/pine-clean-close-\(UUID().uuidString).swift"),
            content: "unchanged",
            savedContent: "unchanged"
        )
        tabManager.tabs = [tab]
        tabManager.activeTabID = tab.id
        var alertPresented = false

        let didClose = await TabCloseHelper.closeAllTabs(
            in: tabManager,
            gitProvider: GitStatusProvider(),
            presentAlert: {
                alertPresented = true
                return .alertThirdButtonReturn
            }
        )

        #expect(didClose)
        #expect(!alertPresented)
        #expect(tabManager.tabs.isEmpty)
    }

    @Test("Cancelled Close Others and Close Right report failure without mutation")
    func cancelledScopedBulkClosesPreserveTabs() async {
        let tabManager = TabManager()
        let first = EditorTab(
            url: URL(fileURLWithPath: "/tmp/pine-keep-\(UUID().uuidString).swift"),
            content: "unchanged",
            savedContent: "unchanged"
        )
        let second = EditorTab(
            url: URL(fileURLWithPath: "/tmp/pine-dirty-\(UUID().uuidString).swift"),
            content: "modified",
            savedContent: "original"
        )
        tabManager.tabs = [first, second]
        tabManager.activeTabID = second.id
        let provider = GitStatusProvider()

        let closedOthers = await TabCloseHelper.closeOtherTabs(
            keeping: first.id,
            in: tabManager,
            gitProvider: provider,
            presentAlert: { .alertThirdButtonReturn }
        )
        let closedRight = await TabCloseHelper.closeTabsToTheRight(
            of: first.id,
            in: tabManager,
            gitProvider: provider,
            presentAlert: { .alertThirdButtonReturn }
        )

        #expect(!closedOthers)
        #expect(!closedRight)
        #expect(tabManager.tabs.map(\.id) == [first.id, second.id])
        #expect(tabManager.tabs.last?.isDirty == true)
    }
}
