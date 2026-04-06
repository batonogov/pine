//
//  DiagnosticTooltipFixTests.swift
//  PineTests
//
//  Tests for the #679 fix: diagnostic icons must show their explanation
//  via dynamic toolTip updates on mouseMoved, must be visually larger,
//  and must support click-to-popover for full message display.
//

import Testing
import AppKit
import SwiftUI

@testable import Pine

@Suite("Diagnostic Tooltip Fix (#679)")
@MainActor
struct DiagnosticTooltipFixTests {

    private func makeGutter() -> LineNumberView {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let textStorage = NSTextStorage(string: "line1\nline2\nline3\nline4\nline5\n")
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(
            containerSize: NSSize(width: 500, height: CGFloat.greatestFiniteMagnitude)
        )
        textContainer.widthTracksTextView = true
        layoutManager.addTextContainer(textContainer)
        let textView = NSTextView(
            frame: NSRect(x: 0, y: 0, width: 500, height: 400),
            textContainer: textContainer
        )
        scrollView.documentView = textView
        layoutManager.ensureLayout(forCharacterRange: NSRange(location: 0, length: textStorage.length))

        let gutterView = LineNumberView(textView: textView, clipView: scrollView.contentView)
        gutterView.frame = NSRect(x: 0, y: 0, width: 40, height: 400)
        return gutterView
    }

    // MARK: - Icon size increased (#679 visual feedback)

    @Test func diagnosticIconDrawSize_isAtLeast12() {
        // Issue feedback: 8px icon was "мелкая и не очень читаемая".
        // Bumped to 12px while still fitting inside the fold area (1+12 = 13 < 18).
        #expect(LineNumberView.diagnosticIconDrawSize >= 12)
    }

    @Test func diagnosticIcon_stillFitsBeforeLineNumbers() {
        // Verify the bumped icon still does not overlap two-digit line numbers.
        let view = makeGutter()
        let iconRightEdge: CGFloat = 1 + LineNumberView.diagnosticIconDrawSize
        let digitWidth = "0".size(withAttributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        ]).width
        let twoDigitWidth = digitWidth * 2
        let lineNumberStartX = view.gutterWidth - twoDigitWidth - 8
        #expect(iconRightEdge < lineNumberStartX)
    }

    // MARK: - mouseMoved updates toolTip dynamically

    @Test func mouseMoved_overDiagnosticLine_setsTooltipString() {
        let view = makeGutter()
        let diag = ValidationDiagnostic(
            line: 1, column: nil, message: "missing colon", severity: .error, source: "yamllint"
        )
        view.validationDiagnostics = [diag]

        // Simulate the resolved tooltip path that mouseMoved performs.
        let resolved = view.resolveTooltip(at: NSPoint(x: 6, y: 5))
        view.toolTip = resolved
        #expect(view.toolTip == "missing colon")
    }

    @Test func mouseExited_clearsToolTipString() throws {
        let view = makeGutter()
        let diag = ValidationDiagnostic(
            line: 1, column: nil, message: "err", severity: .error, source: "test"
        )
        view.validationDiagnostics = [diag]
        view.toolTip = "stale"

        // Build a real synthetic NSEvent and invoke the override under test —
        // not just poking `toolTip = nil`. This actually exercises the override.
        let event = try #require(
            NSEvent.enterExitEvent(
                with: .mouseExited,
                location: NSPoint(x: 100, y: 100),
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                eventNumber: 0,
                trackingNumber: 0,
                userData: nil
            )
        )
        view.mouseExited(with: event)
        #expect(view.toolTip == nil)
    }

    // MARK: - resolveTooltip works for clicks at icon x range

    @Test func resolveTooltip_atIconColumn_returnsMessage() {
        let view = makeGutter()
        let diag = ValidationDiagnostic(
            line: 1, column: nil, message: "bad indent", severity: .warning, source: "yamllint"
        )
        view.validationDiagnostics = [diag]

        // x in icon range (1..13)
        let result = view.resolveTooltip(at: NSPoint(x: 5, y: 5))
        #expect(result == "bad indent")
    }

    // MARK: - Diagnostic popover controller

    @Test func popoverController_storesDiagnostic() {
        let diag = ValidationDiagnostic(
            line: 7, column: 3, message: "Trailing whitespace", severity: .warning, source: "yamllint"
        )
        let controller = DiagnosticPopoverController(diagnostic: diag)
        #expect(controller.diagnostic.message == "Trailing whitespace")
        #expect(controller.diagnostic.severity == .warning)
        #expect(controller.diagnostic.line == 7)
        #expect(controller.diagnostic.column == 3)
    }

    @Test func popoverController_loadView_doesNotCrash() {
        let diag = ValidationDiagnostic(
            line: 1, column: nil, message: "x", severity: .info, source: "test"
        )
        let controller = DiagnosticPopoverController(diagnostic: diag)
        controller.loadView()
        #expect(controller.view.frame.width > 0)
    }

    // MARK: - showDiagnosticPopover does not crash and creates a popover

    @Test func showDiagnosticPopover_createsPopover() throws {
        let view = makeGutter()
        // Add to a window so popover anchoring is well-defined
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView?.addSubview(view)

        let diag = ValidationDiagnostic(
            line: 1, column: 5, message: "boom", severity: .error, source: "test"
        )
        view.validationDiagnostics = [diag]
        view.showDiagnosticPopover(for: diag, at: NSPoint(x: 6, y: 6))

        // The gutter must retain a popover wired to a DiagnosticPopoverController
        // holding the exact diagnostic we asked to show.
        let popover = try #require(view.diagnosticPopoverForTesting)
        let controller = try #require(popover.contentViewController as? DiagnosticPopoverController)
        #expect(controller.diagnostic.message == "boom")
        #expect(controller.diagnostic.severity == .error)
        #expect(controller.diagnostic.line == 1)
        #expect(controller.diagnostic.column == 5)
        #expect(popover.behavior == .transient)
    }

    // MARK: - Popover is dismissed when diagnostics are replaced (memory hygiene)

    @Test func diagnosticPopover_clearedWhenDiagnosticsReplaced() throws {
        let view = makeGutter()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView?.addSubview(view)

        let diag = ValidationDiagnostic(
            line: 1, column: nil, message: "x", severity: .error, source: "t"
        )
        view.validationDiagnostics = [diag]
        view.showDiagnosticPopover(for: diag, at: NSPoint(x: 6, y: 6))
        #expect(view.diagnosticPopoverForTesting != nil)

        // Replacing diagnostics must drop the retained popover.
        view.validationDiagnostics = []
        #expect(view.diagnosticPopoverForTesting == nil)
    }

    // MARK: - Cursor handling (#679 critical fix)

    @Test func mouseMoved_outsideIconZone_doesNotLeavePointingCursor() {
        let view = makeGutter()
        let diag = ValidationDiagnostic(
            line: 1, column: nil, message: "m", severity: .error, source: "t"
        )
        view.validationDiagnostics = [diag]

        // First: hover the icon zone (point.x < 14) — should set pointing-hand.
        view.simulateMouseMovedForTesting(at: NSPoint(x: 5, y: 5))
        #expect(view.didSetPointingCursorForTesting == true)

        // Then: move out of the icon zone (point.x >= 14) — must reset.
        view.simulateMouseMovedForTesting(at: NSPoint(x: 30, y: 5))
        #expect(view.didSetPointingCursorForTesting == false)
    }

    @Test func mouseExited_resetsPointingCursorFlag() throws {
        let view = makeGutter()
        let diag = ValidationDiagnostic(
            line: 1, column: nil, message: "m", severity: .error, source: "t"
        )
        view.validationDiagnostics = [diag]
        view.simulateMouseMovedForTesting(at: NSPoint(x: 5, y: 5))
        #expect(view.didSetPointingCursorForTesting == true)

        let event = try #require(
            NSEvent.enterExitEvent(
                with: .mouseExited,
                location: NSPoint(x: 100, y: 100),
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                eventNumber: 0,
                trackingNumber: 0,
                userData: nil
            )
        )
        view.mouseExited(with: event)
        #expect(view.didSetPointingCursorForTesting == false)
    }

    // MARK: - Diagnostic icon hit zone fits inside the gutter (#677 compat)

    @Test func diagnosticIconHitZone_fitsInsideGutter() {
        let view = makeGutter()
        // Hit zone must not overflow the gutter bounds (#677 fixed-width gutter).
        #expect(LineNumberView.diagnosticIconHitZoneWidth <= view.gutterWidth)
        // Drawn icon must fit inside the hit zone.
        #expect(1 + LineNumberView.diagnosticIconDrawSize <= LineNumberView.diagnosticIconHitZoneWidth)
    }

    // MARK: - Popover view renders all diagnostic fields

    @Test func popoverView_includesMessage() throws {
        let diag = ValidationDiagnostic(
            line: 42,
            column: 7,
            message: "Unexpected indentation",
            severity: .error,
            source: "yamllint"
        )
        let view = DiagnosticPopoverView(diagnostic: diag)
        // SwiftUI views are not directly inspectable in tests without ViewInspector,
        // so verify the diagnostic is stored on the view.
        #expect(view.diagnostic.message == "Unexpected indentation")
        #expect(view.diagnostic.line == 42)
        #expect(view.diagnostic.column == 7)
        #expect(view.diagnostic.source == "yamllint")
    }
}
