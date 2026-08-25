//
//  AgentHistoryUndoReviewHostedTests.swift
//  PineTests
//

import AppKit
import SwiftUI
import Testing

@testable import Pine

@Suite("Agent History Undo Review hosted controls", .serialized)
@MainActor
struct AgentHistoryUndoReviewHostedTests {
    /// Return used to apply a bulk file rewrite (#1541). Apply carried
    /// `.keyboardShortcut(.defaultAction)` while the button beside it carried
    /// `.cancelAction`, so the sheet answered the most reflexive key on the
    /// keyboard by overwriting files in the workspace — the exact shape
    /// `AlertTemplate` forbids for every `NSAlert` in the app, and that
    /// `RecoveryDialogChoice` restates for the crash-recovery sheet.
    @Test("Ready review answers Return by closing, never by applying")
    func readyControls() throws {
        let activation = ActivationRecorder()
        let presented = PresentedState()
        let hosted = host(
            result: .available(
                AgentHistoryUndoReviewTestFixtures.mixedContentModel()
            ),
            phase: .ready,
            isPresented: presented.binding,
            onApplyActivation: activation.record
        )
        defer { hosted.window.close() }

        sendReturn(to: hosted.window)
        #expect(
            activation.isEmpty,
            "Return must never start a bulk file rewrite"
        )
        #expect(
            !presented.value,
            "Return must answer this sheet by closing it safely"
        )

        // Escape keeps doing what it always did, on its own instance so the
        // Return path above cannot be what closed it.
        let dismissState = PresentedState()
        let dismissActivation = ActivationRecorder()
        let dismissHost = host(
            result: .available(
                AgentHistoryUndoReviewTestFixtures.mixedContentModel()
            ),
            phase: .ready,
            isPresented: dismissState.binding,
            onApplyActivation: dismissActivation.record
        )
        defer { dismissHost.window.close() }
        sendEscape(to: dismissHost.window)
        #expect(!dismissState.value)
        #expect(dismissActivation.isEmpty)
    }

    @Test("Applying review disables Apply and every dismiss path")
    func applyingControlsAreLocked() throws {
        let model = AgentHistoryUndoReviewTestFixtures.mixedContentModel()
        let activation = ActivationRecorder()
        let presented = PresentedState()
        let hosted = host(
            result: .available(model),
            phase: .applying,
            revalidation: .available(model),
            isPresented: presented.binding,
            onApplyActivation: activation.record
        )
        defer { hosted.window.close() }

        sendReturn(to: hosted.window)
        sendEscape(to: hosted.window)

        #expect(activation.isEmpty)
        #expect(presented.value)
    }

    @Test("Stale review omits Apply and keeps safe dismissal available")
    func staleControls() throws {
        let failure = AgentHistoryUndoPreviewFailure.workspaceChanged
        let activation = ActivationRecorder()
        let presented = PresentedState()
        let hosted = host(
            result: .unavailable(failure),
            phase: .blocked(failure),
            isPresented: presented.binding,
            onApplyActivation: activation.record
        )
        defer { hosted.window.close() }

        sendReturn(to: hosted.window)
        #expect(activation.isEmpty)
        #expect(!presented.value, "Return dismisses a sheet with no Apply")

        let escapeState = PresentedState()
        let escapeHost = host(
            result: .unavailable(failure),
            phase: .blocked(failure),
            isPresented: escapeState.binding,
            onApplyActivation: activation.record
        )
        defer { escapeHost.window.close() }
        sendEscape(to: escapeHost.window)
        #expect(!escapeState.value)
        #expect(activation.isEmpty)
    }

    @Test("Review accessibility identifiers are stable and distinct")
    func accessibilityContract() {
        let fixed = [
            AccessibilityID.agentHistoryUndoReview,
            AccessibilityID.agentHistoryUndoReviewSummary,
            AccessibilityID.agentHistoryUndoReviewStale,
            AccessibilityID.agentHistoryUndoReviewApply,
            AccessibilityID.agentHistoryUndoReviewHeaderDismiss,
            AccessibilityID.agentHistoryUndoReviewFooterDismiss,
            AccessibilityID.agentHistoryUndoReviewProgress
        ]
        #expect(Set(fixed).count == fixed.count)
        #expect(
            AccessibilityID.agentHistoryUndoReviewOperation(
                "Assets/logo.bin"
            ) == "agentHistoryUndoReviewOperation_Assets/logo.bin"
        )
        #expect(
            AccessibilityID.agentHistoryUndoReviewOperation(
                "Sources/Generated.swift"
            ) == "agentHistoryUndoReviewOperation_Sources/Generated.swift"
        )
    }

    private struct HostedReview {
        let window: NSWindow
    }

    private final class HostedTestWindow: NSWindow {
        override var canBecomeKey: Bool { true }
    }

    private final class ActivationRecorder {
        private var activations: [Bool] = []
        var count: Int { activations.count }
        var isEmpty: Bool { activations.isEmpty }

        func record() {
            activations.append(true)
        }
    }

    private final class PresentedState {
        var value = true

        var binding: Binding<Bool> {
            Binding(
                get: { self.value },
                set: { self.value = $0 }
            )
        }
    }

    private func host(
        result: AgentHistoryUndoPreviewResult,
        phase: AgentHistoryUndoReviewActionGate.Phase,
        revalidation: AgentHistoryUndoPreviewResult? = nil,
        isPresented: Binding<Bool> = .constant(true),
        onApplyActivation: @escaping () -> Void = {}
    ) -> HostedReview {
        let root = AgentHistoryUndoReviewView(
            previewResult: result,
            phase: phase,
            revalidation: revalidation,
            isPresented: isPresented,
            onApplyActivation: onApplyActivation
        )
        .environment(\.locale, Locale(identifier: "en"))
        let hosted = NSHostingView(rootView: AnyView(root))
        hosted.frame = NSRect(x: 0, y: 0, width: 680, height: 540)
        let window = HostedTestWindow(
            contentRect: hosted.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosted
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(hosted)
        hosted.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        hosted.layoutSubtreeIfNeeded()
        return HostedReview(window: window)
    }

    private func sendReturn(
        to window: NSWindow,
        drainRunLoop: Bool = true
    ) {
        sendKey(
            to: window,
            characters: "\r",
            keyCode: 36,
            drainRunLoop: drainRunLoop
        )
    }

    private func sendEscape(
        to window: NSWindow,
        drainRunLoop: Bool = true
    ) {
        sendKey(
            to: window,
            characters: "\u{1B}",
            keyCode: 53,
            drainRunLoop: drainRunLoop
        )
    }

    private func sendKey(
        to window: NSWindow,
        characters: String,
        keyCode: UInt16,
        drainRunLoop: Bool = true
    ) {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ) else {
            Issue.record("Could not construct a hosted key event")
            return
        }
        if !window.performKeyEquivalent(with: event) {
            window.sendEvent(event)
        }
        if drainRunLoop {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
            window.contentView?.layoutSubtreeIfNeeded()
        }
    }
}
