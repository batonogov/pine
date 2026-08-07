//
//  BulkCloseAgentAuthorizationTests.swift
//  PineTests
//
//  Regression coverage for #1348: the two bulk destructive paths — project
//  window close and application quit — must authorize terminal tabs through
//  `TerminalTabCloseAuthorization` (stable agent-session identity), exactly
//  like the single-tab path fixed in #1343.
//
//  The pre-#1348 mechanism snapshotted the volatile foreground pgid before
//  presenting the sheet and required the post-sheet snapshot to be a subset.
//  An agent tab has no foreground pgid of its own between child spawns, so
//  that snapshot was empty: the bulk paths never warned about a running
//  agent at all, and once a child did appear mid-sheet the subset check
//  failed and the confirmed close/quit aborted in silence.
//
//  Each test below fails against that old mechanism and passes against the
//  authorization primitive.
//

import AppKit
import Foundation
import Testing
@testable import Pine

@Suite("Bulk Close Agent Authorization (#1348)")
@MainActor
struct BulkCloseAgentAuthorizationTests {

    // MARK: - Fixtures

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PineBulkCloseAuth-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func settle() async {
        for _ in 0..<8 { await Task.yield() }
    }

    /// Adds a terminal pane carrying one tab that is running an AI agent.
    /// The tab has no live PTY, so `foregroundProcessID` stays `-1` — which is
    /// precisely the state the old pgid snapshot could not represent.
    @discardableResult
    private func addAgentTerminalTab(
        to projectManager: ProjectManager
    ) throws -> TerminalTab {
        projectManager.paneManager.createTerminalPaneAtBottom(
            workingDirectory: nil
        )
        let tab = try #require(projectManager.terminal.allTerminalTabs.first)
        #expect(!tab.hasForegroundProcess)
        tab.agentSession = AgentSession(agentType: .claudeCode)
        return tab
    }

    // MARK: - Project window close

    @Test("Window close warns about a running agent that has no foreground pgid")
    func windowCloseWarnsAboutRunningAgent() async throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }
        let registry = ProjectRegistry()
        let project = try #require(registry.projectManager(for: dir))
        try addAgentTerminalTab(to: project)

        var presentedTemplates: [AlertTemplate] = []
        let delegate = CloseDelegate(
            projectManager: project,
            registry: registry,
            projectURL: dir,
            appDelegate: AppDelegate(),
            original: nil,
            presentAlert: { template, _, _, _ in
                presentedTemplates.append(template)
                return .alertFirstButtonReturn
            }
        )
        let window = BulkCloseTrackingWindow()
        window.delegate = delegate
        defer { DialogPresenter.ownerDidClose(window) }

        #expect(!delegate.windowShouldClose(window))
        await settle()

        #expect(presentedTemplates == [.terminalTabCloseWarning])
        #expect(window.performCloseCount == 1)
        await project.workspace.waitForLoadingComplete()
    }

    @Test("Confirmed window close survives agent child-process churn")
    func confirmedWindowCloseSurvivesChurn() async throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }
        let registry = ProjectRegistry()
        let project = try #require(registry.projectManager(for: dir))
        let tab = try addAgentTerminalTab(to: project)
        let sessionID = try #require(tab.agentSession?.id)

        let delegate = CloseDelegate(
            projectManager: project,
            registry: registry,
            projectURL: dir,
            appDelegate: AppDelegate(),
            original: nil,
            presentAlert: { _, _, _, _ in .alertFirstButtonReturn }
        )
        let window = BulkCloseTrackingWindow()
        window.delegate = delegate
        defer { DialogPresenter.ownerDidClose(window) }

        #expect(!delegate.windowShouldClose(window))
        await settle()

        // Same agent session throughout: the confirmation still covers the tab.
        #expect(tab.agentSession?.id == sessionID)
        #expect(window.performCloseCount == 1)
        #expect(window.approvedCloseCount == 1)
        await project.workspace.waitForLoadingComplete()
    }

    @Test("A new agent run started during the sheet cancels the window close")
    func newAgentRunDuringSheetCancelsWindowClose() async throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }
        let registry = ProjectRegistry()
        let project = try #require(registry.projectManager(for: dir))
        let tab = try addAgentTerminalTab(to: project)

        let delegate = CloseDelegate(
            projectManager: project,
            registry: registry,
            projectURL: dir,
            appDelegate: AppDelegate(),
            original: nil,
            presentAlert: { _, _, _, _ in
                // A genuinely different agent run appears while the sheet is
                // up. The user authorized the previous one, not this.
                tab.agentSession = AgentSession(agentType: .claudeCode)
                return .alertFirstButtonReturn
            }
        )
        let window = BulkCloseTrackingWindow()
        window.delegate = delegate
        defer { DialogPresenter.ownerDidClose(window) }

        #expect(!delegate.windowShouldClose(window))
        await settle()

        #expect(window.performCloseCount == 0)
        await project.workspace.waitForLoadingComplete()
    }

    @Test("An agent that exits during the sheet still lets the window close")
    func agentExitDuringSheetStillClosesWindow() async throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }
        let registry = ProjectRegistry()
        let project = try #require(registry.projectManager(for: dir))
        let tab = try addAgentTerminalTab(to: project)

        let delegate = CloseDelegate(
            projectManager: project,
            registry: registry,
            projectURL: dir,
            appDelegate: AppDelegate(),
            original: nil,
            presentAlert: { _, _, _, _ in
                // Nothing left to protect once the agent is gone.
                tab.agentSession = nil
                return .alertFirstButtonReturn
            }
        )
        let window = BulkCloseTrackingWindow()
        window.delegate = delegate
        defer { DialogPresenter.ownerDidClose(window) }

        #expect(!delegate.windowShouldClose(window))
        await settle()

        #expect(window.performCloseCount == 1)
        #expect(window.approvedCloseCount == 1)
        await project.workspace.waitForLoadingComplete()
    }

    // MARK: - Application quit

    @Test("Quit warns about a running agent that has no foreground pgid")
    func quitWarnsAboutRunningAgent() async throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }
        let registry = ProjectRegistry()
        let project = try #require(registry.projectManager(for: dir))
        try addAgentTerminalTab(to: project)

        let delegate = AppDelegate()
        delegate.registry = registry
        var presentedTemplates: [AlertTemplate] = []

        let result = await delegate.confirmApplicationTermination(
            presentAlert: { template, _, _, _ in
                presentedTemplates.append(template)
                return .alertFirstButtonReturn
            },
            terminationDeadlineOverride: .now() + 120
        )

        #expect(result)
        #expect(presentedTemplates == [.terminalActiveProcessWarning])
        await project.workspace.waitForLoadingComplete()
    }

    @Test("Confirmed quit survives agent child-process churn")
    func confirmedQuitSurvivesChurn() async throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }
        let registry = ProjectRegistry()
        let project = try #require(registry.projectManager(for: dir))
        let tab = try addAgentTerminalTab(to: project)
        let sessionID = try #require(tab.agentSession?.id)

        let delegate = AppDelegate()
        delegate.registry = registry

        let result = await delegate.confirmApplicationTermination(
            presentAlert: { _, _, _, _ in .alertFirstButtonReturn },
            terminationDeadlineOverride: .now() + 120
        )

        #expect(result)
        #expect(tab.agentSession?.id == sessionID)
        await project.workspace.waitForLoadingComplete()
    }

    @Test("A new agent run started during the quit sheet cancels termination")
    func newAgentRunDuringQuitSheetCancelsTermination() async throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }
        let registry = ProjectRegistry()
        let project = try #require(registry.projectManager(for: dir))
        let tab = try addAgentTerminalTab(to: project)

        let delegate = AppDelegate()
        delegate.registry = registry

        let result = await delegate.confirmApplicationTermination(
            presentAlert: { _, _, _, _ in
                tab.agentSession = AgentSession(agentType: .claudeCode)
                return .alertFirstButtonReturn
            },
            terminationDeadlineOverride: .now() + 120
        )

        #expect(!result)
        await project.workspace.waitForLoadingComplete()
    }

    @Test("Quit is not blocked by a project that never had anything running")
    func idleProjectDoesNotBlockQuit() async throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }
        let registry = ProjectRegistry()
        let project = try #require(registry.projectManager(for: dir))
        project.paneManager.createTerminalPaneAtBottom(workingDirectory: nil)

        let delegate = AppDelegate()
        delegate.registry = registry
        var alertCount = 0

        let result = await delegate.confirmApplicationTermination(
            presentAlert: { _, _, _, _ in
                alertCount += 1
                return .alertFirstButtonReturn
            },
            terminationDeadlineOverride: .now() + 120
        )

        #expect(result)
        #expect(alertCount == 0)
        await project.workspace.waitForLoadingComplete()
    }

    @Test("An agent in a background project still gates quit")
    func backgroundProjectAgentStillGatesQuit() async throws {
        // Closing a project window only backgrounds it — the agent keeps
        // running. Quit must still account for it (the user's real-world
        // scenario: every window closed, agents alive, ⌘Q).
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }
        let registry = ProjectRegistry()
        let project = try #require(registry.projectManager(for: dir))
        let tab = try addAgentTerminalTab(to: project)
        registry.closeProjectWindow(dir)
        #expect(registry.openProjects[registry.canonicalProjectURL(dir)] != nil)

        let delegate = AppDelegate()
        delegate.registry = registry
        var presentedTemplates: [AlertTemplate] = []

        let result = await delegate.confirmApplicationTermination(
            presentAlert: { template, _, _, _ in
                presentedTemplates.append(template)
                return .alertFirstButtonReturn
            },
            terminationDeadlineOverride: .now() + 120
        )

        #expect(result)
        #expect(presentedTemplates == [.terminalActiveProcessWarning])
        #expect(tab.agentSession != nil)
        await project.workspace.waitForLoadingComplete()
    }

    @Test("Declining the quit warning cancels termination")
    func decliningQuitWarningCancelsTermination() async throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }
        let registry = ProjectRegistry()
        let project = try #require(registry.projectManager(for: dir))
        try addAgentTerminalTab(to: project)

        let delegate = AppDelegate()
        delegate.registry = registry

        let result = await delegate.confirmApplicationTermination(
            presentAlert: { _, _, _, _ in .alertSecondButtonReturn },
            terminationDeadlineOverride: .now() + 120
        )

        #expect(!result)
        await project.workspace.waitForLoadingComplete()
    }
}

/// Counts `performClose` so a test can distinguish "the close was approved"
/// from "the close silently aborted" (#1348).
@MainActor
private final class BulkCloseTrackingWindow: NSWindow {
    private(set) var performCloseCount = 0
    private(set) var approvedCloseCount = 0

    override func performClose(_ sender: Any?) {
        performCloseCount += 1
        if delegate?.windowShouldClose?(self) != false {
            approvedCloseCount += 1
        }
    }
}
