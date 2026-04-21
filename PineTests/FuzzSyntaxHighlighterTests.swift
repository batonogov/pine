//
//  FuzzSyntaxHighlighterTests.swift
//  PineTests
//
//  Fuzz tests for SyntaxHighlighter grammar loading and rule compilation.
//

import Foundation
import Testing
@testable import Pine

@Suite("Fuzz Syntax Highlighter Tests", .timeLimit(.minutes(2)))
struct FuzzSyntaxHighlighterTests {

    @Test func fuzzGrammarDecoding_randomJSON() {
        var rng = SplitMix64(seed: 47)
        let decoder = JSONDecoder()

        for _ in 0..<100 {
            let json: String
            switch rng.next() % 6 {
            case 0:
                // Completely random bytes
                json = FuzzGen.randomBytes(
                    count: FuzzGen.randomLength(max: 500, rng: &rng),
                    rng: &rng
                )
            case 1:
                // Valid JSON structure but wrong schema
                json = generateRandomJSON(rng: &rng)
            case 2:
                // Grammar-like JSON with invalid regex patterns
                json = generateInvalidRegexGrammar(rng: &rng)
            case 3:
                // Grammar with giant regex
                json = generateGiantRegexGrammar(rng: &rng)
            case 4:
                // Truncated JSON
                let full = generateValidGrammarJSON()
                let cutoff = FuzzGen.randomLength(min: 1, max: full.count, rng: &rng)
                json = String(full.prefix(cutoff))
            default:
                // Empty or whitespace
                json = ""
            }

            // Grammar decoding must not crash
            if let data = json.data(using: .utf8) {
                _ = try? decoder.decode(Grammar.self, from: data)
            }
        }
    }

    @Test func fuzzGrammarDecoding_edgeCases() {
        let decoder = JSONDecoder()
        let inputs = [
            "null",
            "[]",
            "{}",
            "{\"name\": null}",
            "{\"name\": \"\", \"extensions\": [], \"rules\": []}",
            "{\"name\": \"test\", \"extensions\": [\"x\"], \"rules\": [{\"pattern\": \"[\", \"scope\": \"error\"}]}",
            "{\"name\": \"test\", \"extensions\": [\"x\"], \"rules\": [{\"pattern\": \"(?=\", \"scope\": \"error\"}]}",
            "{\"name\": \"test\", \"extensions\": [\"x\"], \"rules\": [{\"pattern\": \"((((((\", \"scope\": \"deep\"}]}",
            String(repeating: "{", count: 1000),
            String(repeating: "[", count: 1000),
            "{\"name\": \"\\u0000\", \"extensions\": [\"\\u0000\"], \"rules\": []}"
        ]
        for input in inputs {
            if let data = input.data(using: .utf8) {
                _ = try? decoder.decode(Grammar.self, from: data)
            }
        }
    }

    @Test func fuzzGrammarDecoding_invalidRegex() {
        // Proxy test: compileRules is private, so we test the full decode path
        // that SyntaxHighlighter uses when loading grammars from JSON.
        // Invalid regex patterns should be silently skipped or handled gracefully.
        let decoder = JSONDecoder()

        let invalidPatterns = ["[", "(", "***", "(?P<invalid>)", "\\\\", "(?="]
        for pattern in invalidPatterns {
            // Escape backslashes and quotes for JSON embedding
            let escaped = pattern
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            let json = """
            {"name":"fuzz","extensions":["fz"],"rules":[{"pattern":"\(escaped)","scope":"error"}]}
            """
            if let data = json.data(using: .utf8) {
                // Grammar must decode without crashing even with invalid regex
                _ = try? decoder.decode(Grammar.self, from: data)
            }
        }
    }

    private func generateRandomJSON(rng: inout SplitMix64) -> String {
        switch rng.next() % 4 {
        case 0:
            return "{\"key\": \(rng.next())}"
        case 1:
            return "[\"a\", \"b\", \(rng.next())]"
        case 2:
            return "{\"name\": \"\(FuzzGen.randomPrintable(count: 10, rng: &rng))\", \"value\": null}"
        default:
            return "{\"\": \"\"}"
        }
    }

    private func generateInvalidRegexGrammar(rng: inout SplitMix64) -> String {
        // Intentionally unescaped: these patterns are meant to produce malformed JSON
        // in some cases, testing the decoder's resilience to garbage input.
        let badPatterns = ["[", "(", "(?=", "***", "\\\\", "+", "?", "{", "{1,", "[^"]
        let pattern = badPatterns[Int(rng.next() % UInt64(badPatterns.count))]
        return """
        {"name":"fuzz","extensions":["fz"],"rules":[{"pattern":"\(pattern)","scope":"error"}]}
        """
    }

    private func generateGiantRegexGrammar(rng: inout SplitMix64) -> String {
        let bigPattern = String(repeating: "a", count: Int(rng.next() % 5000 + 100))
        return """
        {"name":"giant","extensions":["gnt"],"rules":[{"pattern":"\(bigPattern)","scope":"keyword"}]}
        """
    }

    private func generateValidGrammarJSON() -> String {
        """
        {"name":"test","extensions":["tst"],"rules":[{"pattern":"\\\\bfunc\\\\b","scope":"keyword"}]}
        """
    }
}
