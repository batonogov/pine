//
//  MarkdownGrammarTests.swift
//  PineTests
//
//  Verifies the markdown grammar produces a clear visual hierarchy:
//  distinct scopes per heading level, code/emphasis/list/quote/link
//  scopes that don't collide, neutral prose, and tight rules that
//  don't over-match (e.g. `#hashtag` is not a heading).
//

import Testing
import AppKit
@testable import Pine

@Suite(.serialized)
@MainActor
struct MarkdownGrammarTests {

    nonisolated(unsafe) private let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private let hl = SyntaxHighlighter.shared

    // swiftlint:disable force_unwrapping
    private var h1Color: NSColor { hl.theme.color(for: "markdown.heading.1")! }
    private var h2Color: NSColor { hl.theme.color(for: "markdown.heading.2")! }
    private var h3Color: NSColor { hl.theme.color(for: "markdown.heading.3")! }
    private var h4Color: NSColor { hl.theme.color(for: "markdown.heading.4")! }
    private var h5Color: NSColor { hl.theme.color(for: "markdown.heading.5")! }
    private var h6Color: NSColor { hl.theme.color(for: "markdown.heading.6")! }
    private var boldColor: NSColor { hl.theme.color(for: "markdown.bold")! }
    private var italicColor: NSColor { hl.theme.color(for: "markdown.italic")! }
    private var codeColor: NSColor { hl.theme.color(for: "markdown.code")! }
    private var fencedColor: NSColor { hl.theme.color(for: "markdown.code.fenced")! }
    private var linkColor: NSColor { hl.theme.color(for: "markdown.link")! }
    private var listColor: NSColor { hl.theme.color(for: "markdown.list")! }
    private var quoteColor: NSColor { hl.theme.color(for: "markdown.quote")! }
    private var ruleColor: NSColor { hl.theme.color(for: "markdown.rule")! }
    // swiftlint:enable force_unwrapping

    private var prose: NSColor { NSColor.textColor }

    // MARK: - Helpers

    private func loadMarkdownGrammar() throws -> Grammar {
        let grammarURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Pine/Grammars/markdown.json")
        let data = try Data(contentsOf: grammarURL)
        return try JSONDecoder().decode(Grammar.self, from: data)
    }

    private func highlight(_ text: String) throws -> NSTextStorage {
        let grammar = try loadMarkdownGrammar()
        hl.registerGrammar(grammar)
        let storage = NSTextStorage(string: text)
        hl.highlight(textStorage: storage, language: "markdown", font: font)
        return storage
    }

    private func color(in storage: NSTextStorage, at position: Int) -> NSColor? {
        guard position < storage.length else { return nil }
        return storage.attribute(.foregroundColor, at: position, effectiveRange: nil) as? NSColor
    }

    private func position(of substring: String, in storage: NSTextStorage) -> Int {
        (storage.string as NSString).range(of: substring).location
    }

    // MARK: - Heading hierarchy

    @Test func eachHeadingLevelGetsDistinctScope() throws {
        let storage = try highlight("""
        # H1
        ## H2
        ### H3
        #### H4
        ##### H5
        ###### H6
        """)

        #expect(color(in: storage, at: position(of: "# H1", in: storage)) == h1Color)
        #expect(color(in: storage, at: position(of: "## H2", in: storage)) == h2Color)
        #expect(color(in: storage, at: position(of: "### H3", in: storage)) == h3Color)
        #expect(color(in: storage, at: position(of: "#### H4", in: storage)) == h4Color)
        #expect(color(in: storage, at: position(of: "##### H5", in: storage)) == h5Color)
        #expect(color(in: storage, at: position(of: "###### H6", in: storage)) == h6Color)
    }

    @Test func headingColorsAreAllDifferent() {
        let levels: [NSColor] = [h1Color, h2Color, h3Color, h4Color, h5Color, h6Color]
        for i in 0..<levels.count {
            for j in (i + 1)..<levels.count {
                #expect(levels[i] != levels[j], "Heading levels \(i + 1) and \(j + 1) share a color")
            }
        }
    }

    @Test func headingAtFirstLineOfFile() throws {
        let storage = try highlight("# Title\nbody")
        #expect(color(in: storage, at: 0) == h1Color)
    }

    @Test func headingAfterBlankLine() throws {
        let storage = try highlight("intro\n\n## Section\nbody")
        let pos = position(of: "## Section", in: storage)
        #expect(color(in: storage, at: pos) == h2Color)
    }

    // MARK: - Negative: things that look like headings but aren't

    @Test func hashtagWithoutSpaceIsNotHeading() throws {
        let storage = try highlight("#hashtag is not a heading")
        // First char should NOT be heading-colored — must remain prose.
        #expect(color(in: storage, at: 0) == prose)
    }

    @Test func sevenHashesIsNotHeading() throws {
        // Markdown spec allows max 6 #'s; 7+ is plain text.
        let storage = try highlight("####### too many")
        #expect(color(in: storage, at: 0) == prose)
    }

    @Test func hashInMiddleOfLineIsNotHeading() throws {
        let storage = try highlight("see issue #123 today")
        let pos = position(of: "#123", in: storage)
        #expect(color(in: storage, at: pos) == prose)
    }

    // MARK: - Prose stays neutral

    @Test func plainProseIsNotColored() throws {
        let storage = try highlight("This is just regular paragraph text.")
        #expect(color(in: storage, at: 0) == prose)
        #expect(color(in: storage, at: 10) == prose)
    }

    @Test func emptyDocumentDoesNotCrash() throws {
        let storage = try highlight("")
        #expect(storage.length == 0)
    }

    // MARK: - Code

    @Test func inlineCodeIsHighlighted() throws {
        let storage = try highlight("call `foo()` here")
        let pos = position(of: "`foo()`", in: storage)
        #expect(color(in: storage, at: pos) == codeColor)
    }

    @Test func fencedCodeBlockIsHighlighted() throws {
        let storage = try highlight("""
        before
        ```
        let x = 1
        ```
        after
        """)
        let pos = position(of: "```", in: storage)
        #expect(color(in: storage, at: pos) == fencedColor)
        let inner = position(of: "let x", in: storage)
        #expect(color(in: storage, at: inner) == fencedColor)
    }

    // MARK: - Fenced code block — comprehensive coverage for #750

    @Test func fencedCodeBlockFromRealReadme() throws {
        // Read the actual project README and verify fenced blocks are highlighted.
        let readmeURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("README.md")
        guard let data = try? Data(contentsOf: readmeURL),
              let content = String(data: data, encoding: .utf8) else {
            return
        }
        let grammar = try loadMarkdownGrammar()
        hl.registerGrammar(grammar)
        let storage = NSTextStorage(string: content)
        hl.highlight(textStorage: storage, language: "markdown", font: font)

        // README contains `brew tap batonogov/tap` inside a ```bash block.
        let ns = content as NSString
        let brewRange = ns.range(of: "brew tap batonogov/tap")
        if brewRange.location != NSNotFound {
            #expect(color(in: storage, at: brewRange.location) == fencedColor,
                    "brew tap line inside fenced block must be fenced-colored")
        }
    }

    @Test func fencedCodeBlockWithLanguageTag() throws {
        // Regression for #750 — ```bash ... ``` must color interior lines.
        let storage = try highlight("""
        intro paragraph.

        ```bash
        brew tap batonogov/tap
        brew install --cask pine-editor
        ```

        after paragraph.
        """)
        let openFence = position(of: "```bash", in: storage)
        #expect(color(in: storage, at: openFence) == fencedColor)
        let line1 = position(of: "brew tap", in: storage)
        #expect(color(in: storage, at: line1) == fencedColor)
        let line2 = position(of: "brew install", in: storage)
        #expect(color(in: storage, at: line2) == fencedColor)
        // Prose after the block stays neutral.
        let afterPos = position(of: "after paragraph", in: storage)
        #expect(color(in: storage, at: afterPos) == prose)
    }

    @Test func fencedCodeBlockThreeLines() throws {
        let storage = try highlight("""
        ```
        a
        b
        c
        ```
        """)
        #expect(color(in: storage, at: position(of: "a", in: storage)) == fencedColor)
        #expect(color(in: storage, at: position(of: "b", in: storage)) == fencedColor)
        #expect(color(in: storage, at: position(of: "c", in: storage)) == fencedColor)
    }

    @Test func fencedCodeBlockFiftyLines() throws {
        var lines = ["```swift"]
        for i in 0..<50 {
            lines.append("let var\(i) = \(i)")
        }
        lines.append("```")
        let storage = try highlight(lines.joined(separator: "\n"))
        for i in 0..<50 {
            let needle = "let var\(i)"
            let pos = position(of: needle, in: storage)
            #expect(color(in: storage, at: pos) == fencedColor, "line \(i) not fenced-colored")
        }
    }

    @Test func fencedCodeBlockAtStartOfFile() throws {
        let storage = try highlight("""
        ```
        first line
        second line
        ```
        after
        """)
        #expect(color(in: storage, at: 0) == fencedColor)
        #expect(color(in: storage, at: position(of: "first line", in: storage)) == fencedColor)
        #expect(color(in: storage, at: position(of: "second line", in: storage)) == fencedColor)
    }

    @Test func fencedCodeBlockAtEndOfFile() throws {
        let storage = try highlight("""
        intro

        ```
        last block
        ```
        """)
        #expect(color(in: storage, at: position(of: "last block", in: storage)) == fencedColor)
    }

    @Test func twoFencedBlocksBackToBack() throws {
        let storage = try highlight("""
        ```
        first
        ```

        prose between

        ```
        second
        ```
        """)
        #expect(color(in: storage, at: position(of: "first", in: storage)) == fencedColor)
        #expect(color(in: storage, at: position(of: "second", in: storage)) == fencedColor)
        #expect(color(in: storage, at: position(of: "prose between", in: storage)) == prose)
    }

    @Test func singleBacktickOnItsOwnLineIsNotFenced() throws {
        // Negative: a lonely single backtick must not trigger fenced coloring.
        let storage = try highlight("""
        text line
        `
        more text
        """)
        #expect(color(in: storage, at: position(of: "more text", in: storage)) == prose)
    }

    @Test func fencedCodeBlockSpanningBeyondViewport() throws {
        // Edge: a fenced block larger than the viewport+context window.
        // The user is scrolled into the middle of it — fence markers are
        // far above and below. Highlighter must still color the visible
        // interior lines as fenced.
        let grammar = try loadMarkdownGrammar()
        hl.registerGrammar(grammar)

        var lines = ["# Title", "", "```swift"]
        for i in 0..<1000 {
            lines.append("let huge\(i) = \(i) // inside fence")
        }
        lines.append("```")
        lines.append("after the block")
        let text = lines.joined(separator: "\n")
        let storage = NSTextStorage(string: text)

        // Place the visible range around line 500, far from either fence.
        let ns = text as NSString
        let targetRange = ns.range(of: "let huge500 = 500")
        let visible = NSRange(location: targetRange.location, length: 200)
        hl.highlightVisibleRange(
            textStorage: storage, visibleCharRange: visible,
            language: "markdown", font: font
        )

        // The inner line must be fenced-colored even though fence markers
        // are ~500 lines away in both directions.
        #expect(color(in: storage, at: targetRange.location) == fencedColor,
                "deep interior of long fenced block must be fenced-colored")
    }

    @Test func fencedCodeBlockLargeFileViewportPath() throws {
        // Edge: file > viewportHighlightThreshold (50_000 chars) — the editor
        // switches to `highlightVisibleRange`. A fenced block inside the
        // visible window must still color its interior lines correctly.
        let grammar = try loadMarkdownGrammar()
        hl.registerGrammar(grammar)

        var padding = ""
        while padding.count < 60_000 {
            padding += "regular markdown prose line.\n"
        }
        let block = "\n```swift\nlet inner = 42\nlet another = 7\n```\n"
        let text = padding + block + padding
        let storage = NSTextStorage(string: text)

        let blockStart = (text as NSString).range(of: "```swift").location
        // Visible range = just the block + a few lines around it.
        let visible = NSRange(location: blockStart, length: block.count)
        hl.highlightVisibleRange(
            textStorage: storage, visibleCharRange: visible,
            language: "markdown", font: font
        )

        let innerPos = (text as NSString).range(of: "let inner = 42").location
        #expect(color(in: storage, at: innerPos) == fencedColor)
        let anotherPos = (text as NSString).range(of: "let another = 7").location
        #expect(color(in: storage, at: anotherPos) == fencedColor)
    }

    @Test func headingInsideFencedCodeIsNotHeading() throws {
        // Critical: # inside a code fence must remain code-colored, not heading.
        let storage = try highlight("""
        ```
        # this is code, not a heading
        ```
        """)
        let pos = position(of: "# this", in: storage)
        #expect(color(in: storage, at: pos) == fencedColor)
    }

    @Test func boldInsideFencedCodeStaysCode() throws {
        let storage = try highlight("""
        ```
        **not bold**
        ```
        """)
        let pos = position(of: "**not bold**", in: storage)
        #expect(color(in: storage, at: pos) == fencedColor)
    }

    // MARK: - Bold and italic

    @Test func boldIsHighlightedSeparatelyFromHeadings() throws {
        let storage = try highlight("a **bold** word")
        let pos = position(of: "**bold**", in: storage)
        #expect(color(in: storage, at: pos) == boldColor)
        // Make sure bold is NOT the same as any heading color.
        #expect(boldColor != h1Color)
        #expect(boldColor != h2Color)
        #expect(boldColor != h3Color)
    }

    @Test func underscoreBoldIsHighlighted() throws {
        let storage = try highlight("a __bold__ word")
        let pos = position(of: "__bold__", in: storage)
        #expect(color(in: storage, at: pos) == boldColor)
    }

    @Test func italicIsHighlighted() throws {
        let storage = try highlight("an *italic* word")
        let pos = position(of: "*italic*", in: storage)
        #expect(color(in: storage, at: pos) == italicColor)
    }

    @Test func starsAttachedToWordAreNotItalic() throws {
        // `foo*bar*baz` should not become italic — needs whitespace boundary.
        let storage = try highlight("foo*bar*baz")
        let pos = position(of: "*bar*", in: storage)
        #expect(color(in: storage, at: pos) == prose)
    }

    @Test func boldOverridesItalicForSameRange() throws {
        // **x** must be bold, not italic. Bold has higher priority.
        let storage = try highlight("a **x** y")
        let pos = position(of: "**x**", in: storage)
        #expect(color(in: storage, at: pos) == boldColor)
    }

    // MARK: - Lists

    @Test func dashListMarker() throws {
        let storage = try highlight("- item one\n- item two")
        #expect(color(in: storage, at: 0) == listColor)
    }

    @Test func numberedListMarker() throws {
        let storage = try highlight("1. first\n2. second")
        #expect(color(in: storage, at: 0) == listColor)
    }

    @Test func plusListMarker() throws {
        let storage = try highlight("+ item")
        #expect(color(in: storage, at: 0) == listColor)
    }

    @Test func indentedListMarker() throws {
        let storage = try highlight("    - nested")
        let pos = position(of: "-", in: storage)
        #expect(color(in: storage, at: pos) == listColor)
    }

    // MARK: - Links

    @Test func linkIsHighlighted() throws {
        let storage = try highlight("see [docs](https://example.com) here")
        let pos = position(of: "[docs](https://example.com)", in: storage)
        #expect(color(in: storage, at: pos) == linkColor)
    }

    @Test func linkColorDifferentFromProse() {
        #expect(linkColor != prose)
    }

    // MARK: - Quotes and rules

    @Test func blockQuoteIsHighlighted() throws {
        let storage = try highlight("> quoted line")
        #expect(color(in: storage, at: 0) == quoteColor)
    }

    @Test func horizontalRuleIsHighlighted() throws {
        let storage = try highlight("---")
        #expect(color(in: storage, at: 0) == ruleColor)
    }

    @Test func horizontalRuleManyDashes() throws {
        let storage = try highlight("------")
        #expect(color(in: storage, at: 0) == ruleColor)
    }

    // MARK: - Edge cases

    @Test func documentOnlyCodeFence() throws {
        let storage = try highlight("```\nx\n```")
        #expect(color(in: storage, at: 0) == fencedColor)
    }

    @Test func quoteContainingListMarker() throws {
        // List regex требует list marker в начале строки (после опционального whitespace);
        // строка "> - item" начинается с ">", поэтому list не срабатывает, и quote получает всю строку.
        let storage = try highlight("> - item in quote")
        #expect(color(in: storage, at: 0) == quoteColor)
    }

    @Test func fencedCodeColorDiffersFromInlineCodeColor() {
        // Fenced code blocks должны визуально отличаться от inline code,
        // иначе scope markdown.code.fenced не несёт смысла.
        #expect(fencedColor != codeColor)
    }

    @Test func headingDoesNotBleedIntoNextLine() throws {
        let storage = try highlight("# Heading\nplain text")
        let plainPos = position(of: "plain", in: storage)
        #expect(color(in: storage, at: plainPos) == prose)
    }

    @Test func multipleParagraphsKeepProseNeutral() throws {
        let storage = try highlight("first paragraph.\n\nsecond paragraph.")
        #expect(color(in: storage, at: 0) == prose)
        let pos = position(of: "second", in: storage)
        #expect(color(in: storage, at: pos) == prose)
    }

    @Test func heading1ContentBetweenHashesAndEndIsHeadingColored() throws {
        let storage = try highlight("# Hello World")
        let pos = position(of: "Hello", in: storage)
        #expect(color(in: storage, at: pos) == h1Color)
    }

    @Test func allHeadingScopesArePresentInTheme() {
        for level in 1...6 {
            #expect(hl.theme.color(for: "markdown.heading.\(level)") != nil)
        }
    }

    @Test func allMarkdownScopesArePresentInTheme() {
        let scopes = [
            "markdown.bold", "markdown.italic", "markdown.code",
            "markdown.code.fenced", "markdown.link", "markdown.list",
            "markdown.quote", "markdown.rule"
        ]
        for scope in scopes {
            #expect(hl.theme.color(for: scope) != nil, "Missing color for \(scope)")
        }
    }
}
