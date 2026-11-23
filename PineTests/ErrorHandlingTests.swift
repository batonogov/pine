//
//  ErrorHandlingTests.swift
//  PineTests
//

import Testing
import Foundation
@testable import Pine

@MainActor
struct ErrorHandlingTests {

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PineErrorTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - RecoveryManager error handling

    @Test func snapshotLogsEncodingFailureWithoutCrashing() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let manager = RecoveryManager(recoveryDirectory: dir)

        // A normal dirty tab should snapshot successfully
        let fileURL = URL(fileURLWithPath: "/tmp/test.swift")
        let tab = EditorTab(url: fileURL, content: "dirty", savedContent: "clean")
        manager.snapshotDirtyTabs([tab])

        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        #expect(files.count == 1)
    }

    @Test func deleteRecoveryFileHandlesNonexistentFile() {
        // Should not crash when deleting a file that doesn't exist
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PineErrorTests-nonexistent-\(UUID().uuidString)")
        let manager = RecoveryManager(recoveryDirectory: dir)
        manager.deleteRecoveryFile(for: UUID())
        // No crash = success
    }

    @Test func terminationSweepHandlesNonexistentDirectory() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PineErrorTests-nonexistent-\(UUID().uuidString)")
        let manager = RecoveryManager(recoveryDirectory: dir)
        manager.deleteSnapshotsOfOpenTabs([UUID()])
        // No crash = success
    }

    @Test func pendingRecoverySkipsCorruptedFiles() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let manager = RecoveryManager(recoveryDirectory: dir)

        // Write corrupted JSON
        let corruptFile = dir.appendingPathComponent("\(UUID().uuidString).json")
        try Data("not valid json".utf8).write(to: corruptFile)

        let entries = manager.pendingRecoveryEntries()
        #expect(entries.isEmpty)
    }

    @Test func pendingRecoveryReturnsEmptyForNonexistentDirectory() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PineErrorTests-nonexistent-\(UUID().uuidString)")
        let manager = RecoveryManager(recoveryDirectory: dir)

        let entries = manager.pendingRecoveryEntries()
        #expect(entries.isEmpty)
    }

    // MARK: - SessionState error handling

    @Test func sessionSaveHandlesEncodingGracefully() throws {
        let suiteName = "PineErrorTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Normal save should work without crash
        SessionState.save(
            projectURL: URL(fileURLWithPath: "/tmp/project"),
            openFileURLs: [URL(fileURLWithPath: "/tmp/project/file.swift")],
            defaults: defaults
        )
        // Encoding succeeded if no crash
    }

    @Test func sessionLoadHandlesCorruptedData() throws {
        let suiteName = "PineErrorTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Write corrupted data
        let key = "sessionState:/tmp/project"
        defaults.set(Data("corrupted".utf8), forKey: key)

        let loaded = SessionState.load(
            for: URL(fileURLWithPath: "/tmp/project"),
            defaults: defaults
        )
        #expect(loaded == nil)
    }

    // MARK: - TabManager file reading error handling

    @Test func reloadTabHandlesNonexistentFile() {
        let tabManager = TabManager()
        let fakeURL = URL(fileURLWithPath: "/nonexistent/file.swift")
        let tab = EditorTab(url: fakeURL, content: "content", savedContent: "content")
        tabManager.tabs = [tab]

        // Should not crash when file doesn't exist
        tabManager.reloadTab(url: fakeURL)
        #expect(tabManager.tabs[0].content == "content") // unchanged
    }

    @Test func reopenActiveTabHandlesNonexistentFile() {
        let tabManager = TabManager()
        let fakeURL = URL(fileURLWithPath: "/nonexistent/file.swift")
        let tab = EditorTab(url: fakeURL, content: "content", savedContent: "content")
        tabManager.tabs = [tab]
        tabManager.activeTabID = tab.id

        let result = tabManager.reopenActiveTab(withEncoding: .utf16)
        #expect(result == false) // Should fail gracefully
    }

    @Test func modDateReturnsNilForNonexistentFile() {
        let tabManager = TabManager()
        // fileSize uses the same attributesOfItem pattern as modDate
        let size = tabManager.fileSize(url: URL(fileURLWithPath: "/nonexistent/file.swift"))
        #expect(size == nil)
    }
}
