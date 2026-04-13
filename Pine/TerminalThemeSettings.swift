//
//  TerminalThemeSettings.swift
//  Pine
//
//  Persists the user's terminal theme selection in UserDefaults.
//  Follows the same singleton @Observable pattern as ShellSettings.
//

import Foundation

@MainActor
@Observable
final class TerminalThemeSettings {
    static let shared = TerminalThemeSettings()

    static let userDefaultsKey = "terminalThemeID"

    private let defaults: UserDefaults

    var selectedTheme: TerminalThemeID {
        didSet {
            defaults.set(selectedTheme.rawValue, forKey: Self.userDefaultsKey)
            NotificationCenter.default.post(name: .terminalThemeChanged, object: nil)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let stored = defaults.string(forKey: Self.userDefaultsKey),
           let theme = TerminalThemeID(rawValue: stored) {
            self.selectedTheme = theme
        } else {
            self.selectedTheme = .basic
        }
    }
}
