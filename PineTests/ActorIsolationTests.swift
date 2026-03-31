//
//  ActorIsolationTests.swift
//  PineTests
//
//  Tests that classes using background queues are correctly marked nonisolated
//  to prevent crashes under SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor (#693).
//

import Testing
import AppKit
@testable import Pine

/// Verifies that types which perform background work are not implicitly @MainActor.
/// Under SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor, any class without an explicit
/// isolation marker becomes @MainActor. Classes that dispatch work to background
/// queues (OperationQueue, DispatchQueue.global) must be marked `nonisolated`
/// to prevent dispatch_assert_queue_fail → SIGTRAP at runtime.
@Suite(.serialized)
struct ActorIsolationTests {

    private let testGrammar = Grammar(
        name: "IsolationTestLang",
        extensions: ["isoltest"],
        rules: [
            GrammarRule(pattern: "\\bfunc\\b", scope: "keyword"),
            GrammarRule(pattern: "\"[^\"]*\"", scope: "string"),
            GrammarRule(pattern: "//.*$", scope: "comment", options: ["anchorsMatchLines"])
        ]
    )

    // MARK: - SyntaxHighlighter on background thread

    /// Calling computeMatches from a background thread must not crash.
    /// Before the fix, SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor made
    /// SyntaxHighlighter implicitly @MainActor, causing dispatch_assert_queue_fail
    /// when resolveGrammar was called from the highlight OperationQueue.
    @Test func computeMatchesOnBackgroundThread() async {
        SyntaxHighlighter.shared.registerGrammar(testGrammar)

        let text = "func hello() // comment\n\"string\""
        let fullRange = NSRange(location: 0, length: (text as NSString).length)

        // Run on a background thread via withCheckedContinuation + DispatchQueue.global
        let result: HighlightMatchResult? = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let r = SyntaxHighlighter.shared.computeMatches(
                    text: text,
                    language: "isoltest",
                    repaintRange: fullRange,
                    searchRange: fullRange
                )
                continuation.resume(returning: r)
            }
        }

        #expect(result != nil, "computeMatches should return results from background thread")
        #expect(!result!.matches.isEmpty, "Should find keyword, string, and comment matches")
    }

    /// Calling resolveGrammar indirectly via computeMatches from multiple
    /// concurrent background tasks must not crash.
    @Test func concurrentBackgroundComputeMatches() async {
        SyntaxHighlighter.shared.registerGrammar(testGrammar)

        let text = "func a() // comment\nfunc b() \"str\""
        let fullRange = NSRange(location: 0, length: (text as NSString).length)

        await withTaskGroup(of: HighlightMatchResult?.self) { group in
            for _ in 0..<50 {
                group.addTask {
                    await withCheckedContinuation { continuation in
                        DispatchQueue.global(qos: .userInitiated).async {
                            let r = SyntaxHighlighter.shared.computeMatches(
                                text: text,
                                language: "isoltest",
                                repaintRange: fullRange,
                                searchRange: fullRange
                            )
                            continuation.resume(returning: r)
                        }
                    }
                }
            }
            for await result in group {
                #expect(result != nil)
            }
        }
    }

    /// lineComment and commentStyle lookups from background thread must not crash.
    @Test func grammarLookupOnBackgroundThread() async {
        SyntaxHighlighter.shared.registerGrammar(testGrammar)

        let result: (String?, SyntaxHighlighter.CommentStyle?) = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let lc = SyntaxHighlighter.shared.lineComment(forExtension: "isoltest")
                let cs = SyntaxHighlighter.shared.commentStyle(forExtension: "isoltest", fileName: nil)
                continuation.resume(returning: (lc, cs))
            }
        }

        // Grammar has lineComment as "//.*$" pattern but no lineComment property set
        // The point is that the call didn't crash, not the specific value
        #expect(true, "Grammar lookups from background thread completed without crash")
        _ = result  // suppress unused warning
    }

    /// HighlightGeneration increment/current from background thread must not crash.
    @Test func highlightGenerationOnBackgroundThread() async {
        let gen = HighlightGeneration()

        let values: [Int] = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var collected: [Int] = []
                for _ in 0..<100 {
                    gen.increment()
                    collected.append(gen.current)
                }
                continuation.resume(returning: collected)
            }
        }

        #expect(values.count == 100)
        #expect(gen.current >= 100, "All increments should have been applied")
    }

    /// highlightAsync dispatches to background OperationQueue internally.
    /// This must not crash under MainActor default isolation.
    @Test @MainActor func highlightAsyncDoesNotCrash() async {
        SyntaxHighlighter.shared.registerGrammar(testGrammar)

        let text = "func test() // hello\n\"world\""
        let storage = NSTextStorage(string: text)
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let gen = HighlightGeneration()

        let result = await SyntaxHighlighter.shared.highlightAsync(
            textStorage: storage,
            language: "isoltest",
            font: font,
            generation: gen
        )

        #expect(result != nil, "highlightAsync should complete without crash")
        #expect(!result!.matches.isEmpty)
    }

    // MARK: - FileNode on background thread

    /// Creating FileNode from a background thread must not crash.
    /// Before the fix, SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor made FileNode
    /// implicitly @MainActor, causing dispatch_assert_queue_fail when constructed
    /// in WorkspaceManager.loadDirectoryContentsAsync (#693).
    @Test func fileNodeCreationOnBackgroundThread() async {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-isolation-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create a test file
        let testFile = tempDir.appendingPathComponent("test.swift")
        FileManager.default.createFile(atPath: testFile.path, contents: Data("func hello()".utf8))

        let node: FileNode = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let n = FileNode(url: tempDir, projectRoot: tempDir)
                continuation.resume(returning: n)
            }
        }

        #expect(node.isDirectory, "Should be a directory")
        #expect(node.children != nil, "Directory should have children")
        #expect(node.children?.count == 1, "Should have one child (test.swift)")
        #expect(node.children?.first?.name == "test.swift")
    }

    /// FileNode.loadTree from a background thread must not crash.
    /// This mimics the exact call path in WorkspaceManager.loadDirectoryContentsAsync.
    @Test func fileNodeLoadTreeOnBackgroundThread() async {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-isolation-loadtree-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let subDir = tempDir.appendingPathComponent("src")
        try? FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        let testFile = subDir.appendingPathComponent("main.swift")
        FileManager.default.createFile(atPath: testFile.path, contents: Data("import Foundation".utf8))
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let result: FileNode.LoadResult = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let r = FileNode.loadTree(
                    url: tempDir, projectRoot: tempDir,
                    ignoredPaths: [], maxDepth: 10
                )
                continuation.resume(returning: r)
            }
        }

        #expect(!result.wasDepthLimited, "Small tree should not hit depth limit")
        #expect(result.root.isDirectory)
        #expect(result.root.children?.first?.name == "src")
        #expect(result.root.children?.first?.children?.first?.name == "main.swift")
    }

    /// Concurrent FileNode creation from multiple background threads must not crash.
    @Test func concurrentFileNodeCreation() async {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-isolation-concurrent-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        for i in 0..<5 {
            let f = tempDir.appendingPathComponent("file\(i).txt")
            FileManager.default.createFile(atPath: f.path, contents: Data("content \(i)".utf8))
        }
        defer { try? FileManager.default.removeItem(at: tempDir) }

        await withTaskGroup(of: FileNode.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    await withCheckedContinuation { continuation in
                        DispatchQueue.global(qos: .userInitiated).async {
                            let n = FileNode(url: tempDir, projectRoot: tempDir)
                            continuation.resume(returning: n)
                        }
                    }
                }
            }
            for await node in group {
                #expect(node.isDirectory)
                #expect(node.children?.count == 5, "Each concurrent FileNode should see all 5 files")
            }
        }
    }

    // MARK: - GitFetcher on background thread (replaces GitStatusProvider background init)

    /// GitFetcher.fetchAllInParallel from a background thread must not crash.
    /// WorkspaceManager.loadDirectoryContentsAsync now uses GitFetcher directly
    /// instead of creating @MainActor GitStatusProvider on background (#693).
    @Test func gitFetcherOnBackgroundThread() async {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-isolation-gitfetcher-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Not a git repo — should return empty results without crashing
        typealias GitResult = (
            branch: String, statuses: [String: GitFileStatus],
            ignored: Set<String>, branches: [String]
        )
        let result: GitResult = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let r = GitFetcher.fetchAllInParallel(at: tempDir)
                continuation.resume(returning: r)
            }
        }

        #expect(result.branch.isEmpty, "Non-git directory should have empty branch")
        #expect(result.statuses.isEmpty, "Non-git directory should have no statuses")
    }
}
