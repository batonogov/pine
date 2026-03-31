//
//  RecoveryManagerTests.swift
//  PineTests
//

import Testing
import Foundation
@testable import Pine

@MainActor
struct RecoveryManagerTests {

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PineRecoveryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func makeDirtyTab(
        url: URL? = nil,
        content: String = "unsaved content",
        savedContent: String = "saved content",
        encoding: String.Encoding = .utf8
    ) -> EditorTab {
        let fileURL = url ?? URL(fileURLWithPath: "/tmp/test.swift")
        var tab = EditorTab(url: fileURL, content: content, savedContent: savedContent)
        tab.encoding = encoding
        return tab
    }

    private func makeCleanTab(url: URL? = nil) -> EditorTab {
        let fileURL = url ?? URL(fileURLWithPath: "/tmp/clean.swift")
        return EditorTab(url: fileURL, content: "same", savedContent: "same")
    }

    // MARK: - Snapshot dirty tabs

    @Test func snapshotCreatesRecoveryFileForDirtyTab() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let manager = RecoveryManager(recoveryDirectory: dir)

        let tab = makeDirtyTab()
        manager.snapshotDirtyTabs([tab])

        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        #expect(files.count == 1)
        #expect(files[0].lastPathComponent == "\(tab.id.uuidString).json")
    }

    @Test func snapshotContainsCorrectContent() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let manager = RecoveryManager(recoveryDirectory: dir)

        let tab = makeDirtyTab(
            url: URL(fileURLWithPath: "/Users/test/file.swift"),
            content: "modified code",
            encoding: .utf16
        )
        manager.snapshotDirtyTabs([tab])

        let entries = manager.pendingRecoveryEntries()
        #expect(entries.count == 1)

        let (entryID, entry) = entries[0]
        #expect(entryID == tab.id)
        #expect(entry.originalPath == "/Users/test/file.swift")
        #expect(entry.content == "modified code")
        #expect(entry.encoding == .utf16)
    }

    @Test func snapshotSkipsCleanTabs() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let manager = RecoveryManager(recoveryDirectory: dir)

        let clean = makeCleanTab()
        manager.snapshotDirtyTabs([clean])

        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        #expect(files.isEmpty)
    }

    @Test func snapshotMultipleDirtyTabs() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let manager = RecoveryManager(recoveryDirectory: dir)

        let tab1 = makeDirtyTab(content: "content1")
        let tab2 = makeDirtyTab(content: "content2")
        let tab3 = makeDirtyTab(content: "content3")

        manager.snapshotDirtyTabs([tab1, tab2, tab3])

        let entries = manager.pendingRecoveryEntries()
        #expect(entries.count == 3)
    }

    @Test func snapshotOverwritesPreviousRecoveryFile() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let manager = RecoveryManager(recoveryDirectory: dir)

        var tab = makeDirtyTab(content: "version1")
        manager.snapshotDirtyTabs([tab])

        // Simulate content change — same tab ID, different content
        tab.content = "version2"
        manager.snapshotDirtyTabs([tab])

        let entries = manager.pendingRecoveryEntries()
        #expect(entries.count == 1)
        #expect(entries[0].1.content == "version2")
    }

    @Test func recoveryFileRemovedWhenTabSaved() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let manager = RecoveryManager(recoveryDirectory: dir)

        let tab = makeDirtyTab(content: "dirty")
        manager.snapshotDirtyTabs([tab])
        #expect(manager.pendingRecoveryEntries().count == 1)

        // Simulate save — TabManager calls deleteRecoveryFile after trySaveTab
        manager.deleteRecoveryFile(for: tab.id)
        #expect(manager.pendingRecoveryEntries().isEmpty)
    }

    // MARK: - Delete recovery file

    @Test func deleteRecoveryFileRemovesFile() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let manager = RecoveryManager(recoveryDirectory: dir)

        let tab = makeDirtyTab()
        manager.snapshotDirtyTabs([tab])
        #expect(manager.pendingRecoveryEntries().count == 1)

        manager.deleteRecoveryFile(for: tab.id)
        #expect(manager.pendingRecoveryEntries().isEmpty)
    }

    @Test func deleteRecoveryFileNoOpForMissingID() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let manager = RecoveryManager(recoveryDirectory: dir)

        // Should not crash
        manager.deleteRecoveryFile(for: UUID())
        #expect(manager.pendingRecoveryEntries().isEmpty)
    }

    // MARK: - Delete all

    @Test func deleteAllRecoveryFilesRemovesEverything() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let manager = RecoveryManager(recoveryDirectory: dir)

        manager.snapshotDirtyTabs([
            makeDirtyTab(content: "a"),
            makeDirtyTab(content: "b"),
            makeDirtyTab(content: "c")
        ])
        #expect(manager.pendingRecoveryEntries().count == 3)

        manager.deleteAllRecoveryFiles()
        #expect(manager.pendingRecoveryEntries().isEmpty)
    }

    // MARK: - Pending entries

    @Test func pendingRecoveryEntriesReturnsEmptyWhenNoFiles() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let manager = RecoveryManager(recoveryDirectory: dir)

        #expect(manager.pendingRecoveryEntries().isEmpty)
    }

    @Test func pendingRecoveryEntriesReturnsEmptyWhenDirectoryDoesNotExist() {
        let nonexistent = URL(fileURLWithPath: "/tmp/nonexistent-\(UUID().uuidString)")
        let manager = RecoveryManager(recoveryDirectory: nonexistent)

        #expect(manager.pendingRecoveryEntries().isEmpty)
    }

    @Test func pendingRecoveryEntriesParsesTabIDFromFilename() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let manager = RecoveryManager(recoveryDirectory: dir)

        let tab = makeDirtyTab()
        manager.snapshotDirtyTabs([tab])

        let entries = manager.pendingRecoveryEntries()
        #expect(entries.count == 1)
        #expect(entries[0].0 == tab.id)
    }

    // MARK: - Stale cleanup

    @Test func cleanupStaleEntriesRemovesOldFiles() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let manager = RecoveryManager(recoveryDirectory: dir)

        // Create a recovery file manually with old timestamp
        let oldEntry = RecoveryEntry(
            originalPath: "/tmp/old.swift",
            content: "old content",
            timestamp: Date().addingTimeInterval(-8 * 24 * 3600), // 8 days ago
            encoding: .utf8
        )
        let oldID = UUID()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(oldEntry)
        let filePath = dir.appendingPathComponent("\(oldID.uuidString).json")
        try data.write(to: filePath, options: .atomic)

        #expect(manager.pendingRecoveryEntries().count == 1)

        manager.cleanupStaleEntries(olderThan: 7)

        #expect(manager.pendingRecoveryEntries().isEmpty)
    }

    @Test func cleanupStaleEntriesKeepsRecentFiles() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let manager = RecoveryManager(recoveryDirectory: dir)

        let tab = makeDirtyTab()
        manager.snapshotDirtyTabs([tab])

        manager.cleanupStaleEntries(olderThan: 7)

        #expect(manager.pendingRecoveryEntries().count == 1)
    }

    // MARK: - Edge cases

    @Test func recoveryDirectoryCreatedAutomatically() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PineRecoveryTests-\(UUID().uuidString)")
            .appendingPathComponent("nested")
        defer { cleanup(dir.deletingLastPathComponent()) }

        let manager = RecoveryManager(recoveryDirectory: dir)
        let tab = makeDirtyTab()
        manager.snapshotDirtyTabs([tab])

        #expect(FileManager.default.fileExists(atPath: dir.path))
        #expect(manager.pendingRecoveryEntries().count == 1)
    }

    @Test func encodingPreservedInRecovery() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let manager = RecoveryManager(recoveryDirectory: dir)

        let encodings: [String.Encoding] = [.utf8, .utf16, .ascii, .isoLatin1, .shiftJIS]
        for encoding in encodings {
            let tab = makeDirtyTab(encoding: encoding)
            manager.snapshotDirtyTabs([tab])

            let entries = manager.pendingRecoveryEntries()
            let entry = entries.first { $0.0 == tab.id }
            #expect(entry?.1.encoding == encoding, "Encoding \(encoding) should be preserved")

            manager.deleteRecoveryFile(for: tab.id)
        }
    }

    @Test func timestampRecordedInSnapshot() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let manager = RecoveryManager(recoveryDirectory: dir)

        let before = Date().addingTimeInterval(-1) // 1s tolerance for ISO 8601 rounding
        let tab = makeDirtyTab()
        manager.snapshotDirtyTabs([tab])
        let after = Date().addingTimeInterval(1)

        let entries = manager.pendingRecoveryEntries()
        #expect(entries.count == 1)
        let timestamp = entries[0].1.timestamp
        #expect(timestamp >= before)
        #expect(timestamp <= after)
    }

    @Test func corruptedRecoveryFileIsSkipped() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let manager = RecoveryManager(recoveryDirectory: dir)

        // Write valid file
        let tab = makeDirtyTab()
        manager.snapshotDirtyTabs([tab])

        // Write corrupted file
        let corruptPath = dir.appendingPathComponent("\(UUID().uuidString).json")
        try Data("not valid json".utf8).write(to: corruptPath, options: .atomic)

        // Should return only the valid entry, not crash
        let entries = manager.pendingRecoveryEntries()
        #expect(entries.count == 1)
        #expect(entries[0].0 == tab.id)
    }

    @Test func nonJsonFilesInDirectoryAreIgnored() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let manager = RecoveryManager(recoveryDirectory: dir)

        // Write a non-json file
        let otherFile = dir.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: otherFile, options: .atomic)

        #expect(manager.pendingRecoveryEntries().isEmpty)
    }

    // MARK: - Performance

    @Test func snapshotPerformanceWith100LargeTabs() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let manager = RecoveryManager(recoveryDirectory: dir)

        // 100 tabs × 1 MB each
        let largeContent = String(repeating: "x", count: 1_000_000)
        var tabs: [EditorTab] = []
        for i in 0..<100 {
            tabs.append(makeDirtyTab(
                url: URL(fileURLWithPath: "/tmp/file\(i).swift"),
                content: largeContent
            ))
        }

        let start = Date()
        manager.snapshotDirtyTabs(tabs)
        let elapsed = Date().timeIntervalSince(start)

        #expect(elapsed < 2.0, "Snapshot of 100 × 1MB tabs should complete within 2 seconds, took \(elapsed)s")
        #expect(manager.pendingRecoveryEntries().count == 100)
    }

    // MARK: - Preview tabs

    @Test func previewTabsAreSkipped() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let manager = RecoveryManager(recoveryDirectory: dir)

        let previewTab = EditorTab(url: URL(fileURLWithPath: "/tmp/image.png"), kind: .preview)
        manager.snapshotDirtyTabs([previewTab])

        #expect(manager.pendingRecoveryEntries().isEmpty)
    }

    // MARK: - Per-project isolation

    @Test func differentProjectsGetDifferentDirectories() {
        let url1 = URL(fileURLWithPath: "/Users/test/project-a")
        let url2 = URL(fileURLWithPath: "/Users/test/project-b")

        let dir1 = RecoveryManager.directory(for: url1)
        let dir2 = RecoveryManager.directory(for: url2)

        #expect(dir1 != dir2)
    }

    @Test func sameProjectGetsSameDirectory() {
        let url = URL(fileURLWithPath: "/Users/test/project")

        let dir1 = RecoveryManager.directory(for: url)
        let dir2 = RecoveryManager.directory(for: url)

        #expect(dir1 == dir2)
    }

    @Test func perProjectRecoveryFilesDoNotMix() throws {
        let root = try makeTempDir()
        defer { cleanup(root) }

        let dirA = root.appendingPathComponent("project-a")
        let dirB = root.appendingPathComponent("project-b")

        let managerA = RecoveryManager(recoveryDirectory: dirA)
        let managerB = RecoveryManager(recoveryDirectory: dirB)

        let tabA = makeDirtyTab(content: "from project A")
        let tabB = makeDirtyTab(content: "from project B")

        managerA.snapshotDirtyTabs([tabA])
        managerB.snapshotDirtyTabs([tabB])

        #expect(managerA.pendingRecoveryEntries().count == 1)
        #expect(managerB.pendingRecoveryEntries().count == 1)
        #expect(managerA.pendingRecoveryEntries()[0].1.content == "from project A")
        #expect(managerB.pendingRecoveryEntries()[0].1.content == "from project B")

        managerA.deleteAllRecoveryFiles()
        #expect(managerA.pendingRecoveryEntries().isEmpty)
        #expect(managerB.pendingRecoveryEntries().count == 1)
    }
}
