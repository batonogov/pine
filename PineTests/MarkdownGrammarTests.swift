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
