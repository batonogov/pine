//
//  FontSizeSettingsTests.swift
//  PineTests
//

import Testing
import Foundation
import AppKit
@testable import Pine

@Suite("FontSizeSettings Tests")
@MainActor
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

    @Test func defaultFontSizeIs12() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        let settings = FontSizeSettings(defaults: defaults)
        #expect(settings.fontSize == 12)
    }

    // MARK: - Increase

    @Test func increaseBumpsBy1() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        let settings = FontSizeSettings(defaults: defaults)
        settings.increase()
        #expect(settings.fontSize == 13)
    }

    @Test func increaseCannotExceedMax() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        let settings = FontSizeSettings(defaults: defaults)
        // Set to max
        for _ in 0..<50 {
            settings.increase()
        }
        #expect(settings.fontSize == 18)

        // One more should stay at max
        settings.increase()
        #expect(settings.fontSize == 18)
    }

    // MARK: - Decrease

    @Test func decreaseBumpsBy1() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        let settings = FontSizeSettings(defaults: defaults)
        settings.decrease()
        #expect(settings.fontSize == 11)
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
        #expect(settings.fontSize == 15)

        settings.reset()
        #expect(settings.fontSize == 12)
    }

    // MARK: - Persistence

    @Test func fontSizePersistsToUserDefaults() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        let settings = FontSizeSettings(defaults: defaults)
        settings.increase()
        settings.increase()

        #expect(defaults.double(forKey: "editorFontSize") == 14)
    }

    @Test func fontSizeLoadsFromUserDefaults() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        defaults.set(Double(15), forKey: "editorFontSize")

        let settings = FontSizeSettings(defaults: defaults)
        #expect(settings.fontSize == 15)
    }

    @Test func invalidPersistedValueClampsToRange() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        defaults.set(Double(100), forKey: "editorFontSize")
        let settings1 = FontSizeSettings(defaults: defaults)
        #expect(settings1.fontSize == 18)

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
        #expect(settings.fontSize == 12)
    }

    // MARK: - Fonts

    @Test func editorFontMatchesFontSize() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        let settings = FontSizeSettings(defaults: defaults)
        #expect(settings.editorFont.pointSize == 12)

        settings.increase()
        #expect(settings.editorFont.pointSize == 13)
    }

    @Test func gutterFontIsSmallerThanEditor() throws {
        let defaults = try makeDefaults()
        defer { cleanupDefaults(defaults) }

        let settings = FontSizeSettings(defaults: defaults)
        #expect(settings.gutterFont.pointSize == 10)

        settings.increase()
        #expect(settings.gutterFont.pointSize == 11)
    }
}
