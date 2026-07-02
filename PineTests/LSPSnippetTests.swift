//
//  LSPSnippetTests.swift
//  PineTests
//
//  Unit tests for LSPSnippet — pure logic that parses LSP snippet syntax
//  (tab stops, placeholders, choices, escapes) into plain text + ordered
//  tab-stop ranges.
//

import Foundation
import Testing

@testable import Pine

@Suite("LSPSnippet Tests")
struct LSPSnippetTests {

    // MARK: - Simple tab stops ($0, $1, $2)

    @Test("Parse $0 as final tab stop")
    func parseFinalTabStop() {
        let snippet = LSPSnippet("hello$0")
        #expect(snippet.text == "hello")
        #expect(snippet.tabStops.count == 1)
        #expect(snippet.tabStops[0].index == 0)
        #expect(snippet.tabStops[0].range == 5..<5)
    }

    @Test("Parse $1 and $2 tab stops")
    func parseNumberedTabStops() {
        let snippet = LSPSnippet("$1$2")
        #expect(snippet.text == "")
        #expect(snippet.tabStops.count == 2)
        #expect(snippet.tabStops[0].index == 1)
        #expect(snippet.tabStops[1].index == 2)
    }

    @Test("Parse tab stops interleaved with text")
    func parseTabStopsInText() {
        let snippet = LSPSnippet("func $1($2) {$0}")
        #expect(snippet.text == "func () {}")
        #expect(snippet.tabStops.count == 3)
        // Ordered by index: $1, $2, then $0 last
        #expect(snippet.tabStops[0].index == 1)
        #expect(snippet.tabStops[0].range == 5..<5)
        #expect(snippet.tabStops[1].index == 2)
        #expect(snippet.tabStops[1].range == 6..<6)
        #expect(snippet.tabStops[2].index == 0)
        #expect(snippet.tabStops[2].range == 9..<9)
    }

    @Test("Parse multi-digit tab stop $10")
    func parseMultiDigitTabStop() {
        let snippet = LSPSnippet("$10")
        #expect(snippet.text == "")
        #expect(snippet.tabStops.count == 1)
        #expect(snippet.tabStops[0].index == 10)
    }

    // MARK: - Placeholders ${1:default}

    @Test("Parse ${1:default} placeholder")
    func parsePlaceholder() {
        let snippet = LSPSnippet("${1:default}")
        #expect(snippet.text == "default")
        #expect(snippet.tabStops.count == 1)
        #expect(snippet.tabStops[0].index == 1)
        #expect(snippet.tabStops[0].range == 0..<7)
    }

    @Test("Parse placeholder with surrounding text")
    func parsePlaceholderWithText() {
        let snippet = LSPSnippet("var ${1:name} = ${2:value}")
        #expect(snippet.text == "var name = value")
        #expect(snippet.tabStops.count == 2)
        #expect(snippet.tabStops[0].index == 1)
        #expect(snippet.tabStops[0].range == 4..<8)
        #expect(snippet.tabStops[1].index == 2)
        #expect(snippet.tabStops[1].range == 11..<16)
    }

    @Test("Parse empty braced tab stop ${1}")
    func parseEmptyBracedTabStop() {
        let snippet = LSPSnippet("${1}")
        #expect(snippet.text == "")
        #expect(snippet.tabStops.count == 1)
        #expect(snippet.tabStops[0].index == 1)
        #expect(snippet.tabStops[0].range == 0..<0)
    }

    // MARK: - Choices ${1|a,b,c|}

    @Test("Parse ${1|a,b,c|} choice — first option used")
    func parseChoice() {
        let snippet = LSPSnippet("${1|a,b,c|}")
        #expect(snippet.text == "a")
        #expect(snippet.tabStops.count == 1)
        #expect(snippet.tabStops[0].index == 1)
        #expect(snippet.tabStops[0].range == 0..<1)
    }

    @Test("Parse choice with multi-word options")
    func parseChoiceMultiWord() {
        let snippet = LSPSnippet("${1|let,var,const|}")
        #expect(snippet.text == "let")
        #expect(snippet.tabStops[0].range == 0..<3)
    }

    @Test("Parse choice within surrounding text")
    func parseChoiceWithText() {
        let snippet = LSPSnippet("type: ${1|Int,String,Bool|}")
        #expect(snippet.text == "type: Int")
        #expect(snippet.tabStops[0].range == 6..<9)
    }

    // MARK: - Escape sequences

    @Test("Escape dollar sign with backslash (\\$)")
    func escapeDollar() {
        // Swift "\\$" → actual string \$  → literal $
        let snippet = LSPSnippet("\\$")
        #expect(snippet.text == "$")
        #expect(snippet.tabStops.isEmpty)
    }

    @Test("Escape backslash (\\\\)")
    func escapeBackslash() {
        // Swift "\\\\" → actual string \\ → literal \
        let snippet = LSPSnippet("\\\\")
        #expect(snippet.text == "\\")
        #expect(snippet.tabStops.isEmpty)
    }

    @Test("Double dollar ($$) produces literal dollar")
    func dollarLiteral() {
        let snippet = LSPSnippet("$$")
        #expect(snippet.text == "$")
        #expect(snippet.tabStops.isEmpty)
    }

    @Test("Escape inside placeholder body")
    func escapeInPlaceholder() {
        // Swift "${1:val\\$}" → actual ${1:val\$}
        // Parser reads body: v-a-l then \$ → appends $, skips both
        let snippet = LSPSnippet("${1:val\\$}")
        #expect(snippet.text == "val$")
        #expect(snippet.tabStops[0].range == 0..<4)
    }

    // MARK: - Tab stop ordering ($0 always last)

    @Test("$0 sorts last regardless of position in snippet")
    func finalTabStopSortsLast() {
        let snippet = LSPSnippet("$0$1$2")
        #expect(snippet.tabStops.count == 3)
        #expect(snippet.tabStops[0].index == 1)
        #expect(snippet.tabStops[1].index == 2)
        #expect(snippet.tabStops[2].index == 0)
    }

    @Test("Tab stops ordered ascending by index")
    func tabStopsOrderedAscending() {
        let snippet = LSPSnippet("$3$1$2$0")
        #expect(snippet.tabStops.count == 4)
        #expect(snippet.tabStops[0].index == 1)
        #expect(snippet.tabStops[1].index == 2)
        #expect(snippet.tabStops[2].index == 3)
        #expect(snippet.tabStops[3].index == 0)
    }

    @Test("Synthetic final tab stop appended when no $0")
    func syntheticFinalTabStop() {
        let snippet = LSPSnippet("hello $1")
        #expect(snippet.tabStops.count == 2)
        #expect(snippet.tabStops[0].index == 1)
        #expect(snippet.tabStops[1].index == 0)  // synthetic, at end of text
    }

    @Test("Duplicate index deduplicated")
    func duplicateIndexDeduplicated() {
        let snippet = LSPSnippet("$1$1")
        // First $1 kept, second dropped. Synthetic $0 appended.
        #expect(snippet.tabStops.count == 2)
        #expect(snippet.tabStops[0].index == 1)
        #expect(snippet.tabStops[1].index == 0)
    }

    // MARK: - No tab stops

    @Test("Plain text with no tab stops")
    func plainTextNoTabStops() {
        let snippet = LSPSnippet("plain text")
        #expect(snippet.text == "plain text")
        #expect(snippet.tabStops.isEmpty)
        #expect(!snippet.hasTabStops)
    }

    @Test("Empty snippet")
    func emptySnippet() {
        let snippet = LSPSnippet("")
        #expect(snippet.text == "")
        #expect(snippet.tabStops.isEmpty)
        #expect(!snippet.hasTabStops)
    }

    @Test("hasTabStops is true when tab stops present")
    func hasTabStopsTrue() {
        let snippet = LSPSnippet("$1")
        #expect(snippet.hasTabStops)
    }

    // MARK: - Complex snippets

    @Test("Function snippet with placeholder and final cursor")
    func functionSnippet() {
        let snippet = LSPSnippet("func ${1:name}(${2:args}) {\n\t$0\n}")
        #expect(snippet.text == "func name(args) {\n\t\n}")
        #expect(snippet.tabStops.count == 3)
        #expect(snippet.tabStops[0].index == 1)
        #expect(snippet.tabStops[1].index == 2)
        #expect(snippet.tabStops[2].index == 0)
    }

    @Test("For-loop snippet")
    func forLoopSnippet() {
        let snippet = LSPSnippet("for ${1:i} in ${2:0}..<${3:n} {\n\t$0\n}")
        #expect(snippet.text == "for i in 0..<n {\n\t\n}")
        #expect(snippet.tabStops.count == 4)
        #expect(snippet.tabStops[0].index == 1)  // i
        #expect(snippet.tabStops[1].index == 2)  // 0
        #expect(snippet.tabStops[2].index == 3)  // n
        #expect(snippet.tabStops[3].index == 0)  // final cursor
    }
}
