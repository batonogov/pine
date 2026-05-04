//
//  EditorSettingsTests.swift
//  PineTests
//

import Foundation
import Testing

@testable import Pine

@Suite("EditorSettings persistence and defaults")
@MainActor
struct EditorSettingsTests {

    private func makeIsolatedDefaults() -> UserDefaults {
        let suiteName = "EditorSettingsTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Failed to create test UserDefaults suite")
        }
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    /// Calls `TabManager.contentPreparedForSave` with a sentinel URL and an empty
    /// formatter registry — these tests exercise the whitespace/newline rules only.
    private func prepared(_ content: String, settings: EditorSettings) -> String {
        TabManager.contentPreparedForSave(
            content,
            url: URL(fileURLWithPath: "/dev/null"),
            settings: settings,
            formatters: FileFormatterRegistry(formatters: [])
        )
    }

    @Test("Defaults to enabled when no value stored")
    func defaultsEnabled() {
        let defaults = makeIsolatedDefaults()
        let settings = EditorSettings(defaults: defaults)
        #expect(settings.insertFinalNewline == true)
        #expect(settings.stripTrailingWhitespace == true)
        #expect(settings.formatOnSave == false)
    }

    @Test("Respects explicitly stored false")
    func respectsStoredFalse() {
        let defaults = makeIsolatedDefaults()
        defaults.set(false, forKey: EditorSettings.Keys.insertFinalNewline)
        defaults.set(false, forKey: EditorSettings.Keys.stripTrailingWhitespace)
        defaults.set(false, forKey: EditorSettings.Keys.formatOnSave)
        let settings = EditorSettings(defaults: defaults)
        #expect(settings.insertFinalNewline == false)
        #expect(settings.stripTrailingWhitespace == false)
        #expect(settings.formatOnSave == false)
    }

    @Test("Writes to UserDefaults on mutation")
    func persistsMutation() {
        let defaults = makeIsolatedDefaults()
        let settings = EditorSettings(defaults: defaults)
        settings.insertFinalNewline = false
        settings.stripTrailingWhitespace = false
        settings.formatOnSave = false
        #expect(defaults.bool(forKey: EditorSettings.Keys.insertFinalNewline) == false)
        #expect(defaults.bool(forKey: EditorSettings.Keys.stripTrailingWhitespace) == false)
        #expect(defaults.bool(forKey: EditorSettings.Keys.formatOnSave) == false)
    }

    @Test("Re-reading defaults preserves toggled values")
    func roundTrip() {
        let defaults = makeIsolatedDefaults()
        let first = EditorSettings(defaults: defaults)
        first.insertFinalNewline = false
        let second = EditorSettings(defaults: defaults)
        #expect(second.insertFinalNewline == false)
    }

    @Test("contentPreparedForSave applies both transforms when enabled")
    func preparedAppliesBoth() {
        let defaults = makeIsolatedDefaults()
        let settings = EditorSettings(defaults: defaults)
        let input = "hello   \nworld"
        let output = prepared(input, settings: settings)
        #expect(output == "hello\nworld\n")
    }

    @Test("contentPreparedForSave with both disabled is identity")
    func preparedIdentityWhenDisabled() {
        let defaults = makeIsolatedDefaults()
        let settings = EditorSettings(defaults: defaults)
        settings.insertFinalNewline = false
        settings.stripTrailingWhitespace = false
        let input = "hello   \nworld"
        #expect(prepared(input, settings: settings) == input)
    }

    @Test("contentPreparedForSave with only stripping enabled")
    func preparedOnlyStrip() {
        let defaults = makeIsolatedDefaults()
        let settings = EditorSettings(defaults: defaults)
        settings.insertFinalNewline = false
        let input = "hello   \nworld  "
        #expect(prepared(input, settings: settings) == "hello\nworld")
    }

    @Test("contentPreparedForSave with only newline enabled")
    func preparedOnlyNewline() {
        let defaults = makeIsolatedDefaults()
        let settings = EditorSettings(defaults: defaults)
        settings.stripTrailingWhitespace = false
        let input = "hello   \nworld"
        #expect(prepared(input, settings: settings) == "hello   \nworld\n")
    }

    @Test("contentPreparedForSave preserves CRLF style")
    func preparedPreservesCRLF() {
        let defaults = makeIsolatedDefaults()
        let settings = EditorSettings(defaults: defaults)
        let input = "hello  \r\nworld"
        #expect(prepared(input, settings: settings) == "hello\r\nworld\r\n")
    }

    @Test("contentPreparedForSave leaves empty content empty")
    func preparedEmpty() {
        let defaults = makeIsolatedDefaults()
        let settings = EditorSettings(defaults: defaults)
        #expect(prepared("", settings: settings) == "")
    }
}
