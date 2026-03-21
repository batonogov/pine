//
//  SecretMaskingSettings.swift
//  Pine
//

import Foundation

/// Persisted toggle for secret masking in the editor.
@Observable
final class SecretMaskingSettings {
    static let shared = SecretMaskingSettings()

    private static let userDefaultsKey = "secretMaskingEnabled"
    private let defaults: UserDefaults

    private(set) var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: Self.userDefaultsKey)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Defaults to `true` — opt-out, not opt-in.
        if defaults.object(forKey: Self.userDefaultsKey) == nil {
            self.isEnabled = true
        } else {
            self.isEnabled = defaults.bool(forKey: Self.userDefaultsKey)
        }
    }

    func toggle() {
        isEnabled.toggle()
    }

    func enable() {
        isEnabled = true
    }

    func disable() {
        isEnabled = false
    }
}
