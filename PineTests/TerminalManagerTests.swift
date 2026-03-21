//
//  TerminalManagerTests.swift
//  PineTests
//
//  Created by Claude on 14.03.2026.
//

import Foundation
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

    @Test("initial search state is hidden with empty query")
    func initialSearchState() {
        let manager = TerminalManager()
        #expect(manager.isSearchVisible == false)
        #expect(manager.terminalSearchQuery == "")
    }

    @Test("isSearchVisible can be toggled")
    func searchVisibilityToggle() {
        let manager = TerminalManager()
        manager.isSearchVisible = true
        #expect(manager.isSearchVisible == true)
        manager.isSearchVisible = false
        #expect(manager.isSearchVisible == false)
    }

    @Test("terminalSearchQuery can be updated")
    func searchQueryUpdate() {
        let manager = TerminalManager()
        manager.terminalSearchQuery = "hello"
        #expect(manager.terminalSearchQuery == "hello")
        manager.terminalSearchQuery = ""
        #expect(manager.terminalSearchQuery == "")
    }

    @Test("search on unstarted tab returns no matches")
    func searchOnUnstartedTabReturnsNoMatches() {
        let tab = TerminalTab(name: "Test")
        tab.search(for: "anything")
        // Empty terminal buffer produces no matches
        #expect(tab.searchMatches.isEmpty)
        #expect(tab.currentMatchIndex == -1)
    }

    @Test("search with empty query clears matches")
    func searchWithEmptyQueryClearsMatches() {
        let tab = TerminalTab(name: "Test")
        tab.search(for: "something")
        tab.search(for: "")
        #expect(tab.searchMatches.isEmpty)
        #expect(tab.currentMatchIndex == -1)
    }

    @Test("nextMatch and previousMatch do nothing when no matches")
    func navigationWithNoMatches() {
        let tab = TerminalTab(name: "Test")
        // No matches — navigation should not crash
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

    @Test("TerminalSearchMatch stores row, col, and length")
    func terminalSearchMatchProperties() {
        let match = TerminalSearchMatch(row: 5, col: 10, length: 3)
        #expect(match.row == 5)
        #expect(match.col == 10)
        #expect(match.length == 3)
    }
}
