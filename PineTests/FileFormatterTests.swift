//
//  FileFormatterTests.swift
//  PineTests
//

import Foundation
import Testing

@testable import Pine

@Suite("JSONFileFormatter")
@MainActor
struct JSONFileFormatterTests {
    private let formatter = JSONFileFormatter()

    @Test("Claims .json files and rejects others")
    func canFormatGating() {
        #expect(formatter.canFormat(url: URL(fileURLWithPath: "/tmp/a.json")))
        #expect(formatter.canFormat(url: URL(fileURLWithPath: "/tmp/A.JSON")))
        #expect(!formatter.canFormat(url: URL(fileURLWithPath: "/tmp/a.yaml")))
        #expect(!formatter.canFormat(url: URL(fileURLWithPath: "/tmp/a.swift")))
        #expect(!formatter.canFormat(url: URL(fileURLWithPath: "/tmp/json")))
    }

    @Test("Pretty-prints a compact object")
    func prettyPrintObject() {
        let input = #"{"b":1,"a":2}"#
        let output = formatter.format(input)
        // Sorted keys: "a" before "b", 2-space indent, no trailing newline.
        #expect(output == "{\n  \"a\" : 2,\n  \"b\" : 1\n}")
    }

    @Test("Sorted keys are deterministic")
    func sortedKeysAreDeterministic() {
        let a = formatter.format(#"{"z":1,"a":2,"m":3}"#)
        let b = formatter.format(#"{"a":2,"m":3,"z":1}"#)
        #expect(a == b)
    }

    @Test("Is idempotent — format(format(x)) == format(x)")
    func idempotent() {
        let once = formatter.format(#"{"b":1,"a":[1,2,3]}"#)
        let twice = formatter.format(once)
        #expect(once == twice)
    }

    @Test("Preserves invalid JSON unchanged")
    func preservesInvalid() {
        let broken = "{ not json"
        #expect(formatter.format(broken) == broken)
    }

    @Test("Preserves empty content")
    func preservesEmpty() {
        #expect(formatter.format("") == "")
        #expect(formatter.format("   \n  ") == "   \n  ")
    }

    @Test("Accepts top-level fragments (numbers, strings, arrays)")
    func topLevelFragments() {
        #expect(formatter.format("42") == "42")
        // String fragments may be reformatted but must still round-trip back to the
        // same JSON value.
        let stringFrag = formatter.format("\"hello\"")
        #expect(stringFrag.contains("hello"))
    }

    @Test("Formats arrays with sorted keys in nested objects")
    func nestedArray() {
        let input = #"[{"z":1,"a":2},{"b":3}]"#
        let output = formatter.format(input)
        #expect(output.contains("\"a\" : 2"))
        #expect(output.contains("\"z\" : 1"))
        #expect(output.contains("\"b\" : 3"))
    }

    @Test("Trailing newline is NOT added by the formatter (left to save pipeline)")
    func noTrailingNewlineFromFormatter() {
        let output = formatter.format(#"{"a":1}"#)
        #expect(!output.hasSuffix("\n"))
    }
}

@Suite("FileFormatterRegistry dispatch")
@MainActor
struct FileFormatterRegistryTests {

    struct SpyFormatter: FileFormatter {
        let ext: String
        let reply: String
        func canFormat(url: URL) -> Bool { url.pathExtension == ext }
        func format(_ content: String) -> String { reply }
    }

    @Test("Empty registry is a no-op")
    func emptyIsNoOp() {
        let registry = FileFormatterRegistry(formatters: [])
        #expect(registry.format(content: "x", url: URL(fileURLWithPath: "/tmp/x.json")) == "x")
    }

    @Test("Applies the first matching formatter only")
    func firstMatchWins() {
        let registry = FileFormatterRegistry(formatters: [
            SpyFormatter(ext: "json", reply: "FIRST"),
            SpyFormatter(ext: "json", reply: "SECOND")
        ])
        let url = URL(fileURLWithPath: "/tmp/a.json")
        #expect(registry.format(content: "x", url: url) == "FIRST")
    }

    @Test("Falls through to original when no formatter claims the file")
    func fallsThrough() {
        let registry = FileFormatterRegistry(formatters: [
            SpyFormatter(ext: "json", reply: "X")
        ])
        let url = URL(fileURLWithPath: "/tmp/a.yaml")
        #expect(registry.format(content: "hello", url: url) == "hello")
    }

    @Test("Default registry includes JSON formatter")
    func defaultIncludesJSON() {
        let url = URL(fileURLWithPath: "/tmp/a.json")
        let output = FileFormatterRegistry.default.format(content: #"{"a":1}"#, url: url)
        #expect(output.contains("\"a\" : 1"))
    }
}

@Suite("TabManager.contentPreparedForSave with formatters")
@MainActor
struct ContentPreparedForSaveTests {

    private func makeSettings(format: Bool = true, strip: Bool = true, newline: Bool = true) -> EditorSettings {
        let suite = "ContentPreparedForSaveTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            fatalError("Failed to create test UserDefaults")
        }
        defaults.removePersistentDomain(forName: suite)
        let settings = EditorSettings(defaults: defaults)
        settings.formatOnSave = format
        settings.stripTrailingWhitespace = strip
        settings.insertFinalNewline = newline
        return settings
    }

    @Test("JSON: format, strip, and newline all apply")
    func jsonFullPipeline() {
        let settings = makeSettings()
        let url = URL(fileURLWithPath: "/tmp/config.json")
        let input = #"{"b":1,"a":2}"#
        let output = TabManager.contentPreparedForSave(
            input,
            url: url,
            settings: settings,
            formatters: .default
        )
        // Pretty-printed, sorted, with a trailing newline.
        #expect(output.hasSuffix("\n"))
        #expect(output.contains("\"a\" : 2"))
        #expect(output.contains("\"b\" : 1"))
    }

    @Test("JSON: formatOnSave=false skips formatter but still strips/newlines")
    func jsonFormatDisabled() {
        let settings = makeSettings(format: false)
        let url = URL(fileURLWithPath: "/tmp/a.json")
        let input = #"{"b":1,"a":2}   "#
        let output = TabManager.contentPreparedForSave(
            input,
            url: url,
            settings: settings,
            formatters: .default
        )
        #expect(output == "{\"b\":1,\"a\":2}\n")
    }

    @Test("Non-JSON file passes through formatter unchanged")
    func nonJSONUntouched() {
        let settings = makeSettings()
        let url = URL(fileURLWithPath: "/tmp/a.swift")
        let input = "let x = 1"
        let output = TabManager.contentPreparedForSave(
            input,
            url: url,
            settings: settings,
            formatters: .default
        )
        #expect(output == "let x = 1\n")
    }

    @Test("Broken JSON is preserved (formatter no-ops, other rules still apply)")
    func brokenJSONIsPreserved() {
        let settings = makeSettings()
        let url = URL(fileURLWithPath: "/tmp/a.json")
        let input = "{ not json   "
        let output = TabManager.contentPreparedForSave(
            input,
            url: url,
            settings: settings,
            formatters: .default
        )
        // Formatter returned input; strip removed trailing spaces; newline added.
        #expect(output == "{ not json\n")
    }

    @Test("Empty JSON file stays empty")
    func emptyJSON() {
        let settings = makeSettings()
        let url = URL(fileURLWithPath: "/tmp/a.json")
        let output = TabManager.contentPreparedForSave(
            "",
            url: url,
            settings: settings,
            formatters: .default
        )
        #expect(output == "")
    }

    @Test("All flags off: identity transform")
    func allFlagsOff() {
        let settings = makeSettings(format: false, strip: false, newline: false)
        let url = URL(fileURLWithPath: "/tmp/a.json")
        let input = #"{"b":1,"a":2}  "#
        let output = TabManager.contentPreparedForSave(
            input,
            url: url,
            settings: settings,
            formatters: .default
        )
        #expect(output == input)
    }

    @Test("Idempotent: running the pipeline twice gives the same result")
    func idempotentPipeline() {
        let settings = makeSettings()
        let url = URL(fileURLWithPath: "/tmp/a.json")
        let once = TabManager.contentPreparedForSave(
            #"{"a":1,"b":[2,3]}"#,
            url: url,
            settings: settings,
            formatters: .default
        )
        let twice = TabManager.contentPreparedForSave(
            once,
            url: url,
            settings: settings,
            formatters: .default
        )
        #expect(once == twice)
    }
}
