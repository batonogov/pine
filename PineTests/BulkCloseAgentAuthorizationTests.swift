//
//  BulkCloseAgentAuthorizationTests.swift
//  PineTests
//
//  Regression coverage for the terminal lifecycle boundary established by
//  #1348 and #1406. Destructive terminal-tab/pane closes and application quit
//  authorize terminal work through `TerminalTabCloseAuthorization` (stable
//  agent-session identity). Closing a project window is not destructive: it
//  backgrounds the same ProjectManager, terminal tabs, and agent sessions.
//
//  The pre-#1348 mechanism snapshotted the volatile foreground pgid before
//  presenting the sheet and required the post-sheet snapshot to be a subset.
//  An agent tab has no foreground pgid of its own between child spawns, so
//  that snapshot was empty: the bulk paths never warned about a running
//  agent at all, and once a child did appear mid-sheet the subset check
//  failed and the confirmed close/quit aborted in silence.
//
//  The authorization tests below pin the destructive paths, while the window
//  tests pin the intentionally non-destructive background/reopen path.
//

import AppKit
import Foundation
import Testing
@testable import Pine

@Suite("Terminal Lifecycle Authorization (#1348, #1406)", .serialized)
@MainActor
struct BulkCloseAgentAuthorizationTests {

    // MARK: - Fixtures

    private func makeRegistry() -> ProjectRegistry {
        ProjectRegistry(agentTasks: AgentTaskRegistry(
            persistence: BulkCloseAgentTaskStore()
        ))
    }

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

    private func detectedSession(
        agentType: AgentType,
        processID: Int32,
        generation: UInt64
    ) -> AgentSession {
        let startedAt = Date().addingTimeInterval(1)
        let session = AgentSession(
            agentType: agentType,
            startedAt: startedAt
        )
        _ = session.bindProcessEvidence(AgentProcessEvidence(
            processIdentifier: processID,
            processGeneration: generation,
            startIdentifier: "generation-\(generation)",
            observedStartedAt: startedAt,
            startIsAuthoritative: true
        ))
        return session
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

    private func addDirtyTab(
        to projectManager: ProjectManager,
        in directory: URL
    ) throws -> URL {
        projectManager.primaryTabManager.autoSavePreferenceProvider = { false }
        let suite = "BulkCloseAgentAuthorizationTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let settings = EditorSettings(defaults: defaults)
        settings.insertFinalNewline = false
        settings.stripTrailingWhitespace = false
        settings.formatOnSave = false
        projectManager.primaryTabManager.editorSettings = settings
        let fileURL = directory.appendingPathComponent("dirty.swift")
        try "original".write(
            to: fileURL,
            atomically: true,
            encoding: .utf8
        )
        projectManager.primaryTabManager.openTab(url: fileURL)
        projectManager.primaryTabManager.updateContent("modified")
        return fileURL
    }

    // MARK: - Terminal authorization primitive

    @Test("Reused foreground PGID is a new authorization generation")
    func reusedForegroundPGIDIsRejected() async throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }
        let registry = makeRegistry()
        let project = try #require(registry.projectManager(for: dir))
        project.paneManager.createTerminalPaneAtBottom(workingDirectory: nil)
        let tab = try #require(project.terminal.allTerminalTabs.first)
        tab.foregroundProcessIDOverrideForTesting = 4_242
        tab.foregroundStartOverrideForTesting = TerminalProcessStartIdentity(
            processID: 4_242,
            seconds: 10,
            microseconds: 20
        )
        let authorization = TerminalTabCloseAuthorization.authorizing(
            tabs: [tab]
        )

        tab.foregroundStartOverrideForTesting = TerminalProcessStartIdentity(
            processID: 4_242,
            seconds: 11,
            microseconds: 20
        )

        #expect(!authorization.stillCovers([tab]))
        await project.workspace.waitForLoadingComplete()
    }

    @Test("Leaderless foreground group retains an exact live member witness")
    func leaderlessForegroundGroupIsAuthorizedByMember() async throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }
        let registry = makeRegistry()
        let project = try #require(registry.projectManager(for: dir))
        project.paneManager.createTerminalPaneAtBottom(workingDirectory: nil)
        let tab = try #require(project.terminal.allTerminalTabs.first)
        tab.foregroundProcessIDOverrideForTesting = 4_242
        let member = TerminalProcessStartIdentity(
            processID: 5_252,
            seconds: 10,
            microseconds: 20
        )
        tab.foregroundStartOverrideForTesting = member
        let authorization = TerminalTabCloseAuthorization.authorizing(
            tabs: [tab]
        )

        #expect(authorization.stillCovers([tab]))

        tab.foregroundStartOverrideForTesting = TerminalProcessStartIdentity(
            processID: member.processID,
            seconds: member.seconds + 1,
            microseconds: member.microseconds
        )
        #expect(!authorization.stillCovers([tab]))
        await project.workspace.waitForLoadingComplete()
    }

    @Test("Unavailable foreground member identity fails closed")
    func unavailableForegroundMemberIdentityFailsClosed() async throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }
        let registry = makeRegistry()
        let project = try #require(registry.projectManager(for: dir))
        project.paneManager.createTerminalPaneAtBottom(workingDirectory: nil)
        let tab = try #require(project.terminal.allTerminalTabs.first)
        tab.foregroundProcessIDOverrideForTesting = 4_242
        tab.foregroundStartOverrideForTesting = nil
        let authorization = TerminalTabCloseAuthorization.authorizing(
            tabs: [tab]
        )

        #expect(authorization.requiresConfirmation)
        #expect(!authorization.stillCovers([tab]))
        await project.workspace.waitForLoadingComplete()
    }

    @Test("Foreground transition accepts the exact settled Pine agent task")
    func foregroundTransitionAcceptsExactSettledAgent() async throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }
        let registry = makeRegistry()
        let project = try #require(registry.projectManager(for: dir))
        project.paneManager.createTerminalPaneAtBottom(workingDirectory: dir)
        let tab = try #require(project.terminal.allTerminalTabs.first)
        tab.foregroundProcessIDOverrideForTesting = 4_242
        tab.foregroundStartOverrideForTesting = TerminalProcessStartIdentity(
            processID: 4_242,
            seconds: 10,
            microseconds: 20
        )
        let gate = BulkCloseAgentLaunchGate()
        let launchTask = Task { @MainActor in
            await project.terminal.launchAgentCommandForTesting(
                "codex",
                descriptor: AgentDescriptor(
                    agentType: .codex,
                    launchExecutable: "codex"
                ),
                in: tab
            ) {
                await gate.waitForCompletion()
            }
        }
        try #require(await gate.waitUntilStarted())
        let terminalAuthorization = TerminalTabCloseAuthorization.authorizing(
            tabs: [tab]
        )
        let launchAuthorization = project.terminal
            .capturePineAgentLaunchAuthorization()

        gate.finish(true)
        guard case .reserved(let reservation) = await launchTask.value else {
            Issue.record("Pine launch was not reserved")
            return
        }
        let session = detectedSession(
            agentType: .codex,
            processID: 8_111,
            generation: 10
        )
        project.terminal.bridgeAgentSession(
            session,
            replacing: nil,
            in: tab,
            reservation: reservation
        )
        tab.agentSession = session
        let currentLaunchAuthorization = project.terminal
            .capturePineAgentLaunchAuthorization()

        #expect(terminalAuthorization.stillCovers(
            [tab],
            pineAgentLaunches: launchAuthorization,
            currentPineAgentLaunches: currentLaunchAuthorization
        ))
        await project.workspace.waitForLoadingComplete()
    }

    @Test("Foreground transition accepts the same manually launched agent")
    func foregroundTransitionAcceptsSameManualAgent() async throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }
        let registry = makeRegistry()
        let project = try #require(registry.projectManager(for: dir))
        project.paneManager.createTerminalPaneAtBottom(workingDirectory: dir)
        let tab = try #require(project.terminal.allTerminalTabs.first)
        let capturedStart = TerminalProcessStartIdentity(
            processID: 4_242,
            seconds: 10,
            microseconds: 20
        )
        tab.foregroundProcessIDOverrideForTesting = 4_242
        tab.foregroundStartOverrideForTesting = capturedStart
        let authorization = TerminalTabCloseAuthorization.authorizing(
            tabs: [tab]
        )

        tab.agentSession = detectedSession(
            agentType: .codex,
            processID: 4_242,
            generation: 10
        )

        #expect(authorization.stillCovers([tab]))

        tab.foregroundStartOverrideForTesting = TerminalProcessStartIdentity(
            processID: capturedStart.processID,
            seconds: capturedStart.seconds + 1,
            microseconds: capturedStart.microseconds
        )
        #expect(!authorization.stillCovers([tab]))
        await project.workspace.waitForLoadingComplete()
    }

    @Test("Foreground transition rejects an unrelated detected agent")
    func foregroundTransitionRejectsUnrelatedAgent() async throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }
        let registry = makeRegistry()
        let project = try #require(registry.projectManager(for: dir))
        project.paneManager.createTerminalPaneAtBottom(workingDirectory: dir)
        let tab = try #require(project.terminal.allTerminalTabs.first)
        tab.foregroundProcessIDOverrideForTesting = 4_242
        tab.foregroundStartOverrideForTesting = TerminalProcessStartIdentity(
            processID: 4_242,
            seconds: 10,
            microseconds: 20
        )
        let gate = BulkCloseAgentLaunchGate()
        let launchTask = Task { @MainActor in
            await project.terminal.launchAgentCommandForTesting(
                "codex",
                descriptor: AgentDescriptor(
                    agentType: .codex,
                    launchExecutable: "codex"
                ),
                in: tab
            ) {
                await gate.waitForCompletion()
            }
        }
        try #require(await gate.waitUntilStarted())
        let terminalAuthorization = TerminalTabCloseAuthorization.authorizing(
            tabs: [tab]
        )
        let launchAuthorization = project.terminal
            .capturePineAgentLaunchAuthorization()

        gate.finish(true)
        guard case .reserved(let reservation) = await launchTask.value else {
            Issue.record("Pine launch was not reserved")
            return
        }
        let launched = detectedSession(
            agentType: .codex,
            processID: 8_111,
            generation: 10
        )
        project.terminal.bridgeAgentSession(
            launched,
            replacing: nil,
            in: tab,
            reservation: reservation
        )
        launched.applyLiveness(.terminated)
        let unrelated = detectedSession(
            agentType: .claudeCode,
            processID: 8_222,
            generation: 11
        )
        project.terminal.bridgeAgentSession(
            unrelated,
            replacing: launched,
            in: tab
        )
        tab.agentSession = unrelated
        let currentLaunchAuthorization = project.terminal
            .capturePineAgentLaunchAuthorization()

        #expect(!terminalAuthorization.stillCovers(
            [tab],
            pineAgentLaunches: launchAuthorization,
            currentPineAgentLaunches: currentLaunchAuthorization
        ))
        await project.workspace.waitForLoadingComplete()
    }

    @Test("Settled launch authorization rejects same-task reservation replay")
    func settledLaunchRejectsSameTaskReservationReplay() async throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }
        let registry = makeRegistry()
        let project = try #require(registry.projectManager(for: dir))
        let pane = project.paneManager.createTerminalPaneAtBottom(
            workingDirectory: dir
        )
        let tab = try #require(
            project.paneManager.terminalState(for: pane)?.terminalTabs.first
        )
        let descriptor = AgentDescriptor(
            agentType: .codex,
            launchExecutable: "codex"
        )
        guard case .reserved(let firstReservation) = await project.terminal
                .launchAgentCommandForTesting(
                    "codex",
                    descriptor: descriptor,
                    in: tab,
                    acknowledgedWrite: { true }
                ) else {
            Issue.record("First launch was not reserved")
            return
        }
        let firstAuthorization = project.terminal
            .capturePineAgentLaunchAuthorization()
        let firstSession = detectedSession(
            agentType: .codex,
            processID: 8_111,
            generation: 10
        )
        project.terminal.bridgeAgentSession(
            firstSession,
            replacing: nil,
            in: tab,
            reservation: firstReservation
        )
        tab.agentSession = firstSession
        #expect(firstAuthorization.coversLaunch(
            in: tab.id,
            settledSessionID: firstSession.id,
            current: project.terminal.capturePineAgentLaunchAuthorization()
        ))

        firstSession.applyLiveness(.terminated)
        firstSession.recordLifecycleState(
            .done,
            accuracy: .processTerminationOnly
        )
        project.terminal.bridgeAgentSession(
            firstSession,
            replacing: firstSession,
            in: tab
        )
        guard case .reserved(let secondReservation) = project.terminal
                .prepareAgentResume(
                    taskID: firstReservation.taskID,
                    in: tab
                ) else {
            Issue.record("Second launch was not reserved")
            return
        }
        #expect(secondReservation != firstReservation)
        #expect(registry.agentTasks.armLaunch(secondReservation))
        let secondSession = detectedSession(
            agentType: .codex,
            processID: 8_222,
            generation: 11
        )
        project.terminal.bridgeAgentSession(
            secondSession,
            replacing: firstSession,
            in: tab,
            reservation: secondReservation
        )
        tab.agentSession = secondSession
        let current = project.terminal.capturePineAgentLaunchAuthorization()

        #expect(!firstAuthorization.stillCovers(current))
        #expect(!firstAuthorization.coversLaunch(
            in: tab.id,
            settledSessionID: secondSession.id,
            current: current
        ))
        await project.workspace.waitForLoadingComplete()
    }

    @Test("Pending Pine launch does not authorize an unrelated detected agent")
    func pendingLaunchRejectsUnrelatedDetectedAgent() async throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }
        let registry = makeRegistry()
        let project = try #require(registry.projectManager(for: dir))
        let pane = project.paneManager.createTerminalPaneAtBottom(
            workingDirectory: dir
        )
        let tab = try #require(
            project.paneManager.terminalState(for: pane)?.terminalTabs.first
        )
        let terminalAuthorization = TerminalTabCloseAuthorization.authorizing(
            tabs: [tab]
        )
        guard case .reserved = await project.terminal
                .launchAgentCommandForTesting(
                    "codex",
                    descriptor: AgentDescriptor(
                        agentType: .codex,
                        launchExecutable: "codex"
                    ),
                    in: tab,
                    acknowledgedWrite: { true }
                ) else {
            Issue.record("Pine launch was not reserved")
            return
        }
        let launchAuthorization = project.terminal
            .capturePineAgentLaunchAuthorization()
        let unrelated = detectedSession(
            agentType: .claudeCode,
            processID: 8_222,
            generation: 11
        )

        // The implicit bridge attempts to consume the pending Codex
        // reservation for this terminal, but the incompatible Claude session
        // must not inherit that authorization while the claim remains live.
        project.terminal.bridgeAgentSession(
            unrelated,
            replacing: nil,
            in: tab
        )
        tab.agentSession = unrelated
        let current = project.terminal.capturePineAgentLaunchAuthorization()

        #expect(current.requiresConfirmation)
        #expect(!terminalAuthorization.stillCovers(
            [tab],
            pineAgentLaunches: launchAuthorization,
            currentPineAgentLaunches: current
        ))
        await project.workspace.waitForLoadingComplete()
    }

    @Test("Stale agent session does not authorize a replacement foreground job")
    func staleAgentSessionRejectsReplacementForegroundJob() async throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }
        let registry = makeRegistry()
        let project = try #require(registry.projectManager(for: dir))
        let pane = project.paneManager.createTerminalPaneAtBottom(
            workingDirectory: dir
        )
        let tab = try #require(
            project.paneManager.terminalState(for: pane)?.terminalTabs.first
        )
        let startedAt = Date(timeIntervalSince1970: 10.000_020)
        let session = AgentSession(
            agentType: .codex,
            startedAt: startedAt
        )
        _ = session.bindProcessEvidence(AgentProcessEvidence(
            processIdentifier: 8_111,
            processGeneration: 10,
            startIdentifier: "generation-10",
            observedStartedAt: startedAt,
            startIsAuthoritative: true
        ))
        let processIdentity = TerminalProcessStartIdentity(
            processID: 8_111,
            seconds: 10,
            microseconds: 20
        )
        tab.agentSession = session
        tab.foregroundProcessIDOverrideForTesting = 8_111
        tab.agentProcessIdentityResolverForTesting = { _ in processIdentity }
        let authorization = TerminalTabCloseAuthorization.authorizing(
            tabs: [tab]
        )

        #expect(authorization.stillCovers([tab]))

        // Detection is frozen during the machine phase, so the old session
        // object can remain after its process exits. A new foreground job in
        // the same PTY is independent work and must fail closed.
        tab.agentProcessIdentityResolverForTesting = { _ in nil }
        tab.foregroundProcessIDOverrideForTesting = 9_999
        tab.foregroundStartOverrideForTesting = TerminalProcessStartIdentity(
            processID: 9_999,
            seconds: processIdentity.seconds + 1,
            microseconds: processIdentity.microseconds
        )

        #expect(!authorization.stillCovers([tab]))
        await project.workspace.waitForLoadingComplete()
    }

    // MARK: - Project window backgrounding

    @Test("Window close backgrounds a live agent without a terminal alert")
    func windowCloseBackgroundsLiveAgentWithoutAlert() async throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }
        let registry = makeRegistry()
        let project = try #require(registry.projectManager(for: dir))
        let tab = try addAgentTerminalTab(to: project)
        let session = try #require(tab.agentSession)
        #expect(!tab.isTerminated)

        var presentedTemplates: [AlertTemplate] = []
        let appDelegate = AppDelegate()
        let delegate = CloseDelegate(
            projectManager: project,
            registry: registry,
            projectURL: dir,
            appDelegate: appDelegate,
            original: nil,
            presentAlert: { template, _, _, _ in
                presentedTemplates.append(template)
                return .alertThirdButtonReturn
            }
        )
        let window = BulkCloseTrackingWindow()
        window.delegate = delegate
        defer { DialogPresenter.ownerDidClose(window) }

        #expect(!delegate.windowShouldClose(window))
        await settle()

        #expect(presentedTemplates.isEmpty)
        #expect(window.performCloseCount == 1)
        #expect(window.approvedCloseCount == 1)

        delegate.windowWillClose(Notification(
            name: NSWindow.willCloseNotification,
            object: window
        ))
        #expect(!registry.isWindowOpen(dir))
        #expect(!tab.isTerminated)
        #expect(tab.agentSession === session)

        let reopened = try #require(registry.projectManager(for: dir))
        #expect(reopened === project)
        #expect(reopened.terminal.allTerminalTabs.first === tab)
        #expect(!tab.isTerminated)
        #expect(tab.agentSession === session)
        #expect(registry.isWindowOpen(dir))
        await reopened.workspace.waitForLoadingComplete()
    }

    @Test("Window close backgrounds foreground work without a terminal alert")
    func windowCloseBackgroundsForegroundWorkWithoutAlert() async throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }
        let registry = makeRegistry()
        let project = try #require(registry.projectManager(for: dir))
        project.paneManager.createTerminalPaneAtBottom(workingDirectory: nil)
        let tab = try #require(project.terminal.allTerminalTabs.first)
        let startIdentity = TerminalProcessStartIdentity(
            processID: 4_242,
            seconds: 10,
            microseconds: 20
        )
        tab.foregroundProcessIDOverrideForTesting = 4_242
        tab.foregroundStartOverrideForTesting = startIdentity
        #expect(!tab.isTerminated)

        var presentedTemplates: [AlertTemplate] = []
        let appDelegate = AppDelegate()
        let delegate = CloseDelegate(
            projectManager: project,
            registry: registry,
            projectURL: dir,
            appDelegate: appDelegate,
            original: nil,
            presentAlert: { template, _, _, _ in
                presentedTemplates.append(template)
                return .alertThirdButtonReturn
            }
        )
        let window = BulkCloseTrackingWindow()
        window.delegate = delegate
        defer { DialogPresenter.ownerDidClose(window) }

        #expect(!delegate.windowShouldClose(window))
        await settle()

        #expect(presentedTemplates.isEmpty)
        #expect(window.performCloseCount == 1)
        #expect(window.approvedCloseCount == 1)

        delegate.windowWillClose(Notification(
            name: NSWindow.willCloseNotification,
            object: window
        ))
        #expect(!registry.isWindowOpen(dir))
        #expect(!tab.isTerminated)
        #expect(tab.foregroundProcessID == 4_242)
        #expect(tab.foregroundStartOverrideForTesting == startIdentity)

        let reopened = try #require(registry.projectManager(for: dir))
        #expect(reopened === project)
        #expect(reopened.terminal.allTerminalTabs.first === tab)
        #expect(!tab.isTerminated)
        #expect(tab.foregroundProcessID == 4_242)
        #expect(tab.foregroundStartOverrideForTesting == startIdentity)
        #expect(registry.isWindowOpen(dir))
        await reopened.workspace.waitForLoadingComplete()
    }

    @Test("Dirty window with a live agent presents only the unsaved alert")
    func dirtyWindowWithAgentPresentsOnlyUnsavedAlert() async throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }
        let registry = makeRegistry()
        let project = try #require(registry.projectManager(for: dir))
        let tab = try addAgentTerminalTab(to: project)
        let session = try #require(tab.agentSession)
        _ = try addDirtyTab(to: project, in: dir)

        var presentedTemplates: [AlertTemplate] = []
        let appDelegate = AppDelegate()
        let delegate = CloseDelegate(
            projectManager: project,
            registry: registry,
            projectURL: dir,
            appDelegate: appDelegate,
            original: nil,
            presentAlert: { template, _, _, _ in
                presentedTemplates.append(template)
                return template == .unsavedChangesBulk
                    ? .alertSecondButtonReturn
                    : .alertThirdButtonReturn
            }
        )
        let window = BulkCloseTrackingWindow()
        window.delegate = delegate
        defer { DialogPresenter.ownerDidClose(window) }

        #expect(!delegate.windowShouldClose(window))
        await settle()

        #expect(presentedTemplates == [.unsavedChangesBulk])
        #expect(window.performCloseCount == 1)
        #expect(window.approvedCloseCount == 1)
        #expect(tab.agentSession === session)
        #expect(!project.hasUnsavedChanges)
        await project.workspace.waitForLoadingComplete()
    }

    @Test("Saving a dirty window backgrounds its live agent without terminal alert")
    func savedDirtyWindowBackgroundsAgentWithoutTerminalAlert() async throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }
        let registry = makeRegistry()
        let project = try #require(registry.projectManager(for: dir))
        let tab = try addAgentTerminalTab(to: project)
        let session = try #require(tab.agentSession)
        let fileURL = try addDirtyTab(to: project, in: dir)

        var presentedTemplates: [AlertTemplate] = []
        let appDelegate = AppDelegate()
        let delegate = CloseDelegate(
            projectManager: project,
            registry: registry,
            projectURL: dir,
            appDelegate: appDelegate,
            original: nil,
            presentAlert: { template, _, _, _ in
                presentedTemplates.append(template)
                return template == .unsavedChangesBulk
                    ? .alertFirstButtonReturn
                    : .alertThirdButtonReturn
            }
        )
        let window = BulkCloseTrackingWindow()
        window.delegate = delegate
        defer { DialogPresenter.ownerDidClose(window) }

        #expect(!delegate.windowShouldClose(window))
        await settle()

        #expect(presentedTemplates == [.unsavedChangesBulk])
        #expect(window.performCloseCount == 1)
        #expect(window.approvedCloseCount == 1)
        #expect(!project.hasUnsavedChanges)
        let savedContent = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(savedContent == "modified")
        #expect(!tab.isTerminated)
        #expect(tab.agentSession === session)

        delegate.windowWillClose(Notification(
            name: NSWindow.willCloseNotification,
            object: window
        ))
        #expect(!registry.isWindowOpen(dir))
        let reopened = try #require(registry.projectManager(for: dir))
        #expect(reopened === project)
        #expect(reopened.terminal.allTerminalTabs.first === tab)
        #expect(!tab.isTerminated)
        #expect(tab.agentSession === session)
        await reopened.workspace.waitForLoadingComplete()
    }

    // MARK: - Application quit

    @Test("Hidden Quick Terminal foreground work gates application quit")
    func hiddenQuickTerminalForegroundWorkGatesQuit() async {
        let delegate = AppDelegate()
        delegate.registry = makeRegistry()
        let tab = delegate.quickTerminalCoordinator.paneState.addTab(
            workingDirectory: nil
        )
        tab.foregroundProcessIDOverrideForTesting = 8_111
        tab.foregroundStartOverrideForTesting = TerminalProcessStartIdentity(
            processID: 8_111,
            seconds: 10,
            microseconds: 20
        )
        var presented: [AlertTemplate] = []
        var summaryMessage: String?

        let result = await delegate.confirmApplicationTermination(
            presentAlert: { template, _, _, message in
                presented.append(template)
                if template == .applicationQuitSummary {
                    summaryMessage = message
                }
                return .alertSecondButtonReturn
            },
            terminationDeadlineOverride: .now() + 5
        )

        #expect(result)
        #expect(presented == [.applicationQuitSummary])
        #expect(summaryMessage == Strings.applicationQuitSummaryMessage(1))
    }

    @Test("Review asks separately before stopping Quick Terminal work")
    func reviewConfirmsQuickTerminalForegroundWork() async {
        let delegate = AppDelegate()
        delegate.registry = makeRegistry()
        let tab = delegate.quickTerminalCoordinator.paneState.addTab(
            workingDirectory: nil
        )
        tab.foregroundProcessIDOverrideForTesting = 8_111
        tab.foregroundStartOverrideForTesting = TerminalProcessStartIdentity(
            processID: 8_111,
            seconds: 10,
            microseconds: 20
        )
        var presented: [AlertTemplate] = []

        let result = await delegate.confirmApplicationTermination(
            presentAlert: { template, _, _, _ in
                presented.append(template)
                return .alertFirstButtonReturn
            },
            terminationDeadlineOverride: .now() + 5
        )

        #expect(result)
        #expect(
            presented == [
                .applicationQuitSummary,
                .terminalActiveProcessWarning,
            ]
        )
    }

    @Test("Quick Terminal job started during summary cancels quit")
    func quickTerminalJobStartedDuringSummaryCancelsQuit() async throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }
        let registry = makeRegistry()
        let project = try #require(registry.projectManager(for: dir))
        try addAgentTerminalTab(to: project)
        let delegate = AppDelegate()
        delegate.registry = registry
        let tab = delegate.quickTerminalCoordinator.paneState.addTab(
            workingDirectory: nil
        )
        var presented: [AlertTemplate] = []

        let result = await delegate.confirmApplicationTermination(
            presentAlert: { template, _, _, _ in
                presented.append(template)
                if template == .applicationQuitSummary {
                    tab.foregroundProcessIDOverrideForTesting = 8_222
                    tab.foregroundStartOverrideForTesting =
                        TerminalProcessStartIdentity(
                            processID: 8_222,
                            seconds: 11,
                            microseconds: 20
                        )
                    return .alertSecondButtonReturn
                }
                return .alertFirstButtonReturn
            },
            terminationDeadlineOverride: .now() + 5
        )

        #expect(!result)
        #expect(
            presented == [
                .applicationQuitSummary,
                .applicationQuitFailure,
            ]
        )
        await project.workspace.waitForLoadingComplete()
    }

    @Test("Quit summarizes agents from multiple projects in one alert")
    func quitSummarizesAgentsAcrossProjects() async throws {
        let firstDirectory = try makeTempDirectory()
        let secondDirectory = try makeTempDirectory()
        defer {
            cleanup(firstDirectory)
            cleanup(secondDirectory)
        }
        let registry = makeRegistry()
        let firstProject = try #require(
            registry.projectManager(for: firstDirectory)
        )
        let secondProject = try #require(
            registry.projectManager(for: secondDirectory)
        )
        try addAgentTerminalTab(to: firstProject)
        try addAgentTerminalTab(to: secondProject)

        let delegate = AppDelegate()
        delegate.registry = registry
        var presentedTemplates: [AlertTemplate] = []
        var summaryMessage: String?

        let result = await delegate.confirmApplicationTermination(
            presentAlert: { template, _, _, message in
                presentedTemplates.append(template)
                if template == .applicationQuitSummary {
                    summaryMessage = message
                }
                return .alertSecondButtonReturn
            },
            terminationDeadlineOverride: .now() + 120
        )

        #expect(result)
        #expect(presentedTemplates == [.applicationQuitSummary])
        #expect(summaryMessage == Strings.applicationQuitSummaryMessage(2))
        await firstProject.workspace.waitForLoadingComplete()
        await secondProject.workspace.waitForLoadingComplete()
    }

    @Test("Idle terminal becoming an agent during summary cancels quit")
    func idleTerminalBecomingAgentDuringSummaryCancelsQuit() async throws {
        let activeDirectory = try makeTempDirectory()
        let idleDirectory = try makeTempDirectory()
        defer {
            cleanup(activeDirectory)
            cleanup(idleDirectory)
        }
        let registry = makeRegistry()
        let activeProject = try #require(
            registry.projectManager(for: activeDirectory)
        )
        let idleProject = try #require(
            registry.projectManager(for: idleDirectory)
        )
        try addAgentTerminalTab(to: activeProject)
        idleProject.paneManager.createTerminalPaneAtBottom(
            workingDirectory: nil
        )
        let idleTab = try #require(
            idleProject.terminal.allTerminalTabs.first
        )
        let delegate = AppDelegate()
        delegate.registry = registry
        var presentedTemplates: [AlertTemplate] = []

        let result = await delegate.confirmApplicationTermination(
            presentAlert: { template, _, _, _ in
                presentedTemplates.append(template)
                if template == .applicationQuitSummary {
                    idleTab.agentSession = AgentSession(
                        agentType: .claudeCode
                    )
                    return .alertSecondButtonReturn
                }
                return .alertFirstButtonReturn
            },
            terminationDeadlineOverride: .now() + 120
        )

        #expect(!result)
        #expect(
            presentedTemplates == [
                .applicationQuitSummary,
                .applicationQuitFailure,
            ]
        )
        await activeProject.workspace.waitForLoadingComplete()
        await idleProject.workspace.waitForLoadingComplete()
    }

    @Test("Idle terminal accepts the exact Pine launch authorized by Quit")
    func idleTerminalAcceptsExactAuthorizedPineLaunch() async throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }
        let registry = makeRegistry()
        let project = try #require(registry.projectManager(for: dir))
        let pane = project.paneManager.createTerminalPaneAtBottom(
            workingDirectory: dir
        )
        let tab = try #require(
            project.paneManager.terminalState(for: pane)?.terminalTabs.first
        )
        #expect(tab.foregroundProcessID <= 0)
        let descriptor = AgentDescriptor(
            agentType: .codex,
            launchExecutable: "codex"
        )
        let gate = BulkCloseAgentLaunchGate()
        let launchTask = Task { @MainActor in
            await project.terminal.launchAgentCommandForTesting(
                "codex",
                descriptor: descriptor,
                in: tab
            ) {
                await gate.waitForCompletion()
            }
        }
        #expect(await gate.waitUntilStarted())
        let delegate = AppDelegate()
        delegate.registry = registry

        let result = await delegate.confirmApplicationTermination(
            presentAlert: { template, _, _, _ in
                #expect(template == .applicationQuitSummary)
                gate.finish(true)
                guard case .reserved = await launchTask.value else {
                    Issue.record("authorized Pine launch was not armed")
                    return .alertThirdButtonReturn
                }
                tab.foregroundProcessIDOverrideForTesting = 8_111
                return .alertSecondButtonReturn
            },
            terminationDeadlineOverride: .now() + 5
        )

        #expect(result)
        await project.workspace.waitForLoadingComplete()
    }

    @Test("Idle terminal rejects an unrelated new foreground process")
    func idleTerminalRejectsUnrelatedForegroundProcess() async throws {
        let activeDirectory = try makeTempDirectory()
        let idleDirectory = try makeTempDirectory()
        defer {
            cleanup(activeDirectory)
            cleanup(idleDirectory)
        }
        let registry = makeRegistry()
        let activeProject = try #require(
            registry.projectManager(for: activeDirectory)
        )
        let idleProject = try #require(
            registry.projectManager(for: idleDirectory)
        )
        try addAgentTerminalTab(to: activeProject)
        let pane = idleProject.paneManager.createTerminalPaneAtBottom(
            workingDirectory: idleDirectory
        )
        let idleTab = try #require(
            idleProject.paneManager.terminalState(for: pane)?.terminalTabs.first
        )
        let delegate = AppDelegate()
        delegate.registry = registry
        var presented: [AlertTemplate] = []

        let result = await delegate.confirmApplicationTermination(
            presentAlert: { template, _, _, _ in
                presented.append(template)
                if template == .applicationQuitSummary {
                    idleTab.foregroundProcessIDOverrideForTesting = 8_222
                    return .alertSecondButtonReturn
                }
                return .alertFirstButtonReturn
            },
            terminationDeadlineOverride: .now() + 5
        )

        #expect(!result)
        #expect(
            presented == [
                .applicationQuitSummary,
                .applicationQuitFailure,
            ]
        )
        await activeProject.workspace.waitForLoadingComplete()
        await idleProject.workspace.waitForLoadingComplete()
    }

    @Test("Confirmed quit survives agent child-process churn")
    func confirmedQuitSurvivesChurn() async throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }
        let registry = makeRegistry()
        let project = try #require(registry.projectManager(for: dir))
        let tab = try addAgentTerminalTab(to: project)
        let sessionID = try #require(tab.agentSession?.id)

        let delegate = AppDelegate()
        delegate.registry = registry

        let result = await delegate.confirmApplicationTermination(
            presentAlert: { _, _, _, _ in .alertSecondButtonReturn },
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
        let registry = makeRegistry()
        let project = try #require(registry.projectManager(for: dir))
        let tab = try addAgentTerminalTab(to: project)

        let delegate = AppDelegate()
        delegate.registry = registry

        var presentedTemplates: [AlertTemplate] = []
        let result = await delegate.confirmApplicationTermination(
            presentAlert: { template, _, _, _ in
                presentedTemplates.append(template)
                if template == .applicationQuitSummary {
                    tab.agentSession = AgentSession(agentType: .claudeCode)
                    return .alertSecondButtonReturn
                }
                return .alertFirstButtonReturn
            },
            terminationDeadlineOverride: .now() + 120
        )

        #expect(!result)
        #expect(
            presentedTemplates == [
                .applicationQuitSummary,
                .applicationQuitFailure,
            ]
        )
        await project.workspace.waitForLoadingComplete()
    }

    @Test("Quit is not blocked by a project that never had anything running")
    func idleProjectDoesNotBlockQuit() async throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }
        let registry = makeRegistry()
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
        let registry = makeRegistry()
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
                return .alertSecondButtonReturn
            },
            terminationDeadlineOverride: .now() + 120
        )

        #expect(result)
        #expect(presentedTemplates == [.applicationQuitSummary])
        #expect(tab.agentSession != nil)
        await project.workspace.waitForLoadingComplete()
    }

    @Test("Declining the quit warning cancels termination")
    func decliningQuitWarningCancelsTermination() async throws {
        let dir = try makeTempDirectory()
        defer { cleanup(dir) }
        let registry = makeRegistry()
        let project = try #require(registry.projectManager(for: dir))
        try addAgentTerminalTab(to: project)

        let delegate = AppDelegate()
        delegate.registry = registry

        let result = await delegate.confirmApplicationTermination(
            presentAlert: { _, _, _, _ in .alertThirdButtonReturn },
            terminationDeadlineOverride: .now() + 120
        )

        #expect(!result)
        await project.workspace.waitForLoadingComplete()
    }
}

private actor BulkCloseAgentTaskStore: AgentTaskPersisting {
    func load(
        project: AgentTaskProjectIdentity
    ) async -> AgentTaskMetadataLoadResult {
        AgentTaskMetadataLoadResult(status: .missing, tasks: [])
    }

    func save(
        tasks: [AgentTask],
        project: AgentTaskProjectIdentity,
        authorization: AgentTaskPublicationAuthorization?
    ) async -> AgentTaskMetadataSaveResult {
        .saved(taskCount: tasks.count)
    }
}

@MainActor
private final class BulkCloseAgentLaunchGate {
    private var started = false
    private var completion: Bool?

    func waitForCompletion() async -> Bool {
        started = true
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while completion == nil, clock.now < deadline {
            do {
                try await clock.sleep(for: .milliseconds(1))
            } catch {
                return false
            }
        }
        return completion ?? false
    }

    func waitUntilStarted() async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while !started, clock.now < deadline {
            do {
                try await clock.sleep(for: .milliseconds(1))
            } catch {
                return false
            }
        }
        return started
    }

    func finish(_ result: Bool) {
        completion = result
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
