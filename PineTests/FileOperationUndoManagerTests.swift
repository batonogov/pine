//
//  FileOperationUndoManagerTests.swift
//  PineTests
//

import Testing
import Foundation
@testable import Pine

struct FileOperationUndoManagerTests {

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PineUndoTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Delete undo

    @Test func deleteFileCanBeUndone() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let fileURL = dir.appendingPathComponent("hello.txt")
        try "content".write(to: fileURL, atomically: true, encoding: .utf8)

        let undoManager = UndoManager()
        let ops = FileOperationUndoManager()

        try ops.deleteItem(at: fileURL, undoManager: undoManager)

        #expect(!FileManager.default.fileExists(atPath: fileURL.path))

        undoManager.undo()

        #expect(FileManager.default.fileExists(atPath: fileURL.path))
        let restored = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(restored == "content")
    }

    @Test func deleteDirectoryCanBeUndone() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let subdir = dir.appendingPathComponent("myFolder")
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: false)
        let fileInside = subdir.appendingPathComponent("inner.txt")
        try "inner".write(to: fileInside, atomically: true, encoding: .utf8)

        let undoManager = UndoManager()
        let ops = FileOperationUndoManager()

        try ops.deleteItem(at: subdir, undoManager: undoManager)

        #expect(!FileManager.default.fileExists(atPath: subdir.path))

        undoManager.undo()

        #expect(FileManager.default.fileExists(atPath: subdir.path))
        let restored = try String(contentsOf: fileInside, encoding: .utf8)
        #expect(restored == "inner")
    }

    // MARK: - Rename undo

    @Test func renameFileCanBeUndone() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let oldURL = dir.appendingPathComponent("old.txt")
        try "data".write(to: oldURL, atomically: true, encoding: .utf8)
        let newURL = dir.appendingPathComponent("new.txt")

        let undoManager = UndoManager()
        let ops = FileOperationUndoManager()

        try ops.renameItem(from: oldURL, to: newURL, undoManager: undoManager)

        #expect(!FileManager.default.fileExists(atPath: oldURL.path))
        #expect(FileManager.default.fileExists(atPath: newURL.path))

        undoManager.undo()

        #expect(FileManager.default.fileExists(atPath: oldURL.path))
        #expect(!FileManager.default.fileExists(atPath: newURL.path))
        let content = try String(contentsOf: oldURL, encoding: .utf8)
        #expect(content == "data")
    }

    @Test func renameDirectoryCanBeUndone() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let oldURL = dir.appendingPathComponent("folderA")
        try FileManager.default.createDirectory(at: oldURL, withIntermediateDirectories: false)
        try "x".write(to: oldURL.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        let newURL = dir.appendingPathComponent("folderB")

        let undoManager = UndoManager()
        let ops = FileOperationUndoManager()

        try ops.renameItem(from: oldURL, to: newURL, undoManager: undoManager)

        #expect(!FileManager.default.fileExists(atPath: oldURL.path))
        #expect(FileManager.default.fileExists(atPath: newURL.path))

        undoManager.undo()

        #expect(FileManager.default.fileExists(atPath: oldURL.path))
        #expect(!FileManager.default.fileExists(atPath: newURL.path))
    }

    // MARK: - Create undo

    @Test func createFileCanBeUndone() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let fileURL = dir.appendingPathComponent("created.txt")

        let undoManager = UndoManager()
        let ops = FileOperationUndoManager()

        try ops.createItem(at: fileURL, isDirectory: false, undoManager: undoManager)

        #expect(FileManager.default.fileExists(atPath: fileURL.path))

        undoManager.undo()

        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test func createDirectoryCanBeUndone() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let folderURL = dir.appendingPathComponent("newFolder")

        let undoManager = UndoManager()
        let ops = FileOperationUndoManager()

        try ops.createItem(at: folderURL, isDirectory: true, undoManager: undoManager)

        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: folderURL.path, isDirectory: &isDir))
        #expect(isDir.boolValue)

        undoManager.undo()

        #expect(!FileManager.default.fileExists(atPath: folderURL.path))
    }

    // MARK: - Redo

    @Test func deleteRedoDeletesAgain() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let fileURL = dir.appendingPathComponent("redo.txt")
        try "redo".write(to: fileURL, atomically: true, encoding: .utf8)

        let undoManager = UndoManager()
        let ops = FileOperationUndoManager()

        try ops.deleteItem(at: fileURL, undoManager: undoManager)
        undoManager.undo()
        #expect(FileManager.default.fileExists(atPath: fileURL.path))

        undoManager.redo()
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test func renameRedoRenamesAgain() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let oldURL = dir.appendingPathComponent("a.txt")
        try "a".write(to: oldURL, atomically: true, encoding: .utf8)
        let newURL = dir.appendingPathComponent("b.txt")

        let undoManager = UndoManager()
        let ops = FileOperationUndoManager()

        try ops.renameItem(from: oldURL, to: newURL, undoManager: undoManager)
        undoManager.undo()
        #expect(FileManager.default.fileExists(atPath: oldURL.path))

        undoManager.redo()
        #expect(FileManager.default.fileExists(atPath: newURL.path))
        #expect(!FileManager.default.fileExists(atPath: oldURL.path))
    }

    @Test func createRedoRecreates() throws {
        let dir = try makeTempDir()
        defer { cleanup(dir) }

        let fileURL = dir.appendingPathComponent("redocreate.txt")

        let undoManager = UndoManager()
        let ops = FileOperationUndoManager()

        try ops.createItem(at: fileURL, isDirectory: false, undoManager: undoManager)
        undoManager.undo()
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))

        undoManager.redo()
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
    }

    // MARK: - Error cases

    @Test func deleteNonexistentFileThrows() {
        let ops = FileOperationUndoManager()
        let undoManager = UndoManager()
        let fakeURL = FileManager.default.temporaryDirectory.appendingPathComponent("nonexistent-\(UUID().uuidString)")

        #expect(throws: (any Error).self) {
            try ops.deleteItem(at: fakeURL, undoManager: undoManager)
        }
    }

    @Test func renameNonexistentFileThrows() {
        let ops = FileOperationUndoManager()
        let undoManager = UndoManager()
        let fakeURL = FileManager.default.temporaryDirectory.appendingPathComponent("nonexistent-\(UUID().uuidString)")
        let destURL = FileManager.default.temporaryDirectory.appendingPathComponent("dest-\(UUID().uuidString)")

        #expect(throws: (any Error).self) {
            try ops.renameItem(from: fakeURL, to: destURL, undoManager: undoManager)
        }
    }
}
