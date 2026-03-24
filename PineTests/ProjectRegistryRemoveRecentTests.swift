//
//  ProjectRegistryRemoveRecentTests.swift
//  PineTests
//

import Testing
import Foundation
@testable import Pine

/// Tests for ProjectRegistry.removeFromRecent(_:) — removing individual entries from recent projects.
@Suite("ProjectRegistry Remove Recent Tests")
struct ProjectRegistryRemoveRecentTests {

    private func makeTempDir(name: String = "RemoveRecentTests") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Pine\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        // Return canonical URL so tests match what ProjectRegistry stores internally
        return url.resolvingSymlinksInPath()
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - removeFromRecent

    @Test("Remove existing project from recent list")
    func removeExistingProject() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let registry = ProjectRegistry()
        // Open project to add it to recents
        _ = registry.projectManager(for: dir)
        #expect(registry.recentProjects.contains(dir))

        registry.removeFromRecent(dir)
        #expect(!registry.recentProjects.contains(dir))
    }

    @Test("Remove non-existent project from recent list is no-op")
    func removeNonExistentProject() {
        let registry = ProjectRegistry()
        let fakeURL = URL(fileURLWithPath: "/tmp/non-existent-\(UUID().uuidString)")
        let before = registry.recentProjects

        registry.removeFromRecent(fakeURL)
        #expect(registry.recentProjects == before)
    }

    @Test("Remove one project preserves other recents")
    func removePreservesOtherRecents() throws {
        let dir1 = try makeTempDir(name: "A")
        let dir2 = try makeTempDir(name: "B")
        let dir3 = try makeTempDir(name: "C")
        defer {
            cleanup(dir1)
            cleanup(dir2)
            cleanup(dir3)
        }

        let registry = ProjectRegistry()
        _ = registry.projectManager(for: dir1)
        _ = registry.projectManager(for: dir2)
        _ = registry.projectManager(for: dir3)

        // Remove only dir2
        registry.removeFromRecent(dir2)

        #expect(registry.recentProjects.contains(dir1))
        #expect(!registry.recentProjects.contains(dir2))
        #expect(registry.recentProjects.contains(dir3))
    }

    @Test("Remove persists to UserDefaults")
    func removePersistsToDefaults() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let registry = ProjectRegistry()
        _ = registry.projectManager(for: dir)
        #expect(registry.recentProjects.contains(dir))

        registry.removeFromRecent(dir)

        // Create new registry to load from UserDefaults
        let registry2 = ProjectRegistry()
        #expect(!registry2.recentProjects.contains(dir))
    }

    @Test("Remove matches by exact URL equality")
    func removeMatchesByExactURL() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let registry = ProjectRegistry()
        _ = registry.projectManager(for: dir)

        // Remove using an equivalent URL object (same canonical path)
        let sameDir = URL(fileURLWithPath: dir.path)
        registry.removeFromRecent(sameDir)
        #expect(!registry.recentProjects.contains(dir))
    }
}
