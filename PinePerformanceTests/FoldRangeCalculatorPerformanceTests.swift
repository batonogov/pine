//
//  FoldRangeCalculatorPerformanceTests.swift
//  PinePerformanceTests
//

import XCTest
@testable import Pine

final class FoldRangeCalculatorPerformanceTests: XCTestCase {

    // MARK: - Helpers

    /// Generates deeply nested braces: `{ { { ... } } }`
    private func generateDeeplyNestedBraces(depth: Int, linesPerLevel: Int = 2) -> String {
        var lines: [String] = []
        for i in 0..<depth {
            let indent = String(repeating: "    ", count: i)
            lines.append("\(indent)func level\(i)() {")
            for j in 0..<linesPerLevel {
                lines.append("\(indent)    let x\(j) = \(j)")
            }
        }
        for i in stride(from: depth - 1, through: 0, by: -1) {
            let indent = String(repeating: "    ", count: i)
            lines.append("\(indent)}")
        }
        return lines.joined(separator: "\n")
    }

    /// Generates a flat file with many independent brace blocks.
    private func generateManyBlocks(count: Int, linesPerBlock: Int = 3) -> String {
        var lines: [String] = []
        for i in 0..<count {
            lines.append("func block\(i)() {")
            for j in 0..<linesPerBlock {
                lines.append("    let x\(j) = \(j)")
            }
            lines.append("}")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// Generates a file with mixed bracket types: {}, [], ().
    private func generateMixedBrackets(count: Int) -> String {
        var lines: [String] = []
        for i in 0..<count {
            lines.append("let arr\(i) = [")
            lines.append("    (key: \"a\", value: {")
            lines.append("        return \(i)")
            lines.append("    }),")
            lines.append("    (key: \"b\", value: {")
            lines.append("        return \(i + 1)")
            lines.append("    })")
            lines.append("]")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Tests

    func testDeeplyNestedBraces() {
        let text = generateDeeplyNestedBraces(depth: 100)
        measure {
            _ = FoldRangeCalculator.calculate(text: text)
        }
    }

    func testManyBlocks() {
        let text = generateManyBlocks(count: 500)
        measure {
            _ = FoldRangeCalculator.calculate(text: text)
        }
    }

    func testMixedBrackets() {
        let text = generateMixedBrackets(count: 200)
        measure {
            _ = FoldRangeCalculator.calculate(text: text)
        }
    }

    func testLargeFileWithSkipRanges() {
        let text = generateManyBlocks(count: 300)
        // Simulate comment/string ranges to skip
        let skipRanges = stride(from: 0, to: text.count, by: 100).map {
            NSRange(location: $0, length: min(20, text.count - $0))
        }
        measure {
            _ = FoldRangeCalculator.calculate(text: text, skipRanges: skipRanges)
        }
    }

    func testVeryLargeFile() {
        let text = generateManyBlocks(count: 1000, linesPerBlock: 5)
        measure {
            _ = FoldRangeCalculator.calculate(text: text)
        }
    }
}
