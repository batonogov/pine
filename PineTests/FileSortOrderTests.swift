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

    // MARK: - Sort by name

    @Test func sortByNameAscending() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        FileManager.default.createFile(atPath: tempDir.appendingPathComponent("c.swift").path, contents: nil)
        FileManager.default.createFile(atPath: tempDir.appendingPathComponent("a.swift").path, contents: nil)
        FileManager.default.createFile(atPath: tempDir.appendingPathComponent("b.swift").path, contents: nil)

        let node = FileNode(url: tempDir, projectRoot: tempDir, ignoredPaths: [],
                            sortOrder: .name, sortDirection: .ascending)
        let names = node.children?.map(\.name) ?? []
        #expect(names == ["a.swift", "b.swift", "c.swift"])
    }

    @Test func sortByNameDescending() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        FileManager.default.createFile(atPath: tempDir.appendingPathComponent("c.swift").path, contents: nil)
        FileManager.default.createFile(atPath: tempDir.appendingPathComponent("a.swift").path, contents: nil)
        FileManager.default.createFile(atPath: tempDir.appendingPathComponent("b.swift").path, contents: nil)

        let node = FileNode(url: tempDir, projectRoot: tempDir, ignoredPaths: [],
                            sortOrder: .name, sortDirection: .descending)
        let names = node.children?.map(\.name) ?? []
        #expect(names == ["c.swift", "b.swift", "a.swift"])
    }

    // MARK: - Sort by type

    @Test func sortByTypeAscending() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        FileManager.default.createFile(atPath: tempDir.appendingPathComponent("b.swift").path, contents: nil)
        FileManager.default.createFile(atPath: tempDir.appendingPathComponent("a.json").path, contents: nil)
        FileManager.default.createFile(atPath: tempDir.appendingPathComponent("c.md").path, contents: nil)

        let node = FileNode(url: tempDir, projectRoot: tempDir, ignoredPaths: [],
                            sortOrder: .type, sortDirection: .ascending)
        let names = node.children?.map(\.name) ?? []
        // Sorted by extension: json < md < swift
        #expect(names == ["a.json", "c.md", "b.swift"])
    }

    @Test func sortByTypeSameExtensionFallsBackToName() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        FileManager.default.createFile(atPath: tempDir.appendingPathComponent("z.swift").path, contents: nil)
        FileManager.default.createFile(atPath: tempDir.appendingPathComponent("a.swift").path, contents: nil)
        FileManager.default.createFile(atPath: tempDir.appendingPathComponent("m.swift").path, contents: nil)

        let node = FileNode(url: tempDir, projectRoot: tempDir, ignoredPaths: [],
                            sortOrder: .type, sortDirection: .ascending)
        let names = node.children?.map(\.name) ?? []
        // Same extension → alphabetical by name
        #expect(names == ["a.swift", "m.swift", "z.swift"])
    }

    @Test func sortByTypeDescending() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        FileManager.default.createFile(atPath: tempDir.appendingPathComponent("b.swift").path, contents: nil)
        FileManager.default.createFile(atPath: tempDir.appendingPathComponent("a.json").path, contents: nil)
        FileManager.default.createFile(atPath: tempDir.appendingPathComponent("c.md").path, contents: nil)

        let node = FileNode(url: tempDir, projectRoot: tempDir, ignoredPaths: [],
                            sortOrder: .type, sortDirection: .descending)
        let names = node.children?.map(\.name) ?? []
        // Descending by extension: swift > md > json
        #expect(names == ["b.swift", "c.md", "a.json"])
    }

    // MARK: - Sort by size

    @Test func sortBySizeAscending() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        let small = "hi".data(using: .utf8)!
        let medium = String(repeating: "x", count: 100).data(using: .utf8)!
        let large = String(repeating: "y", count: 1000).data(using: .utf8)!

        FileManager.default.createFile(atPath: tempDir.appendingPathComponent("large.txt").path, contents: large)
        FileManager.default.createFile(atPath: tempDir.appendingPathComponent("small.txt").path, contents: small)
        FileManager.default.createFile(atPath: tempDir.appendingPathComponent("medium.txt").path, contents: medium)

        let node = FileNode(url: tempDir, projectRoot: tempDir, ignoredPaths: [],
                            sortOrder: .size, sortDirection: .ascending)
        let names = node.children?.map(\.name) ?? []
        #expect(names == ["small.txt", "medium.txt", "large.txt"])
    }

    @Test func sortBySizeDescending() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        let small = "hi".data(using: .utf8)!
        let large = String(repeating: "y", count: 1000).data(using: .utf8)!

        FileManager.default.createFile(atPath: tempDir.appendingPathComponent("large.txt").path, contents: large)
        FileManager.default.createFile(atPath: tempDir.appendingPathComponent("small.txt").path, contents: small)

        let node = FileNode(url: tempDir, projectRoot: tempDir, ignoredPaths: [],
                            sortOrder: .size, sortDirection: .descending)
        let names = node.children?.map(\.name) ?? []
        #expect(names == ["large.txt", "small.txt"])
    }

    @Test func sortBySizeSameSizeFallsBackToName() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        let data = "abc".data(using: .utf8)!
        FileManager.default.createFile(atPath: tempDir.appendingPathComponent("z.txt").path, contents: data)
        FileManager.default.createFile(atPath: tempDir.appendingPathComponent("a.txt").path, contents: data)

        let node = FileNode(url: tempDir, projectRoot: tempDir, ignoredPaths: [],
                            sortOrder: .size, sortDirection: .ascending)
        let names = node.children?.map(\.name) ?? []
        // Same size → alphabetical by name
        #expect(names == ["a.txt", "z.txt"])
    }

    // MARK: - Directories always first

    @Test func directoriesAlwaysFirstRegardlessOfSortOrder() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        FileManager.default.createFile(atPath: tempDir.appendingPathComponent("a.txt").path,
                                       contents: "large content to be big".data(using: .utf8))
        try FileManager.default.createDirectory(
            at: tempDir.appendingPathComponent("zDir"), withIntermediateDirectories: true
        )

        // Even sorted by size ascending, directory should appear first
        let node = FileNode(url: tempDir, projectRoot: tempDir, ignoredPaths: [],
                            sortOrder: .size, sortDirection: .ascending)
        let children = node.children ?? []
        #expect(children.first?.isDirectory == true)
        #expect(children.first?.name == "zDir")
    }

    // MARK: - Date modified

    @Test func sortByDateModifiedAscending() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        // Create files with deliberate modification date ordering
        let olderURL = tempDir.appendingPathComponent("older.txt")
        let newerURL = tempDir.appendingPathComponent("newer.txt")

        FileManager.default.createFile(atPath: olderURL.path, contents: nil)
        // Force modification dates to be meaningfully different
        let oldDate = Date(timeIntervalSinceNow: -3600)
        let newDate = Date(timeIntervalSinceNow: -10)
        try FileManager.default.setAttributes(
            [.modificationDate: oldDate], ofItemAtPath: olderURL.path
        )
        FileManager.default.createFile(atPath: newerURL.path, contents: nil)
        try FileManager.default.setAttributes(
            [.modificationDate: newDate], ofItemAtPath: newerURL.path
        )

        let node = FileNode(url: tempDir, projectRoot: tempDir, ignoredPaths: [],
                            sortOrder: .dateModified, sortDirection: .ascending)
        let names = node.children?.map(\.name) ?? []
        #expect(names == ["older.txt", "newer.txt"])
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

        let node = FileNode(url: tempDir, projectRoot: tempDir, ignoredPaths: [],
                            sortOrder: .dateModified, sortDirection: .descending)
        let names = node.children?.map(\.name) ?? []
        #expect(names == ["newer.txt", "older.txt"])
    }

    // MARK: - Static sorted() helper

    @Test func staticSortedByNameAscending() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        let urls = ["c.txt", "a.txt", "b.txt"].map { tempDir.appendingPathComponent($0) }
        for url in urls {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let nodes = urls.map { FileNode(url: $0) }
        let sorted = FileNode.sorted(nodes, by: .name, direction: .ascending)
        #expect(sorted.map(\.name) == ["a.txt", "b.txt", "c.txt"])
    }

    @Test func staticSortedByNameDescending() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        let urls = ["c.txt", "a.txt", "b.txt"].map { tempDir.appendingPathComponent($0) }
        for url in urls {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let nodes = urls.map { FileNode(url: $0) }
        let sorted = FileNode.sorted(nodes, by: .name, direction: .descending)
        #expect(sorted.map(\.name) == ["c.txt", "b.txt", "a.txt"])
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

    @Test func sortDirectionToggled() {
        #expect(FileSortDirection.ascending.toggled == .descending)
        #expect(FileSortDirection.descending.toggled == .ascending)
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

        let data = "hello world".data(using: .utf8)!
        let fileURL = tempDir.appendingPathComponent("test.txt")
        FileManager.default.createFile(atPath: fileURL.path, contents: data)

        let node = FileNode(url: fileURL)
        #expect(node.fileSize == data.count)
    }

    @Test func loadTreePassesSortOrderToChildren() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        FileManager.default.createFile(atPath: tempDir.appendingPathComponent("z.txt").path, contents: nil)
        FileManager.default.createFile(atPath: tempDir.appendingPathComponent("a.txt").path, contents: nil)

        let result = FileNode.loadTree(
            url: tempDir, projectRoot: tempDir,
            ignoredPaths: [], maxDepth: 5,
            sortOrder: .name, sortDirection: .descending
        )
        let names = result.root.children?.map(\.name) ?? []
        #expect(names == ["z.txt", "a.txt"])
    }
}
