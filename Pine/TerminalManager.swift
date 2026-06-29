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
    /// tests inject a no-op at construction to avoid forking `/bin/ps` (and
    /// the macos-26 fork/spawn hang, #1060). Read once at boot; stored
    /// privately so it cannot be mutated after construction.
    private let agentDetectionProcessRunner: ProcessRunner

    /// `true` once agent-detection polling has started. Read-only diagnostic /
    /// test hook. Delegates to the coordinator's `isRunning` so it correctly
    /// reports `false` after a future `stop()`.
    var isAgentDetectionPolling: Bool { agentCoordinator?.isRunning ?? false }

    /// Coordinator that polls `ps` off the main thread and reconciles agent
    /// sessions with terminal tabs. Started lazily by
    /// ``ensureAgentDetectionStarted()`` — invoked on the first terminal
    /// creation via ``createTerminalTab(relativeTo:workingDirectory:)``, on
    /// session restore (`ContentView.restoreSessionIfNeeded`), and via
    /// ``startTerminals(workingDirectory:)``.
    private var agentCoordinator: AgentDetectionCoordinator?

    /// Creates a terminal manager. `agentDetectionProcessRunner` is injected
    /// here (rather than exposed as a mutable property) so the coordinator's
    /// runner is fixed for the manager's lifetime — matches the init-param
    /// injection pattern used by `ExternalFileFormatter` / `FileFormatter`.
    init(agentDetectionProcessRunner: @escaping ProcessRunner = runRealProcess) {
        self.agentDetectionProcessRunner = agentDetectionProcessRunner
    }

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
    ///
    /// Callers: `createTerminalTab` (interactive creation), `startTerminals`
    /// (legacy), and `ContentView.restoreSessionIfNeeded` (session restore
    /// creates tabs via `state.addTab` directly, bypassing `createTerminalTab`).
    /// Internal rather than private so the restore path can reach it.
    func ensureAgentDetectionStarted() {
        guard agentCoordinator == nil else { return }
        // Allow UI tests (and users hitting the macos-26 fork/spawn hang,
        // #1060) to disable the coordinator entirely. Without this gate the
        // repeated 2s `ps` fork hangs the terminal UI-test shards on macos-26
        // runners — unit tests inject a no-op runner instead, so they do not
        // set this flag and still exercise the boot path.
        if Self.isAgentDetectionDisabled { return }
        let coord = AgentDetectionCoordinator(
            detector: agentDetector,
            terminalManager: self,
            processRunner: agentDetectionProcessRunner
        )
        agentCoordinator = coord
        coord.start()
    }

    /// `true` when agent detection is explicitly disabled via the
    /// `--disable-agent-detection` launch argument or the
    /// `PINE_DISABLE_AGENT_DETECTION` environment variable. Used by UI tests
    /// to avoid the macos-26 fork/spawn hang (#1060) and as a production
    /// opt-out for affected users.
    private static var isAgentDetectionDisabled: Bool {
        CommandLine.arguments.contains("--disable-agent-detection")
            || ProcessInfo.processInfo.environment["PINE_DISABLE_AGENT_DETECTION"] != nil
    }

    #if DEBUG
    /// Synchronous one-shot poll for unit tests: runs a single snapshot using
    /// the injected `agentDetectionProcessRunner` so tests can assert detector
    /// state without waiting for the 2s timer. No-op if detection has not
    /// booted. Proves the injected runner is wired through to the coordinator.
    @MainActor internal func runAgentSnapshotForTesting() {
        agentCoordinator?.runSnapshotForTesting()
    }
    #endif
}
