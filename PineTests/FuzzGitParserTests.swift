//
//  FuzzGitParserTests.swift
//  PineTests
//
//  Fuzz tests for GitStatusProvider parsers: diff, blame, and status.
//

import Foundation
import Testing
@testable import Pine

// MARK: - Git Diff Parser

@Suite("Fuzz Git Diff Parser Tests", .timeLimit(.minutes(1)))
struct FuzzGitDiffParserTests {

    @Test func fuzzParseDiff_randomInput() {
        var rng = SplitMix64(seed: 42)

        for _ in 0..<200 {
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

        for _ in 0..<200 {
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

// MARK: - Git Blame Parser

@Suite("Fuzz Git Blame Parser Tests", .timeLimit(.minutes(1)))
struct FuzzGitBlameParserTests {

    @Test func fuzzParseBlame_randomInput() {
        var rng = SplitMix64(seed: 44)

        for _ in 0..<200 {
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

// MARK: - Git Status Parser

@Suite("Fuzz Git Status Parser Tests", .timeLimit(.minutes(1)))
struct FuzzGitStatusParserTests {

    @Test func fuzzParseStatusOutput_randomInput() {
        var rng = SplitMix64(seed: 45)

        for _ in 0..<200 {
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

        for _ in 0..<200 {
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
            let path = FuzzGen.randomPrintable(
                count: FuzzGen.randomLength(min: 1, max: 80, rng: &rng),
                rng: &rng
            )
            lines.append("\(idx)\(work) \(path)")
        }
        return lines.joined(separator: "\n")
    }
}
