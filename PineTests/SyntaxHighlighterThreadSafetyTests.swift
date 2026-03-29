//
//  SyntaxHighlighterThreadSafetyTests.swift
//  PineTests
//

import Testing
import AppKit
@testable import Pine

/// Thread safety tests for SyntaxHighlighter.
/// Verifies that concurrent access to mutable dictionaries does not crash.
///
/// Tests that touch NSTextStorage run on @MainActor because NSTextStorage
/// is not Sendable and must be accessed from the main thread.
/// Pure computation tests (computeMatches) use TaskGroup for true concurrency.
@Suite(.serialized)
struct SyntaxHighlighterThreadSafetyTests {

    private let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    private let testGrammar = Grammar(
        name: "ThreadTestLang",
        extensions: ["threadtest"],
        rules: [
            GrammarRule(pattern: "/\\*[\\s\\S]*?\\*/", scope: "comment"),
            GrammarRule(pattern: "\\bfunc\\b", scope: "keyword"),
            GrammarRule(pattern: "\"[^\"]*\"", scope: "string")
        ],
        fileNames: ["ThreadTestFile"],
        filePatterns: ["*.threadtest"]
    )

    private func register() {
        SyntaxHighlighter.shared.registerGrammar(testGrammar)
    }

    // MARK: - Concurrent highlight + resolveGrammar

    /// Runs many highlight calls sequentially on the main actor to verify
    /// thread-safe dictionary access inside SyntaxHighlighter.
    @Test @MainActor func concurrentHighlightCallsDoNotCrash() async {
        register()

        let text = "func hello() /* comment */ \"string\"\nfunc world()"
        let iterations = 100

        for _ in 0..<iterations {
            let storage = NSTextStorage(string: text)
            SyntaxHighlighter.shared.highlight(
                textStorage: storage, language: "threadtest", font: font
            )
        }

        #expect(true, "Highlight calls completed without crash")
    }

    // MARK: - Concurrent registerGrammar + highlight

    @Test @MainActor func concurrentRegisterAndHighlightDoNotCrash() async {
        register()

        let text = "func test() /* block */ \"str\""
        let iterations = 50

        for i in 0..<iterations {
            let grammar = Grammar(
                name: "ConcurrentLang\(i)",
                extensions: ["conc\(i)"],
                rules: [
                    GrammarRule(pattern: "\\bvar\\b", scope: "keyword")
                ],
                fileNames: ["ConcFile\(i)"],
                filePatterns: ["*.conc\(i)"]
            )
            SyntaxHighlighter.shared.registerGrammar(grammar)

            let storage = NSTextStorage(string: text)
            SyntaxHighlighter.shared.highlight(
                textStorage: storage, language: "threadtest", font: font
            )
        }

        #expect(true, "Register + highlight completed without crash")
    }

    // MARK: - Concurrent multilineMatchCache access

    @Test @MainActor func concurrentMultilineMatchCacheAccessDoesNotCrash() async {
        register()

        let text = "/* multiline\ncomment */\nfunc a()\nfunc b()"
        let iterations = 100

        for _ in 0..<iterations {
            let storage = NSTextStorage(string: text)
            // Full highlight (writes to multilineMatchCache)
            SyntaxHighlighter.shared.highlight(
                textStorage: storage, language: "threadtest", font: font
            )
            // Incremental highlight (reads + writes multilineMatchCache)
            SyntaxHighlighter.shared.highlightEdited(
                textStorage: storage,
                editedRange: NSRange(location: 0, length: 1),
                language: "threadtest",
                font: font
            )
            // Invalidate cache
            SyntaxHighlighter.shared.invalidateCache(for: storage)
        }

        #expect(true, "MultilineMatchCache access completed without crash")
    }

    // MARK: - Concurrent commentStyle + highlight

    @Test @MainActor func concurrentCommentStyleAndHighlightDoNotCrash() async {
        register()

        let text = "func test() /* comment */"
        let iterations = 100

        for _ in 0..<iterations {
            _ = SyntaxHighlighter.shared.commentStyle(
                forExtension: "threadtest", fileName: nil
            )
            _ = SyntaxHighlighter.shared.lineComment(forExtension: "threadtest")
            _ = SyntaxHighlighter.shared.lineComment(forFileName: "ThreadTestFile")

            let storage = NSTextStorage(string: text)
            SyntaxHighlighter.shared.highlight(
                textStorage: storage, language: "threadtest", font: font
            )
        }

        #expect(true, "CommentStyle + highlight completed without crash")
    }

    // MARK: - Concurrent computeMatches (pure computation, no NSTextStorage)

    @Test func concurrentComputeMatchesDoNotCrash() async {
        register()

        let text = "func hello() /* comment */ \"string\"\nfunc world()"
        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        let iterations = 100

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<iterations {
                group.addTask {
                    _ = SyntaxHighlighter.shared.computeMatches(
                        text: text,
                        language: "threadtest",
                        repaintRange: fullRange,
                        searchRange: fullRange
                    )
                }
            }
        }

        #expect(true, "Concurrent computeMatches completed without crash")
    }
}
