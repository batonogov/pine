//
//  LoadContextLifetimeTests.swift
//  PineTests
//

import Testing
import Foundation
@testable import Pine

struct LoadContextLifetimeTests {

    private func makeTempDirectory() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PineTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Repeated loadTree calls (reproduces use-after-free)

    @Test func repeatedLoadTreeDoesNotCrash() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        // Create a project structure with some depth
        let src = tempDir.appendingPathComponent("src")
        let lib = src.appendingPathComponent("lib")
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: lib.appendingPathComponent("main.swift").path, contents: nil
        )
        FileManager.default.createFile(
            atPath: src.appendingPathComponent("app.swift").path, contents: nil
        )

        // Call loadTree many times in a tight loop — triggers use-after-free
        // with class-based LoadContext due to ARC deallocation races
        for _ in 0..<50 {
            let result = FileNode.loadTree(
                url: tempDir, projectRoot: tempDir,
                ignoredPaths: [], maxDepth: 3
            )
            #expect(result.root.isDirectory == true)
        }
    }

    @Test func repeatedLoadTreeWithIgnoredPathsDoesNotCrash() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        let nodeModules = tempDir.appendingPathComponent("node_modules")
        let express = nodeModules.appendingPathComponent("express")
        try FileManager.default.createDirectory(at: express, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: express.appendingPathComponent("index.js").path, contents: nil
        )
        FileManager.default.createFile(
            atPath: tempDir.appendingPathComponent("app.js").path, contents: nil
        )

        // Tight loop with ignored paths — exercises LoadContext symlink cache + ignored logic
        for _ in 0..<50 {
            let result = FileNode.loadTree(
                url: tempDir, projectRoot: tempDir,
                ignoredPaths: ["node_modules"], maxDepth: 3
            )
            #expect(result.root.children?.isEmpty == false)
        }
    }

    @Test func repeatedInitDoesNotCrash() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        let sub = tempDir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: sub.appendingPathComponent("file.txt").path, contents: nil
        )

        // Direct init calls in tight loop — triggers the same malloc crash
        for _ in 0..<50 {
            let node = FileNode(url: tempDir, projectRoot: tempDir, ignoredPaths: ["ignored"])
            #expect(node.isDirectory == true)
        }
    }

    // MARK: - Concurrent tree loading

    @Test func concurrentLoadTreeDoesNotCrash() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        let src = tempDir.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: src.appendingPathComponent("main.swift").path, contents: nil
        )
        FileManager.default.createFile(
            atPath: tempDir.appendingPathComponent("README.md").path, contents: nil
        )

        // Concurrent loadTree from multiple threads — each must use independent state
        DispatchQueue.concurrentPerform(iterations: 20) { _ in
            let result = FileNode.loadTree(
                url: tempDir, projectRoot: tempDir,
                ignoredPaths: [], maxDepth: 5
            )
            // Each call must produce a valid tree
            assert(result.root.isDirectory == true)
            assert(result.root.children != nil)
        }
    }

    @Test func concurrentInitWithSharedProjectRoot() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        // Simulate WorkspaceManager.loadTopLevelInParallel pattern
        let dirA = tempDir.appendingPathComponent("dirA")
        let dirB = tempDir.appendingPathComponent("dirB")
        let dirC = tempDir.appendingPathComponent("dirC")
        try FileManager.default.createDirectory(at: dirA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dirB, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dirC, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: dirA.appendingPathComponent("a.txt").path, contents: nil
        )
        FileManager.default.createFile(
            atPath: dirB.appendingPathComponent("b.txt").path, contents: nil
        )
        FileManager.default.createFile(
            atPath: dirC.appendingPathComponent("c.txt").path, contents: nil
        )

        let urls = [dirA, dirB, dirC]
        let results = UnsafeMutableBufferPointer<FileNode?>.allocate(capacity: urls.count)
        results.initialize(repeating: nil)
        defer { results.deallocate() }

        DispatchQueue.concurrentPerform(iterations: urls.count) { index in
            results[index] = FileNode(
                url: urls[index], projectRoot: tempDir, ignoredPaths: []
            )
        }

        for idx in 0..<urls.count {
            let node = results[idx]
            #expect(node != nil)
            #expect(node?.isDirectory == true)
            #expect(node?.children?.isEmpty == false)
        }
    }

    // MARK: - Stale results / generation token correctness

    @Test func loadTreeResultIndependentPerCall() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        let sub = tempDir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)

        // First call with depth limit
        let limited = FileNode.loadTree(
            url: tempDir, projectRoot: tempDir,
            ignoredPaths: [], maxDepth: 0
        )
        #expect(limited.wasDepthLimited == true)

        // Second call without depth limit — must NOT carry over reachedDepthLimit from previous call
        let full = FileNode.loadTree(
            url: tempDir, projectRoot: tempDir,
            ignoredPaths: [], maxDepth: .max
        )
        #expect(full.wasDepthLimited == false)
    }

    @Test func loadContextStateNotSharedBetweenCalls() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        // Create symlink to test visitedRealPaths isolation
        let realDir = tempDir.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: realDir.appendingPathComponent("file.txt").path, contents: nil
        )
        let link = tempDir.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: realDir)

        // First call populates visitedRealPaths with the symlink target
        let result1 = FileNode.loadTree(
            url: tempDir, projectRoot: tempDir,
            ignoredPaths: [], maxDepth: 10
        )

        // Second call must have fresh visitedRealPaths — link should still resolve
        let result2 = FileNode.loadTree(
            url: tempDir, projectRoot: tempDir,
            ignoredPaths: [], maxDepth: 10
        )

        // Both results should have identical structure
        let names1 = result1.root.children?.map(\.name).sorted() ?? []
        let names2 = result2.root.children?.map(\.name).sorted() ?? []
        #expect(names1 == names2)
        #expect(names1.contains("real"))
        #expect(names1.contains("link"))
    }

    // MARK: - Value semantics verification

    @Test func loadTreeWithDepthLimitProducesCorrectResult() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        // Create: root/a/b/c/d.txt
        let path = tempDir.appendingPathComponent("a")
            .appendingPathComponent("b")
            .appendingPathComponent("c")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: path.appendingPathComponent("d.txt").path, contents: nil
        )

        let result = FileNode.loadTree(
            url: tempDir, projectRoot: tempDir,
            ignoredPaths: [], maxDepth: 1
        )
        #expect(result.wasDepthLimited == true)

        // a (depth 1) loaded, b (depth 2) should be shallow
        let aNode = result.root.children?.first { $0.name == "a" }
        #expect(aNode != nil)
        let bNode = aNode?.children?.first { $0.name == "b" }
        #expect(bNode != nil)
        #expect(bNode?.children?.isEmpty == true) // shallow — beyond maxDepth
    }
}
