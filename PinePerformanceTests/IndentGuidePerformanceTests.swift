//
//  IndentGuidePerformanceTests.swift
//  PinePerformanceTests
//
//  Created by Fedor Batonogov on 25.03.2026.
//

import XCTest
@testable import Pine

final class IndentGuidePerformanceTests: XCTestCase {

    // MARK: - Helpers

    /// Generates a realistic Swift-like file with nested indentation.
    private func generateNestedCode(lines lineCount: Int) -> String {
        var lines: [String] = []
        var depth = 0
        for i in 0..<lineCount {
            if i % 10 == 0 && depth < 5 {
                let indent = String(repeating: "    ", count: depth)
                lines.append("\(indent)func method\(i)() {")
                depth += 1
            } else if i % 10 == 9 && depth > 0 {
                depth -= 1
                let indent = String(repeating: "    ", count: depth)
                lines.append("\(indent)}")
            } else if i % 7 == 0 {
                // Blank line
                lines.append("")
            } else {
                let indent = String(repeating: "    ", count: depth)
                lines.append("\(indent)let x\(i) = \(i)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Generates lines array for effectiveLevels testing.
    private func generateLines(count: Int) -> [String] {
        var lines: [String] = []
        var depth = 0
        for i in 0..<count {
            if i % 10 == 0 && depth < 5 {
                lines.append(String(repeating: "    ", count: depth) + "func f\(i)() {")
                depth += 1
            } else if i % 10 == 9 && depth > 0 {
                depth -= 1
                lines.append(String(repeating: "    ", count: depth) + "}")
            } else if i % 7 == 0 {
                lines.append("")
            } else {
                lines.append(String(repeating: "    ", count: depth) + "let x = \(i)")
            }
        }
        return lines
    }

    // MARK: - Performance tests

    func testIndentLevelDetection10KLines() {
        let code = generateNestedCode(lines: 10_000)
        let lines = code.components(separatedBy: "\n")

        measure {
            for line in lines {
                _ = IndentGuideRenderer.indentLevel(of: line, tabWidth: 4)
            }
        }
    }

    func testGuideLevelsCalculation10KLines() {
        let code = generateNestedCode(lines: 10_000)
        let lines = code.components(separatedBy: "\n")
        let columns = lines.map { IndentGuideRenderer.indentLevel(of: $0, tabWidth: 4) }

        measure {
            for col in columns {
                _ = IndentGuideRenderer.guideLevels(columns: col, indentUnitWidth: 4)
            }
        }
    }

    func testEffectiveLevelsWithBlankLines10KLines() {
        let lines = generateLines(count: 10_000)

        measure {
            for i in 0..<lines.count {
                _ = IndentGuideRenderer.effectiveLevels(
                    forLineAt: i,
                    lines: lines,
                    tabWidth: 4,
                    indentUnitWidth: 4
                )
            }
        }
    }

    func testSegmentCollection1KVisibleLines() {
        // Simulates collecting guide segments for ~1000 visible lines
        // (typical viewport is 40-80 lines, but test with more for stress)
        let lines = generateLines(count: 1_000)

        measure {
            var segments: [IndentGuideRenderer.GuideSegment] = []
            segments.reserveCapacity(lines.count * 3)
            let charWidth: CGFloat = 7.8
            let textOriginX: CGFloat = 44.0

            for (i, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                let levels: Int
                if trimmed.isEmpty {
                    levels = IndentGuideRenderer.effectiveLevels(
                        forLineAt: i, lines: lines, tabWidth: 4, indentUnitWidth: 4
                    )
                } else {
                    let cols = IndentGuideRenderer.indentLevel(of: line, tabWidth: 4)
                    levels = IndentGuideRenderer.guideLevels(columns: cols, indentUnitWidth: 4)
                }
                guard levels > 0 else { continue }
                let y = CGFloat(i) * 18.0
                for level in 1...levels {
                    let x = textOriginX + CGFloat(level * 4) * charWidth
                    segments.append(.init(x: x, y: y, height: 18.0))
                }
            }
        }
    }
}
