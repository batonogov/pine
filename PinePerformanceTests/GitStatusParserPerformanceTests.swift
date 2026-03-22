//
//  GitStatusParserPerformanceTests.swift
//  PinePerformanceTests
//

import XCTest
@testable import Pine

final class GitStatusParserPerformanceTests: XCTestCase {

    // MARK: - Helpers

    /// Generates `git status --porcelain` output with many entries.
    private func generateStatusOutput(count: Int) -> String {
        var lines: [String] = []
        for i in 0..<count {
            let dir = "src/module\(i / 10)"
            switch i % 6 {
            case 0: lines.append("?? \(dir)/new_file\(i).swift")
            case 1: lines.append(" M \(dir)/modified\(i).swift")
            case 2: lines.append("M  \(dir)/staged\(i).swift")
            case 3: lines.append("A  \(dir)/added\(i).swift")
            case 4: lines.append(" D \(dir)/deleted\(i).swift")
            case 5: lines.append("MM \(dir)/mixed\(i).swift")
            default: break
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Generates `git status --porcelain --ignored` output.
    private func generateIgnoredOutput(count: Int) -> String {
        var lines: [String] = []
        for i in 0..<count {
            lines.append("!! build/output\(i)/")
        }
        return lines.joined(separator: "\n")
    }

    /// Generates `git diff --unified=0` output with many hunks.
    private func generateDiffOutput(hunkCount: Int) -> String {
        var lines: [String] = [
            "diff --git a/file.swift b/file.swift",
            "index abc1234..def5678 100644",
            "--- a/file.swift",
            "+++ b/file.swift",
        ]
        var currentLine = 1
        for _ in 0..<hunkCount {
            let oldStart = currentLine
            let newStart = currentLine
            lines.append("@@ -\(oldStart),3 +\(newStart),5 @@ func example()")
            lines.append("-    let old1 = 1")
            lines.append("-    let old2 = 2")
            lines.append("-    let old3 = 3")
            lines.append("+    let new1 = 1")
            lines.append("+    let new2 = 2")
            lines.append("+    let new3 = 3")
            lines.append("+    let new4 = 4")
            lines.append("+    let new5 = 5")
            currentLine += 10
        }
        return lines.joined(separator: "\n")
    }

    /// Generates `git blame --porcelain` output.
    private func generateBlameOutput(lineCount: Int) -> String {
        var lines: [String] = []
        let hashes = (0..<10).map { String(format: "%040x", $0) }

        for i in 0..<lineCount {
            let hash = hashes[i % hashes.count]
            let isFirst = i < hashes.count

            lines.append("\(hash) \(i + 1) \(i + 1) 1")
            if isFirst {
                lines.append("author Developer\(i % 5)")
                lines.append("author-time \(1700000000 + i * 3600)")
                lines.append("summary Commit message \(i)")
            }
            lines.append("\tlet line\(i) = \(i)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Status Parsing

    func testParseStatus500Entries() {
        let output = generateStatusOutput(count: 500)
        measure {
            _ = GitStatusProvider.parseStatusOutput(output)
        }
    }

    func testParseStatus2000Entries() {
        let output = generateStatusOutput(count: 2000)
        measure {
            _ = GitStatusProvider.parseStatusOutput(output)
        }
    }

    // MARK: - Ignored Parsing

    func testParseIgnored500Entries() {
        let output = generateIgnoredOutput(count: 500)
        measure {
            _ = GitStatusProvider.parseIgnoredOutput(output)
        }
    }

    // MARK: - Diff Parsing

    func testParseDiff100Hunks() {
        let output = generateDiffOutput(hunkCount: 100)
        measure {
            _ = GitStatusProvider.parseDiff(output)
        }
    }

    func testParseDiff500Hunks() {
        let output = generateDiffOutput(hunkCount: 500)
        measure {
            _ = GitStatusProvider.parseDiff(output)
        }
    }

    // MARK: - Blame Parsing

    func testParseBlame500Lines() {
        let output = generateBlameOutput(lineCount: 500)
        measure {
            _ = GitStatusProvider.parseBlame(output)
        }
    }

    func testParseBlame2000Lines() {
        let output = generateBlameOutput(lineCount: 2000)
        measure {
            _ = GitStatusProvider.parseBlame(output)
        }
    }

    // MARK: - Change Region Starts

    func testChangeRegionStarts() {
        // Generate many diffs with contiguous and non-contiguous regions
        var diffs: [GitLineDiff] = []
        for region in 0..<100 {
            let base = region * 20
            for offset in 0..<5 {
                diffs.append(GitLineDiff(line: base + offset, kind: .modified))
            }
        }

        measure {
            _ = GitLineDiff.changeRegionStarts(diffs)
        }
    }

    func testNextChangeLine() {
        var diffs: [GitLineDiff] = []
        for region in 0..<200 {
            let base = region * 15
            for offset in 0..<3 {
                diffs.append(GitLineDiff(line: base + offset, kind: .added))
            }
        }
        let starts = GitLineDiff.changeRegionStarts(diffs)

        measure {
            for line in stride(from: 0, to: 3000, by: 10) {
                _ = GitLineDiff.nextChangeLine(from: line, regionStarts: starts, diffs: diffs)
            }
        }
    }
}
