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

    /// Returns the number of arrow keys the alternate-screen scroll path should
    /// emit for a given `NormalScrollResult`.
    ///
    /// The alternate-screen path (TUI apps without mouse reporting: vim/less/man,
    /// k9s without mouse) emits one application cursor sequence
    /// (`ESC O A`/`ESC O B`) per scrollback line, so this forwards `result.lines`.
    ///
    /// This is a thin named mapping kept for readability at the call site in
    /// `TerminalSession.swift`; it documents that the arrow cadence intentionally
    /// matches normal-mode scrollback. The helper itself is an identity pass-through
    /// over `result.lines`, so the count it returns is already covered by the
    /// `normalScrollLines` tests. The actual `sendResponse` emission loop and the
    /// per-call arrow direction selection live in the caller and are not
    /// unit-tested here: the project has no SwiftTerm `Terminal` spy or integration
    /// harness, so they are verified manually per the PR's manual-test checklist.
    ///
    /// - Parameter result: The result of `normalScrollLines` for the scroll event.
    /// - Returns: Number of arrow key sequences to emit.
    static func arrowKeyCount(for result: NormalScrollResult) -> Int {
        result.lines
    }

    /// Points of trackpad delta that correspond to one line of scrollback.
    static let trackpadLineThreshold: CGFloat = 10

    /// Minimum residual trackpad delta (points) that still commits a final
    /// line when a scroll gesture ends. Half the per-line `trackpadLineThreshold`
    /// so the last partial line is not lost, while sub-threshold noise is
    /// dropped to avoid a stray 1-line twitch.
    static let gestureEndSettleThreshold: CGFloat = trackpadLineThreshold / 2

    /// Result of a normal-mode scroll calculation.
    struct NormalScrollResult {
        /// Number of scrollback lines to scroll.
        let lines: Int
        /// Remaining accumulated delta after consuming whole lines.
        let remainingDelta: CGFloat
    }

    /// Returns how many whole lines of residual delta to commit when a scroll
    /// gesture ends (trackpad phase `.ended`, including the final momentum
    /// `.ended`), so a partial line above the settle threshold is not silently
    /// dropped.
    ///
    /// Both `normalScrollLines` and `mouseReportingScrollEvents` always consume
    /// whole `trackpadLineThreshold` multiples during the gesture, so the
    /// residual reaching `.ended` is strictly below one full threshold.
    /// Therefore this returns `0` or `1`: commit the single final partial line
    /// when the residual meets `gestureEndSettleThreshold` (half a line), or
    /// drop it to avoid a stray twitch. This matches the Ghostty/iTerm2 gesture
    /// model where `.ended` flushes the residual so the buffer lands exactly
    /// where the fingers stopped.
    ///
    /// - Parameters:
    ///   - accumulatedDelta: The residual delta carried by the active branch.
    ///   - settleThreshold: Minimum residual magnitude that still emits. Defaults
    ///     to `gestureEndSettleThreshold` (`trackpadLineThreshold / 2`).
    /// - Returns: `1` when the residual should commit its final line, else `0`.
    static func flushResidual(
        accumulatedDelta: CGFloat,
        settleThreshold: CGFloat = gestureEndSettleThreshold
    ) -> Int {
        abs(accumulatedDelta) >= settleThreshold ? 1 : 0
    }

    /// Calculates controlled scroll lines for normal-mode terminal scrollback.
    ///
    /// Trackpad scrolling accumulates precise deltas and scrolls one line per
    /// `trackpadLineThreshold` points, preventing macOS momentum from scrolling
    /// entire pages. Mouse wheel scrolling uses a clamped delta (1–3 lines).
    ///
    /// - Parameters:
    ///   - accumulatedDelta: Previously accumulated trackpad delta (ignored for mouse wheel).
    ///   - newDelta: The current event's scroll delta.
    ///   - isPrecise: Whether the event comes from a trackpad (`hasPreciseScrollingDeltas`).
    ///   - phaseBegan: Whether the gesture phase is `.began` (resets accumulation).
    /// - Returns: The number of lines to scroll and the remaining delta.
    static func normalScrollLines(
        accumulatedDelta: CGFloat,
        newDelta: CGFloat,
        isPrecise: Bool,
        phaseBegan: Bool
    ) -> NormalScrollResult {
        if isPrecise {
            let accumulated = phaseBegan ? newDelta : accumulatedDelta + newDelta
            let linesToScroll = Int(abs(accumulated) / trackpadLineThreshold)
            if linesToScroll > 0 {
                let consumed = CGFloat(linesToScroll) * trackpadLineThreshold
                let remaining = accumulated - consumed * (accumulated > 0 ? 1 : -1)
                return NormalScrollResult(lines: linesToScroll, remainingDelta: remaining)
            }
            return NormalScrollResult(lines: 0, remainingDelta: accumulated)
        } else {
            let lines = min(max(Int(abs(newDelta)), 1), 3)
            return NormalScrollResult(lines: lines, remainingDelta: 0)
        }
    }

    // MARK: - Mouse-reporting scroll forwarding

    /// Result of a mouse-reporting scroll calculation.
    ///
    /// `events` is the number of VT100 mouse-button events to forward to the
    /// TUI app (each one represents a single wheel click in the TUI's view).
    /// `remainingDelta` is the residual trackpad delta carried into the next
    /// scroll event so sub-threshold motion is not lost.
    struct MouseReportingScrollResult {
        /// Number of VT100 mouse-button events to send.
        let events: Int
        /// Remaining accumulated delta after consuming whole thresholds.
        let remainingDelta: CGFloat
    }

    /// Calculates how many VT100 mouse-button events to forward to a TUI app
    /// that has mouse reporting enabled (vim `set mouse=a`, lazygit, htop,
    /// k9s, etc.).
    ///
    /// This mirrors `normalScrollLines`'s trackpad accumulator pattern
    /// (accumulate precise deltas, consume whole `trackpadLineThreshold`
    /// multiples, preserve the remainder, reset on `phaseBegan`) but differs
    /// in two important ways:
    ///
    /// 1. **Each threshold crossing emits exactly one event, not `n`.**
    ///    TUI apps treat every VT100 mouse-button-4/5 event as a discrete
    ///    wheel click, so emitting `n` per `n × threshold` of motion produces
    ///    `n`-line jumps. Forwarding one event per threshold crossing lets the
    ///    TUI pace itself to the actual gesture (Ghostty/WezTerm/iTerm2
    ///    behavior).
    ///
    /// 2. **Non-precise (mouse wheel) input always returns exactly one event**
    ///    with no accumulation. A physical mouse wheel tick is already a
    ///    single discrete click; scaling it to 1–3 (as `normalScrollLines`
    ///    does for scrollback) would again cause multi-line jumps in the TUI.
    ///
    /// - Parameters:
    ///   - accumulatedDelta: Previously accumulated trackpad delta (ignored
    ///     for non-precise input and on `phaseBegan`).
    ///   - newDelta: The current event's scroll delta.
    ///   - isPrecise: Whether the event comes from a trackpad
    ///     (`hasPreciseScrollingDeltas`).
    ///   - phaseBegan: Whether the gesture phase is `.began` (resets
    ///     accumulation).
    /// - Returns: The number of events to forward and the remaining delta.
    static func mouseReportingScrollEvents(
        accumulatedDelta: CGFloat,
        newDelta: CGFloat,
        isPrecise: Bool,
        phaseBegan: Bool
    ) -> MouseReportingScrollResult {
        if isPrecise {
            let accumulated = phaseBegan ? newDelta : accumulatedDelta + newDelta
            let crossings = Int(abs(accumulated) / trackpadLineThreshold)
            if crossings > 0 {
                // One event per threshold crossing — the TUI sees one wheel
                // click per `trackpadLineThreshold` of motion, not a burst.
                let consumed = CGFloat(crossings) * trackpadLineThreshold
                let remaining = accumulated - consumed * (accumulated > 0 ? 1 : -1)
                return MouseReportingScrollResult(events: crossings, remainingDelta: remaining)
            }
            return MouseReportingScrollResult(events: 0, remainingDelta: accumulated)
        } else {
            // Physical mouse wheel: one discrete click → one event, no scaling,
            // no accumulation (consistent with how TUIs expect wheel input).
            return MouseReportingScrollResult(events: 1, remainingDelta: 0)
        }
    }
}
