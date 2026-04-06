//
//  PaneManagerRootDropTests.swift
//  PineTests
//

import Testing
import Foundation
@testable import Pine

@Suite("PaneManager Root Drop Tests")
@MainActor
struct PaneManagerRootDropTests {

    // MARK: - Helpers

    /// Creates a PaneManager with one editor pane and one terminal pane at the bottom,
    /// returning (manager, editorPaneID, terminalPaneID, terminalTabID).
    private func managerWithTerminal() throws -> (PaneManager, PaneID, PaneID, UUID) {
        let manager = PaneManager()
        let editorID = manager.activePaneID
        let terminalID = manager.createTerminalPaneAtBottom(workingDirectory: nil)
        let state = try #require(manager.terminalState(for: terminalID))
        let tab = try #require(state.terminalTabs.first)
        return (manager, editorID, terminalID, tab.id)
    }

    // MARK: - wrapRootWithTerminal

    @Test func wrapBottom_createsVerticalSplitWithTerminalSecond() throws {
        let (manager, _, terminalID, tabID) = try managerWithTerminal()

        manager.wrapRootWithTerminal(at: .bottom, from: terminalID, tabID: tabID)

        if case .split(let axis, _, let second, let ratio) = manager.root {
            #expect(axis == .vertical)
            #expect(ratio == 0.7)
            if case .leaf(_, let content) = second {
                #expect(content == .terminal)
            } else {
                Issue.record("Expected terminal leaf as second child")
            }
        } else {
            Issue.record("Expected split node at root")
        }
    }

    @Test func wrapTop_createsVerticalSplitWithTerminalFirst() throws {
        let (manager, _, terminalID, tabID) = try managerWithTerminal()

        manager.wrapRootWithTerminal(at: .top, from: terminalID, tabID: tabID)

        if case .split(let axis, let first, _, let ratio) = manager.root {
            #expect(axis == .vertical)
            #expect(ratio == 0.3)
            if case .leaf(_, let content) = first {
                #expect(content == .terminal)
            } else {
                Issue.record("Expected terminal leaf as first child")
            }
        } else {
            Issue.record("Expected split node at root")
        }
    }

    @Test func wrapRight_createsHorizontalSplitWithTerminalSecond() throws {
        let (manager, _, terminalID, tabID) = try managerWithTerminal()

        manager.wrapRootWithTerminal(at: .right, from: terminalID, tabID: tabID)

        if case .split(let axis, _, let second, let ratio) = manager.root {
            #expect(axis == .horizontal)
            #expect(ratio == 0.7)
            if case .leaf(_, let content) = second {
                #expect(content == .terminal)
            } else {
                Issue.record("Expected terminal leaf as second child")
            }
        } else {
            Issue.record("Expected split node at root")
        }
    }

    @Test func wrapLeft_createsHorizontalSplitWithTerminalFirst() throws {
        let (manager, _, terminalID, tabID) = try managerWithTerminal()

        manager.wrapRootWithTerminal(at: .left, from: terminalID, tabID: tabID)

        if case .split(let axis, let first, _, let ratio) = manager.root {
            #expect(axis == .horizontal)
            #expect(ratio == 0.3)
            if case .leaf(_, let content) = first {
                #expect(content == .terminal)
            } else {
                Issue.record("Expected terminal leaf as first child")
            }
        } else {
            Issue.record("Expected split node at root")
        }
    }

    @Test func wrapRoot_movesTerminalTabToNewPane() throws {
        let (manager, _, terminalID, tabID) = try managerWithTerminal()

        manager.wrapRootWithTerminal(at: .bottom, from: terminalID, tabID: tabID)

        // Source pane should be gone (it had only one tab)
        #expect(manager.terminalState(for: terminalID) == nil)

        // New terminal pane should have the tab
        let newTerminalPanes = manager.terminalPaneIDs.filter { $0 != terminalID }
        #expect(newTerminalPanes.count == 1)
        let newState = try #require(manager.terminalState(for: newTerminalPanes[0]))
        #expect(newState.terminalTabs.count == 1)
        #expect(newState.terminalTabs[0].id == tabID)
    }

    @Test func wrapRoot_sourcePaneKeptWhenMultipleTabs() throws {
        let manager = PaneManager()
        let terminalID = manager.createTerminalPaneAtBottom(workingDirectory: nil)
        let state = try #require(manager.terminalState(for: terminalID))
        state.addTab(workingDirectory: nil) // second tab
        let firstTabID = state.terminalTabs[0].id

        manager.wrapRootWithTerminal(at: .right, from: terminalID, tabID: firstTabID)

        // Source pane should still exist with 1 remaining tab
        let remainingState = try #require(manager.terminalState(for: terminalID))
        #expect(remainingState.terminalTabs.count == 1)
    }

    @Test func wrapRoot_setsActivePaneToNewTerminal() throws {
        let (manager, _, terminalID, tabID) = try managerWithTerminal()

        manager.wrapRootWithTerminal(at: .bottom, from: terminalID, tabID: tabID)

        let newTerminalPanes = manager.terminalPaneIDs
        #expect(newTerminalPanes.contains(manager.activePaneID))
    }

    @Test func rootDropZone_clearedByDefault() {
        let manager = PaneManager()
        #expect(manager.rootDropZone == nil)
    }
}
