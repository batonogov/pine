//
//  RecoveryManagerTests.swift
//  PineTests
//

import AppKit
import Foundation
import Testing
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

    private func waitUntil(
        timeout: Duration = .seconds(120),
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
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
        #expect(entry.schemaVersion == RecoveryEntry.currentSchemaVersion)
    }

    @Test func futureSchemaFailsClosedWithoutOverwrite() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let manager = RecoveryManager(recoveryDirectory: dir)
        let id = UUID()
        let file = dir.appendingPathComponent("\(id.uuidString).json")
        let entry = RecoveryEntry(
            schemaVersion: RecoveryEntry.currentSchemaVersion + 1,
            originalPath: "/sanitized/project/file.swift",
            content: "future contents"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(entry)
        try data.write(to: file)

        #expect(manager.pendingRecoveryEntries().isEmpty)
        #expect(try Data(contentsOf: file) == data)
    }

    @Test func legacySnapshotWithoutSchemaRemainsReadable() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let manager = RecoveryManager(recoveryDirectory: dir)
        let id = UUID()
        let legacy = """
        {
          "originalPath": "/sanitized/project/file.swift",
          "content": "legacy contents",
          "timestamp": "2026-01-01T00:00:00Z",
          "encodingRawValue": 4
        }
        """
        try Data(legacy.utf8).write(
            to: dir.appendingPathComponent("\(id.uuidString).json")
        )

        let entries = manager.pendingRecoveryEntries()
        #expect(entries.count == 1)
        #expect(entries.first?.0 == id)
        #expect(entries.first?.1.schemaVersion == nil)
        #expect(entries.first?.1.content == "legacy contents")
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

    @Test func restoreWaitsForLargeFileOpenBeforeApplyingAndDeleting() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let manager = RecoveryManager(recoveryDirectory: dir)
        let file = dir.appendingPathComponent("large.swift")
        let diskContent = String(
            repeating: "d",
            count: TabManager.largeFileThreshold + 1
        )
        try diskContent.write(to: file, atomically: true, encoding: .utf8)
        let recoveredContent = "recovered unsaved content"
        let crashedTab = makeDirtyTab(
            url: file,
            content: recoveredContent,
            savedContent: diskContent,
            encoding: .utf16
        )
        manager.snapshotDirtyTabs([crashedTab])
        let entries = manager.pendingRecoveryEntries()
        let tabManager = TabManager()
        let (responses, responseContinuation) = AsyncStream.makeStream(
            of: NSApplication.ModalResponse.self
        )
        var presentationCount = 0
        tabManager.largeFileAlertPresenter = { _, _, _ in
            presentationCount += 1
            for await response in responses {
                return response
            }
            return .abort
        }

        let restoreTask = Task { @MainActor in
            await manager.restorePendingEntries(
                entries,
                in: tabManager,
                context: .unscoped
            )
        }
        #expect(await waitUntil { presentationCount == 1 })
        #expect(tabManager.tabs.isEmpty)
        #expect(manager.pendingRecoveryEntries().map(\.0) == [crashedTab.id])

        responseContinuation.yield(.alertSecondButtonReturn)
        responseContinuation.finish()
        let retained = await restoreTask.value

        let restoredTab = try #require(tabManager.activeTab)
        #expect(retained.isEmpty)
        #expect(tabManager.tabs.count == 2)
        let baselineTab = try #require(tabManager.tabs.first)
        #expect(baselineTab.id != restoredTab.id)
        #expect(baselineTab.content == diskContent)
        #expect(baselineTab.savedContent == diskContent)
        #expect(restoredTab.content == recoveredContent)
        #expect(restoredTab.savedContent == diskContent)
        #expect(restoredTab.encoding == .utf16)
        #expect(restoredTab.isDirty)
        let currentSnapshots = manager.pendingRecoveryEntries()
        #expect(currentSnapshots.map(\.0) == [restoredTab.id])
        #expect(currentSnapshots.first?.1.content == recoveredContent)
    }

    @Test func cancelledLargeFileRecoveryRetainsSnapshot() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let manager = RecoveryManager(recoveryDirectory: dir)
        let file = dir.appendingPathComponent("cancelled-large.swift")
        let diskContent = String(
            repeating: "d",
            count: TabManager.largeFileThreshold + 1
        )
        try diskContent.write(to: file, atomically: true, encoding: .utf8)
        let crashedTab = makeDirtyTab(
            url: file,
            content: "keep this recovery",
            savedContent: diskContent
        )
        manager.snapshotDirtyTabs([crashedTab])
        let entries = manager.pendingRecoveryEntries()
        let tabManager = TabManager()
        tabManager.largeFileAlertPresenter = { _, _, _ in .abort }

        let retained = await manager.restorePendingEntries(
            entries,
            in: tabManager,
            context: .unscoped
        )

        #expect(retained.map(\.0) == [crashedTab.id])
        #expect(tabManager.tabs.isEmpty)
        #expect(manager.pendingRecoveryEntries().map(\.0) == [crashedTab.id])
    }

    @Test func partialRestoreRetainsOnlyCancelledEntryAndSelectiveDiscard() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let manager = RecoveryManager(recoveryDirectory: dir)
        let restoredURL = dir.appendingPathComponent("restored.swift")
        let restoredDiskContent = "let disk = true"
        try restoredDiskContent.write(
            to: restoredURL,
            atomically: true,
            encoding: .utf8
        )
        let cancelledURL = dir.appendingPathComponent("cancelled.swift")
        let cancelledDiskContent = String(
            repeating: "c",
            count: TabManager.largeFileThreshold + 1
        )
        try cancelledDiskContent.write(
            to: cancelledURL,
            atomically: true,
            encoding: .utf8
        )
        let restoredCrashTab = makeDirtyTab(
            url: restoredURL,
            content: "let recovered = true",
            savedContent: restoredDiskContent
        )
        let cancelledCrashTab = makeDirtyTab(
            url: cancelledURL,
            content: "retain cancelled recovery",
            savedContent: cancelledDiskContent
        )
        manager.snapshotDirtyTabs([
            restoredCrashTab,
            cancelledCrashTab
        ])
        let tabManager = TabManager()
        tabManager.largeFileAlertPresenter = { _, _, _ in .abort }

        let retained = await manager.restorePendingEntries(
            manager.pendingRecoveryEntries(),
            in: tabManager,
            context: .unscoped
        )

        #expect(retained.map(\.0) == [cancelledCrashTab.id])
        let recoveredTab = try #require(tabManager.tabs.first(where: {
            $0.content == "let recovered = true"
        }))
        #expect(recoveredTab.id != restoredCrashTab.id)
        #expect(recoveredTab.isDirty)
        #expect(
            Set(manager.pendingRecoveryEntries().map(\.0)) ==
                Set([cancelledCrashTab.id, recoveredTab.id])
        )

        manager.deleteRecoveryFiles(for: retained.map(\.0))

        #expect(
            manager.pendingRecoveryEntries().map(\.0) ==
                [recoveredTab.id]
        )
        #expect(
            manager.pendingRecoveryEntries().first?.1.content ==
                "let recovered = true"
        )
    }

    @Test func duplicateURLRecoveryKeepsEveryDivergentBuffer() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let recoveryManager = RecoveryManager(recoveryDirectory: dir)
        let file = dir.appendingPathComponent("duplicate.swift")
        let diskContent = "let value = \"disk\""
        try diskContent.write(to: file, atomically: true, encoding: .utf8)
        let firstRecoveredContent = "let value = \"first 🧪\"\n\u{0}"
        let secondRecoveredContent = "let value = \"second\""
        let firstCrashTab = makeDirtyTab(
            url: file,
            content: firstRecoveredContent,
            savedContent: diskContent,
            encoding: .utf16
        )
        let secondCrashTab = makeDirtyTab(
            url: file,
            content: secondRecoveredContent,
            savedContent: diskContent,
            encoding: .ascii
        )
        recoveryManager.snapshotDirtyTabs([
            firstCrashTab,
            secondCrashTab
        ])

        let tabManager = TabManager()
        tabManager.openTab(url: file)
        let existingID = try #require(tabManager.activeTabID)
        tabManager.tabs[0].content = "live unsaved buffer"
        tabManager.tabs[0].recomputeContentCaches()

        let retained = await recoveryManager.restorePendingEntries(
            recoveryManager.pendingRecoveryEntries(),
            in: tabManager,
            context: .unscoped
        )

        #expect(retained.isEmpty)
        #expect(tabManager.tabs.count == 3)
        let existing = try #require(tabManager.tabs.first(where: {
            $0.id == existingID
        }))
        #expect(existing.content == "live unsaved buffer")
        #expect(existing.savedContent == diskContent)

        let recoveredTabs = tabManager.tabs.filter { $0.id != existingID }
        #expect(Set(recoveredTabs.map(\.content)) == Set([
            firstRecoveredContent,
            secondRecoveredContent
        ]))
        #expect(
            recoveredTabs.first(where: {
                $0.content == firstRecoveredContent
            })?.encoding == .utf16
        )
        #expect(
            recoveredTabs.first(where: {
                $0.content == secondRecoveredContent
            })?.encoding == .ascii
        )
        let allRecoveredTabsShareBaseline = recoveredTabs.allSatisfy {
            $0.savedContent == diskContent
        }
        #expect(allRecoveredTabsShareBaseline)
        let allRecoveredTabsAreDirty = recoveredTabs.allSatisfy {
            $0.isDirty
        }
        #expect(allRecoveredTabsAreDirty)
        #expect(Set(tabManager.tabs.map(\.id)).count == 3)
        #expect(
            Set(recoveryManager.pendingRecoveryEntries().map(\.1.content)) ==
                Set([firstRecoveredContent, secondRecoveredContent])
        )
        #expect(
            Set(recoveryManager.pendingRecoveryEntries().map(\.0))
                .isDisjoint(with: [firstCrashTab.id, secondCrashTab.id])
        )
    }

    @Test func maxTabsRecoveryIsRetainedWithoutOverwritingExistingTab() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let recoveryManager = RecoveryManager(recoveryDirectory: dir)
        let file = dir.appendingPathComponent("full.swift")
        let baseline = "baseline"
        try baseline.write(to: file, atomically: true, encoding: .utf8)
        let crashTab = makeDirtyTab(
            url: file,
            content: "must remain recoverable",
            savedContent: baseline
        )
        recoveryManager.snapshotDirtyTabs([crashTab])

        let tabManager = TabManager()
        tabManager.tabs = [EditorTab(
            url: file,
            content: baseline,
            savedContent: baseline
        )]
        for index in 1..<TabManager.maxTabs {
            tabManager.tabs.append(EditorTab(
                url: dir.appendingPathComponent("filler-\(index).swift"),
                content: "",
                savedContent: ""
            ))
        }
        let existingID = tabManager.tabs[0].id

        let retained = await recoveryManager.restorePendingEntries(
            recoveryManager.pendingRecoveryEntries(),
            in: tabManager,
            context: .unscoped
        )

        #expect(retained.map(\.0) == [crashTab.id])
        #expect(tabManager.tabs.count == TabManager.maxTabs)
        #expect(tabManager.tabs[0].id == existingID)
        #expect(tabManager.tabs[0].content == baseline)
        #expect(
            recoveryManager.pendingRecoveryEntries().map(\.0) ==
                [crashTab.id]
        )
    }

    @Test func unopenedRecoveryNeedsRoomForBaselineAndRecoveredTabs() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let recoveryManager = RecoveryManager(recoveryDirectory: dir)
        let file = dir.appendingPathComponent("needs-two-slots.swift")
        try "disk".write(to: file, atomically: true, encoding: .utf8)
        let crashTab = makeDirtyTab(
            url: file,
            content: "recovered",
            savedContent: "disk"
        )
        recoveryManager.snapshotDirtyTabs([crashTab])

        let tabManager = TabManager()
        for index in 0..<(TabManager.maxTabs - 1) {
            tabManager.tabs.append(EditorTab(
                url: dir.appendingPathComponent("filler-\(index).swift")
            ))
        }
        let originalIDs = tabManager.tabs.map(\.id)

        let retained = await recoveryManager.restorePendingEntries(
            recoveryManager.pendingRecoveryEntries(),
            in: tabManager,
            context: .unscoped
        )

        #expect(retained.map(\.0) == [crashTab.id])
        #expect(tabManager.tabs.map(\.id) == originalIDs)
        #expect(!tabManager.tabs.contains { $0.url == file })
        #expect(
            recoveryManager.pendingRecoveryEntries().map(\.0) ==
                [crashTab.id]
        )
    }

    @Test func cleanRecoveredContentConsumesOldSnapshotWithoutCreatingNewOne() async throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let recoveryManager = RecoveryManager(recoveryDirectory: dir)
        let file = dir.appendingPathComponent("clean.swift")
        let diskContent = "already on disk"
        try diskContent.write(to: file, atomically: true, encoding: .utf8)
        let crashTab = makeDirtyTab(
            url: file,
            content: diskContent,
            savedContent: "older baseline"
        )
        recoveryManager.snapshotDirtyTabs([crashTab])
        let tabManager = TabManager()

        let retained = await recoveryManager.restorePendingEntries(
            recoveryManager.pendingRecoveryEntries(),
            in: tabManager,
            context: .unscoped
        )

        #expect(retained.isEmpty)
        #expect(tabManager.tabs.count == 2)
        #expect(tabManager.tabs.allSatisfy { $0.content == diskContent })
        #expect(tabManager.tabs.allSatisfy { !$0.isDirty })
        #expect(Set(tabManager.tabs.map(\.id)).count == 2)
        #expect(recoveryManager.pendingRecoveryEntries().isEmpty)
    }

    @Test func failedRuntimeSnapshotKeepsOldUntilLaterSnapshotSucceeds() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let manager = RecoveryManager(recoveryDirectory: dir)
        let oldTab = makeDirtyTab(content: "old durable recovery")
        manager.snapshotDirtyTabs([oldTab])
        let runtimeTab = makeDirtyTab(
            content: "runtime recovered content"
        )
        let blockingDestination = dir.appendingPathComponent(
            "\(runtimeTab.id.uuidString).json"
        )
        try FileManager.default.createDirectory(
            at: blockingDestination,
            withIntermediateDirectories: false
        )

        #expect(
            manager.migrateRecoverySnapshot(
                from: oldTab.id,
                to: runtimeTab
            ) == false
        )
        #expect(
            manager.pendingRecoveryEntries().map(\.0) == [oldTab.id]
        )
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(
            atPath: blockingDestination.path,
            isDirectory: &isDirectory
        ))
        #expect(isDirectory.boolValue)

        try FileManager.default.removeItem(at: blockingDestination)
        manager.snapshotDirtyTabs([runtimeTab])

        let entries = manager.pendingRecoveryEntries()
        #expect(entries.map(\.0) == [runtimeTab.id])
        #expect(entries.first?.1.content == "runtime recovered content")
    }

    @Test func failedRuntimeSnapshotOldIDIsAlsoCleanedAfterSave() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let manager = RecoveryManager(recoveryDirectory: dir)
        let oldTab = makeDirtyTab(content: "old durable recovery")
        manager.snapshotDirtyTabs([oldTab])
        let documentURL = dir.appendingPathComponent("saved.swift")
        try "disk baseline".write(
            to: documentURL,
            atomically: true,
            encoding: .utf8
        )
        let runtimeTab = makeDirtyTab(
            url: documentURL,
            content: "now saved elsewhere",
            savedContent: "disk baseline"
        )
        let blockingDestination = dir.appendingPathComponent(
            "\(runtimeTab.id.uuidString).json"
        )
        try FileManager.default.createDirectory(
            at: blockingDestination,
            withIntermediateDirectories: false
        )
        #expect(
            !manager.migrateRecoverySnapshot(
                from: oldTab.id,
                to: runtimeTab
            )
        )

        let tabManager = TabManager()
        tabManager.recoveryManager = manager
        tabManager.tabs = [runtimeTab]
        tabManager.activeTabID = runtimeTab.id
        #expect(tabManager.saveActiveTab())

        #expect(manager.pendingRecoveryEntries().isEmpty)
        #expect(!FileManager.default.fileExists(
            atPath: blockingDestination.path
        ))
    }

    @Test func sameIDMigrationKeepsNewlyReplacedSnapshot() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }
        let manager = RecoveryManager(recoveryDirectory: dir)
        var tab = makeDirtyTab(content: "older recovery")
        manager.snapshotDirtyTabs([tab])
        tab.content = "newer recovery under same ID"

        #expect(manager.migrateRecoverySnapshot(from: tab.id, to: tab))

        let entries = manager.pendingRecoveryEntries()
        #expect(entries.count == 1)
        #expect(entries.first?.0 == tab.id)
        #expect(entries.first?.1.content == "newer recovery under same ID")
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
