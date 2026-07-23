//
//  TerminalPaneState.swift
//  Pine
//
//  Per-pane terminal state. Each terminal leaf in the PaneNode tree
//  owns one TerminalPaneState managing its terminal tabs.
//

import SwiftUI

@MainActor
@Observable
final class TerminalPaneState {
    var terminalTabs: [TerminalTab] = []
    var activeTerminalID: UUID? {
        didSet {
            guard activeTerminalID != oldValue else { return }
            if pendingFocusTabID != activeTerminalID {
                pendingFocusTabID = nil
            }
        }
    }
    var pendingFocusTabID: UUID?

    /// Monotonically increasing counter for unique terminal tab names.
    private var nextTabNumber = 1

    var isSearchVisible = false
    var terminalSearchQuery = ""
    var isSearchCaseSensitive = false

    var activeTab: TerminalTab? {
        guard let id = activeTerminalID else { return nil }
        return terminalTabs.first { $0.id == id }
    }

    var tabCount: Int { terminalTabs.count }

    /// Clears a focus request only after AppKit confirms that the active
    /// terminal view became first responder.
    @discardableResult
    func acknowledgeFocusRequest(for tabID: UUID, succeeded: Bool) -> Bool {
        guard pendingFocusTabID == tabID else { return false }
        guard activeTerminalID == tabID else {
            pendingFocusTabID = nil
            return false
        }
        guard succeeded else { return false }
        pendingFocusTabID = nil
        return true
    }

    @discardableResult
    func addTab(workingDirectory: URL?) -> TerminalTab {
        let number = nextTabNumber
        nextTabNumber += 1
        let tab = TerminalTab(name: Strings.terminalNumberedName(number))
        tab.configure(workingDirectory: workingDirectory)
        terminalTabs.append(tab)
        activeTerminalID = tab.id
        pendingFocusTabID = tab.id
        return tab
    }

    func removeTab(id: UUID) {
        guard let tab = terminalTabs.first(where: { $0.id == id }) else { return }
        tab.stop()
        terminalTabs.removeAll { $0.id == id }
        if activeTerminalID == id {
            activeTerminalID = terminalTabs.last?.id
        }
    }

    func reorderTab(draggedID: UUID, targetID: UUID) {
        guard draggedID != targetID,
              let fromIndex = terminalTabs.firstIndex(where: { $0.id == draggedID }),
              let toIndex = terminalTabs.firstIndex(where: { $0.id == targetID }) else { return }
        terminalTabs.move(
            fromOffsets: IndexSet(integer: fromIndex),
            toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex
        )
    }

    /// Moves a terminal tab to one of the strip's N+1 pre-removal gaps.
    func canMoveTab(id: UUID, toInsertionIndex insertionIndex: Int) -> TabInsertionResult {
        guard (0...terminalTabs.count).contains(insertionIndex),
              let sourceIndex = terminalTabs.firstIndex(where: { $0.id == id }) else {
            return .rejected
        }
        let destinationIndex = insertionIndex > sourceIndex
            ? insertionIndex - 1
            : insertionIndex
        return destinationIndex == sourceIndex ? .noOp : .moved
    }

    @discardableResult
    func moveTab(id: UUID, toInsertionIndex insertionIndex: Int) -> TabInsertionResult {
        let validation = canMoveTab(id: id, toInsertionIndex: insertionIndex)
        guard validation != .rejected,
              let sourceIndex = terminalTabs.firstIndex(where: { $0.id == id }) else {
            return .rejected
        }

        let destinationIndex = insertionIndex > sourceIndex
            ? insertionIndex - 1
            : insertionIndex
        guard validation == .moved else {
            activeTerminalID = id
            pendingFocusTabID = id
            return .noOp
        }

        let tab = terminalTabs.remove(at: sourceIndex)
        terminalTabs.insert(tab, at: destinationIndex)
        activeTerminalID = id
        pendingFocusTabID = id
        return .moved
    }

    func startTabs(workingDirectory: URL?) {
        for tab in terminalTabs {
            tab.configure(workingDirectory: workingDirectory)
        }
        if activeTerminalID == nil {
            activeTerminalID = terminalTabs.first?.id
        }
    }

}
