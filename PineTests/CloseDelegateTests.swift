//
//  CloseDelegateTests.swift
//  PineTests
//

import Testing
import AppKit
@testable import Pine

/// Tests for CloseDelegate (PineApp.swift) — window close handling.
@Suite("CloseDelegate Tests")
struct CloseDelegateTests {

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PineCloseDelegateTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func makeCloseDelegate(projectURL: URL) -> (CloseDelegate, ProjectManager, ProjectRegistry) {
        let pm = ProjectManager()
        let registry = ProjectRegistry()
        let appDelegate = AppDelegate()
        let delegate = CloseDelegate(
            projectManager: pm,
            registry: registry,
            projectURL: projectURL,
            appDelegate: appDelegate,
            original: nil
        )
        return (delegate, pm, registry)
    }

    // MARK: - Initialization

    @Test func closeDelegateStoresReferences() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let (delegate, pm, registry) = makeCloseDelegate(projectURL: dir)
        #expect(delegate.projectManager === pm)
        #expect(delegate.registry === registry)
        #expect(delegate.projectURL == dir)
    }

    // MARK: - windowShouldClose

    @Test func windowShouldCloseAllowsWithNoDirtyTabs() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let (delegate, _, _) = makeCloseDelegate(projectURL: dir)

        let window = NSWindow()
        #expect(delegate.windowShouldClose(window) == true)
    }

    // MARK: - closeActiveTab

    @Test func closeActiveTabNoOpWithoutTabs() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let (delegate, pm, _) = makeCloseDelegate(projectURL: dir)

        #expect(pm.tabManager.tabs.isEmpty)
        delegate.closeActiveTab()
        #expect(pm.tabManager.tabs.isEmpty)
    }

    @Test func closeActiveTabClosesCleanTab() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let (delegate, pm, _) = makeCloseDelegate(projectURL: dir)

        let fileURL = dir.appendingPathComponent("clean.swift")
        try "clean content".write(to: fileURL, atomically: true, encoding: .utf8)
        pm.tabManager.openTab(url: fileURL)

        #expect(pm.tabManager.tabs.count == 1)
        delegate.closeActiveTab()
        #expect(pm.tabManager.tabs.isEmpty)
    }

    // MARK: - windowWillClose idempotency

    @Test func windowWillCloseHandlesOnlyOnce() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let (delegate, _, _) = makeCloseDelegate(projectURL: dir)

        let notification = Notification(name: NSWindow.willCloseNotification)
        delegate.windowWillClose(notification)
        // Second call is guarded by didHandleClose — should be no-op
        delegate.windowWillClose(notification)
    }

    // MARK: - closeActiveTab removes empty pane

    @Test func closeActiveTabRemovesEmptyPane() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let (delegate, pm, _) = makeCloseDelegate(projectURL: dir)

        let pane = pm.paneManager
        let firstPaneID = pane.activePaneID

        // Open a tab in the first pane so it stays alive
        let url1 = dir.appendingPathComponent("keep.swift")
        try "keep".write(to: url1, atomically: true, encoding: .utf8)
        pane.tabManager(for: firstPaneID)?.openTab(url: url1)

        // Split to create a second pane
        guard let secondPaneID = pane.splitPane(firstPaneID, axis: .horizontal) else {
            Issue.record("Split failed")
            return
        }
        let url2 = dir.appendingPathComponent("remove.swift")
        try "remove".write(to: url2, atomically: true, encoding: .utf8)
        pane.tabManager(for: secondPaneID)?.openTab(url: url2)
        pane.activePaneID = secondPaneID

        #expect(pane.root.leafCount == 2)

        // Close the only tab in the active (second) pane via CloseDelegate
        delegate.closeActiveTab()

        // The empty pane should have been removed
        #expect(pane.root.leafCount == 1)
        #expect(pane.tabManagers[secondPaneID] == nil)
    }

    @Test func closeActiveTabDoesNotRemovePaneWithRemainingTabs() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let (delegate, pm, _) = makeCloseDelegate(projectURL: dir)

        let pane = pm.paneManager
        let firstPaneID = pane.activePaneID

        // Open a tab in the first pane
        let url1 = dir.appendingPathComponent("keep1.swift")
        try "keep1".write(to: url1, atomically: true, encoding: .utf8)
        pane.tabManager(for: firstPaneID)?.openTab(url: url1)

        // Split to create a second pane with two tabs
        guard let secondPaneID = pane.splitPane(firstPaneID, axis: .horizontal) else {
            Issue.record("Split failed")
            return
        }
        let url2 = dir.appendingPathComponent("stay.swift")
        try "stay".write(to: url2, atomically: true, encoding: .utf8)
        let url3 = dir.appendingPathComponent("close.swift")
        try "close".write(to: url3, atomically: true, encoding: .utf8)
        pane.tabManager(for: secondPaneID)?.openTab(url: url2)
        pane.tabManager(for: secondPaneID)?.openTab(url: url3)
        pane.activePaneID = secondPaneID

        #expect(pane.root.leafCount == 2)

        // Close one tab — pane should remain since it still has a tab
        delegate.closeActiveTab()

        #expect(pane.root.leafCount == 2)
        #expect(pane.tabManagers[secondPaneID] != nil)
    }

    // MARK: - observeWindowClose

    @Test func observeWindowCloseRegistersNotification() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let (delegate, _, _) = makeCloseDelegate(projectURL: dir)

        let window = NSWindow()
        delegate.observeWindowClose(window)
        // Observer registered; cleanup in deinit
    }
}
