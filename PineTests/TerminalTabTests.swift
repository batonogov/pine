//
//  TerminalTabTests.swift
//  PineTests
//

import Testing
import AppKit
import SwiftTerm
@testable import Pine

/// Tests for TerminalTab, TerminalContainerView, TerminalTabDelegate.
@Suite("TerminalTab Tests")
struct TerminalTabTests {

    // MARK: - TerminalTab lifecycle

    @Test func terminalTabInitialState() {
        let tab = TerminalTab(name: "zsh")
        #expect(tab.name == "zsh")
        #expect(tab.isTerminated == false)
        #expect(tab.searchMatches.isEmpty)
        #expect(tab.currentMatchIndex == -1)
    }

    @Test func terminalTabsHaveUniqueIDs() {
        let tab1 = TerminalTab(name: "tab1")
        let tab2 = TerminalTab(name: "tab2")
        #expect(tab1.id != tab2.id)
        #expect(tab1 != tab2)
    }

    @Test func terminalTabHashable() {
        let tab = TerminalTab(name: "test")
        var set: Set<TerminalTab> = [tab, tab]
        #expect(set.count == 1)
    }

    @Test func stopSetsTerminatedIdempotently() {
        let tab = TerminalTab(name: "test")
        tab.stop()
        #expect(tab.isTerminated == true)
        tab.stop() // second call should not crash
        #expect(tab.isTerminated == true)
    }

    // MARK: - Search navigation with empty matches

    @Test func nextMatchNoOpWithoutMatches() {
        let tab = TerminalTab(name: "test")
        tab.nextMatch()
        #expect(tab.currentMatchIndex == -1)
    }

    @Test func previousMatchNoOpWithoutMatches() {
        let tab = TerminalTab(name: "test")
        tab.previousMatch()
        #expect(tab.currentMatchIndex == -1)
    }

    @Test func clearSearchResetsState() {
        let tab = TerminalTab(name: "test")
        tab.clearSearch()
        #expect(tab.searchMatches.isEmpty)
        #expect(tab.currentMatchIndex == -1)
    }

    // MARK: - TerminalContainerView

    @Test func showTabNilClearsSubviews() {
        let container = TerminalContainerView()
        container.showTab(nil)
        #expect(container.subviews.isEmpty)
    }

    @Test func showTabAddsTerminalView() {
        let container = TerminalContainerView(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
        let tab = TerminalTab(name: "test")
        container.showTab(tab)
        #expect(container.subviews.count == 1)
    }

    @Test func showSameTabTwiceIsNoOp() {
        let container = TerminalContainerView(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
        let tab = TerminalTab(name: "test")
        container.showTab(tab)
        container.showTab(tab)
        #expect(container.subviews.count == 1)
    }

    @Test func switchTabsReplacesSubview() {
        let container = TerminalContainerView(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
        let tab1 = TerminalTab(name: "tab1")
        let tab2 = TerminalTab(name: "tab2")

        container.showTab(tab1)
        container.showTab(tab2)
        #expect(container.subviews.count == 1)
        #expect(container.subviews.first === tab2.terminalView)
    }

    // MARK: - TerminalTabDelegate

    @Test func delegateSetTerminalTitle() {
        let delegate = TerminalTabDelegate()
        let tab = TerminalTab(name: "original")
        delegate.tab = tab

        delegate.setTerminalTitle(source: LocalProcessTerminalView(frame: .zero), title: "new title")
        #expect(tab.name == "new title")
    }

    @Test func delegateProcessTerminatedSetsFlag() {
        let delegate = TerminalTabDelegate()
        let tab = TerminalTab(name: "test")
        delegate.tab = tab

        delegate.processTerminated(source: tab.terminalView, exitCode: 0)
        #expect(tab.isTerminated == true)
    }

    @Test func delegateProcessTerminatedWithNonZeroExitCode() {
        let delegate = TerminalTabDelegate()
        let tab = TerminalTab(name: "test")
        delegate.tab = tab

        delegate.processTerminated(source: tab.terminalView, exitCode: 127)
        #expect(tab.isTerminated == true)
    }

    @Test func delegateHandlesNilTabGracefully() {
        let delegate = TerminalTabDelegate()
        delegate.tab = nil
        // Should not crash when tab is nil
        delegate.processTerminated(source: LocalProcessTerminalView(frame: .zero), exitCode: 0)
        delegate.setTerminalTitle(source: LocalProcessTerminalView(frame: .zero), title: "test")
    }
}
