//
//  SecretMaskingSettings.swift
//  Pine
//
//  Persisted toggle for secret masking (amber highlight in editor).
//  Defaults to enabled so new users benefit without any configuration.
//

import Foundation

@Observable
final class SecretMaskingSettings {
    static let shared = SecretMaskingSettings()

    static let storageKey = "secretMaskingEnabled"

    private let defaults: UserDefaults

    var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: Self.storageKey)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Default to true if the key has never been set
        if defaults.object(forKey: Self.storageKey) == nil {
            self.isEnabled = true
        } else {
            self.isEnabled = defaults.bool(forKey: Self.storageKey)
        }
    }

    static func toggle() {
        shared.isEnabled.toggle()
    }
}
