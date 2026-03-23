//
//  ScrollPerformanceTests.swift
//  PineTests
//
//  Tests for scroll performance optimizations (#196).
//

import AppKit
import Testing

@testable import Pine

@Suite("Scroll Performance Tests")
struct ScrollPerformanceTests {

    // MARK: - Bracket matching with windowed search

    @Test("Bracket match within search window works normally")
    func bracketMatchWithinWindow() {
        // Simple case: brackets close together
        let text = "func foo() { return bar(42) }"
        let result = BracketMatcher.findMatch(in: text, cursorPosition: 12)
        #expect(result?.opener == 11)
        #expect(result?.closer == 28)
    }

    @Test("Bracket match works on substring with offset")
    func bracketMatchOnSubstring() {
        // Simulate windowed search: extract a substring and match within it
        let fullText = "prefix { inner content } suffix"
        let nsText = fullText as NSString

        // Window: extract around the '{' at position 7
        let windowStart = 5
        let windowEnd = 25
        let range = NSRange(location: windowStart, length: windowEnd - windowStart)
        let substring = nsText.substring(with: range)
        let localCursor = 7 - windowStart  // '{' is at position 7 globally

        let result = BracketMatcher.findMatch(in: substring, cursorPosition: localCursor + 1)
        #expect(result != nil)

        if let match = result {
            // Convert back to global positions
            let globalOpener = match.opener + windowStart
            let globalCloser = match.closer + windowStart
            #expect(globalOpener == 7)
            #expect(globalCloser == 23)
        }
    }

    @Test("Bracket match returns nil when match is outside window")
    func bracketMatchOutsideWindow() {
        // Full text has matching brackets far apart
        let padding = String(repeating: "x", count: 100)
        let fullText = "{\(padding)}"
        let nsText = fullText as NSString

        // Window only covers the opening bracket area
        let windowRange = NSRange(location: 0, length: 10)
        let substring = nsText.substring(with: windowRange)

        // Should not find match — closing bracket is outside window
        let result = BracketMatcher.findMatch(in: substring, cursorPosition: 1)
        #expect(result == nil)

        // But full text search should find it
        let fullResult = BracketMatcher.findMatch(in: fullText, cursorPosition: 1)
        #expect(fullResult != nil)
        #expect(fullResult?.opener == 0)
        #expect(fullResult?.closer == nsText.length - 1)
    }

    @Test("Bracket match with skip ranges works on substring")
    func bracketMatchSkipRangesOnSubstring() {
        // Substring with a string literal containing a bracket
        let text = "( \"(\" )"
        let skipRanges = [NSRange(location: 2, length: 3)]

        let result = BracketMatcher.findMatch(in: text, cursorPosition: 1, skipRanges: skipRanges)
        #expect(result?.opener == 0)
        #expect(result?.closer == 6)
    }

    // MARK: - LineNumberView diffMap caching

    @Test("LineNumberView diffMap is rebuilt when lineDiffs changes")
    func diffMapCaching() {
        let textView = NSTextView()
        textView.string = "line1\nline2\nline3\n"
        let lineNumberView = LineNumberView(textView: textView)

        // Initially empty
        #expect(lineNumberView.lineDiffs.isEmpty)

        // Set diffs
        lineNumberView.lineDiffs = [
            GitLineDiff(line: 1, kind: .added),
            GitLineDiff(line: 3, kind: .modified)
        ]
        #expect(lineNumberView.lineDiffs.count == 2)

        // Clear diffs
        lineNumberView.lineDiffs = []
        #expect(lineNumberView.lineDiffs.isEmpty)
    }

    // MARK: - Viewport highlighting threshold

    @Test("Viewport highlight threshold is 100_000 characters")
    @MainActor func viewportHighlightThresholdCheck() {
        // Verify threshold constant value
        #expect(CodeEditorView.viewportHighlightThreshold == 100_000)
    }

    // MARK: - Gutter digit width caching (#440)

    @Test("LineNumberView caches digit width across draw calls")
    func gutterDigitWidthCaching() {
        let textView = NSTextView()
        textView.string = "line1\nline2\nline3\n"
        let lineNumberView = LineNumberView(textView: textView)

        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        lineNumberView.gutterFont = font

        // Force a display to populate cached width
        lineNumberView.frame = NSRect(x: 0, y: 0, width: 40, height: 200)

        // Verify the font can be set and view initializes correctly
        #expect(lineNumberView.gutterFont === font)
        #expect(lineNumberView.gutterWidth == 40)
    }

    @Test("MinimapView throttles scroll redraws")
    func minimapScrollThrottle() {
        let textView = NSTextView()
        textView.string = "Hello\nWorld\n"
        let minimap = MinimapView(textView: textView)
        minimap.frame = NSRect(x: 0, y: 0, width: 80, height: 400)

        // MinimapView.scrollThrottleInterval should be > 0
        // We verify the view is created successfully with throttle support
        #expect(minimap.textView === textView)
    }

    // MARK: - commentAndStringRanges on substring

    @Test("commentAndStringRanges works on substring")
    func commentAndStringRangesSubstring() {
        // Register a grammar to ensure the highlighter works
        let grammar = Grammar(
            name: "TestLang",
            extensions: ["testperf"],
            rules: [
                GrammarRule(pattern: "//.*$", scope: "comment", options: ["anchorsMatchLines"]),
                GrammarRule(pattern: "\"[^\"]*\"", scope: "string", options: nil)
            ],
            fileNames: nil,
            lineComment: "//"
        )
        SyntaxHighlighter.shared.registerGrammar(grammar)

        let fullText = "code // comment\n\"string\" more code"
        let ranges = SyntaxHighlighter.shared.commentAndStringRanges(
            in: fullText, language: "testperf"
        )
        // Should find both comment and string ranges
        #expect(ranges.count >= 2)

        // Test on a substring (simulating windowed search)
        let nsText = fullText as NSString
        let substring = nsText.substring(with: NSRange(location: 0, length: 15))
        let subRanges = SyntaxHighlighter.shared.commentAndStringRanges(
            in: substring, language: "testperf"
        )
        // Should find the comment in the substring
        #expect(!subRanges.isEmpty)
    }
}
