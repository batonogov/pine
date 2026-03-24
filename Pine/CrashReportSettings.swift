//
//  CrashReportSettings.swift
//  Pine
//
//  Manages user opt-in preference for crash reporting.
//  Crash reporting is OFF by default (opt-in, not opt-out).
//

import Foundation

@Observable
final class CrashReportSettings {

    static let enabledKey = "crashReportingEnabled"
    static let askedKey = "crashReportingAsked"

    private let defaults: UserDefaults

    /// Whether anonymous crash reporting is enabled. Off by default.
    var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: Self.enabledKey)
        }
    }

    /// Whether the user has been shown the opt-in dialog.
    var hasBeenAsked: Bool {
        didSet {
            defaults.set(hasBeenAsked, forKey: Self.askedKey)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // UserDefaults.bool(forKey:) returns false when key doesn't exist — perfect for opt-in
        self.isEnabled = defaults.bool(forKey: Self.enabledKey)
        self.hasBeenAsked = defaults.bool(forKey: Self.askedKey)
    }
}
