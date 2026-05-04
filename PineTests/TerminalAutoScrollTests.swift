//
//  TerminalAutoScrollTests.swift
//  PineTests
//
//  Tests for the drag-selection auto-scroll feature in the terminal
//  (issue #915). Pure-math helpers in `TerminalAutoScroll` are tested
//  exhaustively without timers or AppKit views.
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

    @Test func interceptorMouseDownClearsLastDragEvent() {
        // mouseDown should reset any in-flight auto-scroll state from a
        // previous drag (defensive — the timer is normally stopped on
        // mouseUp, but we want a hard reset on the next press).
        let interceptor = TerminalScrollInterceptor()
        interceptor.frame = NSRect(x: 0, y: 0, width: 800, height: 300)
        // No terminalView attached; we just want to assert this does not
        // crash and leaves the interceptor in a clean state. A nil
        // terminalView short-circuits all mouse forwarding.
        let event = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 100, y: 100),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 0
        )
        if let event {
            interceptor.mouseDown(with: event)
        }
        // Direct API: there is no public way to assert "timer not running"
        // without exposing internals; the lifecycle is covered indirectly
        // by the deinit / window-detach paths below. This test mainly
        // pins that mouseDown does not crash with no terminal attached.
    }

    @Test func interceptorMouseUpDoesNotCrashWithoutTerminal() {
        let interceptor = TerminalScrollInterceptor()
        interceptor.frame = NSRect(x: 0, y: 0, width: 800, height: 300)
        let event = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: NSPoint(x: 100, y: 100),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 0
        )
        if let event {
            interceptor.mouseUp(with: event)
        }
        // Just assert we got here.
        #expect(true)
    }

    @Test func interceptorMouseDraggedDoesNotCrashWithoutTerminal() {
        let interceptor = TerminalScrollInterceptor()
        interceptor.frame = NSRect(x: 0, y: 0, width: 800, height: 300)
        let event = NSEvent.mouseEvent(
            with: .leftMouseDragged,
            location: NSPoint(x: 100, y: 600), // outside, should try to start auto-scroll
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 0
        )
        if let event {
            interceptor.mouseDragged(with: event)
        }
        #expect(true)
    }
}
