//
//  TerminalManager.swift
//  Pine
//
//  Coordinator for terminal panes. Routes Cmd+T and Cmd+` to the
//  appropriate terminal pane via PaneManager.
//

import SwiftUI

@MainActor
@Observable
final class TerminalManager {
    /// Reference to the pane manager for creating/finding terminal panes.
    weak var paneManager: PaneManager?

    /// ID of the last-focused terminal pane (for Cmd+T routing).
    var lastActiveTerminalPaneID: PaneID?

    // MARK: - Tab creation

    /// Creates a terminal tab in the last-used terminal pane.
    /// If no terminal pane exists, creates one below the given editor pane.
    func createTerminalTab(relativeTo editorPaneID: PaneID, workingDirectory: URL?) {
        guard let pm = paneManager else { return }

        if let tpID = lastActiveTerminalPaneID,
           pm.terminalState(for: tpID) != nil {
            pm.terminalState(for: tpID)?.addTab(workingDirectory: workingDirectory)
            pm.activePaneID = tpID
        } else {
            // Create terminal pane spanning full width at bottom
            let newID = pm.createTerminalPaneAtBottom(workingDirectory: workingDirectory)
            lastActiveTerminalPaneID = newID
            // Collapse any empty editor placeholder that was sitting next to
            // the new terminal — the user clearly wants the screen real estate
            // for terminals, not for "No File Selected".
            pm.pruneEmptyEditorLeaves()
        }
    }

    /// Focuses the nearest terminal pane, or creates one.
    func focusOrCreateTerminal(relativeTo editorPaneID: PaneID, workingDirectory: URL?) {
        guard let pm = paneManager else { return }

        if let tpID = lastActiveTerminalPaneID,
           pm.terminalState(for: tpID) != nil {
            pm.activePaneID = tpID
        } else {
            if let firstTP = pm.terminalPaneIDs.first {
                pm.activePaneID = firstTP
                lastActiveTerminalPaneID = firstTP
            } else {
                createTerminalTab(relativeTo: editorPaneID, workingDirectory: workingDirectory)
            }
        }
    }

    // MARK: - Queries (delegate to PaneManager)

    var allTerminalTabs: [TerminalTab] {
        paneManager?.allTerminalTabs ?? []
    }

    var hasActiveProcesses: Bool {
        allTerminalTabs.contains { $0.hasForegroundProcess }
    }

    var tabsWithForegroundProcesses: [TerminalTab] {
        allTerminalTabs.filter { $0.hasForegroundProcess }
    }

    func terminateAll() {
        for tab in allTerminalTabs {
            tab.stop()
        }
    }

    func startTerminals(workingDirectory: URL?) {
        guard let pm = paneManager else { return }
        for state in pm.terminalStates.values {
            state.startTabs(workingDirectory: workingDirectory)
        }
    }
}
