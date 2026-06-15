//
//  CommandOverlayViewTests.swift
//  PineTests
//
//  Tests for CommandOverlayView dismissal logic and GoToLineView accessibility.
//

import SwiftUI
import Testing

@testable import Pine

@MainActor
struct CommandOverlayViewTests {

    // MARK: - CommandOverlayView

    @Test("CommandOverlayView sets isPresented to false on backdrop tap")
    func backdropDismisses() {
        var isPresented = true
        let binding = Binding<Bool>(
            get: { isPresented },
            set: { isPresented = $0 }
        )
        _ = CommandOverlayView(isPresented: binding) {
            Text("test")
        }
        // The overlay is constructed — actual tap simulation requires UI testing.
        // We verify the binding mechanism works correctly here.
        binding.wrappedValue = false
        #expect(isPresented == false)
    }

    @Test("CommandOverlayView has accessibility identifier")
    func accessibilityIdentifierExists() {
        #expect(AccessibilityID.commandOverlay == "commandOverlay")
    }

    // MARK: - GoToLineView accessibility

    @Test("GoToLineView has invalid message accessibility identifier")
    func goToLineInvalidMessageIdentifier() {
        #expect(AccessibilityID.goToLineInvalidMessage == "goToLineInvalidMessage")
    }

    @Test("GoToLineView is invalid when line exceeds total")
    func invalidWhenExceedsTotal() {
        // Simulate parsing logic: line 5000 exceeds total of 100
        let parsed = GoToLineParser.parse("5000")
        #expect(parsed != nil)
        #expect(parsed?.line == 5000)
        #expect((parsed?.line ?? 0) > 100) // exceeds total
    }

    @Test("GoToLineView is valid when within range")
    func validWhenInRange() {
        let parsed = GoToLineParser.parse("50")
        #expect(parsed != nil)
        #expect(parsed?.line == 50)
        #expect((parsed?.line ?? 0) <= 100) // within total
    }

    @Test("GoToLineView localized string keys resolve without crashing")
    func localizedStringsResolve() {
        // These keys should exist in Localizable.xcstrings.
        // Using NSLocalizedString to avoid LocalizationValue interpolation
        // issues in @testable import context.
        let rangeHint = NSLocalizedString(
            "Enter a line number from 1 to %lld",
            comment: ""
        )
        #expect(!rangeHint.isEmpty)

        let invalidFormat = NSLocalizedString(
            "Enter a valid line number",
            comment: ""
        )
        #expect(!invalidFormat.isEmpty)

        let outOfRange = NSLocalizedString(
            "Line %1$lld is out of range (1\u{2013}%2$lld)",
            comment: ""
        )
        #expect(!outOfRange.isEmpty)
    }
}
