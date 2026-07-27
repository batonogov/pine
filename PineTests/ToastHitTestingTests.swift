//
//  ToastHitTestingTests.swift
//  PineTests
//
//  Tests for the toast overlay hit-testing policy (issue #1247).
//
//  The overlay must never block clicks in the editor, sidebar, or terminal.
//  Only the visible toast card (and its dismiss button) participates in hit
//  testing. These tests assert the declarative policy captured in
//  `ToastHitTesting` without rendering a SwiftUI view.
//

import Testing

@testable import Pine

@Suite("Toast Hit Testing")
struct ToastHitTestingTests {

    // MARK: - Container (full-window clear layer)

    @Test("Container never intercepts clicks, even with a toast visible")
    func containerAlwaysNonInteractive() {
        #expect(ToastHitTesting.containerAllowsHitTesting == false)
    }

    // MARK: - Card

    @Test("Toast card participates in hit testing")
    func cardInteractive() {
        #expect(ToastHitTesting.cardAllowsHitTesting == true)
    }

    @Test("Card hit-testing is gated on visibility")
    func cardHitTestingGatedOnVisibility() {
        #expect(ToastHitTesting.cardHitTesting(isToastVisible: true) == true)
        #expect(ToastHitTesting.cardHitTesting(isToastVisible: false) == false)
    }

    // MARK: - Non-blocking guarantee

    @Test("When a toast is visible, only the card blocks; the container does not")
    func nonBlockingWhileVisible() {
        // The defining property of the fix: visibility enables the card but
        // never the full-window container.
        let visible = true
        #expect(ToastHitTesting.containerAllowsHitTesting == false)
        #expect(ToastHitTesting.cardHitTesting(isToastVisible: visible) == true)
    }

    @Test("When no toast is visible, nothing intercepts clicks")
    func fullyTransparentWhenEmpty() {
        let visible = false
        #expect(ToastHitTesting.containerAllowsHitTesting == false)
        #expect(ToastHitTesting.cardHitTesting(isToastVisible: visible) == false)
    }
}
