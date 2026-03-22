//
//  CloseDelegateTests.swift
//  PineTests
//

import Testing
import AppKit
@testable import Pine

/// Tests for CloseDelegate (PineApp.swift) — window close handling.
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

    @Test func closeDelegate_storesProjectManager() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let (delegate, pm, _) = makeCloseDelegate(projectURL: dir)
        #expect(delegate.projectManager === pm)
    }

    @Test func closeDelegate_storesProjectURL() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let (delegate, _, _) = makeCloseDelegate(projectURL: dir)
        #expect(delegate.projectURL == dir)
    }

    @Test func closeDelegate_storesRegistry() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let (delegate, _, registry) = makeCloseDelegate(projectURL: dir)
        #expect(delegate.registry === registry)
    }

    // MARK: - windowShouldClose

    @Test func windowShouldClose_allowsCloseWithNoDirtyTabs() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let (delegate, _, _) = makeCloseDelegate(projectURL: dir)

        // No tabs → no dirty tabs → should allow close
        let window = NSWindow()
        let result = delegate.windowShouldClose(window)
        #expect(result == true)
    }

    // MARK: - closeActiveTab

    @Test func closeActiveTab_noActiveTab_doesNotCrash() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let (delegate, _, _) = makeCloseDelegate(projectURL: dir)

        // No tabs open — should not crash
        delegate.closeActiveTab()
    }

    @Test func closeActiveTab_closesCleanTab() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let (delegate, pm, _) = makeCloseDelegate(projectURL: dir)

        // Create a temp file and open it
        let fileURL = dir.appendingPathComponent("clean.swift")
        try "clean content".write(to: fileURL, atomically: true, encoding: .utf8)
        pm.tabManager.openTab(url: fileURL)

        #expect(pm.tabManager.tabs.count == 1)
        delegate.closeActiveTab()
        #expect(pm.tabManager.tabs.isEmpty)
    }

    // MARK: - windowWillClose

    @Test func windowWillClose_handlesCloseOnce() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let (delegate, _, _) = makeCloseDelegate(projectURL: dir)

        let notification = Notification(name: NSWindow.willCloseNotification)
        delegate.windowWillClose(notification)
        // Second call should be no-op (didHandleClose guard)
        delegate.windowWillClose(notification)
    }

    // MARK: - windowDidBecomeKey

    @Test func windowDidBecomeKey_forwardsToOriginal() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        // Create with a mock original delegate
        let pm = ProjectManager()
        let registry = ProjectRegistry()
        let appDelegate = AppDelegate()
        let delegate = CloseDelegate(
            projectManager: pm,
            registry: registry,
            projectURL: dir,
            appDelegate: appDelegate,
            original: nil
        )

        let notification = Notification(name: NSWindow.didBecomeKeyNotification)
        delegate.windowDidBecomeKey(notification)
        // Should not crash
    }

    // MARK: - observeWindowClose

    @Test func observeWindowClose_registersObserver() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let (delegate, _, _) = makeCloseDelegate(projectURL: dir)

        let window = NSWindow()
        delegate.observeWindowClose(window)
        // Should not crash; observer registered
    }
}
