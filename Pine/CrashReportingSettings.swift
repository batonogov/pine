//
//  CrashReportingSettings.swift
//  Pine
//
//  Manages user preference for opt-in crash reporting.
//

import Foundation

/// Manages the opt-in crash reporting preference.
/// Persisted via UserDefaults with a clear opt-in flow.
enum CrashReportingSettings {
    /// UserDefaults key for the crash reporting enabled state.
    static let enabledKey = "crashReporting.enabled"

    /// UserDefaults key tracking whether the opt-in dialog has been shown.
    static let promptShownKey = "crashReporting.promptShown"

    /// Whether crash reporting is currently enabled.
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// Whether the opt-in prompt has already been shown to the user.
    static var hasShownPrompt: Bool {
        get { UserDefaults.standard.bool(forKey: promptShownKey) }
        set { UserDefaults.standard.set(newValue, forKey: promptShownKey) }
    }

    /// Returns true if we need to show the opt-in dialog (first launch).
    static var needsPrompt: Bool {
        !hasShownPrompt
    }

    /// Records that the user made a choice and marks the prompt as shown.
    static func recordChoice(enabled: Bool) {
        isEnabled = enabled
        hasShownPrompt = true
    }
}
