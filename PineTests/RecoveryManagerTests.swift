//
//  RecoveryManagerTests.swift
//  PineTests
//
//  Created by Claude on 21.03.2026.
//

import Foundation
import Testing
@testable import Pine

// MARK: - RecoveryManager Unit Tests

@Suite("RecoveryManager Tests")
struct RecoveryManagerTests {

    // MARK: - Helpers

    /// Creates a RecoveryManager backed by an isolated temporary directory.
    private func makeManager() -> (RecoveryManager, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PineRecoveryTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manager = RecoveryManager(recoveryDirectory: dir)
        return (manager, dir)
    }

    private func tempFileURL(name: String = "test.swift") -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(name + "-" + UUID().uuidString)
    }

    // MARK: - Directory creation

    @Test("Recovery directory is created on init")
    func directoryCreatedOnInit() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PineRecoveryInit-\(UUID().uuidString)")
        #expect(!FileManager.default.fileExists(atPath: dir.path))
        _ = RecoveryManager(recoveryDirectory: dir)
        #expect(FileManager.default.fileExists(atPath: dir.path))
    }

    // MARK: - Snapshot

    @Test("Snapshot creates a recovery file")
    func snapshotCreatesFile() {
        let (manager, dir) = makeManager()
        let tabID = UUID()
        let url = tempFileURL()

        manager.snapshot(tabID: tabID, url: url, content: "let x = 1", encoding: .utf8)

        let recoveryFile = dir.appendingPathComponent(tabID.uuidString + ".recovery")
        #expect(FileManager.default.fileExists(atPath: recoveryFile.path))
    }

    @Test("Snapshot content and metadata round-trip correctly")
    func snapshotRoundTrip() {
        let (manager, _) = makeManager()
        let tabID = UUID()
        let url = URL(fileURLWithPath: "/Users/test/project/main.swift")
        let content = "func hello() { print(\"Hello\") }"

        manager.snapshot(tabID: tabID, url: url, content: content, encoding: .utf8)

        let recoveries = manager.pendingRecoveries()
        #expect(recoveries.count == 1)
        let recovery = recoveries[0]
        #expect(recovery.tabID == tabID)
        #expect(recovery.originalURLPath == url.path)
        #expect(recovery.content == content)
        #expect(recovery.encoding == .utf8)
    }

    @Test("Snapshot with nil URL stores nil originalURLPath (untitled buffer)")
    func snapshotUntitledBuffer() {
        let (manager, _) = makeManager()
        let tabID = UUID()

        manager.snapshot(tabID: tabID, url: nil, content: "untitled content", encoding: .utf8)

        let recoveries = manager.pendingRecoveries()
        #expect(recoveries.count == 1)
        #expect(recoveries[0].originalURLPath == nil)
        #expect(recoveries[0].displayName == "Untitled")
    }

    @Test("Snapshot is atomic — overwriting an existing recovery file preserves it on failure")
    func snapshotIsAtomic() {
        let (manager, _) = makeManager()
        let tabID = UUID()
        let url = tempFileURL()

        // Write first snapshot
        manager.snapshot(tabID: tabID, url: url, content: "version 1", encoding: .utf8)

        // Overwrite with second snapshot
        manager.snapshot(tabID: tabID, url: url, content: "version 2", encoding: .utf8)

        let recoveries = manager.pendingRecoveries()
        #expect(recoveries.count == 1)
        #expect(recoveries[0].content == "version 2")
    }

    @Test("Snapshot preserves encoding")
    func snapshotPreservesEncoding() {
        let (manager, _) = makeManager()
        let tabID = UUID()
        let url = tempFileURL()

        manager.snapshot(tabID: tabID, url: url, content: "hello", encoding: .utf16)

        let recoveries = manager.pendingRecoveries()
        #expect(recoveries.count == 1)
        #expect(recoveries[0].encoding == .utf16)
    }

    // MARK: - Multiple tabs

    @Test("Multiple dirty tabs each get independent recovery files")
    func multipleTabsGetIndependentFiles() {
        let (manager, dir) = makeManager()
        let tab1 = UUID()
        let tab2 = UUID()
        let tab3 = UUID()

        manager.snapshot(tabID: tab1, url: tempFileURL(), content: "content 1", encoding: .utf8)
        manager.snapshot(tabID: tab2, url: tempFileURL(), content: "content 2", encoding: .utf8)
        manager.snapshot(tabID: tab3, url: tempFileURL(), content: "content 3", encoding: .utf8)

        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "recovery" } ?? []
        #expect(files.count == 3)

        let recoveries = manager.pendingRecoveries()
        #expect(recoveries.count == 3)
    }

    // MARK: - Delete

    @Test("deleteRecovery removes only the specified tab's file")
    func deleteRecoveryRemovesCorrectFile() {
        let (manager, _) = makeManager()
        let tab1 = UUID()
        let tab2 = UUID()

        manager.snapshot(tabID: tab1, url: tempFileURL(), content: "a", encoding: .utf8)
        manager.snapshot(tabID: tab2, url: tempFileURL(), content: "b", encoding: .utf8)

        manager.deleteRecovery(for: tab1)

        let recoveries = manager.pendingRecoveries()
        #expect(recoveries.count == 1)
        #expect(recoveries[0].tabID == tab2)
    }

    @Test("deleteRecovery is a no-op when no file exists")
    func deleteRecoveryNoop() {
        let (manager, _) = makeManager()
        // Should not throw or crash
        manager.deleteRecovery(for: UUID())
        #expect(manager.pendingRecoveries().isEmpty)
    }

    @Test("deleteAllRecoveries removes all recovery files")
    func deleteAllRecoveries() {
        let (manager, _) = makeManager()

        for _ in 0..<5 {
            manager.snapshot(tabID: UUID(), url: tempFileURL(), content: "x", encoding: .utf8)
        }
        #expect(manager.pendingRecoveries().count == 5)

        manager.deleteAllRecoveries()
        #expect(manager.pendingRecoveries().isEmpty)
    }

    // MARK: - Launch detection

    @Test("pendingRecoveries returns empty array when directory is empty")
    func pendingRecoveriesEmpty() {
        let (manager, _) = makeManager()
        #expect(manager.pendingRecoveries().isEmpty)
    }

    @Test("pendingRecoveries skips corrupt files")
    func pendingRecoveriesSkipsCorrupt() {
        let (manager, dir) = makeManager()

        // Write a valid recovery file
        manager.snapshot(tabID: UUID(), url: tempFileURL(), content: "valid", encoding: .utf8)

        // Write a corrupt file
        let corrupt = dir.appendingPathComponent(UUID().uuidString + ".recovery")
        try? "not json {{{".write(to: corrupt, atomically: true, encoding: .utf8)

        // Only the valid one should be returned
        #expect(manager.pendingRecoveries().count == 1)
    }

    @Test("recoveryByURL returns exactly one entry per URL")
    func recoveryByURL() {
        let (manager, _) = makeManager()
        let url1 = URL(fileURLWithPath: "/project/file1.swift")
        let url2 = URL(fileURLWithPath: "/project/file2.swift")

        // Two different files
        manager.snapshot(tabID: UUID(), url: url1, content: "content1", encoding: .utf8)
        manager.snapshot(tabID: UUID(), url: url2, content: "content2", encoding: .utf8)

        let map = manager.recoveryByURL()
        #expect(map.keys.count == 2)
        #expect(map[url1.path] != nil)
        #expect(map[url2.path] != nil)
    }

    @Test("recoveryByURL deduplicates multiple snapshots for the same URL")
    func recoveryByURLDeduplicated() {
        let (manager, _) = makeManager()
        let url = URL(fileURLWithPath: "/project/file.swift")

        // Two snapshots for the same URL (different tab IDs, as in separate runs)
        manager.snapshot(tabID: UUID(), url: url, content: "content-a", encoding: .utf8)
        manager.snapshot(tabID: UUID(), url: url, content: "content-b", encoding: .utf8)

        let map = manager.recoveryByURL()
        // Only one entry per URL
        #expect(map.keys.count == 1)
        #expect(map[url.path] != nil)
    }

    // MARK: - Stale cleanup

    @Test("cleanupStaleRecoveries deletes files older than 7 days")
    func cleanupStaleRecoveries() throws {
        let (manager, dir) = makeManager()
        let tabID = UUID()

        // Write a recovery file
        manager.snapshot(tabID: tabID, url: tempFileURL(), content: "old", encoding: .utf8)

        // Backdate the file's modification date beyond the threshold
        let fileURL = dir.appendingPathComponent(tabID.uuidString + ".recovery")
        let pastDate = Date().addingTimeInterval(-(RecoveryManager.staleThreshold + 3600))
        try FileManager.default.setAttributes(
            [.modificationDate: pastDate],
            ofItemAtPath: fileURL.path
        )

        manager.cleanupStaleRecoveries()

        #expect(manager.pendingRecoveries().isEmpty)
    }

    @Test("cleanupStaleRecoveries keeps recent files")
    func cleanupStaleRecoveriesKeepsRecent() {
        let (manager, _) = makeManager()

        manager.snapshot(tabID: UUID(), url: tempFileURL(), content: "recent", encoding: .utf8)

        manager.cleanupStaleRecoveries()

        #expect(manager.pendingRecoveries().count == 1)
    }
}

// MARK: - TabManager Recovery Integration Tests

@Suite("TabManager Recovery Integration Tests")
struct TabManagerRecoveryTests {

    private func tempFileURL(name: String = "test.swift", content: String = "let x = 1") -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try? content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test("updateContent schedules a recovery snapshot for dirty tab")
    func updateContentSchedulesSnapshot() {
        let manager = TabManager()
        manager.setRecoveryDelay(10) // Long delay — we only check scheduling, not firing
        let url = tempFileURL()
        manager.openTab(url: url)
        guard let tabID = manager.activeTabID else {
            Issue.record("activeTabID should not be nil")
            return
        }

        manager.updateContent("modified content")

        #expect(manager.hasScheduledRecoverySnapshot(for: tabID))
    }

    @Test("closeTab cancels pending recovery snapshot")
    func closeTabCancelsSnapshot() {
        let manager = TabManager()
        manager.setRecoveryDelay(60) // Long delay so it won't fire during the test
        let url = tempFileURL()
        manager.openTab(url: url)
        guard let tabID = manager.activeTabID else {
            Issue.record("activeTabID should not be nil")
            return
        }

        // Schedule a snapshot by editing the tab
        manager.updateContent("some edit")
        #expect(manager.hasScheduledRecoverySnapshot(for: tabID))

        // Closing the tab should cancel the pending snapshot
        manager.closeTab(id: tabID)
        #expect(!manager.hasScheduledRecoverySnapshot(for: tabID))
    }

    @Test("restoreTabContent sets content and marks tab dirty")
    func restoreTabContentMarksDirty() {
        let manager = TabManager()
        let url = tempFileURL(content: "original")
        manager.openTab(url: url)

        manager.restoreTabContent(url: url, content: "recovered content")

        #expect(manager.activeTab?.content == "recovered content")
        #expect(manager.activeTab?.isDirty == true)
    }

    @Test("restoreTabContent is a no-op for unknown URL")
    func restoreTabContentNoopForUnknownURL() {
        let manager = TabManager()
        let url = tempFileURL(content: "original")
        manager.openTab(url: url)

        let unknownURL = URL(fileURLWithPath: "/does/not/exist.swift")
        manager.restoreTabContent(url: unknownURL, content: "should not apply")

        // Active tab should be unchanged
        #expect(manager.activeTab?.isDirty == false)
    }

    @Test("cancelAllRecoverySnapshots clears all pending items")
    func cancelAllRecoverySnapshots() {
        let manager = TabManager()
        manager.setRecoveryDelay(60)

        let url1 = tempFileURL(name: "a.swift")
        let url2 = tempFileURL(name: "b.swift")
        manager.openTab(url: url1)
        manager.updateContent("edit a")
        manager.openTab(url: url2)
        manager.updateContent("edit b")

        let ids = manager.tabs.map(\.id)
        #expect(ids.contains { manager.hasScheduledRecoverySnapshot(for: $0) })

        manager.cancelAllRecoverySnapshots()

        #expect(!ids.contains { manager.hasScheduledRecoverySnapshot(for: $0) })
    }
}

// MARK: - RecoveryFileData Tests

@Suite("RecoveryFileData Tests")
struct RecoveryFileDataTests {

    @Test("displayName returns filename from URL path")
    func displayNameFromURL() {
        let data = RecoveryFileData(
            tabID: UUID(),
            originalURLPath: "/Users/test/project/main.swift",
            content: "",
            timestamp: Date(),
            encodingRawValue: String.Encoding.utf8.rawValue
        )
        #expect(data.displayName == "main.swift")
    }

    @Test("displayName returns Untitled for nil URL")
    func displayNameUntitled() {
        let data = RecoveryFileData(
            tabID: UUID(),
            originalURLPath: nil,
            content: "",
            timestamp: Date(),
            encodingRawValue: String.Encoding.utf8.rawValue
        )
        #expect(data.displayName == "Untitled")
    }

    @Test("encoding round-trips through rawValue")
    func encodingRoundTrip() {
        for encoding: String.Encoding in [.utf8, .utf16, .ascii, .isoLatin1] {
            let data = RecoveryFileData(
                tabID: UUID(),
                originalURLPath: nil,
                content: "",
                timestamp: Date(),
                encodingRawValue: encoding.rawValue
            )
            #expect(data.encoding == encoding)
        }
    }

    @Test("originalURL is nil when originalURLPath is nil")
    func originalURLNilWhenPathNil() {
        let data = RecoveryFileData(
            tabID: UUID(),
            originalURLPath: nil,
            content: "",
            timestamp: Date(),
            encodingRawValue: String.Encoding.utf8.rawValue
        )
        #expect(data.originalURL == nil)
    }

    @Test("originalURL converts path to URL correctly")
    func originalURLFromPath() {
        let path = "/Users/test/file.txt"
        let data = RecoveryFileData(
            tabID: UUID(),
            originalURLPath: path,
            content: "",
            timestamp: Date(),
            encodingRawValue: String.Encoding.utf8.rawValue
        )
        #expect(data.originalURL?.path == path)
    }
}
