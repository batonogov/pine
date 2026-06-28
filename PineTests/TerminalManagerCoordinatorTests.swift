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
        let terminal = TerminalManager()
        terminal.paneManager = paneManager
        // Inject a no-op runner so the coordinator polls without forking `ps`.
        terminal.agentDetectionProcessRunner = Self.noOpProcessRunner

        let editorPane = paneManager.activePaneID
        terminal.createTerminalTab(relativeTo: editorPane, workingDirectory: nil)

        // Regression: previously `startTerminals` (the sole boot path for the
        // agent-detection coordinator) was never called from anywhere in the
        // app, so the coordinator never started and agent badges never
        // appeared. Creating a terminal must now boot detection.
        #expect(terminal.isAgentDetectionPolling)
    }
}
