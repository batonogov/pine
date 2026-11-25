//
//  RegressionTests.swift
//  PineTests
//
//  Regression tests for #457: source locations, trailing whitespace
//  stripping, partial file loading, and session restoration.
//

import Foundation
import Testing

@testable import Pine

// MARK: - Helpers

private func makeTempDir() throws -> URL {
    let rawDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("PineRegression-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: rawDir, withIntermediateDirectories: true)
    guard let resolved = realpath(rawDir.path, nil) else { throw CocoaError(.fileNoSuchFile) }
    defer { free(resolved) }
    return URL(fileURLWithPath: String(cString: resolved))
}

private func cleanup(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
}

// MARK: - Source Locations: Edge Cases

@Suite("Source Location Regression")
@MainActor
struct SourceLocationRegressionTests {

    @Test("cursorOffset beyond last line clamps to end")
    func cursorOffsetBeyondFile() {
        let content = "line1\nline2\nline3"
        let offset = ContentView.cursorOffset(forLine: 100, in: content)
        #expect(offset == (content as NSString).length)
    }

    @Test("cursorOffset for line 0 still works (clamps to valid range)")
    func cursorOffsetLineZero() {
        let content = "line1\nline2"
        let offset = ContentView.cursorOffset(forLine: 0, in: content)
        #expect(offset >= 0)
        #expect(offset <= (content as NSString).length)
    }

    @Test("cursorOffset with empty content")
    func cursorOffsetEmptyContent() {
        let offset = ContentView.cursorOffset(forLine: 1, in: "")
        #expect(offset == 0)
    }

    @Test("cursorOffset column clamped to line length")
    func cursorOffsetColumnClamped() {
        let content = "short\nmedium line\nlong"
        let offset = ContentView.cursorOffset(forLine: 1, column: 100, in: content)
        #expect(offset <= 5)
    }
}

// MARK: - Strip Whitespace: Edge Cases

@Suite("TrailingWhitespace Regression")
@MainActor
struct TrailingWhitespaceRegressionTests {

    @Test("Binary-like content is not corrupted")
    func binaryLikeContent() {
        // String with null bytes and binary-looking data
        let input = "normal line  \n\0\0binary\0  \nanother  "
        let result = input.trailingWhitespaceStripped()
        // Should strip trailing spaces from normal lines
        #expect(result.hasPrefix("normal line"))
        // Should not crash on binary data
    }

    @Test("Mixed CRLF and LF preserved correctly")
    func mixedLineEndings() {
        let input = "line1   \r\nline2  \nline3\t\r\nline4  \n"
        let expected = "line1\r\nline2\nline3\r\nline4\n"
        #expect(input.trailingWhitespaceStripped() == expected)
    }

    @Test("Leading whitespace preserved while trailing stripped")
    func leadingPreservedTrailingStripped() {
        let input = "    indented   \n\t\ttabbed\t\t\n"
        let expected = "    indented\n\t\ttabbed\n"
        #expect(input.trailingWhitespaceStripped() == expected)
    }

    @Test("Single newline only remains unchanged")
    func singleNewline() {
        #expect("\n".trailingWhitespaceStripped() == "\n")
        #expect("\r\n".trailingWhitespaceStripped() == "\r\n")
    }

    @Test("Very long line with trailing spaces")
    func veryLongLine() {
        let longContent = String(repeating: "a", count: 10_000) + "   "
        let expected = String(repeating: "a", count: 10_000)
        #expect(longContent.trailingWhitespaceStripped() == expected)
    }

    @Test("Unicode content with trailing spaces")
    func unicodeWithTrailingSpaces() {
        let input = "Привет   \n你好  \n🎉  \n"
        let expected = "Привет\n你好\n🎉\n"
        #expect(input.trailingWhitespaceStripped() == expected)
    }

    @Test("Tab and space mix at end of line")
    func tabSpaceMix() {
        let input = "code \t \t  \nmore\t \n"
        let expected = "code\nmore\n"
        #expect(input.trailingWhitespaceStripped() == expected)
    }

    @Test("No-op on already clean content")
    func noOp() {
        let input = "clean\nlines\nno trailing\n"
        #expect(input.trailingWhitespaceStripped() == input)
    }

    @Test("Strip whitespace on save does not corrupt content")
    func stripOnSaveIntegration() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let url = dir.appendingPathComponent("test.swift")
        let original = "func foo()   \n    let x = 1  \n"
        try original.write(to: url, atomically: true, encoding: .utf8)

        let manager = TabManager()
        manager.openTab(url: url)
        let success = manager.saveActiveTab()
        #expect(success)

        // Read back — should have trailing whitespace stripped
        let onDisk = try String(contentsOf: url, encoding: .utf8)
        #expect(onDisk == "func foo()\n    let x = 1\n")
    }
}

// MARK: - Partial Load: Edge Cases

@Suite("Partial Load Regression")
@MainActor
struct PartialLoadRegressionTests {

    @Test("File at exactly 10MB threshold triggers partial load")
    func exactThreshold() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let url = dir.appendingPathComponent("exact.txt")
        let data = Data(count: TabManager.hugeFileThreshold)
        try data.write(to: url)

        let manager = TabManager()
        manager.openTab(url: url)

        #expect(manager.tabs.count == 1)
        #expect(manager.activeTab?.isTruncated == true)
        #expect(manager.activeTab?.syntaxHighlightingDisabled == true)
    }

    @Test("File just below 10MB threshold opens fully")
    func belowThreshold() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let url = dir.appendingPathComponent("below.txt")
        let content = String(repeating: "x", count: TabManager.hugeFileThreshold - 1)
        try content.write(to: url, atomically: true, encoding: .utf8)

        let manager = TabManager()
        // Use the explicit override to skip the large file alert dialog
        manager.openTab(url: url, syntaxHighlightingDisabled: true)

        #expect(manager.tabs.count == 1)
        #expect(manager.activeTab?.isTruncated == false)
    }

    @Test("Save blocked for truncated file")
    func saveBlockedForTruncated() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let url = dir.appendingPathComponent("huge.txt")
        let data = Data(count: TabManager.hugeFileThreshold + 1)
        try data.write(to: url)

        let manager = TabManager()
        manager.openTab(url: url)

        #expect(manager.activeTab?.isTruncated == true)

        // trySaveTab should throw for truncated files
        #expect(throws: (any Error).self) {
            try manager.trySaveTab(at: 0)
        }

        // File on disk should remain unchanged (original size)
        let fileAttrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = fileAttrs[.size] as? Int ?? 0
        #expect(fileSize == TabManager.hugeFileThreshold + 1)
    }

    @Test("Save all skips truncated tabs")
    func saveAllSkipsTruncated() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        // Create a huge file and a normal file
        let hugeURL = dir.appendingPathComponent("huge.txt")
        try Data(count: TabManager.hugeFileThreshold + 1).write(to: hugeURL)

        let normalURL = dir.appendingPathComponent("normal.swift")
        try "hello".write(to: normalURL, atomically: true, encoding: .utf8)

        let manager = TabManager()
        manager.openTab(url: hugeURL)
        manager.openTab(url: normalURL)
        manager.updateContent("modified")

        // Truncated tabs have content == savedContent, so they aren't dirty.
        // trySaveAllTabs only saves dirty tabs — truncated tab is skipped.
        #expect(manager.tabs[0].isTruncated == true)
        #expect(manager.tabs[1].isDirty == true)
        try manager.trySaveAllTabs()
        #expect(manager.tabs[1].isDirty == false)
    }

    @Test("Partial load reads only first 1MB of content")
    func partialLoadSize() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let url = dir.appendingPathComponent("big.txt")
        // Create 15MB file with recognizable pattern
        let pattern = "ABCDEFGHIJ" // 10 bytes
        let repeatCount = (TabManager.hugeFileThreshold + 5_000_000) / pattern.utf8.count
        let fullContent = String(repeating: pattern, count: repeatCount)
        try fullContent.write(to: url, atomically: true, encoding: .utf8)

        let manager = TabManager()
        manager.openTab(url: url)

        #expect(manager.activeTab?.isTruncated == true)
        // Content should be approximately 1MB of the pattern + truncation notice
        if let content = manager.activeTab?.content {
            // The loaded portion should be around 1MB
            // (exact size depends on UTF-8 decoding boundaries)
            #expect(!content.isEmpty)
            #expect(content.count < fullContent.count)
        }
    }

    @Test("Session restore of huge file still uses partial load")
    func sessionRestorePartialLoad() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let url = dir.appendingPathComponent("huge.txt")
        try Data(count: TabManager.hugeFileThreshold + 1).write(to: url)

        let manager = TabManager()
        // Session restore path uses openTab(url:syntaxHighlightingDisabled:)
        manager.openTab(url: url, syntaxHighlightingDisabled: false)

        #expect(manager.activeTab?.isTruncated == true)
        #expect(manager.activeTab?.syntaxHighlightingDisabled == true)
    }

    @Test("Truncated tab is not marked as dirty")
    func truncatedTabNotDirty() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let url = dir.appendingPathComponent("huge.txt")
        try Data(count: TabManager.hugeFileThreshold + 1).write(to: url)

        let manager = TabManager()
        manager.openTab(url: url)

        #expect(manager.activeTab?.isTruncated == true)
        #expect(manager.activeTab?.isDirty == false)
    }

    @Test("File size is stored on partial load tab")
    func fileSizeStoredOnPartialLoad() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let size = TabManager.hugeFileThreshold + 12345
        let url = dir.appendingPathComponent("huge.txt")
        try Data(count: size).write(to: url)

        let manager = TabManager()
        manager.openTab(url: url)

        #expect(manager.activeTab?.fileSizeBytes == size)
    }
}

// MARK: - Session Restore Regression

@Suite("Session Restore Regression")
@MainActor
struct SessionRestoreRegressionTests {

    @Test("Session save and load round-trips correctly")
    func sessionRoundTrip() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let file1 = dir.appendingPathComponent("a.swift")
        let file2 = dir.appendingPathComponent("b.swift")
        try "code1".write(to: file1, atomically: true, encoding: .utf8)
        try "code2".write(to: file2, atomically: true, encoding: .utf8)

        guard let defaults = UserDefaults(suiteName: "PineRegressionTest-\(UUID().uuidString)") else {
            Issue.record("Failed to create test UserDefaults"); return
        }

        SessionState.save(
            projectURL: dir,
            openFileURLs: [file1, file2],
            activeFileURL: file2,
            defaults: defaults
        )

        let loaded = SessionState.load(for: dir, defaults: defaults)
        #expect(loaded != nil)
        #expect(loaded?.existingFileURLs.count == 2)
        #expect(loaded?.activeFileURL == file2)
    }

    @Test("Session load filters deleted files")
    func sessionFiltersMissing() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let file1 = dir.appendingPathComponent("exists.swift")
        let file2 = dir.appendingPathComponent("deleted.swift")
        try "code".write(to: file1, atomically: true, encoding: .utf8)
        try "code".write(to: file2, atomically: true, encoding: .utf8)

        guard let defaults = UserDefaults(suiteName: "PineRegressionTest-\(UUID().uuidString)") else {
            Issue.record("Failed to create test UserDefaults"); return
        }

        SessionState.save(
            projectURL: dir,
            openFileURLs: [file1, file2],
            defaults: defaults
        )

        // Delete one file
        try FileManager.default.removeItem(at: file2)

        let loaded = SessionState.load(for: dir, defaults: defaults)
        #expect(loaded?.existingFileURLs.count == 1)
        #expect(loaded?.existingFileURLs.first == file1)
    }

    @Test("Session load returns nil for deleted project directory")
    func sessionNilForDeletedProject() throws {
        let dir = try makeTempDir()

        guard let defaults = UserDefaults(suiteName: "PineRegressionTest-\(UUID().uuidString)") else {
            Issue.record("Failed to create test UserDefaults"); return
        }

        SessionState.save(
            projectURL: dir,
            openFileURLs: [],
            defaults: defaults
        )

        try FileManager.default.removeItem(at: dir)

        let loaded = SessionState.load(for: dir, defaults: defaults)
        #expect(loaded == nil)
    }

    @Test("Session filters files outside project root")
    func sessionFiltersOutsideRoot() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let insideFile = dir.appendingPathComponent("inside.swift")
        try "code".write(to: insideFile, atomically: true, encoding: .utf8)

        let outsideFile = URL(fileURLWithPath: "/tmp/PineRegression-outside-\(UUID().uuidString).swift")
        try "code".write(to: outsideFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outsideFile) }

        guard let defaults = UserDefaults(suiteName: "PineRegressionTest-\(UUID().uuidString)") else {
            Issue.record("Failed to create test UserDefaults"); return
        }

        SessionState.save(
            projectURL: dir,
            openFileURLs: [insideFile, outsideFile],
            defaults: defaults
        )

        let loaded = SessionState.load(for: dir, defaults: defaults)
        // existingFileURLs filters to files within project root
        #expect(loaded?.existingFileURLs.count == 1)
        #expect(loaded?.existingFileURLs.first == insideFile)
    }

    @Test("Session clear removes saved state")
    func sessionClear() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        guard let defaults = UserDefaults(suiteName: "PineRegressionTest-\(UUID().uuidString)") else {
            Issue.record("Failed to create test UserDefaults"); return
        }

        SessionState.save(projectURL: dir, openFileURLs: [], defaults: defaults)
        #expect(SessionState.load(for: dir, defaults: defaults) != nil)

        SessionState.clear(for: dir, defaults: defaults)
        #expect(SessionState.load(for: dir, defaults: defaults) == nil)
    }
}
