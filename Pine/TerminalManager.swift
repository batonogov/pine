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

    // MARK: - Agent detection (#950, #951)

    /// The agent detector fed by `agentCoordinator`. Exposed read-only so
    /// future consumers (status bar #952) can observe it.
    private(set) var agentDetector = AgentDetector()

    /// Process runner used by the agent-detection coordinator to capture the
    /// `ps` snapshot. Defaults to real subprocess execution (`runRealProcess`);
    /// tests inject a no-op to avoid forking `/bin/ps` (and the macos-26
    /// fork/spawn hang, #1060). Must be set before the first terminal is
    /// created — the coordinator reads it once at startup.
    var agentDetectionProcessRunner: ProcessRunner = runRealProcess

    /// `true` once agent-detection polling has started. Read-only diagnostic /
    /// test hook; the coordinator runs for the lifetime of this
    /// `TerminalManager` once booted.
    var isAgentDetectionPolling: Bool { agentCoordinator != nil }

    /// Coordinator that polls `ps` off the main thread and reconciles agent
    /// sessions with terminal tabs. Started lazily by
    /// ``ensureAgentDetectionStarted()``, which is invoked on the first
    /// terminal creation via ``createTerminalTab(relativeTo:workingDirectory:)``
    /// and on session restore via ``startTerminals(workingDirectory:)``.
    private var agentCoordinator: AgentDetectionCoordinator?

    // MARK: - Tab creation

    /// Creates a terminal tab in the last-used terminal pane.
    /// If no terminal pane exists, creates one below the given editor pane.
    func createTerminalTab(relativeTo editorPaneID: PaneID, workingDirectory: URL?) {
        guard let pm = paneManager else { return }
        // Boot agent detection on the first terminal creation. Idempotent —
        // the guard inside makes repeated calls a no-op. The coordinator
        // lives for the lifetime of this `TerminalManager` and reconciles
        // against all terminal tabs on each 2s poll, so terminals created
        // later are picked up automatically (vision #933, issues #950/#951).
        ensureAgentDetectionStarted()

        if let tpID = lastActiveTerminalPaneID,
           pm.terminalState(for: tpID) != nil {
            // Adding a tab to an existing terminal pane is not a structural
            // mutation — the layout already includes a terminal, so any
            // adjacent empty editor was already pruned (or kept on purpose).
            // No prune needed here.
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
           let state = pm.terminalState(for: tpID) {
            pm.activePaneID = tpID
            state.pendingFocusTabID = state.activeTerminalID
        } else if let firstTP = pm.terminalPaneIDs.first,
                  let state = pm.terminalState(for: firstTP) {
            pm.activePaneID = firstTP
            lastActiveTerminalPaneID = firstTP
            state.pendingFocusTabID = state.activeTerminalID
        } else {
            createTerminalTab(relativeTo: editorPaneID, workingDirectory: workingDirectory)
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

        // Start agent detection polling once terminals are live (#951).
        ensureAgentDetectionStarted()
    }

    /// Ensures the agent-detection coordinator is polling `ps` and reconciling
    /// agent sessions with terminal tabs. Idempotent: a no-op once the
    /// coordinator exists, so safe to call on every terminal creation.
    ///
    /// This is the sole boot path for agent detection. It MUST be invoked when
    /// a terminal comes alive — otherwise the coordinator never starts, `ps`
    /// is never polled, and no `AgentSession` is ever attached to a tab, so
    /// agent badges/status-bar items never appear (regression: `startTerminals`
    /// was previously the only caller and was never wired into the app
    /// lifecycle, leaving detection dead in shipped builds).
    private func ensureAgentDetectionStarted() {
        guard agentCoordinator == nil else { return }
        let coord = AgentDetectionCoordinator(
            detector: agentDetector,
            terminalManager: self,
            processRunner: agentDetectionProcessRunner
        )
        agentCoordinator = coord
        coord.start()
    }
}
