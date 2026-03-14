//
//  WindowLifecycleTests.swift
//  PineTests
//

import AppKit
import Foundation
import Testing

@testable import Pine

@Suite("Window Lifecycle Tests")
struct WindowLifecycleTests {

    private func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PineTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeTempFile(in dir: URL, name: String = "test.swift") throws -> URL {
        let file = dir.appendingPathComponent(name)
        try "// \(name)".write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - onDisappear logic (handleProjectWindowDisappear)

    @Test func closingLastProjectTriggersShowWelcome() throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }

        let registry = ProjectRegistry()
        _ = registry.projectManager(for: dir)

        let delegate = AppDelegate()
        var welcomeCalled = false
        delegate.openNamedWindow = { id in
            if id == "welcome" { welcomeCalled = true }
        }

        delegate.handleProjectWindowDisappear(projectURL: dir, registry: registry)

        #expect(registry.openProjects.isEmpty)
        #expect(welcomeCalled)
    }

    @Test func closingNonLastProjectDoesNotShowWelcome() throws {
        let dir1 = try makeTempDirectory()
        let dir2 = try makeTempDirectory()
        defer { cleanup(dir1); cleanup(dir2) }

        let registry = ProjectRegistry()
        _ = registry.projectManager(for: dir1)
        _ = registry.projectManager(for: dir2)

        let delegate = AppDelegate()
        var welcomeCalled = false
        delegate.openNamedWindow = { id in
            if id == "welcome" { welcomeCalled = true }
        }

        delegate.handleProjectWindowDisappear(projectURL: dir1, registry: registry)

        #expect(registry.openProjects.count == 1)
        #expect(!welcomeCalled)
    }

    @Test func sessionSavedBeforeProjectClosed() throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }
        let file = try makeTempFile(in: dir)

        let registry = ProjectRegistry()
        let pm = try #require(registry.projectManager(for: dir))
        pm.tabManager.openTab(url: file)

        let delegate = AppDelegate()
        delegate.openNamedWindow = { _ in }
        delegate.handleProjectWindowDisappear(projectURL: dir, registry: registry)

        // Project removed from registry
        #expect(registry.openProjects.isEmpty)

        // But session was saved BEFORE close — it must be loadable
        let canonical = dir.resolvingSymlinksInPath()
        let session = SessionState.load(for: canonical)
        #expect(session != nil)
        #expect(session?.existingFileURLs.count == 1)
        #expect(session?.existingFileURLs.first == file)
    }

    // MARK: - Termination

    @Test func terminationSavesAllProjectSessions() throws {
        let dir1 = try makeTempDirectory()
        let dir2 = try makeTempDirectory()
        defer { cleanup(dir1); cleanup(dir2) }

        let file1 = try makeTempFile(in: dir1, name: "a.swift")
        let file2 = try makeTempFile(in: dir2, name: "b.swift")

        let registry = ProjectRegistry()
        let pm1 = try #require(registry.projectManager(for: dir1))
        let pm2 = try #require(registry.projectManager(for: dir2))
        pm1.tabManager.openTab(url: file1)
        pm2.tabManager.openTab(url: file2)

        let delegate = AppDelegate()
        delegate.registry = registry

        // Simulate applicationWillTerminate
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))

        // Both sessions saved
        let session1 = SessionState.load(for: dir1.resolvingSymlinksInPath())
        let session2 = SessionState.load(for: dir2.resolvingSymlinksInPath())
        #expect(session1?.existingFileURLs.count == 1)
        #expect(session2?.existingFileURLs.count == 1)
    }

    // MARK: - windowShouldClose (CloseDelegate)

    @Test func windowShouldCloseReturnsTrueWhenNoTabs() throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }

        let registry = ProjectRegistry()
        let pm = try #require(registry.projectManager(for: dir))
        let delegate = AppDelegate()
        let window = NSWindow()

        let closeDelegate = Pine.CloseDelegate(
            projectManager: pm,
            registry: registry,
            projectURL: dir,
            appDelegate: delegate,
            original: nil
        )

        // No tabs open — window should close
        #expect(closeDelegate.windowShouldClose(window))
    }

    @Test func windowShouldCloseReturnsTrueWithCleanTabs() throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }
        let file = try makeTempFile(in: dir)

        let registry = ProjectRegistry()
        let pm = try #require(registry.projectManager(for: dir))
        pm.tabManager.openTab(url: file)

        let delegate = AppDelegate()
        let window = NSWindow()

        let closeDelegate = Pine.CloseDelegate(
            projectManager: pm,
            registry: registry,
            projectURL: dir,
            appDelegate: delegate,
            original: nil
        )

        // Clean tabs — window should close (not close tab one by one)
        #expect(closeDelegate.windowShouldClose(window))
        // Tabs should NOT have been closed individually
        #expect(pm.tabManager.tabs.count == 1)
    }

    @Test func windowShouldCloseDoesNotCloseIndividualCleanTab() throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }
        let file1 = try makeTempFile(in: dir, name: "a.swift")
        let file2 = try makeTempFile(in: dir, name: "b.swift")

        let registry = ProjectRegistry()
        let pm = try #require(registry.projectManager(for: dir))
        pm.tabManager.openTab(url: file1)
        pm.tabManager.openTab(url: file2)

        let delegate = AppDelegate()
        let window = NSWindow()

        let closeDelegate = Pine.CloseDelegate(
            projectManager: pm,
            registry: registry,
            projectURL: dir,
            appDelegate: delegate,
            original: nil
        )

        // With multiple clean tabs, should close window (return true)
        // and NOT close tabs one by one
        #expect(closeDelegate.windowShouldClose(window))
        #expect(pm.tabManager.tabs.count == 2)
    }

    // MARK: - showWelcome

    @Test func showWelcomeCallsOpenNamedWindow() throws {
        let delegate = AppDelegate()
        var openedWindowID: String?
        delegate.openNamedWindow = { id in
            openedWindowID = id
        }

        delegate.showWelcome()

        #expect(openedWindowID == "welcome")
    }
}
