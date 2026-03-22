//
//  RecoveryManagerExtendedTests.swift
//  PineTests
//

import Testing
import Foundation
@testable import Pine

/// Extended tests for RecoveryManager — hasPendingRecovery, timer, scheduling, cleanup.
@Suite("RecoveryManager Extended Tests")
struct RecoveryManagerExtendedTests {

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PineRecoveryExtTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func makeDirtyTab(content: String = "dirty") -> EditorTab {
        let url = URL(fileURLWithPath: "/tmp/test-\(UUID().uuidString).swift")
        return EditorTab(url: url, content: content, savedContent: "saved")
    }

    // MARK: - hasPendingRecovery

    @Test func hasPendingRecovery_falseWhenEmpty() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let manager = RecoveryManager(recoveryDirectory: dir)
        #expect(manager.hasPendingRecovery == false)
    }

    @Test func hasPendingRecovery_falseWhenDirDoesNotExist() {
        let dir = URL(fileURLWithPath: "/tmp/nonexistent-\(UUID().uuidString)")
        let manager = RecoveryManager(recoveryDirectory: dir)
        #expect(manager.hasPendingRecovery == false)
    }

    @Test func hasPendingRecovery_trueAfterSnapshot() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let manager = RecoveryManager(recoveryDirectory: dir)

        manager.snapshotDirtyTabs([makeDirtyTab()])
        #expect(manager.hasPendingRecovery == true)
    }

    @Test func hasPendingRecovery_falseAfterDeleteAll() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let manager = RecoveryManager(recoveryDirectory: dir)

        manager.snapshotDirtyTabs([makeDirtyTab()])
        #expect(manager.hasPendingRecovery == true)

        manager.deleteAllRecoveryFiles()
        #expect(manager.hasPendingRecovery == false)
    }

    @Test func hasPendingRecovery_ignoresNonJsonFiles() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        // Write non-json file
        try Data("notes".utf8).write(to: dir.appendingPathComponent("notes.txt"))

        let manager = RecoveryManager(recoveryDirectory: dir)
        #expect(manager.hasPendingRecovery == false)
    }

    // MARK: - Timer and scheduling edge cases

    @Test func timerAndSchedulingEdgeCases() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let manager = RecoveryManager(recoveryDirectory: dir)
        manager.tabsProvider = { [self.makeDirtyTab()] }

        // Start/stop/restart periodic snapshots
        manager.startPeriodicSnapshots()
        manager.startPeriodicSnapshots() // restart — stops old timer
        manager.stopPeriodicSnapshots()
        manager.stopPeriodicSnapshots() // idempotent stop

        // Schedule/cancel debounced snapshots
        manager.cancelScheduledSnapshot() // no-op when nothing pending
        manager.scheduleSnapshot()
        manager.scheduleSnapshot() // replaces previous
        manager.cancelScheduledSnapshot()
    }

    // MARK: - tabsProvider

    @Test func tabsProvider_usedByPeriodicTimer() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let manager = RecoveryManager(recoveryDirectory: dir)

        var providerCalled = false
        manager.tabsProvider = {
            providerCalled = true
            return []
        }

        // Directly invoke what the timer would do
        manager.snapshotDirtyTabs(manager.tabsProvider?() ?? [])
        #expect(providerCalled)
    }

    // MARK: - Static constants

    @Test func periodicInterval_is30() {
        #expect(RecoveryManager.periodicInterval == 30)
    }

    @Test func debounceDelay_is5() {
        #expect(RecoveryManager.debounceDelay == 5)
    }

    // MARK: - Project directory hash

    @Test func directory_isDeterministic() {
        let url = URL(fileURLWithPath: "/Users/test/project")
        let dir1 = RecoveryManager.directory(for: url)
        let dir2 = RecoveryManager.directory(for: url)
        #expect(dir1 == dir2)
    }

    @Test func directory_underRootDirectory() {
        let url = URL(fileURLWithPath: "/Users/test/project")
        let dir = RecoveryManager.directory(for: url)
        #expect(dir.path.hasPrefix(RecoveryManager.rootDirectory.path))
    }

    @Test func rootDirectory_isUnderApplicationSupport() {
        let root = RecoveryManager.rootDirectory
        #expect(root.path.contains("Application Support"))
        #expect(root.path.contains("Pine/Recovery"))
    }

    // MARK: - Convenience init

    @Test func convenienceInit_createsCorrectDirectory() {
        let url = URL(fileURLWithPath: "/Users/test/project")
        let manager = RecoveryManager(projectURL: url)
        // Should not crash; directory is set
        #expect(manager.pendingRecoveryEntries().isEmpty)
    }

    // MARK: - cleanupAllStaleEntries

    @Test func cleanupAllStaleEntries_removesOldAcrossProjects() throws {
        let root = try makeTempDir()
        defer { cleanup(root) }

        // Create two "project" subdirectories
        let projA = root.appendingPathComponent("proj-a")
        let projB = root.appendingPathComponent("proj-b")
        try FileManager.default.createDirectory(at: projA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projB, withIntermediateDirectories: true)

        // Write old recovery entries in both
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let oldEntry = RecoveryEntry(
            originalPath: "/tmp/old.swift",
            content: "old",
            timestamp: Date().addingTimeInterval(-10 * 24 * 3600), // 10 days ago
            encoding: .utf8
        )
        let data = try encoder.encode(oldEntry)

        try data.write(to: projA.appendingPathComponent("\(UUID().uuidString).json"))
        try data.write(to: projB.appendingPathComponent("\(UUID().uuidString).json"))

        // Verify both have entries
        let mgrA = RecoveryManager(recoveryDirectory: projA)
        let mgrB = RecoveryManager(recoveryDirectory: projB)
        #expect(mgrA.pendingRecoveryEntries().count == 1)
        #expect(mgrB.pendingRecoveryEntries().count == 1)

        // Clean up with custom root (we can't use the static method directly
        // since it uses a fixed root, but we can test individual cleanup)
        mgrA.cleanupStaleEntries(olderThan: 7)
        mgrB.cleanupStaleEntries(olderThan: 7)

        #expect(mgrA.pendingRecoveryEntries().isEmpty)
        #expect(mgrB.pendingRecoveryEntries().isEmpty)
    }

    @Test func cleanupStaleEntries_keepsNewAndRemovesOld() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        // Old entry (10 days ago)
        let oldEntry = RecoveryEntry(
            originalPath: "/tmp/old.swift",
            content: "old",
            timestamp: Date().addingTimeInterval(-10 * 24 * 3600),
            encoding: .utf8
        )
        let oldID = UUID()
        try encoder.encode(oldEntry).write(to: dir.appendingPathComponent("\(oldID.uuidString).json"))

        // New entry (just now)
        let manager = RecoveryManager(recoveryDirectory: dir)
        let newTab = makeDirtyTab()
        manager.snapshotDirtyTabs([newTab])

        #expect(manager.pendingRecoveryEntries().count == 2)

        manager.cleanupStaleEntries(olderThan: 7)

        let remaining = manager.pendingRecoveryEntries()
        #expect(remaining.count == 1)
        #expect(remaining[0].0 == newTab.id)
    }

    // MARK: - Edge cases

    @Test func deleteAllRecoveryFiles_noOpOnEmptyDirectory() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let manager = RecoveryManager(recoveryDirectory: dir)
        manager.deleteAllRecoveryFiles() // Should not crash
    }

    @Test func deleteAllRecoveryFiles_noOpOnNonExistentDirectory() {
        let dir = URL(fileURLWithPath: "/tmp/nonexistent-\(UUID().uuidString)")
        let manager = RecoveryManager(recoveryDirectory: dir)
        manager.deleteAllRecoveryFiles() // Should not crash
    }

    @Test func cleanupStaleEntries_noOpOnNonExistentDirectory() {
        let dir = URL(fileURLWithPath: "/tmp/nonexistent-\(UUID().uuidString)")
        let manager = RecoveryManager(recoveryDirectory: dir)
        manager.cleanupStaleEntries(olderThan: 7) // Should not crash
    }
}
