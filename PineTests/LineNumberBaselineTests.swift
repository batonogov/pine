//
//  LineNumberBaselineTests.swift
//  PineTests
//

import Testing
import AppKit
@testable import Pine

/// Tests that line number baseline aligns with editor text baseline (issue #250).
struct LineNumberBaselineTests {

    private func makeView() -> LineNumberView {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 500))
        return LineNumberView(textView: textView)
    }

    /// When editor font is larger than gutter font, baselineOffset should compensate.
    @Test func baselineOffsetCompensatesForSmallerGutterFont() {
        let editorFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let gutterFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

        let view = makeView()
        view.gutterFont = gutterFont
        view.editorFont = editorFont

        let expectedOffset = editorFont.ascender - gutterFont.ascender
        #expect(expectedOffset > 0, "Editor font ascender should be larger")
        #expect(view.baselineOffset == expectedOffset)
    }

    /// When editor and gutter fonts have the same size, baselineOffset should be 0.
    @Test func baselineOffsetZeroWhenFontsMatch() {
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

        let view = makeView()
        view.gutterFont = font
        view.editorFont = font

        #expect(view.baselineOffset == 0)
    }

    /// At minimum font size (8pt), both fonts are equal — offset should be 0.
    @Test func baselineOffsetZeroAtMinimumFontSize() {
        let minSize = FontSizeSettings.minSize
        let editorFont = NSFont.monospacedSystemFont(ofSize: minSize, weight: .regular)
        let gutterFont = NSFont.monospacedSystemFont(
            ofSize: max(minSize - 2, minSize), weight: .regular
        )

        let view = makeView()
        view.editorFont = editorFont
        view.gutterFont = gutterFont

        #expect(view.baselineOffset == 0, "At min size both fonts are equal, offset should be 0")
    }

    /// At maximum font size (32pt), offset should still be correct.
    @Test func baselineOffsetCorrectAtMaximumFontSize() {
        let maxSize = FontSizeSettings.maxSize
        let editorFont = NSFont.monospacedSystemFont(ofSize: maxSize, weight: .regular)
        let gutterFont = NSFont.monospacedSystemFont(ofSize: maxSize - 2, weight: .regular)

        let view = makeView()
        view.editorFont = editorFont
        view.gutterFont = gutterFont

        let expected = editorFont.ascender - gutterFont.ascender
        #expect(view.baselineOffset == expected)
        #expect(view.baselineOffset > 0)
    }

    /// When gutter font is clamped to minSize (e.g. fontSize=9, gutterFont=8 not 7).
    @Test func baselineOffsetWithClampedGutterFont() {
        let minSize = FontSizeSettings.minSize
        let editorSize: CGFloat = minSize + 1 // 9pt
        let editorFont = NSFont.monospacedSystemFont(ofSize: editorSize, weight: .regular)
        let gutterFont = NSFont.monospacedSystemFont(
            ofSize: max(editorSize - 2, minSize), weight: .regular
        )

        let view = makeView()
        view.editorFont = editorFont
        view.gutterFont = gutterFont

        // gutterFont clamped to 8pt (not 7pt), so difference is 9-8=1pt
        #expect(gutterFont.pointSize == minSize)
        let expected = editorFont.ascender - gutterFont.ascender
        #expect(view.baselineOffset == expected)
        #expect(view.baselineOffset > 0)
    }

    /// baselineOffset is never negative in normal usage (editor >= gutter).
    @Test func baselineOffsetNonNegativeForAllValidSizes() {
        let view = makeView()

        for size in stride(from: FontSizeSettings.minSize, through: FontSizeSettings.maxSize, by: 1) {
            let editorFont = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
            let gutterFont = NSFont.monospacedSystemFont(
                ofSize: max(size - 2, FontSizeSettings.minSize), weight: .regular
            )
            view.editorFont = editorFont
            view.gutterFont = gutterFont

            #expect(view.baselineOffset >= 0, "Offset should be non-negative at size \(size)")
        }
    }

    /// baselineOffset updates when fonts change and reflects ascender difference.
    @Test func baselineOffsetUpdatesWithFonts() {
        let view = makeView()

        let editor1 = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let gutter1 = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        view.editorFont = editor1
        view.gutterFont = gutter1
        let offset1 = view.baselineOffset

        // Change to different size — offset should match new ascender difference
        let editor2 = NSFont.monospacedSystemFont(ofSize: 20, weight: .regular)
        let gutter2 = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        view.editorFont = editor2
        view.gutterFont = gutter2
        let offset2 = view.baselineOffset

        let expected2 = editor2.ascender - gutter2.ascender
        #expect(offset2 == expected2)
        #expect(offset1 != offset2, "Offset should change when fonts change")
    }

    // MARK: - Regression: cursor positioning offset (issue #250)

    /// Non-monospaced system font — baselineOffset should still be non-negative.
    @Test func baselineOffsetWithSystemFont() {
        let view = makeView()
        let editorFont = NSFont.systemFont(ofSize: 14)
        let gutterFont = NSFont.systemFont(ofSize: 12)
        view.editorFont = editorFont
        view.gutterFont = gutterFont

        let expected = editorFont.ascender - gutterFont.ascender
        #expect(view.baselineOffset == expected)
        #expect(view.baselineOffset >= 0,
                "Non-monospaced fonts must still produce non-negative offset")
    }

    /// Bold weight should not break baseline alignment.
    @Test func baselineOffsetWithBoldFont() {
        let view = makeView()
        let editorFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .bold)
        let gutterFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        view.editorFont = editorFont
        view.gutterFont = gutterFont

        #expect(view.baselineOffset >= 0,
                "Bold editor font must not produce negative offset")
    }

    /// Same font assigned to both editor and gutter — offset must be exactly 0.
    @Test func baselineOffsetIdenticalFontInstances() {
        let view = makeView()
        let font = NSFont.monospacedSystemFont(ofSize: 16, weight: .regular)
        view.editorFont = font
        view.gutterFont = font

        #expect(view.baselineOffset == 0,
                "Identical font instances must yield zero offset")
    }

    /// Gutter width formula: digits * charWidth + 20, minimum 2 digits.
    /// Mirrors the calculation in LineNumberView.draw() (LineNumberGutter.swift:389-401).
    @Test func gutterWidthFormula_matchesExpected() {
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let charWidth = "0".size(withAttributes: [.font: font]).width

        // 2-digit minimum (files with < 100 lines)
        let width2 = CGFloat(max(String(10).count, 2)) * charWidth + 20
        // 4-digit file (e.g. 1000 lines)
        let width4 = CGFloat(max(String(1000).count, 2)) * charWidth + 20
        // 5-digit file (e.g. 10000 lines)
        let width5 = CGFloat(max(String(10000).count, 2)) * charWidth + 20

        #expect(width4 > width2, "4-digit gutter must be wider than 2-digit")
        #expect(width5 > width4, "5-digit gutter must be wider than 4-digit")
        // Verify the formula: digits * charWidth + 20
        #expect(width4 == 4 * charWidth + 20)
        #expect(width5 == 5 * charWidth + 20)
    }

    /// baselineOffset with very large font size difference (e.g. 32pt editor, 8pt gutter).
    @Test func baselineOffsetLargeSizeDifference() {
        let view = makeView()
        let editorFont = NSFont.monospacedSystemFont(ofSize: 32, weight: .regular)
        let gutterFont = NSFont.monospacedSystemFont(ofSize: 8, weight: .regular)
        view.editorFont = editorFont
        view.gutterFont = gutterFont

        let expected = editorFont.ascender - gutterFont.ascender
        #expect(view.baselineOffset == expected)
        #expect(view.baselineOffset > 0,
                "Large size difference must produce positive offset")
    }

    /// Fractional font sizes should produce valid offsets.
    @Test func baselineOffsetFractionalFontSize() {
        let view = makeView()
        let editorFont = NSFont.monospacedSystemFont(ofSize: 13.5, weight: .regular)
        let gutterFont = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        view.editorFont = editorFont
        view.gutterFont = gutterFont

        #expect(view.baselineOffset >= 0)
        #expect(view.baselineOffset.isFinite, "Offset must be finite for fractional sizes")
        #expect(!view.baselineOffset.isNaN, "Offset must not be NaN")
    }
}
