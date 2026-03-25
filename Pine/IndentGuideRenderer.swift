//
//  IndentGuideRenderer.swift
//  Pine
//
//  Created by Fedor Batonogov on 25.03.2026.
//

import AppKit

/// Calculates indent guide positions and draws vertical indent guide lines.
///
/// Indent guides are thin vertical lines at each indentation level, helping
/// visualize code structure. The renderer works with visible lines only for
/// performance and uses batched CGContext drawing to minimize allocations.
enum IndentGuideRenderer {

    /// Dynamic guide color that adapts to Light/Dark mode.
    static let guideColor = NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor.white.withAlphaComponent(0.12)
        } else {
            return NSColor.black.withAlphaComponent(0.10)
        }
    }

    /// The width of each indent guide line in points.
    static let guideLineWidth: CGFloat = 1

    // MARK: - Indent level detection

    /// Returns the number of leading whitespace columns in a line.
    /// Tabs are expanded to `tabWidth` columns.
    static func indentLevel(of line: String, tabWidth: Int) -> Int {
        var columns = 0
        for char in line {
            if char == " " {
                columns += 1
            } else if char == "\t" {
                columns += tabWidth
            } else {
                break
            }
        }
        return columns
    }

    /// Returns the number of indent guide levels for a given column count and indent unit width.
    /// For example, 8 columns with indent unit 4 gives 2 levels.
    static func guideLevels(columns: Int, indentUnitWidth: Int) -> Int {
        guard indentUnitWidth > 0 else { return 0 }
        return columns / indentUnitWidth
    }

    /// Resolves the effective indent level for a line, handling blank lines
    /// by looking at surrounding non-blank lines (continuation through blanks).
    ///
    /// For blank lines, the effective level is `min(previous non-blank, next non-blank)`.
    /// This prevents indent guides from being interrupted by empty lines.
    static func effectiveLevels(
        forLineAt index: Int,
        lines: [String],
        tabWidth: Int,
        indentUnitWidth: Int
    ) -> Int {
        guard indentUnitWidth > 0, index >= 0, index < lines.count else { return 0 }

        let line = lines[index]
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

        if !trimmed.isEmpty {
            let columns = indentLevel(of: line, tabWidth: tabWidth)
            return guideLevels(columns: columns, indentUnitWidth: indentUnitWidth)
        }

        // Blank line: look at surrounding non-blank lines
        var prevLevels = 0
        for i in stride(from: index - 1, through: 0, by: -1) {
            let prev = lines[i].trimmingCharacters(in: .whitespacesAndNewlines)
            if !prev.isEmpty {
                let cols = indentLevel(of: lines[i], tabWidth: tabWidth)
                prevLevels = guideLevels(columns: cols, indentUnitWidth: indentUnitWidth)
                break
            }
        }

        var nextLevels = 0
        for i in (index + 1)..<lines.count {
            let next = lines[i].trimmingCharacters(in: .whitespacesAndNewlines)
            if !next.isEmpty {
                let cols = indentLevel(of: lines[i], tabWidth: tabWidth)
                nextLevels = guideLevels(columns: cols, indentUnitWidth: indentUnitWidth)
                break
            }
        }

        return min(prevLevels, nextLevels)
    }

    // MARK: - Batched drawing

    /// A single guide segment to be drawn.
    struct GuideSegment {
        let x: CGFloat
        let y: CGFloat
        let height: CGFloat
    }

    /// Draws all indent guide segments in a single batched CGContext fill.
    /// Much faster than individual NSBezierPath stroke() calls.
    static func drawBatched(_ segments: [GuideSegment]) {
        guard !segments.isEmpty,
              let context = NSGraphicsContext.current?.cgContext else { return }

        guideColor.setFill()

        for segment in segments {
            let rect = CGRect(
                x: segment.x - guideLineWidth / 2,
                y: segment.y,
                width: guideLineWidth,
                height: segment.height
            )
            context.fill(rect)
        }
    }

    /// Detects indent unit width from an `IndentationStyle`.
    static func indentUnitWidth(from style: IndentationStyle) -> Int {
        switch style {
        case .spaces(let count): count
        case .tabs: 1  // tabs count as 1 tab-stop per indent level
        }
    }

    /// Detects the effective tab width used for rendering.
    /// For spaces, this equals the indent unit width.
    /// For tabs, this uses the provided rendering tab width.
    static func effectiveTabWidth(from style: IndentationStyle, renderTabWidth: Int = 4) -> Int {
        switch style {
        case .spaces(let count): count
        case .tabs: renderTabWidth
        }
    }
}
