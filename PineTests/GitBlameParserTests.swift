//
//  GitBlameParserTests.swift
//  PineTests
//

import Foundation
import Testing
@testable import Pine

@MainActor
struct GitBlameParserTests {

    /// Helper to build porcelain blame output from line arrays.
    private func porcelain(_ lines: [String]) -> String {
        lines.joined(separator: "\n")
    }

    // MARK: - Simple blame

    @Test func parsesSimpleBlame() {
        let output = porcelain([
            "abc1234567890abcdef1234567890abcdef12345 1 1 1",
            "author John Doe",
            "author-time 1700000000",
            "summary Initial commit",
            "\tlet x = 1"
        ])
        let result = GitStatusProvider.parseBlame(output)
        #expect(result.count == 1)
        #expect(result[0].hash == "abc1234567890abcdef1234567890abcdef12345")
        #expect(result[0].author == "John Doe")
        #expect(result[0].authorTime == Date(timeIntervalSince1970: 1700000000))
        #expect(result[0].summary == "Initial commit")
        #expect(result[0].finalLine == 1)
    }

    // MARK: - Multiple commits

    @Test func parsesMultipleCommits() {
        let output = porcelain([
            "aaaa000000000000000000000000000000000001 1 1 2",
            "author Alice",
            "author-time 1700000000",
            "summary First commit",
            "\tline 1",
            "aaaa000000000000000000000000000000000001 2 2",
            "\tline 2",
            "bbbb000000000000000000000000000000000002 3 3 1",
            "author Bob",
            "author-time 1700100000",
            "summary Second commit",
            "\tline 3"
        ])
        let result = GitStatusProvider.parseBlame(output)
        #expect(result.count == 3)
        #expect(result[0].author == "Alice")
        #expect(result[0].finalLine == 1)
        #expect(result[1].author == "Alice")
        #expect(result[1].finalLine == 2)
        #expect(result[1].hash == "aaaa000000000000000000000000000000000001")
        #expect(result[2].author == "Bob")
        #expect(result[2].finalLine == 3)
    }

    // MARK: - Uncommitted lines

    @Test func parsesUncommittedLines() {
        let output = porcelain([
            "0000000000000000000000000000000000000000 1 1 1",
            "author Not Committed Yet",
            "author-time 1700000000",
            "summary Not Yet Committed",
            "\tnew line"
        ])
        let result = GitStatusProvider.parseBlame(output)
        #expect(result.count == 1)
        #expect(result[0].isUncommitted)
        #expect(result[0].author == "Not Committed Yet")
    }

    // MARK: - Empty output

    @Test func parsesEmptyOutput() {
        let result = GitStatusProvider.parseBlame("")
        #expect(result.isEmpty)
    }

    // MARK: - Repeated commit headers (porcelain optimization)

    @Test func handlesRepeatedCommitWithoutHeaders() {
        let output = porcelain([
            "abc1234567890abcdef1234567890abcdef12345 1 1 3",
            "author Jane",
            "author-time 1700050000",
            "summary Fix bug",
            "\tline 1",
            "abc1234567890abcdef1234567890abcdef12345 2 2",
            "\tline 2",
            "abc1234567890abcdef1234567890abcdef12345 3 3",
            "\tline 3"
        ])
        let result = GitStatusProvider.parseBlame(output)
        #expect(result.count == 3)
        for line in result {
            #expect(line.hash == "abc1234567890abcdef1234567890abcdef12345")
            #expect(line.author == "Jane")
            #expect(line.summary == "Fix bug")
        }
        #expect(result[0].finalLine == 1)
        #expect(result[1].finalLine == 2)
        #expect(result[2].finalLine == 3)
    }

    // MARK: - Author-time parsing

    @Test func parsesAuthorTimeCorrectly() {
        let output = porcelain([
            "abc1234567890abcdef1234567890abcdef12345 1 1 1",
            "author Test",
            "author-time 0",
            "summary Test",
            "\tx"
        ])
        let result = GitStatusProvider.parseBlame(output)
        #expect(result[0].authorTime == Date(timeIntervalSince1970: 0))
    }

    // MARK: - Lines with special content

    @Test func parsesLineWithTabContent() {
        let output = porcelain([
            "abc1234567890abcdef1234567890abcdef12345 1 1 1",
            "author Dev",
            "author-time 1700000000",
            "summary Add tabs",
            "\t\tindented content"
        ])
        let result = GitStatusProvider.parseBlame(output)
        #expect(result.count == 1)
    }

    @Test func parsesEmptyContentLine() {
        let output = porcelain([
            "abc1234567890abcdef1234567890abcdef12345 1 1 1",
            "author Dev",
            "author-time 1700000000",
            "summary Empty line",
            "\t"
        ])
        let result = GitStatusProvider.parseBlame(output)
        #expect(result.count == 1)
    }

    // MARK: - Extra porcelain headers

    @Test func ignoresExtraPorcelainHeaders() {
        let output = porcelain([
            "abc1234567890abcdef1234567890abcdef12345 1 1 1",
            "author Jane",
            "author-mail <jane@example.com>",
            "author-time 1700000000",
            "author-tz +0000",
            "committer Jane",
            "committer-mail <jane@example.com>",
            "committer-time 1700000000",
            "committer-tz +0000",
            "summary Add feature",
            "boundary",
            "filename main.swift",
            "\tlet x = 1"
        ])
        let result = GitStatusProvider.parseBlame(output)
        #expect(result.count == 1)
        #expect(result[0].author == "Jane")
        #expect(result[0].summary == "Add feature")
    }
}
