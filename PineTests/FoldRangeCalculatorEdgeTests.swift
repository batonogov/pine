//
//  FoldRangeCalculatorEdgeTests.swift
//  PineTests
//

import Testing
import Foundation
@testable import Pine

@Suite("FoldRangeCalculator Edge Case Tests")
@MainActor
struct FoldRangeCalculatorEdgeTests {

    // MARK: - Empty and trivial inputs

    @Test func emptyText_producesNoRanges() {
        let ranges = FoldRangeCalculator.calculate(text: "")
        #expect(ranges.isEmpty)
    }

    @Test func bracesOnSameLine_producesNoRange() {
        let ranges = FoldRangeCalculator.calculate(text: "{ }")
        #expect(ranges.isEmpty)
    }

    @Test func onlyOpeningBrackets_producesNoRanges() {
        let text = "{\n[\n("
        let ranges = FoldRangeCalculator.calculate(text: text)
        #expect(ranges.isEmpty)
    }

    // MARK: - maxStackDepth

    @Test func stackDepthCappedAtMax() {
        // Build text with more nested braces than maxStackDepth
        let depth = FoldRangeCalculator.maxStackDepth + 50
        var text = ""
        for _ in 0..<depth {
            text += "{\n"
        }
        for _ in 0..<depth {
            text += "}\n"
        }
        let ranges = FoldRangeCalculator.calculate(text: text)
        // Should not crash; results count bounded by maxStackDepth
        #expect(ranges.count <= FoldRangeCalculator.maxStackDepth)
    }

    @Test func exactlyAtMaxStackDepth() {
        let depth = FoldRangeCalculator.maxStackDepth
        var text = ""
        for _ in 0..<depth {
            text += "{\n"
        }
        for _ in 0..<depth {
            text += "}\n"
        }
        let ranges = FoldRangeCalculator.calculate(text: text)
        // At exactly max depth, all should be matched
        #expect(ranges.count == depth)
    }

    // MARK: - All three bracket types in one text

    @Test func allBracketTypesProduceFoldRanges() {
        let text = "{\n  [\n    (\n      x\n    )\n  ]\n}"
        let ranges = FoldRangeCalculator.calculate(text: text)
        #expect(ranges.count == 3)
        let kinds = Set(ranges.map(\.kind))
        #expect(kinds.contains(.braces))
        #expect(kinds.contains(.brackets))
        #expect(kinds.contains(.parentheses))
    }

    // MARK: - Skip ranges edge cases

    @Test func entireTextInSkipRangeProducesNoFolds() {
        let text = "{\n  x\n}"
        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        let ranges = FoldRangeCalculator.calculate(text: text, skipRanges: [fullRange])
        #expect(ranges.isEmpty)
    }

    @Test func adjacentSkipRanges() {
        // Skip ranges [0,1) and [1,2) — non-overlapping adjacent
        let text = "{}\n(\n)"
        let ranges = FoldRangeCalculator.calculate(
            text: text,
            skipRanges: [NSRange(location: 0, length: 1), NSRange(location: 1, length: 1)]
        )
        // Braces are skipped, parentheses should still work
        #expect(ranges.count == 1)
        #expect(ranges[0].kind == .parentheses)
    }

    // MARK: - Unicode text

    @Test func unicodeBracketsWork() {
        let text = "{\n  let emoji = \"🎉\"\n}"
        let ranges = FoldRangeCalculator.calculate(text: text)
        #expect(ranges.count == 1)
        #expect(ranges[0].kind == .braces)
    }

    // MARK: - Only closing brackets

    @Test func onlyClosingBracketsProduceNoRanges() {
        let text = "}\n]\n)"
        let ranges = FoldRangeCalculator.calculate(text: text)
        #expect(ranges.isEmpty)
    }

    // MARK: - Single newline text

    @Test func singleNewlineText() {
        let ranges = FoldRangeCalculator.calculate(text: "\n")
        #expect(ranges.isEmpty)
    }

    // MARK: - Interleaved types (not matching)

    @Test func interleavedMismatchedBrackets() {
        // { [ } ] — } doesn't match [ on top → skipped.
        // ] matches [ on top → fold from line 2 to 4.
        // { remains unmatched on stack.
        let text = "{\n[\n}\n]"
        let ranges = FoldRangeCalculator.calculate(text: text)
        #expect(ranges.count == 1)
        #expect(ranges[0].startLine == 2)
        #expect(ranges[0].endLine == 4)
        #expect(ranges[0].kind == .brackets)
    }
}
