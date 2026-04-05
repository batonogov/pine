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
    var activeTerminalID: UUID?
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
        let tab = terminalTabs.remove(at: fromIndex)
        // After removal, find target's new position and insert at that index
        // (before the target for backward moves, after it for forward moves)
        guard let destIndex = terminalTabs.firstIndex(where: { $0.id == targetID }) else { return }
        let insertAt = fromIndex < toIndex ? destIndex + 1 : destIndex
        terminalTabs.insert(tab, at: insertAt)
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
