//
//  QuickTerminalSettingsView.swift
//  Pine
//
//  Settings controls for the Quick Terminal (#1243). All controls apply
//  immediately. The hotkey recorder
//  captures the next key-down event and stores its Carbon key code and
//  modifier bit-field into `QuickTerminalSettings`.
//

import AppKit
import Carbon.HIToolbox
import SwiftUI

@MainActor
struct QuickTerminalSettingsView: View {
    @Bindable var settings: QuickTerminalSettings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(Strings.quickTerminalSettingsTitle)
                    .font(.title2.weight(.semibold))

                QuickTerminalSettingsControls(settings: settings)
            }
            .padding(20)
        }
        .frame(width: 720, height: 540)
    }
}

/// Reusable controls embedded in the consolidated Terminal pane and in the
/// standalone preview/snapshot. State is shared; this view does not duplicate
/// persistence or runtime observers.
@MainActor
struct QuickTerminalSettingsControls: View {
    @Bindable var settings: QuickTerminalSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle(isOn: $settings.enabled) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(Strings.quickTerminalEnabled)
                    Text(Strings.quickTerminalEnabledHelp)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier(AccessibilityID.quickTerminalEnabledToggle)

            Divider()

            hotkeySettings

            VStack(alignment: .leading, spacing: 14) {
                Picker(
                    Strings.quickTerminalScreenEdge,
                    selection: $settings.screenEdge
                ) {
                    ForEach(QuickTerminalScreenEdge.allCases) { edge in
                        Text(label(for: edge)).tag(edge)
                    }
                }
                .accessibilityIdentifier(
                    AccessibilityID.quickTerminalScreenEdgePicker
                )

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(Strings.quickTerminalSize)
                            .font(.headline)
                        Spacer()
                        percentage
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(
                        value: $settings.heightFraction,
                        in: 0.2 ... 0.8,
                        step: 0.05
                    )
                    .accessibilityLabel(Strings.quickTerminalSize)
                    .accessibilityValue(percentage)
                    .accessibilityIdentifier(
                        AccessibilityID.quickTerminalSizeSlider
                    )
                }

                Picker(
                    Strings.quickTerminalTargetDisplay,
                    selection: $settings.targetDisplay
                ) {
                    ForEach(QuickTerminalTargetDisplay.allCases) { display in
                        Text(label(for: display)).tag(display)
                    }
                }
                .accessibilityIdentifier(
                    AccessibilityID.quickTerminalTargetDisplayPicker
                )

                Toggle(isOn: $settings.hideOnFocusLoss) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(Strings.quickTerminalHideOnFocusLoss)
                        Text(Strings.quickTerminalHideOnFocusLossHelp)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier(
                    AccessibilityID.quickTerminalHideOnFocusLossToggle
                )
            }
            .disabled(settings.enabled == false)

            Divider()

            Button(Strings.quickTerminalReset) {
                settings.reset()
            }
            .accessibilityIdentifier(AccessibilityID.quickTerminalResetButton)
        }
    }

    private var hotkeySettings: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Strings.quickTerminalHotkey)
                .font(.headline)
            QuickTerminalHotkeyRecorder(settings: settings)
                .frame(maxWidth: 220)
            Text(Strings.quickTerminalHotkeyHelp)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Label helpers

    private func label(for edge: QuickTerminalScreenEdge) -> LocalizedStringKey {
        switch edge {
        case .top: return Strings.quickTerminalEdgeTop
        case .bottom: return Strings.quickTerminalEdgeBottom
        case .left: return Strings.quickTerminalEdgeLeft
        case .right: return Strings.quickTerminalEdgeRight
        }
    }

    private func label(for display: QuickTerminalTargetDisplay) -> LocalizedStringKey {
        switch display {
        case .active: return Strings.quickTerminalDisplayActive
        case .main: return Strings.quickTerminalDisplayMain
        }
    }

    private var percentage: Text {
        Text(
            settings.heightFraction,
            format: .percent.precision(.fractionLength(0))
        )
    }
}

// MARK: - Hotkey recorder

/// A button-style recorder that captures the next key-down event through
/// ``QuickTerminalHotkeyCaptureRouter``. The app's one local event monitor
/// routes capture first, so user keybindings and built-in shortcuts cannot
/// fire while a shortcut is being recorded.
@MainActor
struct QuickTerminalHotkeyRecorder: View {
    let settings: QuickTerminalSettings
    @State private var rejectedBareKey = false
    @State private var captureToken: QuickTerminalHotkeyCaptureRouter.Token?

    private var isRecording: Bool { captureToken != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                if isRecording {
                    stopRecording()
                } else {
                    startRecording()
                }
            } label: {
                HStack {
                    Image(systemName: isRecording ? "keyboard" : "command")
                    if isRecording {
                        Text(Strings.quickTerminalRecordingHotkey)
                            .lineLimit(1)
                    } else {
                        Text(verbatim: settings.hotkeyLabel)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel(Strings.quickTerminalHotkey)
            .accessibilityValue(
                isRecording
                    ? Text(Strings.quickTerminalRecordingHotkey)
                    : Text(verbatim: settings.hotkeyLabel)
            )
            .accessibilityHint(Strings.quickTerminalHotkeyHelp)
            .accessibilityIdentifier(
                AccessibilityID.quickTerminalHotkeyRecorder
            )

            if rejectedBareKey {
                Text(Strings.quickTerminalHotkeyModifierRequired)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier(
                        AccessibilityID.quickTerminalHotkeyValidation
                    )
            }
        }
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        rejectedBareKey = false
        captureToken = QuickTerminalHotkeyCaptureRouter.shared.begin { event in
            switch QuickTerminalHotkeyCapture.decision(
                keyCode: event.keyCode,
                modifiers: event.modifierFlags
            ) {
            case .cancel:
                stopRecording()
            case .rejectMissingModifier:
                rejectedBareKey = true
                NSSound.beep()
            case let .accept(keyCode, modifiers):
                settings.setHotkey(
                    keyCode: keyCode,
                    modifiers: modifiers
                )
                stopRecording()
            }
        }
    }

    private func stopRecording() {
        if let captureToken {
            QuickTerminalHotkeyCaptureRouter.shared.end(captureToken)
            self.captureToken = nil
        }
    }
}

/// Exclusive capture slot consumed by AppDelegate's single key-down monitor.
/// A token prevents a stale/disappearing recorder from ending a newer
/// recording session.
@MainActor
final class QuickTerminalHotkeyCaptureRouter {
    struct Token: Equatable {
        fileprivate let id: UUID
    }

    static let shared = QuickTerminalHotkeyCaptureRouter()

    private var activeCapture: (
        token: Token,
        handler: (NSEvent) -> Void
    )?

    @discardableResult
    func begin(_ handler: @escaping (NSEvent) -> Void) -> Token? {
        guard activeCapture == nil else { return nil }
        let token = Token(id: UUID())
        activeCapture = (token, handler)
        return token
    }

    func end(_ token: Token) {
        guard activeCapture?.token == token else { return }
        activeCapture = nil
    }

    /// Returns `true` when capture owns the event. Capture always consumes the
    /// key-down, including Escape and a rejected bare key.
    func route(_ event: NSEvent) -> Bool {
        guard let handler = activeCapture?.handler else { return false }
        handler(event)
        return true
    }

    var isCapturing: Bool { activeCapture != nil }
}

enum QuickTerminalHotkeyCaptureDecision: Equatable {
    case cancel
    case rejectMissingModifier
    case accept(keyCode: UInt32, modifiers: UInt32)
}

/// Pure decision layer for the AppKit event monitor. XCUITest key injection
/// bypasses local event monitors on macOS, so unit tests cover cancellation,
/// rejection, and Carbon conversion directly.
enum QuickTerminalHotkeyCapture {
    static func decision(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags
    ) -> QuickTerminalHotkeyCaptureDecision {
        if keyCode == UInt16(kVK_Escape) {
            return .cancel
        }
        let normalized = KeyboardShortcutMatcher.normalizedModifiers(modifiers)
        let supportedFlags: NSEvent.ModifierFlags = [
            .command,
            .option,
            .control,
            .shift,
        ]
        let supported = normalized.intersection(supportedFlags)
        let primaryFlags: NSEvent.ModifierFlags = [
            .command,
            .option,
            .control,
        ]
        guard supported.isDisjoint(with: primaryFlags) == false else {
            return .rejectMissingModifier
        }
        let carbon = carbonModifiers(from: supported)
        return .accept(
            keyCode: UInt32(keyCode),
            modifiers: carbon
        )
    }

    private static func carbonModifiers(
        from flags: NSEvent.ModifierFlags
    ) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        return result
    }
}
