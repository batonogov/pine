//
//  TerminalManagerTests.swift
//  PineTests
//
//  Created by Claude on 14.03.2026.
//

import Foundation
import SwiftTerm
import Testing

@testable import Pine

@Suite("TerminalManager Tests")
struct TerminalManagerTests {

    @Test("Initial state has one tab and no active terminal")
    func initialState() {
        let manager = TerminalManager()
        #expect(manager.terminalTabs.count == 1)
        #expect(manager.activeTerminalID == nil)
        #expect(manager.activeTerminalTab == nil)
        #expect(manager.isTerminalVisible == false)
        #expect(manager.isTerminalMaximized == false)
    }

    @Test("startTerminals sets activeTerminalID to first tab")
    func startTerminalsSetsActive() {
        let manager = TerminalManager()
        manager.startTerminals(workingDirectory: nil)
        #expect(manager.activeTerminalID == manager.terminalTabs.first?.id)
        #expect(manager.activeTerminalTab != nil)
    }

    @Test("startTerminals does not overwrite existing activeTerminalID")
    func startTerminalsPreservesActive() throws {
        let manager = TerminalManager()
        let firstTab = try #require(manager.terminalTabs.first)
        manager.activeTerminalID = firstTab.id
        manager.startTerminals(workingDirectory: nil)
        #expect(manager.activeTerminalID == firstTab.id)
    }

    @Test("addTerminalTab appends and activates new tab")
    func addTerminalTab() throws {
        let manager = TerminalManager()
        let initialCount = manager.terminalTabs.count
        manager.addTerminalTab(workingDirectory: nil)
        #expect(manager.terminalTabs.count == initialCount + 1)
        let newTab = try #require(manager.terminalTabs.last)
        #expect(manager.activeTerminalID == newTab.id)
    }

    @Test("addTerminalTab assigns numbered name")
    func addTerminalTabName() throws {
        let manager = TerminalManager()
        manager.addTerminalTab(workingDirectory: nil)
        let newTab = try #require(manager.terminalTabs.last)
        #expect(newTab.name.contains("2"))
    }

    @Test("closeTerminalTab removes tab and selects last remaining")
    func closeTerminalTab() throws {
        let manager = TerminalManager()
        manager.addTerminalTab(workingDirectory: nil)
        #expect(manager.terminalTabs.count == 2)

        let tabToClose = try #require(manager.terminalTabs.last)
        manager.closeTerminalTab(tabToClose)

        #expect(manager.terminalTabs.count == 1)
        #expect(manager.activeTerminalID == manager.terminalTabs.last?.id)
    }

    @Test("closeTerminalTab when closing active selects last remaining")
    func closeActiveTab() throws {
        let manager = TerminalManager()
        manager.startTerminals(workingDirectory: nil)
        manager.addTerminalTab(workingDirectory: nil)
        let activeTab = try #require(manager.activeTerminalTab)

        manager.closeTerminalTab(activeTab)

        #expect(manager.activeTerminalID == manager.terminalTabs.last?.id)
    }

    @Test("closeTerminalTab when closing non-active preserves active")
    func closeNonActiveTab() throws {
        let manager = TerminalManager()
        manager.startTerminals(workingDirectory: nil)
        manager.addTerminalTab(workingDirectory: nil)
        let activeID = manager.activeTerminalID
        let firstTab = try #require(manager.terminalTabs.first)

        manager.closeTerminalTab(firstTab)

        #expect(manager.activeTerminalID == activeID)
    }

    @Test("closing all tabs results in nil activeTerminalTab")
    func closeAllTabs() throws {
        let manager = TerminalManager()
        let tab = try #require(manager.terminalTabs.first)
        manager.closeTerminalTab(tab)

        #expect(manager.terminalTabs.isEmpty)
        #expect(manager.activeTerminalID == nil)
        #expect(manager.activeTerminalTab == nil)
    }

    @Test("activeTerminalTab returns correct tab by ID")
    func activeTerminalTabLookup() throws {
        let manager = TerminalManager()
        manager.addTerminalTab(workingDirectory: nil)
        let secondTab = try #require(manager.terminalTabs.last)
        manager.activeTerminalID = secondTab.id

        #expect(manager.activeTerminalTab?.id == secondTab.id)
    }

    @Test("activeTerminalTab returns nil for unknown ID")
    func activeTerminalTabUnknownID() {
        let manager = TerminalManager()
        manager.activeTerminalID = UUID()
        #expect(manager.activeTerminalTab == nil)
    }

    @Test("visibility and maximize state toggling")
    func visibilityState() {
        let manager = TerminalManager()
        #expect(manager.isTerminalVisible == false)
        #expect(manager.isTerminalMaximized == false)

        manager.isTerminalVisible = true
        #expect(manager.isTerminalVisible == true)

        manager.isTerminalMaximized = true
        #expect(manager.isTerminalMaximized == true)
    }

    @Test("multiple addTerminalTab calls increment correctly")
    func multipleAdds() {
        let manager = TerminalManager()
        manager.addTerminalTab(workingDirectory: nil)
        manager.addTerminalTab(workingDirectory: nil)
        manager.addTerminalTab(workingDirectory: nil)

        #expect(manager.terminalTabs.count == 4) // 1 initial + 3 added
        #expect(manager.activeTerminalID == manager.terminalTabs.last?.id)
    }

    @Test("terminateAll stops all tabs")
    func terminateAll() {
        let manager = TerminalManager()
        manager.addTerminalTab(workingDirectory: nil)
        manager.addTerminalTab(workingDirectory: nil)
        #expect(manager.terminalTabs.count == 3)

        manager.terminateAll()

        for tab in manager.terminalTabs {
            #expect(tab.isTerminated)
        }
    }

    @Test("hasActiveProcesses returns false when no processes started")
    func hasActiveProcessesNoProcesses() {
        let manager = TerminalManager()
        #expect(!manager.hasActiveProcesses)
        #expect(manager.tabsWithForegroundProcesses.isEmpty)
    }

    // MARK: - Search state tests

    @Test("initial search state is hidden with empty query and case-insensitive")
    func initialSearchState() {
        let manager = TerminalManager()
        #expect(manager.isSearchVisible == false)
        #expect(manager.terminalSearchQuery == "")
        #expect(manager.isSearchCaseSensitive == false)
    }

    @Test("isSearchCaseSensitive toggles independently")
    func caseSensitiveToggle() {
        let manager = TerminalManager()
        #expect(manager.isSearchCaseSensitive == false)
        manager.isSearchCaseSensitive = true
        #expect(manager.isSearchCaseSensitive == true)
    }

    @Test("search with empty query clears matches")
    @MainActor
    func searchWithEmptyQueryClearsMatches() async {
        let tab = TerminalTab(name: "Test")
        tab.searchMatches = [TerminalSearchMatch(row: 0, col: 0, length: 3)]
        tab.currentMatchIndex = 0

        await tab.search(for: "")

        #expect(tab.searchMatches.isEmpty)
        #expect(tab.currentMatchIndex == -1)
    }

    @Test("search on empty buffer returns no matches")
    @MainActor
    func searchOnEmptyBuffer() async {
        let tab = TerminalTab(name: "Test")
        await tab.search(for: "anything")
        #expect(tab.searchMatches.isEmpty)
        #expect(tab.currentMatchIndex == -1)
    }

    @Test("search finds matches in terminal buffer")
    @MainActor
    func searchFindsMatches() async {
        let tab = TerminalTab(name: "Test")
        let terminal = tab.terminalView.getTerminal()
        terminal.feed(text: "hello world\r\nhello pine\r\ngoodbye\r\n")

        await tab.search(for: "hello")

        #expect(tab.searchMatches.count == 2)
        #expect(tab.currentMatchIndex == 0)
        #expect(tab.searchMatches[0].row == 0)
        #expect(tab.searchMatches[0].col == 0)
        #expect(tab.searchMatches[0].length == 5)
        #expect(tab.searchMatches[1].row == 1)
    }

    @Test("search finds multiple matches on same line")
    @MainActor
    func searchMultipleMatchesSameLine() async {
        let tab = TerminalTab(name: "Test")
        let terminal = tab.terminalView.getTerminal()
        terminal.feed(text: "abc abc abc\r\n")

        await tab.search(for: "abc")

        #expect(tab.searchMatches.count == 3)
        #expect(tab.searchMatches[0].col == 0)
        #expect(tab.searchMatches[1].col == 4)
        #expect(tab.searchMatches[2].col == 8)
    }

    @Test("search is case-insensitive by default")
    @MainActor
    func searchCaseInsensitive() async {
        let tab = TerminalTab(name: "Test")
        let terminal = tab.terminalView.getTerminal()
        terminal.feed(text: "Hello HELLO hello\r\n")

        await tab.search(for: "hello")

        #expect(tab.searchMatches.count == 3)
    }

    @Test("search respects case sensitivity flag")
    @MainActor
    func searchCaseSensitive() async {
        let tab = TerminalTab(name: "Test")
        let terminal = tab.terminalView.getTerminal()
        terminal.feed(text: "Hello HELLO hello\r\n")

        await tab.search(for: "hello", caseSensitive: true)

        #expect(tab.searchMatches.count == 1)
        #expect(tab.searchMatches[0].col == 12)
    }

    @Test("nextMatch wraps around to first match")
    @MainActor
    func nextMatchWraps() async {
        let tab = TerminalTab(name: "Test")
        let terminal = tab.terminalView.getTerminal()
        terminal.feed(text: "aaa\r\naaa\r\n")

        await tab.search(for: "aaa")

        #expect(tab.currentMatchIndex == 0)
        tab.nextMatch()
        #expect(tab.currentMatchIndex == 1)
        tab.nextMatch()
        #expect(tab.currentMatchIndex == 0) // wraps
    }

    @Test("previousMatch wraps around to last match")
    @MainActor
    func previousMatchWraps() async {
        let tab = TerminalTab(name: "Test")
        let terminal = tab.terminalView.getTerminal()
        terminal.feed(text: "aaa\r\naaa\r\n")

        await tab.search(for: "aaa")

        #expect(tab.currentMatchIndex == 0)
        tab.previousMatch()
        #expect(tab.currentMatchIndex == 1) // wraps to last
    }

    @Test("nextMatch and previousMatch do nothing when no matches")
    func navigationWithNoMatches() {
        let tab = TerminalTab(name: "Test")
        tab.nextMatch()
        tab.previousMatch()
        #expect(tab.currentMatchIndex == -1)
    }

    @Test("clearSearch resets state")
    func clearSearchResetsState() {
        let tab = TerminalTab(name: "Test")
        tab.searchMatches = [TerminalSearchMatch(row: 0, col: 0, length: 3)]
        tab.currentMatchIndex = 0
        tab.clearSearch()
        #expect(tab.searchMatches.isEmpty)
        #expect(tab.currentMatchIndex == -1)
    }

    @Test("new search replaces previous results")
    @MainActor
    func newSearchReplacesOld() async {
        let tab = TerminalTab(name: "Test")
        let terminal = tab.terminalView.getTerminal()
        terminal.feed(text: "foo bar baz\r\n")

        await tab.search(for: "foo")
        #expect(tab.searchMatches.count == 1)

        await tab.search(for: "bar")
        #expect(tab.searchMatches.count == 1)
        #expect(tab.searchMatches[0].col == 4)
    }

    @Test("search for nonexistent text returns empty")
    @MainActor
    func searchNoResults() async {
        let tab = TerminalTab(name: "Test")
        let terminal = tab.terminalView.getTerminal()
        terminal.feed(text: "hello world\r\n")

        await tab.search(for: "xyz")

        #expect(tab.searchMatches.isEmpty)
        #expect(tab.currentMatchIndex == -1)
    }

    @Test("TerminalSearchMatch stores row, col, and length")
    func terminalSearchMatchProperties() {
        let match = TerminalSearchMatch(row: 5, col: 10, length: 3)
        #expect(match.row == 5)
        #expect(match.col == 10)
        #expect(match.length == 3)
    }

    // MARK: - Edge cases

    @Test("single character search")
    @MainActor
    func singleCharSearch() async {
        let tab = TerminalTab(name: "Test")
        let terminal = tab.terminalView.getTerminal()
        terminal.feed(text: "abcabc\r\n")

        await tab.search(for: "a")

        #expect(tab.searchMatches.count == 2)
        #expect(tab.searchMatches[0].col == 0)
        #expect(tab.searchMatches[0].length == 1)
        #expect(tab.searchMatches[1].col == 3)
    }

    @Test("navigation with single match stays at index 0")
    @MainActor
    func singleMatchNavigation() async {
        let tab = TerminalTab(name: "Test")
        let terminal = tab.terminalView.getTerminal()
        terminal.feed(text: "unique\r\n")

        await tab.search(for: "unique")

        #expect(tab.currentMatchIndex == 0)
        tab.nextMatch()
        #expect(tab.currentMatchIndex == 0)
        tab.previousMatch()
        #expect(tab.currentMatchIndex == 0)
    }

    @Test("non-overlapping search: 'aa' in 'aaaa' finds 2 matches not 3")
    @MainActor
    func nonOverlappingMatches() async {
        let tab = TerminalTab(name: "Test")
        let terminal = tab.terminalView.getTerminal()
        terminal.feed(text: "aaaa\r\n")

        await tab.search(for: "aa")

        #expect(tab.searchMatches.count == 2)
        #expect(tab.searchMatches[0].col == 0)
        #expect(tab.searchMatches[1].col == 2)
    }

    @Test("search with unicode characters")
    @MainActor
    func unicodeSearch() async {
        let tab = TerminalTab(name: "Test")
        let terminal = tab.terminalView.getTerminal()
        terminal.feed(text: "привет мир привет\r\n")

        await tab.search(for: "привет")

        #expect(tab.searchMatches.count == 2)
    }

    @Test("search with special ASCII characters")
    @MainActor
    func specialAsciiSearch() async {
        let tab = TerminalTab(name: "Test")
        let terminal = tab.terminalView.getTerminal()
        terminal.feed(text: "path/to/file:123 path/to/file:456\r\n")

        await tab.search(for: "path/to/file:")

        #expect(tab.searchMatches.count == 2)
    }

    @Test("search across empty lines in buffer")
    @MainActor
    func searchWithEmptyLines() async {
        let tab = TerminalTab(name: "Test")
        let terminal = tab.terminalView.getTerminal()
        terminal.feed(text: "match\r\n\r\n\r\nmatch\r\n")

        await tab.search(for: "match")

        #expect(tab.searchMatches.count == 2)
        // Rows should not be adjacent due to empty lines
        #expect(tab.searchMatches[0].row != tab.searchMatches[1].row)
    }

    @Test("search after clearSearch then new search works")
    @MainActor
    func searchAfterClear() async {
        let tab = TerminalTab(name: "Test")
        let terminal = tab.terminalView.getTerminal()
        terminal.feed(text: "foo bar\r\n")

        await tab.search(for: "foo")
        #expect(tab.searchMatches.count == 1)

        tab.clearSearch()
        #expect(tab.searchMatches.isEmpty)

        await tab.search(for: "bar")
        #expect(tab.searchMatches.count == 1)
        #expect(tab.searchMatches[0].col == 4)
    }

    @Test("case sensitive search finds exact match only")
    @MainActor
    func caseSensitiveExact() async {
        let tab = TerminalTab(name: "Test")
        let terminal = tab.terminalView.getTerminal()
        terminal.feed(text: "Error error ERROR\r\n")

        await tab.search(for: "Error", caseSensitive: true)

        #expect(tab.searchMatches.count == 1)
        #expect(tab.searchMatches[0].col == 0)
    }

    @Test("switching case sensitivity changes results")
    @MainActor
    func toggleCaseSensitivity() async {
        let tab = TerminalTab(name: "Test")
        let terminal = tab.terminalView.getTerminal()
        terminal.feed(text: "Foo foo FOO\r\n")

        await tab.search(for: "foo", caseSensitive: false)
        #expect(tab.searchMatches.count == 3)

        await tab.search(for: "foo", caseSensitive: true)
        #expect(tab.searchMatches.count == 1)
    }

    @Test("special regex characters are treated as literals")
    @MainActor
    func specialCharactersAsLiterals() async {
        let tab = TerminalTab(name: "Test")
        let terminal = tab.terminalView.getTerminal()
        terminal.feed(text: "file.txt [test] (foo)\r\n")

        await tab.search(for: "[test]")
        #expect(tab.searchMatches.count == 1)

        await tab.search(for: ".")
        #expect(tab.searchMatches.count >= 1)
    }

    // MARK: - Regression: find in terminal (issue #308)

    @Test("search with ANSI escape sequences in buffer")
    @MainActor
    func searchWithAnsiEscapes() async {
        // Regression #308: ANSI color codes should not interfere with text search
        let tab = TerminalTab(name: "Test")
        let terminal = tab.terminalView.getTerminal()
        // Simulate colored output: ESC[31m = red, ESC[0m = reset
        terminal.feed(text: "\u{1B}[31merror\u{1B}[0m: something failed\r\n")

        await tab.search(for: "error")
        // SwiftTerm processes escape sequences, so buffer text should contain "error"
        // without the raw escape codes
        #expect(tab.searchMatches.count >= 1, "ANSI escapes must not prevent finding text")
    }

    @Test("search with bold/underline ANSI sequences")
    @MainActor
    func searchWithFormattingAnsi() async {
        let tab = TerminalTab(name: "Test")
        let terminal = tab.terminalView.getTerminal()
        // ESC[1m = bold, ESC[4m = underline
        terminal.feed(text: "\u{1B}[1mbold text\u{1B}[0m and \u{1B}[4munderlined\u{1B}[0m\r\n")

        await tab.search(for: "bold text")
        #expect(tab.searchMatches.count >= 1)

        await tab.search(for: "underlined")
        #expect(tab.searchMatches.count >= 1)
    }

    @Test("search spanning multiple terminal rows")
    @MainActor
    func searchManyRows() async {
        let tab = TerminalTab(name: "Test")
        let terminal = tab.terminalView.getTerminal()
        // Generate 100 lines with "match" on every 10th line.
        // Note: SwiftTerm default scroll-back is large enough for 100 lines;
        // if scroll-back shrinks, older lines may be evicted and this count will drop.
        for i in 0..<100 {
            if i % 10 == 0 {
                terminal.feed(text: "match line \(i)\r\n")
            } else {
                terminal.feed(text: "other line \(i)\r\n")
            }
        }

        await tab.search(for: "match")
        #expect(tab.searchMatches.count == 10,
                "Should find exactly 10 matches across 100 lines")
    }

    @Test("search query longer than any line returns no matches")
    @MainActor
    func searchQueryLongerThanLine() async {
        let tab = TerminalTab(name: "Test")
        let terminal = tab.terminalView.getTerminal()
        terminal.feed(text: "short\r\n")

        let longQuery = String(repeating: "x", count: 200)
        await tab.search(for: longQuery)

        #expect(tab.searchMatches.isEmpty)
        #expect(tab.currentMatchIndex == -1)
    }

    @Test("search with whitespace-only query")
    @MainActor
    func searchWhitespaceOnly() async {
        let tab = TerminalTab(name: "Test")
        let terminal = tab.terminalView.getTerminal()
        terminal.feed(text: "hello world\r\n")

        await tab.search(for: " ")
        #expect(tab.searchMatches.count >= 1, "Space character is a valid search query")
    }

    @Test("search with tab character")
    @MainActor
    func searchTabCharacter() async {
        let tab = TerminalTab(name: "Test")
        let terminal = tab.terminalView.getTerminal()
        terminal.feed(text: "col1\tcol2\tcol3\r\n")

        await tab.search(for: "col2")
        #expect(tab.searchMatches.count == 1)
    }

    @Test("rapid sequential searches replace previous results")
    @MainActor
    func rapidSequentialSearches() async {
        let tab = TerminalTab(name: "Test")
        let terminal = tab.terminalView.getTerminal()
        terminal.feed(text: "alpha beta gamma\r\n")

        await tab.search(for: "alpha")
        #expect(tab.searchMatches.count == 1)

        await tab.search(for: "beta")
        #expect(tab.searchMatches.count == 1)
        #expect(tab.searchMatches[0].col == 6, "Should find 'beta' at col 6")

        await tab.search(for: "gamma")
        #expect(tab.searchMatches.count == 1)
        #expect(tab.searchMatches[0].col == 11)
    }

    @Test("navigation through many matches visits all of them")
    @MainActor
    func navigationThroughAllMatches() async {
        let tab = TerminalTab(name: "Test")
        let terminal = tab.terminalView.getTerminal()
        terminal.feed(text: "a a a a a\r\n")

        await tab.search(for: "a")
        let count = tab.searchMatches.count
        #expect(count == 5)

        // Walk forward through all matches + wrap
        for i in 1..<count {
            tab.nextMatch()
            #expect(tab.currentMatchIndex == i)
        }
        tab.nextMatch()
        #expect(tab.currentMatchIndex == 0, "Should wrap to first match")
    }

    @Test("clearSearch then navigation does nothing")
    func clearThenNavigate() {
        let tab = TerminalTab(name: "Test")
        tab.searchMatches = [
            TerminalSearchMatch(row: 0, col: 0, length: 3),
            TerminalSearchMatch(row: 1, col: 0, length: 3),
        ]
        tab.currentMatchIndex = 0

        tab.clearSearch()
        tab.nextMatch()
        #expect(tab.currentMatchIndex == -1)
        tab.previousMatch()
        #expect(tab.currentMatchIndex == -1)
    }

    @Test("search match position is correct with leading spaces")
    @MainActor
    func searchWithLeadingSpaces() async {
        let tab = TerminalTab(name: "Test")
        let terminal = tab.terminalView.getTerminal()
        terminal.feed(text: "    indented\r\n")

        await tab.search(for: "indented")
        #expect(tab.searchMatches.count == 1)
        #expect(tab.searchMatches[0].col == 4, "Match should account for leading spaces")
    }

    // MARK: - Focus tests (issue #558)

    @Test("pendingFocusTabID is nil initially")
    func pendingFocusInitiallyNil() {
        let manager = TerminalManager()
        #expect(manager.pendingFocusTabID == nil)
    }

    @Test("addTerminalTab sets pendingFocusTabID to new tab")
    func addTerminalTabSetsPendingFocus() throws {
        let manager = TerminalManager()
        manager.addTerminalTab(workingDirectory: nil)
        let newTab = try #require(manager.terminalTabs.last)
        #expect(manager.pendingFocusTabID == newTab.id)
    }

    @Test("pendingFocusTabID matches activeTerminalID after addTerminalTab")
    func pendingFocusMatchesActiveAfterAdd() {
        let manager = TerminalManager()
        manager.addTerminalTab(workingDirectory: nil)
        #expect(manager.pendingFocusTabID == manager.activeTerminalID)
    }

    @Test("pendingFocusTabID can be cleared externally")
    func pendingFocusCanBeCleared() {
        let manager = TerminalManager()
        manager.addTerminalTab(workingDirectory: nil)
        #expect(manager.pendingFocusTabID != nil)
        manager.pendingFocusTabID = nil
        #expect(manager.pendingFocusTabID == nil)
    }

    @Test("multiple addTerminalTab calls update pendingFocusTabID to latest")
    func multiplePendingFocusUpdates() throws {
        let manager = TerminalManager()
        manager.addTerminalTab(workingDirectory: nil)
        let firstNewID = manager.pendingFocusTabID

        manager.addTerminalTab(workingDirectory: nil)
        let secondNewTab = try #require(manager.terminalTabs.last)
        #expect(manager.pendingFocusTabID == secondNewTab.id)
        #expect(manager.pendingFocusTabID != firstNewID)
    }

    @Test("closeTerminalTab does not set pendingFocusTabID")
    func closeDoesNotSetPendingFocus() throws {
        let manager = TerminalManager()
        manager.startTerminals(workingDirectory: nil)
        manager.addTerminalTab(workingDirectory: nil)
        manager.pendingFocusTabID = nil

        let tabToClose = try #require(manager.terminalTabs.last)
        manager.closeTerminalTab(tabToClose)
        #expect(manager.pendingFocusTabID == nil)
    }
}
