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

    // NOTE: Velocity threshold tests are in the "Scroll velocity threshold tests (#551)" section below.

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

    // MARK: - Scroll velocity edge cases

    @Test func scrollVelocityForNegativeDelta() {
        let velocity = MouseScrollForwarder.scrollVelocity(delta: -3.0)
        #expect(velocity == 3)
    }

    @Test func scrollVelocityForNegativeLargeDelta() {
        let velocity = MouseScrollForwarder.scrollVelocity(delta: -10.0)
        #expect(velocity == 3)
    }

    // NOTE: Scroll velocity boundary and grid position edge case tests
    // are in the "#551" sections below — duplicates removed.

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

    // MARK: - Scroll velocity threshold tests (#551)

    @Test func scrollVelocityAtExactThresholdOne() {
        // delta exactly 1.0 → absDelta is 1.0, not > 1 → velocity = 1
        let v = MouseScrollForwarder.scrollVelocity(delta: 1.0)
        #expect(v == 1)
    }

    @Test func scrollVelocityJustAboveThresholdOne() {
        // delta 1.01 → absDelta > 1 → velocity = Int(min(1.01, 3)) = 1
        let v = MouseScrollForwarder.scrollVelocity(delta: 1.01)
        #expect(v == 1)
    }

    @Test func scrollVelocityAtExactThresholdFive() {
        // delta exactly 5.0 → absDelta is 5.0, which is > 1 but not > 5 → velocity = Int(min(5.0, 3)) = 3
        let v = MouseScrollForwarder.scrollVelocity(delta: 5.0)
        #expect(v == 3)
    }

    @Test func scrollVelocityJustAboveThresholdFive() {
        // delta 5.01 → absDelta > 5 → velocity = 3
        let v = MouseScrollForwarder.scrollVelocity(delta: 5.01)
        #expect(v == 3)
    }

    @Test func scrollVelocityWithNegativeDelta() {
        // Negative deltas should use abs() and produce same velocities
        #expect(MouseScrollForwarder.scrollVelocity(delta: -1.0) == 1)
        #expect(MouseScrollForwarder.scrollVelocity(delta: -3.0) == 3)
        #expect(MouseScrollForwarder.scrollVelocity(delta: -7.0) == 3)
    }

    @Test func scrollVelocityForMediumValues() {
        // delta 2.0 → absDelta > 1, not > 5 → Int(min(2.0, 3)) = 2
        #expect(MouseScrollForwarder.scrollVelocity(delta: 2.0) == 2)
        // delta 2.5 → Int(min(2.5, 3)) = 2
        #expect(MouseScrollForwarder.scrollVelocity(delta: 2.5) == 2)
    }

    @Test func scrollVelocityNeverExceedsThree() {
        // Even with extremely large deltas, velocity should cap at 3
        let v = MouseScrollForwarder.scrollVelocity(delta: 1000.0)
        #expect(v == 3)
        let vNeg = MouseScrollForwarder.scrollVelocity(delta: -1000.0)
        #expect(vNeg == 3)
    }

    @Test func scrollVelocityIsAlwaysAtLeastOne() {
        // Even for tiny deltas, velocity should be at least 1
        #expect(MouseScrollForwarder.scrollVelocity(delta: 0.001) >= 1)
        #expect(MouseScrollForwarder.scrollVelocity(delta: -0.001) >= 1)
        #expect(MouseScrollForwarder.scrollVelocity(delta: 0.0) >= 1)
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
}
