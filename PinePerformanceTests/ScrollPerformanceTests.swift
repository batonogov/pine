//
//  ScrollPerformanceTests.swift
//  PinePerformanceTests
//

import XCTest
import AppKit
@testable import Pine

@MainActor
final class ScrollPerformanceTests: XCTestCase {

    private var highlighter: SyntaxHighlighter!

    override func setUp() {
        super.setUp()
        highlighter = SyntaxHighlighter.shared
        let grammar = Grammar(
            name: "ScrollPerfSwift",
            extensions: ["scrollperfswift"],
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
        PerformanceTestHelpers.generateSwiftCode(lines: lines, classPrefix: "Scroll")
    }

    // MARK: - Scroll Benchmarks

    /// Benchmarks scrolling through a 100K-line file by forcing layout
    /// for successive viewport-sized ranges (simulating smooth scroll).
    func testScrollThrough100kLines() throws {
        let code = generateCode(lines: 100_000)
        let (textView, _, layoutManager) = try createTextSystem(text: code)

        guard let textContainer = textView.textContainer else {
            XCTFail("Text container not configured")
            return
        }

        // Force initial layout before measure — so we benchmark scrolling, not first layout
        layoutManager.ensureLayout(for: textContainer)

        let totalGlyphRange = layoutManager.glyphRange(for: textContainer)
        let totalGlyphs = totalGlyphRange.length

        // Simulate scrolling in chunks (~50 lines worth of glyphs per viewport)
        let viewportGlyphSize = 2500
        let scrollStep = viewportGlyphSize

        measure {
            var offset = 0
            while offset < totalGlyphs {
                let length = min(viewportGlyphSize, totalGlyphs - offset)
                let range = NSRange(location: offset, length: length)
                layoutManager.ensureLayout(forGlyphRange: range)

                // Simulate reading visible line fragments (what the editor does on scroll)
                layoutManager.enumerateLineFragments(forGlyphRange: range) { _, _, _, _, _ in }

                offset += scrollStep
            }
        }
    }

    /// Benchmarks viewport layout for a 100K-line file at random positions
    /// (simulates jump-scrolling via scrollbar or Go to Line).
    func testViewportLayoutAtRandomPositions100kLines() throws {
        let code = generateCode(lines: 100_000)
        let (textView, _, layoutManager) = try createTextSystem(text: code)

        guard let textContainer = textView.textContainer else {
            XCTFail("Text container not configured")
            return
        }

        // Force initial layout before measure — so we benchmark viewport access, not first layout
        layoutManager.ensureLayout(for: textContainer)

        let totalGlyphs = layoutManager.glyphRange(for: textContainer).length
        let viewportSize = 2500

        // Pre-generate deterministic "random" positions
        let positions = stride(from: 0, to: totalGlyphs, by: totalGlyphs / 20).map { $0 }

        measure {
            for pos in positions {
                let length = min(viewportSize, totalGlyphs - pos)
                let range = NSRange(location: pos, length: length)
                layoutManager.ensureLayout(forGlyphRange: range)

                // Extract line fragment info (what CodeEditorView does on scroll)
                layoutManager.enumerateLineFragments(forGlyphRange: range) { _, _, _, glyphRange, _ in
                    _ = layoutManager.characterRange(
                        forGlyphRange: glyphRange, actualGlyphRange: nil
                    )
                }
            }
        }
    }

    /// Benchmarks scroll with syntax highlighting applied (closer to real usage).
    func testScrollWithHighlighting50kLines() throws {
        let code = generateCode(lines: 50_000)
        let (textView, textStorage, layoutManager) = try createTextSystem(text: code)

        guard let textContainer = textView.textContainer else {
            XCTFail("Text container not configured")
            return
        }

        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        highlighter.highlight(textStorage: textStorage, language: "scrollperfswift", font: font)
        // Force initial layout before measure — so we benchmark scrolling, not first layout
        layoutManager.ensureLayout(for: textContainer)

        let totalGlyphs = layoutManager.glyphRange(for: textContainer).length
        let viewportSize = 2500
        let scrollStep = viewportSize

        measure {
            var offset = 0
            while offset < totalGlyphs {
                let length = min(viewportSize, totalGlyphs - offset)
                let range = NSRange(location: offset, length: length)
                layoutManager.ensureLayout(forGlyphRange: range)

                // Read color attributes per line fragment (minimap/gutter path)
                layoutManager.enumerateLineFragments(forGlyphRange: range) { _, _, _, glyphRange, _ in
                    let charRange = layoutManager.characterRange(
                        forGlyphRange: glyphRange, actualGlyphRange: nil
                    )
                    var pos = charRange.location
                    let end = NSMaxRange(charRange)
                    while pos < end {
                        var effectiveRange = NSRange()
                        _ = textStorage.attribute(
                            .foregroundColor, at: pos, effectiveRange: &effectiveRange
                        )
                        pos = min(NSMaxRange(effectiveRange), end)
                    }
                }

                offset += scrollStep
            }
        }
    }
}
