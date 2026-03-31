//
//  DockMenuTests.swift
//  PineTests
//

import AppKit
import Foundation
import Testing

@testable import Pine

@Suite("Dock Menu Tests")
@MainActor
struct DockMenuTests {

    private func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PineTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Creates a fresh AppDelegate with an isolated registry (no persisted recent projects).
    private func makeDelegate() -> AppDelegate {
        let delegate = AppDelegate()
        let registry = ProjectRegistry()
        registry.recentProjects = []
        delegate.registry = registry
        return delegate
    }

    // MARK: - Menu construction

    @Test func dockMenuReturnsNilWhenNoRecentProjects() {
        let delegate = makeDelegate()
        let menu = delegate.applicationDockMenu(NSApplication.shared)
        #expect(menu == nil)
    }

    @Test func dockMenuShowsRecentProjects() throws {
        let dir1 = try makeTempDirectory()
        let dir2 = try makeTempDirectory()
        defer {
            cleanup(dir1)
            cleanup(dir2)
        }

        let delegate = makeDelegate()
        _ = delegate.registry.projectManager(for: dir1)
        _ = delegate.registry.projectManager(for: dir2)

        let menu = delegate.applicationDockMenu(NSApplication.shared)
        #expect(menu != nil)
        guard let menu else { return }
        #expect(menu.items.count == 2)

        // Most recent project should be first
        let firstItem = menu.items[0]
        let canonical2 = dir2.resolvingSymlinksInPath()
        #expect(firstItem.title.contains(canonical2.lastPathComponent))
        #expect(firstItem.representedObject as? URL == canonical2)
    }

    @Test func dockMenuLimitsToTenProjects() throws {
        var dirs: [URL] = []
        defer { dirs.forEach { cleanup($0) } }

        let delegate = makeDelegate()
        for _ in 0..<12 {
            let dir = try makeTempDirectory()
            dirs.append(dir)
            _ = delegate.registry.projectManager(for: dir)
        }

        let menu = delegate.applicationDockMenu(NSApplication.shared)
        guard let menu else { return }
        #expect(menu.items.count == 10)
    }

    @Test func dockMenuItemsHaveCorrectTarget() throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }

        let delegate = makeDelegate()
        _ = delegate.registry.projectManager(for: dir)

        let menu = delegate.applicationDockMenu(NSApplication.shared)
        guard let menu else { return }
        let item = menu.items[0]
        #expect(item.target === delegate)
        #expect(item.action != nil)
    }

    @Test func dockMenuItemTitleContainsAbbreviatedPath() throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }

        let delegate = makeDelegate()
        _ = delegate.registry.projectManager(for: dir)

        let menu = delegate.applicationDockMenu(NSApplication.shared)
        guard let menu else { return }
        let item = menu.items[0]
        let canonical = dir.resolvingSymlinksInPath()
        #expect(item.title.contains(canonical.lastPathComponent))
        #expect(item.title.contains("—"))
    }

    @Test func dockMenuOrderMatchesRecentProjectsOrder() throws {
        let dir1 = try makeTempDirectory()
        let dir2 = try makeTempDirectory()
        let dir3 = try makeTempDirectory()
        defer {
            cleanup(dir1)
            cleanup(dir2)
            cleanup(dir3)
        }

        let delegate = makeDelegate()
        _ = delegate.registry.projectManager(for: dir1)
        _ = delegate.registry.projectManager(for: dir2)
        _ = delegate.registry.projectManager(for: dir3)

        let menu = delegate.applicationDockMenu(NSApplication.shared)
        guard let menu else { return }
        #expect(menu.items.count == 3)

        // recentProjects order: dir3 (most recent), dir2, dir1
        let canonical3 = dir3.resolvingSymlinksInPath()
        let canonical2 = dir2.resolvingSymlinksInPath()
        let canonical1 = dir1.resolvingSymlinksInPath()
        #expect(menu.items[0].representedObject as? URL == canonical3)
        #expect(menu.items[1].representedObject as? URL == canonical2)
        #expect(menu.items[2].representedObject as? URL == canonical1)
    }

    // MARK: - Menu item action

    @Test func dockMenuOpenProjectCallsOpenProjectWindow() throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }

        let delegate = makeDelegate()
        var openedURL: URL?
        delegate.openProjectWindow = { url in openedURL = url }

        let canonical = dir.resolvingSymlinksInPath()
        let item = NSMenuItem()
        item.representedObject = canonical

        delegate.dockMenuOpenProject(item)

        #expect(openedURL == canonical)
        #expect(delegate.registry.isProjectOpen(canonical))
    }

    @Test func dockMenuOpenProjectIgnoresInvalidRepresentedObject() {
        let delegate = makeDelegate()
        var openCalled = false
        delegate.openProjectWindow = { _ in openCalled = true }

        let item = NSMenuItem()
        item.representedObject = "not a URL"

        delegate.dockMenuOpenProject(item)
        #expect(!openCalled)
    }

    @Test func dockMenuOpenProjectIgnoresNilRepresentedObject() {
        let delegate = makeDelegate()
        var openCalled = false
        delegate.openProjectWindow = { _ in openCalled = true }

        let item = NSMenuItem()
        delegate.dockMenuOpenProject(item)
        #expect(!openCalled)
    }

    @Test func dockMenuOpenProjectHandlesDeletedDirectory() throws {
        let dir = try makeTempDirectory()
        let canonical = dir.resolvingSymlinksInPath()

        let delegate = makeDelegate()
        _ = delegate.registry.projectManager(for: canonical)

        // Delete the directory
        cleanup(dir)

        var openCalled = false
        delegate.openProjectWindow = { _ in openCalled = true }

        // Close to background so projectManager(for:) tries to recreate
        delegate.registry.closeProject(canonical)

        let item = NSMenuItem()
        item.representedObject = canonical

        delegate.dockMenuOpenProject(item)
        // Should not open — directory doesn't exist
        #expect(!openCalled)
    }

    @Test func dockMenuOpenProjectReopensBackgroundProject() throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }

        let canonical = dir.resolvingSymlinksInPath()
        let delegate = makeDelegate()
        _ = delegate.registry.projectManager(for: canonical)
        // Move to background (simulates window close)
        delegate.registry.closeProjectWindow(canonical)
        #expect(delegate.registry.backgroundProjects.contains(canonical))

        var openedURL: URL?
        delegate.openProjectWindow = { url in openedURL = url }

        let item = NSMenuItem()
        item.representedObject = canonical

        delegate.dockMenuOpenProject(item)

        #expect(openedURL == canonical)
        #expect(!delegate.registry.backgroundProjects.contains(canonical))
    }
}
