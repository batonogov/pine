//
//  YAMLGrammarTests.swift
//  PineTests
//

import Testing
import AppKit
@testable import Pine

@Suite(.serialized)
@MainActor
struct YAMLGrammarTests {

    nonisolated(unsafe) private let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private let hl = SyntaxHighlighter.shared

    private var commentColor: NSColor { hl.theme.color(for: "comment")! } // swiftlint:disable:this force_unwrapping
    private var stringColor: NSColor { hl.theme.color(for: "string")! } // swiftlint:disable:this force_unwrapping
    private var keywordColor: NSColor { hl.theme.color(for: "keyword")! } // swiftlint:disable:this force_unwrapping
    private var numberColor: NSColor { hl.theme.color(for: "number")! } // swiftlint:disable:this force_unwrapping
    private var attributeColor: NSColor { hl.theme.color(for: "attribute")! } // swiftlint:disable:this force_unwrapping

    // MARK: - Helpers

    private func loadYAMLGrammar() throws -> Grammar {
        let grammarURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Pine/Grammars/yaml.json")
        let data = try Data(contentsOf: grammarURL)
        return try JSONDecoder().decode(Grammar.self, from: data)
    }

    private func highlight(_ text: String) throws -> NSTextStorage {
        let grammar = try loadYAMLGrammar()
        hl.registerGrammar(grammar)
        let storage = NSTextStorage(string: text)
        hl.highlight(textStorage: storage, language: "yaml", font: font)
        return storage
    }

    private func color(in storage: NSTextStorage, at position: Int) -> NSColor? {
        guard position < storage.length else { return nil }
        return storage.attribute(.foregroundColor, at: position, effectiveRange: nil) as? NSColor
    }

    /// Returns position of the first occurrence of substring in the storage string.
    private func position(of substring: String, in storage: NSTextStorage) -> Int {
        (storage.string as NSString).range(of: substring).location
    }

    // MARK: - Comments

    @Test func highlightsComments() throws {
        let storage = try highlight("# this is a comment")
        #expect(color(in: storage, at: 0) == commentColor)
        #expect(color(in: storage, at: 5) == commentColor)
    }

    @Test func highlightsInlineComments() throws {
        let storage = try highlight("key: value # inline comment")
        let commentPos = position(of: "# inline", in: storage)
        #expect(color(in: storage, at: commentPos) == commentColor)
    }

    // MARK: - Keys

    @Test func highlightsTopLevelKeys() throws {
        let storage = try highlight("name: Pine")
        let keyPos = position(of: "name", in: storage)
        #expect(color(in: storage, at: keyPos) == attributeColor)
    }

    @Test func highlightsIndentedKeys() throws {
        let storage = try highlight("parent:\n  child: value")
        let childPos = position(of: "child", in: storage)
        #expect(color(in: storage, at: childPos) == attributeColor,
                "Indented keys must be highlighted as attributes")
    }

    @Test func highlightsDeeplyNestedKeys() throws {
        let storage = try highlight("a:\n  b:\n    c:\n      deep-key: val")
        let deepPos = position(of: "deep-key", in: storage)
        #expect(color(in: storage, at: deepPos) == attributeColor,
                "Deeply nested keys must be highlighted")
    }

    @Test func highlightsKeysWithDots() throws {
        let storage = try highlight("some.dotted.key: value")
        let keyPos = position(of: "some.dotted.key", in: storage)
        #expect(color(in: storage, at: keyPos) == attributeColor)
    }

    // MARK: - Strings

    @Test func highlightsDoubleQuotedStrings() throws {
        let storage = try highlight("key: \"hello world\"")
        let strPos = position(of: "\"hello", in: storage)
        #expect(color(in: storage, at: strPos) == stringColor)
    }

    @Test func highlightsSingleQuotedStrings() throws {
        let storage = try highlight("key: 'hello world'")
        let strPos = position(of: "'hello", in: storage)
        #expect(color(in: storage, at: strPos) == stringColor)
    }

    // MARK: - Keywords (booleans, null)

    @Test func highlightsBooleans() throws {
        let storage = try highlight("enabled: true\ndisabled: false")
        let truePos = position(of: "true", in: storage)
        let falsePos = position(of: "false", in: storage)
        #expect(color(in: storage, at: truePos) == keywordColor)
        #expect(color(in: storage, at: falsePos) == keywordColor)
    }

    @Test func highlightsNull() throws {
        let storage = try highlight("value: null")
        let nullPos = position(of: "null", in: storage)
        #expect(color(in: storage, at: nullPos) == keywordColor)
    }

    // MARK: - Numbers

    @Test func highlightsIntegers() throws {
        let storage = try highlight("port: 8080")
        let numPos = position(of: "8080", in: storage)
        #expect(color(in: storage, at: numPos) == numberColor)
    }

    @Test func highlightsFloats() throws {
        let storage = try highlight("ratio: 3.14")
        let numPos = position(of: "3.14", in: storage)
        #expect(color(in: storage, at: numPos) == numberColor)
    }

    // MARK: - Document separators

    @Test func highlightsDocumentSeparator() throws {
        let storage = try highlight("---\nkey: value")
        #expect(color(in: storage, at: 0) == keywordColor)
    }

    // MARK: - Anchors and aliases

    @Test func highlightsAnchors() throws {
        let storage = try highlight("defaults: &defaults\n  adapter: postgres")
        let anchorPos = position(of: "&defaults", in: storage)
        #expect(color(in: storage, at: anchorPos) == attributeColor)
    }

    @Test func highlightsAliases() throws {
        let storage = try highlight("production:\n  <<: *defaults")
        let aliasPos = position(of: "*defaults", in: storage)
        #expect(color(in: storage, at: aliasPos) == attributeColor)
    }

    // MARK: - Block scalar indicators

    @Test func highlightsBlockScalarIndicators() throws {
        let storage = try highlight("description: >\n  folded text")
        let indicatorPos = position(of: ">", in: storage)
        #expect(color(in: storage, at: indicatorPos) == keywordColor,
                "Block scalar indicator > should be highlighted")
    }

    @Test func highlightsBlockScalarWithChomping() throws {
        let storage = try highlight("description: >-\n  folded text")
        let indicatorPos = position(of: ">-", in: storage)
        #expect(color(in: storage, at: indicatorPos) == keywordColor,
                "Block scalar indicator >- should be highlighted")
    }

    @Test func highlightsLiteralBlockScalar() throws {
        let storage = try highlight("script: |\n  echo hello")
        let indicatorPos = position(of: "|", in: storage)
        #expect(color(in: storage, at: indicatorPos) == keywordColor,
                "Block scalar indicator | should be highlighted")
    }

    // MARK: - Tag handles

    @Test func highlightsTagHandles() throws {
        let storage = try highlight("value: !!str 123")
        let tagPos = position(of: "!!str", in: storage)
        #expect(color(in: storage, at: tagPos) == attributeColor,
                "Tag handles like !!str should be highlighted")
    }
}
