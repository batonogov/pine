//
//  MouseScrollForwarder.swift
//  Pine
//
//  Encodes scroll wheel events as VT100 mouse button events
//  so TUI apps (k9s, htop, lazygit) receive scroll input
//  when mouse reporting is enabled.
//

import AppKit

/// Pure utility for encoding scroll wheel events as terminal mouse button events.
/// Extracted from TerminalContainerView for testability.
enum MouseScrollForwarder {

    /// Grid position in terminal coordinates.
    struct GridPosition {
        let col: Int
        let row: Int
    }

    /// Encodes a scroll wheel direction and modifiers into VT100 mouse button flags.
    ///
    /// In the VT100 mouse protocol:
    /// - Button 4 (scroll up) = 64
    /// - Button 5 (scroll down) = 65
    /// - Shift adds 4, Meta/Option adds 8, Control adds 16
    ///
    /// - Parameters:
    ///   - deltaY: Positive = scroll up, negative = scroll down.
    ///   - shift: Whether the Shift key is pressed.
    ///   - option: Whether the Option/Meta key is pressed.
    ///   - control: Whether the Control key is pressed.
    /// - Returns: Encoded button flags suitable for `Terminal.sendEvent`.
    static func encodeScrollButton(
        deltaY: CGFloat,
        shift: Bool,
        option: Bool,
        control: Bool
    ) -> Int {
        var value = deltaY > 0 ? 64 : 65
        if shift { value |= 4 }
        if option { value |= 8 }
        if control { value |= 16 }
        return value
    }

    /// Converts a point in view coordinates to terminal grid coordinates.
    ///
    /// - Parameters:
    ///   - point: The mouse location in the view's coordinate system.
    ///   - viewBounds: The view's bounds rectangle.
    ///   - cols: Number of terminal columns.
    ///   - rows: Number of terminal rows.
    ///   - isFlipped: Whether the view uses a flipped coordinate system (y=0 at top).
    /// - Returns: Clamped grid position.
    static func gridPosition(
        point: CGPoint,
        viewBounds: NSRect,
        cols: Int,
        rows: Int,
        isFlipped: Bool
    ) -> GridPosition {
        guard viewBounds.width > 0, viewBounds.height > 0, cols > 0, rows > 0 else {
            return GridPosition(col: 0, row: 0)
        }

        let clampedX = min(max(point.x, 0), viewBounds.width - 1)
        let clampedY = min(max(point.y, 0), viewBounds.height - 1)

        let cellWidth = viewBounds.width / CGFloat(cols)
        let cellHeight = viewBounds.height / CGFloat(rows)

        let col = min(Int(clampedX / cellWidth), cols - 1)

        let row: Int
        if isFlipped {
            row = min(Int(clampedY / cellHeight), rows - 1)
        } else {
            // Non-flipped: y=0 at bottom, so invert
            let invertedY = viewBounds.height - 1 - clampedY
            row = min(Int(invertedY / cellHeight), rows - 1)
        }

        return GridPosition(col: col, row: row)
    }

    /// Determines the arrow key escape sequence for alternate screen scroll.
    ///
    /// When a TUI app is on the alternate screen but has mouse reporting off,
    /// scroll events are converted to arrow key sequences (like Ghostty/iTerm2).
    ///
    /// - Parameter deltaY: Positive = scroll up, negative = scroll down.
    /// - Returns: `ESC O A` for scroll up, `ESC O B` for scroll down.
    static func arrowKeyForScroll(deltaY: CGFloat) -> String {
        deltaY > 0 ? "\u{1b}OA" : "\u{1b}OB"
    }

    /// Computes scroll velocity (number of events to send) based on scroll delta magnitude.
    ///
    /// - Parameter delta: Absolute scroll delta value.
    /// - Returns: Number of scroll events to send (1–3).
    static func scrollVelocity(delta: CGFloat) -> Int {
        let absDelta = abs(delta)
        if absDelta > 5 {
            return 3
        }
        if absDelta > 1 {
            return Int(min(absDelta, 3))
        }
        return 1
    }
}
