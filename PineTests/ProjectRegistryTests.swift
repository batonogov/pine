//
//  ProjectRegistryTests.swift
//  PineTests
//

import Foundation
import Testing

@testable import Pine

@Suite("ProjectRegistry Tests")
struct ProjectRegistryTests {

    private func makeTempDirectory() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PineTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Project creation

    @Test func projectManagerCreatesNewInstance() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        let registry = ProjectRegistry()
        let pm = registry.projectManager(for: tempDir)

        #expect(pm != nil)
        #expect(registry.openProjects.count >= 1)

        let canonical = tempDir.resolvingSymlinksInPath()
        #expect(registry.openProjects[canonical] != nil)
    }

    @Test func projectManagerReturnsSameInstanceForSameURL() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        let registry = ProjectRegistry()
        let pm1 = registry.projectManager(for: tempDir)
        let pm2 = registry.projectManager(for: tempDir)

        #expect(pm1 != nil)
        #expect(pm1 === pm2)
    }

    @Test func projectManagerDeduplicatesSymlinks() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        let symlinkDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PineTests-symlink-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: symlinkDir, withDestinationURL: tempDir)
        defer { cleanup(symlinkDir) }

        let registry = ProjectRegistry()
        let pm1 = registry.projectManager(for: tempDir)
        let pm2 = registry.projectManager(for: symlinkDir)

        #expect(pm1 != nil)
        #expect(pm1 === pm2)

        // Only one entry in openProjects despite two different URLs
        let canonical = tempDir.resolvingSymlinksInPath()
        #expect(registry.openProjects[canonical] === pm1)
    }

    @Test func projectManagerReturnsNilForDeletedDirectory() throws {
        let tempDir = try makeTempDirectory()
        let canonical = tempDir.resolvingSymlinksInPath()

        let registry = ProjectRegistry()

        // Open and close so it's in recent but not open
        let pm = registry.projectManager(for: tempDir)
        #expect(pm != nil)
        registry.closeProject(tempDir)
        #expect(registry.recentProjects.contains(canonical))

        // Delete directory, then try to open — must return nil
        cleanup(tempDir)
        let pm2 = registry.projectManager(for: tempDir)
        #expect(pm2 == nil)
    }

    // MARK: - Close

    @Test func closeProjectRemovesFromOpenProjects() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        let registry = ProjectRegistry()
        _ = registry.projectManager(for: tempDir)

        let canonical = tempDir.resolvingSymlinksInPath()
        #expect(registry.openProjects[canonical] != nil)

        registry.closeProject(tempDir)
        #expect(registry.openProjects[canonical] == nil)
    }

    @Test func closeAndReopenCreatesNewInstance() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        let registry = ProjectRegistry()
        let pm1 = registry.projectManager(for: tempDir)
        registry.closeProject(tempDir)
        let pm2 = registry.projectManager(for: tempDir)

        #expect(pm1 != nil)
        #expect(pm2 != nil)
        #expect(pm1 !== pm2)
    }

    // MARK: - Recent projects

    @Test func recentProjectsAddedOnOpen() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        let registry = ProjectRegistry()
        _ = registry.projectManager(for: tempDir)

        let canonical = tempDir.resolvingSymlinksInPath()
        #expect(registry.recentProjects.contains(canonical))
        #expect(registry.recentProjects.first == canonical)
    }

    @Test func recentProjectsLimitedToMax() throws {
        var dirs: [URL] = []
        for _ in 0..<12 {
            dirs.append(try makeTempDirectory())
        }
        defer { dirs.forEach { cleanup($0) } }

        let registry = ProjectRegistry()
        for dir in dirs {
            _ = registry.projectManager(for: dir)
        }

        #expect(registry.recentProjects.count <= 10)

        // Most recent should be last opened
        let lastCanonical = try #require(dirs.last).resolvingSymlinksInPath()
        #expect(registry.recentProjects.first == lastCanonical)

        // First two should have been pushed out
        let firstCanonical = dirs[0].resolvingSymlinksInPath()
        let secondCanonical = dirs[1].resolvingSymlinksInPath()
        #expect(!registry.recentProjects.contains(firstCanonical))
        #expect(!registry.recentProjects.contains(secondCanonical))
    }

    @Test func recentProjectsNotRemovedOnClose() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        let registry = ProjectRegistry()
        _ = registry.projectManager(for: tempDir)

        let canonical = tempDir.resolvingSymlinksInPath()
        registry.closeProject(tempDir)

        // Close removes from openProjects but NOT from recentProjects
        #expect(registry.openProjects[canonical] == nil)
        #expect(registry.recentProjects.contains(canonical))
    }

    // MARK: - isProjectOpen

    @Test func isProjectOpenReflectsState() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        let registry = ProjectRegistry()
        #expect(!registry.isProjectOpen(tempDir))

        _ = registry.projectManager(for: tempDir)
        #expect(registry.isProjectOpen(tempDir))

        registry.closeProject(tempDir)
        #expect(!registry.isProjectOpen(tempDir))
    }
}
