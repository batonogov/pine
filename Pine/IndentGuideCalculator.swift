//
//  IndentGuideCalculator.swift
//  Pine
//
//  Created by Claude on 21.03.2026.
//

import CoreGraphics

/// Pure functions for computing indent guide positions.
///
/// Used by `GutterTextView` to draw subtle vertical lines at each indentation
/// level, helping visualize code structure and nesting depth.
enum IndentGuideCalculator {

    /// Number of columns used for tab indentation when computing guide positions.
    static let tabVisualWidth = 4

    /// Returns the number of complete indent units at the start of a line.
    ///
    /// Returns 0 for:
    /// - Empty lines
    /// - Lines that contain only whitespace (no visible content to guide toward)
    ///
    /// - Parameters:
    ///   - line: The line content (may include a trailing newline).
    ///   - style: Indentation style detected from the file.
    static func indentLevel(of line: some StringProtocol, style: IndentationStyle) -> Int {
        // Skip whitespace-only lines — no content to draw a guide toward
        guard line.contains(where: { !$0.isWhitespace }) else { return 0 }
        switch style {
        case .tabs:
            return line.prefix(while: { $0 == "\t" }).count
        case .spaces(let width):
            guard width > 0 else { return 0 }
            let spaceCount = line.prefix(while: { $0 == " " }).count
            return spaceCount / width
        }
    }

    /// Returns the x offset (in points) from the start of the text content area
    /// for a guide at the given 1-based indent level.
    ///
    /// - Parameters:
    ///   - level: The 1-based guide level (1 = first indent stop, 2 = second, …).
    ///   - style: The indentation style.
    ///   - charWidth: The advance width of a single glyph in the monospace font.
    static func guideXOffset(level: Int, style: IndentationStyle, charWidth: CGFloat) -> CGFloat {
        let columnsPerLevel: Int
        switch style {
        case .tabs:
            columnsPerLevel = tabVisualWidth
        case .spaces(let width):
            columnsPerLevel = max(width, 1)
        }
        return CGFloat(level * columnsPerLevel) * charWidth
    }
}
