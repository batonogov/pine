//
//  XCTMetricPerformanceTests.swift
//  PinePerformanceTests
//
//  Demonstrates adoption of `XCTMetric` (`XCTClockMetric`, `XCTMemoryMetric`,
//  `XCTStorageMetric`) beyond the raw `measure {}` default. These are the
//  standardized, machine-comparable metrics that complement the per-test
//  wall-clock baselines in baselines.json.
//
//  Pattern reference for migrating existing `measure {}` benchmarks: each test
//  declares its metrics explicitly via `measure(metrics:)`. The clock metric
//  is preserved (so wall-clock comparisons stay valid) and additional metrics
//  are layered on per scenario.
//

import AppKit
import XCTest
@testable import Pine

@MainActor
final class XCTMetricPerformanceTests: XCTestCase {

    // MARK: - XCTClockMetric — wall-clock time (explicit default)

    /// Same measurement as the default `measure {}`, but with the metric
    /// declared explicitly. Demonstrates the migration form that keeps
    /// existing baselines valid while making the measured dimension explicit.
    func testFoldRangeClockMetric() {
        let text = generateManyBlocks(count: 1000, linesPerBlock: 5)

        measure(metrics: [XCTClockMetric()]) {
            _ = FoldRangeCalculator.calculate(text: text)
        }
    }

    // MARK: - XCTMemoryMetric — peak allocations

    /// Highlights a large file while tracking peak memory, which `measure {}`
    /// cannot capture on its own. Memory is the dimension that matters for the
    /// huge-file path (see AGENTS.md → Performance thresholds).
    func testHighlightMemoryMetric() {
        let highlighter = SyntaxHighlighter.shared
        registerSwiftGrammar(on: highlighter)

        let code = PerformanceTestHelpers.generateSwiftCode(lines: 5000, classPrefix: "Metric")
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

        // Clock is kept so the wall-clock baseline stays meaningful; memory is added.
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            let storage = NSTextStorage(string: code)
            highlighter.highlight(textStorage: storage, language: "metricswift", font: font)
        }
    }

    // MARK: - XCTStorageMetric — disk read throughput

    /// Project search reads files from disk; `XCTStorageMetric` quantifies
    /// the I/O cost that the clock-only baselines hide. This mirrors the
    /// `ProjectSearchProvider.searchFile` path measured in the nightly suite.
    func testSearchStorageIOMetric() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PineXCTMetric-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // A single large file to exercise the disk-read path.
        let lines = (0..<5000).map { "let value\($0) = compute(\($0)) // target marker" }
        let content = lines.joined(separator: "\n")
        let file = tempDir.appendingPathComponent("large.swift")
        try content.write(to: file, atomically: true, encoding: .utf8)

        measure(metrics: [XCTClockMetric(), XCTStorageMetric()]) {
            _ = ProjectSearchProvider.searchFile(at: file, query: "target", isCaseSensitive: false)
        }
    }

    // MARK: - Helpers

    private func generateManyBlocks(count: Int, linesPerBlock: Int) -> String {
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

    private func registerSwiftGrammar(on highlighter: SyntaxHighlighter) {
        let grammar = Grammar(
            name: "MetricsSwift",
            extensions: ["metricswift"],
            rules: [
                GrammarRule(pattern: "//.*$", scope: "comment", options: ["anchorsMatchLines"]),
                GrammarRule(pattern: #""(?:[^"\\]|\\.)*""#, scope: "string"),
                GrammarRule(
                    pattern: #"\b(func|var|let|class|struct|return|if|else)\b"#,
                    scope: "keyword"
                ),
                GrammarRule(pattern: #"\b[A-Z][A-Za-z0-9_]*\b"#, scope: "type"),
                GrammarRule(pattern: #"\b\d+(\.\d+)?\b"#, scope: "number"),
            ]
        )
        highlighter.registerGrammar(grammar)
    }
}
