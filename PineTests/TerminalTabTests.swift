//
//  TerminalTabTests.swift
//  PineTests
//

import Testing
import AppKit
import SwiftTerm
@testable import Pine

/// Tests for TerminalTab, TerminalSearchMatch, TerminalContainerView, TerminalTabDelegate.
struct TerminalTabTests {

    // MARK: - TerminalSearchMatch

    @Test func searchMatch_storesValues() {
        let match = TerminalSearchMatch(row: 5, col: 10, length: 3)
        #expect(match.row == 5)
        #expect(match.col == 10)
        #expect(match.length == 3)
    }

    // MARK: - TerminalTab initialization

    @Test func terminalTab_defaultName() {
        let tab = TerminalTab(name: "zsh")
        #expect(tab.name == "zsh")
        #expect(tab.isTerminated == false)
        #expect(tab.searchMatches.isEmpty)
        #expect(tab.currentMatchIndex == -1)
    }

    @Test func terminalTab_hasUniqueID() {
        let tab1 = TerminalTab(name: "tab1")
        let tab2 = TerminalTab(name: "tab2")
        #expect(tab1.id != tab2.id)
    }

    @Test func terminalTab_equality() {
        let tab = TerminalTab(name: "test")
        #expect(tab == tab)

        let other = TerminalTab(name: "test")
        #expect(tab != other) // Different IDs
    }

    @Test func terminalTab_hashable() {
        let tab = TerminalTab(name: "test")
        var set: Set<TerminalTab> = []
        set.insert(tab)
        set.insert(tab) // Duplicate
        #expect(set.count == 1)
    }

    @Test func terminalTab_configure() {
        let tab = TerminalTab(name: "test")
        let url = URL(fileURLWithPath: "/tmp")
        tab.configure(workingDirectory: url)
        // Should not crash; workingDirectory stored internally
    }

    @Test func terminalTab_configureNil() {
        let tab = TerminalTab(name: "test")
        tab.configure(workingDirectory: nil)
        // Should not crash
    }

    @Test func terminalTab_stopSetsTerminated() {
        let tab = TerminalTab(name: "test")
        #expect(tab.isTerminated == false)
        tab.stop()
        #expect(tab.isTerminated == true)
    }

    @Test func terminalTab_stopIdempotent() {
        let tab = TerminalTab(name: "test")
        tab.stop()
        tab.stop() // Should not crash
        #expect(tab.isTerminated == true)
    }

    @Test func terminalTab_nameCanBeChanged() {
        let tab = TerminalTab(name: "original")
        tab.name = "renamed"
        #expect(tab.name == "renamed")
    }

    // MARK: - Search state

    @Test func terminalTab_searchInitialState() {
        let tab = TerminalTab(name: "test")
        #expect(tab.searchMatches.isEmpty)
        #expect(tab.currentMatchIndex == -1)
    }

    @Test func terminalTab_nextMatch_noMatches() {
        let tab = TerminalTab(name: "test")
        tab.nextMatch() // Should not crash
        #expect(tab.currentMatchIndex == -1)
    }

    @Test func terminalTab_previousMatch_noMatches() {
        let tab = TerminalTab(name: "test")
        tab.previousMatch() // Should not crash
        #expect(tab.currentMatchIndex == -1)
    }

    @Test func terminalTab_clearSearch() {
        let tab = TerminalTab(name: "test")
        tab.clearSearch()
        #expect(tab.searchMatches.isEmpty)
        #expect(tab.currentMatchIndex == -1)
    }

    // MARK: - TerminalContainerView

    @Test func containerView_isFlipped() {
        let container = TerminalContainerView()
        #expect(container.isFlipped == true)
    }

    @Test func containerView_showTabNil() {
        let container = TerminalContainerView()
        container.showTab(nil)
        #expect(container.subviews.isEmpty)
    }

    @Test func containerView_showTabAddsSubview() {
        let container = TerminalContainerView(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
        let tab = TerminalTab(name: "test")
        container.showTab(tab)
        #expect(container.subviews.count == 1)
    }

    @Test func containerView_showSameTabTwiceIsNoop() {
        let container = TerminalContainerView(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
        let tab = TerminalTab(name: "test")
        container.showTab(tab)
        container.showTab(tab)
        #expect(container.subviews.count == 1)
    }

    @Test func containerView_switchTabs() {
        let container = TerminalContainerView(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
        let tab1 = TerminalTab(name: "tab1")
        let tab2 = TerminalTab(name: "tab2")

        container.showTab(tab1)
        #expect(container.subviews.count == 1)

        container.showTab(tab2)
        #expect(container.subviews.count == 1)
        // The view should be tab2's terminal view
        #expect(container.subviews.first === tab2.terminalView)
    }

    // MARK: - TerminalTabDelegate

    @Test func delegate_setTerminalTitle() {
        let delegate = TerminalTabDelegate()
        let tab = TerminalTab(name: "original")
        delegate.tab = tab

        let view = LocalProcessTerminalView(frame: .zero)
        delegate.setTerminalTitle(source: view, title: "new title")
        #expect(tab.name == "new title")
    }

    @Test func delegate_processTerminated() {
        let delegate = TerminalTabDelegate()
        let tab = TerminalTab(name: "test")
        delegate.tab = tab

        #expect(tab.isTerminated == false)
        delegate.processTerminated(source: tab.terminalView, exitCode: 0)
        #expect(tab.isTerminated == true)
    }

    @Test func delegate_processTerminatedWithError() {
        let delegate = TerminalTabDelegate()
        let tab = TerminalTab(name: "test")
        delegate.tab = tab

        delegate.processTerminated(source: tab.terminalView, exitCode: 1)
        #expect(tab.isTerminated == true)
    }

    @Test func delegate_weakTabReference() {
        let delegate = TerminalTabDelegate()
        // Setting to nil should not crash
        delegate.tab = nil
        delegate.processTerminated(source: LocalProcessTerminalView(frame: .zero), exitCode: 0)
    }
}
