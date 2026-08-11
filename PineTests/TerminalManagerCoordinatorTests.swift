//
//  TerminalManagerCoordinatorTests.swift
//  PineTests
//

import Testing
import Foundation
@testable import Pine

@Suite("TerminalManager Coordinator Tests")
@MainActor
struct TerminalManagerCoordinatorTests {

    @Test func createTerminalTab_noTerminalPane_createsOne() {
        let paneManager = PaneManager()
        let terminal = TerminalManager()
        terminal.paneManager = paneManager

        let editorPane = paneManager.activePaneID
        terminal.createTerminalTab(relativeTo: editorPane, workingDirectory: nil)

        #expect(paneManager.terminalPaneIDs.count == 1)
        guard let tpID = paneManager.terminalPaneIDs.first else {
            Issue.record("no terminal pane")
            return
        }
        #expect(paneManager.terminalState(for: tpID)?.tabCount == 1)
    }

    @Test func createTerminalTab_existingPane_addsTab() {
        let paneManager = PaneManager()
        let terminal = TerminalManager()
        terminal.paneManager = paneManager

        let editorPane = paneManager.activePaneID
        guard let tpID = paneManager.createTerminalPane(
            relativeTo: editorPane, axis: .vertical, workingDirectory: nil
        ) else {
            Issue.record("createTerminalPane failed")
            return
        }
        terminal.lastActiveTerminalPaneID = tpID

        terminal.createTerminalTab(relativeTo: editorPane, workingDirectory: nil)
        #expect(paneManager.terminalState(for: tpID)?.tabCount == 2)
    }

    @Test func focusOrCreateTerminal_existingPane_focusesIt() {
        let paneManager = PaneManager()
        let terminal = TerminalManager()
        terminal.paneManager = paneManager

        let editorPane = paneManager.activePaneID
        guard let tpID = paneManager.createTerminalPane(
            relativeTo: editorPane, axis: .vertical, workingDirectory: nil
        ) else {
            Issue.record("createTerminalPane failed")
            return
        }
        terminal.lastActiveTerminalPaneID = tpID
        paneManager.activePaneID = editorPane

        terminal.focusOrCreateTerminal(relativeTo: editorPane, workingDirectory: nil)
        #expect(paneManager.activePaneID == tpID)
    }

    @Test func focusOrCreateTerminal_existingPane_setsPendingFocusTabID() {
        let paneManager = PaneManager()
        let terminal = TerminalManager()
        terminal.paneManager = paneManager

        let editorPane = paneManager.activePaneID
        guard let tpID = paneManager.createTerminalPane(
            relativeTo: editorPane, axis: .vertical, workingDirectory: nil
        ) else {
            Issue.record("createTerminalPane failed")
            return
        }
        terminal.lastActiveTerminalPaneID = tpID
        paneManager.activePaneID = editorPane

        let activeTabID = paneManager.terminalState(for: tpID)?.activeTerminalID
        terminal.focusOrCreateTerminal(relativeTo: editorPane, workingDirectory: nil)

        #expect(paneManager.terminalState(for: tpID)?.pendingFocusTabID == activeTabID)
    }

    @Test func focusOrCreateTerminal_fallbackToFirstPane_setsPendingFocusTabID() {
        let paneManager = PaneManager()
        let terminal = TerminalManager()
        terminal.paneManager = paneManager

        let editorPane = paneManager.activePaneID
        guard let tpID = paneManager.createTerminalPane(
            relativeTo: editorPane, axis: .vertical, workingDirectory: nil
        ) else {
            Issue.record("createTerminalPane failed")
            return
        }
        // No lastActiveTerminalPaneID — should fall back to first terminal pane
        let activeTabID = paneManager.terminalState(for: tpID)?.activeTerminalID

        terminal.focusOrCreateTerminal(relativeTo: editorPane, workingDirectory: nil)

        #expect(paneManager.activePaneID == tpID)
        #expect(paneManager.terminalState(for: tpID)?.pendingFocusTabID == activeTabID)
    }

    @Test func createTerminalTab_existingPane_setsPendingFocusTabID() {
        let paneManager = PaneManager()
        let terminal = TerminalManager()
        terminal.paneManager = paneManager

        let editorPane = paneManager.activePaneID
        guard let tpID = paneManager.createTerminalPane(
            relativeTo: editorPane, axis: .vertical, workingDirectory: nil
        ) else {
            Issue.record("createTerminalPane failed")
            return
        }
        terminal.lastActiveTerminalPaneID = tpID

        terminal.createTerminalTab(relativeTo: editorPane, workingDirectory: nil)

        let state = paneManager.terminalState(for: tpID)
        #expect(state?.tabCount == 2)
        #expect(state?.pendingFocusTabID == state?.activeTerminalID)
    }

    @Test func focusOrCreateTerminal_noPane_createsOne() {
        let paneManager = PaneManager()
        let terminal = TerminalManager()
        terminal.paneManager = paneManager

        let editorPane = paneManager.activePaneID
        terminal.focusOrCreateTerminal(relativeTo: editorPane, workingDirectory: nil)

        #expect(paneManager.terminalPaneIDs.count == 1)
    }

    @Test func allTerminalTabs_delegatesToPaneManager() {
        let paneManager = PaneManager()
        let terminal = TerminalManager()
        terminal.paneManager = paneManager

        let editorPane = paneManager.activePaneID
        _ = paneManager.createTerminalPane(
            relativeTo: editorPane, axis: .vertical, workingDirectory: nil
        )

        #expect(terminal.allTerminalTabs.count == 1)
    }

    @Test func hasActiveProcesses_checksAllPanes() {
        let paneManager = PaneManager()
        let terminal = TerminalManager()
        terminal.paneManager = paneManager
        #expect(!terminal.hasActiveProcesses)
    }

    // MARK: - Agent detection wiring (regression: startTerminals was dead code)

    /// No-op `ps` runner used by agent-detection tests so the coordinator never
    /// forks a real subprocess (avoids the macos-26 fork/spawn hang, #1060).
    private static let noOpProcessRunner: ProcessRunner = { _, _, _, _ in
        ProcessRunResult(stdout: "", stderr: "", exitCode: 0, timedOut: false)
    }

    @Test func agentDetection_notPolling_beforeAnyTerminal() {
        let paneManager = PaneManager()
        let terminal = TerminalManager()
        terminal.paneManager = paneManager
        // Fresh manager with no terminals must not have started polling.
        #expect(!terminal.isAgentDetectionPolling)
    }

    @Test func createTerminalTab_startsAgentDetection() {
        let paneManager = PaneManager()
        // Inject a no-op runner at construction so the coordinator polls
        // without forking `ps`.
        let terminal = TerminalManager(agentDetectionProcessRunner: Self.noOpProcessRunner)
        terminal.paneManager = paneManager

        let editorPane = paneManager.activePaneID
        terminal.createTerminalTab(relativeTo: editorPane, workingDirectory: nil)

        // Regression: previously `startTerminals` (the sole boot path for the
        // agent-detection coordinator) was never called from anywhere in the
        // app, so the coordinator never started and agent badges never
        // appeared. Creating a terminal must now boot detection. This now
        // asserts `isRunning` (not just non-nil) via `isAgentDetectionPolling`.
        #expect(terminal.isAgentDetectionPolling)
    }

    @Test func terminationFreezePreservesAgentAuthorization() throws {
        let paneManager = PaneManager()
        let terminal = TerminalManager(
            agentDetectionProcessRunner: Self.noOpProcessRunner
        )
        terminal.paneManager = paneManager

        terminal.createTerminalTab(
            relativeTo: paneManager.activePaneID,
            workingDirectory: nil
        )
        #expect(terminal.isAgentDetectionPolling)

        let tab = try #require(terminal.allTerminalTabs.first)
        let startedAt = Date(timeIntervalSince1970: 10.000_020)
        let session = AgentSession(
            agentType: .claudeCode,
            startedAt: startedAt
        )
        _ = session.bindProcessEvidence(AgentProcessEvidence(
            processIdentifier: 42,
            processGeneration: 10,
            startIdentifier: "generation-10",
            observedStartedAt: startedAt,
            startIsAuthoritative: true
        ))
        tab.agentSession = session
        tab.foregroundProcessIDOverrideForTesting = 42
        tab.agentProcessIdentityResolverForTesting = { processID in
            TerminalProcessStartIdentity(
                processID: processID,
                seconds: 10,
                microseconds: 20
            )
        }
        let authorization = TerminalTabCloseAuthorization.authorizing(tabs: [tab])

        terminal.freezeAgentTasksForTermination()

        #expect(!terminal.isAgentDetectionPolling)
        #expect(tab.agentSession === session)
        #expect(authorization.stillCovers([tab]))
    }

    @Test func startTerminals_bootsAgentDetection() {
        let paneManager = PaneManager()
        let terminal = TerminalManager(agentDetectionProcessRunner: Self.noOpProcessRunner)
        terminal.paneManager = paneManager

        terminal.startTerminals(workingDirectory: nil)

        // The legacy / explicit start path must also boot detection.
        #expect(terminal.isAgentDetectionPolling)
    }

    @Test func createTerminalTab_injectedRunnerWiredToCoordinator() {
        let paneManager = PaneManager()
        // Inject a runner returning a fake `claude` process to prove the
        // injected runner (not the default `runRealProcess`) reaches the
        // booted coordinator and feeds the shared detector — validating the
        // full boot -> coordinator -> runner -> detector wiring through the
        // new `createTerminalTab` boot path.
        let terminal = TerminalManager(agentDetectionProcessRunner: { _, _, _, _ in
            ProcessRunResult(
                stdout: completeClaudePsSnapshot(),
                stderr: "",
                exitCode: 0,
                timedOut: false
            )
        })
        terminal.paneManager = paneManager

        let editorPane = paneManager.activePaneID
        terminal.createTerminalTab(relativeTo: editorPane, workingDirectory: nil)

        // Force a synchronous poll (DEBUG hook) so the mock `ps` output is
        // applied immediately. `tab.agentSession` itself cannot be asserted
        // here because a real terminal foreground pid is unavailable in unit
        // tests (`foregroundProcessID` returns -1); that link is covered by
        // `AgentDetectionCoordinatorTests`. We assert the detector saw the
        // mock output, which proves the wiring is live.
        terminal.runAgentSnapshotForTesting()
        #expect(terminal.agentDetector.detectedSessions.count == 1)
        #expect(terminal.agentDetector.detectedSessions.first?.agentType == .claudeCode)
    }
}

nonisolated private func completeClaudePsSnapshot() -> String {
    [
        "1 0 1 Wed Jul 22 15:08:40 2026 0:12.45 /sbin/launchd",
        "100 1 100 Wed Jul 22 15:08:40 2026 0:12.45 claude",
        """
        99999 1 99999 Wed Jul 22 15:08:40 2026 0:12.45 \
        /bin/ps -eo pid=,ppid=,pgid=,lstart=,cputime=,command=
        """,
        AgentDetectionCoordinator.psCompletionMarker,
    ].joined(separator: "\n")
}
