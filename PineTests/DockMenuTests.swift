//
//  DockMenuTests.swift
//  PineTests
//

import AppKit
import Foundation
import Testing

@testable import Pine

@Suite("Dock Menu Tests")
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

    @Test func dockMenuReturnsNilWhenNoRecentProjects() {
        let delegate = AppDelegate()
        delegate.registry = ProjectRegistry()
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

        let registry = ProjectRegistry()
        _ = registry.projectManager(for: dir1)
        _ = registry.projectManager(for: dir2)

        let delegate = AppDelegate()
        delegate.registry = registry

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

        let registry = ProjectRegistry()
        for _ in 0..<12 {
            let dir = try makeTempDirectory()
            dirs.append(dir)
            _ = registry.projectManager(for: dir)
        }

        let delegate = AppDelegate()
        delegate.registry = registry

        let menu = delegate.applicationDockMenu(NSApplication.shared)
        guard let menu else { return }
        #expect(menu.items.count == 10)
    }

    @Test func dockMenuItemsHaveCorrectTarget() throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }

        let registry = ProjectRegistry()
        _ = registry.projectManager(for: dir)

        let delegate = AppDelegate()
        delegate.registry = registry

        let menu = delegate.applicationDockMenu(NSApplication.shared)
        guard let menu else { return }
        let item = menu.items[0]
        #expect(item.target === delegate)
        #expect(item.action != nil)
    }

    @Test func dockMenuItemTitleContainsAbbreviatedPath() throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }

        let registry = ProjectRegistry()
        _ = registry.projectManager(for: dir)

        let delegate = AppDelegate()
        delegate.registry = registry

        let menu = delegate.applicationDockMenu(NSApplication.shared)
        guard let menu else { return }
        let item = menu.items[0]
        let canonical = dir.resolvingSymlinksInPath()
        #expect(item.title.contains(canonical.lastPathComponent))
        #expect(item.title.contains("—"))
    }
}
