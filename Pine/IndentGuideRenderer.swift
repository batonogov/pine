//
//  IndentGuideRenderer.swift
//  Pine
//
//  Created by Pine on 27.03.2026.
//

import AppKit

// MARK: - Indent Guide Data Model

/// Represents a single vertical indent guide to be drawn.
struct IndentGuide: Equatable {
    /// The indentation level (1-based). Level 1 is the first indent column.
    let level: Int
    /// The x-coordinate where the guide should be drawn (in text container coordinates).
    let xPosition: CGFloat
}

// MARK: - Indent Guide Calculator (Pure Logic, Testable)

/// Calculates indent guide positions for a given line of text.
/// Handles tabs, spaces, and mixed indentation correctly.
enum IndentGuideCalculator {

    /// Computes the indentation level of a line based on its leading whitespace.
    ///
    /// For tab-based indentation, each tab counts as one indent level.
    /// For space-based indentation, every `indentWidth` spaces count as one indent level.
    /// Mixed indentation: tabs first (each = 1 level), then remaining spaces
    /// contribute fractional levels (rounded down).
    ///
    /// - Parameters:
    ///   - line: The text of the line.
    ///   - indentWidth: Number of spaces per indent level (used for space-based indentation).
    /// - Returns: The number of indent levels for this line.
    static func indentLevel(of line: String, indentWidth: Int) -> Int {
        guard indentWidth > 0 else { return 0 }

        var tabs = 0
        var spaces = 0

        for char in line {
            switch char {
            case "\t":
                tabs += 1
            case " ":
                spaces += 1
            default:
                break
            }
            if char != "\t" && char != " " { break }
        }

        // Each tab = 1 indent level, remaining spaces contribute based on indentWidth
        return tabs + spaces / indentWidth
    }

    /// Computes the x-positions of indent guides for a given indentation level.
    ///
    /// For tab-based files, each guide is placed at the tab stop position.
    /// For space-based files, each guide is placed at `level * indentWidth * charWidth`.
    ///
    /// All x-positions are pixel-snapped to `floor(x) + 0.5` so that 1pt-wide
    /// stroke lines land on exact pixel boundaries and render crisp on both
    /// Retina and non-Retina displays.
    ///
    /// - Parameters:
    ///   - level: Number of indent levels.
    ///   - charWidth: Width of a single character in the current monospaced font.
    ///   - tabStopWidth: Width of a tab stop in points (from NSTextView paragraph style).
    ///   - usesTabs: Whether the file uses tab-based indentation.
    ///   - indentWidth: Number of spaces per indent level (for space-based indentation).
    /// - Returns: Array of `IndentGuide` values, one per level.
    static func guides(
        forLevel level: Int,
        charWidth: CGFloat,
        tabStopWidth: CGFloat,
        usesTabs: Bool,
        indentWidth: Int
    ) -> [IndentGuide] {
        guard level > 0, charWidth > 0 else { return [] }

        return (1...level).map { lvl in
            let rawX: CGFloat
            if usesTabs {
                // Tab-based: position at the tab stop boundary
                rawX = CGFloat(lvl) * tabStopWidth
            } else {
                // Space-based: position at indentWidth * charWidth per level
                rawX = CGFloat(lvl * indentWidth) * charWidth
            }
            // Snap to pixel boundary: floor(x) + 0.5 ensures the 1pt-wide
            // stroke line fills exactly one column of pixels.
            let snappedX = floor(rawX) + 0.5
            return IndentGuide(level: lvl, xPosition: snappedX)
        }
    }

    /// Determines the effective indent level for blank/empty lines
    /// by looking at surrounding non-blank lines.
    ///
    /// Blank lines inherit the minimum indent of the nearest
    /// non-blank lines above and below them, so guides continue
    /// through empty lines.
    ///
    /// - Parameters:
    ///   - lineIndex: The 0-based index of the blank line.
    ///   - lines: All lines in the document.
    ///   - indentWidth: Number of spaces per indent level.
    /// - Returns: The inherited indent level for the blank line.
    static func inheritedIndentLevel(
        forBlankLineAt lineIndex: Int,
        in lines: [String],
        indentWidth: Int
    ) -> Int {
        guard indentWidth > 0 else { return 0 }

        // Search upward for nearest non-blank line
        var above = 0
        for i in stride(from: lineIndex - 1, through: 0, by: -1) {
            let trimmed = lines[i].trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                above = indentLevel(of: lines[i], indentWidth: indentWidth)
                break
            }
        }

        // Search downward for nearest non-blank line
        var below = 0
        for i in (lineIndex + 1)..<lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                below = indentLevel(of: lines[i], indentWidth: indentWidth)
                break
            }
        }

        return min(above, below)
    }
}

// MARK: - Indent Guide Renderer (Drawing)

/// Draws vertical indent guide lines in the editor.
enum IndentGuideRenderer {

    /// The color used for indent guide lines.
    static let guideColor = NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor.white.withAlphaComponent(0.08)
        } else {
            return NSColor.black.withAlphaComponent(0.08)
        }
    }

    /// Width of the indent guide lines.
    static let lineWidth: CGFloat = 1.0

    /// Draws indent guides for all visible lines in the text view.
    ///
    /// Instead of pre-computing x-positions via character width arithmetic,
    /// this method queries NSLayoutManager for the **real** glyph position
    /// of each indent column. This guarantees that the guide line aligns
    /// exactly with the character the layout engine actually placed there.
    ///
    /// - Parameters:
    ///   - textView: The GutterTextView to draw in.
    ///   - rect: The dirty rectangle to draw in.
    ///   - indentStyle: The detected indentation style of the file.
    static func draw(
        in textView: NSTextView,
        dirtyRect rect: NSRect,
        indentStyle: IndentationStyle
    ) {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }

        let content = textView.string
        guard !content.isEmpty else { return }

        let usesTabs: Bool
        let indentWidth: Int
        switch indentStyle {
        case .tabs:
            usesTabs = true
            indentWidth = 4
        case .spaces(let width):
            usesTabs = false
            indentWidth = width
        }

        let origin = textView.textContainerOrigin
        let nsContent = content as NSString
        let lines = content.components(separatedBy: "\n")

        // Find visible glyph range
        let visibleRect = textView.visibleRect
        let containerVisibleRect = NSRect(
            x: visibleRect.origin.x - origin.x,
            y: visibleRect.origin.y - origin.y,
            width: visibleRect.width,
            height: visibleRect.height
        )
        let visibleGlyphRange = layoutManager.glyphRange(
            forBoundingRect: containerVisibleRect,
            in: textContainer
        )
        let visibleCharRange = layoutManager.characterRange(
            forGlyphRange: visibleGlyphRange, actualGlyphRange: nil
        )

        // Find which lines are visible
        let firstVisibleLine = nsContent.lineRange(
            for: NSRange(location: visibleCharRange.location, length: 0)
        )
        var lineStart = firstVisibleLine.location
        var lineNumber = nsContent.substring(to: lineStart)
            .components(separatedBy: "\n").count - 1

        guideColor.setStroke()

        let path = NSBezierPath()
        path.lineWidth = lineWidth

        while lineStart < nsContent.length && lineStart <= NSMaxRange(visibleCharRange) {
            guard lineNumber < lines.count else { break }

            let line = lines[lineNumber]
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            let level: Int
            if trimmed.isEmpty {
                level = IndentGuideCalculator.inheritedIndentLevel(
                    forBlankLineAt: lineNumber, in: lines, indentWidth: indentWidth
                )
            } else {
                level = IndentGuideCalculator.indentLevel(of: line, indentWidth: indentWidth)
            }

            if level > 0 {
                let lineRange = nsContent.lineRange(for: NSRange(location: lineStart, length: 0))
                let lineGlyphRange = layoutManager.glyphRange(
                    forCharacterRange: lineRange, actualCharacterRange: nil
                )

                if lineGlyphRange.location != NSNotFound && lineGlyphRange.length > 0 {
                    let lineFragmentRect = layoutManager.lineFragmentRect(
                        forGlyphAt: lineGlyphRange.location, effectiveRange: nil
                    )
                    let yTop = lineFragmentRect.origin.y + origin.y
                    let height = lineFragmentRect.height

                    for lvl in 1...level {
                        // Character index of the indent column for this level
                        let charIndex = lineStart + (usesTabs ? lvl : lvl * indentWidth)

                        // Ensure we don't read past the end of this line
                        guard charIndex < NSMaxRange(lineRange) else { continue }

                        let glyphIndex = layoutManager.glyphIndexForCharacter(at: charIndex)
                        let location = layoutManager.location(forGlyphAt: glyphIndex)
                        let x = location.x + origin.x

                        path.move(to: NSPoint(x: x, y: yTop))
                        path.line(to: NSPoint(x: x, y: yTop + height))
                    }
                }
            }

            // Advance to the next line
            let lineRange = nsContent.lineRange(for: NSRange(location: lineStart, length: 0))
            lineStart = NSMaxRange(lineRange)
            lineNumber += 1
        }

        path.stroke()
    }
}
