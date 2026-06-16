//
//  GoToLineView.swift
//  Pine
//

import SwiftUI

/// Compact dialog for Go to Line navigation (Cmd+L).
struct GoToLineView: View {
    let totalLines: Int
    @Binding var isPresented: Bool
    var onGoTo: (Int, Int?) -> Void

    @State private var inputText = ""
    @State private var isInvalid = false
    @State private var invalidEnteredLine: Int?
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        VStack(spacing: 8) {
            TextField("42 or 42:10", text: $inputText)
                .textFieldStyle(.roundedBorder)
                .focused($isFieldFocused)
                .accessibilityIdentifier(AccessibilityID.goToLineField)
                .accessibilityLabel(String(localized: "Go to line"))
                .accessibilityHint(rangeHint)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isInvalid ? Color.red : Color.clear, lineWidth: 1)
                )
                .onSubmit { submit() }
                .animation(PineAnimation.quick, value: isInvalid)
                .onChange(of: inputText) { _, _ in
                    isInvalid = false
                    invalidEnteredLine = nil
                }

            feedbackLabel
        }
        .padding()
        .frame(width: 220)
        .accessibilityIdentifier(AccessibilityID.goToLineSheet)
        .onAppear { isFieldFocused = true }
        .onExitCommand { isPresented = false }
        .onChange(of: isInvalid) { _, newValue in
            guard newValue else { return }
            announceAccessibility(message: invalidMessage)
        }
    }

    /// Range hint for accessibility, e.g. "Enter a line number from 1 to 1234".
    private var rangeHint: String {
        String(localized: "Enter a line number from 1 to \(totalLines)")
    }

    /// Human-readable invalid-input message. Shows the entered line number
    /// when it parsed but was out of range; otherwise a generic format message.
    private var invalidMessage: String {
        if let entered = invalidEnteredLine {
            return String(localized: "Line \(entered) is out of range (1\u{2013}\(totalLines))")
        }
        return String(localized: "Enter a valid line number")
    }

    /// Feedback label: shows valid range normally, error message when invalid.
    @ViewBuilder
    private var feedbackLabel: some View {
        if isInvalid {
            Text(invalidMessage)
                .font(.caption)
                .foregroundStyle(.red)
                .accessibilityIdentifier(AccessibilityID.goToLineInvalidMessage)
                .transition(.opacity)
        } else {
            Text(String(localized: "1\u{2013}\(totalLines)"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Posts a VoiceOver announcement so the invalid-input state is audible.
    private func announceAccessibility(message: String) {
        NSAccessibility.post(
            element: NSApp.mainWindow ?? NSApp,
            notification: .announcementRequested,
            userInfo: [.announcement: message]
        )
    }

    private func submit() {
        let parsed = GoToLineParser.parse(inputText)
        guard let result = parsed, result.line <= totalLines else {
            isInvalid = true
            invalidEnteredLine = parsed?.line
            return
        }
        onGoTo(result.line, result.column)
        isPresented = false
    }
}
