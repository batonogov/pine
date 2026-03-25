//
//  CrashReportSettings.swift
//  Pine
//
//  Manages user opt-in preference for crash reporting.
//  Crash reporting is OFF by default (opt-in, not opt-out).
//

import Foundation

@MainActor
@Observable
final class CrashReportSettings {

    enum Keys {
        static let enabled = "crashReportingEnabled"
        static let asked = "crashReportingAsked"
    }

    private let defaults: UserDefaults

    /// Whether anonymous crash reporting is enabled. Off by default.
    var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: Keys.enabled)
        }
    }

    /// Whether the user has been shown the opt-in dialog.
    var hasBeenAsked: Bool {
        didSet {
            defaults.set(hasBeenAsked, forKey: Keys.asked)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // UserDefaults.bool(forKey:) returns false when key doesn't exist — perfect for opt-in
        self.isEnabled = defaults.bool(forKey: Keys.enabled)
        self.hasBeenAsked = defaults.bool(forKey: Keys.asked)
    }
}
