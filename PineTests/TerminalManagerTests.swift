//
//  TerminalManagerTests.swift
//  PineTests
//
//  Created by Claude on 14.03.2026.
//

import AppKit
import Foundation
import SwiftTerm
import Testing

@testable import Pine

@Suite("TerminalManager Tests")
struct TerminalManagerTests {

    @Test("Initial state has no paneManager and empty tabs")
    func initialState() {
        let manager = TerminalManager()
        #expect(manager.paneManager == nil)
        #expect(manager.allTerminalTabs.isEmpty)
        #expect(manager.lastActiveTerminalPaneID == nil)
    }

    @Test("createTerminalTab creates pane when no terminal pane exists")
    func createTerminalTabCreatesPane() {
        let pm = PaneManager()
        let manager = TerminalManager()
        manager.paneManager = pm

        let editorPaneID = pm.activePaneID
        manager.createTerminalTab(relativeTo: editorPaneID, workingDirectory: nil)

        #expect(pm.terminalPaneIDs.count == 1)
        #expect(manager.lastActiveTerminalPaneID != nil)
        #expect(manager.allTerminalTabs.count == 1)
    }

    @Test("createTerminalTab adds to existing terminal pane")
    func createTerminalTabAddsToExisting() {
        let pm = PaneManager()
        let manager = TerminalManager()
        manager.paneManager = pm

        let editorPaneID = pm.activePaneID
        manager.createTerminalTab(relativeTo: editorPaneID, workingDirectory: nil)
        manager.createTerminalTab(relativeTo: editorPaneID, workingDirectory: nil)

        #expect(pm.terminalPaneIDs.count == 1)
        #expect(manager.allTerminalTabs.count == 2)
    }

    @Test("focusOrCreateTerminal focuses existing terminal pane")
    func focusOrCreateTerminalFocuses() throws {
        let pm = PaneManager()
        let manager = TerminalManager()
        manager.paneManager = pm

        let editorPaneID = pm.activePaneID
        manager.createTerminalTab(relativeTo: editorPaneID, workingDirectory: nil)
        let terminalPaneID = try #require(manager.lastActiveTerminalPaneID)

        // Switch back to editor pane
        pm.activePaneID = editorPaneID

        manager.focusOrCreateTerminal(relativeTo: editorPaneID, workingDirectory: nil)
        #expect(pm.activePaneID == terminalPaneID)
    }

    @Test("focusOrCreateTerminal creates pane when none exist")
    func focusOrCreateTerminalCreates() {
        let pm = PaneManager()
        let manager = TerminalManager()
        manager.paneManager = pm

        let editorPaneID = pm.activePaneID
        manager.focusOrCreateTerminal(relativeTo: editorPaneID, workingDirectory: nil)

        #expect(pm.terminalPaneIDs.count == 1)
        #expect(manager.allTerminalTabs.count == 1)
    }

    @Test("hasActiveProcesses returns false when no processes started")
    func hasActiveProcessesNoProcesses() {
        let pm = PaneManager()
        let manager = TerminalManager()
        manager.paneManager = pm

        let editorPaneID = pm.activePaneID
        manager.createTerminalTab(relativeTo: editorPaneID, workingDirectory: nil)

        #expect(!manager.hasActiveProcesses)
        #expect(manager.tabsWithForegroundProcesses.isEmpty)
    }

    @Test("terminateAll stops all tabs across panes")
    func terminateAll() {
        let pm = PaneManager()
        let manager = TerminalManager()
        manager.paneManager = pm

        let editorPaneID = pm.activePaneID
        manager.createTerminalTab(relativeTo: editorPaneID, workingDirectory: nil)
        manager.createTerminalTab(relativeTo: editorPaneID, workingDirectory: nil)
        #expect(manager.allTerminalTabs.count == 2)

        manager.terminateAll()

        for tab in manager.allTerminalTabs {
            #expect(tab.isTerminated)
        }
    }

    @Test("allTerminalTabs collects from all panes")
    func allTerminalTabsMultiplePanes() {
        let pm = PaneManager()
        let manager = TerminalManager()
        manager.paneManager = pm

        let editorPaneID = pm.activePaneID
        manager.createTerminalTab(relativeTo: editorPaneID, workingDirectory: nil)

        // Force creating a second terminal pane by clearing lastActiveTerminalPaneID
        manager.lastActiveTerminalPaneID = nil
        // Split the editor pane first to get a second editor pane
        if let newEditorID = pm.splitPane(editorPaneID, axis: .horizontal) {
            manager.createTerminalTab(relativeTo: newEditorID, workingDirectory: nil)
        }

        #expect(pm.terminalPaneIDs.count == 2)
        #expect(manager.allTerminalTabs.count == 2)
    }

    // MARK: - Search state tests (moved to TerminalTab which still has search)

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
        let tab = TerminalTab(name: "Test")
        let terminal = tab.terminalView.getTerminal()
        terminal.feed(text: "\u{1B}[31merror\u{1B}[0m: something failed\r\n")

        await tab.search(for: "error")
        #expect(tab.searchMatches.count >= 1, "ANSI escapes must not prevent finding text")
    }

    @Test("search with bold/underline ANSI sequences")
    @MainActor
    func searchWithFormattingAnsi() async {
        let tab = TerminalTab(name: "Test")
        let terminal = tab.terminalView.getTerminal()
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

    // MARK: - Environment construction tests (#551)

    @Test("buildEnvironment includes PINE_TERMINAL marker")
    func buildEnvironmentContainsPineTerminal() {
        let tab = TerminalTab(name: "test")
        let env = tab.buildEnvironment()
        #expect(env["PINE_TERMINAL"] == "1")
    }

    @Test("buildEnvironment sets TERM to xterm-256color")
    func buildEnvironmentSetsTermValue() {
        let tab = TerminalTab(name: "test")
        let env = tab.buildEnvironment()
        #expect(env["TERM"] == "xterm-256color")
    }

    @Test("buildEnvironment inherits PATH from parent process")
    func buildEnvironmentInheritsPATH() throws {
        let tab = TerminalTab(name: "test")
        let env = tab.buildEnvironment()
        let path = try #require(env["PATH"], "PATH must be inherited for shell to function")
        #expect(!path.isEmpty)
    }

    @Test("buildEnvironment inherits HOME from parent process")
    func buildEnvironmentInheritsHOME() throws {
        let tab = TerminalTab(name: "test")
        let env = tab.buildEnvironment()
        let home = try #require(env["HOME"], "HOME must be inherited")
        #expect(home.hasPrefix("/"))
    }

    @Test("buildEnvironment inherits USER from parent process")
    func buildEnvironmentInheritsUSER() throws {
        let tab = TerminalTab(name: "test")
        let env = tab.buildEnvironment()
        let user = try #require(env["USER"], "USER must be inherited")
        #expect(!user.isEmpty)
    }

    @Test("buildEnvironment produces valid KEY=VALUE strings")
    func buildEnvironmentMapFormat() {
        let tab = TerminalTab(name: "test")
        let env = tab.buildEnvironment()
        let envStrings = env.map { "\($0.key)=\($0.value)" }

        for entry in envStrings {
            #expect(entry.contains("="), "Each env entry must contain '='")
            let parts = entry.split(separator: "=", maxSplits: 1)
            #expect(!parts[0].isEmpty, "Key must not be empty in: \(entry)")
        }

        #expect(envStrings.contains("PINE_TERMINAL=1"))
        #expect(envStrings.contains("TERM=xterm-256color"))
    }

    @Test("resolveWorkingDirectory falls back to HOME when nil")
    func resolveWorkingDirectoryFallback() {
        let tab = TerminalTab(name: "test")
        let dir = tab.resolveWorkingDirectory()
        let expectedHome = ProcessInfo.processInfo.environment["HOME"] ?? "/"
        #expect(dir == expectedHome,
                "nil workingDirectory should fall back to HOME")
    }

    @Test("resolveWorkingDirectory uses configured URL")
    func resolveWorkingDirectoryProvided() {
        let tab = TerminalTab(name: "test")
        tab.configure(workingDirectory: URL(fileURLWithPath: "/tmp"))
        #expect(tab.resolveWorkingDirectory() == "/tmp")
    }

    @Test("terminal tab uses shell settings resolved path")
    func terminalTabUsesResolvedShellPath() throws {
        let suiteName = "PineTests.TerminalEnv.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = ShellSettings(defaults: defaults)
        settings.shellPath = "/bin/zsh"
        #expect(settings.resolvedShellPath == "/bin/zsh")

        settings.shellPath = "/nonexistent/shell"
        let resolved = settings.resolvedShellPath
        #expect(FileManager.default.isExecutableFile(atPath: resolved))
    }

    @Test("terminal tab configure sets working directory without starting")
    func terminalTabConfigureDoesNotStart() {
        let tab = TerminalTab(name: "test")
        let url = URL(fileURLWithPath: "/tmp")
        tab.configure(workingDirectory: url)
        #expect(!tab.isTerminated)
        #expect(!tab.isProcessRunning)
        #expect(tab.resolveWorkingDirectory() == "/tmp")
    }
}

// MARK: - TerminalScrollInterceptor Tests

@Suite("TerminalScrollInterceptor Tests")
struct TerminalScrollInterceptorTests {

    @Test("acceptsFirstResponder returns false")
    func acceptsFirstResponderIsFalse() {
        let interceptor = TerminalScrollInterceptor()
        #expect(interceptor.acceptsFirstResponder == false)
    }

    @Test("hitTest returns self for point inside bounds")
    func hitTestInsideBounds() {
        let interceptor = TerminalScrollInterceptor()
        interceptor.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        let result = interceptor.hitTest(NSPoint(x: 200, y: 150))
        #expect(result === interceptor)
    }

    @Test("hitTest returns self for point at origin")
    func hitTestAtOrigin() {
        let interceptor = TerminalScrollInterceptor()
        interceptor.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        let result = interceptor.hitTest(NSPoint(x: 0, y: 0))
        #expect(result === interceptor)
    }

    @Test("hitTest returns self for point at bounds edge")
    func hitTestAtEdge() {
        let interceptor = TerminalScrollInterceptor()
        interceptor.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        let result = interceptor.hitTest(NSPoint(x: 399, y: 299))
        #expect(result === interceptor)
    }

    @Test("hitTest returns nil for point outside bounds")
    func hitTestOutsideBounds() {
        let interceptor = TerminalScrollInterceptor()
        interceptor.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        let result = interceptor.hitTest(NSPoint(x: 500, y: 400))
        #expect(result == nil)
    }

    @Test("hitTest returns nil for negative coordinates")
    func hitTestNegativeCoordinates() {
        let interceptor = TerminalScrollInterceptor()
        interceptor.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        let result = interceptor.hitTest(NSPoint(x: -10, y: -10))
        #expect(result == nil)
    }

    @Test("hitTest returns nil for point beyond right edge")
    func hitTestBeyondRightEdge() {
        let interceptor = TerminalScrollInterceptor()
        interceptor.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        let result = interceptor.hitTest(NSPoint(x: 400, y: 150))
        #expect(result == nil)
    }

    @Test("hitTest returns nil for point beyond bottom edge")
    func hitTestBeyondBottomEdge() {
        let interceptor = TerminalScrollInterceptor()
        interceptor.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        let result = interceptor.hitTest(NSPoint(x: 200, y: 300))
        #expect(result == nil)
    }

    @Test("isFlipped returns true")
    func isFlippedIsTrue() {
        let interceptor = TerminalScrollInterceptor()
        #expect(interceptor.isFlipped == true)
    }

    @Test("terminalView is nil by default")
    func terminalViewDefaultNil() {
        let interceptor = TerminalScrollInterceptor()
        #expect(interceptor.terminalView == nil)
    }
}
