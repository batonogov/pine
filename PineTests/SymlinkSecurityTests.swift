//
//  SymlinkSecurityTests.swift
//  PineTests
//

import Testing
import Foundation
@testable import Pine

struct SymlinkSecurityTests {

    private func makeTempDirectory() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PineSymlinkTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Symlink outside project root

    @Test func symlinkOutsideProjectRootIsNotExpanded() throws {
        let projectDir = try makeTempDirectory()
        let outsideDir = try makeTempDirectory()
        defer {
            cleanup(projectDir)
            cleanup(outsideDir)
        }

        // Create a file inside the outside directory
        FileManager.default.createFile(
            atPath: outsideDir.appendingPathComponent("secret.txt").path,
            contents: Data("secret".utf8)
        )

        // Create a symlink inside the project pointing outside
        let symlinkURL = projectDir.appendingPathComponent("external")
        try FileManager.default.createSymbolicLink(
            at: symlinkURL,
            withDestinationURL: outsideDir
        )

        let root = FileNode(url: projectDir, projectRoot: projectDir)

        // The symlink should appear in the tree
        let externalNode = root.children?.first { $0.name == "external" }
        #expect(externalNode != nil)

        // But it should NOT have children loaded (not expanded)
        #expect(externalNode?.children == nil || externalNode?.children?.isEmpty == true)
        #expect(externalNode?.isSymlink == true)
    }

    @Test func symlinkToFileOutsideProjectRootStillVisible() throws {
        let projectDir = try makeTempDirectory()
        let outsideDir = try makeTempDirectory()
        defer {
            cleanup(projectDir)
            cleanup(outsideDir)
        }

        let outsideFile = outsideDir.appendingPathComponent("data.txt")
        FileManager.default.createFile(atPath: outsideFile.path, contents: Data("data".utf8))

        // Symlink to a file outside project
        let symlinkURL = projectDir.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: outsideFile)

        let root = FileNode(url: projectDir, projectRoot: projectDir)

        let linkNode = root.children?.first { $0.name == "link.txt" }
        #expect(linkNode != nil)
        #expect(linkNode?.isSymlink == true)
        #expect(linkNode?.isDirectory == false)
    }

    // MARK: - Symlink cycle detection

    @Test func selfReferencingSymlinkDoesNotCrash() throws {
        let projectDir = try makeTempDirectory()
        defer { cleanup(projectDir) }

        // Create a symlink that points to its own parent: loop -> .
        let loopURL = projectDir.appendingPathComponent("loop")
        try FileManager.default.createSymbolicLink(
            atPath: loopURL.path,
            withDestinationPath: "."
        )

        // This must not hang or crash
        let root = FileNode(url: projectDir, projectRoot: projectDir)

        let loopNode = root.children?.first { $0.name == "loop" }
        #expect(loopNode != nil)
        #expect(loopNode?.isSymlink == true)
        // Should not have recursively loaded children (cycle)
        #expect(loopNode?.children == nil || loopNode?.children?.isEmpty == true)
    }

    @Test func ancestorSymlinkCycleDoesNotCrash() throws {
        let projectDir = try makeTempDirectory()
        defer { cleanup(projectDir) }

        // Create nested structure: sub/ancestor -> projectDir
        let subDir = projectDir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)

        let ancestorLink = subDir.appendingPathComponent("ancestor")
        try FileManager.default.createSymbolicLink(
            at: ancestorLink,
            withDestinationURL: projectDir
        )

        // This must not hang or crash
        let root = FileNode(url: projectDir, projectRoot: projectDir)

        let subNode = root.children?.first { $0.name == "sub" }
        #expect(subNode != nil)

        let ancestorNode = subNode?.children?.first { $0.name == "ancestor" }
        #expect(ancestorNode != nil)
        #expect(ancestorNode?.isSymlink == true)
        // Cycle: ancestor resolves to projectDir which is already visited
        #expect(ancestorNode?.children == nil || ancestorNode?.children?.isEmpty == true)
    }

    @Test func mutualSymlinkCycleDoesNotCrash() throws {
        let projectDir = try makeTempDirectory()
        defer { cleanup(projectDir) }

        // A -> B, B -> A
        let dirA = projectDir.appendingPathComponent("a")
        let dirB = projectDir.appendingPathComponent("b")
        try FileManager.default.createSymbolicLink(at: dirA, withDestinationURL: dirB)
        try FileManager.default.createSymbolicLink(at: dirB, withDestinationURL: dirA)

        // Must not hang or crash
        let root = FileNode(url: projectDir, projectRoot: projectDir)

        let nodeA = root.children?.first { $0.name == "a" }
        let nodeB = root.children?.first { $0.name == "b" }
        #expect(nodeA != nil)
        #expect(nodeB != nil)
        #expect(nodeA?.isSymlink == true)
        #expect(nodeB?.isSymlink == true)
    }

    @Test func danglingSymlinkDoesNotCrash() throws {
        let projectDir = try makeTempDirectory()
        defer { cleanup(projectDir) }

        // Symlink to a path that does not exist
        try FileManager.default.createSymbolicLink(
            atPath: projectDir.appendingPathComponent("broken").path,
            withDestinationPath: "/nonexistent/path/that/does/not/exist"
        )

        // Must not crash
        let root = FileNode(url: projectDir, projectRoot: projectDir)

        let brokenNode = root.children?.first { $0.name == "broken" }
        #expect(brokenNode != nil)
        #expect(brokenNode?.isSymlink == true)
    }

    // MARK: - Valid symlinks within project are fine

    @Test func symlinkWithinProjectRootIsVisible() throws {
        let projectDir = try makeTempDirectory()
        defer { cleanup(projectDir) }

        // Create a real subdirectory with a file
        let realDir = projectDir.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: realDir.appendingPathComponent("file.txt").path,
            contents: nil
        )

        // Create a symlink to it (within the project)
        let linkDir = projectDir.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: linkDir, withDestinationURL: realDir)

        let root = FileNode(url: projectDir, projectRoot: projectDir)

        // Both the real dir and the symlink should appear in the tree
        let linkNode = root.children?.first { $0.name == "link" }
        let realNode = root.children?.first { $0.name == "real" }
        #expect(linkNode != nil)
        #expect(realNode != nil)
        #expect(linkNode?.isSymlink == true)
        #expect(linkNode?.isDirectory == true)
        #expect(realNode?.isSymlink == false)
    }

    // MARK: - loadChildren preserves protection

    @Test func loadChildrenPreservesSymlinkProtection() throws {
        let projectDir = try makeTempDirectory()
        let outsideDir = try makeTempDirectory()
        defer {
            cleanup(projectDir)
            cleanup(outsideDir)
        }

        FileManager.default.createFile(
            atPath: outsideDir.appendingPathComponent("secret.txt").path,
            contents: Data("secret".utf8)
        )

        let symlinkURL = projectDir.appendingPathComponent("external")
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: outsideDir)

        let root = FileNode(url: projectDir, projectRoot: projectDir)

        // After loadChildren (simulating a refresh), protection must still be active
        root.loadChildren()

        let externalNode = root.children?.first { $0.name == "external" }
        #expect(externalNode != nil)
        #expect(externalNode?.isSymlink == true)
        #expect(externalNode?.children == nil || externalNode?.children?.isEmpty == true)
    }

    // MARK: - isSymlink property

    @Test func regularFileIsNotSymlink() throws {
        let projectDir = try makeTempDirectory()
        defer { cleanup(projectDir) }

        let fileURL = projectDir.appendingPathComponent("regular.txt")
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)

        let node = FileNode(url: fileURL)
        #expect(node.isSymlink == false)
    }

    @Test func regularDirectoryIsNotSymlink() throws {
        let projectDir = try makeTempDirectory()
        defer { cleanup(projectDir) }

        let dirURL = projectDir.appendingPathComponent("regular")
        try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)

        let node = FileNode(url: dirURL)
        #expect(node.isSymlink == false)
    }

    // MARK: - Backward compatibility (no projectRoot)

    @Test func fileNodeWithoutProjectRootStillWorks() throws {
        let projectDir = try makeTempDirectory()
        defer { cleanup(projectDir) }

        FileManager.default.createFile(
            atPath: projectDir.appendingPathComponent("a.swift").path,
            contents: nil
        )

        let root = FileNode(url: projectDir)
        #expect(root.children?.count == 1)
        #expect(root.children?[0].name == "a.swift")
    }

    // MARK: - Deep symlink chain

    @Test func deepSymlinkChainOutsideRootIsBlocked() throws {
        let projectDir = try makeTempDirectory()
        let outsideDir = try makeTempDirectory()
        defer {
            cleanup(projectDir)
            cleanup(outsideDir)
        }

        // Chain: project/a -> project/b -> outside
        let dirB = projectDir.appendingPathComponent("b")
        try FileManager.default.createSymbolicLink(at: dirB, withDestinationURL: outsideDir)

        let dirA = projectDir.appendingPathComponent("a")
        try FileManager.default.createSymbolicLink(at: dirA, withDestinationURL: dirB)

        let root = FileNode(url: projectDir, projectRoot: projectDir)

        // "a" resolves through "b" to outside — should be blocked
        let nodeA = root.children?.first { $0.name == "a" }
        #expect(nodeA != nil)
        #expect(nodeA?.isSymlink == true)
        #expect(nodeA?.children == nil || nodeA?.children?.isEmpty == true)
    }

    // MARK: - Relative symlink outside root

    @Test func relativeSymlinkOutsideRootIsBlocked() throws {
        let baseDir = try makeTempDirectory()
        defer { cleanup(baseDir) }

        // Create project as a subdirectory so relative ../.. escapes
        let projectDir = baseDir.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let secretDir = baseDir.appendingPathComponent("secrets")
        try FileManager.default.createDirectory(at: secretDir, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: secretDir.appendingPathComponent("password.txt").path,
            contents: Data("hunter2".utf8)
        )

        // Relative symlink: project/escape -> ../secrets
        try FileManager.default.createSymbolicLink(
            atPath: projectDir.appendingPathComponent("escape").path,
            withDestinationPath: "../secrets"
        )

        let root = FileNode(url: projectDir, projectRoot: projectDir)

        let escapeNode = root.children?.first { $0.name == "escape" }
        #expect(escapeNode != nil)
        #expect(escapeNode?.isSymlink == true)
        #expect(escapeNode?.children == nil || escapeNode?.children?.isEmpty == true)
    }

    // MARK: - Symlink in nested directory

    @Test func nestedSymlinkOutsideRootIsBlocked() throws {
        let projectDir = try makeTempDirectory()
        let outsideDir = try makeTempDirectory()
        defer {
            cleanup(projectDir)
            cleanup(outsideDir)
        }

        // project/sub/link -> outside
        let subDir = projectDir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)

        try FileManager.default.createSymbolicLink(
            at: subDir.appendingPathComponent("link"),
            withDestinationURL: outsideDir
        )

        let root = FileNode(url: projectDir, projectRoot: projectDir)

        let subNode = root.children?.first { $0.name == "sub" }
        let linkNode = subNode?.children?.first { $0.name == "link" }
        #expect(linkNode != nil)
        #expect(linkNode?.isSymlink == true)
        #expect(linkNode?.children == nil || linkNode?.children?.isEmpty == true)
    }

    // MARK: - Path traversal via rename

    @Test func isWithinProjectRootRejectsPathTraversal() throws {
        let projectDir = try makeTempDirectory()
        defer { cleanup(projectDir) }

        // Simulate a rename to ../../escape — newURL would resolve outside
        let traversalURL = projectDir
            .appendingPathComponent("sub")
            .appendingPathComponent("..")
            .appendingPathComponent("..")
            .appendingPathComponent("escape")

        #expect(FileNode.isWithinProjectRoot(traversalURL, projectRoot: projectDir) == false)
    }

    @Test func isWithinProjectRootRejectsSimilarPrefix() throws {
        let baseDir = try makeTempDirectory()
        defer { cleanup(baseDir) }

        // project vs project-evil — must not pass prefix check
        let projectDir = baseDir.appendingPathComponent("project")
        let evilDir = baseDir.appendingPathComponent("project-evil")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: evilDir, withIntermediateDirectories: true)

        #expect(FileNode.isWithinProjectRoot(evilDir, projectRoot: projectDir) == false)
    }

    // MARK: - Root boundary check for file operations

    @Test func isWithinProjectRootAcceptsInternalPaths() throws {
        let projectDir = try makeTempDirectory()
        defer { cleanup(projectDir) }

        let subFile = projectDir.appendingPathComponent("src/main.swift")

        #expect(FileNode.isWithinProjectRoot(subFile, projectRoot: projectDir) == true)
        #expect(FileNode.isWithinProjectRoot(projectDir, projectRoot: projectDir) == true)
    }

    @Test func isWithinProjectRootRejectsExternalPaths() throws {
        let projectDir = try makeTempDirectory()
        let outsideDir = try makeTempDirectory()
        defer {
            cleanup(projectDir)
            cleanup(outsideDir)
        }

        #expect(FileNode.isWithinProjectRoot(outsideDir, projectRoot: projectDir) == false)
    }

    @Test func isWithinProjectRootResolvesSymlinks() throws {
        let projectDir = try makeTempDirectory()
        let outsideDir = try makeTempDirectory()
        defer {
            cleanup(projectDir)
            cleanup(outsideDir)
        }

        // Create a symlink inside the project pointing outside
        let symlinkURL = projectDir.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: outsideDir)

        // The symlink path looks internal but resolves external
        #expect(FileNode.isWithinProjectRoot(symlinkURL, projectRoot: projectDir) == false)
    }
}
