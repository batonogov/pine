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
    private func readPayload(in dir: URL) throws -> ContextPayload {
        let fileURL = dir.appendingPathComponent(ContextFileWriter.fileName)
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(ContextPayload.self, from: data)
    }

    // MARK: - JSON encoding / decoding

    @Test func contextPayloadEncodesToJSON() throws {
        let payload = ContextPayload(currentFile: "Sources/main.swift", cursorLine: 42, cursorColumn: 10)
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(ContextPayload.self, from: data)
        #expect(decoded == payload)
    }

    @Test func contextPayloadWithNilValues() throws {
        let payload = ContextPayload(currentFile: nil, cursorLine: nil, cursorColumn: nil)
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(ContextPayload.self, from: data)
        #expect(decoded.currentFile == nil)
        #expect(decoded.cursorLine == nil)
        #expect(decoded.cursorColumn == nil)
    }

    @Test func contextPayloadEquality() {
        let a = ContextPayload(currentFile: "a.swift", cursorLine: 1, cursorColumn: 2)
        let b = ContextPayload(currentFile: "a.swift", cursorLine: 1, cursorColumn: 2)
        let c = ContextPayload(currentFile: "b.swift", cursorLine: 1, cursorColumn: 2)
        #expect(a == b)
        #expect(a != c)
    }

    // MARK: - File writing

    @Test func writesContextFileToProjectRoot() async throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let writer = ContextFileWriter()
        writer.setProjectRoot(tmpDir)
        writer.setDebounceInterval(0.01)

        writer.update(currentFile: "Sources/App.swift", cursorLine: 10, cursorColumn: 5)
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
        writer.setProjectRoot(tmpDir)
        writer.setDebounceInterval(0.05)

        // Rapid updates — only the last one should be written
        writer.update(currentFile: "a.swift", cursorLine: 1, cursorColumn: 1)
        writer.update(currentFile: "b.swift", cursorLine: 2, cursorColumn: 2)
        writer.update(currentFile: "c.swift", cursorLine: 3, cursorColumn: 3)

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
        writer.setProjectRoot(tmpDir)
        writer.setDebounceInterval(0.01)

        writer.update(currentFile: "test.swift", cursorLine: 1, cursorColumn: 1)
        try await Task.sleep(for: .milliseconds(50))

        let fileURL = tmpDir.appendingPathComponent(ContextFileWriter.fileName)
        #expect(FileManager.default.fileExists(atPath: fileURL.path))

        writer.cleanup()
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test func cleanupCancelsPendingWrite() async throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let writer = ContextFileWriter()
        writer.setProjectRoot(tmpDir)
        writer.setDebounceInterval(1.0) // Long debounce

        writer.update(currentFile: "test.swift", cursorLine: 1, cursorColumn: 1)
        #expect(writer.hasPendingWrite)

        writer.cleanup()
        #expect(!writer.hasPendingWrite)

        // File should not exist — the write was cancelled before it fired
        let fileURL = tmpDir.appendingPathComponent(ContextFileWriter.fileName)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test func cleanupWhenFileDoesNotExistOnDisk() throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let writer = ContextFileWriter()
        writer.setProjectRoot(tmpDir)

        // File was never written — cleanup should not crash
        writer.cleanup()

        let fileURL = tmpDir.appendingPathComponent(ContextFileWriter.fileName)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    // MARK: - Nil project root

    @Test func updateWithNilProjectRootDoesNotCrash() async throws {
        let writer = ContextFileWriter()
        // No project root set — should be a no-op
        writer.setDebounceInterval(0.01)
        writer.update(currentFile: "test.swift", cursorLine: 1, cursorColumn: 1)
        try await Task.sleep(for: .milliseconds(50))
        // No crash = pass
        #expect(writer.projectRoot == nil)
    }

    // MARK: - Context file URL

    @Test func contextFileURLReturnsCorrectPath() {
        let writer = ContextFileWriter()
        #expect(writer.contextFileURL == nil)

        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("test-project")
        writer.setProjectRoot(tmpDir)
        let expected = tmpDir.appendingPathComponent(ContextFileWriter.fileName)
        #expect(writer.contextFileURL == expected)
    }

    // MARK: - Relative path calculation

    @Test func relativePathFromProjectRoot() {
        let rootURL = URL(fileURLWithPath: "/Users/test/project")
        let fileURL = URL(fileURLWithPath: "/Users/test/project/Sources/App.swift")
        let rootPath = rootURL.path.hasSuffix("/")
            ? String(rootURL.path.dropLast())
            : rootURL.path
        let prefix = rootPath + "/"

        let relativePath: String? = fileURL.path.hasPrefix(prefix)
            ? String(fileURL.path.dropFirst(prefix.count))
            : fileURL.lastPathComponent

        #expect(relativePath == "Sources/App.swift")
    }

    @Test func relativePathForFileOutsideProject() {
        let rootURL = URL(fileURLWithPath: "/Users/test/project")
        let fileURL = URL(fileURLWithPath: "/Users/test/other/file.swift")
        let rootPath = rootURL.path.hasSuffix("/")
            ? String(rootURL.path.dropLast())
            : rootURL.path
        let prefix = rootPath + "/"

        let relativePath: String? = fileURL.path.hasPrefix(prefix)
            ? String(fileURL.path.dropFirst(prefix.count))
            : fileURL.lastPathComponent

        #expect(relativePath == "file.swift")
    }

    @Test func relativePathWithTrailingSlashInRoot() {
        // rootURL.path sometimes ends with "/" (e.g. volume root)
        let rootPath = "/Users/test/project/"
        let filePath = "/Users/test/project/Sources/App.swift"
        let normalized = rootPath.hasSuffix("/")
            ? String(rootPath.dropLast())
            : rootPath
        let prefix = normalized + "/"

        let relativePath: String? = filePath.hasPrefix(prefix)
            ? String(filePath.dropFirst(prefix.count))
            : URL(fileURLWithPath: filePath).lastPathComponent

        #expect(relativePath == "Sources/App.swift")
    }

    // MARK: - Written JSON is valid and readable by external tools

    @Test func writtenJSONIsReadableByDecoder() async throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let writer = ContextFileWriter()
        writer.setProjectRoot(tmpDir)
        writer.setDebounceInterval(0.01)

        writer.update(currentFile: "path/with \"quotes\".swift", cursorLine: 100, cursorColumn: 25)
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
        writer.setProjectRoot(tmpDir)
        writer.setDebounceInterval(0.01)

        writer.update(currentFile: nil, cursorLine: nil, cursorColumn: nil)
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
        writer.setProjectRoot(tmpDir)
        writer.setDebounceInterval(0.01)

        // First write
        writer.update(currentFile: "a.swift", cursorLine: 1, cursorColumn: 1)
        try await Task.sleep(for: .milliseconds(50))

        let fileURL = tmpDir.appendingPathComponent(ContextFileWriter.fileName)
        let firstModDate = try FileManager.default.attributesOfItem(
            atPath: fileURL.path
        )[.modificationDate] as? Date

        // Wait a bit so mod date would differ if file is rewritten
        try await Task.sleep(for: .milliseconds(100))

        // Same context — should skip the write
        writer.update(currentFile: "a.swift", cursorLine: 1, cursorColumn: 1)
        try await Task.sleep(for: .milliseconds(50))

        let secondModDate = try FileManager.default.attributesOfItem(
            atPath: fileURL.path
        )[.modificationDate] as? Date

        #expect(firstModDate == secondModDate)
    }

    // MARK: - Spaces in paths

    @Test func handlesSpacesInFilePaths() async throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let writer = ContextFileWriter()
        writer.setProjectRoot(tmpDir)
        writer.setDebounceInterval(0.01)

        writer.update(
            currentFile: "path/my project/Sources/App Manager.swift",
            cursorLine: 42,
            cursorColumn: 10
        )
        try await Task.sleep(for: .milliseconds(50))

        let decoded = try readPayload(in: tmpDir)
        #expect(decoded.currentFile == "path/my project/Sources/App Manager.swift")
    }

    // MARK: - Unicode in file names

    @Test func handlesUnicodeInFileNames() async throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let writer = ContextFileWriter()
        writer.setProjectRoot(tmpDir)
        writer.setDebounceInterval(0.01)

        writer.update(currentFile: "файл.swift", cursorLine: 1, cursorColumn: 1)
        try await Task.sleep(for: .milliseconds(50))

        let decoded = try readPayload(in: tmpDir)
        #expect(decoded.currentFile == "файл.swift")
    }

    @Test func handlesEmojiInFileNames() async throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let writer = ContextFileWriter()
        writer.setProjectRoot(tmpDir)
        writer.setDebounceInterval(0.01)

        writer.update(currentFile: "Sources/\u{1F680}rocket.swift", cursorLine: 5, cursorColumn: 3)
        try await Task.sleep(for: .milliseconds(50))

        let decoded = try readPayload(in: tmpDir)
        #expect(decoded.currentFile == "Sources/\u{1F680}rocket.swift")
    }

    // MARK: - Newline and tab in file names

    @Test func handlesNewlineInFileName() async throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let writer = ContextFileWriter()
        writer.setProjectRoot(tmpDir)
        writer.setDebounceInterval(0.01)

        writer.update(currentFile: "file\nname.swift", cursorLine: 1, cursorColumn: 1)
        try await Task.sleep(for: .milliseconds(50))

        let decoded = try readPayload(in: tmpDir)
        #expect(decoded.currentFile == "file\nname.swift")
    }

    @Test func handlesTabInFileName() async throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let writer = ContextFileWriter()
        writer.setProjectRoot(tmpDir)
        writer.setDebounceInterval(0.01)

        writer.update(currentFile: "file\tname.swift", cursorLine: 1, cursorColumn: 1)
        try await Task.sleep(for: .milliseconds(50))

        let decoded = try readPayload(in: tmpDir)
        #expect(decoded.currentFile == "file\tname.swift")
    }

    // MARK: - Backslash in paths

    @Test func handlesBackslashInPaths() async throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let writer = ContextFileWriter()
        writer.setProjectRoot(tmpDir)
        writer.setDebounceInterval(0.01)

        writer.update(currentFile: "path\\to\\file.swift", cursorLine: 1, cursorColumn: 1)
        try await Task.sleep(for: .milliseconds(50))

        let decoded = try readPayload(in: tmpDir)
        #expect(decoded.currentFile == "path\\to\\file.swift")
    }

    // MARK: - File permissions

    @Test func contextFileHasRestrictivePermissions() async throws {
        let tmpDir = try makeTmpDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let writer = ContextFileWriter()
        writer.setProjectRoot(tmpDir)
        writer.setDebounceInterval(0.01)

        writer.update(currentFile: "test.swift", cursorLine: 1, cursorColumn: 1)
        try await Task.sleep(for: .milliseconds(50))

        let fileURL = tmpDir.appendingPathComponent(ContextFileWriter.fileName)
        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let permissions = (attrs[.posixPermissions] as? NSNumber)?.uint16Value
        // 0o600 = 384 decimal = owner rw only
        #expect(permissions == 0o600)
    }
}
