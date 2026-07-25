//
//  AccessibleTabMovementTests.swift
//  PineTests
//

import Foundation
import Testing

@testable import Pine

@Suite("Keyboard and VoiceOver Tab Movement")
@MainActor
struct AccessibleTabMovementTests {
    @Test("Editor leading and trailing moves preserve pinned boundary")
    func editorReorderAndPinnedBoundary() throws {
        let paneManager = PaneManager()
        let paneID = paneManager.activePaneID
        let manager = try #require(paneManager.tabManager(for: paneID))
        let urls = ["a.swift", "b.swift", "c.swift"].map {
            URL(fileURLWithPath: "/project/\($0)")
        }
        manager.tabs = urls.map { EditorTab(url: $0) }
        manager.activeTabID = manager.tabs[1].id
        manager.togglePin(id: manager.tabs[0].id)
        let activeID = try #require(manager.activeTabID)

        #expect(!paneManager.canMoveActiveTab(.leading))
        #expect(!paneManager.moveActiveTab(.leading))
        #expect(manager.tabs.map(\.url) == urls)

        #expect(paneManager.canMoveActiveTab(.trailing))
        #expect(paneManager.moveActiveTab(.trailing))
        #expect(manager.tabs.map(\.url) == [urls[0], urls[2], urls[1]])
        #expect(manager.activeTabID == activeID)
        #expect(manager.pendingFocusTabID == activeID)
    }

    @Test("Cross-pane editor move promotes preview and preserves identity and editor state")
    func editorCrossPaneMove() throws {
        let paneManager = PaneManager()
        let sourcePane = paneManager.activePaneID
        let destinationPane = try #require(
            paneManager.splitPane(sourcePane, axis: .horizontal)
        )
        let source = try #require(paneManager.tabManager(for: sourcePane))
        let destination = try #require(paneManager.tabManager(for: destinationPane))
        var preview = EditorTab(
            url: URL(fileURLWithPath: "/project/preview.swift"),
            content: "let value = 1",
            savedContent: "let value = 1"
        )
        preview.isTransientPreview = true
        preview.cursorPosition = 7
        preview.scrollOffset = 42
        source.tabs = [preview]
        source.activeTabID = preview.id
        paneManager.activePaneID = sourcePane

        #expect(paneManager.canMoveActiveTab(.nextPane))
        #expect(paneManager.moveActiveTab(.nextPane))

        #expect(paneManager.root.leafIDs == [destinationPane])
        let moved = try #require(destination.tabs.first)
        #expect(moved.id == preview.id)
        #expect(!moved.isTransientPreview)
        #expect(moved.cursorPosition == 7)
        #expect(moved.scrollOffset == 42)
        #expect(destination.activeTabID == moved.id)
        #expect(destination.pendingFocusTabID == moved.id)
        #expect(paneManager.activePaneID == destinationPane)
    }

    @Test("Terminal tabs reorder and move across terminal panes")
    func terminalMovement() throws {
        let paneManager = PaneManager()
        let editorPane = paneManager.activePaneID
        let firstTerminal = paneManager.createTerminalPane(
            relativeTo: editorPane,
            axis: .vertical,
            workingDirectory: nil
        )
        let firstPane = try #require(firstTerminal)
        let secondTerminal = paneManager.createTerminalPane(
            relativeTo: firstPane,
            axis: .horizontal,
            workingDirectory: nil
        )
        let secondPane = try #require(secondTerminal)
        let firstState = try #require(paneManager.terminalState(for: firstPane))
        let secondState = try #require(paneManager.terminalState(for: secondPane))
        let extra = firstState.addTab(workingDirectory: nil)
        paneManager.activePaneID = firstPane

        #expect(paneManager.moveActiveTab(.leading))
        #expect(firstState.terminalTabs.first?.id == extra.id)
        #expect(firstState.pendingFocusTabID == extra.id)

        #expect(paneManager.moveActiveTab(.nextPane))
        #expect(firstState.terminalTabs.count == 1)
        #expect(secondState.terminalTabs.last?.id == extra.id)
        #expect(secondState.activeTerminalID == extra.id)
        #expect(secondState.pendingFocusTabID == extra.id)
        #expect(paneManager.activePaneID == secondPane)
    }

    @Test("Maximized layout rejects hidden cross-pane mutation")
    func maximizedRejectsCrossPaneMove() throws {
        let paneManager = PaneManager()
        let firstPane = paneManager.activePaneID
        let secondPane = try #require(
            paneManager.splitPane(firstPane, axis: .horizontal)
        )
        let first = try #require(paneManager.tabManager(for: firstPane))
        let second = try #require(paneManager.tabManager(for: secondPane))
        let tab = EditorTab(url: URL(fileURLWithPath: "/project/main.swift"))
        first.tabs = [tab]
        first.activeTabID = tab.id
        second.tabs = [EditorTab(url: URL(fileURLWithPath: "/project/other.swift"))]
        second.activeTabID = second.tabs[0].id
        paneManager.activePaneID = firstPane
        paneManager.maximize(paneID: firstPane)

        #expect(!paneManager.canMoveActiveTab(.nextPane))
        #expect(!paneManager.moveActiveTab(.nextPane))
        #expect(first.tabs.map(\.id) == [tab.id])
        #expect(second.tabs.count == 1)
    }

    @Test("Pane movement skips incompatible content and chooses nearest matching pane")
    func skipsIncompatiblePanes() throws {
        let paneManager = PaneManager()
        let firstEditor = paneManager.activePaneID
        let terminal = paneManager.createTerminalPane(
            relativeTo: firstEditor,
            axis: .horizontal,
            workingDirectory: nil
        )
        let terminalPane = try #require(terminal)
        let secondEditor = try #require(
            paneManager.splitPane(terminalPane, axis: .horizontal)
        )
        let first = try #require(paneManager.tabManager(for: firstEditor))
        let second = try #require(paneManager.tabManager(for: secondEditor))
        let tab = EditorTab(url: URL(fileURLWithPath: "/project/main.swift"))
        first.tabs = [tab]
        first.activeTabID = tab.id
        second.tabs = [EditorTab(url: URL(fileURLWithPath: "/project/other.swift"))]
        second.activeTabID = second.tabs[0].id
        paneManager.activePaneID = firstEditor

        #expect(paneManager.moveActiveTab(.nextPane))
        #expect(second.tabs.contains(where: { $0.id == tab.id }))
        #expect(paneManager.root.content(for: terminalPane) == .terminal)
    }
}
