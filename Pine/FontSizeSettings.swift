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
    nonisolated static let maxSize: CGFloat = 32

    private static let userDefaultsKey = "editorFontSize"
    private let defaults: UserDefaults

    private(set) var fontSize: CGFloat {
        didSet {
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
}
