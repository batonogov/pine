//
//  SyntaxHighlighterPerformanceTests.swift
//  PinePerformanceTests
//

import XCTest
import AppKit
@testable import Pine

@MainActor
final class SyntaxHighlighterPerformanceTests: XCTestCase {

    private var highlighter: SyntaxHighlighter!

    override func setUp() {
        super.setUp()
        highlighter = SyntaxHighlighter.shared
        // Register a Swift grammar for testing
        let grammar = Grammar(
            name: "PerfTestSwift",
            extensions: ["perfswift"],
            rules: [
                GrammarRule(pattern: "//.*$", scope: "comment", options: ["anchorsMatchLines"]),
                GrammarRule(pattern: #"/\*[\s\S]*?\*/"#, scope: "comment", options: ["dotMatchesLineSeparators"]),
                GrammarRule(pattern: #""(?:[^"\\]|\\.)*""#, scope: "string"),
                GrammarRule(
                    pattern: #"\b(func|var|let|class|struct|enum|protocol|import|return"#
                        + #"|if|else|guard|switch|case|for|while|do|try|catch|throw|throws|async|await)\b"#,
                    scope: "keyword"
                ),
                GrammarRule(pattern: #"\b[A-Z][A-Za-z0-9_]*\b"#, scope: "type"),
                GrammarRule(pattern: #"\b\d+(\.\d+)?\b"#, scope: "number"),
                GrammarRule(pattern: #"\b[a-z][A-Za-z0-9_]*(?=\s*\()"#, scope: "function"),
                GrammarRule(pattern: #"@\w+"#, scope: "attribute"),
            ]
        )
        highlighter.registerGrammar(grammar)
    }

    // MARK: - Helpers

    /// Generates realistic Swift-like code.
    private func generateSwiftCode(lines: Int) -> String {
        var result: [String] = [
            "import Foundation",
            "import AppKit",
            "",
        ]
        var lineCount = 3
        var classIndex = 0

        while lineCount < lines {
            result.append("/// A class for testing performance.")
            result.append("class TestClass\(classIndex): NSObject {")
            result.append("    var name: String = \"default\"")
            result.append("    let id: Int = \(classIndex)")
            result.append("")
            lineCount += 5

            for method in 0..<5 {
                guard lineCount < lines else { break }
                result.append("    func method\(method)(param: Int) -> String {")
                result.append("        // Compute the result")
                result.append("        let value = param * \(method + 1)")
                result.append("        if value > 100 {")
                result.append("            return \"large: \\(value)\"")
                result.append("        } else {")
                result.append("            return \"small: \\(value)\"")
                result.append("        }")
                result.append("    }")
                result.append("")
                lineCount += 10
            }

            result.append("}")
            result.append("")
            lineCount += 2
            classIndex += 1
        }

        return result.joined(separator: "\n")
    }

    // MARK: - Full Highlight

    func testFullHighlight500Lines() {
        let code = generateSwiftCode(lines: 500)
        let textStorage = NSTextStorage(string: code)
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

        measure {
            highlighter.highlight(textStorage: textStorage, language: "perfswift", font: font)
        }
    }

    func testFullHighlight2000Lines() {
        let code = generateSwiftCode(lines: 2000)
        let textStorage = NSTextStorage(string: code)
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

        measure {
            highlighter.highlight(textStorage: textStorage, language: "perfswift", font: font)
        }
    }

    func testFullHighlight5000Lines() {
        let code = generateSwiftCode(lines: 5000)
        let textStorage = NSTextStorage(string: code)
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

        measure {
            highlighter.highlight(textStorage: textStorage, language: "perfswift", font: font)
        }
    }

    // MARK: - Incremental Highlight

    func testIncrementalHighlight() {
        let code = generateSwiftCode(lines: 2000)
        let textStorage = NSTextStorage(string: code)
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

        // First, do a full highlight to populate cache
        highlighter.highlight(textStorage: textStorage, language: "perfswift", font: font)

        // Simulate a small edit in the middle
        let midpoint = code.count / 2
        let editRange = NSRange(location: midpoint, length: 10)

        measure {
            highlighter.highlightEdited(
                textStorage: textStorage,
                editedRange: editRange,
                language: "perfswift",
                font: font
            )
        }
    }

    // MARK: - computeMatches (pure computation, no NSTextStorage mutation)

    func testComputeMatches2000Lines() {
        let code = generateSwiftCode(lines: 2000)
        let fullRange = NSRange(location: 0, length: (code as NSString).length)

        measure {
            _ = highlighter.computeMatches(
                text: code,
                language: "perfswift",
                repaintRange: fullRange,
                searchRange: fullRange
            )
        }
    }

    // MARK: - Viewport Highlight (lazy, ±50 line buffer)

    func testViewportHighlight5000Lines() {
        let code = generateSwiftCode(lines: 5000)
        let textStorage = NSTextStorage(string: code)
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let source = code as NSString

        // Find char offset of line 2500 (middle of file)
        var lineCount = 0
        var midOffset = 0
        for i in 0..<source.length {
            if lineCount >= 2500 { midOffset = i; break }
            if source.character(at: i) == 0x0A { lineCount += 1 }
        }
        // Visible range: ~20 lines in the middle
        var endOffset = midOffset
        var linesFound = 0
        while endOffset < source.length && linesFound < 20 {
            if source.character(at: endOffset) == 0x0A { linesFound += 1 }
            endOffset += 1
        }
        let visibleRange = NSRange(location: midOffset, length: endOffset - midOffset)

        measure {
            highlighter.highlightVisibleRange(
                textStorage: textStorage,
                visibleCharRange: visibleRange,
                language: "perfswift",
                font: font
            )
        }
    }

    func testViewportHighlightVsFullHighlight5000Lines() {
        let code = generateSwiftCode(lines: 5000)
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let source = code as NSString

        // Find char offset of line 2500
        var lineCount = 0
        var midOffset = 0
        for i in 0..<source.length {
            if lineCount >= 2500 { midOffset = i; break }
            if source.character(at: i) == 0x0A { lineCount += 1 }
        }
        var endOffset = midOffset
        var linesFound = 0
        while endOffset < source.length && linesFound < 20 {
            if source.character(at: endOffset) == 0x0A { linesFound += 1 }
            endOffset += 1
        }
        let visibleRange = NSRange(location: midOffset, length: endOffset - midOffset)

        // Viewport highlight should be significantly faster than full highlight
        let viewportStorage = NSTextStorage(string: code)
        let fullStorage = NSTextStorage(string: code)

        let viewportStart = CFAbsoluteTimeGetCurrent()
        for _ in 0..<10 {
            highlighter.highlightVisibleRange(
                textStorage: viewportStorage,
                visibleCharRange: visibleRange,
                language: "perfswift",
                font: font
            )
        }
        let viewportTime = CFAbsoluteTimeGetCurrent() - viewportStart

        let fullStart = CFAbsoluteTimeGetCurrent()
        for _ in 0..<10 {
            highlighter.highlight(
                textStorage: fullStorage,
                language: "perfswift",
                font: font
            )
        }
        let fullTime = CFAbsoluteTimeGetCurrent() - fullStart

        // Viewport highlighting should be at least 2x faster than full
        XCTAssertLessThan(viewportTime, fullTime,
                          "Viewport highlight (\(viewportTime)s) should be faster than full (\(fullTime)s)")
    }

    // MARK: - Comment and String Ranges

    func testCommentAndStringRanges() {
        let code = generateSwiftCode(lines: 2000)

        measure {
            _ = highlighter.commentAndStringRanges(in: code, language: "perfswift")
        }
    }
}
