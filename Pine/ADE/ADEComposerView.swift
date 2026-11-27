//
//  ADEComposerView.swift
//  Pine
//
//  The task input. Request or Command is chosen only on its mode control,
//  never inferred from the text, and nothing is sent except by Send.
//

import SwiftUI

struct ADEComposerView: View {
    @Bindable var model: ADEWorkspaceModel
    /// `true` on the project overview, where the input is the main thing on screen.
    var isProminent = false
    @FocusState private var isFocused: Bool
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var prompt: LocalizedStringKey {
        switch (model.inputMode, model.selectedTaskID) {
        case (.command, _): Strings.workspaceCommandPrompt
        case (.request, nil): Strings.workspaceComposerPrompt
        case (.request, .some): Strings.workspaceContinuePrompt
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            modePicker
            field
            footer
        }
        .padding(isProminent ? 16 : 12)
        .background { card }
        .animation(PineAnimation.content(reduceMotion: reduceMotion), value: model.inputMode)
        .onAppear { takeFocus() }
        .onChange(of: model.newTaskFocusRequest) { _, _ in takeFocus() }
        .accessibilityIdentifier(AccessibilityID.workspaceComposer)
    }

    /// The overview is not on screen yet when "New task" asks for focus, so
    /// the request is kept until it is.
    private func takeFocus() {
        guard model.newTaskFocusRequest != nil else { return }
        isFocused = true
        model.newTaskFocusRequest = nil
    }

    private var modePicker: some View {
        Picker(Strings.workspaceInputMode, selection: $model.inputMode) {
            Text(Strings.workspaceModeRequest).tag(ADEInputMode.request)
            Text(Strings.workspaceModeCommand).tag(ADEInputMode.command)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .accessibilityLabel(Strings.workspaceInputMode)
        .accessibilityIdentifier(AccessibilityID.workspaceInputMode)
    }

    private var field: some View {
        TextField(prompt, text: $model.input, axis: .vertical)
            .font(isProminent ? .title3 : .body)
            .lineLimit(isProminent ? 2...8 : 1...6)
            .textFieldStyle(.plain)
            .focused($isFocused)
            .disabled(model.isBusy || !model.inputIsEditable)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier(AccessibilityID.workspaceComposerInput)
    }

    private var footer: some View {
        HStack(alignment: .bottom, spacing: 12) {
            notes
            Spacer(minLength: 8)
            sendButton
        }
    }

    @ViewBuilder
    private var notes: some View {
        if let failure = model.failure {
            failureText(failure)
        } else if let notice = model.notice {
            if notice == .instructionTooLong {
                // Explained before Send, the same way the registry would refuse it.
                failureText(.instructionTooLong)
            } else {
                Text(noticeText(notice))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(AccessibilityID.workspaceComposerNotice)
            }
        }
    }

    private func failureText(_ failure: OpenCodeTaskSubmissionFailure) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            switch failure {
            case .actionFailed:
                Text(Strings.openCodeTaskActionFailed)
            case .instructionTooLong:
                Text(Strings.workspaceRequestTooLong)
                Text(Strings.workspaceRequestTooLongDetail)
            }
        }
        .font(.caption)
        .foregroundStyle(failure == .actionFailed ? .orange : .secondary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(AccessibilityID.workspaceComposerNotice)
    }

    private func noticeText(_ notice: ADEComposerNotice) -> LocalizedStringKey {
        switch notice {
        case .commandUnavailable: Strings.workspaceCommandUnavailable
        case .noLiveSession: Strings.workspaceNoLiveSession
        case .inputFenced: Strings.openCodeTaskInputFenced
        case .awaitingRetry: Strings.workspaceAwaitingRetry
        case .instructionTooLong: Strings.workspaceRequestTooLongDetail
        }
    }

    @ViewBuilder
    private var sendButton: some View {
        if isProminent {
            sendButtonBody
                .keyboardShortcut(.defaultAction)
        } else {
            sendButtonBody
        }
    }

    private var sendButtonBody: some View {
        Button {
            Task { await model.send() }
        } label: {
            if model.isBusy {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 14, height: 14)
            } else {
                Label(Strings.workspaceSend, systemImage: "arrow.up")
            }
        }
        .buttonStyle(.borderedProminent)
        .disabled(!model.canSend)
        .accessibilityIdentifier(AccessibilityID.workspaceComposerSend)
    }

    /// An opaque card. It has a focus ring like a text field, and a firmer
    /// edge under Increase Contrast.
    private var card: some View {
        let shape = RoundedRectangle(cornerRadius: isProminent ? 12 : 10, style: .continuous)
        return shape
            .fill(Color(nsColor: .textBackgroundColor))
            .overlay {
                shape.strokeBorder(edge, lineWidth: isFocused ? 2 : 1)
            }
            .shadow(
                color: isProminent ? .black.opacity(0.08) : .clear,
                radius: isProminent ? 16 : 0,
                y: isProminent ? 6 : 0
            )
    }

    private var edge: Color {
        if isFocused {
            return contrast == .increased ? Color.accentColor : Color.accentColor.opacity(0.55)
        }
        return Color.primary.opacity(contrast == .increased ? 0.5 : 0.1)
    }
}
