//
//  DigitalRainThemeTests.swift
//  PineTests
//
//  Tests for the "Digital Rain" terminal theme (#1349) and the built-in theme
//  registry invariants it relies on: registry shape, exact id lookup and
//  fallback, scheme routing, per-scheme ANSI count, slot-0 ghost-text
//  legibility, normal/bright ordering, and WCAG contrast against each
//  variant's own background.
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

// MARK: - Built-in theme registry invariants

@Suite("Terminal theme registry")
struct TerminalThemeRegistryTests {

    @Test("Default theme is the first built-in entry")
    func defaultIsFirst() {
        #expect(TerminalTheme.builtIn.first?.id == TerminalTheme.defaultID)
        #expect(TerminalTheme.defaultID == "pine")
    }

    @Test("Built-in identifiers are unique")
    func identifiersAreUnique() {
        let ids = TerminalTheme.builtIn.map(\.id)
        #expect(Set(ids).count == ids.count, "duplicate theme id in builtIn: \(ids)")
    }

    @Test("Built-in localization keys are unique and follow the naming convention")
    func nameKeysWellFormed() {
        let keys = TerminalTheme.builtIn.map(\.nameKey)
        #expect(Set(keys).count == keys.count, "duplicate nameKey in builtIn: \(keys)")

        for theme in TerminalTheme.builtIn {
            #expect(!theme.id.isEmpty, "a built-in theme has an empty id")
            #expect(!theme.nameKey.isEmpty, "\(theme.id) has an empty nameKey")
            #expect(
                theme.nameKey == "terminal.theme.\(theme.id).name",
                "\(theme.id) nameKey \(theme.nameKey) breaks the id-derived convention"
            )
        }
    }

    @Test("Every scheme of every built-in theme has exactly 16 ANSI entries")
    func sixteenAnsiEntriesEverywhere() {
        for theme in TerminalTheme.builtIn {
            #expect(
                theme.light.ansiColors.count == TerminalPalette.colorCount,
                "light scheme of \(theme.id) has \(theme.light.ansiColors.count) entries"
            )
            #expect(
                theme.dark.ansiColors.count == TerminalPalette.colorCount,
                "dark scheme of \(theme.id) has \(theme.dark.ansiColors.count) entries"
            )
        }
    }

    @Test("Every built-in theme converts to a 16-color SwiftTerm palette")
    func swiftTermConversionSucceeds() {
        for theme in TerminalTheme.builtIn {
            #expect(theme.light.swiftTermColors()?.count == TerminalPalette.colorCount)
            #expect(theme.dark.swiftTermColors()?.count == TerminalPalette.colorCount)
        }
    }

    @Test("scheme(forDarkAppearance:) routes each appearance to its own scheme")
    func schemeRouting() {
        for theme in TerminalTheme.builtIn {
            #expect(theme.scheme(forDarkAppearance: true) == theme.dark)
            #expect(theme.scheme(forDarkAppearance: false) == theme.light)
        }
    }

    @Test("Light and dark schemes are never the same palette")
    func schemesDiffer() {
        for theme in TerminalTheme.builtIn {
            #expect(theme.light != theme.dark, "\(theme.id) light and dark are identical")
        }
    }

    @Test("theme(forID:) resolves every built-in identifier")
    func lookupResolvesBuiltIns() {
        for theme in TerminalTheme.builtIn {
            #expect(TerminalTheme.theme(forID: theme.id) == theme)
        }
    }

    @Test(
        "theme(forID:) falls back to the default on anything but an exact id",
        arguments: [
            "",
            " ",
            "definitely-not-a-theme",
            "digital",           // prefix of digital-rain
            "digital-rain ",     // trailing whitespace
            " digital-rain",     // leading whitespace
            "Digital-Rain",      // casing
            "Digital Rain",      // display name, not id
            "digital_rain",      // separator drift
            "digitalRain",       // Swift property name, not id
        ]
    )
    func unknownIdFallsBackToDefault(id: String) {
        #expect(TerminalTheme.theme(forID: id) == .pine)
    }
}

// MARK: - Digital Rain

@Suite("Digital Rain theme")
struct DigitalRainThemeTests {

    /// Resolved through the registry so the test also proves the id is
    /// registered — an unregistered id would silently return `.pine`.
    private let theme = TerminalTheme.theme(forID: "digital-rain")

    // MARK: Identity

    @Test("Registered in builtIn with a stable id and localization key")
    func identity() {
        #expect(theme == TerminalTheme.digitalRain)
        #expect(theme.id == "digital-rain")
        #expect(theme.nameKey == "terminal.theme.digital-rain.name")
        #expect(TerminalTheme.builtIn.contains(TerminalTheme.digitalRain))
    }

    @Test("Registered after the existing themes so Pine stays the default")
    func registrationOrder() {
        #expect(
            TerminalTheme.builtIn.map(\.id)
                == ["pine", "solarized", "dracula", "nord", "github", "digital-rain"]
        )
    }

    // MARK: Palette reference values

    @Test("Dark palette matches its authored reference values")
    func darkReferenceValues() {
        let expected: [(UInt8, UInt8, UInt8)] = [
            (0x35, 0x6B, 0x49), (0xFF, 0x33, 0x44), (0x00, 0xC8, 0x53), (0xFF, 0xD2, 0x3F),
            (0x33, 0xA1, 0xFF), (0xB2, 0x67, 0xFF), (0x1F, 0xE0, 0xB0), (0x7A, 0xF0, 0xA0),
            (0x4E, 0x74, 0x59), (0xFF, 0x55, 0x66), (0x00, 0xFF, 0x66), (0xFF, 0xE0, 0x66),
            (0x5B, 0xB8, 0xFF), (0xCB, 0x8A, 0xFF), (0x5C, 0xFF, 0xD8), (0xDC, 0xFF, 0xE6),
        ]
        for (index, value) in expected.enumerated() {
            #expect(
                theme.dark.ansiColors[index]
                    == TerminalPaletteEntry(red: value.0, green: value.1, blue: value.2),
                "dark ANSI \(index) drifted"
            )
        }
        #expect(theme.dark.background == TerminalPaletteEntry(red: 0x0A, green: 0x0E, blue: 0x0A))
        #expect(theme.dark.foreground == TerminalPaletteEntry(red: 0x00, green: 0xE0, blue: 0x56))
        #expect(theme.dark.cursor == TerminalPaletteEntry(red: 0x00, green: 0xFF, blue: 0x66))
    }

    @Test("Light palette matches its authored reference values")
    func lightReferenceValues() {
        let expected: [(UInt8, UInt8, UInt8)] = [
            (0x5A, 0x78, 0x62), (0xC0, 0x20, 0x2E), (0x1F, 0x7A, 0x3A), (0x9A, 0x67, 0x00),
            (0x1A, 0x5F, 0xB4), (0x8E, 0x24, 0xAA), (0x0F, 0x7C, 0x8A), (0x4A, 0x5A, 0x4A),
            (0x6B, 0x83, 0x71), (0xD6, 0x3A, 0x47), (0x2A, 0x8F, 0x3F), (0xA3, 0x76, 0x00),
            (0x2E, 0x74, 0xD6), (0xA2, 0x3A, 0xB8), (0x15, 0x87, 0x7A), (0x66, 0x78, 0x66),
        ]
        for (index, value) in expected.enumerated() {
            #expect(
                theme.light.ansiColors[index]
                    == TerminalPaletteEntry(red: value.0, green: value.1, blue: value.2),
                "light ANSI \(index) drifted"
            )
        }
        #expect(theme.light.background == TerminalPaletteEntry(red: 0xDC, green: 0xEB, blue: 0xDC))
        #expect(theme.light.foreground == TerminalPaletteEntry(red: 0x0E, green: 0x3D, blue: 0x1E))
        #expect(theme.light.cursor == TerminalPaletteEntry(red: 0x0A, green: 0x2E, blue: 0x16))
    }

    // MARK: Ghost text (SwiftTerm 8 -> 0 collapse)

    @Test("Slot 0 is distinct from the background in both schemes")
    func slot0DiffersFromBackground() {
        // Pine runs SwiftTerm with useBrightColors = false, which collapses the
        // 256-color index 8 onto 0 (see TerminalPalette.ghostTextOverride). A
        // slot 0 equal to the background renders zsh-autosuggestions ghost text
        // invisible — the Nord light defect tracked in #1350.
        #expect(theme.dark.ansiColors[0] != theme.dark.background)
        #expect(theme.light.ansiColors[0] != theme.light.background)
    }

    @Test("Slot 0 is legible as ghost text — at least 2.5:1 against its background")
    func slot0IsLegible() {
        // "Not equal to the background" is not enough: a near-background slot 0
        // is still invisible in practice. Ghost text is dim by design, so the
        // bar is below body-text AA but well clear of the background.
        let darkRatio = contrastRatio(theme.dark.ansiColors[0], theme.dark.background)
        let lightRatio = contrastRatio(theme.light.ansiColors[0], theme.light.background)
        #expect(darkRatio >= 2.5, "dark slot 0 ghost-text contrast \(darkRatio) below 2.5:1")
        #expect(lightRatio >= 2.5, "light slot 0 ghost-text contrast \(lightRatio) below 2.5:1")
    }

    @Test("Slot 0 stays dimmer than the foreground so ghost text reads as a hint")
    func slot0IsDimmerThanForeground() {
        #expect(
            contrastRatio(theme.dark.ansiColors[0], theme.dark.background)
                < contrastRatio(theme.dark.foreground, theme.dark.background)
        )
        #expect(
            contrastRatio(theme.light.ansiColors[0], theme.light.background)
                < contrastRatio(theme.light.foreground, theme.light.background)
        )
    }

    // MARK: Readability

    @Test("Every ANSI slot clears 3:1 against its own background")
    func everySlotClearsThreeToOne() {
        for index in 0..<TerminalPalette.colorCount {
            let darkRatio = contrastRatio(theme.dark.ansiColors[index], theme.dark.background)
            let lightRatio = contrastRatio(theme.light.ansiColors[index], theme.light.background)
            #expect(darkRatio >= 3.0, "dark ANSI \(index) contrast \(darkRatio) below 3:1")
            #expect(lightRatio >= 3.0, "light ANSI \(index) contrast \(lightRatio) below 3:1")
        }
    }

    @Test("Foreground clears WCAG AAA (7:1) in both schemes")
    func foregroundContrastIsAAA() {
        let darkRatio = contrastRatio(theme.dark.foreground, theme.dark.background)
        let lightRatio = contrastRatio(theme.light.foreground, theme.light.background)
        #expect(darkRatio >= 7.0, "dark fg/bg contrast \(darkRatio) below AAA")
        #expect(lightRatio >= 7.0, "light fg/bg contrast \(lightRatio) below AAA")
    }

    @Test("Cursor and link clear WCAG AA (4.5:1) in both schemes")
    func cursorAndLinkContrastIsAA() {
        for (label, entry) in [
            ("dark cursor", theme.dark.cursor),
            ("dark link", theme.dark.link),
        ] {
            let ratio = contrastRatio(entry, theme.dark.background)
            #expect(ratio >= 4.5, "\(label) contrast \(ratio) below AA")
        }
        for (label, entry) in [
            ("light cursor", theme.light.cursor),
            ("light link", theme.light.link),
        ] {
            let ratio = contrastRatio(entry, theme.light.background)
            #expect(ratio >= 4.5, "\(label) contrast \(ratio) below AA")
        }
    }

    @Test("Dark scheme paints light-on-dark and light scheme dark-on-light")
    func polarityIsCorrect() {
        let darkBackground = relativeLuminance(theme.dark.background)
        let lightBackground = relativeLuminance(theme.light.background)
        #expect(relativeLuminance(theme.dark.foreground) > darkBackground)
        #expect(relativeLuminance(theme.light.foreground) < lightBackground)

        for index in 0..<TerminalPalette.colorCount {
            #expect(
                relativeLuminance(theme.dark.ansiColors[index]) > darkBackground,
                "dark ANSI \(index) is not lighter than the dark background"
            )
            #expect(
                relativeLuminance(theme.light.ansiColors[index]) < lightBackground,
                "light ANSI \(index) is not darker than the light background"
            )
        }
    }

    // MARK: Palette structure

    @Test("Every bright slot is strictly lighter than its normal counterpart")
    func brightSlotsAreLighter() {
        for index in 0..<8 {
            #expect(
                relativeLuminance(theme.dark.ansiColors[index + 8])
                    > relativeLuminance(theme.dark.ansiColors[index]),
                "dark bright slot \(index + 8) is not lighter than slot \(index)"
            )
            #expect(
                relativeLuminance(theme.light.ansiColors[index + 8])
                    > relativeLuminance(theme.light.ansiColors[index]),
                "light bright slot \(index + 8) is not lighter than slot \(index)"
            )
        }
    }

    @Test("All 16 ANSI entries are distinct in both schemes")
    func ansiEntriesAreDistinct() {
        #expect(Set(theme.dark.ansiColors).count == TerminalPalette.colorCount)
        #expect(Set(theme.light.ansiColors).count == TerminalPalette.colorCount)
    }

    @Test("The dark background carries a green undertone rather than pure black")
    func darkBackgroundIsGreenTinted() {
        let background = theme.dark.background
        #expect(background.green > background.red)
        #expect(background.green > background.blue)
        #expect(background.red < 0x20, "dark background is not near-black")
        #expect(background.green < 0x20, "dark background is not near-black")
    }

    @Test("The light background is a pale green-grey, not white")
    func lightBackgroundIsGreenTinted() {
        let background = theme.light.background
        #expect(background.green > background.red)
        #expect(background.green > background.blue)
        #expect(background.green < 0xFF, "light background is plain white")
    }

    @Test("Green and cyan dominate while the other hues stay distinct")
    func accentsRemainDistinguishable() {
        // Green-family slots must actually read green.
        for slot in [2, 6, 10, 14] {
            let entry = theme.dark.ansiColors[slot]
            #expect(entry.green > entry.red, "dark slot \(slot) is not green-dominant")
        }
        // Red / yellow / blue / magenta must not collapse onto the foreground
        // or onto each other, otherwise git diffs, errors and TUI apps stop
        // being readable at a glance.
        let accents = [1, 3, 4, 5, 9, 11, 12, 13]
        for slot in accents {
            #expect(theme.dark.ansiColors[slot] != theme.dark.foreground)
            #expect(theme.light.ansiColors[slot] != theme.light.foreground)
        }
        #expect(Set(accents.map { theme.dark.ansiColors[$0] }).count == accents.count)
        #expect(Set(accents.map { theme.light.ansiColors[$0] }).count == accents.count)
    }

    @Test("Selection is a background wash, never equal to the text it highlights")
    func selectionIsUsable() {
        #expect(theme.dark.selection != theme.dark.foreground)
        #expect(theme.light.selection != theme.light.foreground)
        #expect(theme.dark.selection != theme.dark.background)
        #expect(theme.light.selection != theme.light.background)
        #expect(contrastRatio(theme.dark.selection, theme.dark.foreground) >= 4.5)
        #expect(contrastRatio(theme.light.selection, theme.light.foreground) >= 4.5)
    }

    @Test("Link is visually distinct from the plain foreground")
    func linkIsDistinctFromForeground() {
        #expect(theme.dark.link != theme.dark.foreground)
        #expect(theme.light.link != theme.light.foreground)
    }

    // MARK: Bridging

    @Test("Both schemes bridge to AppKit and SwiftTerm without loss")
    func colorBridging() {
        #expect(theme.dark.swiftTermColors()?.count == TerminalPalette.colorCount)
        #expect(theme.light.swiftTermColors()?.count == TerminalPalette.colorCount)

        let background = theme.dark.backgroundColor()
        #expect(abs(background.redComponent - 0x0A / 255.0) < 0.001)
        #expect(abs(background.greenComponent - 0x0E / 255.0) < 0.001)
        #expect(abs(background.blueComponent - 0x0A / 255.0) < 0.001)
        #expect(background.alphaComponent == 1.0)

        // 8-bit components are promoted with the standard x257 formula.
        let brightGreen = theme.dark.ansiColors[10].makeSwiftTermColor()
        #expect(brightGreen.red == 0)
        #expect(brightGreen.green == UInt16(0xFF) * 257)
        #expect(brightGreen.blue == UInt16(0x66) * 257)
    }
}
