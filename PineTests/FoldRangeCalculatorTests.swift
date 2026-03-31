//
//  FoldRangeCalculatorTests.swift
//  PineTests
//

import Testing
import Foundation
@testable import Pine

@MainActor
struct FoldRangeCalculatorTests {

    // MARK: - Brace folding

    @Test func simpleBracePair() {
        let text = "func foo() {\n    bar()\n}"
        let ranges = FoldRangeCalculator.calculate(text: text)
        #expect(ranges.count == 1)
        #expect(ranges[0].startLine == 1)
        #expect(ranges[0].endLine == 3)
        #expect(ranges[0].kind == .braces)
    }

    @Test func nestedBraces() {
        let text = "func foo() {\n    if true {\n        bar()\n    }\n}"
        let ranges = FoldRangeCalculator.calculate(text: text)
        #expect(ranges.count == 2)
        // Outer fold
        let outer = ranges.first { $0.startLine == 1 }
        #expect(outer != nil)
        #expect(outer?.endLine == 5)
        // Inner fold
        let inner = ranges.first { $0.startLine == 2 }
        #expect(inner != nil)
        #expect(inner?.endLine == 4)
    }

    @Test func multipleBracePairsOnSameLevel() {
        let text = "func a() {\n}\nfunc b() {\n}"
        let ranges = FoldRangeCalculator.calculate(text: text)
        #expect(ranges.count == 2)
        #expect(ranges[0].startLine == 1)
        #expect(ranges[0].endLine == 2)
        #expect(ranges[1].startLine == 3)
        #expect(ranges[1].endLine == 4)
    }

    @Test func singleLineBracesNotFoldable() {
        // Braces on the same line should not produce a fold range
        let text = "let x = { a }"
        let ranges = FoldRangeCalculator.calculate(text: text)
        #expect(ranges.isEmpty)
    }

    @Test func emptyTextReturnsNoRanges() {
        let ranges = FoldRangeCalculator.calculate(text: "")
        #expect(ranges.isEmpty)
    }

    @Test func textWithoutBracesReturnsNoRanges() {
        let text = "let x = 1\nlet y = 2\nlet z = 3"
        let ranges = FoldRangeCalculator.calculate(text: text)
        #expect(ranges.isEmpty)
    }

    @Test func unbalancedOpeningBrace() {
        let text = "func foo() {\n    bar()\n"
        let ranges = FoldRangeCalculator.calculate(text: text)
        #expect(ranges.isEmpty)
    }

    @Test func unbalancedClosingBrace() {
        let text = "    bar()\n}"
        let ranges = FoldRangeCalculator.calculate(text: text)
        #expect(ranges.isEmpty)
    }

    @Test func squareBracketFolding() {
        let text = "let arr = [\n    1,\n    2,\n    3\n]"
        let ranges = FoldRangeCalculator.calculate(text: text)
        #expect(ranges.count == 1)
        #expect(ranges[0].startLine == 1)
        #expect(ranges[0].endLine == 5)
        #expect(ranges[0].kind == .brackets)
    }

    @Test func parenthesesFolding() {
        let text = "foo(\n    arg1,\n    arg2\n)"
        let ranges = FoldRangeCalculator.calculate(text: text)
        #expect(ranges.count == 1)
        #expect(ranges[0].startLine == 1)
        #expect(ranges[0].endLine == 4)
        #expect(ranges[0].kind == .parentheses)
    }

    @Test func bracesInStringSkipped() {
        let text = "let s = \"{\"\nlet t = \"}\""
        let ranges = FoldRangeCalculator.calculate(
            text: text,
            skipRanges: [NSRange(location: 9, length: 1), NSRange(location: 21, length: 1)]
        )
        #expect(ranges.isEmpty)
    }

    @Test func bracesInCommentSkipped() {
        let text = "// {\n// }"
        let ranges = FoldRangeCalculator.calculate(
            text: text,
            skipRanges: [NSRange(location: 3, length: 1), NSRange(location: 8, length: 1)]
        )
        #expect(ranges.isEmpty)
    }

    @Test func mixedBracketTypes() {
        // { } on different lines + [ ] on same line — only braces produce fold
        let text = "func foo() {\n    let arr = [1, 2]\n}"
        let ranges = FoldRangeCalculator.calculate(text: text)
        #expect(ranges.count == 1)
        #expect(ranges[0].kind == .braces)
    }

    @Test func rangesAreSortedByStartLine() {
        let text = "func a() {\n}\nfunc b() {\n    if true {\n    }\n}"
        let ranges = FoldRangeCalculator.calculate(text: text)
        let startLines = ranges.map(\.startLine)
        #expect(startLines == startLines.sorted())
    }

    @Test func deeplyNestedBraces() {
        let text = "a {\n  b {\n    c {\n      d()\n    }\n  }\n}"
        let ranges = FoldRangeCalculator.calculate(text: text)
        #expect(ranges.count == 3)
        let outer = ranges.first { $0.startLine == 1 }
        #expect(outer?.endLine == 7)
        let middle = ranges.first { $0.startLine == 2 }
        #expect(middle?.endLine == 6)
        let inner = ranges.first { $0.startLine == 3 }
        #expect(inner?.endLine == 5)
    }

    // MARK: - Binary search skip ranges edge cases (#298)

    @Test func emptySkipRangesDoesNotCrash() {
        let text = "func foo() {\n    bar()\n}"
        let ranges = FoldRangeCalculator.calculate(text: text, skipRanges: [])
        #expect(ranges.count == 1)
    }

    @Test func singleElementSkipRange() {
        // Single skip range covering the opening brace
        let text = "func foo() {\n    bar()\n}"
        let bracePos = (text as NSString).range(of: "{").location
        let ranges = FoldRangeCalculator.calculate(
            text: text,
            skipRanges: [NSRange(location: bracePos, length: 1)]
        )
        // Opening brace is skipped — no fold range
        #expect(ranges.isEmpty)
    }

    @Test func positionAtSkipRangeBoundary() {
        // Skip range [5, 10) — test positions 4 (before), 5 (start), 9 (inside), 10 (after)
        let text = "abcd{\n  x\n}efgh"
        // Skip range covers positions 5-9 (the newline + content inside braces)
        // but NOT the braces themselves — fold should still work
        let ranges = FoldRangeCalculator.calculate(
            text: text,
            skipRanges: [NSRange(location: 5, length: 4)]
        )
        #expect(ranges.count == 1)
    }

    @Test func mismatchedBracketsWithStackLastOptimization() {
        // ( { ) } — ')' doesn't match '{' on stack top, so ')' is skipped.
        // Then '}' matches '{' on stack top — valid fold from line 2 to line 4.
        let text = "(\n{\n)\n}"
        let ranges = FoldRangeCalculator.calculate(text: text)
        #expect(ranges.count == 1)
        #expect(ranges[0].startLine == 2)
        #expect(ranges[0].endLine == 4)
        #expect(ranges[0].kind == .braces)
    }

    @Test func characterOffsetsAreCorrect() {
        let text = "{\n  x\n}"
        // { is at offset 0, } is at offset 6
        let ranges = FoldRangeCalculator.calculate(text: text)
        #expect(ranges.count == 1)
        #expect(ranges[0].startCharIndex == 0)
        #expect(ranges[0].endCharIndex == 6)
    }
}
