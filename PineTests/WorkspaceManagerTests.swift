//
//  WorkspaceManagerTests.swift
//  PineTests
//
//  Created by Claude on 14.03.2026.
//

import Foundation
import Testing

@testable import Pine

@Suite("WorkspaceManager Tests")
struct WorkspaceManagerTests {

    private func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    @Test("Initial state has empty rootNodes and default project name")
    func initialState() {
        let manager = WorkspaceManager()
        #expect(manager.rootNodes.isEmpty)
        #expect(manager.projectName == "Pine")
        #expect(manager.rootURL == nil)
        #expect(manager.externalChangeToken == 0)
    }

    @Test("loadDirectory sets rootURL and projectName")
    func loadDirectorySetsProperties() throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }

        let manager = WorkspaceManager()
        manager.loadDirectory(url: dir)

        #expect(manager.rootURL == dir)
        #expect(manager.projectName == dir.lastPathComponent)
    }

    @Test("loadDirectory clears previous state immediately")
    func loadDirectoryClearsState() throws {
        let dir1 = try makeTempDirectory()
        let dir2 = try makeTempDirectory()
        defer { cleanup(dir1); cleanup(dir2) }

        // Create a file in dir1 so it has children
        try "content".write(
            to: dir1.appendingPathComponent("file.txt"),
            atomically: true,
            encoding: .utf8
        )

        let manager = WorkspaceManager()
        manager.loadDirectory(url: dir1)

        // Now load dir2 — should clear state immediately (synchronous)
        manager.loadDirectory(url: dir2)

        // rootNodes should be cleared synchronously
        #expect(manager.rootNodes.isEmpty)
        #expect(manager.rootURL == dir2)
        #expect(manager.gitProvider.isGitRepository == false)
        #expect(manager.gitProvider.currentBranch == "")
        #expect(manager.gitProvider.fileStatuses.isEmpty)
        #expect(manager.gitProvider.branches.isEmpty)
    }

    @Test("refreshFileTree reloads children from disk")
    func refreshFileTree() throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }

        let manager = WorkspaceManager()
        manager.loadDirectory(url: dir)
        // Sync refresh to populate from empty dir
        manager.refreshFileTree()

        // Initially empty directory
        #expect(manager.rootNodes.isEmpty)

        // Create a file
        try "hello".write(
            to: dir.appendingPathComponent("newfile.txt"),
            atomically: true,
            encoding: .utf8
        )

        // Refresh should pick it up
        manager.refreshFileTree()
        #expect(manager.rootNodes.count == 1)
        #expect(manager.rootNodes.first?.url.lastPathComponent == "newfile.txt")
    }

    @Test("refreshFileTree does nothing without rootURL")
    func refreshFileTreeNoRoot() {
        let manager = WorkspaceManager()
        manager.refreshFileTree()
        #expect(manager.rootNodes.isEmpty)
    }

    @Test("loadDirectory then refreshFileTree populates rootNodes")
    func loadDirectoryThenRefreshPopulatesNodes() throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }

        try "a".write(to: dir.appendingPathComponent("alpha.txt"), atomically: true, encoding: .utf8)
        try "b".write(to: dir.appendingPathComponent("beta.txt"), atomically: true, encoding: .utf8)

        let manager = WorkspaceManager()
        manager.loadDirectory(url: dir)

        // Async load dispatches to main which we can't easily await in tests.
        // Use synchronous refreshFileTree instead (rootURL is already set).
        manager.refreshFileTree()

        #expect(manager.rootNodes.count == 2)
    }

    @Test("loadDirectory twice quickly uses latest directory")
    func loadDirectoryRaceProtection() throws {
        let dir1 = try makeTempDirectory()
        let dir2 = try makeTempDirectory()
        defer { cleanup(dir1); cleanup(dir2) }

        // Create different files to distinguish
        try "a".write(to: dir1.appendingPathComponent("from_dir1.txt"), atomically: true, encoding: .utf8)
        try "b".write(to: dir2.appendingPathComponent("from_dir2.txt"), atomically: true, encoding: .utf8)

        let manager = WorkspaceManager()
        manager.loadDirectory(url: dir1)
        manager.loadDirectory(url: dir2) // Immediately switch

        // Synchronous properties should reflect dir2
        #expect(manager.rootURL == dir2)
        #expect(manager.projectName == dir2.lastPathComponent)

        // Use synchronous refresh to load dir2 content
        manager.refreshFileTree()
        let names = manager.rootNodes.map(\.url.lastPathComponent)
        #expect(names.contains("from_dir2.txt"))
        #expect(!names.contains("from_dir1.txt"))
    }
}
