//
//  TerminalThemeTests.swift
//  PineTests
//
//  Tests for TerminalThemeID, TerminalThemeSettings, and the theme-aware
//  palette installation path (issue #816).
//

import Foundation
import Testing
@testable import Pine

// MARK: - TerminalThemeID tests

@Suite("TerminalThemeID")
struct TerminalThemeIDTests {

    @Test("All themes have exactly 16 palette entries")
    func allThemesHave16Entries() {
        for theme in TerminalThemeID.allCases {
            #expect(theme.palette.count == 16, "Theme \(theme.rawValue) has \(theme.palette.count) entries")
        }
    }

    @Test("Display names are non-empty")
    func displayNamesNonEmpty() {
        for theme in TerminalThemeID.allCases {
            #expect(!theme.displayName.isEmpty, "Theme \(theme.rawValue) has an empty display name")
        }
    }

    @Test("Display names are unique")
    func displayNamesUnique() {
        let names = TerminalThemeID.allCases.map(\.displayName)
        #expect(Set(names).count == names.count, "Duplicate display names found")
    }

    @Test("Raw values are unique and stable")
    func rawValuesUnique() {
        let rawValues = TerminalThemeID.allCases.map(\.rawValue)
        #expect(Set(rawValues).count == rawValues.count)
    }

    @Test("Identifiable id matches rawValue")
    func identifiableId() {
        for theme in TerminalThemeID.allCases {
            #expect(theme.id == theme.rawValue)
        }
    }

    @Test("CaseIterable covers all expected themes")
    func allCasesCovered() {
        let expected: Set<String> = ["basic", "pro", "solarizedDark", "dracula", "oneDark", "nord"]
        let actual = Set(TerminalThemeID.allCases.map(\.rawValue))
        #expect(actual == expected)
    }

    @Test("needsGhostTextOverride — solarizedDark does not need it")
    func solarizedDarkNoGhostOverride() {
        #expect(!TerminalThemeID.solarizedDark.needsGhostTextOverride)
    }

    @Test("needsGhostTextOverride — dark themes with black slot 0 need it")
    func darkThemesNeedGhostOverride() {
        let needsOverride: [TerminalThemeID] = [.basic, .pro, .dracula, .oneDark, .nord]
        for theme in needsOverride {
            #expect(theme.needsGhostTextOverride, "\(theme.rawValue) should need ghost text override")
        }
    }

    @Test("Init from invalid raw value returns nil")
    func invalidRawValue() {
        #expect(TerminalThemeID(rawValue: "nonexistent") == nil)
        #expect(TerminalThemeID(rawValue: "") == nil)
        #expect(TerminalThemeID(rawValue: "Basic") == nil) // case-sensitive
    }
}

// MARK: - TerminalThemeSettings tests

@Suite("TerminalThemeSettings")
struct TerminalThemeSettingsTests {

    @Test("Default theme is basic")
    @MainActor func defaultIsBasic() throws {
        let suiteName = "TerminalThemeSettingsTests-default-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let settings = TerminalThemeSettings(defaults: defaults)
        #expect(settings.selectedTheme == .basic)
    }

    @Test("Persists selected theme to UserDefaults")
    @MainActor func persistsTheme() throws {
        let suiteName = "TerminalThemeSettingsTests-persist-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let settings = TerminalThemeSettings(defaults: defaults)
        settings.selectedTheme = .dracula
        #expect(defaults.string(forKey: TerminalThemeSettings.userDefaultsKey) == "dracula")
    }

    @Test("Reads persisted theme on init")
    @MainActor func readsPersistedTheme() throws {
        let suiteName = "TerminalThemeSettingsTests-read-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set("nord", forKey: TerminalThemeSettings.userDefaultsKey)
        let settings = TerminalThemeSettings(defaults: defaults)
        #expect(settings.selectedTheme == .nord)
    }

    @Test("Falls back to basic for unknown stored value")
    @MainActor func fallbackForUnknownValue() throws {
        let suiteName = "TerminalThemeSettingsTests-fallback-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set("unknown_theme_xyz", forKey: TerminalThemeSettings.userDefaultsKey)
        let settings = TerminalThemeSettings(defaults: defaults)
        #expect(settings.selectedTheme == .basic)
    }

    @Test("Falls back to basic when key is absent")
    @MainActor func fallbackWhenKeyAbsent() throws {
        let suiteName = "TerminalThemeSettingsTests-absent-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let settings = TerminalThemeSettings(defaults: defaults)
        #expect(settings.selectedTheme == .basic)
    }

    @Test("Roundtrip: write then read each theme")
    @MainActor func roundtripAllThemes() throws {
        let suiteName = "TerminalThemeSettingsTests-roundtrip-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let settings = TerminalThemeSettings(defaults: defaults)
        for theme in TerminalThemeID.allCases {
            settings.selectedTheme = theme
            let reloaded = TerminalThemeSettings(defaults: defaults)
            #expect(reloaded.selectedTheme == theme, "Roundtrip failed for \(theme.rawValue)")
        }
    }
}

// MARK: - Palette resolution tests

@Suite("TerminalPalette theme resolution")
struct TerminalPaletteThemeTests {

    @Test("resolvedPalette applies ghost text override when needed")
    func ghostTextOverrideApplied() {
        for theme in TerminalThemeID.allCases where theme.needsGhostTextOverride {
            let resolved = TerminalPalette.resolvedPalette(for: theme)
            #expect(
                resolved[0] == TerminalPalette.ghostTextOverride,
                "\(theme.rawValue) slot 0 should be ghostTextOverride"
            )
        }
    }

    @Test("resolvedPalette preserves slot 0 when ghost override not needed")
    func noGhostTextOverrideWhenNotNeeded() {
        for theme in TerminalThemeID.allCases where !theme.needsGhostTextOverride {
            let resolved = TerminalPalette.resolvedPalette(for: theme)
            #expect(
                resolved[0] == theme.palette[0],
                "\(theme.rawValue) slot 0 should be unmodified"
            )
        }
    }

    @Test("resolvedPalette always has 16 entries")
    func resolvedPaletteSize() {
        for theme in TerminalThemeID.allCases {
            let resolved = TerminalPalette.resolvedPalette(for: theme)
            #expect(resolved.count == 16)
        }
    }

    @Test("swiftTermColors succeeds for all resolved palettes")
    func swiftTermColorsForAllThemes() {
        for theme in TerminalThemeID.allCases {
            let resolved = TerminalPalette.resolvedPalette(for: theme)
            let colors = TerminalPalette.swiftTermColors(from: resolved)
            #expect(colors != nil, "swiftTermColors returned nil for \(theme.rawValue)")
            #expect(colors?.count == 16)
        }
    }

    @Test("resolvedPalette does not modify non-zero slots")
    func nonZeroSlotsPreserved() {
        for theme in TerminalThemeID.allCases {
            let resolved = TerminalPalette.resolvedPalette(for: theme)
            let original = theme.palette
            for idx in 1..<16 {
                #expect(resolved[idx] == original[idx],
                        "\(theme.rawValue) slot \(idx) should be unmodified")
            }
        }
    }

    @Test("macOSAligned matches basic with ghost override")
    func macOSAlignedMatchesBasicResolved() {
        let basicResolved = TerminalPalette.resolvedPalette(for: .basic)
        #expect(basicResolved == TerminalPalette.macOSAligned)
    }
}

// MARK: - Specific palette value tests

@Suite("Palette hex values")
struct PaletteHexValueTests {

    @Test("Dracula palette slot 0 is #21222C")
    func draculaBlack() {
        let entry = TerminalPalette.dracula[0]
        #expect(entry.red == 0x21)
        #expect(entry.green == 0x22)
        #expect(entry.blue == 0x2C)
    }

    @Test("One Dark palette slot 0 is #282C34")
    func oneDarkBlack() {
        let entry = TerminalPalette.oneDark[0]
        #expect(entry.red == 0x28)
        #expect(entry.green == 0x2C)
        #expect(entry.blue == 0x34)
    }

    @Test("Nord palette slot 0 is #3B4252")
    func nordBlack() {
        let entry = TerminalPalette.nord[0]
        #expect(entry.red == 0x3B)
        #expect(entry.green == 0x42)
        #expect(entry.blue == 0x52)
    }

    @Test("Dracula bright white is #FFFFFF")
    func draculaBrightWhite() {
        let entry = TerminalPalette.dracula[15]
        #expect(entry.red == 0xFF)
        #expect(entry.green == 0xFF)
        #expect(entry.blue == 0xFF)
    }

    @Test("Nord white is #E5E9F0")
    func nordWhite() {
        let entry = TerminalPalette.nord[7]
        #expect(entry.red == 0xE5)
        #expect(entry.green == 0xE9)
        #expect(entry.blue == 0xF0)
    }

    @Test("One Dark cyan is #56B6C2")
    func oneDarkCyan() {
        let entry = TerminalPalette.oneDark[6]
        #expect(entry.red == 0x56)
        #expect(entry.green == 0xB6)
        #expect(entry.blue == 0xC2)
    }
}
