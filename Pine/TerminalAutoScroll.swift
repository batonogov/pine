//
//  TerminalAutoScroll.swift
//  Pine
//
//  Pure helpers for computing terminal scrollback auto-scroll behaviour
//  while the user drags a selection past the view bounds. Extracted from
//  TerminalScrollInterceptor so the math can be unit-tested without timers,
//  NSEvent, or AppKit views in the loop.
//

import Foundation
import CoreGraphics

/// Direction in which the scrollback buffer should auto-scroll while the
/// user drags a selection past the terminal view bounds.
enum TerminalAutoScrollDirection {
    case up
    case down
}

/// Pure utilities for the drag-selection auto-scroll feature.
///
/// All entry points are static functions of plain numeric types so they can
/// be exercised by Swift Testing without spinning up `NSView`, `NSEvent`,
/// timers, or a real terminal buffer.
enum TerminalAutoScroll {

    /// Tick interval for the auto-scroll timer. Roughly ~17 ticks/second
    /// keeps scrolling smooth while the user holds the cursor outside the
    /// view, without saturating the main thread.
    static let tickInterval: TimeInterval = 0.06

    /// Hard ceiling on lines scrolled per tick. Prevents runaway scroll
    /// when the user flings the cursor far below the terminal.
    static let maxLinesPerTick: Int = 8

    /// Distance (points) over which one extra line per tick is added.
    /// `lines = clamp(distance / linesPerPoint, 1, maxLinesPerTick)`.
    static let pointsPerLineStep: CGFloat = 20

    /// Returns the auto-scroll direction implied by `point` relative to
    /// the terminal view's `bounds` (assumed flipped, y=0 at top).
    ///
    /// - Returns: `.up` if the cursor is above the view, `.down` if below,
    ///   or `nil` when the cursor is inside the view (or exactly on the
    ///   border — touching the edge does not trigger auto-scroll, matching
    ///   how AppKit `NSTextView` behaves).
    static func direction(forPoint point: CGPoint, in bounds: CGRect) -> TerminalAutoScrollDirection? {
        guard bounds.height > 0, bounds.width > 0 else { return nil }
        if point.y < bounds.minY {
            return .up
        }
        if point.y > bounds.maxY {
            return .down
        }
        return nil
    }

    /// Distance (in points) the cursor sits beyond the closer of the
    /// two horizontal edges of `bounds`. Always non-negative.
    ///
    /// - Returns: 0 if the cursor is inside or exactly on either edge.
    static func edgeDistance(forPoint point: CGPoint, in bounds: CGRect) -> CGFloat {
        guard bounds.height > 0, bounds.width > 0 else { return 0 }
        if point.y < bounds.minY {
            return bounds.minY - point.y
        }
        if point.y > bounds.maxY {
            return point.y - bounds.maxY
        }
        return 0
    }

    /// Lines to scroll per tick given how far the cursor sits beyond the view.
    ///
    /// - 0 distance → 0 lines (no-op; caller should not start a timer).
    /// - Linear ramp: 1 line per `pointsPerLineStep` points beyond the edge.
    /// - Always at least 1 line once `distance > 0`, ceilinged at `maxLinesPerTick`.
    /// - Defensive against negative inputs (treats them as 0).
    /// - Defensive against `NaN` / `-infinity` (treated as 0) and `+infinity`
    ///   (clamped to `maxLinesPerTick`). `Int(_:)` of a non-finite `Double` is
    ///   undefined behaviour in Swift (traps in debug, returns garbage in
    ///   release), so we must intercept before constructing the integer.
    static func linesPerTick(forDistance distance: CGFloat) -> Int {
        guard distance.isFinite else {
            // +infinity should saturate at the cap; -infinity / NaN are
            // treated as "no scroll" so they cannot stall or crash the loop.
            return distance > 0 ? maxLinesPerTick : 0
        }
        guard distance > 0 else { return 0 }
        let raw = Int((distance / pointsPerLineStep).rounded(.down))
        let withFloor = max(1, raw)
        return min(maxLinesPerTick, withFloor)
    }
}
