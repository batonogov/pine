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
    /// Uses computed property to avoid @Observable + didSet infinite recursion.
    var isEnabled: Bool {
        get { defaults.bool(forKey: Self.enabledKey) }
        set { defaults.set(newValue, forKey: Self.enabledKey) }
    }

    /// Whether the user has been shown the opt-in dialog.
    var hasBeenAsked: Bool {
        get { defaults.bool(forKey: Self.askedKey) }
        set { defaults.set(newValue, forKey: Self.askedKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }
}
