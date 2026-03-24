//
//  SettingsManagerTests.swift
//  PineTests
//

import Testing
import Foundation
@testable import Pine

@Suite("SettingsManager Tests")
struct SettingsManagerTests {

    private let suiteName = "PineTests.Settings.\(UUID().uuidString)"

    private func makeDefaults() throws -> UserDefaults {
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return defaults
    }

    private func cleanupDefaults(_ defaults: UserDefaults) {
        defaults.removePersistentDomain(forName: suiteName)
    }

    // MARK: - Default values

    @Test func defaultAutoSaveIsOff() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        let settings = SettingsManager(defaults: defaults)
        #expect(settings.autoSaveEnabled == false)
    }

    @Test func defaultStripTrailingWhitespaceIsOn() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        let settings = SettingsManager(defaults: defaults)
        #expect(settings.stripTrailingWhitespace == true)
    }

    @Test func defaultFontSizeIs13() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        let settings = SettingsManager(defaults: defaults)
        #expect(settings.fontSize == 13)
    }

    @Test func defaultTabWidthIs4() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        let settings = SettingsManager(defaults: defaults)
        #expect(settings.tabWidth == 4)
    }

    @Test func defaultShowLineNumbersIsOn() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        let settings = SettingsManager(defaults: defaults)
        #expect(settings.showLineNumbers == true)
    }

    @Test func defaultShowMinimapIsOn() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        let settings = SettingsManager(defaults: defaults)
        #expect(settings.showMinimap == true)
    }

    @Test func defaultThemeIsDefault() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        let settings = SettingsManager(defaults: defaults)
        #expect(settings.theme == "default")
    }

    // MARK: - Persistence (write)

    @Test func autoSavePersistsToDefaults() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        let settings = SettingsManager(defaults: defaults)
        settings.autoSaveEnabled = true
        #expect(defaults.bool(forKey: SettingsManager.Keys.autoSaveEnabled) == true)
    }

    @Test func stripTrailingWhitespacePersists() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        let settings = SettingsManager(defaults: defaults)
        settings.stripTrailingWhitespace = false
        #expect(defaults.bool(forKey: SettingsManager.Keys.stripTrailingWhitespace) == false)
    }

    @Test func fontSizePersists() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        let settings = SettingsManager(defaults: defaults)
        settings.fontSize = 18
        #expect(defaults.double(forKey: SettingsManager.Keys.fontSize) == 18)
    }

    @Test func tabWidthPersists() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        let settings = SettingsManager(defaults: defaults)
        settings.tabWidth = 2
        #expect(defaults.integer(forKey: SettingsManager.Keys.tabWidth) == 2)
    }

    @Test func showLineNumbersPersists() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        let settings = SettingsManager(defaults: defaults)
        settings.showLineNumbers = false
        #expect(defaults.bool(forKey: SettingsManager.Keys.showLineNumbers) == false)
    }

    @Test func showMinimapPersists() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        let settings = SettingsManager(defaults: defaults)
        settings.showMinimap = false
        #expect(defaults.bool(forKey: SettingsManager.Keys.showMinimap) == false)
    }

    @Test func themePersists() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        let settings = SettingsManager(defaults: defaults)
        settings.theme = "monokai"
        #expect(defaults.string(forKey: SettingsManager.Keys.theme) == "monokai")
    }

    // MARK: - Persistence (read)

    @Test func loadsAutoSaveFromDefaults() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        defaults.set(true, forKey: SettingsManager.Keys.autoSaveEnabled)
        let settings = SettingsManager(defaults: defaults)
        #expect(settings.autoSaveEnabled == true)
    }

    @Test func loadsFontSizeFromDefaults() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        defaults.set(20.0, forKey: SettingsManager.Keys.fontSize)
        let settings = SettingsManager(defaults: defaults)
        #expect(settings.fontSize == 20)
    }

    @Test func loadsTabWidthFromDefaults() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        defaults.set(8, forKey: SettingsManager.Keys.tabWidth)
        let settings = SettingsManager(defaults: defaults)
        #expect(settings.tabWidth == 8)
    }

    @Test func loadsThemeFromDefaults() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        defaults.set("solarized", forKey: SettingsManager.Keys.theme)
        let settings = SettingsManager(defaults: defaults)
        #expect(settings.theme == "solarized")
    }

    // MARK: - Edge cases / clamping

    @Test func fontSizeClampedToMin() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        let settings = SettingsManager(defaults: defaults)
        settings.fontSize = 2
        #expect(settings.fontSize == SettingsManager.minFontSize)
    }

    @Test func fontSizeClampedToMax() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        let settings = SettingsManager(defaults: defaults)
        settings.fontSize = 100
        #expect(settings.fontSize == SettingsManager.maxFontSize)
    }

    @Test func tabWidthClampedToMin() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        let settings = SettingsManager(defaults: defaults)
        settings.tabWidth = 0
        #expect(settings.tabWidth == SettingsManager.minTabWidth)
    }

    @Test func tabWidthClampedToMax() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        let settings = SettingsManager(defaults: defaults)
        settings.tabWidth = 20
        #expect(settings.tabWidth == SettingsManager.maxTabWidth)
    }

    @Test func corruptedFontSizeInDefaultsFallsBackToDefault() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        // Negative value
        defaults.set(-5.0, forKey: SettingsManager.Keys.fontSize)
        let settings = SettingsManager(defaults: defaults)
        #expect(settings.fontSize == SettingsManager.defaultFontSize)
    }

    @Test func zeroFontSizeInDefaultsFallsBackToDefault() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        defaults.set(0.0, forKey: SettingsManager.Keys.fontSize)
        let settings = SettingsManager(defaults: defaults)
        #expect(settings.fontSize == SettingsManager.defaultFontSize)
    }

    @Test func corruptedTabWidthInDefaultsFallsBackToDefault() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        // Zero value — integer(forKey:) returns 0 for missing key
        defaults.set(0, forKey: SettingsManager.Keys.tabWidth)
        let settings = SettingsManager(defaults: defaults)
        #expect(settings.tabWidth == SettingsManager.defaultTabWidth)
    }

    @Test func emptyThemeInDefaultsFallsBackToDefault() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        defaults.set("", forKey: SettingsManager.Keys.theme)
        let settings = SettingsManager(defaults: defaults)
        #expect(settings.theme == "default")
    }

    // MARK: - Bool defaults for first launch

    @Test func stripTrailingWhitespaceDefaultsTrueWhenKeyMissing() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        // Key is not set — object(forKey:) returns nil
        let settings = SettingsManager(defaults: defaults)
        #expect(settings.stripTrailingWhitespace == true)
    }

    @Test func showLineNumbersDefaultsTrueWhenKeyMissing() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        let settings = SettingsManager(defaults: defaults)
        #expect(settings.showLineNumbers == true)
    }

    @Test func showMinimapDefaultsTrueWhenKeyMissing() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        let settings = SettingsManager(defaults: defaults)
        #expect(settings.showMinimap == true)
    }

    // MARK: - Keys namespace

    @Test func keysUsePinePrefix() {
        #expect(SettingsManager.Keys.autoSaveEnabled == "pine.autoSaveEnabled")
        #expect(SettingsManager.Keys.stripTrailingWhitespace == "pine.stripTrailingWhitespace")
        #expect(SettingsManager.Keys.fontSize == "pine.fontSize")
        #expect(SettingsManager.Keys.tabWidth == "pine.tabWidth")
        #expect(SettingsManager.Keys.showLineNumbers == "pine.showLineNumbers")
        #expect(SettingsManager.Keys.showMinimap == "pine.showMinimap")
        #expect(SettingsManager.Keys.theme == "pine.theme")
    }
}
