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
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        VStack(spacing: 8) {
            TextField(Strings.goToLinePlaceholder, text: $inputText)
                .textFieldStyle(.roundedBorder)
                .focused($isFieldFocused)
                .accessibilityIdentifier(AccessibilityID.goToLineField)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isInvalid ? Color.red : Color.clear, lineWidth: 1)
                )
                .onSubmit { submit() }
                .onChange(of: inputText) { _, _ in isInvalid = false }

            Text("1–\(totalLines)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(width: 220)
        .accessibilityIdentifier(AccessibilityID.goToLineSheet)
        .onAppear { isFieldFocused = true }
        .onExitCommand { isPresented = false }
    }

    private func submit() {
        guard let result = GoToLineParser.parse(inputText),
              result.line <= totalLines else {
            isInvalid = true
            return
        }
        onGoTo(result.line, result.column)
        isPresented = false
    }
}
