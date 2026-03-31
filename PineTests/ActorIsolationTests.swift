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
}
