//
//  TabDuplicatorTests.swift
//  PineTests
//

import Foundation
import Testing

@testable import Pine

@Suite("TabDuplicator Tests")
@MainActor
struct TabDuplicatorTests {

    private func makeSettings() -> EditorSettings {
        let suite = "TabDuplicatorTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            fatalError("Failed to create UserDefaults")
        }
        return EditorSettings(defaults: defaults)
    }

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("duplicateTab creates copy with Finder naming")
    func duplicateCreatesCopy() throws {
        let dir = tempDir()
        let url = dir.appendingPathComponent("file.swift")
        try "content".write(to: url, atomically: true, encoding: .utf8)

        var tabs = [EditorTab(url: url, content: "content", savedContent: "content")]
        let newID = try TabDuplicator.duplicateTab(
            atIndex: 0, in: &tabs,
            editorSettings: makeSettings(), fileFormatters: .default,
            projectRoot: nil
        )

        #expect(newID != nil)
        #expect(tabs.count == 2)
        #expect(tabs[1].url.lastPathComponent == "file copy.swift")
        // Default EditorSettings has insertFinalNewline=true
        #expect(tabs[1].content == "content\n")
    }

    @Test("duplicateTab inserts after original")
    func duplicateInsertsAfterOriginal() throws {
        let dir = tempDir()
        let url = dir.appendingPathComponent("file.swift")
        try "data".write(to: url, atomically: true, encoding: .utf8)

        var tabs = [
            EditorTab(url: URL(fileURLWithPath: "/tmp/a.swift"), content: "", savedContent: ""),
            EditorTab(url: url, content: "data", savedContent: "data"),
            EditorTab(url: URL(fileURLWithPath: "/tmp/c.swift"), content: "", savedContent: ""),
        ]

        _ = try TabDuplicator.duplicateTab(
            atIndex: 1, in: &tabs,
            editorSettings: makeSettings(), fileFormatters: .default,
            projectRoot: nil
        )

        #expect(tabs.count == 4)
        #expect(tabs[2].url.lastPathComponent == "file copy.swift")
    }

    @Test("duplicateTab returns nil for out-of-bounds index")
    func duplicateOutOfBounds() throws {
        var tabs = [EditorTab(url: URL(fileURLWithPath: "/tmp/a.swift"), content: "", savedContent: "")]

        let result = try TabDuplicator.duplicateTab(
            atIndex: 5, in: &tabs,
            editorSettings: makeSettings(), fileFormatters: .default,
            projectRoot: nil
        )

        #expect(result == nil)
        #expect(tabs.count == 1)
    }

    @Test("duplicateTab blocks files outside project root")
    func duplicateBlocksOutsideRoot() throws {
        let projectDir = tempDir()
        let outsideDir = tempDir()
        let outsideFile = outsideDir.appendingPathComponent("secret.txt")
        try "secret".write(to: outsideFile, atomically: true, encoding: .utf8)

        var tabs = [EditorTab(url: outsideFile, content: "secret", savedContent: "secret")]

        #expect(throws: (any Error).self) {
            try TabDuplicator.duplicateTab(
                atIndex: 0, in: &tabs,
                editorSettings: makeSettings(), fileFormatters: .default,
                projectRoot: projectDir
            )
        }
    }

    @Test("duplicateTab throws for non-writable path")
    func duplicateThrowsForBadPath() {
        let badURL = URL(fileURLWithPath: "/nonexistent_\(UUID().uuidString)/file.txt")
        var tabs = [EditorTab(url: badURL, content: "data", savedContent: "data")]

        #expect(throws: (any Error).self) {
            try TabDuplicator.duplicateTab(
                atIndex: 0, in: &tabs,
                editorSettings: makeSettings(), fileFormatters: .default,
                projectRoot: nil
            )
        }
    }
}
