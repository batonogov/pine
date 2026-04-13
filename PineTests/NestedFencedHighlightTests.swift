//
//  NestedFencedHighlightTests.swift
//  PineTests
//
//  Verifies that fenced code blocks with a language tag apply
//  the inner language grammar to the block content.
//

import Testing
import AppKit
@testable import Pine

@Suite(.serialized)
@MainActor
struct NestedFencedHighlightTests {

    nonisolated(unsafe) private let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private let hl = SyntaxHighlighter.shared

    // swiftlint:disable force_unwrapping
    private var fencedColor: NSColor { hl.theme.color(for: "markdown.code.fenced")! }
    private var keywordColor: NSColor { hl.theme.color(for: "keyword")! }
    private var stringColor: NSColor { hl.theme.color(for: "string")! }
    private var numberColor: NSColor { hl.theme.color(for: "number")! }
    private var commentColor: NSColor { hl.theme.color(for: "comment")! }
    private var functionColor: NSColor { hl.theme.color(for: "function")! }
    // swiftlint:enable force_unwrapping

    // MARK: - Helpers

    private func registerGrammars() throws {
        let grammarsDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Pine/Grammars")

        for name in ["markdown", "swift", "python", "shell"] {
            let url = grammarsDir.appendingPathComponent("\(name).json")
            let data = try Data(contentsOf: url)
            let grammar = try JSONDecoder().decode(Grammar.self, from: data)
            hl.registerGrammar(grammar)
        }
    }

    private func highlight(_ text: String) throws -> NSTextStorage {
        try registerGrammars()
        let storage = NSTextStorage(string: text)
        hl.highlight(textStorage: storage, language: "md", font: font)
        return storage
    }

    private func color(in storage: NSTextStorage, at position: Int) -> NSColor? {
        guard position < storage.length else { return nil }
        return storage.attribute(.foregroundColor, at: position, effectiveRange: nil) as? NSColor
    }

    private func position(of substring: String, in storage: NSTextStorage) -> Int {
        (storage.string as NSString).range(of: substring).location
    }

    // MARK: - Swift fenced block

    @Test func swiftKeywordHighlightedInsideFencedBlock() throws {
        let text = """
        ```swift
        let x = 1
        ```
        """
        let storage = try highlight(text)
        let letPos = position(of: "let", in: storage)
        #expect(color(in: storage, at: letPos) == keywordColor)
    }

    @Test func swiftNumberHighlightedInsideFencedBlock() throws {
        let text = """
        ```swift
        let x = 1
        ```
        """
        let storage = try highlight(text)
        let numPos = position(of: "1", in: storage)
        #expect(color(in: storage, at: numPos) == numberColor)
    }

    // MARK: - Python fenced block

    @Test func pythonKeywordsHighlightedInsideFencedBlock() throws {
        let text = """
        ```python
        def hello():
            pass
        ```
        """
        let storage = try highlight(text)
        // `def hello` matches as function scope in Python grammar (def + name),
        // so `def` gets function color, not keyword color.
        let defPos = position(of: "def", in: storage)
        #expect(color(in: storage, at: defPos) == functionColor)

        let passPos = position(of: "pass", in: storage)
        #expect(color(in: storage, at: passPos) == keywordColor)
    }

    @Test func pythonFunctionHighlightedInsideFencedBlock() throws {
        let text = """
        ```python
        def hello():
            pass
        ```
        """
        let storage = try highlight(text)
        let helloPos = position(of: "hello", in: storage)
        #expect(color(in: storage, at: helloPos) == functionColor)
    }

    // MARK: - No language tag

    @Test func fencedBlockWithoutLanguageKeepsUniformColor() throws {
        let text = """
        ```
        some code here
        ```
        """
        let storage = try highlight(text)
        let pos = position(of: "some code", in: storage)
        #expect(color(in: storage, at: pos) == fencedColor)
    }

    // MARK: - Unknown language

    @Test func fencedBlockWithUnknownLanguageFallsBackToFencedColor() throws {
        let text = """
        ```unknownlang
        foo bar
        ```
        """
        let storage = try highlight(text)
        let pos = position(of: "foo", in: storage)
        #expect(color(in: storage, at: pos) == fencedColor)
    }

    // MARK: - Two different language blocks

    @Test func twoDifferentLanguageBlocksInSameFile() throws {
        let text = """
        ```swift
        let x = 1
        ```

        ```python
        def hello():
            pass
        ```
        """
        let storage = try highlight(text)

        let letPos = position(of: "let", in: storage)
        #expect(color(in: storage, at: letPos) == keywordColor)

        // `def hello` matches as function scope in Python grammar
        let defPos = position(of: "def", in: storage)
        #expect(color(in: storage, at: defPos) == functionColor)

        let passPos = position(of: "pass", in: storage)
        #expect(color(in: storage, at: passPos) == keywordColor)
    }

    // MARK: - Bash/shell alias

    @Test func bashAliasResolvesToShellGrammar() throws {
        let text = """
        ```bash
        echo "hello"
        ```
        """
        let storage = try highlight(text)
        // `echo` is scope `function` in the shell grammar (built-in command).
        let echoPos = position(of: "echo", in: storage)
        #expect(color(in: storage, at: echoPos) == functionColor)
    }

    // MARK: - Fence markers stay fenced color

    @Test func fenceMarkersKeepFencedColor() throws {
        let text = """
        ```swift
        let x = 1
        ```
        """
        let storage = try highlight(text)
        // Opening fence marker
        let openPos = position(of: "```swift", in: storage)
        #expect(color(in: storage, at: openPos) == fencedColor)
    }

    // MARK: - Surrounding markdown unaffected

    @Test func markdownOutsideFencedBlockUnaffected() throws {
        let text = """
        # Heading

        ```swift
        let x = 1
        ```

        Plain text.
        """
        let storage = try highlight(text)

        // swiftlint:disable:next force_unwrapping
        let headingColor = hl.theme.color(for: "markdown.heading.1")!
        let headingPos = position(of: "# Heading", in: storage)
        #expect(color(in: storage, at: headingPos) == headingColor)

        let plainPos = position(of: "Plain text", in: storage)
        #expect(color(in: storage, at: plainPos) == NSColor.textColor)
    }

    // MARK: - Comment inside fenced block

    @Test func commentInsideFencedBlockHighlighted() throws {
        let text = """
        ```swift
        // this is a comment
        let x = 1
        ```
        """
        let storage = try highlight(text)
        let commentPos = position(of: "// this", in: storage)
        #expect(color(in: storage, at: commentPos) == commentColor)
    }

    // MARK: - String inside fenced block

    @Test func stringInsideFencedBlockHighlighted() throws {
        let text = """
        ```swift
        let s = "hello"
        ```
        """
        let storage = try highlight(text)
        let strPos = position(of: "\"hello\"", in: storage)
        #expect(color(in: storage, at: strPos) == stringColor)
    }

    // MARK: - Viewport highlighting

    @Test func viewportHighlightingAlsoAppliesNestedGrammar() throws {
        try registerGrammars()
        let text = """
        ```swift
        let x = 1
        ```
        """
        let storage = NSTextStorage(string: text)
        let fullRange = NSRange(location: 0, length: storage.length)
        hl.highlightVisibleRange(
            textStorage: storage,
            visibleCharRange: fullRange,
            language: "md",
            font: font
        )
        let letPos = position(of: "let", in: storage)
        #expect(color(in: storage, at: letPos) == keywordColor)
    }

    // MARK: - computeMatches also works

    @Test func computeMatchesIncludesNestedMatches() throws {
        try registerGrammars()
        let text = """
        ```swift
        let x = 1
        ```
        """
        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        let result = hl.computeMatches(
            text: text,
            language: "md",
            repaintRange: fullRange,
            searchRange: fullRange
        )
        #expect(result != nil)
        let keywordMatches = result?.matches.filter { $0.scope == "keyword" } ?? []
        #expect(!keywordMatches.isEmpty)
    }
}
