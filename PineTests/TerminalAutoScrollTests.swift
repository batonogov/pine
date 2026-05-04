//
//  TerminalAutoScrollTests.swift
//  PineTests
//
//  Tests for the drag-selection auto-scroll feature in the terminal
//  (issue #915). Pure-math helpers in `TerminalAutoScroll` are tested
//  exhaustively without timers or AppKit views; lifecycle of
//  `TerminalScrollInterceptor` (start, stop on mouseUp / window detach /
//  active tab change / global mouseUp / window resign key) is verified
//  via the internal `isAutoScrollActive` test hook.
//

import Testing
import AppKit
@testable import Pine

@Suite("Terminal Auto-Scroll Tests")
@MainActor
struct TerminalAutoScrollTests {

    // MARK: - direction(forPoint:in:)

    private static let standardBounds = CGRect(x: 0, y: 0, width: 800, height: 300)

    @Test func directionInsideBoundsIsNil() {
        let direction = TerminalAutoScroll.direction(
            forPoint: CGPoint(x: 400, y: 150),
            in: Self.standardBounds
        )
        #expect(direction == nil)
    }

    @Test func directionAboveTopEdgeIsUp() {
        let direction = TerminalAutoScroll.direction(
            forPoint: CGPoint(x: 400, y: -1),
            in: Self.standardBounds
        )
        #expect(direction == .up)
    }

    @Test func directionFarAboveTopEdgeIsUp() {
        let direction = TerminalAutoScroll.direction(
            forPoint: CGPoint(x: 400, y: -500),
            in: Self.standardBounds
        )
        #expect(direction == .up)
    }

    @Test func directionBelowBottomEdgeIsDown() {
        let direction = TerminalAutoScroll.direction(
            forPoint: CGPoint(x: 400, y: 301),
            in: Self.standardBounds
        )
        #expect(direction == .down)
    }

    @Test func directionFarBelowBottomEdgeIsDown() {
        let direction = TerminalAutoScroll.direction(
            forPoint: CGPoint(x: 400, y: 100_000),
            in: Self.standardBounds
        )
        #expect(direction == .down)
    }

    @Test func directionExactlyOnTopEdgeIsNil() {
        // Cursor sitting exactly on the top edge should not trigger
        // auto-scroll, mirroring NSTextView behaviour.
        let direction = TerminalAutoScroll.direction(
            forPoint: CGPoint(x: 400, y: 0),
            in: Self.standardBounds
        )
        #expect(direction == nil)
    }

    @Test func directionExactlyOnBottomEdgeIsNil() {
        let direction = TerminalAutoScroll.direction(
            forPoint: CGPoint(x: 400, y: 300),
            in: Self.standardBounds
        )
        #expect(direction == nil)
    }

    @Test func directionForXOutsideBoundsStillFollowsYAxis() {
        // Horizontal axis is irrelevant — only y matters because the
        // terminal scrolls vertically. A point off the right edge but
        // vertically inside should not trigger auto-scroll.
        let direction = TerminalAutoScroll.direction(
            forPoint: CGPoint(x: 5_000, y: 150),
            in: Self.standardBounds
        )
        #expect(direction == nil)
    }

    @Test func directionForZeroHeightBoundsIsNil() {
        // Collapsed pane — no terminal area to scroll over. Must not crash
        // and must not return a direction.
        let direction = TerminalAutoScroll.direction(
            forPoint: CGPoint(x: 100, y: 100),
            in: CGRect(x: 0, y: 0, width: 800, height: 0)
        )
        #expect(direction == nil)
    }

    @Test func directionForZeroWidthBoundsIsNil() {
        let direction = TerminalAutoScroll.direction(
            forPoint: CGPoint(x: 100, y: 100),
            in: CGRect(x: 0, y: 0, width: 0, height: 300)
        )
        #expect(direction == nil)
    }

    // MARK: - edgeDistance(forPoint:in:)

    @Test func edgeDistanceInsideBoundsIsZero() {
        let distance = TerminalAutoScroll.edgeDistance(
            forPoint: CGPoint(x: 400, y: 150),
            in: Self.standardBounds
        )
        #expect(distance == 0)
    }

    @Test func edgeDistanceExactlyOnTopEdgeIsZero() {
        let distance = TerminalAutoScroll.edgeDistance(
            forPoint: CGPoint(x: 400, y: 0),
            in: Self.standardBounds
        )
        #expect(distance == 0)
    }

    @Test func edgeDistanceExactlyOnBottomEdgeIsZero() {
        let distance = TerminalAutoScroll.edgeDistance(
            forPoint: CGPoint(x: 400, y: 300),
            in: Self.standardBounds
        )
        #expect(distance == 0)
    }

    @Test func edgeDistanceOnePixelBelowIsOne() {
        let distance = TerminalAutoScroll.edgeDistance(
            forPoint: CGPoint(x: 400, y: 301),
            in: Self.standardBounds
        )
        #expect(distance == 1)
    }

    @Test func edgeDistanceOnePixelAboveIsOne() {
        let distance = TerminalAutoScroll.edgeDistance(
            forPoint: CGPoint(x: 400, y: -1),
            in: Self.standardBounds
        )
        #expect(distance == 1)
    }

    @Test func edgeDistanceFarBelowIsBigPositive() {
        let distance = TerminalAutoScroll.edgeDistance(
            forPoint: CGPoint(x: 400, y: 600),
            in: Self.standardBounds
        )
        #expect(distance == 300)
    }

    @Test func edgeDistanceFarAboveIsBigPositive() {
        let distance = TerminalAutoScroll.edgeDistance(
            forPoint: CGPoint(x: 400, y: -250),
            in: Self.standardBounds
        )
        #expect(distance == 250)
    }

    @Test func edgeDistanceForZeroHeightBoundsIsZero() {
        let distance = TerminalAutoScroll.edgeDistance(
            forPoint: CGPoint(x: 100, y: 100),
            in: CGRect(x: 0, y: 0, width: 800, height: 0)
        )
        #expect(distance == 0)
    }

    @Test func edgeDistanceWithOriginOffset() {
        // Bounds origin should not be assumed to be (0, 0).
        let bounds = CGRect(x: 0, y: 50, width: 800, height: 300)
        // Point above minY (50)
        #expect(TerminalAutoScroll.edgeDistance(
            forPoint: CGPoint(x: 100, y: 30),
            in: bounds
        ) == 20)
        // Point below maxY (350)
        #expect(TerminalAutoScroll.edgeDistance(
            forPoint: CGPoint(x: 100, y: 400),
            in: bounds
        ) == 50)
        // Point inside
        #expect(TerminalAutoScroll.edgeDistance(
            forPoint: CGPoint(x: 100, y: 200),
            in: bounds
        ) == 0)
    }

    // MARK: - linesPerTick(forDistance:)

    @Test func linesPerTickAtZeroDistanceIsZero() {
        #expect(TerminalAutoScroll.linesPerTick(forDistance: 0) == 0)
    }

    @Test func linesPerTickAtOnePixelIsOne() {
        // Tiny but non-zero distance should still scroll exactly one line
        // per tick — this is what makes the feature feel responsive when
        // the user just barely overshoots the edge.
        #expect(TerminalAutoScroll.linesPerTick(forDistance: 1) == 1)
    }

    @Test func linesPerTickAtOneStepStaysOne() {
        // 20 px is exactly one step; floor(20/20) = 1 → 1 line.
        #expect(TerminalAutoScroll.linesPerTick(forDistance: 20) == 1)
    }

    @Test func linesPerTickJustBelowOneStepStaysOne() {
        // 19 px → floor(19/20) = 0 → clamped up to 1.
        #expect(TerminalAutoScroll.linesPerTick(forDistance: 19) == 1)
    }

    @Test func linesPerTickAtTwoStepsIsTwo() {
        // 40 px → floor(40/20) = 2 → 2 lines.
        #expect(TerminalAutoScroll.linesPerTick(forDistance: 40) == 2)
    }

    @Test func linesPerTickAtMaxIsCapped() {
        // 200 px → 10, clamped to maxLinesPerTick (8).
        #expect(TerminalAutoScroll.linesPerTick(forDistance: 200) == TerminalAutoScroll.maxLinesPerTick)
    }

    @Test func linesPerTickFarBeyondMaxStaysCapped() {
        // Runaway protection: a fling 10 000 px below should still cap
        // at maxLinesPerTick — never pump dozens of lines per tick.
        #expect(TerminalAutoScroll.linesPerTick(forDistance: 10_000) == TerminalAutoScroll.maxLinesPerTick)
    }

    @Test func linesPerTickForNegativeDistanceIsZero() {
        // Defensive — direction encodes sign, distance is always non-negative.
        #expect(TerminalAutoScroll.linesPerTick(forDistance: -1) == 0)
        #expect(TerminalAutoScroll.linesPerTick(forDistance: -1_000) == 0)
    }

    @Test func linesPerTickForFractionalDistance() {
        // 30.5 → floor(30.5/20) = floor(1.525) = 1 → 1 line.
        #expect(TerminalAutoScroll.linesPerTick(forDistance: 30.5) == 1)
        // 41 → floor(41/20) = floor(2.05) = 2 → 2 lines.
        #expect(TerminalAutoScroll.linesPerTick(forDistance: 41) == 2)
    }

    // MARK: - linesPerTick non-finite inputs (NaN / +∞ / -∞)
    //
    // Without an `isFinite` guard, `Int((nan / step).rounded(.down))` traps
    // in debug and returns garbage in release. These tests pin the explicit
    // contract: NaN and -∞ are treated as 0 (no scroll), +∞ saturates at
    // the cap. Symmetric with the negative-distance test above — caller
    // never has to launder its inputs before calling.

    @Test func linesPerTickForNaNIsZero() {
        #expect(TerminalAutoScroll.linesPerTick(forDistance: .nan) == 0)
    }

    @Test func linesPerTickForPositiveInfinityIsCapped() {
        #expect(
            TerminalAutoScroll.linesPerTick(forDistance: .infinity)
                == TerminalAutoScroll.maxLinesPerTick
        )
    }

    @Test func linesPerTickForNegativeInfinityIsZero() {
        #expect(TerminalAutoScroll.linesPerTick(forDistance: -.infinity) == 0)
    }

    // MARK: - linesPerTick boundary around the maxLinesPerTick cap
    //
    // 200 px == 10 raw lines → clamped to 8 (the cap). 199 px == 9 raw → 8.
    // 201 px == 10 raw → still 8. The cap should clamp from both directions
    // smoothly, no off-by-one regressions if the constants ever change.

    @Test func linesPerTickAtBoundary199() {
        // 199 / 20 = 9.95 → floor 9 → clamped to 8.
        #expect(TerminalAutoScroll.linesPerTick(forDistance: 199) == TerminalAutoScroll.maxLinesPerTick)
    }

    @Test func linesPerTickAtBoundary200() {
        // 200 / 20 = 10 → clamped to 8.
        #expect(TerminalAutoScroll.linesPerTick(forDistance: 200) == TerminalAutoScroll.maxLinesPerTick)
    }

    @Test func linesPerTickAtBoundary201() {
        // 201 / 20 = 10.05 → floor 10 → clamped to 8.
        #expect(TerminalAutoScroll.linesPerTick(forDistance: 201) == TerminalAutoScroll.maxLinesPerTick)
    }

    @Test func linesPerTickIsMonotonic() {
        // The ramp must be monotonic non-decreasing across the full range
        // we care about, so larger overshoots never scroll less.
        var previous = 0
        for distance in stride(from: CGFloat(0), through: CGFloat(400), by: 1) {
            let lines = TerminalAutoScroll.linesPerTick(forDistance: distance)
            #expect(lines >= previous)
            previous = lines
        }
    }

    @Test func linesPerTickNeverExceedsCeiling() {
        // Property check: under no input does linesPerTick exceed
        // maxLinesPerTick.
        for distance in stride(from: CGFloat(0), through: CGFloat(20_000), by: 7.5) {
            #expect(TerminalAutoScroll.linesPerTick(forDistance: distance) <= TerminalAutoScroll.maxLinesPerTick)
        }
    }

    // MARK: - Tick interval and constants are sane

    @Test func tickIntervalIsBetween30And120Hz() {
        // ~60 ms is the design target. Guard against accidentally setting
        // it to 0 (busy loop) or > 1 s (sluggish).
        #expect(TerminalAutoScroll.tickInterval > 0)
        #expect(TerminalAutoScroll.tickInterval < 1.0)
    }

    @Test func maxLinesPerTickIsReasonable() {
        // Should be high enough to feel fast at the edges, low enough
        // to not jump entire pages per tick.
        #expect(TerminalAutoScroll.maxLinesPerTick > 0)
        #expect(TerminalAutoScroll.maxLinesPerTick <= 32)
    }

    @Test func pointsPerLineStepIsPositive() {
        #expect(TerminalAutoScroll.pointsPerLineStep > 0)
    }

    // MARK: - TerminalScrollInterceptor lifecycle
    //
    // These tests use the internal `startAutoScrollForTesting()` hook to
    // bring the interceptor into the "timer running" state without needing
    // a fully-initialised `LocalProcessTerminalView` with real scrollback.
    // Each test then exercises one of the stop paths and verifies the
    // public test hook `isAutoScrollActive` flips back to `false`.

    private func makeInterceptor() -> TerminalScrollInterceptor {
        let interceptor = TerminalScrollInterceptor()
        interceptor.frame = NSRect(x: 0, y: 0, width: 800, height: 300)
        return interceptor
    }

    private func makeMouseEvent(type: NSEvent.EventType, at point: NSPoint) -> NSEvent {
        // NSEvent.mouseEvent(...) returns nil only for non-mouse `type`
        // values, which we never pass — but we still avoid force-unwrap
        // and fail the test loudly if AppKit ever changes that contract.
        guard let event = NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 0
        ) else {
            Issue.record("NSEvent.mouseEvent returned nil for type \(type)")
            // Sentinel that will fail downstream if reached; swift-testing
            // already recorded the failure above.
            return NSEvent()
        }
        return event
    }

    @Test func interceptorStartsInactive() {
        let interceptor = makeInterceptor()
        #expect(interceptor.isAutoScrollActive == false)
    }

    @Test func interceptorTestHookStartsTimer() {
        let interceptor = makeInterceptor()
        interceptor.startAutoScrollForTesting()
        #expect(interceptor.isAutoScrollActive == true)
        // Cleanup so the timer cannot fire after the test exits.
        interceptor.handleGlobalMouseUp()
    }

    @Test func interceptorMouseDownStopsActiveAutoScroll() {
        // A new mouseDown means the user started a fresh drag — any
        // in-flight auto-scroll from a previous (interrupted) drag must
        // be torn down so the new gesture starts from a clean state.
        let interceptor = makeInterceptor()
        interceptor.startAutoScrollForTesting()
        #expect(interceptor.isAutoScrollActive == true)

        let event = makeMouseEvent(type: .leftMouseDown, at: NSPoint(x: 100, y: 100))
        interceptor.mouseDown(with: event)
        #expect(interceptor.isAutoScrollActive == false)
    }

    @Test func interceptorMouseUpStopsAutoScroll() {
        let interceptor = makeInterceptor()
        interceptor.startAutoScrollForTesting()
        #expect(interceptor.isAutoScrollActive == true)

        let event = makeMouseEvent(type: .leftMouseUp, at: NSPoint(x: 100, y: 100))
        interceptor.mouseUp(with: event)
        #expect(interceptor.isAutoScrollActive == false)
    }

    @Test func interceptorMouseDraggedWithoutTerminalStopsAutoScroll() {
        // mouseDragged → updateAutoScroll early-returns when terminalView
        // is nil, which calls stopAutoScroll(). This also covers the
        // "drag back inside bounds" path indirectly: in both cases the
        // updateAutoScroll guard chain must reach stopAutoScroll().
        let interceptor = makeInterceptor()
        interceptor.startAutoScrollForTesting()
        #expect(interceptor.isAutoScrollActive == true)

        let event = makeMouseEvent(type: .leftMouseDragged, at: NSPoint(x: 100, y: 100))
        interceptor.mouseDragged(with: event)
        #expect(interceptor.isAutoScrollActive == false)
    }

    @Test func interceptorWindowDetachStopsAutoScroll() {
        // viewWillMove(toWindow: nil) is AppKit's "you are about to be
        // unhooked" signal — the interceptor must drop the timer so it
        // cannot fire against a torn-down view.
        let interceptor = makeInterceptor()
        interceptor.startAutoScrollForTesting()
        #expect(interceptor.isAutoScrollActive == true)

        interceptor.viewWillMove(toWindow: nil)
        #expect(interceptor.isAutoScrollActive == false)
    }

    @Test func interceptorActiveTabChangeStopsAutoScroll() {
        // When the user switches terminal tabs while a drag is active
        // (e.g. clicks another tab), the auto-scroll loop is still
        // pointing at the OLD tab's coordinates. handleActiveTabChange()
        // is the hook the container calls before swapping terminalView.
        let interceptor = makeInterceptor()
        interceptor.startAutoScrollForTesting()
        #expect(interceptor.isAutoScrollActive == true)

        interceptor.handleActiveTabChange()
        #expect(interceptor.isAutoScrollActive == false)
    }

    @Test func interceptorGlobalMouseUpStopsAutoScroll() {
        // Safety net: if the user releases the mouse over another app
        // (Cmd+Tab, Mission Control, the menu bar), the local mouseUp
        // override never fires. handleGlobalMouseUp() is the path the
        // global NSEvent monitor invokes; without it the timer would
        // run forever.
        let interceptor = makeInterceptor()
        interceptor.startAutoScrollForTesting()
        #expect(interceptor.isAutoScrollActive == true)

        interceptor.handleGlobalMouseUp()
        #expect(interceptor.isAutoScrollActive == false)
    }

    @Test func interceptorWindowResignKeyStopsAutoScroll() {
        // Belt-and-braces alongside the global mouse-up monitor — losing
        // key status means there is nothing useful auto-scroll can do
        // against the now-unfocused window, and we want to release the
        // run-loop tick promptly.
        let interceptor = makeInterceptor()
        interceptor.startAutoScrollForTesting()
        #expect(interceptor.isAutoScrollActive == true)

        interceptor.handleWindowResignKey()
        #expect(interceptor.isAutoScrollActive == false)
    }

    @Test func interceptorStopIsIdempotent() {
        // Calling any stop path twice must not crash and must keep
        // isAutoScrollActive == false. Important because multiple
        // safety-net signals (window resign + global mouse up) can
        // arrive nearly simultaneously when focus moves away.
        let interceptor = makeInterceptor()
        interceptor.startAutoScrollForTesting()

        interceptor.handleGlobalMouseUp()
        #expect(interceptor.isAutoScrollActive == false)
        interceptor.handleGlobalMouseUp()
        #expect(interceptor.isAutoScrollActive == false)
        interceptor.handleWindowResignKey()
        #expect(interceptor.isAutoScrollActive == false)
        interceptor.handleActiveTabChange()
        #expect(interceptor.isAutoScrollActive == false)
    }

    @Test func interceptorRestartAfterStop() {
        // After a full mouse-up / mouse-down cycle the interceptor must
        // be reusable for the next drag. Verifies safety nets are torn
        // down cleanly and re-installed on the next start.
        let interceptor = makeInterceptor()
        interceptor.startAutoScrollForTesting()
        #expect(interceptor.isAutoScrollActive == true)
        interceptor.handleGlobalMouseUp()
        #expect(interceptor.isAutoScrollActive == false)

        interceptor.startAutoScrollForTesting()
        #expect(interceptor.isAutoScrollActive == true)
        interceptor.handleGlobalMouseUp()
        #expect(interceptor.isAutoScrollActive == false)
    }

    @Test func interceptorStartIsIdempotent() {
        // Repeated startAutoScrollForTesting() calls must not stack
        // timers — the existing one is reused. Without this guard we
        // could leak Timer instances.
        let interceptor = makeInterceptor()
        interceptor.startAutoScrollForTesting()
        let firstActive = interceptor.isAutoScrollActive
        interceptor.startAutoScrollForTesting()
        let secondActive = interceptor.isAutoScrollActive

        #expect(firstActive == true)
        #expect(secondActive == true)
        // Cleanup
        interceptor.handleGlobalMouseUp()
    }

    @Test func interceptorMouseDraggedInsideBoundsDoesNotStartAutoScroll() {
        // Acceptance criterion from issue #915: cursor inside bounds
        // must NOT trigger auto-scroll. With no terminalView the early
        // guard short-circuits, but the contract is the same — the
        // timer must remain inactive.
        let interceptor = makeInterceptor()
        // Simulate user pressing inside the view first.
        let downEvent = makeMouseEvent(type: .leftMouseDown, at: NSPoint(x: 400, y: 150))
        interceptor.mouseDown(with: downEvent)
        #expect(interceptor.isAutoScrollActive == false)

        // Drag inside the bounds — auto-scroll must NOT activate.
        let dragEvent = makeMouseEvent(type: .leftMouseDragged, at: NSPoint(x: 400, y: 200))
        interceptor.mouseDragged(with: dragEvent)
        #expect(interceptor.isAutoScrollActive == false)
    }
}
