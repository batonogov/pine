//
//  RecentProjectsFilterTests.swift
//  PineTests
//

import Testing
import Foundation
@testable import Pine

@MainActor
struct RecentProjectsFilterTests {

    // MARK: - Helpers

    private func makeURLs(_ names: [String]) -> [URL] {
        names.map { URL(fileURLWithPath: "/Users/dev/\($0)") }
    }

    // MARK: - Empty query returns all

    @Test func emptyQueryReturnsAll() {
        let urls = makeURLs(["alpha", "beta", "gamma"])
        let result = RecentProjectsFilter.filter(urls, query: "")
        #expect(result == urls)
    }

    @Test func whitespaceOnlyQueryReturnsAll() {
        let urls = makeURLs(["alpha", "beta"])
        let result = RecentProjectsFilter.filter(urls, query: "   ")
        #expect(result == urls)
    }

    // MARK: - Matches by project name

    @Test func matchesByProjectName() {
        let urls = makeURLs(["pine-editor", "vscode", "xcode"])
        let result = RecentProjectsFilter.filter(urls, query: "pine")
        #expect(result.count == 1)
        #expect(result[0].lastPathComponent == "pine-editor")
    }

    // MARK: - Matches by path

    @Test func matchesByPath() {
        let urls = [
            URL(fileURLWithPath: "/Users/dev/projects/alpha"),
            URL(fileURLWithPath: "/Users/work/beta")
        ]
        let result = RecentProjectsFilter.filter(urls, query: "projects")
        #expect(result.count == 1)
        #expect(result[0].lastPathComponent == "alpha")
    }

    // MARK: - Case insensitive

    @Test func caseInsensitiveMatch() {
        let urls = makeURLs(["MyProject"])
        let result = RecentProjectsFilter.filter(urls, query: "myproject")
        #expect(result.count == 1)
    }

    @Test func caseInsensitiveMatchUpperQuery() {
        let urls = makeURLs(["myproject"])
        let result = RecentProjectsFilter.filter(urls, query: "MYPROJECT")
        #expect(result.count == 1)
    }

    // MARK: - No matches

    @Test func noMatchesReturnsEmpty() {
        let urls = makeURLs(["alpha", "beta"])
        let result = RecentProjectsFilter.filter(urls, query: "zzz")
        #expect(result.isEmpty)
    }

    // MARK: - Preserves order

    @Test func preservesOriginalOrder() {
        let urls = makeURLs(["a-project", "b-project", "c-project"])
        let result = RecentProjectsFilter.filter(urls, query: "project")
        #expect(result == urls)
    }

    // MARK: - Empty list

    @Test func emptyListReturnsEmpty() {
        let result = RecentProjectsFilter.filter([], query: "anything")
        #expect(result.isEmpty)
    }

    // MARK: - Substring match

    @Test func substringMatchInMiddle() {
        let urls = makeURLs(["my-awesome-app"])
        let result = RecentProjectsFilter.filter(urls, query: "awesome")
        #expect(result.count == 1)
    }

    // MARK: - Multiple matches

    @Test func multipleMatches() {
        let urls = makeURLs(["pine-editor", "pine-cli", "vscode"])
        let result = RecentProjectsFilter.filter(urls, query: "pine")
        #expect(result.count == 2)
        #expect(result[0].lastPathComponent == "pine-editor")
        #expect(result[1].lastPathComponent == "pine-cli")
    }

    // MARK: - Newline trimming

    @Test func newlineOnlyQueryReturnsAll() {
        let urls = makeURLs(["alpha", "beta"])
        let result = RecentProjectsFilter.filter(urls, query: "\n\t  ")
        #expect(result == urls)
    }

    @Test func queryWithLeadingNewlineTrimsCorrectly() {
        let urls = makeURLs(["pine-editor", "vscode"])
        let result = RecentProjectsFilter.filter(urls, query: "\npine\n")
        #expect(result.count == 1)
        #expect(result[0].lastPathComponent == "pine-editor")
    }
}
