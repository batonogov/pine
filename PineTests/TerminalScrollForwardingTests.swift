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

    @Test func encodesControlModifier() {
        let flags = MouseScrollForwarder.encodeScrollButton(
            deltaY: -1.0,
            shift: false,
            option: false,
            control: true
        )
        // 65 (scroll down) | 16 (control) = 81
        #expect(flags == 81)
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

    @Test func nonFlippedCoordinateSystem() {
        // In non-flipped coordinate system, y=0 is bottom
        let pos = MouseScrollForwarder.gridPosition(
            point: CGPoint(x: 0, y: 299),
            viewBounds: NSRect(x: 0, y: 0, width: 800, height: 300),
            cols: 80,
            rows: 24,
            isFlipped: false
        )
        // y=299 in non-flipped means top of view = row 0
        #expect(pos.row == 0)
    }

    @Test func scrollVelocityForSmallDelta() {
        let velocity = MouseScrollForwarder.scrollVelocity(delta: 1.0)
        #expect(velocity == 1)
    }

    @Test func scrollVelocityForMediumDelta() {
        let velocity = MouseScrollForwarder.scrollVelocity(delta: 3.0)
        #expect(velocity == 3)
    }

    @Test func scrollVelocityForLargeDelta() {
        let velocity = MouseScrollForwarder.scrollVelocity(delta: 7.0)
        #expect(velocity >= 3)
    }

    @Test func scrollVelocityForZeroDelta() {
        let velocity = MouseScrollForwarder.scrollVelocity(delta: 0.0)
        #expect(velocity == 1)
    }

    // MARK: - TerminalContainerView scroll forwarding integration

    @Test func containerViewIsFlipped() {
        let container = TerminalContainerView()
        #expect(container.isFlipped == true)
    }
}
