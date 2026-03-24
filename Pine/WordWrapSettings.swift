//
//  WordWrapSettings.swift
//  Pine
//
//  Created by Claude on 24.03.2026.
//

import Foundation

/// Manages the global word wrap preference.
/// Default is `true` (word wrap enabled — text wraps at window edge).
/// When `false`, long lines extend beyond the viewport and require horizontal scrolling.
enum WordWrapSettings {
    private static let key = "wordWrapEnabled"

    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: key) == nil { return true }
        return defaults.bool(forKey: key)
    }

    static func setEnabled(_ enabled: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: key)
    }

    static func toggle(in defaults: UserDefaults = .standard) {
        setEnabled(!isEnabled(in: defaults), in: defaults)
    }
}
