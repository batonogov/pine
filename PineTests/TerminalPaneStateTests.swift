//
//  TerminalPaneStateTests.swift
//  PineTests
//

import Testing
import Foundation
@testable import Pine

@Suite("TerminalPaneState Tests")
@MainActor
struct TerminalPaneStateTests {

    @Test func init_startsEmpty() {
        let state = TerminalPaneState()
        #expect(state.terminalTabs.isEmpty)
        #expect(state.activeTerminalID == nil)
    }

    @Test func addTab_createsTabAndSetsActive() {
        let state = TerminalPaneState()
        let tab = state.addTab(workingDirectory: nil)
        #expect(state.terminalTabs.count == 1)
        #expect(state.activeTerminalID == tab.id)
    }

    @Test func addMultipleTabs_activeIsLast() {
        let state = TerminalPaneState()
        _ = state.addTab(workingDirectory: nil)
        let second = state.addTab(workingDirectory: nil)
        #expect(state.terminalTabs.count == 2)
        #expect(state.activeTerminalID == second.id)
    }

    @Test func removeTab_updatesActive() {
        let state = TerminalPaneState()
        let first = state.addTab(workingDirectory: nil)
        let second = state.addTab(workingDirectory: nil)
        state.removeTab(id: second.id)
        #expect(state.terminalTabs.count == 1)
        #expect(state.activeTerminalID == first.id)
    }

    @Test func removeLastTab_activeBecomesNil() {
        let state = TerminalPaneState()
        let tab = state.addTab(workingDirectory: nil)
        state.removeTab(id: tab.id)
        #expect(state.terminalTabs.isEmpty)
        #expect(state.activeTerminalID == nil)
    }

    @Test func activeTab_returnsCorrectTab() {
        let state = TerminalPaneState()
        let tab = state.addTab(workingDirectory: nil)
        #expect(state.activeTab?.id == tab.id)
    }

    @Test func activeTab_nilWhenEmpty() {
        let state = TerminalPaneState()
        #expect(state.activeTab == nil)
    }

    @Test func pendingFocusTabID_setOnAdd() {
        let state = TerminalPaneState()
        let tab = state.addTab(workingDirectory: nil)
        #expect(state.pendingFocusTabID == tab.id)
    }

    @Test func tabCount_returnsCorrectCount() {
        let state = TerminalPaneState()
        #expect(state.tabCount == 0)
        _ = state.addTab(workingDirectory: nil)
        #expect(state.tabCount == 1)
        _ = state.addTab(workingDirectory: nil)
        #expect(state.tabCount == 2)
    }

    @Test func tabNaming_monotonicAfterClose() {
        let state = TerminalPaneState()
        let tab1 = state.addTab(workingDirectory: nil)
        let tab2 = state.addTab(workingDirectory: nil)
        // Close tab 1, add new — should be "Terminal 3", not "Terminal 2"
        state.removeTab(id: tab1.id)
        let tab3 = state.addTab(workingDirectory: nil)
        #expect(tab2.name != tab3.name)
    }
}
