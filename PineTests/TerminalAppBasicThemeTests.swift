//
//  TerminalAppBasicThemeTests.swift
//  PineTests
//
//  Tests for the "Terminal.app Basic" terminal theme (#1651): registration in
//  the built-in theme list, exact ANSI / foreground / background / cursor
//  values matching Terminal.app's Basic profile (the standard xterm palette),
//  ghost-text (slot 8) contrast compliance, and persistence through
//  `TerminalThemeSettings`.
//

import AppKit
import Foundation
import SwiftTerm
import Testing

@testable import Pine

// MARK: - WCAG contrast helpers

/// WCAG 2.x relative luminance of an 8-bit sRGB entry.
private func relativeLuminance(_ entry: TerminalPaletteEntry) -> Double {
    func channel(_ value: UInt8) -> Double {
        let normalized = Double(value) / 255.0
        return normalized <= 0.03928
            ? normalized / 12.92
            : pow((normalized + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * channel(entry.red)
        + 0.7152 * channel(entry.green)
        + 0.0722 * channel(entry.blue)
}

/// WCAG 2.x contrast ratio between two entries (1.0...21.0).
private func contrastRatio(
    _ lhs: TerminalPaletteEntry,
    _ rhs: TerminalPaletteEntry
) -> Double {
    let first = relativeLuminance(lhs)
    let second = relativeLuminance(rhs)
    return (max(first, second) + 0.05) / (min(first, second) + 0.05)
}

// MARK: - Terminal.app Basic theme

@Suite("Terminal.app Basic theme")
struct TerminalAppBasicThemeTests {

    /// Resolved through the registry so the test also proves the id is
    /// registered — an unregistered id would silently return `.pine`.
    private let theme = TerminalTheme.theme(forID: "terminal-app-basic")

    // MARK: Identity

    @Test("Registered in builtIn with a stable id and localization key")
    func identity() {
        #expect(theme == TerminalTheme.terminalAppBasic)
        #expect(theme.id == "terminal-app-basic")
        #expect(theme.nameKey == "terminal.theme.terminal-app-basic.name")
        #expect(TerminalTheme.builtIn.contains(TerminalTheme.terminalAppBasic))
    }

    @Test("Registered last so Pine stays the default")
    func registrationOrder() {
        #expect(TerminalTheme.builtIn.last == TerminalTheme.terminalAppBasic)
        #expect(TerminalTheme.builtIn.first?.id == TerminalTheme.defaultID)
        #expect(TerminalTheme.defaultID == "pine")
    }

    // MARK: Palette reference values

    /// The acceptance criterion of #1651: the theme's ANSI palette IS the
    /// existing `TerminalPalette.terminalAppBasic` fixture — the exact sRGB
    /// values from the `Basic.terminal` profile shipped with macOS.
    @Test("Both variants reuse the Terminal.app Basic palette fixture")
    func paletteMatchesFixture() {
        #expect(theme.light.ansiColors == TerminalPalette.terminalAppBasic)
        #expect(theme.dark.ansiColors == TerminalPalette.terminalAppBasic)
    }

    @Test("ANSI palette matches the exact xterm / Terminal.app Basic values")
    func ansiReferenceValues() {
        let expected: [(UInt8, UInt8, UInt8)] = [
            (0x00, 0x00, 0x00), // 0  black
            (0x99, 0x00, 0x00), // 1  red
            (0x00, 0xA6, 0x00), // 2  green
            (0x99, 0x99, 0x00), // 3  yellow
            (0x00, 0x00, 0xB2), // 4  blue
            (0xB2, 0x00, 0xB2), // 5  magenta
            (0x00, 0xA6, 0xB2), // 6  cyan
            (0xBF, 0xBF, 0xBF), // 7  white
            (0x66, 0x66, 0x66), // 8  bright black
            (0xE5, 0x00, 0x00), // 9  bright red
            (0x00, 0xD9, 0x00), // 10 bright green
            (0xE5, 0xE5, 0x00), // 11 bright yellow
            (0x00, 0x00, 0xFF), // 12 bright blue
            (0xE5, 0x00, 0xE5), // 13 bright magenta
            (0x00, 0xE5, 0xE5), // 14 bright cyan
            (0xE5, 0xE5, 0xE5), // 15 bright white
        ]
        for (schemeName, scheme) in [("light", theme.light), ("dark", theme.dark)] {
            #expect(scheme.ansiColors.count == expected.count)
            for (index, value) in expected.enumerated() {
                #expect(
                    scheme.ansiColors[index]
                        == TerminalPaletteEntry(red: value.0, green: value.1, blue: value.2),
                    "\(schemeName) ANSI \(index) drifted from Terminal.app Basic"
                )
            }
        }
    }

    // MARK: Non-ANSI slots

    @Test("Light variant matches the Basic profile: black text, white background, black cursor")
    func lightNonAnsiValues() {
        #expect(theme.light.background == TerminalPaletteEntry(red: 0xFF, green: 0xFF, blue: 0xFF))
        #expect(theme.light.foreground == TerminalPaletteEntry(red: 0x00, green: 0x00, blue: 0x00))
        #expect(theme.light.cursor == TerminalPaletteEntry(red: 0x00, green: 0x00, blue: 0x00))
        #expect(theme.light.selection == TerminalPaletteEntry(red: 0xAC, green: 0xCE, blue: 0xF7))
        #expect(theme.light.link == TerminalPaletteEntry(red: 0x00, green: 0x00, blue: 0xB2))
    }

    @Test("Dark variant is the classic xterm dark arrangement: white text on black")
    func darkNonAnsiValues() {
        // Terminal.app ships no dark Basic profile; the dark variant keeps the
        // identical ANSI palette on black with white text and a white cursor.
        #expect(theme.dark.background == TerminalPaletteEntry(red: 0x00, green: 0x00, blue: 0x00))
        #expect(theme.dark.foreground == TerminalPaletteEntry(red: 0xFF, green: 0xFF, blue: 0xFF))
        #expect(theme.dark.cursor == TerminalPaletteEntry(red: 0xFF, green: 0xFF, blue: 0xFF))
        #expect(theme.dark.selection == TerminalPaletteEntry(red: 0x40, green: 0x40, blue: 0x40))
        #expect(theme.dark.link == TerminalPaletteEntry(red: 0x00, green: 0x00, blue: 0xFF))
    }

    // MARK: Ghost text (slot 8)

    @Test("Slot 8 (ghost text) is distinct from the background in both schemes")
    func slot8DiffersFromBackground() {
        #expect(theme.light.ansiColors[8] != theme.light.background)
        #expect(theme.dark.ansiColors[8] != theme.dark.background)
    }

    @Test("Slot 8 (ghost text) clears 1.5:1 against the background in both schemes")
    func slot8GhostTextContrast() {
        // zsh-autosuggestions ghost text (fg=8) reads the real bright-black
        // slot (#666666) since the SwiftTerm fork fixed the bright-index
        // collapse (#1650). It must stay visible on both backgrounds.
        let lightRatio = contrastRatio(theme.light.ansiColors[8], theme.light.background)
        let darkRatio = contrastRatio(theme.dark.ansiColors[8], theme.dark.background)
        #expect(lightRatio >= 1.5, "light slot 8 contrast \(lightRatio) below 1.5:1")
        #expect(darkRatio >= 1.5, "dark slot 8 contrast \(darkRatio) below 1.5:1")
    }

    // MARK: Readability

    @Test("Foreground and background are maximum contrast (21:1) in both schemes")
    func foregroundContrastIsMaximal() {
        #expect(contrastRatio(theme.light.foreground, theme.light.background) == 21.0)
        #expect(contrastRatio(theme.dark.foreground, theme.dark.background) == 21.0)
    }

    @Test("Light scheme paints dark-on-light and dark scheme light-on-dark")
    func polarityIsCorrect() {
        let lightBackground = relativeLuminance(theme.light.background)
        let darkBackground = relativeLuminance(theme.dark.background)
        #expect(relativeLuminance(theme.light.foreground) < lightBackground)
        #expect(relativeLuminance(theme.dark.foreground) > darkBackground)

        for index in 0..<TerminalPalette.colorCount {
            // Slot 0 (ANSI black) equals the dark background by design — the
            // classic xterm arrangement, same as One Dark's slot 0.
            if index == 0 {
                #expect(theme.dark.ansiColors[0] == theme.dark.background)
                continue
            }
            #expect(
                relativeLuminance(theme.dark.ansiColors[index]) > darkBackground,
                "dark ANSI \(index) is not lighter than the dark background"
            )
        }
    }

    @Test("Selection is a background wash, never equal to the text it highlights")
    func selectionIsUsable() {
        #expect(theme.light.selection != theme.light.foreground)
        #expect(theme.dark.selection != theme.dark.foreground)
        #expect(theme.light.selection != theme.light.background)
        #expect(theme.dark.selection != theme.dark.background)
        #expect(contrastRatio(theme.light.selection, theme.light.foreground) >= 4.5)
        #expect(contrastRatio(theme.dark.selection, theme.dark.foreground) >= 4.5)
    }

    @Test("Link is visually distinct from the plain foreground")
    func linkIsDistinctFromForeground() {
        #expect(theme.light.link != theme.light.foreground)
        #expect(theme.dark.link != theme.dark.foreground)
    }

    // MARK: Bridging

    @Test("Both schemes bridge to AppKit and SwiftTerm without loss")
    func colorBridging() {
        #expect(theme.light.swiftTermColors()?.count == TerminalPalette.colorCount)
        #expect(theme.dark.swiftTermColors()?.count == TerminalPalette.colorCount)

        let background = theme.light.backgroundColor()
        #expect(abs(background.redComponent - 1.0) < 0.001)
        #expect(abs(background.greenComponent - 1.0) < 0.001)
        #expect(abs(background.blueComponent - 1.0) < 0.001)
        #expect(background.alphaComponent == 1.0)

        // 8-bit components are promoted with the standard x257 formula.
        let blue = theme.light.ansiColors[4].makeSwiftTermColor()
        #expect(blue.red == 0)
        #expect(blue.green == 0)
        #expect(blue.blue == UInt16(0xB2) * 257)
    }

    // MARK: Persistence

    @Test("Selecting the theme persists across settings instances")
    @MainActor
    func selectionPersists() throws {
        let suiteName = "TerminalAppBasicThemeTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let notificationCenter = NotificationCenter()

        let settings = TerminalThemeSettings(
            defaults: defaults,
            notificationCenter: notificationCenter
        )
        settings.setTheme(id: "terminal-app-basic")

        let restored = TerminalThemeSettings(
            defaults: defaults,
            notificationCenter: notificationCenter
        )
        #expect(restored.selectedThemeID == "terminal-app-basic")
        #expect(restored.selectedTheme == TerminalTheme.terminalAppBasic)
        #expect(
            restored.currentScheme(isDarkAppearance: true)
                == TerminalTheme.terminalAppBasic.dark
        )
        #expect(
            restored.currentScheme(isDarkAppearance: false)
                == TerminalTheme.terminalAppBasic.light
        )
    }
}
