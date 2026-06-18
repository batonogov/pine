//
//  TerminalScrollForwardingTests.swift
//  PineTests
//

import Testing
import AppKit
import SwiftTerm
@testable import Pine

/// Tests for mouse scroll forwarding to TUI apps in terminal.
/// When a TUI app enables mouse reporting (mouseMode != .off),
/// scroll wheel events should be sent as mouse button 4/5 events
/// instead of scrolling the scrollback buffer.
@Suite("Terminal Scroll Forwarding Tests")
@MainActor
struct TerminalScrollForwardingTests {

    // MARK: - MouseScrollForwarder unit tests

    @Test func encodesScrollUpAsButton64() {
        let flags = MouseScrollForwarder.encodeScrollButton(
            deltaY: 1.0,
            shift: false,
            option: false,
            control: false
        )
        // Button 4 (scroll up) = 64
        #expect(flags == 64)
    }

    @Test func encodesScrollDownAsButton65() {
        let flags = MouseScrollForwarder.encodeScrollButton(
            deltaY: -1.0,
            shift: false,
            option: false,
            control: false
        )
        // Button 5 (scroll down) = 65
        #expect(flags == 65)
    }

    @Test func encodesShiftModifier() {
        let flags = MouseScrollForwarder.encodeScrollButton(
            deltaY: 1.0,
            shift: true,
            option: false,
            control: false
        )
        // 64 (scroll up) | 4 (shift) = 68
        #expect(flags == 68)
    }

    @Test func encodesOptionModifier() {
        let flags = MouseScrollForwarder.encodeScrollButton(
            deltaY: 1.0,
            shift: false,
            option: true,
            control: false
        )
        // 64 (scroll up) | 8 (meta/option) = 72
        #expect(flags == 72)
    }

    @Test func encodesControlModifierScrollDown() {
        let flags = MouseScrollForwarder.encodeScrollButton(
            deltaY: -1.0,
            shift: false,
            option: false,
            control: true
        )
        // 65 (scroll down) | 16 (control) = 81
        #expect(flags == 81)
    }

    @Test func encodesControlModifierScrollUp() {
        let flags = MouseScrollForwarder.encodeScrollButton(
            deltaY: 1.0,
            shift: false,
            option: false,
            control: true
        )
        // 64 (scroll up) | 16 (control) = 80
        #expect(flags == 80)
    }

    @Test func encodesAllModifiersCombined() {
        let flags = MouseScrollForwarder.encodeScrollButton(
            deltaY: 1.0,
            shift: true,
            option: true,
            control: true
        )
        // 64 (scroll up) | 4 (shift) | 8 (meta) | 16 (control) = 92
        #expect(flags == 92)
    }

    @Test func calculatesGridPositionTopLeft() {
        let pos = MouseScrollForwarder.gridPosition(
            point: CGPoint(x: 0, y: 0),
            viewBounds: NSRect(x: 0, y: 0, width: 800, height: 300),
            cols: 80,
            rows: 24,
            isFlipped: true
        )
        #expect(pos.col == 0)
        #expect(pos.row == 0)
    }

    @Test func calculatesGridPositionBottomRight() {
        let pos = MouseScrollForwarder.gridPosition(
            point: CGPoint(x: 799, y: 299),
            viewBounds: NSRect(x: 0, y: 0, width: 800, height: 300),
            cols: 80,
            rows: 24,
            isFlipped: true
        )
        #expect(pos.col == 79)
        #expect(pos.row == 23)
    }

    @Test func clampsGridPositionToValidRange() {
        let pos = MouseScrollForwarder.gridPosition(
            point: CGPoint(x: 2000, y: 2000),
            viewBounds: NSRect(x: 0, y: 0, width: 800, height: 300),
            cols: 80,
            rows: 24,
            isFlipped: true
        )
        #expect(pos.col == 79)
        #expect(pos.row == 23)
    }

    @Test func clampsNegativePosition() {
        let pos = MouseScrollForwarder.gridPosition(
            point: CGPoint(x: -50, y: -50),
            viewBounds: NSRect(x: 0, y: 0, width: 800, height: 300),
            cols: 80,
            rows: 24,
            isFlipped: true
        )
        #expect(pos.col == 0)
        #expect(pos.row == 0)
    }

    // NOTE: Non-flipped coordinate tests are in the "Grid position edge cases (#551)" section below.

    // MARK: - TerminalContainerView scroll forwarding integration

    @Test func containerViewIsFlipped() {
        let container = TerminalContainerView()
        #expect(container.isFlipped == true)
    }

    // MARK: - TerminalScrollInterceptor tests

    @Test func scrollInterceptorIsFlipped() {
        let interceptor = TerminalScrollInterceptor()
        #expect(interceptor.isFlipped == true)
    }

    @Test func scrollInterceptorDoesNotAcceptFirstResponder() {
        // The interceptor must not steal first responder from the terminal view,
        // otherwise keyboard input would stop working.
        let interceptor = TerminalScrollInterceptor()
        #expect(interceptor.acceptsFirstResponder == false)
    }

    @Test func scrollInterceptorHitTestReturnsNilOutsideBounds() {
        let interceptor = TerminalScrollInterceptor()
        interceptor.frame = NSRect(x: 0, y: 0, width: 800, height: 300)
        let result = interceptor.hitTest(NSPoint(x: 900, y: 400))
        #expect(result == nil)
    }

    @Test func scrollInterceptorHitTestReturnsSelfInsideBounds() {
        let interceptor = TerminalScrollInterceptor()
        interceptor.frame = NSRect(x: 0, y: 0, width: 800, height: 300)
        let result = interceptor.hitTest(NSPoint(x: 400, y: 150))
        #expect(result === interceptor)
    }

    // MARK: - Arrow key encoding for alternate screen scroll

    @Test func arrowKeyForScrollUpReturnsEscOA() {
        let key = MouseScrollForwarder.arrowKeyForScroll(deltaY: 1.0)
        #expect(key == "\u{1b}OA")
    }

    @Test func arrowKeyForScrollDownReturnsEscOB() {
        let key = MouseScrollForwarder.arrowKeyForScroll(deltaY: -1.0)
        #expect(key == "\u{1b}OB")
    }

    @Test func arrowKeyForLargePositiveDeltaReturnsUp() {
        let key = MouseScrollForwarder.arrowKeyForScroll(deltaY: 50.0)
        #expect(key == "\u{1b}OA")
    }

    @Test func arrowKeyForLargeNegativeDeltaReturnsDown() {
        let key = MouseScrollForwarder.arrowKeyForScroll(deltaY: -50.0)
        #expect(key == "\u{1b}OB")
    }

    @Test func arrowKeyForSmallPositiveFractionReturnsUp() {
        let key = MouseScrollForwarder.arrowKeyForScroll(deltaY: 0.1)
        #expect(key == "\u{1b}OA")
    }

    @Test func arrowKeyForSmallNegativeFractionReturnsDown() {
        let key = MouseScrollForwarder.arrowKeyForScroll(deltaY: -0.1)
        #expect(key == "\u{1b}OB")
    }

    // MARK: - Arrow key zero-delta

    @Test func arrowKeyForScrollZeroDelta() {
        // Zero delta defaults to scroll down (ESC O B) since 0 > 0 is false
        let key = MouseScrollForwarder.arrowKeyForScroll(deltaY: 0.0)
        #expect(key == "\u{1b}OB")
    }

    // MARK: - Modifier combinations for scroll encoding

    @Test func encodesShiftAndControlCombined() {
        let flags = MouseScrollForwarder.encodeScrollButton(
            deltaY: -1.0,
            shift: true,
            option: false,
            control: true
        )
        // 65 (scroll down) | 4 (shift) | 16 (control) = 85
        #expect(flags == 85)
    }

    @Test func encodesOptionAndControlCombined() {
        let flags = MouseScrollForwarder.encodeScrollButton(
            deltaY: 1.0,
            shift: false,
            option: true,
            control: true
        )
        // 64 (scroll up) | 8 (option) | 16 (control) = 88
        #expect(flags == 88)
    }

    // MARK: - TerminalContainerView scroll forwarding integration

    @Test func containerAddsScrollInterceptorOnShowTab() {
        let container = TerminalContainerView()
        container.frame = NSRect(x: 0, y: 0, width: 800, height: 300)
        let tab = TerminalTab(name: "test")

        // Need to set up terminal pane state for showTab to work
        let state = TerminalPaneState()
        container.terminalPaneState = state

        container.showTab(tab)

        // The interceptor should be the topmost subview (added after the terminal view)
        let hasInterceptor = container.subviews.contains { $0 is TerminalScrollInterceptor }
        #expect(hasInterceptor == true)

        // Interceptor should be on top (last subview)
        #expect(container.subviews.last is TerminalScrollInterceptor)
    }

    // MARK: - Scroll encoding boundary tests (#551)

    @Test func encodeScrollButtonWithExactZeroDelta() {
        // Zero delta should still produce a value (treated as scroll down since deltaY <= 0)
        let flags = MouseScrollForwarder.encodeScrollButton(
            deltaY: 0.0, shift: false, option: false, control: false
        )
        // deltaY > 0 → 64 (up), else 65 (down). 0.0 is not > 0, so expect 65.
        #expect(flags == 65)
    }

    @Test func encodeScrollButtonWithVerySmallPositiveDelta() {
        let flags = MouseScrollForwarder.encodeScrollButton(
            deltaY: 0.001, shift: false, option: false, control: false
        )
        #expect(flags == 64) // scroll up
    }

    @Test func encodeScrollButtonWithVerySmallNegativeDelta() {
        let flags = MouseScrollForwarder.encodeScrollButton(
            deltaY: -0.001, shift: false, option: false, control: false
        )
        #expect(flags == 65) // scroll down
    }

    @Test func encodeScrollButtonWithLargeDelta() {
        // Very large delta should still produce correct base value
        let flags = MouseScrollForwarder.encodeScrollButton(
            deltaY: 100.0, shift: false, option: false, control: false
        )
        #expect(flags == 64)
    }

    @Test func encodeScrollDownWithAllModifiers() {
        let flags = MouseScrollForwarder.encodeScrollButton(
            deltaY: -1.0, shift: true, option: true, control: true
        )
        // 65 (down) | 4 (shift) | 8 (option) | 16 (control) = 93
        #expect(flags == 93)
    }

    @Test func encodeScrollDownWithShift() {
        let flags = MouseScrollForwarder.encodeScrollButton(
            deltaY: -1.0, shift: true, option: false, control: false
        )
        // 65 (down) | 4 (shift) = 69
        #expect(flags == 69)
    }

    @Test func encodeScrollDownWithOption() {
        let flags = MouseScrollForwarder.encodeScrollButton(
            deltaY: -1.0, shift: false, option: true, control: false
        )
        // 65 (down) | 8 (option) = 73
        #expect(flags == 73)
    }

    // MARK: - Mouse-reporting scroll forwarding (#978)
    //
    // When a TUI app enables mouse reporting (mouseMode != .off), scroll
    // events are forwarded as VT100 mouse-button-4/5 events. The helper
    // emits exactly one event per `trackpadLineThreshold` of accumulated
    // trackpad motion (not a burst), and exactly one event per mouse-wheel
    // tick. The former `scrollVelocity` 1–3 burst helper was removed in
    // favor of this accumulator; see issue #978.

    @Test func mouseReportingPreciseDeltaBelowThresholdEmitsNothing() {
        // A single precise (trackpad) delta below the threshold produces no
        // events and carries the full delta forward into the accumulator.
        let result = MouseScrollForwarder.mouseReportingScrollEvents(
            accumulatedDelta: 0,
            newDelta: 5,
            isPrecise: true,
            phaseBegan: false
        )
        #expect(result.events == 0)
        #expect(result.remainingDelta == 5)
    }

    @Test func mouseReportingPreciseDeltaExactlyAtThresholdEmitsOne() {
        // Exactly one threshold worth of motion → exactly one event.
        let result = MouseScrollForwarder.mouseReportingScrollEvents(
            accumulatedDelta: 0,
            newDelta: MouseScrollForwarder.trackpadLineThreshold,
            isPrecise: true,
            phaseBegan: false
        )
        #expect(result.events == 1)
        #expect(result.remainingDelta == 0)
    }

    @Test func mouseReportingPreciseDeltaMultipleCrossingsEmitsOnePerCrossing() {
        // delta 25 at threshold 10 → 2 crossings (2 events), remainder 5.
        // This is the key difference from the old `scrollVelocity` burst:
        // each crossing is exactly one wheel click in the TUI's view, so a
        // flick scrolls two lines, not a 3× burst × something.
        let result = MouseScrollForwarder.mouseReportingScrollEvents(
            accumulatedDelta: 0,
            newDelta: 25,
            isPrecise: true,
            phaseBegan: false
        )
        #expect(result.events == 2)
        #expect(result.remainingDelta == 5)
    }

    @Test func mouseReportingPreciseAccumulatesAcrossEvents() {
        // First event: delta 6 (below threshold) → 0 events, remaining 6.
        let r1 = MouseScrollForwarder.mouseReportingScrollEvents(
            accumulatedDelta: 0,
            newDelta: 6,
            isPrecise: true,
            phaseBegan: false
        )
        #expect(r1.events == 0)
        #expect(r1.remainingDelta == 6)

        // Second event: delta 6, accumulated = 12 → 1 crossing, remaining 2.
        let r2 = MouseScrollForwarder.mouseReportingScrollEvents(
            accumulatedDelta: r1.remainingDelta,
            newDelta: 6,
            isPrecise: true,
            phaseBegan: false
        )
        #expect(r2.events == 1)
        #expect(r2.remainingDelta == 2)
    }

    @Test func mouseReportingPreciseNegativeDeltaEmitsPerCrossing() {
        // Scrolling down accumulates negative deltas; 25 points → 2 events,
        // remainder -5. The sign of the remaining delta is preserved.
        let result = MouseScrollForwarder.mouseReportingScrollEvents(
            accumulatedDelta: 0,
            newDelta: -25,
            isPrecise: true,
            phaseBegan: false
        )
        #expect(result.events == 2)
        #expect(result.remainingDelta == -5)
    }

    @Test func mouseReportingPreciseLargeMomentumDelta() {
        // A large trackpad-momentum delta of 150 → 15 crossings (15 single
        // events), no remainder. Previously this would have been clamped to a
        // 3-event burst regardless of magnitude.
        let result = MouseScrollForwarder.mouseReportingScrollEvents(
            accumulatedDelta: 0,
            newDelta: 150,
            isPrecise: true,
            phaseBegan: false
        )
        #expect(result.events == 15)
        #expect(result.remainingDelta == 0)
    }

    @Test func mouseReportingPreciseCarriesRemainderAcrossEvents() {
        // Three events of delta 7 each: 7 → 14 → 21
        // 7/10=0 (rem 7), 14/10=1 (rem 4), 11/10=1 (rem 1)
        let r1 = MouseScrollForwarder.mouseReportingScrollEvents(
            accumulatedDelta: 0, newDelta: 7, isPrecise: true, phaseBegan: false
        )
        #expect(r1.events == 0)
        #expect(r1.remainingDelta == 7)

        let r2 = MouseScrollForwarder.mouseReportingScrollEvents(
            accumulatedDelta: r1.remainingDelta, newDelta: 7, isPrecise: true, phaseBegan: false
        )
        #expect(r2.events == 1)
        #expect(r2.remainingDelta == 4)

        let r3 = MouseScrollForwarder.mouseReportingScrollEvents(
            accumulatedDelta: r2.remainingDelta, newDelta: 7, isPrecise: true, phaseBegan: false
        )
        #expect(r3.events == 1)
        #expect(r3.remainingDelta == 1)
    }

    @Test func mouseReportingPhaseBeganResetsAccumulation() {
        // A residual of 999 must be discarded when a new gesture begins; the
        // new gesture's first delta (5, below threshold) becomes the seed.
        let result = MouseScrollForwarder.mouseReportingScrollEvents(
            accumulatedDelta: 999,
            newDelta: 5,
            isPrecise: true,
            phaseBegan: true
        )
        #expect(result.events == 0)
        #expect(result.remainingDelta == 5)
    }

    @Test func mouseReportingPhaseBeganWithLargeDeltaEmitsImmediately() {
        // If the very first event of a gesture is large enough to cross the
        // threshold, events are emitted right away (phaseBegan seeds then
        // consumes in one step).
        let result = MouseScrollForwarder.mouseReportingScrollEvents(
            accumulatedDelta: 999,
            newDelta: 25,
            isPrecise: true,
            phaseBegan: true
        )
        #expect(result.events == 2)
        #expect(result.remainingDelta == 5)
    }

    @Test func mouseReportingMouseWheelAlwaysOneEvent() {
        // Non-precise (physical mouse wheel) input always produces exactly one
        // event regardless of magnitude — a wheel tick is a single discrete
        // click, and there is no accumulation between ticks.
        let small = MouseScrollForwarder.mouseReportingScrollEvents(
            accumulatedDelta: 0, newDelta: 1, isPrecise: false, phaseBegan: false
        )
        #expect(small.events == 1)
        #expect(small.remainingDelta == 0)

        let medium = MouseScrollForwarder.mouseReportingScrollEvents(
            accumulatedDelta: 0, newDelta: 2, isPrecise: false, phaseBegan: false
        )
        #expect(medium.events == 1)
        #expect(medium.remainingDelta == 0)

        let large = MouseScrollForwarder.mouseReportingScrollEvents(
            accumulatedDelta: 0, newDelta: 15, isPrecise: false, phaseBegan: false
        )
        #expect(large.events == 1)
        #expect(large.remainingDelta == 0)
    }

    @Test func mouseReportingMouseWheelIgnoresAccumulatedDelta() {
        // Mouse wheel never accumulates — a leftover trackpad residual must
        // not turn a single wheel tick into multiple events.
        let result = MouseScrollForwarder.mouseReportingScrollEvents(
            accumulatedDelta: 500,
            newDelta: 1,
            isPrecise: false,
            phaseBegan: false
        )
        #expect(result.events == 1)
        #expect(result.remainingDelta == 0)
    }

    @Test func mouseReportingMouseWheelNegativeDeltaOneEvent() {
        // Scrolling down with a mouse wheel is also a single event.
        let result = MouseScrollForwarder.mouseReportingScrollEvents(
            accumulatedDelta: 0,
            newDelta: -3,
            isPrecise: false,
            phaseBegan: false
        )
        #expect(result.events == 1)
        #expect(result.remainingDelta == 0)
    }

    @Test func mouseReportingMouseWheelIgnoresPhaseBegan() {
        // phaseBegan only matters for the precise accumulator; a mouse wheel
        // tick at gesture start is still one event with no remainder.
        let result = MouseScrollForwarder.mouseReportingScrollEvents(
            accumulatedDelta: 0,
            newDelta: 1,
            isPrecise: false,
            phaseBegan: true
        )
        #expect(result.events == 1)
        #expect(result.remainingDelta == 0)
    }

    // MARK: - Grid position edge cases (#551)

    @Test func gridPositionWithZeroDimensions() {
        // Zero cols/rows should return (0,0) without crashing
        let pos = MouseScrollForwarder.gridPosition(
            point: CGPoint(x: 100, y: 100),
            viewBounds: NSRect(x: 0, y: 0, width: 800, height: 300),
            cols: 0, rows: 0, isFlipped: true
        )
        #expect(pos.col == 0)
        #expect(pos.row == 0)
    }

    @Test func gridPositionWithZeroSizeView() {
        let pos = MouseScrollForwarder.gridPosition(
            point: CGPoint(x: 0, y: 0),
            viewBounds: NSRect(x: 0, y: 0, width: 0, height: 0),
            cols: 80, rows: 24, isFlipped: true
        )
        #expect(pos.col == 0)
        #expect(pos.row == 0)
    }

    @Test func gridPositionWithSingleCellTerminal() {
        // 1x1 terminal: any point should map to (0,0)
        let pos = MouseScrollForwarder.gridPosition(
            point: CGPoint(x: 50, y: 50),
            viewBounds: NSRect(x: 0, y: 0, width: 100, height: 100),
            cols: 1, rows: 1, isFlipped: true
        )
        #expect(pos.col == 0)
        #expect(pos.row == 0)
    }

    @Test func gridPositionMidPoint() {
        // Middle of an 80x24 terminal in an 800x240 view
        let pos = MouseScrollForwarder.gridPosition(
            point: CGPoint(x: 400, y: 120),
            viewBounds: NSRect(x: 0, y: 0, width: 800, height: 240),
            cols: 80, rows: 24, isFlipped: true
        )
        // cellWidth = 10, cellHeight = 10
        // col = Int(400/10) = 40, row = Int(120/10) = 12
        #expect(pos.col == 40)
        #expect(pos.row == 12)
    }

    @Test func gridPositionNonFlippedBottomLeft() {
        // In non-flipped, y=0 is bottom, so point at (0,0) should be last row
        let pos = MouseScrollForwarder.gridPosition(
            point: CGPoint(x: 0, y: 0),
            viewBounds: NSRect(x: 0, y: 0, width: 800, height: 240),
            cols: 80, rows: 24, isFlipped: false
        )
        #expect(pos.col == 0)
        #expect(pos.row == 23) // bottom of screen = last row
    }

    @Test func gridPositionNonFlippedTopRight() {
        // In non-flipped, y=max is top, so point at (0, 239) should be row 0
        let pos = MouseScrollForwarder.gridPosition(
            point: CGPoint(x: 0, y: 239),
            viewBounds: NSRect(x: 0, y: 0, width: 800, height: 240),
            cols: 80, rows: 24, isFlipped: false
        )
        #expect(pos.row == 0) // top of screen = first row
    }

    // MARK: - Normal-mode scrollback line calculation

    @Test func normalScrollTrackpadSingleLineThreshold() {
        let result = MouseScrollForwarder.normalScrollLines(
            accumulatedDelta: 0,
            newDelta: 10,
            isPrecise: true,
            phaseBegan: false
        )
        #expect(result.lines == 1)
        #expect(result.remainingDelta == 0)
    }

    @Test func normalScrollTrackpadMultipleLines() {
        let result = MouseScrollForwarder.normalScrollLines(
            accumulatedDelta: 0,
            newDelta: 35,
            isPrecise: true,
            phaseBegan: false
        )
        #expect(result.lines == 3)
        #expect(result.remainingDelta == 5)
    }

    @Test func normalScrollTrackpadAccumulation() {
        // First event: delta 6, below threshold
        let r1 = MouseScrollForwarder.normalScrollLines(
            accumulatedDelta: 0,
            newDelta: 6,
            isPrecise: true,
            phaseBegan: false
        )
        #expect(r1.lines == 0)
        #expect(r1.remainingDelta == 6)

        // Second event: delta 6, accumulated = 12, crosses threshold
        let r2 = MouseScrollForwarder.normalScrollLines(
            accumulatedDelta: r1.remainingDelta,
            newDelta: 6,
            isPrecise: true,
            phaseBegan: false
        )
        #expect(r2.lines == 1)
        #expect(r2.remainingDelta == 2)
    }

    @Test func normalScrollTrackpadPhaseBeganResetsAccumulation() {
        // phaseBegan = true ignores the accumulated delta and starts fresh
        let result = MouseScrollForwarder.normalScrollLines(
            accumulatedDelta: 999,
            newDelta: 5,
            isPrecise: true,
            phaseBegan: true
        )
        #expect(result.lines == 0)
        #expect(result.remainingDelta == 5)
    }

    @Test func normalScrollTrackpadNegativeDelta() {
        let result = MouseScrollForwarder.normalScrollLines(
            accumulatedDelta: 0,
            newDelta: -25,
            isPrecise: true,
            phaseBegan: false
        )
        #expect(result.lines == 2)
        #expect(result.remainingDelta == -5)
    }

    @Test func normalScrollTrackpadAlternatingDirection() {
        // Scroll up 15, then down 5 — remaining should be 5 (positive)
        let r1 = MouseScrollForwarder.normalScrollLines(
            accumulatedDelta: 0,
            newDelta: 15,
            isPrecise: true,
            phaseBegan: false
        )
        #expect(r1.lines == 1)
        #expect(r1.remainingDelta == 5)

        let r2 = MouseScrollForwarder.normalScrollLines(
            accumulatedDelta: r1.remainingDelta,
            newDelta: -5,
            isPrecise: true,
            phaseBegan: false
        )
        #expect(r2.lines == 0)
        #expect(r2.remainingDelta == 0)
    }

    @Test func normalScrollTrackpadTinyDeltaNoScroll() {
        let result = MouseScrollForwarder.normalScrollLines(
            accumulatedDelta: 0,
            newDelta: 3,
            isPrecise: true,
            phaseBegan: false
        )
        #expect(result.lines == 0)
        #expect(result.remainingDelta == 3)
    }

    @Test func normalScrollMouseWheelSmallDelta() {
        let result = MouseScrollForwarder.normalScrollLines(
            accumulatedDelta: 0,
            newDelta: 1,
            isPrecise: false,
            phaseBegan: false
        )
        #expect(result.lines == 1)
        #expect(result.remainingDelta == 0)
    }

    @Test func normalScrollMouseWheelMediumDelta() {
        let result = MouseScrollForwarder.normalScrollLines(
            accumulatedDelta: 0,
            newDelta: 2,
            isPrecise: false,
            phaseBegan: false
        )
        #expect(result.lines == 2)
        #expect(result.remainingDelta == 0)
    }

    @Test func normalScrollMouseWheelLargeDeltaCappedAt3() {
        let result = MouseScrollForwarder.normalScrollLines(
            accumulatedDelta: 0,
            newDelta: 15,
            isPrecise: false,
            phaseBegan: false
        )
        #expect(result.lines == 3)
        #expect(result.remainingDelta == 0)
    }

    @Test func normalScrollMouseWheelIgnoresAccumulation() {
        let result = MouseScrollForwarder.normalScrollLines(
            accumulatedDelta: 500,
            newDelta: 1,
            isPrecise: false,
            phaseBegan: false
        )
        // Mouse wheel never accumulates — ignores accumulated delta
        #expect(result.lines == 1)
        #expect(result.remainingDelta == 0)
    }

    @Test func normalScrollMouseWheelNegativeDelta() {
        let result = MouseScrollForwarder.normalScrollLines(
            accumulatedDelta: 0,
            newDelta: -3,
            isPrecise: false,
            phaseBegan: false
        )
        #expect(result.lines == 3)
    }

    @Test func normalScrollTrackpadLargeMomentumDelta() {
        // Simulates a large momentum event that would have scrolled
        // an entire page with SwiftTerm's default velocity.
        let result = MouseScrollForwarder.normalScrollLines(
            accumulatedDelta: 0,
            newDelta: 150,
            isPrecise: true,
            phaseBegan: false
        )
        // 150 / 10 = 15 lines — controlled, not a full page
        #expect(result.lines == 15)
        #expect(result.remainingDelta == 0)
    }

    @Test func normalScrollTrackpadCarriesRemainderAcrossEvents() {
        // Three events of delta 7 each: 7 → 14 → 21
        // 7/10=0, 14/10=1 (rem 4), 11/10=1 (rem 1)
        let r1 = MouseScrollForwarder.normalScrollLines(
            accumulatedDelta: 0, newDelta: 7, isPrecise: true, phaseBegan: false
        )
        #expect(r1.lines == 0)
        #expect(r1.remainingDelta == 7)

        let r2 = MouseScrollForwarder.normalScrollLines(
            accumulatedDelta: r1.remainingDelta, newDelta: 7, isPrecise: true, phaseBegan: false
        )
        #expect(r2.lines == 1)
        #expect(r2.remainingDelta == 4)

        let r3 = MouseScrollForwarder.normalScrollLines(
            accumulatedDelta: r2.remainingDelta, newDelta: 7, isPrecise: true, phaseBegan: false
        )
        #expect(r3.lines == 1)
        #expect(r3.remainingDelta == 1)
    }

    // MARK: - Alternate-screen arrow-key emission (#979)

    // The alternate-screen scroll path (TUI apps without mouse reporting:
    // vim/less/man, k9s without mouse) feeds `normalScrollLines` into an
    // arrow-key emitter: one `ESC O A`/`ESC O B` sequence per resulting line.
    // These tests verify that integration — the cadence matches normal-mode
    // scrollback (1 arrow per `trackpadLineThreshold` = 10 points) and residual
    // delta is preserved.

    @Test func alternateScreenArrowTrackpadBelowThresholdEmitsNothing() {
        // Precise delta < 10 → 0 arrows, remaining carried forward
        let result = MouseScrollForwarder.normalScrollLines(
            accumulatedDelta: 0, newDelta: 5, isPrecise: true, phaseBegan: false
        )
        let arrowCount = MouseScrollForwarder.arrowKeyCount(for: result)
        #expect(arrowCount == 0)
        #expect(result.remainingDelta == 5) // carried forward, not discarded
    }

    @Test func alternateScreenArrowTrackpadAccumulatedTo25EmitsTwoArrows() {
        // Precise delta = 25 → 2 arrows (25/10 = 2), remaining = 5
        let result = MouseScrollForwarder.normalScrollLines(
            accumulatedDelta: 0, newDelta: 25, isPrecise: true, phaseBegan: false
        )
        let arrowCount = MouseScrollForwarder.arrowKeyCount(for: result)
        #expect(arrowCount == 2)
        #expect(result.remainingDelta == 5) // overshoot preserved
    }

    @Test func alternateScreenArrowPhaseBeganResetsAccumulation() {
        // .began phase resets accumulation; previously accumulated 999 is
        // discarded instead of being added to the new delta.
        let result = MouseScrollForwarder.normalScrollLines(
            accumulatedDelta: 999, newDelta: 5, isPrecise: true, phaseBegan: true
        )
        let arrowCount = MouseScrollForwarder.arrowKeyCount(for: result)
        #expect(arrowCount == 0)
        #expect(result.remainingDelta == 5) // not 1004 — accumulation was reset
    }

    @Test func alternateScreenArrowMouseWheelEmitsOneToThreeArrows() {
        // Non-precise mouse wheel: 1..3 arrows scaled by delta magnitude.
        // This is an intentional behavior change from the previous code, which
        // always emitted exactly 1 arrow per tick — see PR body for rationale.
        let small = MouseScrollForwarder.normalScrollLines(
            accumulatedDelta: 0, newDelta: 1, isPrecise: false, phaseBegan: false
        )
        #expect(MouseScrollForwarder.arrowKeyCount(for: small) >= 1)
        #expect(small.remainingDelta == 0)

        let medium = MouseScrollForwarder.normalScrollLines(
            accumulatedDelta: 0, newDelta: 2, isPrecise: false, phaseBegan: false
        )
        #expect(MouseScrollForwarder.arrowKeyCount(for: medium) == 2)

        let large = MouseScrollForwarder.normalScrollLines(
            accumulatedDelta: 0, newDelta: 15, isPrecise: false, phaseBegan: false
        )
        #expect(MouseScrollForwarder.arrowKeyCount(for: large) == 3) // capped at 3
    }

    @Test func alternateScreenArrowDirectionDeterminesSequence() {
        // Direction determines ESC O A (up) vs ESC O B (down); count is symmetric.
        let up = MouseScrollForwarder.normalScrollLines(
            accumulatedDelta: 0, newDelta: 25, isPrecise: true, phaseBegan: false
        )
        let down = MouseScrollForwarder.normalScrollLines(
            accumulatedDelta: 0, newDelta: -25, isPrecise: true, phaseBegan: false
        )
        #expect(MouseScrollForwarder.arrowKeyCount(for: up) == 2)
        #expect(MouseScrollForwarder.arrowKeyCount(for: down) == 2)
        #expect(MouseScrollForwarder.arrowKeyForScroll(deltaY: 25) == "\u{1b}OA")
        #expect(MouseScrollForwarder.arrowKeyForScroll(deltaY: -25) == "\u{1b}OB")
    }

    @Test func alternateScreenArrowResidualCarriedAcrossEvents() {
        // Demonstrates residual preservation across events — the central fix.
        // Event 1: delta 12 → emit 1 arrow, remaining 2.
        // Event 2: delta 8 → accumulated 10 → emit 1 arrow, remaining 0.
        // With the old code (threshold 25, reset to 0), neither event would
        // have emitted any arrow key.
        let r1 = MouseScrollForwarder.normalScrollLines(
            accumulatedDelta: 0, newDelta: 12, isPrecise: true, phaseBegan: false
        )
        #expect(MouseScrollForwarder.arrowKeyCount(for: r1) == 1)
        #expect(r1.remainingDelta == 2)

        let r2 = MouseScrollForwarder.normalScrollLines(
            accumulatedDelta: r1.remainingDelta, newDelta: 8, isPrecise: true, phaseBegan: false
        )
        #expect(MouseScrollForwarder.arrowKeyCount(for: r2) == 1)
        #expect(r2.remainingDelta == 0)
    }

    // MARK: - Gesture phase boundary flush (#980)

    // On trackpad gesture end (phase `.ended`, including the final momentum
    // `.ended`), residual delta above the settle threshold
    // (`gestureEndSettleThreshold` = `trackpadLineThreshold / 2` = 5) is flushed
    // so the final partial line is committed instead of being silently dropped.
    // Residual below the settle threshold is dropped to avoid a stray twitch.
    // Because the per-event helpers always consume whole thresholds during the
    // gesture, the residual reaching `.ended` is below one full threshold, so
    // `flushResidual` returns 0 or 1.

    @Test func flushResidualAboveSettleThresholdCommitsOneLine() {
        // Residual 8 (>= settle 5) → commit the final partial line.
        #expect(MouseScrollForwarder.flushResidual(accumulatedDelta: 8) == 1)
        // Exactly at the settle boundary.
        #expect(MouseScrollForwarder.flushResidual(accumulatedDelta: 5) == 1)
        // Negative residual scrolls down and still commits.
        #expect(MouseScrollForwarder.flushResidual(accumulatedDelta: -8) == 1)
    }

    @Test func flushResidualBelowSettleThresholdDropsNothing() {
        // Residual 3 (< settle 5) → dropped to avoid a stray 1-line twitch.
        #expect(MouseScrollForwarder.flushResidual(accumulatedDelta: 3) == 0)
        // Just under the boundary.
        #expect(MouseScrollForwarder.flushResidual(accumulatedDelta: 4.9) == 0)
        // Zero residual → nothing to flush.
        #expect(MouseScrollForwarder.flushResidual(accumulatedDelta: 0) == 0)
        // Small negative residual → also dropped.
        #expect(MouseScrollForwarder.flushResidual(accumulatedDelta: -2) == 0)
    }

    @Test func flushResidualCustomSettleThreshold() {
        // A custom settle threshold changes the gate but still returns 0/1 for
        // sub-threshold residuals.
        #expect(MouseScrollForwarder.flushResidual(accumulatedDelta: 4, settleThreshold: 4) == 1)
        #expect(MouseScrollForwarder.flushResidual(accumulatedDelta: 3.9, settleThreshold: 4) == 0)
    }

    // The following tests simulate full synthetic gesture sequences — threading
    // residual delta through the per-event helpers, then flushing on `.ended` —
    // exactly as `TerminalContainerView.installScrollMonitor` does at runtime.

    @Test func gestureEndFlushCommitsFinalPartialLine() {
        // Sequence: .began(delta 8) → 0 lines, residual 8. Then .ended carries
        // delta 0: normalScrollLines keeps residual 8, then flushResidual(8)
        // commits the final partial line. The last line the user intended is
        // not lost.
        let began = MouseScrollForwarder.normalScrollLines(
            accumulatedDelta: 0, newDelta: 8, isPrecise: true, phaseBegan: true
        )
        #expect(began.lines == 0)
        #expect(began.remainingDelta == 8)

        let ended = MouseScrollForwarder.normalScrollLines(
            accumulatedDelta: began.remainingDelta, newDelta: 0, isPrecise: true, phaseBegan: false
        )
        #expect(ended.lines == 0)
        #expect(ended.remainingDelta == 8)

        let flushCount = MouseScrollForwarder.flushResidual(accumulatedDelta: ended.remainingDelta)
        #expect(flushCount == 1)
    }

    @Test func gestureEndWithTinyResidualEmitsNothing() {
        // Sequence: .began(delta 3) → 0 lines, residual 3. .ended → residual
        // still 3, below settle threshold → no spurious emit (no twitch).
        let began = MouseScrollForwarder.normalScrollLines(
            accumulatedDelta: 0, newDelta: 3, isPrecise: true, phaseBegan: true
        )
        let ended = MouseScrollForwarder.normalScrollLines(
            accumulatedDelta: began.remainingDelta, newDelta: 0, isPrecise: true, phaseBegan: false
        )
        let flushCount = MouseScrollForwarder.flushResidual(accumulatedDelta: ended.remainingDelta)
        #expect(flushCount == 0)
    }

    @Test func mouseReportingGestureEndFlushCommitsFinalEvent() {
        // Mouse-reporting path: .began(delta 8) → 0 events, residual 8. .ended
        // → flushResidual(8) commits one final VT100 mouse-button event.
        let began = MouseScrollForwarder.mouseReportingScrollEvents(
            accumulatedDelta: 0, newDelta: 8, isPrecise: true, phaseBegan: true
        )
        #expect(began.events == 0)
        #expect(began.remainingDelta == 8)

        let flushCount = MouseScrollForwarder.flushResidual(accumulatedDelta: began.remainingDelta)
        #expect(flushCount == 1)
    }

    @Test func momentumContinuesUnderSamePerLineThreshold() {
        // After the main gesture `.ended` flushes and resets the accumulator to
        // 0, momentum `.changed` events accumulate under the SAME per-line
        // threshold (no cap, no multiply). Then the momentum `.ended` flushes
        // its own residual.
        //
        // Main gesture: .began(8) → residual 8, flush → 1 line, reset to 0.
        let began = MouseScrollForwarder.normalScrollLines(
            accumulatedDelta: 0, newDelta: 8, isPrecise: true, phaseBegan: true
        )
        let mainFlush = MouseScrollForwarder.flushResidual(accumulatedDelta: began.remainingDelta)
        #expect(mainFlush == 1)
        // Accumulator reset to 0 on .ended (runtime does this).
        var residual: CGFloat = 0

        // Momentum .changed(12) → 1 line (12/10), residual 2 — same threshold.
        let momentum = MouseScrollForwarder.normalScrollLines(
            accumulatedDelta: residual, newDelta: 12, isPrecise: true, phaseBegan: false
        )
        #expect(momentum.lines == 1)
        #expect(momentum.remainingDelta == 2)
        residual = momentum.remainingDelta

        // Momentum .ended → residual 2 below settle → no flush.
        let momentumFlush = MouseScrollForwarder.flushResidual(accumulatedDelta: residual)
        #expect(momentumFlush == 0)
    }

    @Test func beganResetsStaleAccumulatorFromPreviousGesture() {
        // A previous gesture leaves a stale residual of 7. A new gesture starts
        // with .began(delta 4): phaseBegan discards the stale 7 and seeds 4,
        // so no phantom jump carries over from the old gesture.
        let staleResidual: CGFloat = 7
        let newBegan = MouseScrollForwarder.normalScrollLines(
            accumulatedDelta: staleResidual, newDelta: 4, isPrecise: true, phaseBegan: true
        )
        #expect(newBegan.lines == 0)
        #expect(newBegan.remainingDelta == 4) // not 11 — stale residual discarded
    }

    @Test func fullGestureSequenceAccumulatesThenFlushes() {
        // End-to-end: .began(7) → .changed(7) → .ended, simulating a flick.
        // .began(7): reset, residual 7, 0 lines.
        let r0 = MouseScrollForwarder.normalScrollLines(
            accumulatedDelta: 0, newDelta: 7, isPrecise: true, phaseBegan: true
        )
        #expect(r0.lines == 0)
        #expect(r0.remainingDelta == 7)
        // .changed(7): accumulated 14 → 1 line, residual 4.
        let r1 = MouseScrollForwarder.normalScrollLines(
            accumulatedDelta: r0.remainingDelta, newDelta: 7, isPrecise: true, phaseBegan: false
        )
        #expect(r1.lines == 1)
        #expect(r1.remainingDelta == 4)
        // .ended: residual 4 < settle 5 → no flush. Final tally: 1 line.
        let flush = MouseScrollForwarder.flushResidual(accumulatedDelta: r1.remainingDelta)
        #expect(flush == 0)

        // Contrast: .began(7) → .changed(8) → .ended leaves residual 5.
        let s0 = MouseScrollForwarder.normalScrollLines(
            accumulatedDelta: 0, newDelta: 7, isPrecise: true, phaseBegan: true
        )
        let s1 = MouseScrollForwarder.normalScrollLines(
            accumulatedDelta: s0.remainingDelta, newDelta: 8, isPrecise: true, phaseBegan: false
        )
        #expect(s1.lines == 1)
        #expect(s1.remainingDelta == 5)
        // .ended: residual 5 >= settle 5 → flush 1 line. Final tally: 2 lines.
        let flush2 = MouseScrollForwarder.flushResidual(accumulatedDelta: s1.remainingDelta)
        #expect(flush2 == 1)
    }

    @Test func gestureEndFlushAfterMultipleChangedEvents() {
        // Issue #980 requires ".began + several .changed + .ended with residual"
        // to assert the final flush count. Multiple .changed(3) events accumulate
        // below the per-line threshold so 0 lines are emitted during the gesture,
        // and the residual crosses the settle threshold only at .ended.
        // Math: 3 → 6 → 9, none crosses threshold 10, so 0 per-event lines and
        // residual 9 at .ended; 9 ≥ 5 settle → flush 1.
        let r0 = MouseScrollForwarder.normalScrollLines(
            accumulatedDelta: 0, newDelta: 3, isPrecise: true, phaseBegan: true
        )
        #expect(r0.lines == 0)
        #expect(r0.remainingDelta == 3)

        let r1 = MouseScrollForwarder.normalScrollLines(
            accumulatedDelta: r0.remainingDelta, newDelta: 3, isPrecise: true, phaseBegan: false
        )
        #expect(r1.lines == 0)
        #expect(r1.remainingDelta == 6)

        let r2 = MouseScrollForwarder.normalScrollLines(
            accumulatedDelta: r1.remainingDelta, newDelta: 3, isPrecise: true, phaseBegan: false
        )
        #expect(r2.lines == 0)
        #expect(r2.remainingDelta == 9)

        // .ended carries delta 0: residual stays 9, no per-event line.
        let rEnd = MouseScrollForwarder.normalScrollLines(
            accumulatedDelta: r2.remainingDelta, newDelta: 0, isPrecise: true, phaseBegan: false
        )
        #expect(rEnd.lines == 0)
        #expect(rEnd.remainingDelta == 9)

        // .ended flush: residual 9 ≥ settle 5 → commit the final partial line.
        let flushCount = MouseScrollForwarder.flushResidual(accumulatedDelta: rEnd.remainingDelta)
        #expect(flushCount == 1)
    }
}
