//
//  MinimapRenderPerformanceTests.swift
//  PinePerformanceTests
//

import XCTest
import AppKit
@testable import Pine

@MainActor
final class MinimapRenderPerformanceTests: XCTestCase {

    private var highlighter: SyntaxHighlighter!

    override func setUp() {
        super.setUp()
        highlighter = SyntaxHighlighter.shared
        let grammar = Grammar(
            name: "MinimapPerfSwift",
            extensions: ["minimapperfswift"],
            rules: [
                GrammarRule(pattern: "//.*$", scope: "comment", options: ["anchorsMatchLines"]),
                GrammarRule(pattern: #""(?:[^"\\]|\\.)*""#, scope: "string"),
                GrammarRule(
                    pattern: #"\b(func|var|let|class|struct|return|if|else|for|while)\b"#,
                    scope: "keyword"
                ),
                GrammarRule(pattern: #"\b[A-Z][A-Za-z0-9_]*\b"#, scope: "type"),
                GrammarRule(pattern: #"\b\d+(\.\d+)?\b"#, scope: "number"),
            ]
        )
        highlighter.registerGrammar(grammar)
    }

    // MARK: - Helpers

    private func generateCode(lines: Int) -> String {
        PerformanceTestHelpers.generateSwiftCode(lines: lines, classPrefix: "Minimap")
    }

    /// Creates a fully configured text system with highlighted text
    /// and forced layout. Throws on failure instead of returning empty objects.
    private func createHighlightedTextSystem(
        lines: Int
    ) throws -> (NSTextView, NSTextStorage) {
        let code = generateCode(lines: lines)
        let (textView, textStorage, _) = try createTextSystem(text: code)

        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        highlighter.highlight(textStorage: textStorage, language: "minimapperfswift", font: font)

        // Force layout so enumerateLineFragments works — done before measure
        if let layoutManager = textView.layoutManager, let textContainer = textView.textContainer {
            layoutManager.ensureLayout(for: textContainer)
        }

        return (textView, textStorage)
    }

    // MARK: - Minimap Data Preparation

    /// Benchmarks the data preparation phase for minimap rendering:
    /// walking line fragments and extracting syntax color segments.
    /// This is the CPU-intensive part of MinimapView.draw().
    func testMinimapDataPrep2000Lines() throws {
        let (textView, textStorage) = try createHighlightedTextSystem(lines: 2000)

        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else {
            XCTFail("Text system not configured")
            return
        }

        let source = textView.string as NSString
        let fullRange = layoutManager.glyphRange(for: textContainer)

        measure {
            var lineData: [(y: CGFloat, segments: [(x: CGFloat, width: CGFloat)])] = []

            layoutManager.enumerateLineFragments(forGlyphRange: fullRange) { lineRect, _, _, glyphRange, _ in
                let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
                let yPos = lineRect.origin.y * 0.12

                var segments: [(x: CGFloat, width: CGFloat)] = []
                var pos = charRange.location
                let end = NSMaxRange(charRange)

                while pos < end {
                    var effectiveRange = NSRange()
                    _ = textStorage.attribute(.foregroundColor, at: pos, effectiveRange: &effectiveRange)
                    let segStart = max(pos, charRange.location)
                    let segEnd = min(NSMaxRange(effectiveRange), end)
                    let segLen = segEnd - segStart
                    if segLen > 0 {
                        let localStart = segStart - charRange.location
                        segments.append((x: CGFloat(localStart) * 1.2, width: CGFloat(segLen) * 1.2))
                    }
                    pos = segEnd
                }

                lineData.append((y: yPos, segments: segments))
            }

            // Verify we got meaningful data
            XCTAssertGreaterThan(lineData.count, 100, "Expected many line fragments")
            _ = source // Keep source alive
        }
    }

    /// Benchmarks minimap data preparation for a 5000-line file.
    func testMinimapDataPrep5000Lines() throws {
        let (textView, textStorage) = try createHighlightedTextSystem(lines: 5000)

        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else {
            XCTFail("Text system not configured")
            return
        }

        let fullRange = layoutManager.glyphRange(for: textContainer)

        measure {
            var segmentCount = 0

            layoutManager.enumerateLineFragments(forGlyphRange: fullRange) { _, _, _, glyphRange, _ in
                let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
                var pos = charRange.location
                let end = NSMaxRange(charRange)

                while pos < end {
                    var effectiveRange = NSRange()
                    _ = textStorage.attribute(.foregroundColor, at: pos, effectiveRange: &effectiveRange)
                    let segEnd = min(NSMaxRange(effectiveRange), end)
                    if segEnd - max(pos, charRange.location) > 0 {
                        segmentCount += 1
                    }
                    pos = segEnd
                }
            }

            XCTAssertGreaterThan(segmentCount, 500)
        }
    }

    /// Benchmarks minimap data preparation with diff markers overlaid.
    /// Simulates the real minimap render path: walk line fragments,
    /// extract syntax colors, and check each line against a diff map.
    func testMinimapDataPrepWithDiffMarkers() throws {
        let (textView, textStorage) = try createHighlightedTextSystem(lines: 3000)

        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else {
            XCTFail("Text system not configured")
            return
        }

        // Simulate ~120 changed lines scattered across the file
        var diffMap: [Int: GitLineDiff.Kind] = [:]
        for i in stride(from: 10, to: 3000, by: 25) {
            diffMap[i] = [.added, .modified, .deleted][i % 3]
        }

        let fullRange = layoutManager.glyphRange(for: textContainer)

        measure {
            var lineIndex = 0
            var markerCount = 0

            layoutManager.enumerateLineFragments(forGlyphRange: fullRange) { _, _, _, glyphRange, _ in
                let charRange = layoutManager.characterRange(
                    forGlyphRange: glyphRange, actualGlyphRange: nil
                )
                // Syntax color segments (same as real minimap)
                var pos = charRange.location
                let end = NSMaxRange(charRange)
                while pos < end {
                    var effectiveRange = NSRange()
                    _ = textStorage.attribute(
                        .foregroundColor, at: pos, effectiveRange: &effectiveRange
                    )
                    pos = min(NSMaxRange(effectiveRange), end)
                }

                // Diff marker lookup per line (same as real minimap)
                if diffMap[lineIndex] != nil {
                    markerCount += 1
                }
                lineIndex += 1
            }

            XCTAssertGreaterThan(lineIndex, 100, "Expected many line fragments")
            XCTAssertGreaterThan(markerCount, 10, "Expected some diff markers")
        }
    }

    /// Benchmarks the full minimap pipeline: highlight + data preparation.
    func testMinimapFullPipeline3000Lines() throws {
        let (textView, textStorage) = try createHighlightedTextSystem(lines: 3000)
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else {
            XCTFail("Text system not configured")
            return
        }

        measure {
            // Phase 1: Syntax highlighting
            highlighter.highlight(textStorage: textStorage, language: "minimapperfswift", font: font)
            layoutManager.ensureLayout(for: textContainer)

            // Phase 2: Walk line fragments (minimap data prep)
            let fullRange = layoutManager.glyphRange(for: textContainer)
            var lineCount = 0

            layoutManager.enumerateLineFragments(forGlyphRange: fullRange) { _, _, _, glyphRange, _ in
                let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
                var pos = charRange.location
                let end = NSMaxRange(charRange)
                while pos < end {
                    var effectiveRange = NSRange()
                    _ = textStorage.attribute(.foregroundColor, at: pos, effectiveRange: &effectiveRange)
                    pos = min(NSMaxRange(effectiveRange), end)
                }
                lineCount += 1
            }

            XCTAssertGreaterThan(lineCount, 100)
        }
    }
}
