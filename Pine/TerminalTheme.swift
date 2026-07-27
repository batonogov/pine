//
//  TerminalTheme.swift
//  Pine
//
//  Selectable terminal color themes with paired light/dark variants (#1244).
//
//  Each built-in theme is modelled as a light/dark pair covering the ANSI 16
//  colors, the default foreground/background, cursor, selection, and link
//  treatment. Pine's default theme ("Pine") reproduces the previous fixed
//  One Dark / Catppuccin Latte palettes bit-for-bit, so existing users see no
//  visual change unless they pick another theme.
//
//  The active variant (light or dark) is resolved by `TerminalThemeSettings`
//  using the user's Appearance policy (Follow System / Always Light /
//  Always Dark) combined with `NSApp.effectiveAppearance`.
//

import AppKit
import Foundation
import SwiftTerm

// MARK: - Color scheme (one half of a theme — light OR dark)

/// A complete color scheme for one appearance: the 16 ANSI colors plus the
/// non-ANSI slots (background, foreground, cursor, selection, link).
///
/// `ansiColors` slot order matches the SGR / xterm convention:
/// `[black, red, green, yellow, blue, magenta, cyan, white,
///  brightBlack, brightRed, brightGreen, brightYellow,
///  brightBlue, brightMagenta, brightCyan, brightWhite]`.
struct TerminalColorScheme: Equatable, Sendable {
    /// Exactly 16 ANSI color entries.
    let ansiColors: [TerminalPaletteEntry]
    /// Default terminal background.
    let background: TerminalPaletteEntry
    /// Default terminal foreground (text).
    let foreground: TerminalPaletteEntry
    /// Caret / cursor color.
    let cursor: TerminalPaletteEntry
    /// Selection highlight background.
    let selection: TerminalPaletteEntry
    /// Color used for underlined hyperlinks (OSC 8 / implicit URLs).
    let link: TerminalPaletteEntry

    init(
        ansiColors: [TerminalPaletteEntry],
        background: TerminalPaletteEntry,
        foreground: TerminalPaletteEntry,
        cursor: TerminalPaletteEntry,
        selection: TerminalPaletteEntry,
        link: TerminalPaletteEntry
    ) {
        precondition(
            ansiColors.count == TerminalPalette.colorCount,
            "TerminalColorScheme requires exactly \(TerminalPalette.colorCount) ANSI entries"
        )
        self.ansiColors = ansiColors
        self.background = background
        self.foreground = foreground
        self.cursor = cursor
        self.selection = selection
        self.link = link
    }

    /// Background as an opaque `NSColor` (sRGB).
    func backgroundColor() -> NSColor {
        background.makeNSColor()
    }

    /// Foreground as an `NSColor` (sRGB).
    func foregroundColor() -> NSColor {
        foreground.makeNSColor()
    }

    /// Cursor as an `NSColor` (sRGB).
    func cursorColor() -> NSColor {
        cursor.makeNSColor()
    }

    /// Selection as an `NSColor` (sRGB).
    func selectionColor() -> NSColor {
        selection.makeNSColor()
    }

    /// Link color as an `NSColor` (sRGB).
    func linkColor() -> NSColor {
        link.makeNSColor()
    }

    /// Builds the SwiftTerm `Color` array for `installColors`.
    /// Returns `nil` if the entry list does not contain exactly 16 entries.
    func swiftTermColors() -> [SwiftTerm.Color]? {
        TerminalPalette.swiftTermColors(from: ansiColors)
    }
}

// MARK: - Theme (a light/dark pair)

/// A terminal theme: a stable identifier, a localized display-name key, and
/// the light/dark color schemes. The active variant is chosen at runtime by
/// `TerminalThemeSettings` based on the Appearance policy and the system's
/// effective appearance.
struct TerminalTheme: Equatable, Hashable, Identifiable, Sendable {
    /// Stable, non-localized identifier persisted in UserDefaults.
    let id: String
    /// Localization key for the human-readable theme name.
    let nameKey: String
    /// Light-appearance color scheme.
    let light: TerminalColorScheme
    /// Dark-appearance color scheme.
    let dark: TerminalColorScheme

    /// Returns the scheme matching the given appearance.
    func scheme(forDarkAppearance isDark: Bool) -> TerminalColorScheme {
        isDark ? dark : light
    }
}

// MARK: - Built-in themes

extension TerminalTheme {

    /// All built-in themes, in display order. The first entry ("pine") is the
    /// default and reproduces Pine's previous fixed One Dark / Catppuccin
    /// Latte palettes bit-for-bit.
    static let builtIn: [TerminalTheme] = [
        pine,
        solarized,
        dracula,
        nord,
        github,
    ]

    /// The default theme identifier.
    static let defaultID = pine.id

    /// Looks up a built-in theme by identifier, falling back to the default
    /// ("pine") theme when the id is unknown (e.g. a theme removed in a past
    /// release). Never returns `nil`.
    static func theme(forID id: String) -> TerminalTheme {
        builtIn.first { $0.id == id } ?? pine
    }

    // MARK: Pine (default — One Dark / Catppuccin Latte)

    /// Pine's signature theme. The dark variant is One Dark (with the
    /// ghost-text slot-0 override); the light variant is the contrast-adjusted
    /// Catppuccin Latte palette. Both reproduce the colors Pine shipped before
    /// themes were user-selectable, so this is a no-op visual change for
    /// existing users.
    static let pine = TerminalTheme(
        id: "pine",
        nameKey: "terminal.theme.pine.name",
        light: TerminalColorScheme(
            ansiColors: TerminalPalette.lightPalette,
            background: TerminalPalette.lightModeBackgroundReference,
            foreground: TerminalPaletteEntry(red: 0x4C, green: 0x4F, blue: 0x69),
            cursor: TerminalPaletteEntry(red: 0xDC, green: 0x8A, blue: 0x78),
            selection: TerminalPaletteEntry(red: 0xCC, green: 0xD0, blue: 0xE1),
            link: TerminalPaletteEntry(red: 0x1E, green: 0x66, blue: 0xF5)
        ),
        dark: TerminalColorScheme(
            ansiColors: TerminalPalette.macOSAligned,
            background: TerminalPalette.darkModeBackgroundReference,
            foreground: TerminalPaletteEntry(red: 0xAB, green: 0xB2, blue: 0xBF),
            cursor: TerminalPaletteEntry(red: 0xFF, green: 0xFF, blue: 0xFF),
            selection: TerminalPaletteEntry(red: 0x3E, green: 0x44, blue: 0x55),
            link: TerminalPaletteEntry(red: 0x61, green: 0xAF, blue: 0xEF)
        )
    )

    // MARK: Solarized

    /// Solarized (Ethan Schoonover). The dark variant uses the Solarized
    /// "base03" background; the light variant uses "base3". ANSI slots map to
    /// the canonical Solarized accent colors.
    static let solarized = TerminalTheme(
        id: "solarized",
        nameKey: "terminal.theme.solarized.name",
        light: TerminalColorScheme(
            ansiColors: [
                .init(red: 0xEE, green: 0xE8, blue: 0xD5), // 0  base2 (black)
                .init(red: 0xDC, green: 0x32, blue: 0x2F), // 1  red
                .init(red: 0x85, green: 0x99, blue: 0x00), // 2  green
                .init(red: 0xB5, green: 0x89, blue: 0x00), // 3  yellow
                .init(red: 0x26, green: 0x8B, blue: 0xD2), // 4  blue
                .init(red: 0xD3, green: 0x36, blue: 0x82), // 5  magenta
                .init(red: 0x2A, green: 0xA1, blue: 0x98), // 6  cyan
                .init(red: 0x07, green: 0x36, blue: 0x42), // 7  base02 (white)
                .init(red: 0x00, green: 0x2B, blue: 0x36), // 8  base03 (bright black)
                .init(red: 0xCB, green: 0x4B, blue: 0x16), // 9  orange
                .init(red: 0x58, green: 0x6E, blue: 0x75), // 10 base01
                .init(red: 0x82, green: 0x84, blue: 0x00), // 11 base00
                .init(red: 0x83, green: 0x94, blue: 0x96), // 12 base1
                .init(red: 0x6C, green: 0x71, blue: 0xC4), // 13 violet
                .init(red: 0x93, green: 0xA1, blue: 0xA1), // 14 base1
                .init(red: 0xFD, green: 0xF6, blue: 0xE3), // 15 base3
            ],
            background: TerminalPaletteEntry(red: 0xFD, green: 0xF6, blue: 0xE3), // base3
            foreground: TerminalPaletteEntry(red: 0x65, green: 0x7B, blue: 0x83), // base00
            cursor: TerminalPaletteEntry(red: 0x65, green: 0x7B, blue: 0x83),
            selection: TerminalPaletteEntry(red: 0xE8, green: 0xE4, blue: 0xD0), // base2
            link: TerminalPaletteEntry(red: 0x26, green: 0x8B, blue: 0xD2)
        ),
        dark: TerminalColorScheme(
            ansiColors: [
                .init(red: 0x07, green: 0x36, blue: 0x42), // 0  base02
                .init(red: 0xDC, green: 0x32, blue: 0x2F), // 1  red
                .init(red: 0x85, green: 0x99, blue: 0x00), // 2  green
                .init(red: 0xB5, green: 0x89, blue: 0x00), // 3  yellow
                .init(red: 0x26, green: 0x8B, blue: 0xD2), // 4  blue
                .init(red: 0xD3, green: 0x36, blue: 0x82), // 5  magenta
                .init(red: 0x2A, green: 0xA1, blue: 0x98), // 6  cyan
                .init(red: 0xEE, green: 0xE8, blue: 0xD5), // 7  base2
                .init(red: 0x00, green: 0x2B, blue: 0x36), // 8  base03
                .init(red: 0xCB, green: 0x4B, blue: 0x16), // 9  orange
                .init(red: 0x58, green: 0x6E, blue: 0x75), // 10 base01
                .init(red: 0x82, green: 0x84, blue: 0x00), // 11 base00
                .init(red: 0x83, green: 0x94, blue: 0x96), // 12 base1
                .init(red: 0x6C, green: 0x71, blue: 0xC4), // 13 violet
                .init(red: 0x93, green: 0xA1, blue: 0xA1), // 14 base1
                .init(red: 0xFD, green: 0xF6, blue: 0xE3), // 15 base3
            ],
            background: TerminalPaletteEntry(red: 0x00, green: 0x2B, blue: 0x36), // base03
            foreground: TerminalPaletteEntry(red: 0x8A, green: 0x99, blue: 0xA5), // base0
            cursor: TerminalPaletteEntry(red: 0x8A, green: 0x99, blue: 0xA5),
            selection: TerminalPaletteEntry(red: 0x07, green: 0x36, blue: 0x42), // base02
            link: TerminalPaletteEntry(red: 0x26, green: 0x8B, blue: 0xD2)
        )
    )

    // MARK: Dracula

    /// Dracula — a popular dark theme. The light variant is a softened
    /// Dracula-on-cream adaptation for light mode.
    static let dracula = TerminalTheme(
        id: "dracula",
        nameKey: "terminal.theme.dracula.name",
        light: TerminalColorScheme(
            ansiColors: [
                .init(red: 0xD5, green: 0xCE, blue: 0xC8), // 0  black (soft)
                .init(red: 0xC1, green: 0x2C, blue: 0x2C), // 1  red
                .init(red: 0x1A, green: 0x8B, blue: 0x3B), // 2  green
                .init(red: 0xB6, green: 0x79, blue: 0x06), // 3  yellow
                .init(red: 0x1E, green: 0x55, blue: 0xCC), // 4  blue
                .init(red: 0xA6, green: 0x35, blue: 0xA0), // 5  magenta
                .init(red: 0x0E, green: 0x8A, blue: 0x8A), // 6  cyan
                .init(red: 0x3C, green: 0x38, blue: 0x36), // 7  white (dark)
                .init(red: 0x92, green: 0x83, blue: 0x74), // 8  bright black
                .init(red: 0xE5, green: 0x44, blue: 0x44), // 9  bright red
                .init(red: 0x2E, green: 0xC2, blue: 0x7E), // 10 bright green
                .init(red: 0xE0, green: 0xB0, blue: 0x4A), // 11 bright yellow
                .init(red: 0x45, green: 0x6C, blue: 0xE8), // 12 bright blue
                .init(red: 0xC8, green: 0x61, blue: 0xC0), // 13 bright magenta
                .init(red: 0x2A, green: 0xB7, blue: 0xB7), // 14 bright cyan
                .init(red: 0x4C, green: 0x49, blue: 0x45), // 15 bright white
            ],
            background: TerminalPaletteEntry(red: 0xFB, green: 0xF4, blue: 0xF0),
            foreground: TerminalPaletteEntry(red: 0x3C, green: 0x38, blue: 0x36),
            cursor: TerminalPaletteEntry(red: 0xC8, green: 0x61, blue: 0xC0),
            selection: TerminalPaletteEntry(red: 0xE5, green: 0xD8, blue: 0xD0),
            link: TerminalPaletteEntry(red: 0x1E, green: 0x55, blue: 0xCC)
        ),
        dark: TerminalColorScheme(
            ansiColors: [
                .init(red: 0x21, green: 0x29, blue: 0x33), // 0  black
                .init(red: 0xFF, green: 0x55, blue: 0x55), // 1  red
                .init(red: 0x50, green: 0xFA, blue: 0x7B), // 2  green
                .init(red: 0xF1, green: 0xFA, blue: 0x8C), // 3  yellow
                .init(red: 0xBD, green: 0x93, blue: 0xF9), // 4  blue
                .init(red: 0xFF, green: 0x79, blue: 0xC6), // 5  magenta
                .init(red: 0x8B, green: 0xE9, blue: 0xFD), // 6  cyan
                .init(red: 0xF8, green: 0xF8, blue: 0xF2), // 7  white
                .init(red: 0x62, green: 0x72, blue: 0xA4), // 8  bright black
                .init(red: 0xFF, green: 0x6E, blue: 0x6E), // 9  bright red
                .init(red: 0x69, green: 0xFF, blue: 0x94), // 10 bright green
                .init(red: 0xFF, green: 0xFF, blue: 0xA5), // 11 bright yellow
                .init(red: 0xD6, green: 0xAC, blue: 0xFF), // 12 bright blue
                .init(red: 0xFF, green: 0x92, blue: 0xDF), // 13 bright magenta
                .init(red: 0xA4, green: 0xFF, blue: 0xFF), // 14 bright cyan
                .init(red: 0xFF, green: 0xFF, blue: 0xFF), // 15 bright white
            ],
            background: TerminalPaletteEntry(red: 0x28, green: 0x2A, blue: 0x36),
            foreground: TerminalPaletteEntry(red: 0xF8, green: 0xF8, blue: 0xF2),
            cursor: TerminalPaletteEntry(red: 0xFF, green: 0x79, blue: 0xC6),
            selection: TerminalPaletteEntry(red: 0x44, green: 0x47, blue: 0x5A),
            link: TerminalPaletteEntry(red: 0xBD, green: 0x93, blue: 0xF9)
        )
    )

    // MARK: Nord

    /// Nord — an arctic, north-bluish color palette. Light variant uses the
    /// "Snow Storm" neutrals.
    static let nord = TerminalTheme(
        id: "nord",
        nameKey: "terminal.theme.nord.name",
        light: TerminalColorScheme(
            ansiColors: [
                .init(red: 0xEC, green: 0xEF, blue: 0xF4), // 0  snow storm
                .init(red: 0xBF, green: 0x61, blue: 0x6A), // 1  red (frost)
                .init(red: 0xA3, green: 0xBE, blue: 0x8C), // 2  green
                .init(red: 0xEB, green: 0xCB, blue: 0x8B), // 3  yellow
                .init(red: 0x53, green: 0x7A, blue: 0x9E), // 4  blue (frost)
                .init(red: 0xB4, green: 0x8E, blue: 0xAD), // 5  magenta
                .init(red: 0x8F, green: 0xBC, blue: 0xBB), // 6  cyan (frost)
                .init(red: 0x2E, green: 0x34, blue: 0x40), // 7  white (dark)
                .init(red: 0xD8, green: 0xDE, blue: 0xE9), // 8  bright black
                .init(red: 0xBF, green: 0x61, blue: 0x6A), // 9  bright red
                .init(red: 0xA3, green: 0xBE, blue: 0x8C), // 10 bright green
                .init(red: 0xEB, green: 0xCB, blue: 0x8B), // 11 bright yellow
                .init(red: 0x53, green: 0x7A, blue: 0x9E), // 12 bright blue
                .init(red: 0xB4, green: 0x8E, blue: 0xAD), // 13 bright magenta
                .init(red: 0x8F, green: 0xBC, blue: 0xBB), // 14 bright cyan
                .init(red: 0x4C, green: 0x55, blue: 0x6A), // 15 bright white
            ],
            background: TerminalPaletteEntry(red: 0xEC, green: 0xEF, blue: 0xF4),
            foreground: TerminalPaletteEntry(red: 0x2E, green: 0x34, blue: 0x40),
            cursor: TerminalPaletteEntry(red: 0x2E, green: 0x34, blue: 0x40),
            selection: TerminalPaletteEntry(red: 0xD8, green: 0xDE, blue: 0xE9),
            link: TerminalPaletteEntry(red: 0x53, green: 0x7A, blue: 0x9E)
        ),
        dark: TerminalColorScheme(
            ansiColors: [
                .init(red: 0x3B, green: 0x42, blue: 0x52), // 0  black (polar night)
                .init(red: 0xBF, green: 0x61, blue: 0x6A), // 1  red
                .init(red: 0xA3, green: 0xBE, blue: 0x8C), // 2  green
                .init(red: 0xEB, green: 0xCB, blue: 0x8B), // 3  yellow
                .init(red: 0x81, green: 0xA1, blue: 0xC1), // 4  blue (frost)
                .init(red: 0xB4, green: 0x8E, blue: 0xAD), // 5  magenta
                .init(red: 0x88, green: 0xC0, blue: 0xD0), // 6  cyan (frost)
                .init(red: 0xE5, green: 0xE9, blue: 0xF0), // 7  white (snow storm)
                .init(red: 0x4C, green: 0x55, blue: 0x6A), // 8  bright black
                .init(red: 0xBF, green: 0x61, blue: 0x6A), // 9  bright red
                .init(red: 0xA3, green: 0xBE, blue: 0x8C), // 10 bright green
                .init(red: 0xEB, green: 0xCB, blue: 0x8B), // 11 bright yellow
                .init(red: 0x81, green: 0xA1, blue: 0xC1), // 12 bright blue
                .init(red: 0xB4, green: 0x8E, blue: 0xAD), // 13 bright magenta
                .init(red: 0x8F, green: 0xBC, blue: 0xBB), // 14 bright cyan
                .init(red: 0xEC, green: 0xEF, blue: 0xF4), // 15 bright white
            ],
            background: TerminalPaletteEntry(red: 0x2E, green: 0x34, blue: 0x40),
            foreground: TerminalPaletteEntry(red: 0xD8, green: 0xDE, blue: 0xE9),
            cursor: TerminalPaletteEntry(red: 0xD8, green: 0xDE, blue: 0xE9),
            selection: TerminalPaletteEntry(red: 0x43, green: 0x4C, blue: 0x5E),
            link: TerminalPaletteEntry(red: 0x88, green: 0xC0, blue: 0xD0)
        )
    )

    // MARK: GitHub

    /// GitHub — based on GitHub's light and dark default themes.
    static let github = TerminalTheme(
        id: "github",
        nameKey: "terminal.theme.github.name",
        light: TerminalColorScheme(
            ansiColors: [
                .init(red: 0x6E, green: 0x77, blue: 0x83), // 0  black
                .init(red: 0xCB, green: 0x24, blue: 0x33), // 1  red
                .init(red: 0x1A, green: 0x7F, blue: 0x37), // 2  green
                .init(red: 0xBF, green: 0x87, blue: 0x0A), // 3  yellow
                .init(red: 0x09, green: 0x69, blue: 0xE7), // 4  blue
                .init(red: 0x82, green: 0x53, blue: 0x9E), // 5  magenta
                .init(red: 0x1B, green: 0x7C, blue: 0x83), // 6  cyan
                .init(red: 0x24, green: 0x29, blue: 0x2F), // 7  white
                .init(red: 0x5C, green: 0x65, blue: 0x70), // 8  bright black
                .init(red: 0xCB, green: 0x24, blue: 0x33), // 9  bright red
                .init(red: 0x1A, green: 0x7F, blue: 0x37), // 10 bright green
                .init(red: 0xBF, green: 0x87, blue: 0x0A), // 11 bright yellow
                .init(red: 0x09, green: 0x69, blue: 0xE7), // 12 bright blue
                .init(red: 0x82, green: 0x53, blue: 0x9E), // 13 bright magenta
                .init(red: 0x1B, green: 0x7C, blue: 0x83), // 14 bright cyan
                .init(red: 0x57, green: 0x5F, blue: 0x66), // 15 bright white
            ],
            background: TerminalPaletteEntry(red: 0xFF, green: 0xFF, blue: 0xFF),
            foreground: TerminalPaletteEntry(red: 0x24, green: 0x29, blue: 0x2F),
            cursor: TerminalPaletteEntry(red: 0x24, green: 0x29, blue: 0x2F),
            selection: TerminalPaletteEntry(red: 0xAE, green: 0xD0, blue: 0xFF),
            link: TerminalPaletteEntry(red: 0x09, green: 0x69, blue: 0xE7)
        ),
        dark: TerminalColorScheme(
            ansiColors: [
                .init(red: 0x48, green: 0x4F, blue: 0x58), // 0  black
                .init(red: 0xFF, green: 0x7B, blue: 0x72), // 1  red
                .init(red: 0x3F, green: 0xB9, blue: 0x50), // 2  green
                .init(red: 0xD2, green: 0x9E, blue: 0x22), // 3  yellow
                .init(red: 0x58, green: 0xA6, blue: 0xFF), // 4  blue
                .init(red: 0xBC, green: 0x8C, blue: 0xFF), // 5  magenta
                .init(red: 0x39, green: 0xC5, blue: 0xCF), // 6  cyan
                .init(red: 0xB1, green: 0xBA, blue: 0xC4), // 7  white
                .init(red: 0x6E, green: 0x76, blue: 0x81), // 8  bright black
                .init(red: 0xFF, green: 0x7B, blue: 0x72), // 9  bright red
                .init(red: 0x3F, green: 0xB9, blue: 0x50), // 10 bright green
                .init(red: 0xE3, green: 0xB3, blue: 0x41), // 11 bright yellow
                .init(red: 0x79, green: 0xC0, blue: 0xFF), // 12 bright blue
                .init(red: 0xD2, green: 0xA8, blue: 0xFF), // 13 bright magenta
                .init(red: 0x56, green: 0xD4, blue: 0xDD), // 14 bright cyan
                .init(red: 0xF0, green: 0xF6, blue: 0xFC), // 15 bright white
            ],
            background: TerminalPaletteEntry(red: 0x0D, green: 0x11, blue: 0x17),
            foreground: TerminalPaletteEntry(red: 0xE6, green: 0xED, blue: 0xF3),
            cursor: TerminalPaletteEntry(red: 0xE6, green: 0xED, blue: 0xF3),
            selection: TerminalPaletteEntry(red: 0x39, green: 0x35, blue: 0x3F),
            link: TerminalPaletteEntry(red: 0x58, green: 0xA6, blue: 0xFF)
        )
    )
}
