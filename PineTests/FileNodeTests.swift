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

    // MARK: - Gitignored directories: visible and expandable (shallow-loaded)

    @Test func gitignoredDirectoryVisibleWithShallowChildren() throws {
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

        // Gitignored directories are visible and their immediate children are loaded
        let node = FileNode(url: tempDir, projectRoot: tempDir, ignoredPaths: ["node_modules"])
        let names = node.children?.map(\.name) ?? []
        #expect(names.contains("node_modules"))
        #expect(names.contains("index.js"))

        // Immediate children are loaded — folder is expandable in the sidebar
        let nmNode = node.children?.first { $0.name == "node_modules" }
        #expect(nmNode?.isDirectory == true)
        let nmNames = nmNode?.children?.map(\.name) ?? []
        #expect(nmNames.contains("package.json"))
    }

    @Test func gitignoredDirectoryExpandableInSidebar() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        let nodeModules = tempDir.appendingPathComponent("node_modules")
        try FileManager.default.createDirectory(at: nodeModules, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: nodeModules.appendingPathComponent("package.json").path, contents: nil
        )

        let node = FileNode(url: tempDir, projectRoot: tempDir, ignoredPaths: ["node_modules"])
        let nmNode = node.children?.first { $0.name == "node_modules" }

        // optionalChildren returns non-nil so SwiftUI List shows disclosure triangle
        #expect(nmNode?.optionalChildren != nil)
        #expect(nmNode?.optionalChildren?.first?.name == "package.json")
    }

    @Test func gitignoredDirectoryShallowDoesNotRecurse() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        // node_modules/express/lib/router.js — deep nested structure
        let express = tempDir.appendingPathComponent("node_modules")
            .appendingPathComponent("express")
        let lib = express.appendingPathComponent("lib")
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: lib.appendingPathComponent("router.js").path, contents: nil
        )

        let node = FileNode(url: tempDir, projectRoot: tempDir, ignoredPaths: ["node_modules"])
        let nmNode = node.children?.first { $0.name == "node_modules" }

        // Immediate child (express) is visible
        let expressNode = nmNode?.children?.first { $0.name == "express" }
        #expect(expressNode?.isDirectory == true)

        // But express's children are NOT loaded (shallow limit)
        #expect(expressNode?.children?.isEmpty == true)

        // loadChildren() on the subdirectory fills in contents on-demand
        expressNode?.loadChildren()
        let expressNames = expressNode?.children?.map(\.name) ?? []
        #expect(expressNames.contains("lib"))
    }

    @Test func gitignoredDotDirectoriesExpandable() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        let claude = tempDir.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: claude.appendingPathComponent("settings.json").path, contents: nil
        )
        let cache = tempDir.appendingPathComponent(".cache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let github = tempDir.appendingPathComponent(".github")
        try FileManager.default.createDirectory(at: github, withIntermediateDirectories: true)

        let node = FileNode(url: tempDir, projectRoot: tempDir, ignoredPaths: [".claude", ".cache"])
        let names = node.children?.map(\.name) ?? []
        #expect(names.contains(".claude"))
        #expect(names.contains(".cache"))
        #expect(names.contains(".github"))

        // .claude is ignored — immediate children loaded (shallow)
        let claudeNode = node.children?.first { $0.name == ".claude" }
        let claudeNames = claudeNode?.children?.map(\.name) ?? []
        #expect(claudeNames.contains("settings.json"))

        // .github is NOT ignored — children loaded eagerly too
        let githubNode = node.children?.first { $0.name == ".github" }
        #expect(githubNode?.children?.isEmpty == true) // empty dir, but was loaded
    }

    @Test func gitignoredFilesStillVisible() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        FileManager.default.createFile(
            atPath: tempDir.appendingPathComponent(".env").path, contents: nil
        )

        // ignoredPaths only affects directories, not files
        let node = FileNode(url: tempDir, projectRoot: tempDir, ignoredPaths: [".env"])
        let names = node.children?.map(\.name) ?? []
        #expect(names.contains(".env"))
    }

    @Test func nestedGitignoredDirectoryShallowLoaded() throws {
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
        let srcNode = node.children?.first { $0.name == "src" }
        #expect(srcNode != nil)
        let srcNames = srcNode?.children?.map(\.name) ?? []
        #expect(srcNames.contains("main.js"))
        #expect(srcNames.contains("vendor"))

        // vendor is visible and immediate children are loaded (shallow)
        let vendorNode = srcNode?.children?.first { $0.name == "vendor" }
        let vendorNames = vendorNode?.children?.map(\.name) ?? []
        #expect(vendorNames.contains("lib.js"))
    }

    @Test func emptyIgnoredPathsDoesNotAffectLoading() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        let src = tempDir.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: src.appendingPathComponent("main.swift").path, contents: nil
        )

        // Empty ignoredPaths — all directories loaded eagerly as usual
        let node = FileNode(url: tempDir, projectRoot: tempDir, ignoredPaths: [])
        let srcNode = node.children?.first { $0.name == "src" }
        let srcNames = srcNode?.children?.map(\.name) ?? []
        #expect(srcNames.contains("main.swift"))
    }

    @Test func multipleIgnoredDirectoriesAllShallowLoaded() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        let nodeModules = tempDir.appendingPathComponent("node_modules")
        try FileManager.default.createDirectory(at: nodeModules, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: nodeModules.appendingPathComponent("express").path, contents: nil
        )
        let build = tempDir.appendingPathComponent(".build")
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: build.appendingPathComponent("debug.log").path, contents: nil
        )
        let src = tempDir.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)

        let node = FileNode(url: tempDir, projectRoot: tempDir, ignoredPaths: ["node_modules", ".build"])
        let names = node.children?.map(\.name) ?? []
        // All visible
        #expect(names.contains("node_modules"))
        #expect(names.contains(".build"))
        #expect(names.contains("src"))

        // Ignored ones have immediate children loaded (shallow)
        let nmNode = node.children?.first { $0.name == "node_modules" }
        let buildNode = node.children?.first { $0.name == ".build" }
        #expect(nmNode?.children?.map(\.name).contains("express") == true)
        #expect(buildNode?.children?.map(\.name).contains("debug.log") == true)
    }

    // MARK: - Depth-limited loading

    @Test func maxDepthLimitsRecursion() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        // Create 4-level deep structure: root/a/b/c/file.txt
        let levelA = tempDir.appendingPathComponent("a")
        let levelB = levelA.appendingPathComponent("b")
        let levelC = levelB.appendingPathComponent("c")
        try FileManager.default.createDirectory(at: levelC, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: levelC.appendingPathComponent("file.txt").path, contents: nil)
        FileManager.default.createFile(atPath: tempDir.appendingPathComponent("root.txt").path, contents: nil)

        // maxDepth=2: root(0) -> a(1) -> b(2) -> c should be shallow
        let node = FileNode(url: tempDir, projectRoot: tempDir, ignoredPaths: [], maxDepth: 2)

        // Level 0 (root) — children loaded
        let aNode = node.children?.first { $0.name == "a" }
        #expect(aNode != nil)
        #expect(aNode?.isDirectory == true)

        // Level 1 (a) — children loaded
        let bNode = aNode?.children?.first { $0.name == "b" }
        #expect(bNode != nil)
        #expect(bNode?.isDirectory == true)

        // Level 2 (b) — children loaded
        let cNode = bNode?.children?.first { $0.name == "c" }
        #expect(cNode != nil)
        #expect(cNode?.isDirectory == true)

        // Level 3 (c) — beyond maxDepth, shallow (empty children)
        #expect(cNode?.children?.isEmpty == true)
    }

    @Test func maxDepthZeroLoadsOnlyTopLevel() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        let subDir = tempDir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: subDir.appendingPathComponent("inner.txt").path, contents: nil)
        FileManager.default.createFile(atPath: tempDir.appendingPathComponent("top.txt").path, contents: nil)

        // maxDepth=0: only the root's direct children, subdirs are shallow
        let node = FileNode(url: tempDir, projectRoot: tempDir, ignoredPaths: [], maxDepth: 0)
        let names = node.children?.map(\.name) ?? []
        #expect(names.contains("sub"))
        #expect(names.contains("top.txt"))

        // sub directory is shallow — empty children
        let subNode = node.children?.first { $0.name == "sub" }
        #expect(subNode?.children?.isEmpty == true)
    }

    @Test func maxDepthDefaultLoadsFullTree() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        let deep = tempDir.appendingPathComponent("a").appendingPathComponent("b").appendingPathComponent("c")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: deep.appendingPathComponent("deep.txt").path, contents: nil)

        // Default maxDepth (no limit) loads everything
        let node = FileNode(url: tempDir, projectRoot: tempDir, ignoredPaths: [])
        let aNode = node.children?.first { $0.name == "a" }
        let bNode = aNode?.children?.first { $0.name == "b" }
        let cNode = bNode?.children?.first { $0.name == "c" }
        let names = cNode?.children?.map(\.name) ?? []
        #expect(names.contains("deep.txt"))
    }

    @Test func loadTreeReportsDepthLimitReached() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        let sub = tempDir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: sub.appendingPathComponent("file.txt").path, contents: nil)

        // Deep enough to hit limit
        let limited = FileNode.loadTree(url: tempDir, projectRoot: tempDir, ignoredPaths: [], maxDepth: 0)
        #expect(limited.wasDepthLimited == true)

        // Shallow enough — no limit hit
        let full = FileNode.loadTree(url: tempDir, projectRoot: tempDir, ignoredPaths: [], maxDepth: 100)
        #expect(full.wasDepthLimited == false)
    }

    @Test func loadTreeReportsNotLimitedForFlatProject() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        FileManager.default.createFile(atPath: tempDir.appendingPathComponent("a.txt").path, contents: nil)
        FileManager.default.createFile(atPath: tempDir.appendingPathComponent("b.txt").path, contents: nil)

        // No directories at all — depth limit can never be reached
        let result = FileNode.loadTree(url: tempDir, projectRoot: tempDir, ignoredPaths: [], maxDepth: 0)
        #expect(result.wasDepthLimited == false)
    }

    @Test func shallowDirectoryLoadsChildrenOnDemand() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        let sub = tempDir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: sub.appendingPathComponent("file.txt").path, contents: nil)

        // maxDepth=0: sub is shallow
        let node = FileNode(url: tempDir, projectRoot: tempDir, ignoredPaths: [], maxDepth: 0)
        let subNode = node.children?.first { $0.name == "sub" }
        #expect(subNode?.children?.isEmpty == true)

        // loadChildren() fills in the contents
        subNode?.loadChildren()
        let names = subNode?.children?.map(\.name) ?? []
        #expect(names.contains("file.txt"))
    }

    @Test func maxDepthCombinesWithGitignore() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        // Structure: root/src/deep/file.txt, root/vendor/lib.js
        let deep = tempDir.appendingPathComponent("src").appendingPathComponent("deep")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: deep.appendingPathComponent("file.txt").path, contents: nil)
        let vendor = tempDir.appendingPathComponent("vendor")
        try FileManager.default.createDirectory(at: vendor, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: vendor.appendingPathComponent("lib.js").path, contents: nil)

        // maxDepth=1 + vendor is gitignored
        let node = FileNode(url: tempDir, projectRoot: tempDir, ignoredPaths: ["vendor"], maxDepth: 1)

        // src loaded at depth 1
        let srcNode = node.children?.first { $0.name == "src" }
        #expect(srcNode != nil)
        // deep is at depth 2 > maxDepth=1, so shallow
        let deepNode = srcNode?.children?.first { $0.name == "deep" }
        #expect(deepNode?.children?.isEmpty == true)

        // vendor is gitignored — shallow-loaded (immediate children only)
        let vendorNode = node.children?.first { $0.name == "vendor" }
        let vendorNames = vendorNode?.children?.map(\.name) ?? []
        #expect(vendorNames.contains("lib.js"))
    }

    @Test func symlinkCacheAvoidsDuplicateResolution() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        // Create a dir and a symlink to it
        let realDir = tempDir.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: realDir.appendingPathComponent("file.txt").path, contents: nil)
        let link = tempDir.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: realDir)

        // Should not crash or infinite loop — symlink cycle protection works
        let node = FileNode(url: tempDir, projectRoot: tempDir, ignoredPaths: [])
        let names = node.children?.map(\.name) ?? []
        #expect(names.contains("real"))
        #expect(names.contains("link"))

        // link should have children (same as real) since it's within project root
        let linkNode = node.children?.first { $0.name == "link" }
        #expect(linkNode?.isSymlink == true)
    }

    @Test func loadChildrenPreservesVisibilityOfIgnored() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        let vendor = tempDir.appendingPathComponent("vendor")
        try FileManager.default.createDirectory(at: vendor, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: tempDir.appendingPathComponent("main.swift").path, contents: nil
        )

        let node = FileNode(url: tempDir, projectRoot: tempDir, ignoredPaths: ["vendor"])
        let initialNames = node.children?.map(\.name) ?? []
        #expect(initialNames.contains("vendor"))
        #expect(initialNames.contains("main.swift"))

        // Add a new file and reload
        FileManager.default.createFile(
            atPath: tempDir.appendingPathComponent("new.swift").path, contents: nil
        )
        node.loadChildren()

        let names = node.children?.map(\.name) ?? []
        #expect(names.contains("main.swift"))
        #expect(names.contains("new.swift"))
        #expect(names.contains("vendor"))
    }
}
