//
//  FuzzGitParserTests.swift
//  PineTests
//
//  Fuzz tests for GitStatusProvider parsers: diff and status.
//

import Foundation
import Testing
@testable import Pine

// MARK: - Git Diff Parser

@Suite("Fuzz Git Diff Parser Tests", .timeLimit(.minutes(2)))
struct FuzzGitDiffParserTests {

    @Test func fuzzParseDiff_randomInput() {
        var rng = SplitMix64(seed: 42)

        for _ in 0..<100 {
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

        for _ in 0..<100 {
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

// MARK: - Git Status Parser

@Suite("Fuzz Git Status Parser Tests", .timeLimit(.minutes(2)))
struct FuzzGitStatusParserTests {

    @Test func fuzzParseStatusOutput_randomInput() {
        var rng = SplitMix64(seed: 45)

        for _ in 0..<100 {
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

        for _ in 0..<100 {
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
