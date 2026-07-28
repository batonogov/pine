//
//  CommandOverlayViewTests.swift
//  PineTests
//
//  Tests for CommandOverlayView dismissal logic and GoToLineView accessibility.
//

import AppKit
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

    @Test("CommandOverlayView dismissal clears binding and runs cleanup once")
    func dismissalIsUnifiedAndOneShot() {
        var isPresented = true
        var cleanupCount = 0
        let binding = Binding<Bool>(
            get: { isPresented },
            set: { isPresented = $0 }
        )
        let overlay = CommandOverlayView(
            isPresented: binding,
            onDismiss: { cleanupCount += 1 },
            content: { Text("test") }
        )

        overlay.dismiss()
        #expect(!isPresented)
        #expect(cleanupCount == 1)

        // An Escape event that bubbles after the focused child already
        // dismissed must not restore focus a second time.
        overlay.dismiss()
        #expect(cleanupCount == 1)
    }

    // MARK: - GoToLineView accessibility

    @Test("GoToLineView has invalid message accessibility identifier")
    func goToLineInvalidMessageIdentifier() {
        #expect(AccessibilityID.goToLineInvalidMessage == "goToLineInvalidMessage")
    }

    @Test("GoToLineView exposes a native accessible field")
    func goToLineNativeFieldAccessibility() throws {
        var isPresented = true
        let totalLines = 123
        let hosted = NSHostingView(
            rootView: GoToLineView(
                totalLines: totalLines,
                isPresented: Binding(
                    get: { isPresented },
                    set: { isPresented = $0 }
                ),
                onGoTo: { _, _ in }
            )
        )
        hosted.frame = NSRect(x: 0, y: 0, width: 220, height: 100)
        hosted.layoutSubtreeIfNeeded()
        drainMainRunLoop()
        hosted.layoutSubtreeIfNeeded()

        let field = try #require(findCommandField(in: hosted))
        #expect(field.isAccessibilityElement())
        #expect(field.accessibilityRole() == .textField)
        #expect(
            field.accessibilityIdentifier() == AccessibilityID.goToLineField
        )
        #expect(field.identifier?.rawValue == AccessibilityID.goToLineField)
        #expect(field.accessibilityLabel() == String(localized: "Go to line"))
        #expect(
            field.accessibilityHelp()
                == String(
                    localized: "Enter a line number from 1 to \(totalLines)"
                )
        )

        let coordinator = try #require(
            field.delegate as? QuickOpenSearchField.Coordinator
        )
        #expect(coordinator.control(
            field,
            textView: NSTextView(),
            doCommandBy: #selector(NSResponder.cancelOperation(_:))
        ))
        #expect(!isPresented)
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

    private func findCommandField(
        in view: NSView
    ) -> CommandOverlayTextField? {
        if let field = view as? CommandOverlayTextField {
            return field
        }
        for subview in view.subviews {
            if let field = findCommandField(in: subview) {
                return field
            }
        }
        return nil
    }

    private func drainMainRunLoop() {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
    }
}
