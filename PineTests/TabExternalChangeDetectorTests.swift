//
//  TabExternalChangeDetectorTests.swift
//  PineTests
//

import Foundation
import Testing

@testable import Pine

@Suite("TabExternalChangeDetector Tests")
@MainActor
struct TabExternalChangeDetectorTests {

    private func tempFile(content: String = "hello") -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("test.txt")
        try? content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private var providers: FileProviders {
        FileProviders(
            modDate: { url in
                try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
            },
            fileSize: { url in
                guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                      let size = attrs[.size] as? Int else { return nil }
                return size
            }
        )
    }

    // MARK: - Silent reload

    @Test("Silently reloads clean tab when file modified externally")
    func silentlyReloadsCleanTab() throws {
        let url = tempFile(content: "v1")
        var tab = EditorTab(url: url, content: "v1", savedContent: "v1")
        tab.lastModDate = Date().addingTimeInterval(-10)

        var tabs = [tab]

        try "v2".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: url.path
        )

        let result = TabExternalChangeDetector.checkExternalChanges(tabs: &tabs, providers: providers)

        #expect(result.conflicts.isEmpty)
        #expect(result.reloadedFileNames.count == 1)
        #expect(result.reloadedTabs.count == 1)
        #expect(result.reloadedTabs[0].url == url)
        #expect(result.reloadedTabs[0].text == "v2")
        #expect(tabs[0].content == "v2")
        #expect(result.cleanDeletedIDs.isEmpty)
    }

    // MARK: - Conflict for dirty tab

    @Test("Returns conflict for dirty tab when file modified externally")
    func conflictForDirtyTab() throws {
        let url = tempFile(content: "v1")
        var tab = EditorTab(url: url, content: "user edits", savedContent: "v1")
        tab.lastModDate = Date().addingTimeInterval(-10)

        var tabs = [tab]

        try "v2".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: url.path
        )

        let result = TabExternalChangeDetector.checkExternalChanges(tabs: &tabs, providers: providers)

        #expect(result.conflicts.count == 1)
        #expect(result.conflicts[0].kind == .modified)
        #expect(tabs[0].content == "user edits") // Not overwritten
    }

    @Test(
        "Detects dirty conflict when replacement keeps or lowers mtime",
        arguments: [TimeInterval.zero, TimeInterval(-60)]
    )
    func conflictForNonIncreasingModificationDate(
        offset: TimeInterval
    ) throws {
        let url = tempFile(content: "v1")
        var tab = TabPersistence.createTextTab(
            url: url,
            syntaxHighlightingDisabled: false,
            providers: providers
        )
        tab.content = "user edits"
        let originalDate = try #require(providers.modDate(url))
        var tabs = [tab]

        try "v2".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: originalDate.addingTimeInterval(offset)],
            ofItemAtPath: url.path
        )

        let result = TabExternalChangeDetector.checkExternalChanges(
            tabs: &tabs,
            providers: providers
        )

        #expect(result.conflicts.count == 1)
        #expect(result.conflicts[0].kind == .modified)
        #expect(tabs[0].content == "user edits")
    }

    // MARK: - Deleted file

    @Test("Returns cleanDeletedIDs for clean tab when file deleted")
    func cleanDeletedForCleanTab() throws {
        let url = tempFile(content: "data")
        var tab = EditorTab(url: url, content: "data", savedContent: "data")
        tab.lastModDate = Date()

        var tabs = [tab]
        try? FileManager.default.removeItem(at: url)

        let result = TabExternalChangeDetector.checkExternalChanges(tabs: &tabs, providers: providers)

        #expect(result.cleanDeletedIDs.count == 1)
        #expect(result.conflicts.isEmpty)
    }

    @Test("Returns conflict for dirty tab when file deleted")
    func conflictForDirtyDeletedTab() throws {
        let url = tempFile(content: "data")
        var tab = EditorTab(url: url, content: "modified", savedContent: "data")
        tab.lastModDate = Date()

        var tabs = [tab]
        try? FileManager.default.removeItem(at: url)

        let result = TabExternalChangeDetector.checkExternalChanges(tabs: &tabs, providers: providers)

        #expect(result.conflicts.count == 1)
        #expect(result.conflicts[0].kind == .deleted)
        #expect(result.cleanDeletedIDs.isEmpty)
    }

    // MARK: - No change

    @Test("No changes when file unchanged")
    func noChangeWhenUnchanged() throws {
        let url = tempFile(content: "data")
        let storedModDate = providers.modDate(url)
        var tab = EditorTab(url: url, content: "data", savedContent: "data")
        tab.lastModDate = storedModDate

        var tabs = [tab]

        let result = TabExternalChangeDetector.checkExternalChanges(tabs: &tabs, providers: providers)

        #expect(result.conflicts.isEmpty)
        #expect(result.reloadedFileNames.isEmpty)
        #expect(result.cleanDeletedIDs.isEmpty)
    }

    // MARK: - Preview tab

    @Test("Preview tab only updates modDate, no reload")
    func previewTabUpdatesModDate() throws {
        let url = tempFile(content: "v1")
        var tab = EditorTab(url: url, kind: .preview)
        tab.lastModDate = Date().addingTimeInterval(-10)

        var tabs = [tab]

        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: url.path
        )

        let result = TabExternalChangeDetector.checkExternalChanges(tabs: &tabs, providers: providers)

        #expect(result.conflicts.isEmpty)
        #expect(result.reloadedFileNames.isEmpty)
        #expect(tabs[0].lastModDate != nil)
    }

    // MARK: - reloadTab

    @Test("reloadTab updates content from disk")
    func reloadTabFromDisk() throws {
        let url = tempFile(content: "v1")
        var tab = EditorTab(url: url, content: "v1", savedContent: "v1")
        tab.lastModDate = Date()

        var tabs = [tab]
        try "v2".write(to: url, atomically: true, encoding: .utf8)

        let reloaded = TabExternalChangeDetector.reloadTab(url: url, tabs: &tabs, providers: providers)

        #expect(tabs[0].content == "v2")
        #expect(tabs[0].savedContent == "v2")
        #expect(reloaded?.url == url)
        #expect(reloaded?.text == "v2")
    }

    @Test("reloadTab is no-op for unknown URL")
    func reloadTabUnknownURL() {
        var tabs = [EditorTab(url: URL(fileURLWithPath: "/tmp/a.txt"), content: "data", savedContent: "data")]
        let reloaded = TabExternalChangeDetector.reloadTab(
            url: URL(fileURLWithPath: "/tmp/missing.txt"), tabs: &tabs,
            providers: .init(modDate: { _ in nil }, fileSize: { _ in nil })
        )
        #expect(tabs[0].content == "data")
        #expect(reloaded == nil)
    }
}
