import AppKit
import Darwin
import Foundation
import Testing

@testable import Pine

/// Partial control-plane coverage for #1422: this suite uses real production
/// process snapshots and exact project routing, but deliberately does not
/// claim Pine PTY launch/close, scrollback, confirmed-Quit process ownership,
/// or Quick Terminal coverage. Those remain with #1436 and #1420.
@Suite("Multi-project agent snapshot routing", .serialized)
@MainActor
struct MultiProjectAgentJourneyTests {
    @Test("fixture publication failures clean every owned child", arguments: [
        "parent", "child", "ready",
    ])
    func fixturePublicationFailureCleanup(phase: String) async throws {
        let fixture = try MultiProjectAgentLifecycleFixture()
        defer { fixture.cleanup() }
        for iteration in 0..<5 {
            try await fixture.assertPublicationFailureCleansChild(
                agent: "pi",
                phase: phase,
                iteration: iteration
            )
        }
    }

    @Test("real snapshots route agents across projects and registry rollback")
    func realProcessControlPlaneJourney() async throws {
        let fixture = try MultiProjectAgentLifecycleFixture()
        defer { fixture.cleanup() }
        let defaultsSuite = "MultiProjectAgentJourneyTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsSuite))
        defaults.removePersistentDomain(forName: defaultsSuite)
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        let store = MultiProjectAgentLifecycleStore()
        let tasks = AgentTaskRegistry(persistence: store)
        let projects = ProjectRegistry(
            defaults: defaults,
            agentTasks: tasks,
            agentDetectionPollInterval: 3_600,
            agentDetectionInitialPollDelay: 3_600
        )
        let managerA = try #require(projects.projectManager(for: fixture.projectA))
        let managerB = try #require(projects.projectManager(for: fixture.projectB))
        #expect(managerA !== managerB)

        let routeA = try makeTerminalRoute(in: managerA, tabCount: 2)
        let routeB = try makeTerminalRoute(in: managerB, tabCount: 1)
        #expect(projects.agentSnapshotSubscriberCountForTesting == 2)

        // Each launch returns only after its child PID/start identity is
        // durably published. Keeping setup sequential means a later failure
        // cannot strand an earlier fixture with unknown ownership.
        let pi = try await fixture.launchReady(agent: "pi")
        let codex = try await fixture.launchReady(agent: "codex")
        let claude = try await fixture.launchReady(agent: "claude")

        let processTree = try #require(
            await projects.captureRealAgentProcessesForTesting()
        )
        try bind(
            pi,
            to: routeA.tabs[0],
            foreground: .agent,
            processes: processTree
        )
        try bind(
            codex,
            to: routeA.tabs[1],
            foreground: .child,
            processes: processTree
        )
        try bind(
            claude,
            to: routeB.tabs[0],
            foreground: .agent,
            processes: processTree
        )
        await projects.runRealAgentProcessSnapshotForTesting()

        try requireDetectedProcess(pi, in: managerA)
        try requireDetectedProcess(codex, in: managerA)
        try requireDetectedProcess(claude, in: managerB)
        let piSession = try requireSession(
            routeA.tabs[0], agent: .pi, process: pi
        )
        let codexSession = try requireSession(
            routeA.tabs[1], agent: .codex, process: codex
        )
        let claudeSession = try requireSession(
            routeB.tabs[0], agent: .claudeCode, process: claude
        )
        let initialSessions = [piSession, codexSession, claudeSession]
        #expect(Set(initialSessions.map(\.id)).count == 3)
        #expect(initialSessions.allSatisfy {
            ($0.processEvidence?.processGeneration ?? 0) > 0
        })
        #expect(tasks.tasks.count == 3)

        let piTaskID = try #require(tasks.taskID(forSessionID: piSession.id))
        let codexTaskID = try #require(tasks.taskID(forSessionID: codexSession.id))
        let claudeTaskID = try #require(tasks.taskID(forSessionID: claudeSession.id))
        assertRoute(
            tasks.task(for: piTaskID),
            project: fixture.projectA,
            pane: routeA.pane,
            tab: routeA.tabs[0],
            process: piSession.processEvidence
        )
        assertRoute(
            tasks.task(for: codexTaskID),
            project: fixture.projectA,
            pane: routeA.pane,
            tab: routeA.tabs[1],
            process: codexSession.processEvidence
        )
        assertRoute(
            tasks.task(for: claudeTaskID),
            project: fixture.projectB,
            pane: routeB.pane,
            tab: routeB.tabs[0],
            process: claudeSession.processEvidence
        )

        // A foreground child in Codex's process group is the ownership
        // witness. Returning foreground control to the agent itself must not
        // detach or replace the exact run.
        let churnTree = try #require(
            await projects.captureRealAgentProcessesForTesting()
        )
        try bind(
            codex,
            to: routeA.tabs[1],
            foreground: .agent,
            processes: churnTree
        )
        await projects.runRealAgentProcessSnapshotForTesting()
        #expect(routeA.tabs[1].agentSession === codexSession)
        #expect(codexSession.processEvidence
                == tasks.task(for: codexTaskID)?.runs.last?.process)

        projects.closeProjectWindow(fixture.projectA)
        #expect(projects.openProjects[
            ProjectRegistry.canonicalProjectURL(fixture.projectA)
        ] === managerA)
        #expect(tasks.task(for: piTaskID)?.route.availability == .background)
        #expect(tasks.task(for: codexTaskID)?.route.availability == .background)
        #expect(tasks.task(for: claudeTaskID)?.route.availability == .available)
        #expect(pi.isRunning)
        #expect(codex.isRunning)

        let expectedCodexRoute = AgentTaskRoute(
            paneID: routeA.pane.id,
            tabID: routeA.tabs[1].id,
            terminalID: routeA.tabs[1].id
        )
        var requestedProject: URL?
        var reopenedWindow: NSWindow?
        defer {
            if let reopenedWindow {
                managerA.unbindDialogOwnerWindow(reopenedWindow)
                reopenedWindow.delegate = nil
                reopenedWindow.close()
                reopenedWindow.contentView = nil
            }
        }
        let navigation = await projects.navigateToAgentTaskFromInbox(
            codexTaskID,
            openProjectWindow: { requestedProject = $0 },
            waitUntilPresented: { recovered in
                #expect(recovered === managerA)
                let window = makeEligibleProjectWindow()
                reopenedWindow = window
                recovered.bindDialogOwnerWindow(window)
                return true
            },
            activateApplication: { recovered in
                #expect(recovered === managerA)
            }
        )
        #expect(requestedProject
                == ProjectRegistry.canonicalProjectURL(fixture.projectA))
        #expect(navigation == .focused(expectedCodexRoute))
        #expect(managerA.paneManager.terminalState(for: routeA.pane)?
            .activeTerminalID == routeA.tabs[1].id)
        #expect(routeA.tabs[1].agentSession === codexSession)
        #expect(!projects.backgroundProjects.contains(
            ProjectRegistry.canonicalProjectURL(fixture.projectA)
        ))

        // A real complete snapshot proves one terminated PID. A subsequent
        // complete tree with a controlled same-PID/different-start row then
        // exercises the detector's logical generation replacement.
        let piProcessGroupID = pi.processGroupID
        pi.terminate()
        try await pi.awaitExit()
        await projects.runRealAgentProcessSnapshotForTesting()
        #expect(piSession.liveness == .terminated)
        let replacementStart = try #require(
            piSession.processEvidence?.observedStartedAt
        ).addingTimeInterval(0.000_001)
        let replacement = DetectedProcess(
            pid: pi.pid,
            parentProcessID: 1,
            processGroupID: piProcessGroupID,
            command: "python3 /controlled/pi",
            cpuTime: 0,
            startIdentifier: "replacement-generation",
            preciseStartedAt: replacementStart
        )
        routeA.tabs[0].foregroundStartOverrideForTesting =
            TerminalProcessStartIdentity(
                processID: pi.pid,
                startedAt: replacementStart
            )
        routeA.tabs[0].agentProcessIdentityResolverForTesting = { processID in
            guard processID == pi.pid else { return nil }
            return TerminalProcessStartIdentity(
                processID: pi.pid,
                startedAt: replacementStart
            )
        }
        let postTerminationTree = try #require(
            await projects.captureRealAgentProcessesForTesting()
        )
        #expect(postTerminationTree.contains { $0.pid == 1 })
        projects.applyCompleteAgentProcessTreeForTesting(
            postTerminationTree.filter { $0.pid != pi.pid } + [replacement]
        )
        guard let replacementSession = routeA.tabs[0].agentSession else {
            throw phaseError(pi, "controlled generation publication")
        }
        #expect(replacementSession !== piSession)
        #expect(replacementSession.agentType == .pi)
        #expect(
            (replacementSession.processEvidence?.processGeneration ?? 0)
                > (piSession.processEvidence?.processGeneration ?? 0)
        )

        // A cancelled termination transaction restores the exact
        // live/background availability projection for current project owners.
        projects.closeProjectWindow(fixture.projectB)
        projects.freezeAgentTasksForTermination()
        tasks.prepareForApplicationTermination()
        #expect(await tasks.flushPersistence() == .saved)
        #expect(tasks.tasks.allSatisfy {
            $0.route.availability == .missing && $0.lifecycle != .active
        })
        #expect(await projects.cancelAgentTaskTermination())
        #expect(tasks.task(for: codexTaskID)?.route.availability == .available)
        #expect(tasks.task(for: claudeTaskID)?.route.availability == .background)
        #expect(routeA.tabs[1].agentSession === codexSession)
        #expect(routeB.tabs[0].agentSession === claudeSession)

        // This final phase proves registry freeze/persistence/destruction only.
        // The processes are intentionally still live after manager teardown:
        // production confirmed-Quit process ownership remains #1436's scope.
        projects.freezeAgentTasksForTermination()
        tasks.prepareForApplicationTermination()
        #expect(await tasks.flushPersistence() == .saved)
        #expect(projects.destroyAllProjects())
        #expect(projects.openProjects.isEmpty)
        #expect(codex.isRunning)
        #expect(claude.isRunning)

        codex.terminate()
        claude.terminate()
        try await codex.awaitExit()
        try await claude.awaitExit()
    }

    private func makeTerminalRoute(
        in manager: ProjectManager,
        tabCount: Int
    ) throws -> (pane: PaneID, tabs: [TerminalTab]) {
        let editorPane = manager.paneManager.activePaneID
        manager.terminal.createTerminalTab(
            relativeTo: editorPane,
            workingDirectory: manager.rootURL
        )
        let pane = try #require(manager.paneManager.terminalPaneIDs.first)
        while manager.paneManager.terminalState(for: pane)?.tabCount ?? 0
                < tabCount {
            _ = manager.terminal.createTerminalTab(
                in: pane,
                workingDirectory: manager.rootURL
            )
        }
        let tabs = try #require(
            manager.paneManager.terminalState(for: pane)?.terminalTabs
        )
        #expect(tabs.count == tabCount)
        return (pane, tabs)
    }

    private enum ForegroundOwner { case agent, child }

    private func bind(
        _ process: ControlledAgentProcess,
        to tab: TerminalTab,
        foreground: ForegroundOwner,
        processes: [DetectedProcess]
    ) throws {
        let foregroundPID = switch foreground {
        case .agent: process.pid
        case .child: process.childPID
        }
        let witness = try #require(processes.first {
            $0.pid == foregroundPID
        })
        let startedAt = try #require(witness.preciseStartedAt)
        tab.foregroundProcessIDOverrideForTesting = witness.processGroupID
        tab.foregroundStartOverrideForTesting = TerminalProcessStartIdentity(
            processID: witness.pid,
            startedAt: startedAt
        )
        tab.agentProcessIdentityResolverForTesting = { processID in
            guard let current = UserTaskProcessInspector.identity(
                for: processID
            ) else { return nil }
            return TerminalProcessStartIdentity(
                processID: current.processID,
                seconds: current.startSeconds,
                microseconds: current.startMicroseconds
            )
        }
    }

    private func requireSession(
        _ tab: TerminalTab,
        agent: AgentType,
        process: ControlledAgentProcess
    ) throws -> AgentSession {
        guard let session = tab.agentSession else {
            throw phaseError(process, "tab publication")
        }
        #expect(session.agentType == agent)
        #expect(session.processEvidence?.processIdentifier == process.pid)
        #expect(session.processEvidence?.startIsAuthoritative == true)
        #expect(session.liveness == .live)
        return session
    }

    private func requireDetectedProcess(
        _ process: ControlledAgentProcess,
        in manager: ProjectManager
    ) throws {
        guard manager.terminal.agentDetector.session(forPID: process.pid)
                != nil else {
            throw ControlledAgentLifecycleError.phaseTimeout(
                agent: process.name,
                phase: "production detection",
                processIdentifier: process.pid
            )
        }
    }

    private func phaseError(
        _ process: ControlledAgentProcess,
        _ phase: String
    ) -> ControlledAgentLifecycleError {
        .phaseTimeout(
            agent: process.name,
            phase: phase,
            processIdentifier: process.pid
        )
    }

    private func assertRoute(
        _ task: AgentTask?,
        project: URL,
        pane: PaneID,
        tab: TerminalTab,
        process: AgentProcessEvidence?
    ) {
        #expect(task?.project.canonicalWorktreePath
                == ProjectRegistry.canonicalProjectURL(project).path)
        #expect(task?.route == AgentTaskRoute(
            paneID: pane.id,
            tabID: tab.id,
            terminalID: tab.id
        ))
        #expect(task?.runs.last?.process == process)
        #expect(task?.runs.last?.liveness == .live)
    }

    private func makeEligibleProjectWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.makeKeyAndOrderFront(nil)
        return window
    }
}

private actor MultiProjectAgentLifecycleStore: AgentTaskPersisting {
    private var byProject: [String: [AgentTask]] = [:]

    func save(
        tasks: [AgentTask],
        project: AgentTaskProjectIdentity,
        authorization: AgentTaskPublicationAuthorization?
    ) async -> AgentTaskMetadataSaveResult {
        if let authorization {
            switch authorization.publishForTesting(operation: {
                byProject[project.persistenceKey] = tasks
                return true
            }) {
            case .published:
                break
            case .failed:
                return .rejected(.ioFailure)
            case .superseded:
                return .rejected(.superseded)
            }
        } else {
            byProject[project.persistenceKey] = tasks
        }
        return .saved(taskCount: tasks.count)
    }

    func load(
        project: AgentTaskProjectIdentity
    ) async -> AgentTaskMetadataLoadResult {
        AgentTaskMetadataLoadResult(
            status: byProject[project.persistenceKey] == nil ? .missing : .loaded,
            tasks: byProject[project.persistenceKey] ?? []
        )
    }
}

private final class MultiProjectAgentLifecycleFixture {
    let root: URL
    let projectA: URL
    let projectB: URL
    private let scripts: URL
    private let state: URL
    private var processes: [ControlledAgentProcess] = []

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "pine-agent-lifecycle-\(UUID().uuidString)",
            isDirectory: true
        )
        projectA = root.appending(path: "A/Duplicate", directoryHint: .isDirectory)
        projectB = root.appending(path: "B/Duplicate", directoryHint: .isDirectory)
        scripts = root.appending(path: "fixtures", directoryHint: .isDirectory)
        state = root.appending(path: "state", directoryHint: .isDirectory)
        for directory in [projectA, projectB, scripts, state] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        for name in ["pi", "codex", "claude"] {
            try Self.controlledAgentSource.write(
                to: scripts.appending(path: name),
                atomically: true,
                encoding: .utf8
            )
        }
    }

    func launchReady(agent: String) async throws -> ControlledAgentProcess {
        let processState = state.appending(
            path: "\(agent)-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: processState,
            withIntermediateDirectories: false
        )
        let script = scripts.appending(path: agent)
        // `posix_spawn` is normally quick but is still a blocking syscall. Run
        // it away from this @MainActor integration journey; the subsequent
        // ownership handshake and every cleanup wait remain explicitly bounded.
        let pid = try await Task.detached(priority: .userInitiated) {
            try Self.spawn(
                agent: agent,
                script: script,
                state: processState,
                failurePhase: nil
            )
        }.value
        let clock = ContinuousClock()
        let identityDeadline = clock.now.advanced(by: .seconds(1))
        var identity: UserTaskProcessIdentity?
        do {
            while clock.now < identityDeadline {
                try Task.checkCancellation()
                identity = UserTaskProcessInspector.identity(
                    for: pid,
                    expectedParent: Darwin.getpid()
                )
                if identity != nil { break }
                try await clock.sleep(for: .milliseconds(10))
            }
        } catch {
            Self.cleanupUnidentifiedDirectChild(
                agent: agent,
                pid: pid,
                state: processState
            )
            throw error
        }
        guard let identity else {
            Self.cleanupUnidentifiedDirectChild(
                agent: agent,
                pid: pid,
                state: processState
            )
            throw ControlledAgentLifecycleError.phaseTimeout(
                agent: agent,
                phase: "authoritative launch identity",
                processIdentifier: pid
            )
        }
        let processGroupID = Darwin.getpgid(pid)
        let controlled = ControlledAgentProcess(
            name: agent,
            identity: identity,
            processGroupID: processGroupID,
            state: processState
        )
        processes.append(controlled)
        guard processGroupID == pid else {
            controlled.forceCleanup()
            processes.removeLast()
            throw ControlledAgentLifecycleError.invalidProcessGroup(
                agent: agent,
                processIdentifier: pid,
                processGroupIdentifier: processGroupID
            )
        }
        do {
            try await controlled.awaitDurableReady()
            return controlled
        } catch {
            controlled.forceCleanup()
            processes.removeAll { $0 === controlled }
            throw error
        }
    }

    func assertPublicationFailureCleansChild(
        agent: String,
        phase: String,
        iteration: Int
    ) async throws {
        let processState = state.appending(
            path: "fault-\(phase)-\(iteration)-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: processState,
            withIntermediateDirectories: false
        )
        let script = scripts.appending(path: agent)
        let pid = try await Task.detached(priority: .userInitiated) {
            try Self.spawn(
                agent: agent,
                script: script,
                state: processState,
                failurePhase: phase
            )
        }.value

        let parent: UserTaskProcessIdentity
        do {
            parent = try await Self.awaitIdentity(
                pid: pid,
                expectedParent: Darwin.getpid(),
                agent: agent,
                phase: "fault parent identity"
            )
        } catch {
            Self.cleanupUnidentifiedDirectChild(
                agent: agent,
                pid: pid,
                state: processState
            )
            throw error
        }
        let processGroupID = Darwin.getpgid(pid)
        guard processGroupID == pid else {
            let controlled = ControlledAgentProcess(
                name: agent,
                identity: parent,
                processGroupID: processGroupID,
                state: processState
            )
            controlled.forceCleanup()
            throw ControlledAgentLifecycleError.invalidProcessGroup(
                agent: agent,
                processIdentifier: pid,
                processGroupIdentifier: processGroupID
            )
        }
        let controlled = ControlledAgentProcess(
            name: agent,
            identity: parent,
            processGroupID: processGroupID,
            state: processState
        )
        processes.append(controlled)

        do {
            // The child handshake is deliberately independent of every file
            // publication being faulted. posix_spawn gives Swift the exact
            // direct-child leader; its validated private pgid then exposes the
            // Python-owned sleep through libproc before the fault is released.
            let child = try await Self.awaitOwnedChild(
                parent: parent,
                processGroupID: processGroupID,
                agent: agent,
                phase: "fault \(phase) child handshake iteration \(iteration)"
            )
            controlled.registerOwnedIdentity(child)

            try Data("release".utf8).write(
                to: processState.appending(path: "fault-release"),
                options: .atomic
            )
            try await Self.awaitFile(
                processState.appending(path: "mask-restored"),
                agent: agent,
                phase: "signal mask restoration"
            )
            try await controlled.awaitExit()
            #expect(UserTaskProcessInspector.identity(for: child.processID) != child)
            #expect(UserTaskProcessInspector.identity(for: pid) != parent)
        } catch {
            controlled.forceCleanup()
            throw error
        }
    }

    func cleanup() {
        for process in processes { process.forceCleanup() }
        try? FileManager.default.removeItem(at: root)
    }

    nonisolated private static func spawn(
        agent: String,
        script: URL,
        state: URL,
        failurePhase: String?
    ) throws -> pid_t {
        var fileActions: posix_spawn_file_actions_t?
        try check(
            posix_spawn_file_actions_init(&fileActions),
            agent: agent,
            operation: "file-actions init"
        )
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        for descriptor in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
            let flags = descriptor == STDIN_FILENO ? O_RDONLY : O_WRONLY
            let result = "/dev/null".withCString { path in
                posix_spawn_file_actions_addopen(
                    &fileActions,
                    descriptor,
                    path,
                    flags,
                    0
                )
            }
            try check(
                result,
                agent: agent,
                operation: "redirect descriptor \(descriptor)"
            )
        }

        var attributes: posix_spawnattr_t?
        try check(
            posix_spawnattr_init(&attributes),
            agent: agent,
            operation: "attributes init"
        )
        defer { posix_spawnattr_destroy(&attributes) }
        try check(
            posix_spawnattr_setpgroup(&attributes, 0),
            agent: agent,
            operation: "process group"
        )
        var signalMask = sigset_t()
        guard sigemptyset(&signalMask) == 0 else {
            throw ControlledAgentLifecycleError.spawnFailure(
                agent: agent,
                operation: "signal mask",
                code: errno
            )
        }
        var defaultSignals = sigset_t()
        guard sigfillset(&defaultSignals) == 0,
              sigdelset(&defaultSignals, SIGKILL) == 0,
              sigdelset(&defaultSignals, SIGSTOP) == 0 else {
            throw ControlledAgentLifecycleError.spawnFailure(
                agent: agent,
                operation: "signal defaults",
                code: errno
            )
        }
        try check(
            posix_spawnattr_setsigmask(&attributes, &signalMask),
            agent: agent,
            operation: "install signal mask"
        )
        try check(
            posix_spawnattr_setsigdefault(&attributes, &defaultSignals),
            agent: agent,
            operation: "install signal defaults"
        )
        let flags = Int16(
            POSIX_SPAWN_SETPGROUP
                | POSIX_SPAWN_CLOEXEC_DEFAULT
                | POSIX_SPAWN_SETSIGMASK
                | POSIX_SPAWN_SETSIGDEF
        )
        try check(
            posix_spawnattr_setflags(&attributes, flags),
            agent: agent,
            operation: "spawn flags"
        )

        let executable = "/usr/bin/python3"
        var processIdentifier: pid_t = 0
        let spawnResult = withMutableCStringArray([
            executable,
            script.path,
            state.path,
            failurePhase ?? "none",
        ]) { arguments in
            withMutableCStringArray([
                "LANG=C",
                "PATH=/usr/bin:/bin",
            ]) { environment in
                executable.withCString { executablePath in
                    posix_spawn(
                        &processIdentifier,
                        executablePath,
                        &fileActions,
                        &attributes,
                        arguments,
                        environment
                    )
                }
            }
        }
        try check(spawnResult, agent: agent, operation: "posix_spawn")
        return processIdentifier
    }

    private static func awaitIdentity(
        pid: pid_t,
        expectedParent: pid_t,
        agent: String,
        phase: String
    ) async throws -> UserTaskProcessIdentity {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            try Task.checkCancellation()
            if let identity = UserTaskProcessInspector.identity(
                for: pid,
                expectedParent: expectedParent
            ) {
                return identity
            }
            try await clock.sleep(for: .milliseconds(10))
        }
        throw ControlledAgentLifecycleError.phaseTimeout(
            agent: agent,
            phase: phase,
            processIdentifier: pid
        )
    }

    private static func awaitFile(
        _ url: URL,
        agent: String,
        phase: String
    ) async throws {
        let clock = ContinuousClock()
        // The controlled Python process has already published an exact child
        // identity before this wait. A loaded macOS runner can still take
        // more than two seconds to schedule it after the release-file rename;
        // keep the wait bounded but align it with the fixture's own 5-second
        // release deadline so a safe cleanup test does not become a scheduler
        // lottery.
        let deadline = clock.now.advanced(by: .seconds(5))
        while clock.now < deadline {
            try Task.checkCancellation()
            if FileManager.default.fileExists(atPath: url.path) { return }
            try await clock.sleep(for: .milliseconds(10))
        }
        throw ControlledAgentLifecycleError.phaseTimeout(
            agent: agent,
            phase: phase,
            processIdentifier: -1
        )
    }

    private static func awaitOwnedChild(
        parent: UserTaskProcessIdentity,
        processGroupID: pid_t,
        agent: String,
        phase: String
    ) async throws -> UserTaskProcessIdentity {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            try Task.checkCancellation()
            guard UserTaskProcessInspector.identity(for: parent.processID)
                    == parent,
                  processGroupID == parent.processID,
                  Darwin.getpgid(parent.processID) == processGroupID else {
                break
            }
            if case .known(let processIDs) =
                UserTaskProcessInspector.processIDs(inGroup: processGroupID) {
                for processID in processIDs where processID != parent.processID {
                    guard Darwin.getpgid(processID) == processGroupID,
                          let child = UserTaskProcessInspector.identity(
                            for: processID,
                            expectedParent: parent.processID
                          ),
                          Darwin.getpgid(processID) == processGroupID,
                          UserTaskProcessInspector.identity(for: processID)
                            == child else {
                        continue
                    }
                    return child
                }
            }
            try await clock.sleep(for: .milliseconds(10))
        }
        throw ControlledAgentLifecycleError.phaseTimeout(
            agent: agent,
            phase: phase,
            processIdentifier: parent.processID
        )
    }

    nonisolated private static func check(
        _ result: Int32,
        agent: String,
        operation: String
    ) throws {
        guard result == 0 else {
            throw ControlledAgentLifecycleError.spawnFailure(
                agent: agent,
                operation: operation,
                code: result
            )
        }
    }

    private static func cleanupUnidentifiedDirectChild(
        agent: String,
        pid: pid_t,
        state: URL
    ) {
        var captured: [pid_t: UserTaskProcessIdentity] = [:]
        var parentIsUnreaped = true
        var didReap = false

        func isCurrent(_ identity: UserTaskProcessIdentity) -> Bool {
            UserTaskProcessInspector.identity(for: identity.processID) == identity
        }

        func captureOwnedMembers() {
            let hasKnownAnchor = captured.values.contains { identity in
                isCurrent(identity)
                    && Darwin.getpgid(identity.processID) == pid
            }
            // Before reaping, the direct-child PID cannot be recycled. Together
            // with the isolated pgid established by posix_spawn, that is a safe
            // setup-failure anchor even when libproc could not read its start.
            let hasDirectChildAnchor = parentIsUnreaped
                && Darwin.getpgid(pid) == pid
            guard hasDirectChildAnchor || hasKnownAnchor else { return }

            if case .known(let memberIDs) =
                UserTaskProcessInspector.processIDs(inGroup: pid) {
                for memberPID in memberIDs where memberPID > 1 {
                    guard Darwin.getpgid(memberPID) == pid,
                          let identity = UserTaskProcessInspector.identity(
                            for: memberPID
                          ),
                          Darwin.getpgid(memberPID) == pid,
                          UserTaskProcessInspector.identity(for: memberPID)
                            == identity else {
                        continue
                    }
                    captured[memberPID] = identity
                }
            }

            if let value = try? String(
                contentsOf: state.appending(path: "child.pid"),
                encoding: .utf8
            ), let childPID = pid_t(value),
               let child = UserTaskProcessInspector.identity(
                for: childPID,
                expectedParent: pid
               ), Darwin.getpgid(childPID) == pid,
               UserTaskProcessInspector.identity(for: childPID) == child {
                captured[childPID] = child
            }
        }

        func signalCaptured(_ signal: Int32) {
            for identity in captured.values where isCurrent(identity) {
                _ = Darwin.kill(identity.processID, signal)
            }
        }

        func pollParent() {
            guard parentIsUnreaped else { return }
            var status: Int32 = 0
            let result = Darwin.waitpid(pid, &status, WNOHANG)
            if result == pid || (result == -1 && errno == ECHILD) {
                parentIsUnreaped = false
                didReap = true
            }
        }

        captureOwnedMembers()
        pollParent()
        guard parentIsUnreaped || !captured.isEmpty else { return }

        // If still running, `waitpid == 0` proved this is our direct child and
        // therefore a safe PID target despite the missing libproc identity.
        if parentIsUnreaped { _ = Darwin.kill(pid, SIGTERM) }
        signalCaptured(SIGTERM)
        let termDeadline = DispatchTime.now() + .milliseconds(500)
        repeat {
            captureOwnedMembers()
            pollParent()
            if !parentIsUnreaped && !captured.values.contains(where: isCurrent) {
                break
            }
            Darwin.usleep(10_000)
        } while DispatchTime.now() < termDeadline

        signalCaptured(SIGKILL)
        // Re-check direct-child ownership immediately before the fallback KILL.
        pollParent()
        if parentIsUnreaped { _ = Darwin.kill(pid, SIGKILL) }
        let killDeadline = DispatchTime.now() + .seconds(1)
        repeat {
            captureOwnedMembers()
            signalCaptured(SIGKILL)
            pollParent()
            if !parentIsUnreaped && !captured.values.contains(where: isCurrent) {
                break
            }
            Darwin.usleep(10_000)
        } while DispatchTime.now() < killDeadline
        pollParent()

        let live = captured.values.filter(isCurrent)
        guard didReap, live.isEmpty else {
            let liveDescription = live.map {
                "\($0.processID)@\($0.startSeconds).\($0.startMicroseconds)"
            }.sorted().joined(separator: ",")
            let message =
                "Bounded setup cleanup failed for controlled \(agent): "
                    + "parent pid \(pid), reaped=\(didReap), "
                    + "live identities=[\(liveDescription)]"
            Issue.record(Comment(rawValue: message))
            return
        }
    }

    private static let controlledAgentSource = #"""
import os
import signal
import subprocess
import sys
import time

state = sys.argv[1]
failure_phase = sys.argv[2]
child = None

def write(name, value):
    temporary = os.path.join(state, name + ".tmp")
    final = os.path.join(state, name)
    with open(temporary, "w", encoding="ascii") as handle:
        handle.write(str(value))
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, final)

def cleanup_child():
    if child is None:
        return
    if child.poll() is not None:
        return
    try:
        child.terminate()
        child.wait(timeout=1)
    except Exception:
        try:
            child.kill()
            child.wait(timeout=1)
        except Exception:
            pass

def stop(_signal, _frame):
    cleanup_child()
    sys.exit(0)

def fail_before(phase):
    if failure_phase == phase:
        raise RuntimeError("injected " + phase + " publication failure")

signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)
blocked = {signal.SIGTERM, signal.SIGINT}
old_mask = signal.pthread_sigmask(signal.SIG_BLOCK, blocked)
mask_restored = False
try:
    child = subprocess.Popen(["/bin/sleep", "3600"])
    if failure_phase != "none":
        release = os.path.join(state, "fault-release")
        deadline = time.monotonic() + 5
        while not os.path.exists(release):
            if time.monotonic() >= deadline:
                raise TimeoutError("fault release timed out")
            time.sleep(0.01)

    signal.pthread_sigmask(signal.SIG_SETMASK, old_mask)
    mask_restored = True
    current_mask = signal.pthread_sigmask(signal.SIG_BLOCK, set())
    if signal.SIGTERM in current_mask or signal.SIGINT in current_mask:
        raise RuntimeError("fixture termination signals remained blocked")
    write("mask-restored", 1)

    fail_before("parent")
    write("parent.pid", os.getpid())
    fail_before("child")
    write("child.pid", child.pid)
    fail_before("ready")
    write("ready", 1)
    while True:
        time.sleep(60)
finally:
    # This fixture owns its child independently from Swift's ability to inspect
    # the leader. Publication, fsync, injected failure, cancellation, and signal
    # paths all pass through this bounded teardown.
    cleanup_child()
    if not mask_restored:
        # Restore even when Popen or pre-publication setup raises. A pending TERM
        # can only be delivered after cleanup_child has eliminated the child.
        signal.pthread_sigmask(signal.SIG_SETMASK, old_mask)
"""#
}

private final class ControlledAgentProcess {
    let name: String
    let identity: UserTaskProcessIdentity
    let processGroupID: pid_t
    let state: URL
    private var knownIdentities: [pid_t: UserTaskProcessIdentity]
    private var didReap = false

    var pid: pid_t { identity.processID }
    var isRunning: Bool {
        UserTaskProcessInspector.identity(for: pid) == identity
    }
    var childPID: pid_t {
        guard let value = try? String(
            contentsOf: state.appending(path: "child.pid"),
            encoding: .utf8
        ), let pid = pid_t(value) else { return -1 }
        return pid
    }

    init(
        name: String,
        identity: UserTaskProcessIdentity,
        processGroupID: pid_t,
        state: URL
    ) {
        self.name = name
        self.identity = identity
        self.processGroupID = processGroupID
        self.state = state
        knownIdentities = [identity.processID: identity]
    }

    func awaitDurableReady() async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while clock.now < deadline {
            let observedChildPID = childPID
            let observedParentValue = try? String(
                contentsOf: state.appending(path: "parent.pid"),
                encoding: .utf8
            )
            let observedParentPID = observedParentValue.flatMap { pid_t($0) }
            if FileManager.default.fileExists(
                atPath: state.appending(path: "ready").path
            ), observedParentPID == pid, observedChildPID > 1,
               UserTaskProcessInspector.identity(for: pid) == identity,
               let child = UserTaskProcessInspector.identity(
                   for: observedChildPID,
                   expectedParent: pid
               ), Darwin.getpgid(observedChildPID) == processGroupID,
               UserTaskProcessInspector.identity(for: observedChildPID) == child {
                knownIdentities[child.processID] = child
                captureOwnedGroupMembers()
                return
            }
            try await clock.sleep(for: .milliseconds(10))
        }
        throw ControlledAgentLifecycleError.phaseTimeout(
            agent: name,
            phase: "ready",
            processIdentifier: pid
        )
    }

    func terminate() {
        captureOwnedGroupMembers()
        signalIfCurrent(identity, signal: SIGTERM)
    }

    func registerOwnedIdentity(_ candidate: UserTaskProcessIdentity) {
        knownIdentities[candidate.processID] = candidate
    }

    func awaitExit() async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while clock.now < deadline {
            captureOwnedGroupMembers()
            if !ownedIdentitiesAreCurrent, reapIfExited() { return }
            try await clock.sleep(for: .milliseconds(10))
        }
        guard !ownedIdentitiesAreCurrent else {
            throw ControlledAgentLifecycleError.phaseTimeout(
                agent: name,
                phase: "identity-qualified exit",
                processIdentifier: pid
            )
        }
        guard reapIfExited() else {
            throw ControlledAgentLifecycleError.phaseTimeout(
                agent: name,
                phase: "bounded reap",
                processIdentifier: pid
            )
        }
    }

    func forceCleanup() {
        captureOwnedGroupMembers()
        signalOwnedProcesses(SIGTERM)
        if waitForOwnedExit(until: .now() + .milliseconds(500)) {
            return
        }
        signalOwnedProcesses(SIGKILL)
        if !waitForOwnedExit(until: .now() + .seconds(1)) {
            let live = ownedIdentities.filter(isCurrent).map {
                "\($0.processID)@\($0.startSeconds).\($0.startMicroseconds)"
            }.joined(separator: ",")
            let message =
                "Bounded cleanup failed for controlled \(name) identities "
                    + "[\(live)] (parent pid \(pid))"
            Issue.record(Comment(rawValue: message))
        }
        if !reapIfExited() {
            let message =
                "Bounded cleanup could not reap controlled \(name) parent "
                    + "pid \(pid)"
            Issue.record(Comment(rawValue: message))
        }
    }

    private var ownedIdentities: [UserTaskProcessIdentity] {
        Array(knownIdentities.values)
    }

    private var ownedIdentitiesAreCurrent: Bool {
        ownedIdentities.contains(where: isCurrent)
    }

    private func isCurrent(_ candidate: UserTaskProcessIdentity) -> Bool {
        UserTaskProcessInspector.identity(for: candidate.processID) == candidate
    }

    private func signalIfCurrent(
        _ candidate: UserTaskProcessIdentity,
        signal: Int32
    ) {
        guard isCurrent(candidate) else { return }
        _ = Darwin.kill(candidate.processID, signal)
    }

    private func signalOwnedProcesses(_ signal: Int32) {
        // Each signal is guarded by the authoritative PID/start identity.
        // Never signal the process group: it may contain an unrelated reused
        // PID after one controlled member has exited.
        for candidate in ownedIdentities.reversed() {
            signalIfCurrent(candidate, signal: signal)
        }
    }

    private func waitForOwnedExit(until deadline: DispatchTime) -> Bool {
        repeat {
            captureOwnedGroupMembers()
            _ = reapIfExited()
            if !ownedIdentitiesAreCurrent, reapIfExited() { return true }
            Darwin.usleep(10_000)
        } while DispatchTime.now() < deadline
        _ = reapIfExited()
        return !ownedIdentitiesAreCurrent && didReap
    }

    private func captureOwnedGroupMembers() {
        // The durable handshake file may become visible while a failure path is
        // already unwinding. Its expected-parent check is sufficient ownership
        // proof even if the promised isolated pgid was not established.
        let observedChildPID = childPID
        if let child = UserTaskProcessInspector.identity(
            for: observedChildPID,
            expectedParent: pid
        ), UserTaskProcessInspector.identity(for: observedChildPID) == child {
            knownIdentities[observedChildPID] = child
        }

        // Never enumerate an unexpected process group: it can contain processes
        // this fixture does not own. The exact parent/direct-child identities
        // above remain safe cleanup targets for that launch-failure path.
        guard processGroupID == pid else { return }
        let hasCurrentAnchor = ownedIdentities.contains { candidate in
            isCurrent(candidate)
                && Darwin.getpgid(candidate.processID) == processGroupID
        }
        guard hasCurrentAnchor,
              case .known(let processIDs) =
                UserTaskProcessInspector.processIDs(inGroup: processGroupID) else {
            return
        }

        for processID in processIDs where processID > 1 {
            guard Darwin.getpgid(processID) == processGroupID,
                  let candidate = UserTaskProcessInspector.identity(
                    for: processID
                  ),
                  Darwin.getpgid(processID) == processGroupID,
                  UserTaskProcessInspector.identity(for: processID)
                    == candidate else {
                continue
            }
            knownIdentities[processID] = candidate
        }
    }

    private func reapIfExited() -> Bool {
        guard !didReap else { return true }
        var status: Int32 = 0
        let result = Darwin.waitpid(pid, &status, WNOHANG)
        if result == pid || (result == -1 && errno == ECHILD) {
            didReap = true
        }
        return didReap
    }
}

nonisolated private enum ControlledAgentLifecycleError:
    Error, CustomStringConvertible {
    case phaseTimeout(agent: String, phase: String, processIdentifier: pid_t)
    case invalidProcessGroup(
        agent: String,
        processIdentifier: pid_t,
        processGroupIdentifier: pid_t
    )
    case spawnFailure(agent: String, operation: String, code: Int32)

    var description: String {
        switch self {
        case .phaseTimeout(let agent, let phase, let processIdentifier):
            "controlled agent \(agent) timed out in \(phase) (pid \(processIdentifier))"
        case .invalidProcessGroup(
            let agent,
            let processIdentifier,
            let processGroupIdentifier
        ):
            "controlled agent \(agent) pid \(processIdentifier) launched in "
                + "unexpected process group \(processGroupIdentifier)"
        case .spawnFailure(let agent, let operation, let code):
            "controlled agent \(agent) failed \(operation) (errno \(code))"
        }
    }
}

nonisolated private func withMutableCStringArray<Result>(
    _ strings: [String],
    body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Result
) -> Result {
    var pointers = strings.map { strdup($0) }
    pointers.append(nil)
    defer {
        for case let pointer? in pointers {
            free(pointer)
        }
    }
    return pointers.withUnsafeMutableBufferPointer { buffer in
        guard let baseAddress = buffer.baseAddress else {
            preconditionFailure("C string array must contain a terminator")
        }
        return body(baseAddress)
    }
}
