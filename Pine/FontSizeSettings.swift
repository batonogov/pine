//
//  FontSizeSettings.swift
//  Pine
//

import AppKit

@MainActor
@Observable
final class FontSizeSettings {
    static let shared = FontSizeSettings()

    nonisolated static let defaultSize: CGFloat = 13
    nonisolated static let minSize: CGFloat = 8
    nonisolated static let maxSize: CGFloat = 18

    private static let userDefaultsKey = "editorFontSize"
    private let defaults: UserDefaults

    /// Current editor font size, always clamped to
    /// [`minSize`, `maxSize`]. Publicly settable so the Settings slider can
    /// bind to it directly (issue #337); the `didSet` persists the value and
    /// re-clamps so direct assignment cannot escape the valid range.
    var fontSize: CGFloat {
        didSet {
            let clamped = min(max(fontSize, Self.minSize), Self.maxSize)
            if clamped != fontSize {
                fontSize = clamped
                return
            }
            defaults.set(Double(fontSize), forKey: Self.userDefaultsKey)
        }
    }

    var editorFont: NSFont {
        NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }

    var gutterFont: NSFont {
        NSFont.monospacedSystemFont(ofSize: fontSize - 2, weight: .regular)
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.double(forKey: Self.userDefaultsKey)
        if stored > 0 {
            self.fontSize = min(max(stored, Self.minSize), Self.maxSize)
        } else {
            self.fontSize = Self.defaultSize
        }
    }

    func increase() {
        fontSize = min(fontSize + 1, Self.maxSize)
    }

    func decrease() {
        fontSize = max(fontSize - 1, Self.minSize)
    }

    func reset() {
        fontSize = Self.defaultSize
    }

    /// Sets an explicit size, clamped to the valid range. Used by callers
    /// that prefer a method over direct assignment.
    func setFontSize(_ size: CGFloat) {
        fontSize = min(max(size, Self.minSize), Self.maxSize)
    }
}
