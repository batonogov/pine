//
//  SyntaxHighlighterThreadSafetyTests.swift
//  PineTests
//

import Testing
import AppKit
@testable import Pine

/// Thread safety tests for SyntaxHighlighter.
/// Verifies that concurrent access to mutable dictionaries does not crash.
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

    @Test func concurrentHighlightCallsDoNotCrash() async {
        register()

        let text = "func hello() /* comment */ \"string\"\nfunc world()"
        let iterations = 100

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<iterations {
                group.addTask {
                    let storage = NSTextStorage(string: text)
                    SyntaxHighlighter.shared.highlight(
                        textStorage: storage, language: "threadtest", font: self.font
                    )
                }
            }
        }

        // If we reach here without crashing, the test passes
        #expect(true, "Concurrent highlight calls completed without crash")
    }

    // MARK: - Concurrent registerGrammar + highlight

    @Test func concurrentRegisterAndHighlightDoNotCrash() async {
        register()

        let text = "func test() /* block */ \"str\""
        let iterations = 50

        await withTaskGroup(of: Void.self) { group in
            // Writers: register grammars concurrently
            for i in 0..<iterations {
                group.addTask {
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
                }
            }

            // Readers: highlight concurrently
            for _ in 0..<iterations {
                group.addTask {
                    let storage = NSTextStorage(string: text)
                    SyntaxHighlighter.shared.highlight(
                        textStorage: storage, language: "threadtest", font: self.font
                    )
                }
            }
        }

        #expect(true, "Concurrent register + highlight completed without crash")
    }

    // MARK: - Concurrent multilineMatchCache access

    @Test func concurrentMultilineMatchCacheAccessDoesNotCrash() async {
        register()

        let text = "/* multiline\ncomment */\nfunc a()\nfunc b()"
        let iterations = 100

        await withTaskGroup(of: Void.self) { group in
            // Multiple threads doing full highlight (writes to multilineMatchCache)
            for _ in 0..<iterations {
                group.addTask {
                    let storage = NSTextStorage(string: text)
                    SyntaxHighlighter.shared.highlight(
                        textStorage: storage, language: "threadtest", font: self.font
                    )
                }
            }

            // Multiple threads doing highlightEdited (reads + writes multilineMatchCache)
            for _ in 0..<iterations {
                group.addTask {
                    let storage = NSTextStorage(string: text)
                    // First establish cache
                    SyntaxHighlighter.shared.highlight(
                        textStorage: storage, language: "threadtest", font: self.font
                    )
                    // Then do incremental highlight
                    SyntaxHighlighter.shared.highlightEdited(
                        textStorage: storage,
                        editedRange: NSRange(location: 0, length: 1),
                        language: "threadtest",
                        font: self.font
                    )
                }
            }

            // Multiple threads invalidating cache
            for _ in 0..<iterations {
                group.addTask {
                    let storage = NSTextStorage(string: text)
                    SyntaxHighlighter.shared.invalidateCache(for: storage)
                }
            }
        }

        #expect(true, "Concurrent multilineMatchCache access completed without crash")
    }

    // MARK: - Concurrent commentStyle + highlight

    @Test func concurrentCommentStyleAndHighlightDoNotCrash() async {
        register()

        let text = "func test() /* comment */"
        let iterations = 100

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<iterations {
                group.addTask {
                    _ = SyntaxHighlighter.shared.commentStyle(
                        forExtension: "threadtest", fileName: nil
                    )
                }
                group.addTask {
                    _ = SyntaxHighlighter.shared.lineComment(forExtension: "threadtest")
                }
                group.addTask {
                    _ = SyntaxHighlighter.shared.lineComment(forFileName: "ThreadTestFile")
                }
                group.addTask {
                    let storage = NSTextStorage(string: text)
                    SyntaxHighlighter.shared.highlight(
                        textStorage: storage, language: "threadtest", font: self.font
                    )
                }
            }
        }

        #expect(true, "Concurrent commentStyle + highlight completed without crash")
    }

    // MARK: - Concurrent computeMatches

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
