//
//  FileNodeTests.swift
//  PineTests
//

import Testing
import Foundation
@testable import Pine

struct FileNodeTests {

    private func makeTempDirectory() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PineTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    @Test func fileNodeDetectsFile() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        let fileURL = tempDir.appendingPathComponent("test.swift")
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)

        let node = FileNode(url: fileURL)
        #expect(node.isDirectory == false)
        #expect(node.name == "test.swift")
        #expect(node.children == nil)
        #expect(node.optionalChildren == nil)
    }

    @Test func fileNodeDetectsDirectory() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        let dirURL = tempDir.appendingPathComponent("Sources")
        try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)

        let node = FileNode(url: dirURL)
        #expect(node.isDirectory == true)
        #expect(node.name == "Sources")
    }

    @Test func fileNodeLoadsDirectoryContents() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        FileManager.default.createFile(
            atPath: tempDir.appendingPathComponent("b.swift").path, contents: nil
        )
        FileManager.default.createFile(
            atPath: tempDir.appendingPathComponent("a.swift").path, contents: nil
        )

        let node = FileNode(url: tempDir)
        #expect(node.isDirectory == true)
        #expect(node.children?.count == 2)
        // Should be sorted alphabetically
        #expect(node.children?[0].name == "a.swift")
        #expect(node.children?[1].name == "b.swift")
    }

    @Test func directoriesSortBeforeFiles() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        FileManager.default.createFile(
            atPath: tempDir.appendingPathComponent("zFile.txt").path, contents: nil
        )
        try FileManager.default.createDirectory(
            at: tempDir.appendingPathComponent("aDir"),
            withIntermediateDirectories: true
        )

        let node = FileNode(url: tempDir)
        #expect(node.children?.count == 2)
        #expect(node.children?[0].name == "aDir")
        #expect(node.children?[0].isDirectory == true)
        #expect(node.children?[1].name == "zFile.txt")
        #expect(node.children?[1].isDirectory == false)
    }

    @Test func dotfilesAreVisibleButGitIsHidden() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        FileManager.default.createFile(
            atPath: tempDir.appendingPathComponent(".gitignore").path, contents: nil
        )
        FileManager.default.createFile(
            atPath: tempDir.appendingPathComponent(".swiftlint.yml").path, contents: nil
        )
        try FileManager.default.createDirectory(
            at: tempDir.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(
            atPath: tempDir.appendingPathComponent(".DS_Store").path, contents: nil
        )
        FileManager.default.createFile(
            atPath: tempDir.appendingPathComponent("visible.txt").path, contents: nil
        )

        let node = FileNode(url: tempDir)
        let names = node.children?.map(\.name) ?? []
        #expect(names.contains(".gitignore"))
        #expect(names.contains(".swiftlint.yml"))
        #expect(names.contains("visible.txt"))
        #expect(!names.contains(".git"))
        #expect(!names.contains(".DS_Store"))
        #expect(node.children?.count == 3)
    }

    @Test func emptyDirectoryHasNilOptionalChildren() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        let emptyDir = tempDir.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)

        let node = FileNode(url: emptyDir)
        #expect(node.isDirectory == true)
        #expect(node.optionalChildren == nil)
    }

    @Test func loadChildrenRefreshes() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        let node = FileNode(url: tempDir)
        #expect(node.children?.isEmpty == true)

        // Add a file after initial load
        FileManager.default.createFile(
            atPath: tempDir.appendingPathComponent("new.txt").path, contents: nil
        )

        node.loadChildren()
        #expect(node.children?.count == 1)
        #expect(node.children?[0].name == "new.txt")
    }

    @Test func fileNodeEquality() throws {
        let url = URL(fileURLWithPath: "/tmp/test.swift")
        let node1 = FileNode(url: url)
        let node2 = FileNode(url: url)
        #expect(node1 == node2)
    }

    // MARK: - Gitignored directory filtering

    @Test func fileNodeSkipsIgnoredDirectories() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        let nodeModules = tempDir.appendingPathComponent("node_modules")
        try FileManager.default.createDirectory(at: nodeModules, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: nodeModules.appendingPathComponent("package.json").path, contents: nil
        )
        FileManager.default.createFile(
            atPath: tempDir.appendingPathComponent("index.js").path, contents: nil
        )

        let node = FileNode(url: tempDir, projectRoot: tempDir, ignoredPaths: ["node_modules"])
        let names = node.children?.map(\.name) ?? []
        #expect(!names.contains("node_modules"))
        #expect(names.contains("index.js"))
    }

    @Test func fileNodeKeepsNonIgnoredSiblings() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        let src = tempDir.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let vendor = tempDir.appendingPathComponent("vendor")
        try FileManager.default.createDirectory(at: vendor, withIntermediateDirectories: true)

        let node = FileNode(url: tempDir, projectRoot: tempDir, ignoredPaths: ["vendor"])
        let names = node.children?.map(\.name) ?? []
        #expect(names.contains("src"))
        #expect(!names.contains("vendor"))
    }

    @Test func fileNodeKeepsIgnoredFiles() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        // .env is a gitignored file (not a directory) — should remain visible
        FileManager.default.createFile(
            atPath: tempDir.appendingPathComponent(".env").path, contents: nil
        )

        let node = FileNode(url: tempDir, projectRoot: tempDir, ignoredPaths: [".env"])
        let names = node.children?.map(\.name) ?? []
        #expect(names.contains(".env"))
    }

    @Test func fileNodeEmptyIgnoredPathsDoesNotFilter() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        let src = tempDir.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: tempDir.appendingPathComponent("file.txt").path, contents: nil
        )

        // Empty ignoredPaths should not filter anything
        let node = FileNode(url: tempDir, projectRoot: tempDir, ignoredPaths: [])
        let names = node.children?.map(\.name) ?? []
        #expect(names.contains("src"))
        #expect(names.contains("file.txt"))
    }

    @Test func fileNodeSkipsMultipleIgnoredDirectories() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        let nodeModules = tempDir.appendingPathComponent("node_modules")
        try FileManager.default.createDirectory(at: nodeModules, withIntermediateDirectories: true)
        let build = tempDir.appendingPathComponent(".build")
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        let src = tempDir.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)

        let node = FileNode(url: tempDir, projectRoot: tempDir, ignoredPaths: ["node_modules", ".build"])
        let names = node.children?.map(\.name) ?? []
        #expect(!names.contains("node_modules"))
        #expect(!names.contains(".build"))
        #expect(names.contains("src"))
    }

    @Test func loadChildrenRespectsIgnoredPaths() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        let vendor = tempDir.appendingPathComponent("vendor")
        try FileManager.default.createDirectory(at: vendor, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: tempDir.appendingPathComponent("main.swift").path, contents: nil
        )

        let node = FileNode(url: tempDir, projectRoot: tempDir, ignoredPaths: ["vendor"])
        // Verify initial load skipped vendor
        let initialNames = node.children?.map(\.name) ?? []
        #expect(!initialNames.contains("vendor"))

        // Add a new file and reload via loadChildren
        FileManager.default.createFile(
            atPath: tempDir.appendingPathComponent("new.swift").path, contents: nil
        )
        node.loadChildren()

        let names = node.children?.map(\.name) ?? []
        #expect(names.contains("main.swift"))
        #expect(names.contains("new.swift"))
        #expect(!names.contains("vendor")) // Still filtered after reload
    }

    @Test func fileNodeSkipsNestedIgnoredPaths() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        let src = tempDir.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let vendor = src.appendingPathComponent("vendor")
        try FileManager.default.createDirectory(at: vendor, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: vendor.appendingPathComponent("lib.js").path, contents: nil
        )
        FileManager.default.createFile(
            atPath: src.appendingPathComponent("main.js").path, contents: nil
        )

        let node = FileNode(url: tempDir, projectRoot: tempDir, ignoredPaths: ["src/vendor"])
        // src should exist, but src/vendor should be skipped
        let srcNode = node.children?.first { $0.name == "src" }
        #expect(srcNode != nil)
        let srcNames = srcNode?.children?.map(\.name) ?? []
        #expect(srcNames.contains("main.js"))
        #expect(!srcNames.contains("vendor"))
    }
}
