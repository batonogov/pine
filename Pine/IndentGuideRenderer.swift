//
//  IndentGuideRenderer.swift
//  Pine
//
//  Created by Claude on 25.03.2026.
//

import AppKit

/// Calculates indent guide positions and draws vertical indent guide lines.
///
/// Indent guides are thin vertical lines at each indentation level, helping
/// visualize code structure. The renderer works with visible lines only for
/// performance and detects the indent unit (tabs or spaces) from the text.
enum IndentGuideRenderer {

    /// The color used for indent guide lines.
    static let guideColor = NSColor.separatorColor.withAlphaComponent(0.3)

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

    /// Computes x-positions for indent guide lines given the indent unit width and character width.
    /// Returns positions for levels 1, 2, 3, ... up to `maxLevel`.
    static func guideXPositions(
        maxLevel: Int,
        indentUnitWidth: Int,
        charWidth: CGFloat,
        textOriginX: CGFloat
    ) -> [CGFloat] {
        guard maxLevel > 0, indentUnitWidth > 0 else { return [] }
        return (1...maxLevel).map { level in
            textOriginX + CGFloat(level * indentUnitWidth) * charWidth
        }
    }

    // MARK: - Drawing

    /// Parameters for drawing indent guides on a single line.
    struct DrawContext {
        let levels: Int
        let indentUnitWidth: Int
        let charWidth: CGFloat
        let textOriginX: CGFloat
        let lineY: CGFloat
        let lineHeight: CGFloat
    }

    /// Draws indent guide lines for a single visible line.
    static func drawGuides(_ context: DrawContext) {
        guard context.levels > 0, context.indentUnitWidth > 0 else { return }

        guideColor.setStroke()

        for level in 1...context.levels {
            let x = context.textOriginX + CGFloat(level * context.indentUnitWidth) * context.charWidth
            let path = NSBezierPath()
            path.move(to: NSPoint(x: x, y: context.lineY))
            path.line(to: NSPoint(x: x, y: context.lineY + context.lineHeight))
            path.lineWidth = guideLineWidth
            path.stroke()
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
    /// For tabs, this is the standard tab width (typically 4).
    static func effectiveTabWidth(from style: IndentationStyle) -> Int {
        switch style {
        case .spaces(let count): count
        case .tabs: 4
        }
    }
}
