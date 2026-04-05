import Foundation
import Testing

@testable import Pine

@Suite("Terminal Tab Drag Between Panes Tests")
@MainActor
struct TerminalTabDragBetweenPanesTests {

    @Test("splitAndMoveTerminalTab creates pane and moves tab")
    func splitAndMoveCreatesAndMoves() throws {
        let paneManager = PaneManager()
        let termPaneID = paneManager.createTerminalPaneAtBottom(workingDirectory: nil)
        let termState = try #require(paneManager.terminalState(for: termPaneID))
        termState.addTab(workingDirectory: nil)
        let tabToMove = termState.terminalTabs[0]
        let tabToMoveID = tabToMove.id

        let newPaneID = paneManager.splitAndMoveTerminalTab(
            tabID: tabToMoveID,
            from: termPaneID,
            relativeTo: termPaneID,
            axis: .horizontal,
            insertBefore: false
        )

        let unwrappedNewPaneID = try #require(newPaneID)
        let newState = try #require(paneManager.terminalState(for: unwrappedNewPaneID))
        #expect(newState.terminalTabs.count == 1)
        #expect(newState.terminalTabs[0].id == tabToMoveID)
        #expect(termState.terminalTabs.count == 1)
    }

    @Test("splitAndMoveTerminalTab removes source pane when last tab moved")
    func splitAndMoveRemovesEmptySource() throws {
        let paneManager = PaneManager()
        let termPaneID = paneManager.createTerminalPaneAtBottom(workingDirectory: nil)
        let termState = try #require(paneManager.terminalState(for: termPaneID))
        let tabID = termState.terminalTabs[0].id

        let newPaneID = paneManager.splitAndMoveTerminalTab(
            tabID: tabID,
            from: termPaneID,
            relativeTo: termPaneID,
            axis: .vertical,
            insertBefore: true
        )

        #expect(newPaneID != nil)
        #expect(paneManager.terminalState(for: termPaneID) == nil)
    }

    @Test("moveTerminalTab moves tab between existing panes")
    func moveTerminalTabBetweenPanes() throws {
        let paneManager = PaneManager()
        let pane1ID = paneManager.createTerminalPaneAtBottom(workingDirectory: nil)
        let pane1State = try #require(paneManager.terminalState(for: pane1ID))
        pane1State.addTab(workingDirectory: nil)

        let pane2ID = try #require(paneManager.createTerminalPane(
            relativeTo: pane1ID, axis: .horizontal, workingDirectory: nil
        ))
        let tabToMove = pane1State.terminalTabs[0]

        paneManager.moveTerminalTab(tabToMove.id, from: pane1ID, to: pane2ID)

        let pane2State = try #require(paneManager.terminalState(for: pane2ID))
        #expect(pane2State.terminalTabs.contains(where: { $0.id == tabToMove.id }))
        #expect(pane1State.terminalTabs.count == 1)
    }
}
