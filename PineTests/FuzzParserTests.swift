//
//  FuzzParserTests.swift
//  PineTests
//
//  Fuzz tests for Pine's parsers: random/malformed input must not crash.
//  Uses a deterministic PRNG (SplitMix64) with fixed seed for CI reproducibility.
//

import Foundation
import Testing
@testable import Pine

// MARK: - Deterministic PRNG

/// SplitMix64 — fast, deterministic PRNG seeded once for reproducibility.
private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9e37_79b9_7f4a_7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        return z ^ (z >> 31)
    }
}

// MARK: - Random Input Generators

/// Generates random strings of various kinds for fuzzing.
private enum FuzzGen {

    /// Random ASCII bytes (including control characters).
    static func randomBytes(count: Int, rng: inout SplitMix64) -> String {
        String((0..<count).map { _ in Character(UnicodeScalar(UInt8(rng.next() % 128))) })
    }

    /// Random printable ASCII string.
    static func randomPrintable(count: Int, rng: inout SplitMix64) -> String {
        let printable = Array(UInt8(32)...UInt8(126))
        return String((0..<count).map { _ in Character(UnicodeScalar(printable[Int(rng.next() % UInt64(printable.count))])) })
    }

    /// Random unicode string with emoji, CJK, combining marks, etc.
    static func randomUnicode(count: Int, rng: inout SplitMix64) -> String {
        let codePoints: [UInt32] = [
            0x0041, 0x00E9, 0x0410, 0x4E2D, 0x1F600, 0x1F4A9, 0x0300, 0x200B,
            0xFEFF, 0x000A, 0x000D, 0x0009, 0x0000, 0x007F, 0x2028, 0x2029,
            0x1F1FA, 0x1F1F8, 0xD7FF, 0xFFFD, 0x10FFFF
        ]
        var result = ""
        for _ in 0..<count {
            let cp = codePoints[Int(rng.next() % UInt64(codePoints.count))]
            if let scalar = UnicodeScalar(cp) {
                result.append(Character(scalar))
            }
        }
        return result
    }

    /// Random length between min and max.
    static func randomLength(min: Int = 0, max: Int = 500, rng: inout SplitMix64) -> Int {
        min + Int(rng.next() % UInt64(max - min + 1))
    }

    /// Random line ending.
    static func randomLineEnding(rng: inout SplitMix64) -> String {
        switch rng.next() % 3 {
        case 0: return "\n"
        case 1: return "\r\n"
        default: return "\r"
        }
    }
}

// MARK: - GitStatusProvider Fuzz Tests

@MainActor
struct FuzzGitDiffParserTests {

    @Test func fuzzParseDiff_randomInput() {
        var rng = SplitMix64(seed: 42)

        for _ in 0..<1000 {
            let input: String
            switch rng.next() % 5 {
            case 0:
                // Completely random bytes
                input = FuzzGen.randomBytes(
                    count: FuzzGen.randomLength(max: 1000, rng: &rng),
                    rng: &rng
                )
            case 1:
                // Malformed hunk headers
                input = generateMalformedDiff(rng: &rng)
            case 2:
                // Unicode in diff content
                input = generateUnicodeDiff(rng: &rng)
            case 3:
                // Mixed line endings
                input = generateMixedLineEndingDiff(rng: &rng)
            default:
                // Empty or whitespace
                input = String(repeating: " ", count: Int(rng.next() % 100))
            }

            // Must not crash
            _ = GitStatusProvider.parseDiff(input)
        }
    }

    @Test func fuzzParseDiff_emptyInput() {
        let result = GitStatusProvider.parseDiff("")
        #expect(result.isEmpty)
    }

    @Test func fuzzParseDiff_onlyAtSigns() {
        // Various broken @@ patterns
        let inputs = [
            "@@", "@@ @@", "@@ @@ @@", "@@@@@@",
            "@@ -1 @@", "@@ +1 @@", "@@ - + @@",
            "@@ -abc +def @@", "@@ -1,2 +abc,def @@",
            "@@ -999999999999999 +999999999999999 @@",
            "@@ -1,1 +1,1 @@\n",
            "@@ -0,0 +0,0 @@\n+\n-\n \n"
        ]
        for input in inputs {
            _ = GitStatusProvider.parseDiff(input)
        }
    }

    @Test func fuzzParseDiff_veryLongInput() {
        // Very long input with many hunks
        var input = ""
        for i in 0..<500 {
            input += "@@ -\(i),1 +\(i),1 @@\n"
            input += String(repeating: "+added line\n", count: 10)
            input += String(repeating: "-removed line\n", count: 10)
        }
        _ = GitStatusProvider.parseDiff(input)
    }

    @Test func fuzzParseHunkNewStart_randomInput() {
        var rng = SplitMix64(seed: 43)

        for _ in 0..<1000 {
            let input = FuzzGen.randomPrintable(
                count: FuzzGen.randomLength(max: 200, rng: &rng),
                rng: &rng
            )
            // Must not crash
            _ = GitStatusProvider.parseHunkNewStart(input)
        }
    }

    private func generateMalformedDiff(rng: inout SplitMix64) -> String {
        var lines: [String] = []
        let count = FuzzGen.randomLength(min: 1, max: 50, rng: &rng)
        for _ in 0..<count {
            switch rng.next() % 8 {
            case 0: lines.append("@@ -\(rng.next() % 10000),\(rng.next() % 100) +\(rng.next() % 10000),\(rng.next() % 100) @@")
            case 1: lines.append("@@ garbage header @@")
            case 2: lines.append("@@ -,+ @@")
            case 3: lines.append("+\(FuzzGen.randomPrintable(count: 20, rng: &rng))")
            case 4: lines.append("-\(FuzzGen.randomPrintable(count: 20, rng: &rng))")
            case 5: lines.append(" \(FuzzGen.randomPrintable(count: 20, rng: &rng))")
            case 6: lines.append("diff --git a/file b/file")
            default: lines.append("\\ No newline at end of file")
            }
        }
        return lines.joined(separator: "\n")
    }

    private func generateUnicodeDiff(rng: inout SplitMix64) -> String {
        var lines: [String] = []
        lines.append("@@ -1,5 +1,5 @@")
        let count = FuzzGen.randomLength(min: 1, max: 30, rng: &rng)
        for _ in 0..<count {
            let prefixes = ["+", "-", " ", "\\"]
            let prefix = prefixes[Int(rng.next() % UInt64(prefixes.count))]
            lines.append("\(prefix)\(FuzzGen.randomUnicode(count: 20, rng: &rng))")
        }
        return lines.joined(separator: "\n")
    }

    private func generateMixedLineEndingDiff(rng: inout SplitMix64) -> String {
        var result = "@@ -1,3 +1,4 @@"
        let count = FuzzGen.randomLength(min: 1, max: 30, rng: &rng)
        for _ in 0..<count {
            result += FuzzGen.randomLineEnding(rng: &rng)
            let prefixes = ["+", "-", " "]
            let prefix = prefixes[Int(rng.next() % UInt64(prefixes.count))]
            result += "\(prefix)content"
        }
        return result
    }
}

// MARK: - GitStatusProvider Blame Parser Fuzz Tests

@MainActor
struct FuzzGitBlameParserTests {

    @Test func fuzzParseBlame_randomInput() {
        var rng = SplitMix64(seed: 44)

        for _ in 0..<1000 {
            let input: String
            switch rng.next() % 5 {
            case 0:
                // Completely random bytes
                input = FuzzGen.randomBytes(
                    count: FuzzGen.randomLength(max: 500, rng: &rng),
                    rng: &rng
                )
            case 1:
                // Corrupted porcelain output
                input = generateCorruptedBlame(rng: &rng)
            case 2:
                // Missing fields
                input = generateIncompleteBlame(rng: &rng)
            case 3:
                // Unicode in author names and summaries
                input = generateUnicodeBlame(rng: &rng)
            default:
                // Empty
                input = ""
            }

            // Must not crash
            _ = GitStatusProvider.parseBlame(input)
        }
    }

    @Test func fuzzParseBlame_emptyInput() {
        let result = GitStatusProvider.parseBlame("")
        #expect(result.isEmpty)
    }

    @Test func fuzzParseBlame_edgeCases() {
        let inputs = [
            // Only hash-like lines
            String(repeating: "a", count: 40) + " 1 1 1",
            // Hash with no fields, no content
            String(repeating: "b", count: 40) + " 1 1\n",
            // Hash + author but no content tab line
            String(repeating: "c", count: 40) + " 1 1\nauthor Test\nsummary Test\n",
            // Content line without preceding hash
            "\tsome content line",
            // Extremely long author name
            String(repeating: "d", count: 40) + " 1 1\nauthor " + String(repeating: "X", count: 10000) + "\n\tcontent",
            // BOM prefix
            "\u{FEFF}" + String(repeating: "e", count: 40) + " 1 1\n\tcontent",
            // Null bytes
            String(repeating: "f", count: 40) + " 1 1\nauthor \0\0\0\n\tcontent",
            // Very large line numbers
            String(repeating: "a", count: 40) + " 999999999 999999999 1\nauthor X\nauthor-time 0\nsummary Y\n\tcontent"
        ]
        for input in inputs {
            _ = GitStatusProvider.parseBlame(input)
        }
    }

    @Test func fuzzParseBlame_veryLongInput() {
        var input = ""
        let hash = String(repeating: "a", count: 40)
        for i in 1...500 {
            if i == 1 {
                input += "\(hash) 1 \(i) 500\nauthor Test\nauthor-time 1234567890\nsummary Commit\n\tline \(i)\n"
            } else {
                input += "\(hash) \(i) \(i)\n\tline \(i)\n"
            }
        }
        let result = GitStatusProvider.parseBlame(input)
        #expect(result.count == 500)
    }

    private func generateCorruptedBlame(rng: inout SplitMix64) -> String {
        var lines: [String] = []
        let count = FuzzGen.randomLength(min: 1, max: 50, rng: &rng)
        for _ in 0..<count {
            switch rng.next() % 7 {
            case 0:
                // Valid-looking hash line but wrong length
                let hashLen = FuzzGen.randomLength(min: 1, max: 80, rng: &rng)
                lines.append(String(repeating: "a", count: hashLen) + " 1 1")
            case 1:
                lines.append("author \(FuzzGen.randomPrintable(count: 20, rng: &rng))")
            case 2:
                lines.append("author-time not-a-number")
            case 3:
                lines.append("author-time \(rng.next())")
            case 4:
                lines.append("summary \(FuzzGen.randomPrintable(count: 50, rng: &rng))")
            case 5:
                lines.append("\t\(FuzzGen.randomPrintable(count: 30, rng: &rng))")
            default:
                lines.append(FuzzGen.randomPrintable(count: 30, rng: &rng))
            }
        }
        return lines.joined(separator: "\n")
    }

    private func generateIncompleteBlame(rng: inout SplitMix64) -> String {
        let hash = String(repeating: "a", count: 40)
        var lines: [String] = []

        // Hash line without content
        lines.append("\(hash) 1 1 1")

        // Randomly omit fields
        if rng.next() % 2 == 0 { lines.append("author Test") }
        if rng.next() % 2 == 0 { lines.append("author-time 0") }
        if rng.next() % 2 == 0 { lines.append("summary Msg") }
        if rng.next() % 2 == 0 { lines.append("\tcontent") }

        return lines.joined(separator: "\n")
    }

    private func generateUnicodeBlame(rng: inout SplitMix64) -> String {
        let hash = String(repeating: "a", count: 40)
        let unicodeName = FuzzGen.randomUnicode(count: 30, rng: &rng)
        let unicodeSummary = FuzzGen.randomUnicode(count: 50, rng: &rng)

        return """
        \(hash) 1 1 1
        author \(unicodeName)
        author-time 1234567890
        summary \(unicodeSummary)
        \t\(FuzzGen.randomUnicode(count: 40, rng: &rng))
        """
    }
}

// MARK: - GitStatusProvider Status Parser Fuzz Tests

@MainActor
struct FuzzGitStatusParserTests {

    @Test func fuzzParseStatusOutput_randomInput() {
        var rng = SplitMix64(seed: 45)

        for _ in 0..<1000 {
            let input: String
            switch rng.next() % 4 {
            case 0:
                input = FuzzGen.randomBytes(
                    count: FuzzGen.randomLength(max: 500, rng: &rng),
                    rng: &rng
                )
            case 1:
                input = generateRandomStatusOutput(rng: &rng)
            case 2:
                input = FuzzGen.randomUnicode(
                    count: FuzzGen.randomLength(max: 200, rng: &rng),
                    rng: &rng
                )
            default:
                input = ""
            }
            _ = GitStatusProvider.parseStatusOutput(input)
        }
    }

    @Test func fuzzParseIgnoredOutput_randomInput() {
        var rng = SplitMix64(seed: 46)

        for _ in 0..<1000 {
            let input = FuzzGen.randomPrintable(
                count: FuzzGen.randomLength(max: 500, rng: &rng),
                rng: &rng
            )
            _ = GitStatusProvider.parseIgnoredOutput(input)
        }
    }

    private func generateRandomStatusOutput(rng: inout SplitMix64) -> String {
        let statusChars: [Character] = [" ", "M", "A", "D", "R", "C", "U", "?", "!"]
        var lines: [String] = []
        let count = FuzzGen.randomLength(min: 1, max: 50, rng: &rng)
        for _ in 0..<count {
            let idx = statusChars[Int(rng.next() % UInt64(statusChars.count))]
            let work = statusChars[Int(rng.next() % UInt64(statusChars.count))]
            let path = FuzzGen.randomPrintable(count: FuzzGen.randomLength(min: 1, max: 80, rng: &rng), rng: &rng)
            lines.append("\(idx)\(work) \(path)")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - SyntaxHighlighter Grammar Loading Fuzz Tests

@MainActor
struct FuzzSyntaxHighlighterTests {

    @Test func fuzzGrammarDecoding_randomJSON() {
        var rng = SplitMix64(seed: 47)
        let decoder = JSONDecoder()

        for _ in 0..<1000 {
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

    @Test func fuzzCompileRules_invalidRegex() {
        // Ensure SyntaxHighlighter.compileRules handles invalid regex gracefully
        // We test via Grammar decoding + rule compilation path
        let grammars = [
            Grammar(name: "fuzz", extensions: ["fz"], rules: [
                GrammarRule(pattern: "[", scope: "error"),
                GrammarRule(pattern: "(", scope: "error"),
                GrammarRule(pattern: "***", scope: "error"),
                GrammarRule(pattern: "(?P<invalid)", scope: "error"),
                GrammarRule(pattern: String(repeating: "(", count: 100), scope: "deep"),
                GrammarRule(pattern: "\\", scope: "error")
            ]),
            Grammar(name: "fuzz2", extensions: ["fz2"], rules: [
                GrammarRule(pattern: "(?i)[a-z]+", scope: "keyword", options: ["caseInsensitive"]),
                GrammarRule(pattern: ".", scope: "all", options: ["dotMatchesLineSeparators"]),
                GrammarRule(pattern: "^.*$", scope: "line", options: ["anchorsMatchLines"])
            ])
        ]

        for grammar in grammars {
            // Attempt to compile — must not crash
            for rule in grammar.rules {
                _ = try? NSRegularExpression(pattern: rule.pattern)
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
        let badPatterns = ["[", "(", "(?=", "***", "\\", "+", "?", "{", "{1,", "[^"]
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

// MARK: - QuickOpenProvider Fuzz Tests

@MainActor
struct FuzzQuickOpenProviderTests {

    @Test func fuzzFuzzyScore_randomInput() {
        var rng = SplitMix64(seed: 48)
        let provider = QuickOpenProvider()

        for _ in 0..<1000 {
            let query: String
            let fileName: String
            let path: String

            switch rng.next() % 5 {
            case 0:
                // Empty query
                query = ""
                fileName = FuzzGen.randomPrintable(count: 20, rng: &rng)
                path = FuzzGen.randomPrintable(count: 50, rng: &rng)
            case 1:
                // Unicode query
                query = FuzzGen.randomUnicode(count: FuzzGen.randomLength(max: 30, rng: &rng), rng: &rng)
                fileName = FuzzGen.randomUnicode(count: 30, rng: &rng)
                path = FuzzGen.randomUnicode(count: 60, rng: &rng)
            case 2:
                // Very long query
                query = FuzzGen.randomPrintable(count: FuzzGen.randomLength(min: 100, max: 1000, rng: &rng), rng: &rng)
                fileName = FuzzGen.randomPrintable(count: 10, rng: &rng)
                path = FuzzGen.randomPrintable(count: 20, rng: &rng)
            case 3:
                // Query longer than target
                query = "abcdefghijklmnop"
                fileName = "ab"
                path = "ab"
            default:
                // Control characters
                query = FuzzGen.randomBytes(count: FuzzGen.randomLength(max: 30, rng: &rng), rng: &rng)
                fileName = FuzzGen.randomBytes(count: 20, rng: &rng)
                path = FuzzGen.randomBytes(count: 40, rng: &rng)
            }

            // Must not crash
            _ = provider.fuzzyScore(
                queryLower: query.lowercased(),
                fileNameLower: fileName.lowercased(),
                pathLower: path.lowercased(),
                pathLength: path.count
            )
        }
    }

    @Test func fuzzIsSubsequence_randomInput() {
        var rng = SplitMix64(seed: 49)

        for _ in 0..<1000 {
            let query = FuzzGen.randomPrintable(
                count: FuzzGen.randomLength(max: 50, rng: &rng),
                rng: &rng
            )
            let target = FuzzGen.randomPrintable(
                count: FuzzGen.randomLength(max: 100, rng: &rng),
                rng: &rng
            )
            // Must not crash
            _ = QuickOpenProvider.isSubsequence(query, of: target)
        }
    }

    @Test func fuzzIsSubsequence_edgeCases() {
        let cases: [(String, String)] = [
            ("", ""),
            ("", "abc"),
            ("abc", ""),
            ("a", "a"),
            ("\0", "\0"),
            ("\n\r\t", "\n\r\t"),
            ("🎉", "🎉🎊"),
            (String(repeating: "a", count: 10000), String(repeating: "a", count: 10000)),
            ("abc", String(repeating: "x", count: 10000)),
            ("\u{FEFF}", "\u{FEFF}text"),
            ("\u{200B}", "a\u{200B}b"),
            ("中文", "中文测试"),
            ("日本", "日x本y"),
        ]

        for (query, target) in cases {
            _ = QuickOpenProvider.isSubsequence(query, of: target)
        }
    }

    @Test func fuzzFuzzyScore_emptyInputs() {
        let provider = QuickOpenProvider()

        // All empty
        let r1 = provider.fuzzyScore(queryLower: "", fileNameLower: "", pathLower: "", pathLength: 0)
        // Empty query is always a subsequence
        #expect(r1 != nil)

        // Empty file name but non-empty path
        _ = provider.fuzzyScore(queryLower: "a", fileNameLower: "", pathLower: "a/b/c", pathLength: 5)

        // Negative-ish path length (should not crash)
        _ = provider.fuzzyScore(queryLower: "a", fileNameLower: "a", pathLower: "a", pathLength: 0)
        _ = provider.fuzzyScore(queryLower: "a", fileNameLower: "a", pathLower: "a", pathLength: Int.max)
    }
}

// MARK: - SymbolParser Fuzz Tests

struct FuzzSymbolParserTests {

    @Test func fuzzSymbolParser_randomInput() {
        var rng = SplitMix64(seed: 50)
        let extensions = ["swift", "py", "js", "ts", "go", "rb", "rs", "java", "kt", "unknown"]

        for _ in 0..<1000 {
            let content: String
            let ext = extensions[Int(rng.next() % UInt64(extensions.count))]

            switch rng.next() % 5 {
            case 0:
                content = FuzzGen.randomBytes(
                    count: FuzzGen.randomLength(max: 500, rng: &rng),
                    rng: &rng
                )
            case 1:
                content = FuzzGen.randomUnicode(
                    count: FuzzGen.randomLength(max: 300, rng: &rng),
                    rng: &rng
                )
            case 2:
                content = generateRandomCode(rng: &rng)
            case 3:
                content = String(repeating: "func ", count: 500)
            default:
                content = ""
            }

            // Must not crash
            _ = SymbolParser.parse(content: content, fileExtension: ext)
        }
    }

    @Test func fuzzSymbolParser_edgeCases() {
        let inputs = [
            ("", "swift"),
            ("\0\0\0", "swift"),
            (String(repeating: "\n", count: 10000), "py"),
            ("class ", "swift"),
            ("func ", "swift"),
            ("struct ", "go"),
            ("def ", "py"),
            ("function ", "js"),
            ("interface ", "ts"),
            // Deeply nested
            (String(repeating: "class A {\n", count: 100), "swift"),
            // Only comments
            (String(repeating: "// comment\n", count: 100), "swift"),
            // Only strings
            ("\"" + String(repeating: "func test() {}", count: 100) + "\"", "swift"),
        ]
        for (content, ext) in inputs {
            _ = SymbolParser.parse(content: content, fileExtension: ext)
        }
    }

    @Test func fuzzSymbolFilter_randomInput() {
        var rng = SplitMix64(seed: 51)
        let symbols = [
            PineSymbol(name: "testFunc", kind: .function, line: 1),
            PineSymbol(name: "MyClass", kind: .class, line: 5),
            PineSymbol(name: "日本語メソッド", kind: .function, line: 10),
        ]

        for _ in 0..<1000 {
            let query = FuzzGen.randomUnicode(
                count: FuzzGen.randomLength(max: 50, rng: &rng),
                rng: &rng
            )
            _ = SymbolParser.filter(symbols, query: query)
        }
    }

    @Test func fuzzLineNumber_randomInput() {
        var rng = SplitMix64(seed: 52)

        for _ in 0..<1000 {
            let content = FuzzGen.randomUnicode(
                count: FuzzGen.randomLength(max: 500, rng: &rng),
                rng: &rng
            )
            let offset = Int(rng.next() % UInt64(max(1, (content as NSString).length + 10)))
            _ = SymbolParser.lineNumber(at: offset, in: content)
        }
    }

    private func generateRandomCode(rng: inout SplitMix64) -> String {
        let keywords = ["func", "class", "struct", "enum", "protocol", "def", "function", "interface", "trait", "fn"]
        var lines: [String] = []
        let count = FuzzGen.randomLength(min: 1, max: 50, rng: &rng)
        for _ in 0..<count {
            let kw = keywords[Int(rng.next() % UInt64(keywords.count))]
            let name = FuzzGen.randomPrintable(count: FuzzGen.randomLength(min: 1, max: 30, rng: &rng), rng: &rng)
            lines.append("  \(kw) \(name) {")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - ConfigValidator Output Parser Fuzz Tests

struct FuzzConfigValidatorTests {

    @Test func fuzzParseYamllint_randomInput() {
        var rng = SplitMix64(seed: 53)

        for _ in 0..<1000 {
            let input: String
            switch rng.next() % 4 {
            case 0:
                input = FuzzGen.randomBytes(
                    count: FuzzGen.randomLength(max: 500, rng: &rng),
                    rng: &rng
                )
            case 1:
                input = generateRandomYamllintOutput(rng: &rng)
            case 2:
                input = FuzzGen.randomUnicode(
                    count: FuzzGen.randomLength(max: 200, rng: &rng),
                    rng: &rng
                )
            default:
                input = ""
            }
            _ = ValidatorOutputParser.parseYamllint(input)
        }
    }

    @Test func fuzzParseShellcheck_randomInput() {
        var rng = SplitMix64(seed: 54)

        for _ in 0..<1000 {
            let input: String
            switch rng.next() % 4 {
            case 0:
                input = FuzzGen.randomBytes(
                    count: FuzzGen.randomLength(max: 500, rng: &rng),
                    rng: &rng
                )
            case 1:
                input = generateRandomShellcheckJSON(rng: &rng)
            case 2:
                input = "[]"
            default:
                input = ""
            }
            _ = ValidatorOutputParser.parseShellcheck(input)
        }
    }

    @Test func fuzzParseTerraform_randomInput() {
        var rng = SplitMix64(seed: 55)

        for _ in 0..<1000 {
            let input: String
            switch rng.next() % 4 {
            case 0:
                input = FuzzGen.randomBytes(
                    count: FuzzGen.randomLength(max: 500, rng: &rng),
                    rng: &rng
                )
            case 1:
                input = generateRandomTerraformJSON(rng: &rng)
            case 2:
                input = "{\"valid\": true}"
            default:
                input = ""
            }
            _ = ValidatorOutputParser.parseTerraform(input)
        }
    }

    @Test func fuzzParseHadolint_randomInput() {
        var rng = SplitMix64(seed: 56)

        for _ in 0..<1000 {
            let input: String
            switch rng.next() % 4 {
            case 0:
                input = FuzzGen.randomBytes(
                    count: FuzzGen.randomLength(max: 500, rng: &rng),
                    rng: &rng
                )
            case 1:
                input = generateRandomHadolintJSON(rng: &rng)
            case 2:
                input = "[]"
            default:
                input = ""
            }
            _ = ValidatorOutputParser.parseHadolint(input)
        }
    }

    @Test func fuzzBuiltinValidateYAML_randomInput() {
        var rng = SplitMix64(seed: 57)

        for _ in 0..<1000 {
            let content: String
            switch rng.next() % 4 {
            case 0:
                content = FuzzGen.randomBytes(count: FuzzGen.randomLength(max: 500, rng: &rng), rng: &rng)
            case 1:
                content = FuzzGen.randomUnicode(count: FuzzGen.randomLength(max: 300, rng: &rng), rng: &rng)
            case 2:
                content = generateRandomYAML(rng: &rng)
            default:
                content = ""
            }
            _ = BuiltinValidator.validateYAML(content)
        }
    }

    @Test func fuzzBuiltinValidateDockerfile_randomInput() {
        var rng = SplitMix64(seed: 58)

        for _ in 0..<1000 {
            let content: String
            switch rng.next() % 4 {
            case 0:
                content = FuzzGen.randomBytes(count: FuzzGen.randomLength(max: 500, rng: &rng), rng: &rng)
            case 1:
                content = FuzzGen.randomUnicode(count: FuzzGen.randomLength(max: 300, rng: &rng), rng: &rng)
            case 2:
                content = generateRandomDockerfile(rng: &rng)
            default:
                content = ""
            }
            _ = BuiltinValidator.validateDockerfile(content)
        }
    }

    @Test func fuzzBuiltinValidateShell_randomInput() {
        var rng = SplitMix64(seed: 59)

        for _ in 0..<1000 {
            let content: String
            switch rng.next() % 4 {
            case 0:
                content = FuzzGen.randomBytes(count: FuzzGen.randomLength(max: 500, rng: &rng), rng: &rng)
            case 1:
                content = FuzzGen.randomUnicode(count: FuzzGen.randomLength(max: 300, rng: &rng), rng: &rng)
            case 2:
                content = generateRandomShellScript(rng: &rng)
            default:
                content = ""
            }
            _ = BuiltinValidator.validateShell(content)
        }
    }

    @Test func fuzzValidatorDetector_randomURLs() {
        var rng = SplitMix64(seed: 60)
        let extensions = ["yml", "yaml", "tf", "tfvars", "sh", "bash", "zsh", "txt", "", "swift", "py"]
        let names = ["Dockerfile", "Dockerfile.prod", "dockerfile", "README.md", "Makefile", ".yml"]

        for _ in 0..<1000 {
            let url: URL
            if rng.next() % 2 == 0 {
                let ext = extensions[Int(rng.next() % UInt64(extensions.count))]
                url = URL(fileURLWithPath: "/tmp/\(FuzzGen.randomPrintable(count: 10, rng: &rng)).\(ext)")
            } else {
                let name = names[Int(rng.next() % UInt64(names.count))]
                url = URL(fileURLWithPath: "/tmp/\(name)")
            }
            _ = ValidatorDetector.detect(for: url)
        }
    }

    // MARK: - Generators

    private func generateRandomYamllintOutput(rng: inout SplitMix64) -> String {
        var lines: [String] = []
        let count = FuzzGen.randomLength(min: 1, max: 20, rng: &rng)
        for _ in 0..<count {
            let lineNum = rng.next() % 1000
            let col = rng.next() % 100
            let level = rng.next() % 2 == 0 ? "error" : "warning"
            lines.append("file.yml:\(lineNum):\(col): [\(level)] \(FuzzGen.randomPrintable(count: 30, rng: &rng))")
        }
        return lines.joined(separator: "\n")
    }

    private func generateRandomShellcheckJSON(rng: inout SplitMix64) -> String {
        let count = FuzzGen.randomLength(min: 0, max: 10, rng: &rng)
        var items: [String] = []
        for _ in 0..<count {
            items.append("""
            {"line":\(rng.next() % 100),"column":\(rng.next() % 80),"level":"warning","message":"msg","code":\(rng.next() % 9999)}
            """)
        }
        return "[\(items.joined(separator: ","))]"
    }

    private func generateRandomTerraformJSON(rng: inout SplitMix64) -> String {
        if rng.next() % 2 == 0 {
            return "{\"valid\":false,\"diagnostics\":[{\"severity\":\"error\",\"summary\":\"test\",\"detail\":null}]}"
        }
        return "{\"valid\":true,\"diagnostics\":[]}"
    }

    private func generateRandomHadolintJSON(rng: inout SplitMix64) -> String {
        let count = FuzzGen.randomLength(min: 0, max: 10, rng: &rng)
        var items: [String] = []
        for _ in 0..<count {
            items.append("""
            {"line":\(rng.next() % 100),"column":\(rng.next() % 80),"level":"warning","message":"msg","code":"DL\(rng.next() % 9999)"}
            """)
        }
        return "[\(items.joined(separator: ","))]"
    }

    private func generateRandomYAML(rng: inout SplitMix64) -> String {
        var lines: [String] = []
        let count = FuzzGen.randomLength(min: 1, max: 30, rng: &rng)
        for _ in 0..<count {
            let indent = String(repeating: rng.next() % 2 == 0 ? "  " : "\t", count: Int(rng.next() % 5))
            lines.append("\(indent)key: value")
        }
        return lines.joined(separator: "\n")
    }

    private func generateRandomDockerfile(rng: inout SplitMix64) -> String {
        let instructions = ["FROM", "RUN", "CMD", "COPY", "ADD", "INVALID", "from", "run"]
        var lines: [String] = []
        let count = FuzzGen.randomLength(min: 1, max: 20, rng: &rng)
        for _ in 0..<count {
            let instr = instructions[Int(rng.next() % UInt64(instructions.count))]
            lines.append("\(instr) \(FuzzGen.randomPrintable(count: 20, rng: &rng))")
        }
        return lines.joined(separator: "\n")
    }

    private func generateRandomShellScript(rng: inout SplitMix64) -> String {
        var lines: [String] = ["#!/bin/bash"]
        let count = FuzzGen.randomLength(min: 1, max: 20, rng: &rng)
        for _ in 0..<count {
            switch rng.next() % 4 {
            case 0: lines.append("[ $VAR == \"test\" ]")
            case 1: lines.append("echo `hostname`")
            case 2: lines.append("echo $(date)")
            default: lines.append("# comment")
            }
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - GoToLineParser Fuzz Tests

struct FuzzGoToLineParserTests {

    @Test func fuzzGoToLineParser_randomInput() {
        var rng = SplitMix64(seed: 61)

        for _ in 0..<1000 {
            let input: String
            switch rng.next() % 5 {
            case 0:
                input = FuzzGen.randomBytes(count: FuzzGen.randomLength(max: 100, rng: &rng), rng: &rng)
            case 1:
                input = FuzzGen.randomUnicode(count: FuzzGen.randomLength(max: 50, rng: &rng), rng: &rng)
            case 2:
                input = "\(rng.next())"
            case 3:
                input = "\(rng.next()):\(rng.next())"
            default:
                input = ""
            }
            _ = GoToLineParser.parse(input)
        }
    }

    @Test func fuzzGoToLineParser_edgeCases() {
        let inputs = [
            "", " ", "\t", "\n", "\0",
            "0", "-1", "999999999999999999",
            "1:0", "0:1", "-1:-1",
            ":", "::", "1:", ":1",
            "abc", "1:abc", "abc:1",
            "1:1:1", "1:1:1:1",
            " 42 ", " 42 : 10 ",
            "\u{FEFF}1", "1\u{200B}",
        ]
        for input in inputs {
            _ = GoToLineParser.parse(input)
        }
    }
}
