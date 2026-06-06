//
//  SyntaxHighlightEngineTests.swift
//  PineTests
//
//  Tests for SyntaxHighlightEngine — sync match computation and application.
//

import Testing
import AppKit
@testable import Pine

@Suite("SyntaxHighlightEngine Tests", .serialized)
@MainActor
struct SyntaxHighlightEngineTests {

    nonisolated(unsafe) private let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    private let engine = SyntaxHighlightEngine()

    private let testGrammar = Grammar(
        name: "EngineTest",
        extensions: ["enginetest"],
        rules: [
            GrammarRule(pattern: "/\\*[\\s\\S]*?\\*/", scope: "comment"),
            GrammarRule(pattern: "\\bfunc\\b", scope: "keyword"),
            GrammarRule(pattern: "\"[^\"]*\"", scope: "string")
        ]
    )

    private var compiledRules: [CompiledRule] {
        GrammarCompiler.compileRules(for: testGrammar)
    }

    private func foregroundColor(in storage: NSTextStorage, at position: Int) -> NSColor? {
        guard position < storage.length else { return nil }
        return storage.attribute(.foregroundColor, at: position, effectiveRange: nil) as? NSColor
    }

    // MARK: - computeMatches

    @Test func computeMatches_findsKeywordAndComment() {
        let text = "func hello() /* comment */"
        let fullRange = NSRange(location: 0, length: (text as NSString).length)

        let result = engine.computeMatches(
            text: text,
            rules: compiledRules,
            grammarName: "EngineTest",
            repaintRange: fullRange,
            searchRange: fullRange
        )

        let keywordMatches = result.matches.filter { $0.scope == "keyword" }
        let commentMatches = result.matches.filter { $0.scope == "comment" }
        #expect(keywordMatches.count == 1)
        #expect(commentMatches.count == 1)
        #expect(keywordMatches.first?.range == NSRange(location: 0, length: 4))
    }

    @Test func computeMatches_returnsFingerprint() {
        let text = "/* block */ func /* another */"
        let fullRange = NSRange(location: 0, length: (text as NSString).length)

        let result = engine.computeMatches(
            text: text,
            rules: compiledRules,
            grammarName: "EngineTest",
            repaintRange: fullRange,
            searchRange: fullRange
        )

        #expect(result.multilineFingerprint.count == 2)
    }

    @Test func computeMatches_respectsRepaintRange() {
        let text = "func a() func b() func c()"
        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        // Only repaint the middle "func b()"
        let repaintRange = NSRange(location: 10, length: 8)

        let result = engine.computeMatches(
            text: text,
            rules: compiledRules,
            grammarName: "EngineTest",
            repaintRange: repaintRange,
            searchRange: fullRange
        )

        // Only the "func" within repaintRange should appear
        let keywordMatches = result.matches.filter { $0.scope == "keyword" }
        #expect(keywordMatches.count == 1)
        #expect(keywordMatches.first?.range.location == 10)
    }

    @Test func computeMatches_scopePriorityCommentBeatsKeyword() {
        let text = "/* func */" // "func" is inside a comment
        let fullRange = NSRange(location: 0, length: (text as NSString).length)

        let result = engine.computeMatches(
            text: text,
            rules: compiledRules,
            grammarName: "EngineTest",
            repaintRange: fullRange,
            searchRange: fullRange
        )

        // Comment has priority 100, keyword has 0 — comment wins
        let keywordMatches = result.matches.filter { $0.scope == "keyword" }
        let commentMatches = result.matches.filter { $0.scope == "comment" }
        #expect(commentMatches.count == 1)
        #expect(keywordMatches.isEmpty, "Keyword inside comment should be overridden")
    }

    // MARK: - applyMatches

    @Test func applyMatches_appliesColors() {
        let text = "func hello()"
        let storage = NSTextStorage(string: text)
        let fullRange = NSRange(location: 0, length: (text as NSString).length)

        let result = engine.computeMatches(
            text: text,
            rules: compiledRules,
            grammarName: "EngineTest",
            repaintRange: fullRange,
            searchRange: fullRange
        )

        engine.applyMatches(result, to: storage, font: font)

        let keywordColor = engine.theme.color(for: "keyword")
        #expect(foregroundColor(in: storage, at: 0) == keywordColor)
    }

    @Test func applyMatches_skipsWhenRangeExceedsLength() {
        let result = HighlightMatchResult(
            matches: [HighlightMatch(range: NSRange(location: 0, length: 5), scope: "keyword", priority: 0)],
            repaintRange: NSRange(location: 0, length: 100),
            multilineFingerprint: []
        )

        let shortStorage = NSTextStorage(string: "hi")

        // Should not crash
        engine.applyMatches(result, to: shortStorage, font: font)

        let color = foregroundColor(in: shortStorage, at: 0)
        let keywordColor = engine.theme.color(for: "keyword")
        #expect(color != keywordColor)
    }

    @Test func applyMatches_doesNotRegisterUndoActions() {
        let text = "func hello() /* comment */"
        let storage = NSTextStorage(string: text)
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(
            containerSize: NSSize(width: 500, height: CGFloat.greatestFiniteMagnitude)
        )
        layoutManager.addTextContainer(container)
        let textView = NSTextView(
            frame: NSRect(x: 0, y: 0, width: 500, height: 500),
            textContainer: container
        )
        textView.allowsUndo = true

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 500),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = textView

        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        let result = engine.computeMatches(
            text: text,
            rules: compiledRules,
            grammarName: "EngineTest",
            repaintRange: fullRange,
            searchRange: fullRange
        )

        #expect(textView.undoManager?.canUndo == false)

        engine.applyMatches(result, to: storage, font: font)

        #expect(textView.undoManager?.canUndo == false,
                "applyMatches must not register undo actions")
    }

    // MARK: - resetAttributes

    @Test func resetAttributes_clearsColors() {
        let text = "func hello()"
        let storage = NSTextStorage(string: text)
        storage.addAttribute(.foregroundColor, value: NSColor.red,
                             range: NSRange(location: 0, length: 4))

        engine.resetAttributes(textStorage: storage,
                               range: NSRange(location: 0, length: storage.length),
                               font: font)

        #expect(foregroundColor(in: storage, at: 0) == NSColor.textColor)
    }

    // MARK: - expandToContext

    @Test func expandToContext_expandsByContextLines() {
        let lines = (0..<100).map { "line \($0)" }
        let text = lines.joined(separator: "\n")
        let source = text as NSString

        // Edit at line 50, character 5
        let editLineStart = (text as NSString).range(of: "line 50").location
        let editRange = NSRange(location: editLineStart, length: 1)

        let expanded = engine.expandToContext(
            editRange, in: source, totalLength: source.length
        )

        // Should expand ~20 lines in each direction
        let expandedText = source.substring(with: expanded)
        let expandedLines = expandedText.components(separatedBy: "\n")
        // Should include ~40+ lines of context (20 before + edit line + 20 after)
        #expect(expandedLines.count >= 30)
    }

    // MARK: - commentAndStringRanges

    @Test func commentAndStringRanges_returnsCorrectRanges() {
        let text = "func hello() /* comment */ \"string\""
        let ranges = engine.commentAndStringRanges(in: text, rules: compiledRules)

        // Should find 1 comment and 1 string range
        #expect(ranges.count == 2)
    }

    @Test func commentAndStringRanges_noMatchesReturnsEmpty() {
        let text = "let x = 1"
        let ranges = engine.commentAndStringRanges(in: text, rules: compiledRules)
        #expect(ranges.isEmpty)
    }

    // MARK: - MultilineMatchCache

    @Test func multilineCache_updateAndRead() {
        let cache = MultilineMatchCache()
        let key = ObjectIdentifier(NSTextStorage(string: "test"))

        #expect(cache.fingerprint(for: key) == nil)

        cache.update(key: key, fingerprint: [1, 2, 3])
        #expect(cache.fingerprint(for: key) == [1, 2, 3])
    }

    @Test func multilineCache_setIfNil() {
        let cache = MultilineMatchCache()
        let key = ObjectIdentifier(NSTextStorage(string: "test"))

        cache.setIfNil(key: key, fingerprint: [1, 2])
        #expect(cache.fingerprint(for: key) == [1, 2])

        // Second setIfNil should be ignored
        cache.setIfNil(key: key, fingerprint: [3, 4])
        #expect(cache.fingerprint(for: key) == [1, 2])
    }

    @Test func multilineCache_remove() {
        let cache = MultilineMatchCache()
        let key = ObjectIdentifier(NSTextStorage(string: "test"))

        cache.update(key: key, fingerprint: [1])
        cache.remove(key: key)
        #expect(cache.fingerprint(for: key) == nil)
    }

    @Test func multilineCache_removeAll() {
        let cache = MultilineMatchCache()
        let key1 = ObjectIdentifier(NSTextStorage(string: "test1"))
        let key2 = ObjectIdentifier(NSTextStorage(string: "test2"))

        cache.update(key: key1, fingerprint: [1])
        cache.update(key: key2, fingerprint: [2])
        cache.removeAll()
        #expect(cache.fingerprint(for: key1) == nil)
        #expect(cache.fingerprint(for: key2) == nil)
    }
}
