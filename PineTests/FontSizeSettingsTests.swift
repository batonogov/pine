//
//  FontSizeSettingsTests.swift
//  PineTests
//

import Testing
import Foundation
import AppKit
@testable import Pine

@Suite("FontSizeSettings Tests")
struct FontSizeSettingsTests {

    private let suiteName = "PineTests.FontSize.\(UUID().uuidString)"

    private func makeDefaults() throws -> UserDefaults {
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return defaults
    }

    private func cleanupDefaults(_ defaults: UserDefaults) {
        defaults.removePersistentDomain(forName: suiteName)
    }

    // MARK: - Default values

    @Test func defaultFontSizeIs13() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        let settings = FontSizeSettings(defaults: defaults)
        #expect(settings.fontSize == 13)
    }

    // MARK: - Increase

    @Test func increaseBumpsBy1() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        let settings = FontSizeSettings(defaults: defaults)
        settings.increase()
        #expect(settings.fontSize == 14)
    }

    @Test func increaseCannotExceedMax() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        let settings = FontSizeSettings(defaults: defaults)
        // Set to max
        for _ in 0..<50 {
            settings.increase()
        }
        #expect(settings.fontSize == 32)

        // One more should stay at max
        settings.increase()
        #expect(settings.fontSize == 32)
    }

    // MARK: - Decrease

    @Test func decreaseBumpsBy1() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        let settings = FontSizeSettings(defaults: defaults)
        settings.decrease()
        #expect(settings.fontSize == 12)
    }

    @Test func decreaseCannotGoBelowMin() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        let settings = FontSizeSettings(defaults: defaults)
        // Set to min
        for _ in 0..<50 {
            settings.decrease()
        }
        #expect(settings.fontSize == 8)

        // One more should stay at min
        settings.decrease()
        #expect(settings.fontSize == 8)
    }

    // MARK: - Reset

    @Test func resetRestoresDefault() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        let settings = FontSizeSettings(defaults: defaults)
        settings.increase()
        settings.increase()
        settings.increase()
        #expect(settings.fontSize == 16)

        settings.reset()
        #expect(settings.fontSize == 13)
    }

    // MARK: - Persistence

    @Test func fontSizePersistsToUserDefaults() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        let settings = FontSizeSettings(defaults: defaults)
        settings.increase()
        settings.increase()

        #expect(defaults.double(forKey: "editorFontSize") == 15)
    }

    @Test func fontSizeLoadsFromUserDefaults() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        defaults.set(Double(20), forKey: "editorFontSize")

        let settings = FontSizeSettings(defaults: defaults)
        #expect(settings.fontSize == 20)
    }

    @Test func invalidPersistedValueClampsToRange() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        defaults.set(Double(100), forKey: "editorFontSize")
        let settings1 = FontSizeSettings(defaults: defaults)
        #expect(settings1.fontSize == 32)

        defaults.set(Double(2), forKey: "editorFontSize")
        let settings2 = FontSizeSettings(defaults: defaults)
        #expect(settings2.fontSize == 8)
    }

    @Test func zeroPersistedValueUsesDefault() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        // double(forKey:) returns 0 when key doesn't exist
        // so 0 should be treated as "not set" → use default
        defaults.set(Double(0), forKey: "editorFontSize")
        let settings = FontSizeSettings(defaults: defaults)
        #expect(settings.fontSize == 13)
    }

    // MARK: - Fonts

    @Test func editorFontMatchesFontSize() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        let settings = FontSizeSettings(defaults: defaults)
        #expect(settings.editorFont.pointSize == 13)

        settings.increase()
        #expect(settings.editorFont.pointSize == 14)
    }

    @Test func gutterFontIsSmallerThanEditor() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        let settings = FontSizeSettings(defaults: defaults)
        #expect(settings.gutterFont.pointSize == 11)

        settings.increase()
        #expect(settings.gutterFont.pointSize == 12)
    }

    // MARK: - Font Family

    @Test func defaultFontFamilyIsEmpty() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        let settings = FontSizeSettings(defaults: defaults)
        #expect(settings.fontFamily == "")
    }

    @Test func setFontFamilyUpdatesFontFamily() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        let settings = FontSizeSettings(defaults: defaults)
        settings.setFontFamily("Courier New")
        #expect(settings.fontFamily == "Courier New")
    }

    @Test func fontFamilyPersistsToUserDefaults() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        let settings = FontSizeSettings(defaults: defaults)
        settings.setFontFamily("Menlo")
        #expect(defaults.string(forKey: "editorFontFamily") == "Menlo")
    }

    @Test func fontFamilyLoadsFromUserDefaults() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        defaults.set("Monaco", forKey: "editorFontFamily")
        let settings = FontSizeSettings(defaults: defaults)
        #expect(settings.fontFamily == "Monaco")
    }

    @Test func editorFontUsesCustomFamilyWhenSet() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        let settings = FontSizeSettings(defaults: defaults)
        settings.setFontFamily("Courier New")
        let font = settings.editorFont
        // Courier New is a fixed-pitch font, so it should be returned
        #expect(font.familyName == "Courier New")
        #expect(font.pointSize == FontSizeSettings.defaultSize)
    }

    @Test func editorFontFallsBackToSystemMonospaceForEmptyFamily() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        let settings = FontSizeSettings(defaults: defaults)
        // Empty family → system monospace
        let font = settings.editorFont
        #expect(font.pointSize == FontSizeSettings.defaultSize)
        #expect(font.isFixedPitch)
    }

    @Test func gutterFontUsesCustomFamilyWhenSet() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        let settings = FontSizeSettings(defaults: defaults)
        settings.setFontFamily("Courier New")
        let font = settings.gutterFont
        #expect(font.familyName == "Courier New")
        #expect(font.pointSize == FontSizeSettings.defaultSize - 2)
    }

    @Test func makeFontReturnsFontForValidFamily() throws {
        // Courier New is available on all macOS systems
        let font = FontSizeSettings.makeFont(family: "Courier New", size: 14)
        #expect(font.familyName == "Courier New")
        #expect(font.pointSize == 14)
    }

    @Test func makeFontFallsBackForEmptyFamily() throws {
        let font = FontSizeSettings.makeFont(family: "", size: 13)
        #expect(font.pointSize == 13)
        #expect(font.isFixedPitch)
    }

    @Test func makeFontFallsBackForInvalidFamily() throws {
        let font = FontSizeSettings.makeFont(family: "NotARealFontFamilyXYZ", size: 13)
        // Falls back to system monospace
        #expect(font.isFixedPitch)
        #expect(font.pointSize == 13)
    }

    @Test func availableMonospacedFontFamiliesIsNonEmpty() throws {
        let families = FontSizeSettings.availableMonospacedFontFamilies()
        #expect(!families.isEmpty)
    }

    @Test func availableMonospacedFontFamiliesContainsKnownFonts() throws {
        let families = FontSizeSettings.availableMonospacedFontFamilies()
        // Menlo and Courier New are always present on macOS
        #expect(families.contains("Menlo"))
        #expect(families.contains("Courier New"))
    }

    @Test func availableMonospacedFontFamiliesAreAllFixed() throws {
        let families = FontSizeSettings.availableMonospacedFontFamilies()
        for family in families {
            let font = FontSizeSettings.makeFont(family: family, size: 12)
            #expect(font.isFixedPitch, "Expected \(family) to be fixed-pitch")
        }
    }
}
