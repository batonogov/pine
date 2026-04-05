import Foundation
import Testing

@testable import Pine

@Suite("Terminal Tab Reorder Tests")
@MainActor
struct TerminalTabReorderTests {

    private func makeState(count: Int) -> TerminalPaneState {
        let state = TerminalPaneState()
        for _ in 0..<count {
            state.addTab(workingDirectory: nil)
        }
        return state
    }

    @Test("Reorder forward: first to last")
    func reorderForward() {
        let state = makeState(count: 3)
        let names = state.terminalTabs.map(\.stableLabel)
        let dragID = state.terminalTabs[0].id
        let targetID = state.terminalTabs[2].id

        state.reorderTab(draggedID: dragID, targetID: targetID)

        #expect(state.terminalTabs.map(\.stableLabel) == [names[1], names[2], names[0]])
    }

    @Test("Reorder backward: last to first")
    func reorderBackward() {
        let state = makeState(count: 3)
        let names = state.terminalTabs.map(\.stableLabel)
        let dragID = state.terminalTabs[2].id
        let targetID = state.terminalTabs[0].id

        state.reorderTab(draggedID: dragID, targetID: targetID)

        #expect(state.terminalTabs.map(\.stableLabel) == [names[2], names[0], names[1]])
    }

    @Test("Reorder same tab does nothing")
    func reorderSameTab() {
        let state = makeState(count: 3)
        let names = state.terminalTabs.map(\.stableLabel)
        let tabID = state.terminalTabs[1].id

        state.reorderTab(draggedID: tabID, targetID: tabID)

        #expect(state.terminalTabs.map(\.stableLabel) == names)
    }

    @Test("Reorder with non-existent ID does nothing")
    func reorderNonExistent() {
        let state = makeState(count: 2)
        let names = state.terminalTabs.map(\.stableLabel)

        state.reorderTab(draggedID: UUID(), targetID: state.terminalTabs[0].id)

        #expect(state.terminalTabs.map(\.stableLabel) == names)
    }

    @Test("Reorder preserves active tab ID")
    func reorderPreservesActive() {
        let state = makeState(count: 3)
        let activeID = state.terminalTabs[1].id
        state.activeTerminalID = activeID

        state.reorderTab(draggedID: state.terminalTabs[0].id, targetID: state.terminalTabs[2].id)

        #expect(state.activeTerminalID == activeID)
    }

    @Test("Reorder single tab does nothing")
    func reorderSingleTab() {
        let state = makeState(count: 1)
        let tabID = state.terminalTabs[0].id

        state.reorderTab(draggedID: tabID, targetID: tabID)

        #expect(state.terminalTabs.count == 1)
    }
}
