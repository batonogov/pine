//
//  PythonGrammarTests.swift
//  PineTests
//
//  Covers Python grammar, with focus on dict-key vs string disambiguation
//  introduced for unifying key/value coloring across grammars (#732).
//

import Testing
import AppKit
@testable import Pine

@Suite(.serialized)
@MainActor
struct PythonGrammarTests {

    nonisolated(unsafe) private let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private let hl = SyntaxHighlighter.shared

    private var commentColor: NSColor { hl.theme.color(for: "comment")! } // swiftlint:disable:this force_unwrapping
    private var stringColor: NSColor { hl.theme.color(for: "string")! } // swiftlint:disable:this force_unwrapping
    private var keywordColor: NSColor { hl.theme.color(for: "keyword")! } // swiftlint:disable:this force_unwrapping
    private var numberColor: NSColor { hl.theme.color(for: "number")! } // swiftlint:disable:this force_unwrapping
    private var typeColor: NSColor { hl.theme.color(for: "type")! } // swiftlint:disable:this force_unwrapping
    private var attributeColor: NSColor { hl.theme.color(for: "attribute")! } // swiftlint:disable:this force_unwrapping

    // MARK: - Helpers

    private func loadGrammar() throws -> Grammar {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Pine/Grammars/python.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Grammar.self, from: data)
    }

    private func highlight(_ text: String) throws -> NSTextStorage {
        let grammar = try loadGrammar()
        hl.registerGrammar(grammar)
        let storage = NSTextStorage(string: text)
        hl.highlight(textStorage: storage, language: "py", font: font)
        return storage
    }

    private func color(in storage: NSTextStorage, at pos: Int) -> NSColor? {
        guard pos < storage.length else { return nil }
        return storage.attribute(.foregroundColor, at: pos, effectiveRange: nil) as? NSColor
    }

    private func position(of substring: String, in storage: NSTextStorage) -> Int {
        (storage.string as NSString).range(of: substring).location
    }

    // MARK: - Comments

    @Test func highlightsLineComments() throws {
        let storage = try highlight("# hello world")
        #expect(color(in: storage, at: 0) == commentColor)
    }

    // MARK: - Plain strings

    @Test func highlightsDoubleQuotedString() throws {
        let storage = try highlight("x = \"hello\"")
        let pos = position(of: "\"hello", in: storage)
        #expect(color(in: storage, at: pos) == stringColor)
    }

    @Test func highlightsSingleQuotedString() throws {
        let storage = try highlight("x = 'hello'")
        let pos = position(of: "'hello", in: storage)
        #expect(color(in: storage, at: pos) == stringColor)
    }

    // MARK: - Dict keys (the unification fix)

    @Test func dictDoubleQuotedKeyIsAttribute() throws {
        let storage = try highlight("d = {\"encryption\": \"none\"}")
        let keyPos = position(of: "\"encryption\"", in: storage)
        #expect(color(in: storage, at: keyPos) == attributeColor,
                "Double-quoted dict key must be highlighted as attribute, not string")
    }

    @Test func dictSingleQuotedKeyIsAttribute() throws {
        let storage = try highlight("d = {'flow': 'xtls'}")
        let keyPos = position(of: "'flow'", in: storage)
        #expect(color(in: storage, at: keyPos) == attributeColor)
    }

    @Test func dictValueIsString() throws {
        let storage = try highlight("d = {\"k\": \"value\"}")
        let valPos = position(of: "\"value\"", in: storage)
        #expect(color(in: storage, at: valPos) == stringColor,
                "Dict value remains a string scope")
    }

    @Test func nestedDictKeysAllAttribute() throws {
        let storage = try highlight("d = {\"outer\": {\"inner\": 1}}")
        let outerPos = position(of: "\"outer\"", in: storage)
        let innerPos = position(of: "\"inner\"", in: storage)
        #expect(color(in: storage, at: outerPos) == attributeColor)
        #expect(color(in: storage, at: innerPos) == attributeColor)
    }

    @Test func multipleKeysOnSameLine() throws {
        let storage = try highlight("d = {\"a\": 1, \"b\": 2, \"c\": 3}")
        for key in ["\"a\"", "\"b\"", "\"c\""] {
            let pos = position(of: key, in: storage)
            #expect(color(in: storage, at: pos) == attributeColor, "Key \(key) must be attribute")
        }
    }

    @Test func keyWithEscapedQuoteIsAttribute() throws {
        let storage = try highlight("d = {\"a\\\"b\": 1}")
        let keyPos = position(of: "\"a", in: storage)
        #expect(color(in: storage, at: keyPos) == attributeColor)
    }

    @Test func keyWithSpacesBeforeColon() throws {
        let storage = try highlight("d = {\"key\"   :   \"value\"}")
        let keyPos = position(of: "\"key\"", in: storage)
        #expect(color(in: storage, at: keyPos) == attributeColor)
    }

    // MARK: - Negative cases / non-key strings

    @Test func sliceWithNumberDoesNotBreakStrings() throws {
        let storage = try highlight("a = items[1:2]\nb = \"safe\"")
        let strPos = position(of: "\"safe\"", in: storage)
        #expect(color(in: storage, at: strPos) == stringColor)
    }

    @Test func typeAnnotationStringIsString() throws {
        // Forward reference: x: "MyType". The "MyType" is value of annotation,
        // sits AFTER the colon so it must be string, not attribute.
        let storage = try highlight("x: \"MyType\" = None")
        let strPos = position(of: "\"MyType\"", in: storage)
        #expect(color(in: storage, at: strPos) == stringColor)
    }

    @Test func lambdaColonDoesNotBreakStrings() throws {
        let storage = try highlight("f = lambda x: \"result\"")
        let strPos = position(of: "\"result\"", in: storage)
        #expect(color(in: storage, at: strPos) == stringColor)
    }

    @Test func functionAnnotationDoesNotConfuseKeys() throws {
        let storage = try highlight("def foo(x: int) -> str:\n    return \"hi\"")
        let strPos = position(of: "\"hi\"", in: storage)
        #expect(color(in: storage, at: strPos) == stringColor)
    }

    @Test func dictComprehensionStringValue() throws {
        let storage = try highlight("d = {k: \"v\" for k in items}")
        let strPos = position(of: "\"v\"", in: storage)
        #expect(color(in: storage, at: strPos) == stringColor)
    }

    @Test func plainStringInListIsString() throws {
        let storage = try highlight("xs = [\"one\", \"two\", \"three\"]")
        for tok in ["\"one\"", "\"two\"", "\"three\""] {
            let pos = position(of: tok, in: storage)
            #expect(color(in: storage, at: pos) == stringColor, "List item \(tok) must be string")
        }
    }

    @Test func numericKeyStaysNumber() throws {
        // Python allows {1: "a"} — 1 is a number literal, not a string-key.
        let storage = try highlight("d = {1: \"a\"}")
        let numPos = position(of: "1", in: storage)
        #expect(color(in: storage, at: numPos) == numberColor)
        let valPos = position(of: "\"a\"", in: storage)
        #expect(color(in: storage, at: valPos) == stringColor)
    }

    @Test func colonInsideStringIsNotKeyTrigger() throws {
        // The string "hello: world" contains a colon inside — must not affect
        // surrounding strings.
        let storage = try highlight("msg = \"hello: world\"")
        let pos = position(of: "\"hello", in: storage)
        #expect(color(in: storage, at: pos) == stringColor)
    }

    // MARK: - Keywords / numbers / types still work

    @Test func keywordHighlightingStillWorks() throws {
        let storage = try highlight("if x: pass")
        let pos = position(of: "if", in: storage)
        #expect(color(in: storage, at: pos) == keywordColor)
    }

    @Test func numberHighlightingStillWorks() throws {
        let storage = try highlight("x = 42")
        let pos = position(of: "42", in: storage)
        #expect(color(in: storage, at: pos) == numberColor)
    }

    @Test func typeHighlightingStillWorks() throws {
        let storage = try highlight("x = int(5)")
        let pos = position(of: "int", in: storage)
        #expect(color(in: storage, at: pos) == typeColor)
    }
}
