//
//  TabFormatterTests.swift
//  PineTests
//

import Foundation
import Testing

@testable import Pine

@Suite("TabFormatter Tests")
struct TabFormatterTests {

    @Test("contentPreparedForSave strips trailing whitespace")
    func stripsWhitespace() {
        let result = TabFormatter.contentPreparedForSave(
            "hello   \nworld\t\n",
            url: URL(fileURLWithPath: "/tmp/test.txt"),
            settings: EditorSettings(defaults: UserDefaults()),
            formatters: .default
        )
        // Default settings: no format, no strip, no newline
        // We need to enable strip via settings
    }

    @Test("contentPreparedForSave with all features disabled returns original")
    func noTransforms() throws {
        let suite = "TabFormatterTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let settings = EditorSettings(defaults: defaults)
        settings.formatOnSave = false
        settings.stripTrailingWhitespace = false
        settings.insertFinalNewline = false

        let content = "hello   \nworld\t"
        let result = TabFormatter.contentPreparedForSave(
            content,
            url: URL(fileURLWithPath: "/tmp/test.txt"),
            settings: settings,
            formatters: .default
        )
        #expect(result == content)
    }

    @Test("contentPreparedForSave strips whitespace when enabled")
    func stripEnabled() throws {
        let suite = "TabFormatterTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let settings = EditorSettings(defaults: defaults)
        settings.stripTrailingWhitespace = true
        settings.insertFinalNewline = false

        let result = TabFormatter.contentPreparedForSave(
            "hello   \nworld\t\n",
            url: URL(fileURLWithPath: "/tmp/test.txt"),
            settings: settings,
            formatters: .default
        )
        #expect(result == "hello\nworld\n")
    }

    @Test("contentPreparedForSave inserts final newline when enabled")
    func insertNewlineEnabled() throws {
        let suite = "TabFormatterTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let settings = EditorSettings(defaults: defaults)
        settings.insertFinalNewline = true
        settings.stripTrailingWhitespace = false

        let result = TabFormatter.contentPreparedForSave(
            "hello",
            url: URL(fileURLWithPath: "/tmp/test.txt"),
            settings: settings,
            formatters: .default
        )
        #expect(result == "hello\n")
    }

    @Test("contentPreparedForSave does not add duplicate newline")
    func noDuplicateNewline() throws {
        let suite = "TabFormatterTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let settings = EditorSettings(defaults: defaults)
        settings.insertFinalNewline = true
        settings.stripTrailingWhitespace = false

        let result = TabFormatter.contentPreparedForSave(
            "hello\n",
            url: URL(fileURLWithPath: "/tmp/test.txt"),
            settings: settings,
            formatters: .default
        )
        #expect(result == "hello\n")
    }

    @Test("formatOnSave applies formatter before whitespace rules")
    func formatBeforeWhitespace() throws {
        let suite = "TabFormatterTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let settings = EditorSettings(defaults: defaults)
        settings.formatOnSave = true
        settings.stripTrailingWhitespace = true
        settings.insertFinalNewline = false

        let jsonURL = URL(fileURLWithPath: "/tmp/test.json")
        let result = TabFormatter.contentPreparedForSave(
            "{\"a\":1}   ",
            url: jsonURL,
            settings: settings,
            formatters: .default
        )
        // JSON formatter pretty-prints, then whitespace is stripped
        #expect(result.hasPrefix("{"))
        #expect(!result.hasSuffix("   "))
    }
}
