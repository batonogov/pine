//
//  QuickTerminalAgentDetectionTests.swift
//  PineTests
//
//  Exact detection, ownership, routing, privacy, and quit coverage for #1420.
//

import AppKit
import Foundation
import Testing
@testable import Pine

nonisolated private final class QuickSnapshotRunCounter:
    @unchecked Sendable {
    private let lock = NSLock()
    private var storedCount = 0

    var count: Int {
        lock.withLock { storedCount }
    }

    func record() {
        lock.withLock { storedCount += 1 }
    }

    func recordRun() -> ProcessRunResult {
        lock.withLock { storedCount += 1 }
        return ProcessRunResult(
            stdout: "",
            stderr: "",
            exitCode: 0,
            timedOut: false
        )
    }
}

private actor QuickAgentScopeResolutionGate {
    private var didEnter = false
    private var isReleased = false
    private var continuation: CheckedContinuation<Void, Never>?

    func suspendUntilReleased() async {
        didEnter = true
        guard !isReleased else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilEntered() async {
        while !didEnter { await Task.yield() }
    }

    func release() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}

@Suite("Quick Terminal agent detection (#1420)", .serialized)
@MainActor
struct QuickTerminalAgentDetectionTests {
    @Test("Quick Terminal uses one shared poller subscription across lifecycle")
    func sharedPollerSubscriptionFollowsLifecycleExactlyOnce() async throws {
        let counter = QuickSnapshotRunCounter()
        let fixture = try QuickTerminalAgentFixture(
            processRunner: { _, _, _, _ in counter.recordRun() }
        )
        defer { fixture.cleanUp() }
        _ = try await fixture.start()

        #expect(fixture.registry.agentSnapshotSubscriberCountForTesting == 1)
        #expect(fixture.controller.isAgentDetectionSubscribedForTesting)
        fixture.registry.runAgentProcessSnapshotForTesting()
        #expect(counter.count == 1)
        #expect(
            fixture.controller.receivedAgentSnapshotCountForTesting == 1
        )

        fixture.controller.hide()
        fixture.controller.show()
        fixture.controller.show()
        #expect(fixture.registry.agentSnapshotSubscriberCountForTesting == 1)

        fixture.controller.freezeAgentTasksForTermination()
        fixture.controller.freezeAgentTasksForTermination()
        #expect(fixture.registry.agentSnapshotSubscriberCountForTesting == 0)
        #expect(!fixture.controller.isAgentDetectionSubscribedForTesting)
        fixture.registry.runAgentProcessSnapshotForTesting()
        #expect(counter.count == 2)
        #expect(
            fixture.controller.receivedAgentSnapshotCountForTesting == 1
        )

        fixture.controller.cancelAgentTaskTermination()
        fixture.controller.cancelAgentTaskTermination()
        #expect(fixture.registry.agentSnapshotSubscriberCountForTesting == 1)
        fixture.registry.runAgentProcessSnapshotForTesting()
        #expect(counter.count == 3)
        #expect(
            fixture.controller.receivedAgentSnapshotCountForTesting == 2
        )

        fixture.controller.shutdown()
        fixture.controller.shutdown()
        #expect(fixture.registry.agentSnapshotSubscriberCountForTesting == 0)
        fixture.registry.runAgentProcessSnapshotForTesting()
        #expect(counter.count == 4)
        #expect(
            fixture.controller.receivedAgentSnapshotCountForTesting == 2
        )
    }

    @Test("Async scope resolution is fenced by freeze and shutdown")
    func asyncScopeResolutionRespectsLifecycleFences() async throws {
        let freezeGate = QuickAgentScopeResolutionGate()
        let freezeCompletions = QuickSnapshotRunCounter()
        let frozenFixture = try QuickTerminalAgentFixture(
            agentScopeResolver: { registry, workingDirectory, surface in
                await freezeGate.suspendUntilReleased()
                let result = await registry.resolveQuickTerminalAgentScope(
                    workingDirectory: workingDirectory,
                    surface: surface
                )
                freezeCompletions.record()
                return result
            }
        )
        defer { frozenFixture.cleanUp() }
        frozenFixture.controller.show()
        await freezeGate.waitUntilEntered()
        #expect(!frozenFixture.controller.isAgentScopeReadyForTesting)
        #expect(
            frozenFixture.registry.agentSnapshotSubscriberCountForTesting == 0
        )

        frozenFixture.controller.freezeAgentTasksForTermination()
        await freezeGate.release()
        while freezeCompletions.count < 1 { await Task.yield() }
        #expect(!frozenFixture.controller.isAgentScopeReadyForTesting)
        #expect(
            frozenFixture.registry.agentSnapshotSubscriberCountForTesting == 0
        )

        frozenFixture.controller.cancelAgentTaskTermination()
        await frozenFixture.controller.waitForAgentScopeResolutionForTesting()
        #expect(frozenFixture.controller.isAgentScopeReadyForTesting)
        #expect(
            frozenFixture.registry.agentSnapshotSubscriberCountForTesting == 1
        )

        let shutdownGate = QuickAgentScopeResolutionGate()
        let shutdownCompletions = QuickSnapshotRunCounter()
        let shutdownFixture = try QuickTerminalAgentFixture(
            agentScopeResolver: { registry, workingDirectory, surface in
                await shutdownGate.suspendUntilReleased()
                let result = await registry.resolveQuickTerminalAgentScope(
                    workingDirectory: workingDirectory,
                    surface: surface
                )
                shutdownCompletions.record()
                return result
            }
        )
        defer { shutdownFixture.cleanUp() }
        shutdownFixture.controller.show()
        await shutdownGate.waitUntilEntered()
        shutdownFixture.controller.shutdown()
        await shutdownGate.release()
        while shutdownCompletions.count < 1 { await Task.yield() }
        #expect(!shutdownFixture.controller.isAgentScopeReadyForTesting)
        #expect(
            shutdownFixture.registry.agentSnapshotSubscriberCountForTesting
                == 0
        )
    }

    @Test("Pi, Claude, and Codex retain exact detected process generations")
    func firstPartyAgentsRetainExactProcessGeneration() async throws {
        let cases: [(String, AgentType)] = [
            ("pi", .pi),
            ("claude", .claudeCode),
            ("codex", .codex),
        ]

        for (index, testCase) in cases.enumerated() {
            let fixture = try QuickTerminalAgentFixture()
            defer { fixture.cleanUp() }
            let tab = try await fixture.start()
            let process = quickAgentProcess(
                pid: Int32(7_100 + index),
                parent: 7_000,
                group: Int32(7_100 + index),
                command: testCase.0,
                startedAt: TimeInterval(7_100 + index)
            )
            setQuickAgentIdentity(process, on: tab)
            setQuickForeground(process, on: tab)

            fixture.consume([process], sequence: 1)

            let session = try #require(tab.agentSession)
            let evidence = try #require(session.processEvidence)
            let taskID = try #require(
                fixture.registry.agentTasks.taskID(forSessionID: session.id)
            )
            let task = try #require(
                fixture.registry.agentTasks.task(for: taskID)
            )
            let run = try #require(task.runs.last)
            #expect(session.agentType == testCase.1)
            #expect(evidence.processGeneration == 1)
            #expect(run.process == evidence)
            #expect(run.process.processIdentifier == process.pid)
            #expect(run.process.startIdentifier == process.startIdentifier)
            #expect(run.process.observedStartedAt == process.preciseStartedAt)
            #expect(task.route.surface.isQuickTerminal)
            #expect(task.route.terminalID == tab.id)
            #expect(
                fixture.registry.agentTasks.isExactLiveOwner(
                    taskID: taskID,
                    terminalID: tab.id,
                    runID: session.id
                )
            )
            #expect(AgentTabBadge.userFacingState(for: session) == .idle)
        }
    }

    @Test("Surface identity rejects a project/Quick Terminal UUID collision")
    func routeSurfaceRejectsTerminalIDCollision() throws {
        let taskRegistry = AgentTaskRegistry(
            persistence: QuickTerminalAgentTaskStore()
        )
        let identity = AgentTaskProjectIdentity(
            canonicalProjectPath: "/tmp/PineCollision",
            canonicalWorktreePath: "/tmp/PineCollision"
        )
        let terminalID = UUID()
        let projectSession = quickDetectedSession(
            agentType: .claudeCode,
            processID: 7_201,
            generation: 1
        )
        let quickSession = quickDetectedSession(
            agentType: .codex,
            processID: 7_202,
            generation: 2
        )
        let projectRoute = AgentTaskRoute(
            surface: .projectWindow,
            paneID: terminalID,
            tabID: terminalID,
            terminalID: terminalID
        )
        let quickRoute = AgentTaskRoute(
            surface: .quickTerminalProject,
            paneID: terminalID,
            tabID: terminalID,
            terminalID: terminalID
        )
        taskRegistry.bridge(
            projectSession,
            replacing: nil,
            context: AgentTaskBridgeContext(
                project: identity,
                route: projectRoute,
                origin: .discoveredInTerminal
            )
        )
        taskRegistry.bridge(
            quickSession,
            replacing: nil,
            context: AgentTaskBridgeContext(
                project: identity,
                route: quickRoute,
                origin: .discoveredInTerminal
            )
        )

        let projectTaskID = try #require(
            taskRegistry.taskID(forSessionID: projectSession.id)
        )
        let quickTaskID = try #require(
            taskRegistry.taskID(forSessionID: quickSession.id)
        )
        #expect(projectTaskID != quickTaskID)
        #expect(taskRegistry.tasks.count == 2)
        #expect(taskRegistry.isExactLiveOwner(
            taskID: projectTaskID,
            terminalID: terminalID,
            runID: projectSession.id
        ))
        #expect(taskRegistry.isExactLiveOwner(
            taskID: quickTaskID,
            terminalID: terminalID,
            runID: quickSession.id
        ))

        taskRegistry.setWindowOpen(false, project: identity)
        #expect(
            taskRegistry.task(for: projectTaskID)?.route.availability
                == .background
        )
        #expect(
            taskRegistry.task(for: quickTaskID)?.route.availability
                == .available
        )
        taskRegistry.setWindowOpen(true, project: identity)
        #expect(
            taskRegistry.task(for: projectTaskID)?.route.availability
                == .available
        )
        #expect(
            taskRegistry.task(for: quickTaskID)?.route.availability
                == .available
        )

        taskRegistry.markTerminalClosed(
            terminalID: terminalID,
            project: identity,
            surface: .quickTerminalProject
        )

        #expect(
            taskRegistry.task(for: projectTaskID)?.route.availability
                == .available
        )
        #expect(
            taskRegistry.task(for: quickTaskID)?.route.availability
                == .missing
        )
    }

    @Test("Quick Terminal project scope is immutable across project switches")
    func projectScopeDoesNotFollowLaterProjectSwitches() async throws {
        let first = try makeQuickTerminalDirectory(name: "First")
        let second = try makeQuickTerminalDirectory(name: "Second")
        defer {
            removeQuickTerminalDirectory(first)
            removeQuickTerminalDirectory(second)
        }
        let fixture = try QuickTerminalAgentFixture(recentProjects: [first])
        defer { fixture.cleanUp() }
        let tab = try await fixture.start()
        fixture.registry.recentProjects = [second]
        fixture.controller.hide()
        fixture.controller.show()
        let process = quickAgentProcess(
            pid: 7_301,
            parent: 7_300,
            group: 7_301,
            command: "claude",
            startedAt: 7_301
        )
        setQuickAgentIdentity(process, on: tab)
        setQuickForeground(process, on: tab)
        fixture.consume([process], sequence: 1)

        let session = try #require(tab.agentSession)
        let taskID = try #require(
            fixture.registry.agentTasks.taskID(forSessionID: session.id)
        )
        let task = try #require(
            fixture.registry.agentTasks.task(for: taskID)
        )
        #expect(tab.workingDirectoryURL?.standardizedFileURL == first)
        #expect(task.route.surface == .quickTerminalProject)
        #expect(task.project.canonicalProjectPath == first.path)
        #expect(task.project.canonicalWorktreePath == first.path)
        #expect(task.project.canonicalProjectPath != second.path)
    }

    @Test("Standalone Inbox origin never projects the home path")
    func standaloneInboxOriginIsPrivacySafe() throws {
        let taskRegistry = AgentTaskRegistry(
            persistence: QuickTerminalAgentTaskStore()
        )
        let privatePath = NSHomeDirectory()
        let privateName = URL(fileURLWithPath: privatePath).lastPathComponent
        let project = AgentTaskProjectIdentity(
            canonicalProjectPath: privatePath,
            canonicalWorktreePath: privatePath
        )
        let session = quickDetectedSession(
            agentType: .pi,
            processID: 7_401,
            generation: 1
        )
        let terminalID = UUID()
        taskRegistry.bridge(
            session,
            replacing: nil,
            context: AgentTaskBridgeContext(
                project: project,
                route: AgentTaskRoute(
                    surface: .quickTerminalStandalone,
                    paneID: UUID(),
                    tabID: terminalID,
                    terminalID: terminalID
                ),
                presentationContext: AgentTaskPresentationContext(
                    terminalStableLabel: Strings.quickTerminalText()
                ),
                origin: .discoveredInTerminal
            )
        )

        let row = try #require(
            AgentInboxSnapshot(tasks: taskRegistry.tasks).rows.first
        )
        #expect(row.surface == .quickTerminalStandalone)
        #expect(row.projectPath.isEmpty)
        #expect(row.worktreePath.isEmpty)
        #expect(row.projectName == Strings.quickTerminalText())
        #expect(row.worktreeName == nil)
        #expect(row.terminalLabel == Strings.quickTerminalText())
        #expect(
            !AgentInboxView.accessibilityLabel(for: row)
                .contains(privatePath)
        )
        let task = try #require(taskRegistry.tasks.first)
        let dockTitle = AgentPresenceController.dockMenuAgentTitle(for: task)
        #expect(dockTitle.contains(Strings.quickTerminalText()))
        #expect(!dockTitle.contains(privatePath))
        #expect(!dockTitle.contains(privateName))
        let projectBacked = quickRecoveryTask(
            surface: .quickTerminalProject,
            lifecycle: .paused,
            privatePath: "/tmp/visible-project"
        )
        let projectOptions = AgentNotificationSettingsProjection
            .projectOptions(tasks: [task, projectBacked])
        #expect(projectOptions.map(\.path) == ["/tmp/visible-project"])
        #expect(!projectOptions.contains { $0.path == privatePath })
        #expect(!projectOptions.contains { $0.label == privateName })
    }

    @Test("Unverified recent project scope downgrades to standalone")
    func unverifiedRecentProjectScopeIsPrivacySafe() async throws {
        let project = try makeQuickTerminalDirectory(name: "Unverified")
        defer { removeQuickTerminalDirectory(project) }
        let fixture = try QuickTerminalAgentFixture(
            recentProjects: [project],
            proveRecentProjectIdentity: false
        )
        defer { fixture.cleanUp() }
        let tab = try await fixture.start()
        let process = quickAgentProcess(
            pid: 7_451,
            parent: 7_450,
            group: 7_451,
            command: "codex",
            startedAt: 7_451
        )
        setQuickAgentIdentity(process, on: tab)
        setQuickForeground(process, on: tab)
        fixture.consume([process], sequence: 1)

        let task = try #require(fixture.registry.agentTasks.tasks.first)
        #expect(task.route.surface == .quickTerminalStandalone)
        let row = try #require(
            AgentInboxSnapshot(tasks: [task]).rows.first
        )
        #expect(row.projectPath.isEmpty)
        #expect(row.worktreePath.isEmpty)
        #expect(row.projectName == Strings.quickTerminalText())
        #expect(!AgentPresenceController.dockMenuAgentTitle(for: task)
            .contains(project.lastPathComponent))
    }

    @Test("Quick task recovery never admits a project-window manager")
    func quickRecoveryFailsClosedBeforeProjectAdmission() async throws {
        let canonicalizationCounter = QuickSnapshotRunCounter()
        let taskRegistry = AgentTaskRegistry(
            persistence: QuickTerminalAgentTaskStore()
        )
        let registry = ProjectRegistry(
            agentTasks: taskRegistry,
            agentInboxProjectCanonicalizer: { url in
                canonicalizationCounter.record()
                return url
            },
            agentDetectionProcessRunner: { _, _, _, _ in
                ProcessRunResult(
                    stdout: "",
                    stderr: "",
                    exitCode: 0,
                    timedOut: false
                )
            },
            agentDetectionPollInterval: 3_600
        )
        let standalone = quickRecoveryTask(
            surface: .quickTerminalStandalone,
            lifecycle: .paused,
            privatePath: "/Users/recovery-private-home"
        )
        let projectBacked = quickRecoveryTask(
            surface: .quickTerminalProject,
            lifecycle: .completed,
            privatePath: "/tmp/recovery-private-worktree"
        )
        taskRegistry.setTasksForTesting([standalone, projectBacked])

        let snapshot = AgentInboxSnapshot(tasks: taskRegistry.tasks)
        #expect(snapshot.rows.count == 2)
        #expect(snapshot.rows.allSatisfy { !$0.canRecover })

        var openedProjectWindow = false
        for task in [standalone, projectBacked] {
            let result = await registry.recoverAgentTaskFromInbox(
                task.id,
                action: .startNewSession,
                openProjectWindow: { _ in openedProjectWindow = true },
                waitUntilPresented: { _ in true },
                activateApplication: { _ in }
            )
            #expect(result == .launchRejected)
        }
        #expect(!openedProjectWindow)
        #expect(registry.openProjects.isEmpty)
        #expect(canonicalizationCounter.count < 1)
    }

    @Test("Managed-worktree Quick scope survives reclaim and relaunch")
    func managedWorktreeRecentIdentitySurvivesReclaimAndRelaunch() async throws {
        let root = try makeQuickTerminalDirectory(name: "ManagedScope")
        defer { removeQuickTerminalDirectory(root) }
        let repository = root.appendingPathComponent(
            "Repository",
            isDirectory: true
        )
        let managedRoot = root.appendingPathComponent(
            "Managed",
            isDirectory: true
        )
        let worktreeRoot = managedRoot.appendingPathComponent(
            "feature-branch",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: managedRoot,
            withIntermediateDirectories: true
        )
        try makeQuickGitRepository(at: repository, seed: "repository-a")
        _ = try runQuickGit([
            "worktree", "add", "-b", "feature/quick-agent", "--",
            worktreeRoot.path,
        ], at: repository)
        _ = try runQuickGit(
            ["config", "core.logAllRefUpdates", "false"],
            at: repository
        )
        _ = try runQuickGit(
            ["reflog", "expire", "--expire=all", "--all"],
            at: repository
        )
        try? FileManager.default.removeItem(
            at: repository.appendingPathComponent(".git/logs")
        )
        let baseCommit = try runQuickGit(
            ["rev-parse", "HEAD"],
            at: repository
        )
        let managed = AgentManagedWorktree(
            taskID: UUID(),
            repositoryRoot: repository,
            managedRoot: managedRoot,
            worktreeRoot: worktreeRoot,
            branchName: "feature/quick-agent",
            baseCommit: baseCommit,
            repositoryProof: try await quickRepositoryProof(
                repository: repository,
                worktree: worktreeRoot
            )
        )
        let defaultsDomain = "QuickManagedIdentity-\(UUID().uuidString)"
        let settingsDomain = "QuickManagedSettings-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsDomain))
        let settingsDefaults = try #require(
            UserDefaults(suiteName: settingsDomain)
        )
        defaults.removePersistentDomain(forName: defaultsDomain)
        settingsDefaults.removePersistentDomain(forName: settingsDomain)
        defer {
            defaults.removePersistentDomain(forName: defaultsDomain)
            settingsDefaults.removePersistentDomain(forName: settingsDomain)
        }
        let noProcessSnapshot: ProcessRunner = { _, _, _, _ in
            ProcessRunResult(
                stdout: "",
                stderr: "",
                exitCode: 0,
                timedOut: false
            )
        }
        let registry = ProjectRegistry(
            defaults: defaults,
            agentTasks: AgentTaskRegistry(
                persistence: QuickTerminalAgentTaskStore()
            ),
            agentDetectionProcessRunner: noProcessSnapshot,
            agentDetectionPollInterval: 3_600
        )
        let original = try #require(
            await registry.projectManager(for: managed)
        )
        let canonicalWorktree = registry.canonicalProjectURL(worktreeRoot)
        registry.closeProjectWindow(worktreeRoot)
        registry.runBackgroundReclamationPassForTesting()
        #expect(registry.openProjects[canonicalWorktree] == nil)

        let reopened = try #require(
            await registry.projectManager(for: managed)
        )
        #expect(reopened !== original)
        registry.closeProjectWindow(worktreeRoot)
        registry.runBackgroundReclamationPassForTesting()
        #expect(registry.openProjects[canonicalWorktree] == nil)

        let settings = QuickTerminalSettings(
            defaults: settingsDefaults,
            notificationCenter: NotificationCenter()
        )
        settings.enabled = true
        settings.hideOnFocusLoss = false
        let firstController = QuickTerminalController(settings: settings)
        firstController.registry = registry
        registry.quickTerminalAgentRouter = firstController
        firstController.show()
        await firstController.waitForAgentScopeResolutionForTesting()
        #expect(firstController.isAgentScopeReadyForTesting)
        let firstTab = try #require(firstController.paneState.activeTab)
        let firstProcess = quickAgentProcess(
            pid: 7_801,
            parent: 7_800,
            group: 7_801,
            command: "codex",
            startedAt: 7_801
        )
        setQuickAgentIdentity(firstProcess, on: firstTab)
        setQuickForeground(firstProcess, on: firstTab)
        firstController.agentSnapshotConsumer.consumeAgentProcessSnapshot(
            [firstProcess],
            observation: quickObservation(sequence: 1)
        )
        let firstTask = try #require(registry.agentTasks.tasks.first)
        #expect(firstTask.route.surface == .quickTerminalProject)
        #expect(firstTask.project.canonicalProjectPath == repository.path)
        #expect(firstTask.project.canonicalWorktreePath == worktreeRoot.path)
        firstController.shutdown()

        // Repository proof is filesystem-instance identity only. Enabling,
        // expiring, and repopulating reflogs cannot invalidate it.
        _ = try runQuickGit(
            ["config", "core.logAllRefUpdates", "true"],
            at: repository
        )
        try Data("before expiry".utf8).write(
            to: repository.appendingPathComponent("later.txt"),
            options: .atomic
        )
        _ = try runQuickGit(["add", "--", "later.txt"], at: repository)
        _ = try runQuickGit(
            ["commit", "-m", "before reflog expiry"],
            at: repository
        )
        _ = try runQuickGit(
            ["reflog", "expire", "--expire=all", "--all"],
            at: repository
        )
        try Data("after expiry".utf8).write(
            to: repository.appendingPathComponent("after.txt"),
            options: .atomic
        )
        _ = try runQuickGit(["add", "--", "after.txt"], at: repository)
        _ = try runQuickGit(
            ["commit", "-m", "after reflog expiry"],
            at: repository
        )

        let relaunchedRegistry = ProjectRegistry(
            defaults: defaults,
            agentTasks: AgentTaskRegistry(
                persistence: QuickTerminalAgentTaskStore()
            ),
            agentDetectionProcessRunner: noProcessSnapshot,
            agentDetectionPollInterval: 3_600
        )
        #expect(relaunchedRegistry.recentProjects.first == canonicalWorktree)
        let relaunchedController = QuickTerminalController(settings: settings)
        defer { relaunchedController.shutdown() }
        relaunchedController.registry = relaunchedRegistry
        relaunchedRegistry.quickTerminalAgentRouter = relaunchedController
        relaunchedController.show()
        await relaunchedController.waitForAgentScopeResolutionForTesting()
        #expect(relaunchedController.isAgentScopeReadyForTesting)
        let relaunchedTab = try #require(
            relaunchedController.paneState.activeTab
        )
        let relaunchedProcess = quickAgentProcess(
            pid: 7_802,
            parent: 7_800,
            group: 7_802,
            command: "claude",
            startedAt: 7_802
        )
        setQuickAgentIdentity(relaunchedProcess, on: relaunchedTab)
        setQuickForeground(relaunchedProcess, on: relaunchedTab)
        relaunchedController.agentSnapshotConsumer
            .consumeAgentProcessSnapshot(
                [relaunchedProcess],
                observation: quickObservation(sequence: 2)
            )
        let relaunchedTask = try #require(
            relaunchedRegistry.agentTasks.tasks.first
        )
        #expect(relaunchedTask.route.surface == .quickTerminalProject)
        #expect(
            relaunchedTask.project.canonicalProjectPath == repository.path
        )
        #expect(
            relaunchedTask.project.canonicalWorktreePath == worktreeRoot.path
        )
    }

    @Test("Actual Recent flow reopens one retained exact worktree manager")
    func actualRecentFlowReopensRetainedExactManager() async throws {
        let fixture = try await makeQuickRecentManagedFixture(
            name: "RecentRetained"
        )
        defer { fixture.cleanUp() }
        let registry = ProjectRegistry(defaults: fixture.defaults)
        let original = try #require(
            await registry.projectManager(for: fixture.managed)
        )
        let canonical = registry.canonicalProjectURL(fixture.worktree)
        registry.closeProjectWindow(canonical)
        #expect(registry.backgroundProjects.contains(canonical))

        let delegate = AppDelegate()
        delegate.registry = registry
        delegate.openProjectWindow = nil
        var openedURL: URL?
        let didOpen = await delegate.openRecentProject(
            canonical,
            fallbackOpenProjectWindow: { openedURL = $0 }
        )

        #expect(didOpen)
        #expect(openedURL == canonical)
        #expect(registry.openProjects[canonical] === original)
        #expect(await registry.projectManager(for: fixture.managed) === original)
    }

    @Test("Actual Recent flow restores exact identity after reclaim and relaunch")
    func actualRecentFlowRestoresReclaimedExactIdentity() async throws {
        let fixture = try await makeQuickRecentManagedFixture(
            name: "RecentRelaunch"
        )
        defer { fixture.cleanUp() }
        let seed = ProjectRegistry(defaults: fixture.defaults)
        _ = try #require(await seed.projectManager(for: fixture.managed))
        let canonical = seed.canonicalProjectURL(fixture.worktree)
        seed.closeProjectWindow(canonical)
        seed.runBackgroundReclamationPassForTesting()
        #expect(seed.openProjects[canonical] == nil)

        let relaunched = ProjectRegistry(defaults: fixture.defaults)
        let delegate = AppDelegate()
        delegate.registry = relaunched
        delegate.openProjectWindow = nil
        var openedURL: URL?
        #expect(await delegate.openRecentProject(
            canonical,
            fallbackOpenProjectWindow: { openedURL = $0 }
        ))
        let restored = try #require(relaunched.openProjects[canonical])
        #expect(openedURL == canonical)
        #expect(
            await relaunched.projectManager(for: fixture.managed) === restored
        )
        let quickScope = try #require(
            await relaunched.resolveQuickTerminalAgentScope(
                workingDirectory: fixture.worktree,
                surface: .quickTerminalProject
            )
        )
        #expect(quickScope.surface == .quickTerminalProject)
        #expect(
            quickScope.project == AgentTaskProjectIdentity(
                canonicalProjectPath: fixture.repository.path,
                canonicalWorktreePath: fixture.worktree.path
            )
        )
    }

    @Test("Actual Recent flow rejects same-path replacement without losing proof")
    func actualRecentFlowRejectsReplacementAndRetainsProof() async throws {
        let fixture = try await makeQuickRecentManagedFixture(
            name: "RecentReplacement"
        )
        defer { fixture.cleanUp() }
        let seed = ProjectRegistry(defaults: fixture.defaults)
        _ = try #require(await seed.projectManager(for: fixture.managed))
        let canonical = seed.canonicalProjectURL(fixture.worktree)
        seed.closeProjectWindow(canonical)
        seed.runBackgroundReclamationPassForTesting()
        let relaunched = ProjectRegistry(defaults: fixture.defaults)

        let displacedRepository = fixture.root.appendingPathComponent(
            "Repository-A",
            isDirectory: true
        )
        let displacedWorktree = fixture.managedRoot.appendingPathComponent(
            "worktree-A",
            isDirectory: true
        )
        try FileManager.default.moveItem(
            at: fixture.worktree,
            to: displacedWorktree
        )
        try FileManager.default.moveItem(
            at: fixture.repository,
            to: displacedRepository
        )
        try makeQuickGitRepository(at: fixture.repository, seed: "replacement")
        _ = try runQuickGit([
            "worktree", "add", "-b", "feature/replacement", "--",
            fixture.worktree.path,
        ], at: fixture.repository)

        let delegate = AppDelegate()
        delegate.registry = relaunched
        delegate.openProjectWindow = nil
        var openedReplacement = false
        #expect(!(await delegate.openRecentProject(
            canonical,
            fallbackOpenProjectWindow: { _ in openedReplacement = true }
        )))
        #expect(!openedReplacement)
        #expect(relaunched.openProjects.isEmpty)

        try FileManager.default.removeItem(at: fixture.worktree)
        try FileManager.default.removeItem(at: fixture.repository)
        try FileManager.default.moveItem(
            at: displacedRepository,
            to: fixture.repository
        )
        try FileManager.default.moveItem(
            at: displacedWorktree,
            to: fixture.worktree
        )

        var openedOriginal: URL?
        #expect(await delegate.openRecentProject(
            canonical,
            fallbackOpenProjectWindow: { openedOriginal = $0 }
        ))
        #expect(openedOriginal == canonical)
        let scope = try #require(
            await relaunched.resolveQuickTerminalAgentScope(
                workingDirectory: fixture.worktree,
                surface: .quickTerminalProject
            )
        )
        #expect(scope.surface == .quickTerminalProject)
        #expect(scope.project.canonicalProjectPath == fixture.repository.path)
        #expect(scope.project.canonicalWorktreePath == fixture.worktree.path)
    }

    @Test("Reused worktree path cannot inherit a prior repository identity")
    func reusedWorktreePathDowngradesAfterRelaunch() async throws {
        let root = try makeQuickTerminalDirectory(name: "PathReuse")
        defer { removeQuickTerminalDirectory(root) }
        let repositoryA = root.appendingPathComponent(
            "Repository-A",
            isDirectory: true
        )
        let repositoryB = root.appendingPathComponent(
            "Repository-B",
            isDirectory: true
        )
        let managedRoot = root.appendingPathComponent(
            "Managed",
            isDirectory: true
        )
        let reusedWorktree = managedRoot.appendingPathComponent(
            "reused",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: managedRoot,
            withIntermediateDirectories: true
        )
        try makeQuickGitRepository(at: repositoryA, seed: "repository-a")
        try makeQuickGitRepository(at: repositoryB, seed: "repository-b")
        _ = try runQuickGit([
            "worktree", "add", "-b", "feature/from-a", "--",
            reusedWorktree.path,
        ], at: repositoryA)
        let baseCommitA = try runQuickGit(
            ["rev-parse", "HEAD"],
            at: repositoryA
        )

        let defaultsDomain = "QuickPathReuseIdentity-\(UUID().uuidString)"
        let settingsDomain = "QuickPathReuseSettings-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsDomain))
        let settingsDefaults = try #require(
            UserDefaults(suiteName: settingsDomain)
        )
        defaults.removePersistentDomain(forName: defaultsDomain)
        settingsDefaults.removePersistentDomain(forName: settingsDomain)
        defer {
            defaults.removePersistentDomain(forName: defaultsDomain)
            settingsDefaults.removePersistentDomain(forName: settingsDomain)
        }
        let noProcessSnapshot: ProcessRunner = { _, _, _, _ in
            ProcessRunResult(
                stdout: "",
                stderr: "",
                exitCode: 0,
                timedOut: false
            )
        }
        let firstRegistry = ProjectRegistry(
            defaults: defaults,
            agentTasks: AgentTaskRegistry(
                persistence: QuickTerminalAgentTaskStore()
            ),
            agentDetectionProcessRunner: noProcessSnapshot,
            agentDetectionPollInterval: 3_600
        )
        let managedA = AgentManagedWorktree(
            taskID: UUID(),
            repositoryRoot: repositoryA,
            managedRoot: managedRoot,
            worktreeRoot: reusedWorktree,
            branchName: "feature/from-a",
            baseCommit: baseCommitA,
            repositoryProof: try await quickRepositoryProof(
                repository: repositoryA,
                worktree: reusedWorktree
            )
        )
        _ = try #require(
            await firstRegistry.projectManager(for: managedA)
        )
        firstRegistry.closeProjectWindow(reusedWorktree)
        firstRegistry.runBackgroundReclamationPassForTesting()

        _ = try runQuickGit([
            "worktree", "remove", "--force", "--", reusedWorktree.path,
        ], at: repositoryA)
        _ = try runQuickGit([
            "worktree", "add", "-b", "feature/from-b", "--",
            reusedWorktree.path,
        ], at: repositoryB)

        let relaunchedRegistry = ProjectRegistry(
            defaults: defaults,
            agentTasks: AgentTaskRegistry(
                persistence: QuickTerminalAgentTaskStore()
            ),
            agentDetectionProcessRunner: noProcessSnapshot,
            agentDetectionPollInterval: 3_600
        )
        #expect(
            relaunchedRegistry.recentProjects.first
                == relaunchedRegistry.canonicalProjectURL(reusedWorktree)
        )
        let settings = QuickTerminalSettings(
            defaults: settingsDefaults,
            notificationCenter: NotificationCenter()
        )
        settings.enabled = true
        settings.hideOnFocusLoss = false
        let controller = QuickTerminalController(settings: settings)
        defer { controller.shutdown() }
        controller.registry = relaunchedRegistry
        relaunchedRegistry.quickTerminalAgentRouter = controller
        controller.show()
        await controller.waitForAgentScopeResolutionForTesting()
        #expect(controller.isAgentScopeReadyForTesting)
        let tab = try #require(controller.paneState.activeTab)
        let process = quickAgentProcess(
            pid: 7_851,
            parent: 7_850,
            group: 7_851,
            command: "codex",
            startedAt: 7_851
        )
        setQuickAgentIdentity(process, on: tab)
        setQuickForeground(process, on: tab)
        controller.agentSnapshotConsumer.consumeAgentProcessSnapshot(
            [process],
            observation: quickObservation(sequence: 1)
        )

        let task = try #require(relaunchedRegistry.agentTasks.tasks.first)
        #expect(task.route.surface == .quickTerminalStandalone)
        #expect(task.project.canonicalProjectPath == reusedWorktree.path)
        #expect(task.project.canonicalProjectPath != repositoryA.path)
        #expect(task.project.canonicalProjectPath != repositoryB.path)
        let row = try #require(
            AgentInboxSnapshot(tasks: [task]).rows.first
        )
        #expect(row.projectPath.isEmpty)
        #expect(row.worktreePath.isEmpty)
        #expect(row.projectName == Strings.quickTerminalText())
        let dockTitle = AgentPresenceController.dockMenuAgentTitle(for: task)
        #expect(!dockTitle.contains(repositoryA.lastPathComponent))
        #expect(!dockTitle.contains(repositoryB.lastPathComponent))
        #expect(!dockTitle.contains(reusedWorktree.lastPathComponent))
    }

    @Test("Same-path repository replacement cannot inherit recent identity")
    func samePathsRepositoryReplacementDowngradesAtRegistration() async throws {
        let root = try makeQuickTerminalDirectory(name: "ExactPathReuse")
        defer { removeQuickTerminalDirectory(root) }
        let repository = root.appendingPathComponent(
            "Repository",
            isDirectory: true
        )
        let managedRoot = root.appendingPathComponent(
            "Managed",
            isDirectory: true
        )
        let worktree = managedRoot.appendingPathComponent(
            "feature",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: managedRoot,
            withIntermediateDirectories: true
        )
        try makeQuickGitRepository(at: repository, seed: "repository-a")
        _ = try runQuickGit([
            "worktree", "add", "-b", "feature/from-a", "--",
            worktree.path,
        ], at: repository)
        let baseCommit = try runQuickGit(
            ["rev-parse", "HEAD"],
            at: repository
        )

        let defaultsDomain = "QuickExactPathReuse-\(UUID().uuidString)"
        let settingsDomain = "QuickExactPathSettings-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsDomain))
        let settingsDefaults = try #require(
            UserDefaults(suiteName: settingsDomain)
        )
        defaults.removePersistentDomain(forName: defaultsDomain)
        settingsDefaults.removePersistentDomain(forName: settingsDomain)
        defer {
            defaults.removePersistentDomain(forName: defaultsDomain)
            settingsDefaults.removePersistentDomain(forName: settingsDomain)
        }
        let noProcessSnapshot: ProcessRunner = { _, _, _, _ in
            ProcessRunResult(
                stdout: "",
                stderr: "",
                exitCode: 0,
                timedOut: false
            )
        }
        let firstRegistry = ProjectRegistry(
            defaults: defaults,
            agentTasks: AgentTaskRegistry(
                persistence: QuickTerminalAgentTaskStore()
            ),
            agentDetectionProcessRunner: noProcessSnapshot,
            agentDetectionPollInterval: 3_600
        )
        let managedA = AgentManagedWorktree(
            taskID: UUID(),
            repositoryRoot: repository,
            managedRoot: managedRoot,
            worktreeRoot: worktree,
            branchName: "feature/from-a",
            baseCommit: baseCommit,
            repositoryProof: try await quickRepositoryProof(
                repository: repository,
                worktree: worktree
            )
        )
        _ = try #require(
            await firstRegistry.projectManager(for: managedA)
        )
        firstRegistry.closeProjectWindow(worktree)
        firstRegistry.runBackgroundReclamationPassForTesting()

        // Decode A's persisted record first. Filesystem proof is deliberately
        // deferred until Quick Terminal registration; replacing both paths
        // here exercises that exact asynchronous validation boundary.
        let preloadedRegistry = ProjectRegistry(
            defaults: defaults,
            agentTasks: AgentTaskRegistry(
                persistence: QuickTerminalAgentTaskStore()
            ),
            agentDetectionProcessRunner: noProcessSnapshot,
            agentDetectionPollInterval: 3_600
        )
        #expect(
            preloadedRegistry.recentProjects.first
                == preloadedRegistry.canonicalProjectURL(worktree)
        )

        _ = try runQuickGit([
            "worktree", "remove", "--force", "--", worktree.path,
        ], at: repository)
        try FileManager.default.removeItem(at: repository)
        try makeQuickGitRepository(at: repository, seed: "repository-b")
        _ = try runQuickGit([
            "worktree", "add", "-b", "feature/from-b", "--",
            worktree.path,
        ], at: repository)

        // The managed token carries A's proof. Replacement before the
        // asynchronous admission check completes cannot admit B under A's
        // logical project/worktree identity.
        let staleAdmissionRegistry = ProjectRegistry(
            agentTasks: AgentTaskRegistry(
                persistence: QuickTerminalAgentTaskStore()
            ),
            agentDetectionProcessRunner: noProcessSnapshot,
            agentDetectionPollInterval: 3_600
        )
        let staleAdmission = await staleAdmissionRegistry.projectManager(
            for: managedA
        )
        #expect(staleAdmission == nil)
        #expect(staleAdmissionRegistry.openProjects.isEmpty)

        // Persisted Inbox metadata for A must not admit or present B after an
        // exact same-root replacement, even though every canonical string is
        // unchanged.
        let persistedRecoveryTask = quickProjectRecoveryTask(
            identity: AgentTaskProjectIdentity(
                canonicalProjectPath: repository.path,
                canonicalWorktreePath: worktree.path
            )
        )
        preloadedRegistry.agentTasks.setTasksForTesting([
            persistedRecoveryTask,
        ])
        var openedPersistedReplacement = false
        let staleRecovery = await preloadedRegistry
            .recoverAgentTaskFromInbox(
                persistedRecoveryTask.id,
                action: .startNewSession,
                openProjectWindow: { _ in
                    openedPersistedReplacement = true
                },
                waitUntilPresented: { _ in true },
                activateApplication: { _ in }
            )
        #expect(staleRecovery == .projectUnavailable)
        #expect(!openedPersistedReplacement)
        #expect(preloadedRegistry.openProjects.isEmpty)
        preloadedRegistry.agentTasks.setTasksForTesting([])

        let settings = QuickTerminalSettings(
            defaults: settingsDefaults,
            notificationCenter: NotificationCenter()
        )
        settings.enabled = true
        settings.hideOnFocusLoss = false
        let controller = QuickTerminalController(settings: settings)
        defer { controller.shutdown() }
        controller.registry = preloadedRegistry
        preloadedRegistry.quickTerminalAgentRouter = controller
        controller.show()
        await controller.waitForAgentScopeResolutionForTesting()
        #expect(controller.isAgentScopeReadyForTesting)
        let tab = try #require(controller.paneState.activeTab)
        let process = quickAgentProcess(
            pid: 7_861,
            parent: 7_860,
            group: 7_861,
            command: "claude",
            startedAt: 7_861
        )
        setQuickAgentIdentity(process, on: tab)
        setQuickForeground(process, on: tab)
        controller.agentSnapshotConsumer.consumeAgentProcessSnapshot(
            [process],
            observation: quickObservation(sequence: 1)
        )

        let task = try #require(preloadedRegistry.agentTasks.tasks.first)
        #expect(task.route.surface == .quickTerminalStandalone)
        #expect(task.project.canonicalProjectPath == worktree.path)
        #expect(task.project.canonicalWorktreePath == worktree.path)
        #expect(preloadedRegistry.openProjects.isEmpty)
    }

    @Test("Bounded Git control reads reject growth and replacement races")
    func boundedGitControlReadsRejectRaces() throws {
        #expect(
            ProjectRegistry.unsignedFilesystemIdentityForTesting(-1)
                == UInt64.max
        )
        let root = try makeQuickTerminalDirectory(name: "BoundedGitRead")
        defer { removeQuickTerminalDirectory(root) }
        let control = root.appendingPathComponent("control", isDirectory: false)
        let original = "gitdir: /private/tmp/repository\n"
        try Data(original.utf8).write(to: control)
        #expect(
            ProjectRegistry.boundedGitPathFileForTesting(
                control,
                beforeRead: {}
            )
                == "gitdir: /private/tmp/repository"
        )
        #expect(
            ProjectRegistry.filesystemIdentityMatchesForTesting(
                leftGeneration: 7,
                rightGeneration: 7
            )
        )
        #expect(
            !ProjectRegistry.filesystemIdentityMatchesForTesting(
                leftGeneration: 7,
                rightGeneration: 8
            )
        )

        let growingHandle = try FileHandle(forWritingTo: control)
        let growthResult = ProjectRegistry.boundedGitPathFileForTesting(control) {
            _ = try? growingHandle.seekToEnd()
            try? growingHandle.write(
                contentsOf: Data(repeating: 0x61, count: 5_000)
            )
        }
        try growingHandle.close()
        #expect(growthResult == nil)

        try Data(original.utf8).write(to: control)
        let replacementResult = ProjectRegistry.boundedGitPathFileForTesting(
            control
        ) {
            try? Data("gitdir: /private/tmp/replacement\n".utf8).write(
                to: control,
                options: .atomic
            )
        }
        #expect(replacementResult == nil)

        for valid in [
            "gitdir: /private/tmp/repository",
            "gitdir: /private/tmp/repository\n",
            "gitdir: /private/tmp/repository\r\n",
        ] {
            try Data(valid.utf8).write(to: control, options: .atomic)
            #expect(
                ProjectRegistry.boundedGitPathFileForTesting(
                    control,
                    beforeRead: {}
                ) == "gitdir: /private/tmp/repository"
            )
        }
        for invalid in [
            "\ngitdir: /private/tmp/repository",
            "gitdir: /private/tmp/repository\n\n",
            "gitdir: /private/tmp/repository\r",
            "gitdir: /private/tmp/repository\r\n\n",
            "gitdir: /private/tmp/repository\u{0}",
        ] {
            try Data(invalid.utf8).write(to: control, options: .atomic)
            #expect(
                ProjectRegistry.boundedGitPathFileForTesting(
                    control,
                    beforeRead: {}
                ) == nil
            )
        }
    }

    @Test("Repository proof binds every Git control-graph edge")
    func repositoryProofRejectsPostResolutionGraphReplacement() async throws {
        let root = try makeQuickTerminalDirectory(name: "GraphBinding")
        defer { removeQuickTerminalDirectory(root) }
        let repository = root.appendingPathComponent(
            "Repository",
            isDirectory: true
        )
        let worktree = root.appendingPathComponent(
            "Worktree",
            isDirectory: true
        )
        try makeQuickGitRepository(at: repository, seed: "graph-a")
        _ = try runQuickGit([
            "worktree", "add", "-b", "feature/graph", "--", worktree.path,
        ], at: repository)
        let identity = AgentTaskProjectIdentity(
            canonicalProjectPath: repository.path,
            canonicalWorktreePath: worktree.path
        )
        let worktreeControl = worktree.appendingPathComponent(".git")
        let originalControl = try Data(contentsOf: worktreeControl)
        let switchedControlProof = await Task.detached(priority: .utility) {
            RecentAgentTaskFilesystemValidator.repositoryProof(
                for: identity,
                afterGraphResolution: {
                    try? originalControl.write(
                        to: worktreeControl,
                        options: .atomic
                    )
                }
            )
        }.value
        #expect(switchedControlProof == nil)

        // Recreate the linked-worktree control graph, then create a previously
        // absent primary commondir immediately after graph resolution. The
        // descriptor-relative ENOENT witness must reject that semantic edge.
        try originalControl.write(to: worktreeControl, options: .atomic)
        let primaryCommonControl = repository
            .appendingPathComponent(".git", isDirectory: true)
            .appendingPathComponent("commondir")
        let createdCommonDirProof = await Task.detached(priority: .utility) {
            RecentAgentTaskFilesystemValidator.repositoryProof(
                for: identity,
                afterGraphResolution: {
                    try? Data(".\n".utf8).write(
                        to: primaryCommonControl,
                        options: .atomic
                    )
                }
            )
        }.value
        #expect(createdCommonDirProof == nil)
    }

    @Test("Repository proof rejects an intermediate path retarget")
    func repositoryProofRejectsIntermediateSymlinkRetarget() async throws {
        let root = try makeQuickTerminalDirectory(name: "GraphIntermediate")
        defer { removeQuickTerminalDirectory(root) }
        let liveParent = root.appendingPathComponent("Live", isDirectory: true)
        let replacementParent = root.appendingPathComponent(
            "Replacement",
            isDirectory: true
        )
        let repository = liveParent.appendingPathComponent(
            "Repository",
            isDirectory: true
        )
        let worktree = liveParent.appendingPathComponent(
            "Worktree",
            isDirectory: true
        )
        try makeQuickGitRepository(at: repository, seed: "intermediate-a")
        _ = try runQuickGit([
            "worktree", "add", "-b", "feature/intermediate", "--",
            worktree.path,
        ], at: repository)
        try FileManager.default.createDirectory(
            at: replacementParent,
            withIntermediateDirectories: true
        )
        let identity = AgentTaskProjectIdentity(
            canonicalProjectPath: repository.path,
            canonicalWorktreePath: worktree.path
        )
        let displaced = root.appendingPathComponent(
            "Displaced",
            isDirectory: true
        )
        let proof = await Task.detached(priority: .utility) {
            RecentAgentTaskFilesystemValidator.repositoryProof(
                for: identity,
                afterGraphResolution: {
                    try? FileManager.default.moveItem(
                        at: liveParent,
                        to: displaced
                    )
                    try? FileManager.default.createSymbolicLink(
                        at: liveParent,
                        withDestinationURL: replacementParent
                    )
                }
            )
        }.value
        #expect(proof == nil)
    }

    @Test("Same repository worktree replacement loses every old authority")
    func sameRepositoryWorktreeReplacementFailsClosedEverywhere() async throws {
        let root = try makeQuickTerminalDirectory(name: "SameRepoWorktree")
        defer { removeQuickTerminalDirectory(root) }
        let repository = root.appendingPathComponent(
            "Repository",
            isDirectory: true
        )
        let managedRoot = root.appendingPathComponent(
            "Managed",
            isDirectory: true
        )
        let worktree = managedRoot.appendingPathComponent(
            "feature",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: managedRoot,
            withIntermediateDirectories: true
        )
        try makeQuickGitRepository(at: repository, seed: "same-repo")
        _ = try runQuickGit([
            "worktree", "add", "-b", "feature/original", "--",
            worktree.path,
        ], at: repository)
        let proof = try await quickRepositoryProof(
            repository: repository,
            worktree: worktree
        )
        let managed = AgentManagedWorktree(
            taskID: UUID(),
            repositoryRoot: repository,
            managedRoot: managedRoot,
            worktreeRoot: worktree,
            branchName: "feature/original",
            baseCommit: try runQuickGit(["rev-parse", "HEAD"], at: repository),
            repositoryProof: proof
        )
        let defaultsDomain = "SameRepoWorktree-\(UUID().uuidString)"
        let settingsDomain = "SameRepoWorktreeSettings-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsDomain))
        let settingsDefaults = try #require(
            UserDefaults(suiteName: settingsDomain)
        )
        defaults.removePersistentDomain(forName: defaultsDomain)
        settingsDefaults.removePersistentDomain(forName: settingsDomain)
        defer {
            defaults.removePersistentDomain(forName: defaultsDomain)
            settingsDefaults.removePersistentDomain(forName: settingsDomain)
        }
        let tasks = AgentTaskRegistry(persistence: QuickTerminalAgentTaskStore())
        let registry = ProjectRegistry(defaults: defaults, agentTasks: tasks)
        let retained = try #require(await registry.projectManager(for: managed))
        let canonicalWorktree = registry.canonicalProjectURL(worktree)
        registry.closeProjectWindow(worktree)
        #expect(registry.openProjects[canonicalWorktree] === retained)
        #expect(registry.backgroundProjects.contains(canonicalWorktree))

        let recoveryTask = quickProjectRecoveryTask(
            identity: AgentTaskProjectIdentity(
                canonicalProjectPath: repository.path,
                canonicalWorktreePath: worktree.path
            )
        )
        tasks.setTasksForTesting([recoveryTask])
        var opened = false
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.orderFront(nil)
        defer {
            retained.unbindDialogOwnerWindow(window)
            window.orderOut(nil)
        }
        #expect(await registry.recoverAgentTaskFromInbox(
            recoveryTask.id,
            action: .startNewSession,
            openProjectWindow: { _ in opened = true },
            waitUntilPresented: { manager in
                manager.bindDialogOwnerWindow(window)
                _ = try? runQuickGit([
                    "worktree", "remove", "--force", "--", worktree.path,
                ], at: repository)
                _ = try? runQuickGit([
                    "worktree", "add", "-b", "feature/replacement", "--",
                    worktree.path,
                ], at: repository)
                return true
            },
            activateApplication: { _ in }
        ) == .projectUnavailable)
        #expect(opened)
        #expect(registry.openProjects[canonicalWorktree] === retained)
        #expect(await registry.projectManager(for: managed) == nil)

        let relaunched = ProjectRegistry(defaults: defaults)
        let settings = QuickTerminalSettings(
            defaults: settingsDefaults,
            notificationCenter: NotificationCenter()
        )
        settings.enabled = true
        settings.hideOnFocusLoss = false
        let controller = QuickTerminalController(settings: settings)
        defer { controller.shutdown() }
        controller.registry = relaunched
        relaunched.quickTerminalAgentRouter = controller
        controller.show()
        await controller.waitForAgentScopeResolutionForTesting()
        #expect(controller.isAgentScopeReadyForTesting)
        #expect(
            controller.agentScopeSurfaceForTesting
                == .quickTerminalStandalone
        )
    }

    @Test("Async workspace load rejects a replaced worktree")
    func workspaceLoadRevalidatesAdmittedInstance() async throws {
        let root = try makeQuickTerminalDirectory(name: "WorkspaceGap")
        defer { removeQuickTerminalDirectory(root) }
        let repository = root.appendingPathComponent("Repository")
        let managedRoot = root.appendingPathComponent("Managed")
        let worktree = managedRoot.appendingPathComponent("feature")
        try FileManager.default.createDirectory(
            at: managedRoot,
            withIntermediateDirectories: true
        )
        try makeQuickGitRepository(at: repository, seed: "workspace-gap")
        _ = try runQuickGit([
            "worktree", "add", "-b", "feature/workspace-gap", "--",
            worktree.path,
        ], at: repository)
        let managed = AgentManagedWorktree(
            taskID: UUID(),
            repositoryRoot: repository,
            managedRoot: managedRoot,
            worktreeRoot: worktree,
            branchName: "feature/workspace-gap",
            baseCommit: try runQuickGit(["rev-parse", "HEAD"], at: repository),
            repositoryProof: try await quickRepositoryProof(
                repository: repository,
                worktree: worktree
            )
        )
        let gate = QuickAgentScopeResolutionGate()
        let registry = ProjectRegistry(agentTaskWorkspaceValidationSeam: {
            await gate.suspendUntilReleased()
        })
        let manager = try #require(await registry.projectManager(for: managed))
        await gate.waitUntilEntered()
        _ = try runQuickGit([
            "worktree", "remove", "--force", "--", worktree.path,
        ], at: repository)
        _ = try runQuickGit([
            "worktree", "add", "-b", "feature/workspace-replacement", "--",
            worktree.path,
        ], at: repository)
        await gate.release()
        await manager.workspace.waitForLoadingComplete()
        #expect(manager.workspace.isSuspended)
        #expect(!manager.workspace.hasActiveFileWatcherForTesting)
        #expect(manager.workspace.rootNodes.isEmpty)
    }

    @Test("Lazy PTY start revalidates after its final suspension")
    func lazyPTYStartRejectsReplacedWorktree() async throws {
        let root = try makeQuickTerminalDirectory(name: "PTYGap")
        defer { removeQuickTerminalDirectory(root) }
        let repository = root.appendingPathComponent("Repository")
        let managedRoot = root.appendingPathComponent("Managed")
        let worktree = managedRoot.appendingPathComponent("feature")
        try FileManager.default.createDirectory(
            at: managedRoot,
            withIntermediateDirectories: true
        )
        try makeQuickGitRepository(at: repository, seed: "pty-gap")
        _ = try runQuickGit([
            "worktree", "add", "-b", "feature/pty-gap", "--",
            worktree.path,
        ], at: repository)
        let managed = AgentManagedWorktree(
            taskID: UUID(),
            repositoryRoot: repository,
            managedRoot: managedRoot,
            worktreeRoot: worktree,
            branchName: "feature/pty-gap",
            baseCommit: try runQuickGit(["rev-parse", "HEAD"], at: repository),
            repositoryProof: try await quickRepositoryProof(
                repository: repository,
                worktree: worktree
            )
        )
        let registry = ProjectRegistry()
        let manager = try #require(await registry.projectManager(for: managed))
        await manager.workspace.waitForLoadingComplete()
        let pane = manager.paneManager.createTerminalPaneAtBottom(
            workingDirectory: worktree
        )
        let tab = try #require(
            manager.paneManager.terminalState(for: pane)?.activeTab
        )
        tab.terminalView.frame = NSRect(x: 0, y: 0, width: 640, height: 320)
        let gate = QuickAgentScopeResolutionGate()
        tab.validationCommitSeamForTesting = {
            await gate.suspendUntilReleased()
        }
        tab.startIfNeeded()
        await gate.waitUntilEntered()
        _ = try runQuickGit([
            "worktree", "remove", "--force", "--", worktree.path,
        ], at: repository)
        _ = try runQuickGit([
            "worktree", "add", "-b", "feature/pty-replacement", "--",
            worktree.path,
        ], at: repository)
        await gate.release()
        for _ in 0..<200
        where tab.isStartValidationPendingForTesting {
            try? await Task.sleep(for: .milliseconds(2))
        }
        #expect(!tab.isStartValidationPendingForTesting)
        #expect(!tab.isProcessRunning)
    }

    @Test("Retained background worktree refuses same-path replacement")
    func retainedBackgroundManagerValidatesRepositoryInstance() async throws {
        let root = try makeQuickTerminalDirectory(name: "RetainedReplacement")
        defer { removeQuickTerminalDirectory(root) }
        let repository = root.appendingPathComponent(
            "Repository",
            isDirectory: true
        )
        let managedRoot = root.appendingPathComponent(
            "Managed",
            isDirectory: true
        )
        let worktree = managedRoot.appendingPathComponent(
            "feature",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: managedRoot,
            withIntermediateDirectories: true
        )
        try makeQuickGitRepository(at: repository, seed: "retained-a")
        _ = try runQuickGit([
            "worktree", "add", "-b", "feature/retained-a", "--",
            worktree.path,
        ], at: repository)
        let managed = AgentManagedWorktree(
            taskID: UUID(),
            repositoryRoot: repository,
            managedRoot: managedRoot,
            worktreeRoot: worktree,
            branchName: "feature/retained-a",
            baseCommit: try runQuickGit(["rev-parse", "HEAD"], at: repository),
            repositoryProof: try await quickRepositoryProof(
                repository: repository,
                worktree: worktree
            )
        )
        let taskRegistry = AgentTaskRegistry(
            persistence: QuickTerminalAgentTaskStore()
        )
        let registry = ProjectRegistry(agentTasks: taskRegistry)
        let retained = try #require(await registry.projectManager(for: managed))
        registry.closeProjectWindow(worktree)
        let canonicalWorktree = registry.canonicalProjectURL(worktree)
        #expect(registry.openProjects[canonicalWorktree] === retained)
        #expect(registry.backgroundProjects.contains(canonicalWorktree))

        _ = try runQuickGit([
            "worktree", "remove", "--force", "--", worktree.path,
        ], at: repository)
        try FileManager.default.removeItem(at: repository)
        try makeQuickGitRepository(at: repository, seed: "retained-b")
        _ = try runQuickGit([
            "worktree", "add", "-b", "feature/retained-b", "--",
            worktree.path,
        ], at: repository)

        let recoveryTask = quickProjectRecoveryTask(
            identity: AgentTaskProjectIdentity(
                canonicalProjectPath: repository.path,
                canonicalWorktreePath: worktree.path
            )
        )
        taskRegistry.setTasksForTesting([recoveryTask])
        var openedReplacement = false
        let result = await registry.recoverAgentTaskFromInbox(
            recoveryTask.id,
            action: .startNewSession,
            openProjectWindow: { _ in openedReplacement = true },
            waitUntilPresented: { _ in true },
            activateApplication: { _ in }
        )
        #expect(result == .projectUnavailable)
        #expect(!openedReplacement)
        #expect(registry.openProjects[canonicalWorktree] === retained)
        #expect(registry.backgroundProjects.contains(canonicalWorktree))
    }

    @Test("Managed admission revalidates after detached suspension")
    func managedAdmissionRejectsReplacementBeforeCommit() async throws {
        let root = try makeQuickTerminalDirectory(name: "ManagedCommitGap")
        defer { removeQuickTerminalDirectory(root) }
        let repository = root.appendingPathComponent(
            "Repository",
            isDirectory: true
        )
        let managedRoot = root.appendingPathComponent(
            "Managed",
            isDirectory: true
        )
        let worktree = managedRoot.appendingPathComponent(
            "feature",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: managedRoot,
            withIntermediateDirectories: true
        )
        try makeQuickGitRepository(at: repository, seed: "managed-gap")
        _ = try runQuickGit([
            "worktree", "add", "-b", "feature/managed-gap", "--",
            worktree.path,
        ], at: repository)
        let managed = AgentManagedWorktree(
            taskID: UUID(),
            repositoryRoot: repository,
            managedRoot: managedRoot,
            worktreeRoot: worktree,
            branchName: "feature/managed-gap",
            baseCommit: try runQuickGit(["rev-parse", "HEAD"], at: repository),
            repositoryProof: try await quickRepositoryProof(
                repository: repository,
                worktree: worktree
            )
        )
        let commitGate = QuickAgentScopeResolutionGate()
        let registry = ProjectRegistry(
            agentTaskFilesystemValidationCommitSeam: {
                await commitGate.suspendUntilReleased()
            }
        )
        let admission = Task { @MainActor in
            await registry.projectManager(for: managed)
        }
        await commitGate.waitUntilEntered()
        let displaced = managedRoot.appendingPathComponent(
            "displaced",
            isDirectory: true
        )
        try FileManager.default.moveItem(at: worktree, to: displaced)
        try FileManager.default.createDirectory(
            at: worktree,
            withIntermediateDirectories: false
        )
        await commitGate.release()
        #expect(await admission.value == nil)
        #expect(registry.openProjects.isEmpty)
    }

    @Test("Quick scope revalidates before registration and subscription")
    func quickScopeRejectsReplacementBeforeCommit() async throws {
        let root = try makeQuickTerminalDirectory(name: "QuickCommitGap")
        defer { removeQuickTerminalDirectory(root) }
        let repository = root.appendingPathComponent(
            "Repository",
            isDirectory: true
        )
        let managedRoot = root.appendingPathComponent(
            "Managed",
            isDirectory: true
        )
        let worktree = managedRoot.appendingPathComponent(
            "feature",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: managedRoot,
            withIntermediateDirectories: true
        )
        try makeQuickGitRepository(at: repository, seed: "quick-gap")
        _ = try runQuickGit([
            "worktree", "add", "-b", "feature/quick-gap", "--",
            worktree.path,
        ], at: repository)
        let managed = AgentManagedWorktree(
            taskID: UUID(),
            repositoryRoot: repository,
            managedRoot: managedRoot,
            worktreeRoot: worktree,
            branchName: "feature/quick-gap",
            baseCommit: try runQuickGit(["rev-parse", "HEAD"], at: repository),
            repositoryProof: try await quickRepositoryProof(
                repository: repository,
                worktree: worktree
            )
        )
        let defaultsDomain = "QuickCommitGap-\(UUID().uuidString)"
        let settingsDomain = "QuickCommitGapSettings-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsDomain))
        let settingsDefaults = try #require(
            UserDefaults(suiteName: settingsDomain)
        )
        defaults.removePersistentDomain(forName: defaultsDomain)
        settingsDefaults.removePersistentDomain(forName: settingsDomain)
        defer {
            defaults.removePersistentDomain(forName: defaultsDomain)
            settingsDefaults.removePersistentDomain(forName: settingsDomain)
        }
        let seedRegistry = ProjectRegistry(defaults: defaults)
        _ = try #require(await seedRegistry.projectManager(for: managed))
        seedRegistry.closeProjectWindow(worktree)
        seedRegistry.runBackgroundReclamationPassForTesting()

        let commitGate = QuickAgentScopeResolutionGate()
        let registry = ProjectRegistry(
            defaults: defaults,
            agentTaskFilesystemValidationCommitSeam: {
                await commitGate.suspendUntilReleased()
            }
        )
        let settings = QuickTerminalSettings(
            defaults: settingsDefaults,
            notificationCenter: NotificationCenter()
        )
        settings.enabled = true
        settings.hideOnFocusLoss = false
        let controller = QuickTerminalController(settings: settings)
        defer { controller.shutdown() }
        controller.registry = registry
        registry.quickTerminalAgentRouter = controller
        controller.show()
        await commitGate.waitUntilEntered()
        let displaced = managedRoot.appendingPathComponent(
            "displaced",
            isDirectory: true
        )
        try FileManager.default.moveItem(at: worktree, to: displaced)
        try FileManager.default.createDirectory(
            at: worktree,
            withIntermediateDirectories: false
        )
        await commitGate.release()
        await controller.waitForAgentScopeResolutionForTesting()
        #expect(!controller.isAgentScopeReadyForTesting)
        #expect(!controller.isAgentDetectionSubscribedForTesting)
        #expect(registry.agentSnapshotSubscriberCountForTesting == 0)
        #expect(registry.openProjects.isEmpty)
    }

    @Test("Hide/show and foreground child churn retain one exact live run")
    func hideShowAndChildChurnRetainExactRun() async throws {
        let fixture = try QuickTerminalAgentFixture()
        defer { fixture.cleanUp() }
        let tab = try await fixture.start()
        let agent = quickAgentProcess(
            pid: 7_501,
            parent: 7_500,
            group: 7_501,
            command: "codex",
            startedAt: 7_501
        )
        let child = quickAgentProcess(
            pid: 7_502,
            parent: 7_501,
            group: 7_502,
            command: "swift test",
            startedAt: 7_502
        )
        setQuickAgentIdentity(agent, on: tab)
        setQuickForeground(agent, on: tab)
        fixture.consume([agent], sequence: 1)
        let original = try #require(tab.agentSession)
        let taskID = try #require(
            fixture.registry.agentTasks.taskID(forSessionID: original.id)
        )

        fixture.controller.hide()
        #expect(!fixture.controller.isVisible)
        setQuickForeground(child, on: tab)
        fixture.consume([agent, child], sequence: 2)
        #expect(tab.agentSession === original)
        #expect(original.liveness == .live)

        fixture.controller.show()
        #expect(fixture.controller.isVisible)
        #expect(fixture.controller.paneState.activeTab === tab)
        setQuickForeground(agent, on: tab)
        fixture.consume([agent], sequence: 3)

        #expect(tab.agentSession === original)
        #expect(
            fixture.registry.agentTasks.task(for: taskID)?.runs.count == 1
        )
        #expect(
            fixture.registry.agentTasks.task(for: taskID)?.runs.last?.liveness
                == .live
        )
    }

    @Test("Inbox routes only the exact Quick Terminal generation")
    func inboxRoutesOnlyExactGeneration() async throws {
        let fixture = try QuickTerminalAgentFixture()
        defer { fixture.cleanUp() }
        let tab = try await fixture.start()
        let originalProcess = quickAgentProcess(
            pid: 7_601,
            parent: 7_600,
            group: 7_601,
            command: "claude",
            startedAt: 7_601
        )
        setQuickAgentIdentity(originalProcess, on: tab)
        setQuickForeground(originalProcess, on: tab)
        fixture.consume([originalProcess], sequence: 1)
        let originalSession = try #require(tab.agentSession)
        let taskID = try #require(
            fixture.registry.agentTasks.taskID(forSessionID: originalSession.id)
        )
        let task = try #require(fixture.registry.agentTasks.task(for: taskID))
        let route = task.route
        fixture.controller.hide()
        var openedProject = false

        let focused = await fixture.registry.navigateToAgentTaskFromInbox(
            taskID,
            openProjectWindow: { _ in openedProject = true },
            waitUntilPresented: { _ in false },
            activateApplication: { _ in }
        )

        #expect(focused == .focused(route))
        #expect(!openedProject)
        #expect(fixture.controller.isVisible)
        #expect(
            fixture.registry.agentTasks.task(for: taskID)?.isUnread == false
        )

        let replacement = quickAgentProcess(
            pid: 7_601,
            parent: 7_600,
            group: 7_601,
            command: "claude",
            startedAt: 7_611
        )
        setQuickAgentIdentity(replacement, on: tab)
        setQuickForeground(replacement, on: tab)
        fixture.consume([replacement], sequence: 2)

        #expect(tab.agentSession !== originalSession)
        #expect(await fixture.registry.navigateToAgentTaskFromInbox(
            taskID,
            openProjectWindow: { _ in },
            waitUntilPresented: { _ in true },
            activateApplication: { _ in }
        ) == .routeStale)
    }

    @Test("Quit cancel preserves detection and Quit confirmation freezes route")
    func quitCancelAndConfirmFollowQuickTerminalLifecycle() async throws {
        let project = try makeQuickTerminalDirectory(name: "Quit")
        defer { removeQuickTerminalDirectory(project) }
        let delegate = AppDelegate()
        let registry = ProjectRegistry(
            agentTasks: AgentTaskRegistry(
                persistence: QuickTerminalAgentTaskStore()
            ),
            agentDetectionProcessRunner: { _, _, _, _ in
                ProcessRunResult(
                    stdout: "",
                    stderr: "",
                    exitCode: 0,
                    timedOut: false
                )
            },
            agentDetectionPollInterval: 3_600
        )
        _ = registry.projectManager(for: project)
        delegate.registry = registry
        let settings = delegate.quickTerminalCoordinator.settings
        let originalEnabled = settings.enabled
        settings.enabled = true
        defer {
            delegate.quickTerminalCoordinator.shutdown()
            settings.enabled = originalEnabled
        }
        delegate.quickTerminalCoordinator.show()
        await delegate.quickTerminalCoordinator
            .waitForAgentScopeResolutionForTesting()
        #expect(
            delegate.quickTerminalCoordinator.isAgentScopeReadyForTesting
        )
        _ = await registry.agentTasks.flushPersistence()
        let tab = try #require(
            delegate.quickTerminalCoordinator.paneState.activeTab
        )
        let process = quickAgentProcess(
            pid: 7_701,
            parent: 7_700,
            group: 7_701,
            command: "pi",
            startedAt: 7_701
        )
        setQuickAgentIdentity(process, on: tab)
        setQuickForeground(process, on: tab)
        delegate.quickTerminalCoordinator.agentSnapshotConsumer
            .consumeAgentProcessSnapshot(
                [process],
                observation: quickObservation(sequence: 1)
            )
        let session = try #require(tab.agentSession)
        let taskID = try #require(
            registry.agentTasks.taskID(forSessionID: session.id)
        )
        delegate.quickTerminalCoordinator.hide()

        let cancelled = await delegate.confirmApplicationTermination(
            presentAlert: { template, _, _, _ in
                template == .applicationQuitSummary
                    ? .alertThirdButtonReturn
                    : .alertFirstButtonReturn
            },
            terminationDeadlineOverride: .now() + 5
        )
        #expect(!cancelled)
        delegate.quickTerminalCoordinator.agentSnapshotConsumer
            .consumeAgentProcessSnapshot(
                [process],
                observation: quickObservation(sequence: 2)
            )
        #expect(tab.agentSession === session)
        #expect(registry.agentTasks.task(for: taskID)?.lifecycle == .active)
        #expect(
            registry.agentTasks.task(for: taskID)?.route.availability
                == .available
        )

        let confirmed = await delegate.confirmApplicationTermination(
            presentAlert: { template, _, _, _ in
                template == .applicationQuitSummary
                    ? .alertSecondButtonReturn
                    : .alertFirstButtonReturn
            },
            terminationDeadlineOverride: .now() + 5
        )
        #expect(confirmed)
        #expect(registry.agentTasks.task(for: taskID)?.lifecycle == .paused)
        #expect(
            registry.agentTasks.task(for: taskID)?.route.availability
                == .missing
        )
        #expect(
            registry.agentTasks.task(for: taskID)?.runs.last?.liveness
                == .stale
        )
    }
}

@MainActor
private final class QuickTerminalAgentFixture {
    let settingsDomain: String
    let registryDomain: String
    let settingsDefaults: UserDefaults
    let registryDefaults: UserDefaults
    let registry: ProjectRegistry
    let controller: QuickTerminalController

    init(
        recentProjects: [URL] = [],
        proveRecentProjectIdentity: Bool = true,
        agentScopeResolver: (@MainActor (
            ProjectRegistry,
            URL,
            AgentTaskTerminalSurface
        ) async -> QuickTerminalAgentScopeRegistration?)? = nil,
        processRunner: @escaping ProcessRunner = { _, _, _, _ in
            ProcessRunResult(
                stdout: "",
                stderr: "",
                exitCode: 0,
                timedOut: false
            )
        }
    ) throws {
        settingsDomain = "QuickTerminalAgentSettings-\(UUID().uuidString)"
        registryDomain = "QuickTerminalAgentRegistry-\(UUID().uuidString)"
        settingsDefaults = try #require(UserDefaults(suiteName: settingsDomain))
        registryDefaults = try #require(UserDefaults(suiteName: registryDomain))
        settingsDefaults.removePersistentDomain(forName: settingsDomain)
        registryDefaults.removePersistentDomain(forName: registryDomain)
        let settings = QuickTerminalSettings(
            defaults: settingsDefaults,
            notificationCenter: NotificationCenter()
        )
        settings.enabled = true
        settings.hideOnFocusLoss = false
        registry = ProjectRegistry(
            defaults: registryDefaults,
            agentTasks: AgentTaskRegistry(
                persistence: QuickTerminalAgentTaskStore()
            ),
            agentDetectionProcessRunner: processRunner,
            agentDetectionPollInterval: 3_600
        )
        if proveRecentProjectIdentity {
            for project in recentProjects.reversed() {
                _ = registry.projectManager(for: project)
            }
        } else {
            registry.recentProjects = recentProjects
        }
        if let agentScopeResolver {
            controller = QuickTerminalController(
                settings: settings,
                agentScopeResolver: agentScopeResolver
            )
        } else {
            controller = QuickTerminalController(settings: settings)
        }
        controller.registry = registry
        registry.quickTerminalAgentRouter = controller
    }

    func start() async throws -> TerminalTab {
        controller.show()
        await controller.waitForAgentScopeResolutionForTesting()
        #expect(controller.isAgentScopeReadyForTesting)
        _ = await registry.agentTasks.flushPersistence()
        return try #require(controller.paneState.activeTab)
    }

    func consume(_ processes: [DetectedProcess], sequence: UInt64) {
        controller.agentSnapshotConsumer.consumeAgentProcessSnapshot(
            processes,
            observation: quickObservation(sequence: sequence)
        )
    }

    func cleanUp() {
        controller.shutdown()
        settingsDefaults.removePersistentDomain(forName: settingsDomain)
        registryDefaults.removePersistentDomain(forName: registryDomain)
    }
}

private actor QuickTerminalAgentTaskStore: AgentTaskPersisting {
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
private struct QuickRecentManagedFixture {
    let root: URL
    let repository: URL
    let managedRoot: URL
    let worktree: URL
    let managed: AgentManagedWorktree
    let defaults: UserDefaults
    let defaultsDomain: String

    func cleanUp() {
        defaults.removePersistentDomain(forName: defaultsDomain)
        removeQuickTerminalDirectory(root)
    }
}

@MainActor
private func makeQuickRecentManagedFixture(
    name: String
) async throws -> QuickRecentManagedFixture {
    let root = try makeQuickTerminalDirectory(name: name)
    do {
        let repository = root.appendingPathComponent(
            "Repository",
            isDirectory: true
        )
        let managedRoot = root.appendingPathComponent(
            "Managed",
            isDirectory: true
        )
        let worktree = managedRoot.appendingPathComponent(
            "worktree",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: managedRoot,
            withIntermediateDirectories: true
        )
        try makeQuickGitRepository(at: repository, seed: name)
        _ = try runQuickGit([
            "worktree", "add", "-b", "feature/\(name.lowercased())",
            "--", worktree.path,
        ], at: repository)
        let defaultsDomain = "QuickRecent-\(name)-\(UUID().uuidString)"
        let defaults = try #require(
            UserDefaults(suiteName: defaultsDomain)
        )
        defaults.removePersistentDomain(forName: defaultsDomain)
        let managed = AgentManagedWorktree(
            taskID: UUID(),
            repositoryRoot: repository,
            managedRoot: managedRoot,
            worktreeRoot: worktree,
            branchName: "feature/\(name.lowercased())",
            baseCommit: try runQuickGit(
                ["rev-parse", "HEAD"],
                at: repository
            ),
            repositoryProof: try await quickRepositoryProof(
                repository: repository,
                worktree: worktree
            )
        )
        return QuickRecentManagedFixture(
            root: root,
            repository: repository,
            managedRoot: managedRoot,
            worktree: worktree,
            managed: managed,
            defaults: defaults,
            defaultsDomain: defaultsDomain
        )
    } catch {
        removeQuickTerminalDirectory(root)
        throw error
    }
}

private func quickRepositoryProof(
    repository: URL,
    worktree: URL
) async throws -> RecentAgentTaskRepositoryProof {
    let canonicalRepository = repository.resolvingSymlinksInPath()
        .standardizedFileURL
    let canonicalWorktree = worktree.resolvingSymlinksInPath()
        .standardizedFileURL
    let identity = AgentTaskProjectIdentity(
        canonicalProjectPath: canonicalRepository.path,
        canonicalWorktreePath: canonicalWorktree.path
    )
    return try #require(await Task.detached(priority: .utility) {
        RecentAgentTaskFilesystemValidator.repositoryProof(for: identity)
    }.value)
}

@MainActor
private func setQuickAgentIdentity(
    _ process: DetectedProcess,
    on tab: TerminalTab
) {
    let identity = process.preciseStartedAt.flatMap {
        TerminalProcessStartIdentity(processID: process.pid, startedAt: $0)
    }
    tab.agentProcessIdentityResolverForTesting = { processID in
        processID == process.pid ? identity : nil
    }
}

@MainActor
private func setQuickForeground(
    _ process: DetectedProcess,
    on tab: TerminalTab
) {
    tab.foregroundProcessIDOverrideForTesting = process.processGroupID
    tab.foregroundStartOverrideForTesting = process.preciseStartedAt.flatMap {
        TerminalProcessStartIdentity(processID: process.pid, startedAt: $0)
    }
}

nonisolated private func quickAgentProcess(
    pid: Int32,
    parent: Int32,
    group: Int32,
    command: String,
    startedAt: TimeInterval
) -> DetectedProcess {
    DetectedProcess(
        pid: pid,
        parentProcessID: parent,
        processGroupID: group,
        command: command,
        cpuTime: 0,
        startIdentifier: "generation-\(startedAt)",
        preciseStartedAt: Date(timeIntervalSince1970: startedAt)
    )
}

nonisolated private func quickObservation(
    sequence: UInt64
) -> AgentObservationStamp {
    AgentObservationStamp(
        wallTime: Date(timeIntervalSince1970: TimeInterval(sequence)),
        uptime: TimeInterval(sequence),
        generation: 1,
        sequence: sequence
    )
}

@MainActor
private func quickDetectedSession(
    agentType: AgentType,
    processID: Int32,
    generation: UInt64
) -> AgentSession {
    let startedAt = Date(timeIntervalSince1970: TimeInterval(generation))
    let session = AgentSession(agentType: agentType, startedAt: startedAt)
    _ = session.bindProcessEvidence(AgentProcessEvidence(
        processIdentifier: processID,
        processGeneration: generation,
        startIdentifier: "generation-\(generation)",
        observedStartedAt: startedAt,
        startIsAuthoritative: true
    ))
    return session
}

@MainActor
private func quickRecoveryTask(
    surface: AgentTaskTerminalSurface,
    lifecycle: AgentTaskLifecycle,
    privatePath: String
) -> AgentTask {
    let terminalID = UUID()
    let timestamp = Date(timeIntervalSince1970: 8_000)
    let context = AgentTaskBridgeContext(
        project: AgentTaskProjectIdentity(
            canonicalProjectPath: privatePath,
            canonicalWorktreePath: privatePath
        ),
        route: AgentTaskRoute(
            surface: surface,
            paneID: UUID(),
            tabID: terminalID,
            terminalID: terminalID,
            availability: .missing
        ),
        presentationContext: AgentTaskPresentationContext(
            terminalStableLabel: Strings.quickTerminalText()
        ),
        origin: .pineLaunched,
        observedAt: timestamp
    )
    var task = AgentTask(
        descriptor: AgentDescriptor(
            agentType: .codex,
            launchExecutable: "codex"
        ),
        context: context,
        title: "Private recovery",
        objective: "Private recovery",
        createdAt: timestamp
    )
    task.lifecycle = lifecycle
    task.completedAt = lifecycle == .completed ? timestamp : nil
    return task
}

@MainActor
private func quickProjectRecoveryTask(
    identity: AgentTaskProjectIdentity
) -> AgentTask {
    let terminalID = UUID()
    let timestamp = Date(timeIntervalSince1970: 8_100)
    let context = AgentTaskBridgeContext(
        project: identity,
        route: AgentTaskRoute(
            surface: .projectWindow,
            paneID: UUID(),
            tabID: terminalID,
            terminalID: terminalID,
            availability: .missing
        ),
        presentationContext: AgentTaskPresentationContext(
            terminalStableLabel: "Terminal"
        ),
        origin: .pineLaunched,
        observedAt: timestamp
    )
    var task = AgentTask(
        descriptor: AgentDescriptor(
            agentType: .codex,
            launchExecutable: "codex"
        ),
        context: context,
        title: "Persisted recovery",
        objective: "Persisted recovery",
        createdAt: timestamp
    )
    task.lifecycle = .paused
    return task
}

private func makeQuickTerminalDirectory(name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
        "PineQuickTerminalAgent-\(name)-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: url,
        withIntermediateDirectories: true
    )
    return url.resolvingSymlinksInPath().standardizedFileURL
}

private func makeQuickGitRepository(
    at repository: URL,
    seed: String
) throws {
    try FileManager.default.createDirectory(
        at: repository,
        withIntermediateDirectories: true
    )
    _ = try runQuickGit(["init", "--initial-branch=main"], at: repository)
    _ = try runQuickGit(
        ["config", "user.name", "Pine Quick Terminal Tests"],
        at: repository
    )
    _ = try runQuickGit(
        ["config", "user.email", "quick-terminal-tests@pine.invalid"],
        at: repository
    )
    try Data(seed.utf8).write(
        to: repository.appendingPathComponent("seed.txt"),
        options: .atomic
    )
    _ = try runQuickGit(["add", "--", "seed.txt"], at: repository)
    _ = try runQuickGit(
        ["commit", "-m", "test fixture"],
        at: repository
    )
}

private func runQuickGit(
    _ arguments: [String],
    at directory: URL
) throws -> String {
    let result = GitCommand.run(arguments, at: directory, timeout: 5)
    guard result.succeeded else {
        throw QuickGitFixtureError.commandFailed(
            arguments: arguments,
            diagnostics: result.errorOutput
        )
    }
    return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
}

private enum QuickGitFixtureError: Error {
    case commandFailed(arguments: [String], diagnostics: String)
}

private func removeQuickTerminalDirectory(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
}
