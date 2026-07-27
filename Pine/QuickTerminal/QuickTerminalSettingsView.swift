//
//  QuickTerminalSettingsView.swift
//  Pine
//
//  Settings tab for the Quick Terminal (#1243). All controls apply
//  immediately — there is no Apply/Reset step. The hotkey recorder
//  captures the next key-down event and stores its Carbon key code and
//  modifier bit-field into `QuickTerminalSettings`.
//

import AppKit
import Carbon.HIToolbox
import SwiftUI

@MainActor
struct QuickTerminalSettingsView: View {
    let settings: QuickTerminalSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(Strings.quickTerminalSettingsTitle)
                .font(.title2.weight(.semibold))

            // Master enable toggle
            Toggle(isOn: Binding(
                get: { settings.enabled },
                set: { settings.enabled = $0 }
            )) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(Strings.quickTerminalEnabled)
                    Text(Strings.quickTerminalEnabledHelp)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            // Hotkey recorder
            VStack(alignment: .leading, spacing: 6) {
                Text(Strings.quickTerminalHotkey)
                    .font(.headline)
                QuickTerminalHotkeyRecorder(settings: settings)
                    .frame(maxWidth: 220)
                Text(Strings.quickTerminalHotkeyHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            // Screen edge picker
            Picker(selection: Binding(
                get: { settings.screenEdge },
                set: { settings.screenEdge = $0 }
            )) {
                ForEach(QuickTerminalScreenEdge.allCases) { edge in
                    Text(label(for: edge)).tag(edge)
                }
            } label: {
                Text(Strings.quickTerminalScreenEdge)
                    .font(.headline)
            }

            // Height / width fraction slider
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(Strings.quickTerminalSize)
                        .font(.headline)
                    Spacer()
                    Text(String(format: "%d%%", Int(settings.heightFraction * 100)))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(
                    value: Binding(
                        get: { settings.heightFraction },
                        set: { settings.heightFraction = $0 }
                    ),
                    in: 0.2 ... 0.8,
                    step: 0.05
                )
            }

            // Target display picker
            Picker(selection: Binding(
                get: { settings.targetDisplay },
                set: { settings.targetDisplay = $0 }
            )) {
                ForEach(QuickTerminalTargetDisplay.allCases) { display in
                    Text(label(for: display)).tag(display)
                }
            } label: {
                Text(Strings.quickTerminalTargetDisplay)
                    .font(.headline)
            }

            Divider()

            // Hide on focus loss
            Toggle(isOn: Binding(
                get: { settings.hideOnFocusLoss },
                set: { settings.hideOnFocusLoss = $0 }
            )) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(Strings.quickTerminalHideOnFocusLoss)
                    Text(Strings.quickTerminalHideOnFocusLossHelp)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(width: 720, height: 540)
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
}

// MARK: - Hotkey recorder

/// A button-style recorder that captures the next key-down event. While
/// "recording", it intercepts key events via a local `NSEvent` monitor,
/// converts them to Carbon key code + modifier bit-field, and writes them
/// into `QuickTerminalSettings`.
@MainActor
private struct QuickTerminalHotkeyRecorder: View {
    let settings: QuickTerminalSettings
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            if isRecording {
                stopRecording()
            } else {
                startRecording()
            }
        } label: {
            HStack {
                Image(systemName: isRecording ? "keyboard" : "command")
                Text(isRecording
                     ? String(localized: Strings.quickTerminalRecordingHotkey)
                     : settings.hotkeyLabel)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(settings.enabled == false)
        .accessibilityIdentifier("quickTerminal.hotkeyRecorder")
    }

    private func startRecording() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Escape cancels recording without changing the hotkey.
            if event.keyCode == UInt16(kVK_Escape) {
                stopRecording()
                return nil
            }
            // Require at least one modifier — a bare key as a global hotkey
            // would shadow ordinary typing.
            let mods = KeyboardShortcutMatcher.normalizedModifiers(event.modifierFlags)
            guard !mods.isEmpty else {
                return nil
            }
            settings.keyCode = UInt32(event.keyCode)
            settings.modifiers = carbonModifiers(from: mods)
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        isRecording = false
    }

    /// Converts `NSEvent.ModifierFlags` → Carbon modifier bit-field.
    private func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        return result
    }
}
