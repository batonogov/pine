//
//  FontSizeSettings.swift
//  Pine

import AppKit

@Observable
final class FontSizeSettings {
    static let shared = FontSizeSettings()

    static let defaultSize: CGFloat = 13
    static let minSize: CGFloat = 8
    static let maxSize: CGFloat = 32
    static let defaultFontFamily: String = ""

    private static let userDefaultsKey = "editorFontSize"
    private static let fontFamilyKey = "editorFontFamily"
    private let defaults: UserDefaults

    private(set) var fontSize: CGFloat {
        didSet {
            defaults.set(Double(fontSize), forKey: Self.userDefaultsKey)
        }
    }

    private(set) var fontFamily: String {
        didSet {
            defaults.set(fontFamily, forKey: Self.fontFamilyKey)
        }
    }

    var editorFont: NSFont {
        Self.makeFont(family: fontFamily, size: fontSize)
    }

    var gutterFont: NSFont {
        Self.makeFont(family: fontFamily, size: max(fontSize - 2, Self.minSize))
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.double(forKey: Self.userDefaultsKey)
        if stored > 0 {
            self.fontSize = min(max(stored, Self.minSize), Self.maxSize)
        } else {
            self.fontSize = Self.defaultSize
        }
        self.fontFamily = defaults.string(forKey: Self.fontFamilyKey) ?? Self.defaultFontFamily
    }

    func increase() {
        fontSize = min(fontSize + 1, Self.maxSize)
    }

    func decrease() {
        fontSize = max(fontSize - 1, Self.minSize)
    }

    func reset() {
        fontSize = Self.defaultSize
        fontFamily = Self.defaultFontFamily
    }

    func setFontFamily(_ family: String) {
        fontFamily = family
    }

    /// Returns a font for the given family and size.
    /// Falls back to system monospace if the family is empty, unavailable, or not monospaced.
    static func makeFont(family: String, size: CGFloat) -> NSFont {
        if !family.isEmpty,
           let font = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size),
           isMonospaced(font) {
            return font
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// Returns `true` if the font is monospaced.
    /// Uses `isFixedPitch` first, then falls back to comparing glyph advances
    /// for 'i' and 'm' — this catches fonts like SF Mono and JetBrains Mono
    /// where `isFixedPitch` incorrectly returns `false`.
    static func isMonospaced(_ font: NSFont) -> Bool {
        if font.isFixedPitch { return true }
        let iAdvance = font.advancement(forGlyph: font.glyph(withName: "i"))
        let mAdvance = font.advancement(forGlyph: font.glyph(withName: "m"))
        return iAdvance.width > 0 && abs(iAdvance.width - mAdvance.width) < 0.01
    }

    /// Returns all monospaced font families available on the system, sorted alphabetically.
    static func availableMonospacedFontFamilies() -> [String] {
        NSFontManager.shared.availableFontFamilies.filter { family in
            guard let font = NSFontManager.shared.font(
                withFamily: family, traits: [], weight: 5, size: 12
            ) else { return false }
            return isMonospaced(font)
        }
    }
}
