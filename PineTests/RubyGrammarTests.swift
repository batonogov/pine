//
//  RubyGrammarTests.swift
//  PineTests
//
//  Covers Ruby grammar, with focus on hash-rocket (`=>`) dict-key vs
//  string disambiguation introduced for unifying key/value coloring
//  across grammars (#732).
//

import Testing
import AppKit
@testable import Pine

@Suite(.serialized)
@MainActor
struct RubyGrammarTests {

    nonisolated(unsafe) private let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private let hl = SyntaxHighlighter.shared

    private var stringColor: NSColor { hl.theme.color(for: "string")! } // swiftlint:disable:this force_unwrapping
    private var attributeColor: NSColor { hl.theme.color(for: "attribute")! } // swiftlint:disable:this force_unwrapping

    // MARK: - Helpers

    private func loadGrammar() throws -> Grammar {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Pine/Grammars/ruby.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Grammar.self, from: data)
    }

    private func highlight(_ text: String) throws -> NSTextStorage {
        let grammar = try loadGrammar()
        hl.registerGrammar(grammar)
        let storage = NSTextStorage(string: text)
        hl.highlight(textStorage: storage, language: "rb", font: font)
        return storage
    }

    private func color(in storage: NSTextStorage, at pos: Int) -> NSColor? {
        guard pos >= 0, pos < storage.length else { return nil }
        return storage.attribute(.foregroundColor, at: pos, effectiveRange: nil) as? NSColor
    }

    private func position(of substring: String, in storage: NSTextStorage) -> Int {
        (storage.string as NSString).range(of: substring).location
    }

    // MARK: - Hash-rocket keys (the unification fix)

    @Test func doubleQuotedHashRocketKeyIsAttribute() throws {
        let storage = try highlight("h = { \"name\" => \"Alice\" }")
        let keyPos = position(of: "\"name\"", in: storage)
        #expect(color(in: storage, at: keyPos) == attributeColor,
                "Double-quoted hash-rocket key must be attribute, not string")
    }

    @Test func singleQuotedHashRocketKeyIsAttribute() throws {
        let storage = try highlight("h = { 'name' => 'Alice' }")
        let keyPos = position(of: "'name'", in: storage)
        #expect(color(in: storage, at: keyPos) == attributeColor)
    }

    @Test func hashRocketValueIsString() throws {
        let storage = try highlight("h = { \"k\" => \"value\" }")
        let valPos = position(of: "\"value\"", in: storage)
        #expect(color(in: storage, at: valPos) == stringColor)
    }

    @Test func multipleHashRocketPairsOnSameLine() throws {
        let storage = try highlight("h = { \"a\" => 1, \"b\" => 2, \"c\" => 3 }")
        for key in ["\"a\"", "\"b\"", "\"c\""] {
            let pos = position(of: key, in: storage)
            #expect(color(in: storage, at: pos) == attributeColor, "Key \(key) must be attribute")
        }
    }

    @Test func nestedHashRocketKeysAllAttribute() throws {
        let storage = try highlight("h = { \"outer\" => { \"inner\" => 1 } }")
        let outerPos = position(of: "\"outer\"", in: storage)
        let innerPos = position(of: "\"inner\"", in: storage)
        #expect(color(in: storage, at: outerPos) == attributeColor)
        #expect(color(in: storage, at: innerPos) == attributeColor)
    }

    @Test func hashRocketWithExtraSpacesBeforeArrow() throws {
        let storage = try highlight("h = { \"k\"  =>  \"v\" }")
        let keyPos = position(of: "\"k\"", in: storage)
        #expect(color(in: storage, at: keyPos) == attributeColor)
    }

    @Test func keyWithEscapedQuoteIsAttribute() throws {
        let storage = try highlight("h = { \"a\\\"b\" => 1 }")
        let keyPos = position(of: "\"a", in: storage)
        #expect(color(in: storage, at: keyPos) == attributeColor)
    }

    // MARK: - Regressions: plain strings must NOT become attributes

    @Test func plainStringWithoutArrowStaysString() throws {
        let storage = try highlight("x = \"hello\"")
        let pos = position(of: "\"hello\"", in: storage)
        #expect(color(in: storage, at: pos) == stringColor)
    }

    @Test func singleQuotedPlainStringStaysString() throws {
        let storage = try highlight("x = 'hello'")
        let pos = position(of: "'hello'", in: storage)
        #expect(color(in: storage, at: pos) == stringColor)
    }

    @Test func regexLiteralStaysString() throws {
        // Regex literal `/foo/` must not be recoloured as attribute —
        // it is not a hash key.
        let storage = try highlight("m = /foo/")
        let pos = position(of: "/foo/", in: storage)
        #expect(color(in: storage, at: pos) == stringColor)
    }

    @Test func stringContainingArrowInContentStaysString() throws {
        // The `=>` sits INSIDE the string, not after it, so the string
        // must remain a plain string.
        let storage = try highlight("msg = \"contains => arrow\"")
        let pos = position(of: "\"contains", in: storage)
        #expect(color(in: storage, at: pos) == stringColor)
    }

    @Test func symbolShorthandIsNotAttribute() throws {
        // `{ key: val }` is the Ruby 1.9+ symbol shorthand. The `key:`
        // disambiguation conflicts with the ternary operator, so this
        // is deliberately deferred — `key` must NOT become an attribute.
        let storage = try highlight("h = { key: \"val\" }")
        let keyPos = position(of: "key", in: storage)
        let keyColor = color(in: storage, at: keyPos)
        #expect(keyColor != attributeColor,
                "Symbol shorthand `key:` must NOT be highlighted as attribute (deferred)")
    }

    @Test func stringInArrayStaysString() throws {
        let storage = try highlight("xs = [\"one\", \"two\", \"three\"]")
        for tok in ["\"one\"", "\"two\"", "\"three\""] {
            let pos = position(of: tok, in: storage)
            #expect(color(in: storage, at: pos) == stringColor, "Array item \(tok) must be string")
        }
    }
}
