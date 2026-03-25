//
//  ContextFileWriterTests.swift
//  PineTests
//

import Testing
import Foundation
@testable import Pine

struct ContextFileWriterTests {

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
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let writer = ContextFileWriter()
        writer.setProjectRoot(tmpDir)
        writer.setDebounceInterval(0.01)

        writer.update(currentFile: "Sources/App.swift", cursorLine: 10, cursorColumn: 5)

        // Wait for debounce to fire
        try await Task.sleep(for: .milliseconds(50))

        let fileURL = tmpDir.appendingPathComponent(ContextFileWriter.fileName)
        let data = try Data(contentsOf: fileURL)
        let decoded = try JSONDecoder().decode(ContextPayload.self, from: data)
        #expect(decoded.currentFile == "Sources/App.swift")
        #expect(decoded.cursorLine == 10)
        #expect(decoded.cursorColumn == 5)
    }

    // MARK: - Debounce behavior

    @Test func debounceCoalescesRapidUpdates() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let writer = ContextFileWriter()
        writer.setProjectRoot(tmpDir)
        writer.setDebounceInterval(0.05)

        // Rapid updates — only the last one should be written
        writer.update(currentFile: "a.swift", cursorLine: 1, cursorColumn: 1)
        writer.update(currentFile: "b.swift", cursorLine: 2, cursorColumn: 2)
        writer.update(currentFile: "c.swift", cursorLine: 3, cursorColumn: 3)

        // Wait for debounce
        try await Task.sleep(for: .milliseconds(100))

        let fileURL = tmpDir.appendingPathComponent(ContextFileWriter.fileName)
        let data = try Data(contentsOf: fileURL)
        let decoded = try JSONDecoder().decode(ContextPayload.self, from: data)
        #expect(decoded.currentFile == "c.swift")
        #expect(decoded.cursorLine == 3)
        #expect(decoded.cursorColumn == 3)
    }

    // MARK: - Cleanup

    @Test func cleanupRemovesFile() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
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
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
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
        // This tests the logic in ProjectManager.updateEditorContext()
        let rootURL = URL(fileURLWithPath: "/Users/test/project")
        let fileURL = URL(fileURLWithPath: "/Users/test/project/Sources/App.swift")
        let rootPath = rootURL.path + "/"

        let relativePath: String? = fileURL.path.hasPrefix(rootPath)
            ? String(fileURL.path.dropFirst(rootPath.count))
            : fileURL.lastPathComponent

        #expect(relativePath == "Sources/App.swift")
    }

    @Test func relativePathForFileOutsideProject() {
        let rootURL = URL(fileURLWithPath: "/Users/test/project")
        let fileURL = URL(fileURLWithPath: "/Users/test/other/file.swift")
        let rootPath = rootURL.path + "/"

        let relativePath: String? = fileURL.path.hasPrefix(rootPath)
            ? String(fileURL.path.dropFirst(rootPath.count))
            : fileURL.lastPathComponent

        #expect(relativePath == "file.swift")
    }

    // MARK: - Written JSON is valid and readable by external tools

    @Test func writtenJSONIsReadableByDecoder() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let writer = ContextFileWriter()
        writer.setProjectRoot(tmpDir)
        writer.setDebounceInterval(0.01)

        writer.update(currentFile: "path/with \"quotes\".swift", cursorLine: 100, cursorColumn: 25)
        try await Task.sleep(for: .milliseconds(50))

        let fileURL = tmpDir.appendingPathComponent(ContextFileWriter.fileName)
        let data = try Data(contentsOf: fileURL)
        let decoded = try JSONDecoder().decode(ContextPayload.self, from: data)
        #expect(decoded.currentFile == "path/with \"quotes\".swift")
        #expect(decoded.cursorLine == 100)
        #expect(decoded.cursorColumn == 25)
    }

    @Test func writtenJSONWithNullValues() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let writer = ContextFileWriter()
        writer.setProjectRoot(tmpDir)
        writer.setDebounceInterval(0.01)

        writer.update(currentFile: nil, cursorLine: nil, cursorColumn: nil)
        try await Task.sleep(for: .milliseconds(50))

        let fileURL = tmpDir.appendingPathComponent(ContextFileWriter.fileName)
        let data = try Data(contentsOf: fileURL)
        let decoded = try JSONDecoder().decode(ContextPayload.self, from: data)
        #expect(decoded.currentFile == nil)
        #expect(decoded.cursorLine == nil)
        #expect(decoded.cursorColumn == nil)
    }

    // MARK: - Skips redundant writes

    @Test func skipsRedundantWriteForSameContext() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
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
}
