//
//  SettingsManager.swift
//  Pine
//

import Foundation

/// Central store for app preferences, backed by UserDefaults.
/// Uses `pine.` prefix for all keys. Changes apply immediately.
///
/// Uses computed properties with direct UserDefaults access instead of
/// stored properties with `didSet` to avoid infinite recursion with `@Observable`.
@Observable
final class SettingsManager {

    // MARK: - Constants

    static let defaultFontSize: CGFloat = 13
    static let minFontSize: CGFloat = 8
    static let maxFontSize: CGFloat = 32

    static let defaultTabWidth = 4
    static let minTabWidth = 1
    static let maxTabWidth = 8

    // MARK: - Keys

    enum Keys {
        static let autoSaveEnabled = "pine.autoSaveEnabled"
        static let stripTrailingWhitespace = "pine.stripTrailingWhitespace"
        static let fontSize = "pine.fontSize"
        static let tabWidth = "pine.tabWidth"
        static let showLineNumbers = "pine.showLineNumbers"
        static let showMinimap = "pine.showMinimap"
        static let theme = "pine.theme"
    }

    // MARK: - Storage

    private let defaults: UserDefaults

    // MARK: - Properties

    var autoSaveEnabled: Bool {
        get { defaults.bool(forKey: Keys.autoSaveEnabled) }
        set { defaults.set(newValue, forKey: Keys.autoSaveEnabled) }
    }

    var stripTrailingWhitespace: Bool {
        get {
            if defaults.object(forKey: Keys.stripTrailingWhitespace) == nil {
                return true
            }
            return defaults.bool(forKey: Keys.stripTrailingWhitespace)
        }
        set { defaults.set(newValue, forKey: Keys.stripTrailingWhitespace) }
    }

    var fontSize: CGFloat {
        get {
            let stored = defaults.double(forKey: Keys.fontSize)
            if stored > 0 {
                return min(max(CGFloat(stored), Self.minFontSize), Self.maxFontSize)
            }
            return Self.defaultFontSize
        }
        set {
            let clamped = min(max(newValue, Self.minFontSize), Self.maxFontSize)
            defaults.set(Double(clamped), forKey: Keys.fontSize)
        }
    }

    var tabWidth: Int {
        get {
            let stored = defaults.integer(forKey: Keys.tabWidth)
            if stored > 0 {
                return min(max(stored, Self.minTabWidth), Self.maxTabWidth)
            }
            return Self.defaultTabWidth
        }
        set {
            let clamped = min(max(newValue, Self.minTabWidth), Self.maxTabWidth)
            defaults.set(clamped, forKey: Keys.tabWidth)
        }
    }

    var showLineNumbers: Bool {
        get {
            if defaults.object(forKey: Keys.showLineNumbers) == nil {
                return true
            }
            return defaults.bool(forKey: Keys.showLineNumbers)
        }
        set { defaults.set(newValue, forKey: Keys.showLineNumbers) }
    }

    var showMinimap: Bool {
        get {
            if defaults.object(forKey: Keys.showMinimap) == nil {
                return true
            }
            return defaults.bool(forKey: Keys.showMinimap)
        }
        set { defaults.set(newValue, forKey: Keys.showMinimap) }
    }

    var theme: String {
        get {
            let stored = defaults.string(forKey: Keys.theme) ?? ""
            return stored.isEmpty ? "default" : stored
        }
        set {
            let value = newValue.isEmpty ? "default" : newValue
            defaults.set(value, forKey: Keys.theme)
        }
    }

    // MARK: - Init

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }
}
