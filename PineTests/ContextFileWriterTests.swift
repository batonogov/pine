//
//  ContextFileWriterTests.swift
//  PineTests
//

import Testing
import Foundation
@testable import Pine

struct ContextFileWriterTests {

    // MARK: - Helpers

    /// Creates a unique temporary directory for test isolation.
    private func makeTmpDir() throws -> URL {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        return tmpDir
    }

    /// Reads and decodes the context file from the given directory.
    private func readPayload(in dir: URL) throws -> ContextFileWriter.Payload {
        let fileURL = dir.appendingPathComponent(ContextFileWriter.fileName)
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(ContextFileWriter.Payload.self, from: data)
    }

    // MARK: - JSON encoding / decoding

    @Test func payloadEncodesToJSON() throws {
        let payload = ContextFileWriter.Payload(
            currentFile: "Sources/main.swift", cursorLine: 42, cursorColumn: 10
        )
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(ContextFileWriter.Payload.self, from: data)
        #expect(decoded == payload)
    }

    @Test func payloadWithNilValues() throws {
        let payload = ContextFileWriter.Payload(currentFile: nil, cursorLine: nil, cursorColumn: nil)
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(ContextFileWriter.Payload.self, from: data)
        #expect(decoded.currentFile == nil)
        #expect(decoded.cursorLine == nil)
        #expect(decoded.cursorColumn == nil)
    }

    @Test func payloadRoundTrip() throws {
        let original = ContextFileWriter.Payload(
            currentFile: "path/to/file.swift", cursorLine: 100, cursorColumn: 25
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ContextFileWriter.Payload.self, from: data)
        #expect(decoded == original)
        #expect(decoded.currentFile == original.currentFile)
        #expect(decoded.cursorLine == original.cursorLine)
        #expect(decoded.cursorColumn == original.cursorColumn)
    }

    @Test func payloadEquality() {
        let a = ContextFileWriter.Payload(currentFile: "a.swift", cursorLine: 1, cursorColumn: 2)
        let b = ContextFileWriter.Payload(currentFile: "a.swift", cursorLine: 1, cursorColumn: 2)
        let c = ContextFileWriter.Payload(currentFile: "b.swift", cursorLine: 1, cursorColumn: 2)
        #expect(a == b)
        #expect(a != c)
    }

    @Test func payloadInequalityOnEachField() {
        let base = ContextFileWriter.Payload(currentFile: "a.swift", cursorLine: 1, cursorColumn: 1)
        let diffFile = ContextFileWriter.Payload(currentFile: "b.swift", cursorLine: 1, cursorColumn: 1)
        let diffLine = ContextFileWriter.Payload(currentFile: "a.swift", cursorLine: 2, cursorColumn: 1)
        let diffCol = ContextFileWriter.Payload(currentFile: "a.swift", cursorLine: 1, cursorColumn: 2)
        #expect(base != diffFile)
        #expect(base != diffLine)
        #expect(base != diffCol)
    }

    @Test func payloadSendableConformance() async throws {
        let payload = ContextFileWriter.Payload(
            currentFile: "test.swift", cursorLine: 1, cursorColumn: 1
        )
        // Verify Sendable by passing through Task boundary
        let result = await Task.detached {
            payload
        }.value
        #expect(result == payload)
    }

    // MARK: - File writing

    @Test func writesContextFileToProjectRoot() async throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let writer = ContextFileWriter()
        await writer.setProjectRoot(tmpDir)
        await writer.setDebounceInterval(0.01)

        await writer.update(currentFile: "Sources/App.swift", cursorLine: 10, cursorColumn: 5)
        try await Task.sleep(for: .milliseconds(50))

        let decoded = try readPayload(in: tmpDir)
        #expect(decoded.currentFile == "Sources/App.swift")
        #expect(decoded.cursorLine == 10)
        #expect(decoded.cursorColumn == 5)
    }

    // MARK: - Debounce behavior

    @Test func debounceCoalescesRapidUpdates() async throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let writer = ContextFileWriter()
        await writer.setProjectRoot(tmpDir)
        await writer.setDebounceInterval(0.05)

        // Rapid updates — only the last one should be written
        await writer.update(currentFile: "a.swift", cursorLine: 1, cursorColumn: 1)
        await writer.update(currentFile: "b.swift", cursorLine: 2, cursorColumn: 2)
        await writer.update(currentFile: "c.swift", cursorLine: 3, cursorColumn: 3)

        try await Task.sleep(for: .milliseconds(100))

        let decoded = try readPayload(in: tmpDir)
        #expect(decoded.currentFile == "c.swift")
        #expect(decoded.cursorLine == 3)
        #expect(decoded.cursorColumn == 3)
    }

    // MARK: - Cleanup

    @Test func cleanupRemovesFile() async throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let writer = ContextFileWriter()
        await writer.setProjectRoot(tmpDir)
        await writer.setDebounceInterval(0.01)

        await writer.update(currentFile: "test.swift", cursorLine: 1, cursorColumn: 1)
        try await Task.sleep(for: .milliseconds(50))

        let fileURL = tmpDir.appendingPathComponent(ContextFileWriter.fileName)
        #expect(FileManager.default.fileExists(atPath: fileURL.path))

        await writer.cleanup()
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test func cleanupCancelsPendingWrite() async throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let writer = ContextFileWriter()
        await writer.setProjectRoot(tmpDir)
        await writer.setDebounceInterval(1.0) // Long debounce

        await writer.update(currentFile: "test.swift", cursorLine: 1, cursorColumn: 1)
        let pending = await writer.hasPendingWrite
        #expect(pending)

        await writer.cleanup()
        let pendingAfter = await writer.hasPendingWrite
        #expect(!pendingAfter)

        // File should not exist — the write was cancelled before it fired
        let fileURL = tmpDir.appendingPathComponent(ContextFileWriter.fileName)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test func cleanupWhenFileDoesNotExistOnDisk() async throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let writer = ContextFileWriter()
        await writer.setProjectRoot(tmpDir)

        // File was never written — cleanup should not crash
        await writer.cleanup()

        let fileURL = tmpDir.appendingPathComponent(ContextFileWriter.fileName)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    // MARK: - Nil project root

    @Test func updateWithNilProjectRootDoesNotCrash() async throws {
        let writer = ContextFileWriter()
        // No project root set — should be a no-op
        await writer.setDebounceInterval(0.01)
        await writer.update(currentFile: "test.swift", cursorLine: 1, cursorColumn: 1)
        try await Task.sleep(for: .milliseconds(50))
        // No crash = pass
        let root = await writer.projectRoot
        #expect(root == nil)
    }

    @Test func updateWithNilCurrentFile() async throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let writer = ContextFileWriter()
        await writer.setProjectRoot(tmpDir)
        await writer.setDebounceInterval(0.01)

        await writer.update(currentFile: nil, cursorLine: nil, cursorColumn: nil)
        try await Task.sleep(for: .milliseconds(50))

        let decoded = try readPayload(in: tmpDir)
        #expect(decoded.currentFile == nil)
        #expect(decoded.cursorLine == nil)
        #expect(decoded.cursorColumn == nil)
    }

    // MARK: - Context file URL

    @Test func contextFileURLReturnsCorrectPath() async {
        let writer = ContextFileWriter()
        let url1 = await writer.contextFileURL
        #expect(url1 == nil)

        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("test-project")
        await writer.setProjectRoot(tmpDir)
        let url2 = await writer.contextFileURL
        let expected = tmpDir.appendingPathComponent(ContextFileWriter.fileName)
        #expect(url2 == expected)
    }

    // MARK: - Relative path calculation

    @Test func relativePathFromProjectRoot() {
        let rootURL = URL(fileURLWithPath: "/Users/test/project")
        let fileURL = URL(fileURLWithPath: "/Users/test/project/Sources/App.swift")
        let result = ContextFileWriter.relativePath(fileURL: fileURL, rootURL: rootURL)
        #expect(result == "Sources/App.swift")
    }

    @Test func relativePathForFileOutsideProject() {
        let rootURL = URL(fileURLWithPath: "/Users/test/project")
        let fileURL = URL(fileURLWithPath: "/Users/test/other/file.swift")
        let result = ContextFileWriter.relativePath(fileURL: fileURL, rootURL: rootURL)
        #expect(result == "file.swift")
    }

    @Test func relativePathWithTrailingSlashInRoot() {
        let rootURL = URL(fileURLWithPath: "/Users/test/project/")
        let fileURL = URL(fileURLWithPath: "/Users/test/project/Sources/App.swift")
        let result = ContextFileWriter.relativePath(fileURL: fileURL, rootURL: rootURL)
        #expect(result == "Sources/App.swift")
    }

    @Test func relativePathWithNilFile() {
        let rootURL = URL(fileURLWithPath: "/Users/test/project")
        let result = ContextFileWriter.relativePath(fileURL: nil, rootURL: rootURL)
        #expect(result == nil)
    }

    @Test func relativePathWithSpecialCharacters() {
        let rootURL = URL(fileURLWithPath: "/Users/test/project")
        let fileURL = URL(fileURLWithPath: "/Users/test/project/Sources/My App (2).swift")
        let result = ContextFileWriter.relativePath(fileURL: fileURL, rootURL: rootURL)
        #expect(result == "Sources/My App (2).swift")
    }

    @Test func relativePathDeeplyNested() {
        let rootURL = URL(fileURLWithPath: "/Users/test/project")
        let fileURL = URL(fileURLWithPath: "/Users/test/project/a/b/c/d/e/file.swift")
        let result = ContextFileWriter.relativePath(fileURL: fileURL, rootURL: rootURL)
        #expect(result == "a/b/c/d/e/file.swift")
    }

    @Test func relativePathFileAtRoot() {
        let rootURL = URL(fileURLWithPath: "/Users/test/project")
        let fileURL = URL(fileURLWithPath: "/Users/test/project/file.swift")
        let result = ContextFileWriter.relativePath(fileURL: fileURL, rootURL: rootURL)
        #expect(result == "file.swift")
    }

    // MARK: - Written JSON is valid and readable by external tools

    @Test func writtenJSONIsReadableByDecoder() async throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let writer = ContextFileWriter()
        await writer.setProjectRoot(tmpDir)
        await writer.setDebounceInterval(0.01)

        await writer.update(currentFile: "path/with \"quotes\".swift", cursorLine: 100, cursorColumn: 25)
        try await Task.sleep(for: .milliseconds(50))

        let decoded = try readPayload(in: tmpDir)
        #expect(decoded.currentFile == "path/with \"quotes\".swift")
        #expect(decoded.cursorLine == 100)
        #expect(decoded.cursorColumn == 25)
    }

    @Test func writtenJSONWithNullValues() async throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let writer = ContextFileWriter()
        await writer.setProjectRoot(tmpDir)
        await writer.setDebounceInterval(0.01)

        await writer.update(currentFile: nil, cursorLine: nil, cursorColumn: nil)
        try await Task.sleep(for: .milliseconds(50))

        let decoded = try readPayload(in: tmpDir)
        #expect(decoded.currentFile == nil)
        #expect(decoded.cursorLine == nil)
        #expect(decoded.cursorColumn == nil)
    }

    // MARK: - Skips redundant writes

    @Test func skipsRedundantWriteForSameContext() async throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let writer = ContextFileWriter()
        await writer.setProjectRoot(tmpDir)
        await writer.setDebounceInterval(0.01)

        // First write
        await writer.update(currentFile: "a.swift", cursorLine: 1, cursorColumn: 1)
        try await Task.sleep(for: .milliseconds(50))

        let fileURL = tmpDir.appendingPathComponent(ContextFileWriter.fileName)
        let firstModDate = try FileManager.default.attributesOfItem(
            atPath: fileURL.path
        )[.modificationDate] as? Date

        // Wait a bit so mod date would differ if file is rewritten
        try await Task.sleep(for: .milliseconds(100))

        // Same context — should skip the write
        await writer.update(currentFile: "a.swift", cursorLine: 1, cursorColumn: 1)
        try await Task.sleep(for: .milliseconds(50))

        let secondModDate = try FileManager.default.attributesOfItem(
            atPath: fileURL.path
        )[.modificationDate] as? Date

        #expect(firstModDate == secondModDate)
    }

    // MARK: - Special characters in file paths

    @Test func handlesSpacesInFilePaths() async throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let writer = ContextFileWriter()
        await writer.setProjectRoot(tmpDir)
        await writer.setDebounceInterval(0.01)

        await writer.update(
            currentFile: "path/my project/Sources/App Manager.swift",
            cursorLine: 42,
            cursorColumn: 10
        )
        try await Task.sleep(for: .milliseconds(50))

        let decoded = try readPayload(in: tmpDir)
        #expect(decoded.currentFile == "path/my project/Sources/App Manager.swift")
    }

    @Test func handlesUnicodeInFileNames() async throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let writer = ContextFileWriter()
        await writer.setProjectRoot(tmpDir)
        await writer.setDebounceInterval(0.01)

        await writer.update(currentFile: "\u{0444}\u{0430}\u{0439}\u{043B}.swift", cursorLine: 1, cursorColumn: 1)
        try await Task.sleep(for: .milliseconds(50))

        let decoded = try readPayload(in: tmpDir)
        #expect(decoded.currentFile == "\u{0444}\u{0430}\u{0439}\u{043B}.swift")
    }

    @Test func handlesEmojiInFileNames() async throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let writer = ContextFileWriter()
        await writer.setProjectRoot(tmpDir)
        await writer.setDebounceInterval(0.01)

        await writer.update(currentFile: "Sources/\u{1F680}rocket.swift", cursorLine: 5, cursorColumn: 3)
        try await Task.sleep(for: .milliseconds(50))

        let decoded = try readPayload(in: tmpDir)
        #expect(decoded.currentFile == "Sources/\u{1F680}rocket.swift")
    }

    @Test func handlesNewlineInFileName() async throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let writer = ContextFileWriter()
        await writer.setProjectRoot(tmpDir)
        await writer.setDebounceInterval(0.01)

        await writer.update(currentFile: "file\nname.swift", cursorLine: 1, cursorColumn: 1)
        try await Task.sleep(for: .milliseconds(50))

        let decoded = try readPayload(in: tmpDir)
        #expect(decoded.currentFile == "file\nname.swift")
    }

    @Test func handlesTabInFileName() async throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let writer = ContextFileWriter()
        await writer.setProjectRoot(tmpDir)
        await writer.setDebounceInterval(0.01)

        await writer.update(currentFile: "file\tname.swift", cursorLine: 1, cursorColumn: 1)
        try await Task.sleep(for: .milliseconds(50))

        let decoded = try readPayload(in: tmpDir)
        #expect(decoded.currentFile == "file\tname.swift")
    }

    @Test func handlesBackslashInPaths() async throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let writer = ContextFileWriter()
        await writer.setProjectRoot(tmpDir)
        await writer.setDebounceInterval(0.01)

        await writer.update(currentFile: "path\\to\\file.swift", cursorLine: 1, cursorColumn: 1)
        try await Task.sleep(for: .milliseconds(50))

        let decoded = try readPayload(in: tmpDir)
        #expect(decoded.currentFile == "path\\to\\file.swift")
    }

    @Test func handlesVeryLongPath() async throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let writer = ContextFileWriter()
        await writer.setProjectRoot(tmpDir)
        await writer.setDebounceInterval(0.01)

        let longPath = (0..<50).map { "dir\($0)" }.joined(separator: "/") + "/file.swift"
        await writer.update(currentFile: longPath, cursorLine: 1, cursorColumn: 1)
        try await Task.sleep(for: .milliseconds(50))

        let decoded = try readPayload(in: tmpDir)
        #expect(decoded.currentFile == longPath)
    }

    // MARK: - File permissions

    @Test func contextFileHasRestrictivePermissions() async throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let writer = ContextFileWriter()
        await writer.setProjectRoot(tmpDir)
        await writer.setDebounceInterval(0.01)

        await writer.update(currentFile: "test.swift", cursorLine: 1, cursorColumn: 1)
        try await Task.sleep(for: .milliseconds(50))

        let fileURL = tmpDir.appendingPathComponent(ContextFileWriter.fileName)
        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let permissions = (attrs[.posixPermissions] as? NSNumber)?.uint16Value
        // 0o600 = 384 decimal = owner rw only
        #expect(permissions == 0o600)
    }

    // MARK: - Concurrent writes (thread safety via actor)

    @Test func concurrentUpdatesDoNotCrash() async throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let writer = ContextFileWriter()
        await writer.setProjectRoot(tmpDir)
        await writer.setDebounceInterval(0.01)

        // Fire many concurrent updates — actor serializes them
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask {
                    await writer.update(
                        currentFile: "file\(i).swift",
                        cursorLine: i,
                        cursorColumn: i
                    )
                }
            }
        }

        try await Task.sleep(for: .milliseconds(100))

        // The file should exist and be valid JSON
        let fileURL = tmpDir.appendingPathComponent(ContextFileWriter.fileName)
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
        let data = try Data(contentsOf: fileURL)
        let decoded = try JSONDecoder().decode(ContextFileWriter.Payload.self, from: data)
        #expect(decoded.currentFile != nil)
    }

    // MARK: - Permission denied (read-only directory)

    @Test func writeToReadOnlyDirectoryDoesNotCrash() async throws {
        let tmpDir = try makeTmpDir()
        defer {
            // Restore permissions before cleanup
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o755)],
                ofItemAtPath: tmpDir.path
            )
            try? FileManager.default.removeItem(at: tmpDir)
        }

        // Make directory read-only
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o555)],
            ofItemAtPath: tmpDir.path
        )

        let writer = ContextFileWriter()
        await writer.setProjectRoot(tmpDir)
        await writer.setDebounceInterval(0.01)

        // Should not crash, just silently fail
        await writer.update(currentFile: "test.swift", cursorLine: 1, cursorColumn: 1)
        try await Task.sleep(for: .milliseconds(50))

        let fileURL = tmpDir.appendingPathComponent(ContextFileWriter.fileName)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    // MARK: - Empty file name

    @Test func handlesEmptyFileName() async throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let writer = ContextFileWriter()
        await writer.setProjectRoot(tmpDir)
        await writer.setDebounceInterval(0.01)

        await writer.update(currentFile: "", cursorLine: 0, cursorColumn: 0)
        try await Task.sleep(for: .milliseconds(50))

        let decoded = try readPayload(in: tmpDir)
        #expect(decoded.currentFile == "")
        #expect(decoded.cursorLine == 0)
        #expect(decoded.cursorColumn == 0)
    }

    // MARK: - TabManager.onEditorContextChanged callback

    @Test func tabManagerCallsContextChangedOnActiveTabSwitch() {
        let tabManager = TabManager()
        var callCount = 0
        tabManager.onEditorContextChanged = { callCount += 1 }

        // Create two tabs manually
        let url1 = URL(fileURLWithPath: "/tmp/test1.swift")
        let url2 = URL(fileURLWithPath: "/tmp/test2.swift")
        let tab1 = EditorTab(url: url1, content: "// 1", savedContent: "// 1")
        let tab2 = EditorTab(url: url2, content: "// 2", savedContent: "// 2")
        tabManager.tabs = [tab1, tab2]

        tabManager.activeTabID = tab1.id
        #expect(callCount == 1)

        // Switch to second tab
        tabManager.activeTabID = tab2.id
        #expect(callCount == 2)

        // Same tab again — no extra callback
        tabManager.activeTabID = tab2.id
        #expect(callCount == 2)
    }

    @Test func tabManagerCallsContextChangedOnCursorUpdate() {
        let tabManager = TabManager()
        var callCount = 0
        tabManager.onEditorContextChanged = { callCount += 1 }

        let url = URL(fileURLWithPath: "/tmp/test.swift")
        let tab = EditorTab(url: url, content: "line1\nline2\nline3", savedContent: "line1\nline2\nline3")
        tabManager.tabs = [tab]
        tabManager.activeTabID = tab.id
        #expect(callCount == 1) // from setting activeTabID

        // Update cursor position
        tabManager.updateEditorState(cursorPosition: 6, scrollOffset: 0)
        #expect(callCount == 2)
    }

    // MARK: - ProjectManager.updateEditorContext

    @Test func updateEditorContextWithNoRootIsNoOp() {
        let pm = ProjectManager()
        // No root URL set — should not crash
        pm.updateEditorContext()
    }
}
