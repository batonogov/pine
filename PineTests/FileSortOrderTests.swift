//
//  FileSortOrderTests.swift
//  PineTests
//

import Testing
import Foundation
@testable import Pine

struct FileSortOrderTests {

    private func makeTempDirectory() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PineSortTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func loadChildren(at tempDir: URL) -> [FileNode] {
        let node = FileNode(url: tempDir, projectRoot: tempDir, ignoredPaths: [])
        return node.children ?? []
    }

    // MARK: - Sort by name

    @Test func sortByNameAscending() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        FileManager.default.createFile(atPath: tempDir.appendingPathComponent("c.swift").path, contents: nil)
        FileManager.default.createFile(atPath: tempDir.appendingPathComponent("a.swift").path, contents: nil)
        FileManager.default.createFile(atPath: tempDir.appendingPathComponent("b.swift").path, contents: nil)

        let sorted = loadChildren(at: tempDir).sorted(by: .name, direction: .ascending)
        #expect(sorted.map(\.name) == ["a.swift", "b.swift", "c.swift"])
    }

    @Test func sortByNameDescending() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        FileManager.default.createFile(atPath: tempDir.appendingPathComponent("c.swift").path, contents: nil)
        FileManager.default.createFile(atPath: tempDir.appendingPathComponent("a.swift").path, contents: nil)
        FileManager.default.createFile(atPath: tempDir.appendingPathComponent("b.swift").path, contents: nil)

        let sorted = loadChildren(at: tempDir).sorted(by: .name, direction: .descending)
        #expect(sorted.map(\.name) == ["c.swift", "b.swift", "a.swift"])
    }

    // MARK: - Sort by type

    @Test func sortByTypeAscending() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        FileManager.default.createFile(atPath: tempDir.appendingPathComponent("b.swift").path, contents: nil)
        FileManager.default.createFile(atPath: tempDir.appendingPathComponent("a.json").path, contents: nil)
        FileManager.default.createFile(atPath: tempDir.appendingPathComponent("c.md").path, contents: nil)

        let sorted = loadChildren(at: tempDir).sorted(by: .type, direction: .ascending)
        // Sorted by extension: json < md < swift
        #expect(sorted.map(\.name) == ["a.json", "c.md", "b.swift"])
    }

    @Test func sortByTypeSameExtensionFallsBackToName() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        FileManager.default.createFile(atPath: tempDir.appendingPathComponent("z.swift").path, contents: nil)
        FileManager.default.createFile(atPath: tempDir.appendingPathComponent("a.swift").path, contents: nil)
        FileManager.default.createFile(atPath: tempDir.appendingPathComponent("m.swift").path, contents: nil)

        let sorted = loadChildren(at: tempDir).sorted(by: .type, direction: .ascending)
        // Same extension → alphabetical by name
        #expect(sorted.map(\.name) == ["a.swift", "m.swift", "z.swift"])
    }

    @Test func sortByTypeDescending() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        FileManager.default.createFile(atPath: tempDir.appendingPathComponent("b.swift").path, contents: nil)
        FileManager.default.createFile(atPath: tempDir.appendingPathComponent("a.json").path, contents: nil)
        FileManager.default.createFile(atPath: tempDir.appendingPathComponent("c.md").path, contents: nil)

        let sorted = loadChildren(at: tempDir).sorted(by: .type, direction: .descending)
        // Descending by extension: swift > md > json
        #expect(sorted.map(\.name) == ["b.swift", "c.md", "a.json"])
    }

    // MARK: - Sort by size

    @Test func sortBySizeAscending() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        let small = Data("hi".utf8)
        let medium = Data(String(repeating: "x", count: 100).utf8)
        let large = Data(String(repeating: "y", count: 1000).utf8)

        FileManager.default.createFile(atPath: tempDir.appendingPathComponent("large.txt").path, contents: large)
        FileManager.default.createFile(atPath: tempDir.appendingPathComponent("small.txt").path, contents: small)
        FileManager.default.createFile(atPath: tempDir.appendingPathComponent("medium.txt").path, contents: medium)

        let sorted = loadChildren(at: tempDir).sorted(by: .size, direction: .ascending)
        #expect(sorted.map(\.name) == ["small.txt", "medium.txt", "large.txt"])
    }

    @Test func sortBySizeDescending() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        let small = Data("hi".utf8)
        let large = Data(String(repeating: "y", count: 1000).utf8)

        FileManager.default.createFile(atPath: tempDir.appendingPathComponent("large.txt").path, contents: large)
        FileManager.default.createFile(atPath: tempDir.appendingPathComponent("small.txt").path, contents: small)

        let sorted = loadChildren(at: tempDir).sorted(by: .size, direction: .descending)
        #expect(sorted.map(\.name) == ["large.txt", "small.txt"])
    }

    @Test func sortBySizeSameSizeFallsBackToName() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        let data = Data("abc".utf8)
        FileManager.default.createFile(atPath: tempDir.appendingPathComponent("z.txt").path, contents: data)
        FileManager.default.createFile(atPath: tempDir.appendingPathComponent("a.txt").path, contents: data)

        let sorted = loadChildren(at: tempDir).sorted(by: .size, direction: .ascending)
        // Same size → alphabetical by name
        #expect(sorted.map(\.name) == ["a.txt", "z.txt"])
    }

    // MARK: - Directories always first

    @Test func directoriesAlwaysFirstRegardlessOfSortOrder() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        FileManager.default.createFile(atPath: tempDir.appendingPathComponent("a.txt").path,
                                       contents: Data("large content to be big".utf8))
        try FileManager.default.createDirectory(
            at: tempDir.appendingPathComponent("zDir"), withIntermediateDirectories: true
        )

        // Even sorted by size ascending, directory should appear first
        let sorted = loadChildren(at: tempDir).sorted(by: .size, direction: .ascending)
        #expect(sorted.first?.isDirectory == true)
        #expect(sorted.first?.name == "zDir")
    }

    // MARK: - Date modified

    @Test func sortByDateModifiedAscending() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        let olderURL = tempDir.appendingPathComponent("older.txt")
        let newerURL = tempDir.appendingPathComponent("newer.txt")

        FileManager.default.createFile(atPath: olderURL.path, contents: nil)
        let oldDate = Date(timeIntervalSinceNow: -3600)
        let newDate = Date(timeIntervalSinceNow: -10)
        try FileManager.default.setAttributes(
            [.modificationDate: oldDate], ofItemAtPath: olderURL.path
        )
        FileManager.default.createFile(atPath: newerURL.path, contents: nil)
        try FileManager.default.setAttributes(
            [.modificationDate: newDate], ofItemAtPath: newerURL.path
        )

        let sorted = loadChildren(at: tempDir).sorted(by: .dateModified, direction: .ascending)
        #expect(sorted.map(\.name) == ["older.txt", "newer.txt"])
    }

    @Test func sortByDateModifiedDescending() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        let olderURL = tempDir.appendingPathComponent("older.txt")
        let newerURL = tempDir.appendingPathComponent("newer.txt")

        FileManager.default.createFile(atPath: olderURL.path, contents: nil)
        let oldDate = Date(timeIntervalSinceNow: -3600)
        let newDate = Date(timeIntervalSinceNow: -10)
        try FileManager.default.setAttributes(
            [.modificationDate: oldDate], ofItemAtPath: olderURL.path
        )
        FileManager.default.createFile(atPath: newerURL.path, contents: nil)
        try FileManager.default.setAttributes(
            [.modificationDate: newDate], ofItemAtPath: newerURL.path
        )

        let sorted = loadChildren(at: tempDir).sorted(by: .dateModified, direction: .descending)
        #expect(sorted.map(\.name) == ["newer.txt", "older.txt"])
    }

    // MARK: - Recursive sort

    @Test func recursiveSortSortsNestedChildren() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        let subDir = tempDir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: subDir.appendingPathComponent("z.txt").path, contents: nil)
        FileManager.default.createFile(atPath: subDir.appendingPathComponent("a.txt").path, contents: nil)
        FileManager.default.createFile(atPath: tempDir.appendingPathComponent("m.txt").path, contents: nil)

        let children = loadChildren(at: tempDir)
        let sorted = children.recursiveSorted(by: .name, direction: .descending)

        // Top level: directory first, then file
        #expect(sorted.map(\.name) == ["sub", "m.txt"])
        // Nested children also sorted descending
        let subChildren = sorted.first?.children ?? []
        #expect(subChildren.map(\.name) == ["z.txt", "a.txt"])
    }

    // MARK: - Sort preferences persistence

    @Test func fileSortOrderRawValueRoundTrips() {
        for order in FileSortOrder.allCases {
            let raw = order.rawValue
            #expect(FileSortOrder(rawValue: raw) == order)
        }
    }

    @Test func fileSortDirectionRawValueRoundTrips() {
        #expect(FileSortDirection(rawValue: "ascending") == .ascending)
        #expect(FileSortDirection(rawValue: "descending") == .descending)
        #expect(FileSortDirection(rawValue: "invalid") == nil)
    }

    // MARK: - Metadata properties

    @Test func fileNodeHasModificationDate() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        let fileURL = tempDir.appendingPathComponent("test.txt")
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)

        let node = FileNode(url: fileURL)
        #expect(node.modificationDate != nil)
    }

    @Test func fileNodeHasFileSize() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        let data = Data("hello world".utf8)
        let fileURL = tempDir.appendingPathComponent("test.txt")
        FileManager.default.createFile(atPath: fileURL.path, contents: data)

        let node = FileNode(url: fileURL)
        #expect(node.fileSize == data.count)
    }

    @Test func loadTreeChildrenCanBeSorted() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        FileManager.default.createFile(atPath: tempDir.appendingPathComponent("z.txt").path, contents: nil)
        FileManager.default.createFile(atPath: tempDir.appendingPathComponent("a.txt").path, contents: nil)

        let result = FileNode.loadTree(
            url: tempDir, projectRoot: tempDir,
            ignoredPaths: [], maxDepth: 5
        )
        let sorted = (result.root.children ?? []).sorted(by: .name, direction: .descending)
        #expect(sorted.map(\.name) == ["z.txt", "a.txt"])
    }
}
