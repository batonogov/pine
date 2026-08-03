//
//  AgentTaskRegistryTests.swift
//  PineTests
//
//  Durable cross-project agent task identity and persistence (issue #1302).
//

import Foundation
import Testing
@testable import Pine

@MainActor
@Suite("Agent Task Registry Tests")
struct AgentTaskRegistryTests {
    @Test("same agent type remains distinct across projects")
    func sameTypeAcrossProjects() throws {
        let registry = AgentTaskRegistry()
        let first = project("/tmp/pine-agent-first")
        let second = project("/tmp/pine-agent-second")
        let firstSession = makeSession(pid: 101, generation: 1)
        let secondSession = makeSession(pid: 202, generation: 2)

        registry.bridge(
            firstSession,
            replacing: nil,
            context: context(project: first, routeSeed: 1)
        )
        registry.bridge(
            secondSession,
            replacing: nil,
            context: context(project: second, routeSeed: 2)
        )

        let firstTaskID = try #require(
            registry.taskID(forSessionID: firstSession.id)
        )
        let secondTaskID = try #require(
            registry.taskID(forSessionID: secondSession.id)
        )
        #expect(firstTaskID != secondTaskID)
        #expect(registry.tasks.count == 2)
        #expect(registry.task(for: firstTaskID)?.project == first)
        #expect(registry.task(for: secondTaskID)?.project == second)
    }

    @Test("one project supports simultaneous routed tasks")
    func multipleTasksInProject() throws {
        let registry = AgentTaskRegistry()
        let identity = project("/tmp/pine-agent-shared")
        let first = makeSession(pid: 301, generation: 1)
        let second = makeSession(pid: 302, generation: 2)

        registry.bridge(
            first,
            replacing: nil,
            context: context(project: identity, routeSeed: 10)
        )
        registry.bridge(
            second,
            replacing: nil,
            context: context(project: identity, routeSeed: 20)
        )

        let firstTask = try #require(
            registry.task(forSessionID: first.id)
        )
        let secondTask = try #require(
            registry.task(forSessionID: second.id)
        )
        #expect(firstTask.id != secondTask.id)
        #expect(firstTask.route != secondTask.route)
        #expect(firstTask.runs.map(\.id) == [first.id])
        #expect(secondTask.runs.map(\.id) == [second.id])
    }

    @Test("identical terminal hints stay project scoped")
    func identicalTerminalHintsAreIsolated() throws {
        let registry = AgentTaskRegistry()
        let firstProject = project("/tmp/pine-agent-scope-a")
        let secondProject = project("/tmp/pine-agent-scope-b")
        let firstContext = context(project: firstProject, routeSeed: 25)
        let secondContext = context(project: secondProject, routeSeed: 25)
        let first = makeSession(pid: 351, generation: 1)
        let second = makeSession(pid: 352, generation: 1)
        registry.bridge(first, replacing: nil, context: firstContext)
        registry.bridge(second, replacing: nil, context: secondContext)

        registry.markTerminalClosed(
            terminalID: firstContext.route.terminalID,
            project: firstProject
        )

        #expect(
            registry.task(forSessionID: first.id)?.route.availability
                == .missing
        )
        #expect(
            registry.task(forSessionID: second.id)?.route.availability
                == .available
        )
    }

    @Test("repeated evidence keeps task and run identity")
    func stableIdentity() throws {
        let registry = AgentTaskRegistry()
        let identity = project("/tmp/pine-agent-stable")
        let route = context(project: identity, routeSeed: 30)
        let session = makeSession(pid: 401, generation: 1)

        registry.bridge(session, replacing: nil, context: route)
        let original = try #require(registry.task(forSessionID: session.id))
        session.state = .executing
        registry.bridge(session, replacing: session, context: route)
        let updated = try #require(registry.task(forSessionID: session.id))

        #expect(updated.id == original.id)
        #expect(updated.runs.count == 1)
        #expect(updated.runs[0].id == session.id)
        #expect(updated.runs[0].state == .executing)
    }

    @Test("manual discovery without process evidence is not joined")
    func missingProcessEvidenceFailsClosed() {
        let registry = AgentTaskRegistry()
        let session = AgentSession(agentType: .codex, state: .idle)
        registry.bridge(
            session,
            replacing: nil,
            context: context(
                project: project("/tmp/pine-agent-unproven"),
                routeSeed: 31
            )
        )

        #expect(registry.tasks.isEmpty)
        #expect(registry.taskID(forSessionID: session.id) == nil)
    }

    @Test("same PID replacement cannot inherit a discovered task")
    func pidReuseStartsNewTask() throws {
        let registry = AgentTaskRegistry()
        let identity = project("/tmp/pine-agent-reuse")
        let route = context(project: identity, routeSeed: 40)
        let first = makeSession(
            pid: 501,
            generation: 4,
            start: "Mon Aug 3 10:00:00 2026"
        )
        registry.bridge(first, replacing: nil, context: route)

        first.applyLiveness(.terminated)
        first.state = .done
        let replacement = makeSession(
            pid: 501,
            generation: 4,
            start: "Mon Aug 3 10:05:00 2026"
        )
        registry.bridge(replacement, replacing: first, context: route)

        let task = try #require(
            registry.task(forSessionID: replacement.id)
        )
        #expect(task.runs.count == 1)
        #expect(task.runs[0].id == replacement.id)
        #expect(
            registry.taskID(forSessionID: first.id)
                != registry.taskID(forSessionID: replacement.id)
        )
    }

    @Test("explicit resume reserves before detector appends a fresh run")
    func explicitResumeStartsRun() throws {
        let registry = AgentTaskRegistry()
        let identity = project("/tmp/pine-agent-resume")
        let originalContext = context(
            project: identity,
            routeSeed: 50,
            origin: .pineLaunched
        )
        let original = makeSession(pid: 601, generation: 1)
        guard case .reserved(let launch) = registry.preparePineLaunch(
            descriptor: AgentDescriptor(
                agentType: original.agentType,
                launchExecutable: "claude"
            ),
            context: originalContext,
            title: nil,
            objective: nil
        ) else {
            Issue.record("initial reservation was rejected")
            return
        }
        #expect(registry.armLaunch(launch))
        registry.bridge(
            original,
            replacing: nil,
            context: originalContext,
            reservation: launch
        )
        original.applyLiveness(.terminated)
        original.state = .done
        registry.refresh(sessions: [original])

        let taskID = try #require(
            registry.historicalTask(forSessionID: original.id)?.id
        )
        let resumed = makeSession(pid: 602, generation: 2)
        let resumedContext = AgentTaskBridgeContext(
            project: identity,
            route: originalContext.route,
            origin: .pineLaunched,
            observedAt: Date(timeIntervalSince1970: 0)
        )
        guard case .reserved(let reservation) = registry.prepareResume(
            taskID: taskID,
            context: resumedContext
        ) else {
            Issue.record("resume reservation was rejected")
            return
        }
        #expect(registry.armLaunch(reservation))
        registry.bridge(
            resumed,
            replacing: original,
            context: resumedContext,
            reservation: reservation
        )

        let task = try #require(registry.task(for: taskID))
        #expect(task.runs.map(\.id) == [original.id, resumed.id])
        #expect(task.route == resumedContext.route)
        #expect(task.lifecycle == .active)
    }

    @Test("Pine launch reservation bridges to detector session")
    func pineLaunchBridgesDetector() throws {
        let registry = AgentTaskRegistry()
        let identity = project("/tmp/pine-agent-launched")
        let baseContext = context(
            project: identity, routeSeed: 60, origin: .pineLaunched
        )
        let launchContext = AgentTaskBridgeContext(
            project: identity,
            route: baseContext.route,
            origin: .pineLaunched,
            observedAt: Date(timeIntervalSince1970: 0)
        )
        let result = registry.preparePineLaunch(
            descriptor: AgentDescriptor(agentType: .codex),
            context: launchContext,
            title: "Review",
            objective: "Inspect the patch"
        )
        guard case .reserved(let reservation) = result else {
            Issue.record("launch reservation was rejected")
            return
        }
        let detected = makeSession(
            pid: 701,
            generation: 1,
            agentType: .codex
        )

        registry.bridge(
            detected,
            replacing: nil,
            context: launchContext,
            reservation: reservation
        )
        #expect(registry.task(for: reservation.taskID)?.runs.isEmpty == true)
        #expect(registry.isLaunchPending(reservation))
        #expect(registry.armLaunch(reservation))
        registry.bridge(
            detected,
            replacing: nil,
            context: launchContext,
            reservation: reservation
        )

        let taskID = reservation.taskID
        let task = try #require(registry.task(for: taskID))
        #expect(task.origin == .pineLaunched)
        #expect(task.title == "Review")
        #expect(task.objective == "Inspect the patch")
        #expect(task.runs.map(\.id) == [detected.id])
        #expect(registry.taskID(forSessionID: detected.id) == taskID)
    }

    @Test("untokened polling preserves Pine intent for its launch owner")
    func untokenedPollingPreservesReservation() throws {
        let registry = AgentTaskRegistry()
        let identity = project("/tmp/pine-agent-token-race")
        let launchContext = context(
            project: identity,
            routeSeed: 61,
            origin: .pineLaunched
        )
        guard case .reserved(let reservation) = registry.preparePineLaunch(
            descriptor: AgentDescriptor(agentType: .codex),
            context: launchContext,
            title: nil,
            objective: nil
        ) else {
            Issue.record("launch reservation was rejected")
            return
        }
        #expect(registry.armLaunch(reservation))
        #expect(
            registry.task(for: reservation.taskID)?.route.availability
                == .missing
        )
        let unrelated = makeSession(
            pid: 702,
            generation: 1,
            agentType: .codex
        )
        registry.bridge(unrelated, replacing: nil, context: launchContext)

        #expect(registry.task(for: reservation.taskID)?.runs.isEmpty == true)
        #expect(registry.task(forSessionID: unrelated.id) == nil)
        registry.bridge(
            unrelated,
            replacing: nil,
            context: launchContext,
            reservation: reservation
        )
        #expect(registry.taskID(forSessionID: unrelated.id) == reservation.taskID)
    }

    @Test("pre-existing process cannot consume or destroy launch intent")
    func preexistingProcessPreservesReservation() throws {
        let registry = AgentTaskRegistry()
        let identity = project("/tmp/pine-agent-process-boundary")
        let capturedAt = Date(timeIntervalSince1970: 1_785_672_000)
        let launchContext = AgentTaskBridgeContext(
            project: identity,
            route: context(project: identity, routeSeed: 615).route,
            origin: .pineLaunched,
            observedAt: capturedAt
        )
        guard case .reserved(let reservation) = registry.preparePineLaunch(
            descriptor: AgentDescriptor(agentType: .claudeCode),
            context: launchContext,
            title: nil,
            objective: nil,
            boundary: AgentTaskLaunchBoundary(
                generationFloor: 5,
                capturedAt: capturedAt
            )
        ) else {
            Issue.record("launch reservation was rejected")
            return
        }
        #expect(registry.armLaunch(reservation))
        let preexisting = makeSession(
            pid: 702,
            generation: 6,
            start: "Sat Aug 1 10:00:00 2026",
            preciseStartedAt: capturedAt.addingTimeInterval(-86_400)
        )
        registry.bridge(
            preexisting,
            replacing: nil,
            context: launchContext,
            reservation: reservation
        )
        #expect(registry.task(for: reservation.taskID)?.runs.isEmpty == true)

        let boundaryEqual = makeSession(
            pid: 703,
            generation: 7,
            start: "Sun Aug 2 10:00:00 2026",
            preciseStartedAt: capturedAt
        )
        registry.bridge(
            boundaryEqual,
            replacing: preexisting,
            context: launchContext,
            reservation: reservation
        )
        #expect(registry.task(for: reservation.taskID)?.runs.isEmpty == true)

        let launched = makeSession(
            pid: 704,
            generation: 8,
            start: "Mon Aug 3 10:00:00 2026",
            preciseStartedAt: capturedAt.addingTimeInterval(86_400)
        )
        registry.bridge(
            launched,
            replacing: boundaryEqual,
            context: launchContext,
            reservation: reservation
        )
        #expect(registry.taskID(forSessionID: launched.id) == reservation.taskID)
    }

    @Test("launch claim requires authoritative process start evidence")
    func launchClaimRequiresAuthoritativeStart() throws {
        let registry = AgentTaskRegistry()
        let identity = project("/tmp/pine-agent-authoritative-start")
        let launchContext = context(
            project: identity,
            routeSeed: 616,
            origin: .pineLaunched
        )
        guard case .reserved(let reservation) = registry.preparePineLaunch(
            descriptor: AgentDescriptor(agentType: .claudeCode),
            context: launchContext,
            title: nil,
            objective: nil,
            boundary: AgentTaskLaunchBoundary(
                generationFloor: 1,
                capturedAt: Date(timeIntervalSince1970: 100)
            )
        ) else {
            Issue.record("reservation was rejected")
            return
        }
        #expect(registry.armLaunch(reservation))
        let session = makeSession(
            pid: 705,
            generation: 2,
            preciseStartedAt: Date(timeIntervalSince1970: 200),
            startIsAuthoritative: false
        )

        registry.bridge(
            session,
            replacing: nil,
            context: launchContext,
            reservation: reservation
        )

        #expect(registry.task(for: reservation.taskID)?.runs.isEmpty == true)
        #expect(registry.task(forSessionID: session.id) == nil)
    }

    @Test("claims expire without a later registry mutation")
    func claimExpiresWithoutPolling() async throws {
        let registry = AgentTaskRegistry(claimTTL: .milliseconds(1))
        let identity = project("/tmp/pine-agent-expiry")
        let launchContext = context(
            project: identity,
            routeSeed: 651,
            origin: .pineLaunched
        )
        guard case .reserved(let reservation) = registry.preparePineLaunch(
            descriptor: AgentDescriptor(agentType: .claudeCode),
            context: launchContext,
            title: nil,
            objective: nil
        ) else {
            Issue.record("launch reservation was rejected")
            return
        }

        try await ContinuousClock().sleep(for: .milliseconds(50))
        #expect(registry.task(for: reservation.taskID) == nil)
    }

    @Test("a real reservation is single use")
    func reservationCannotBeConsumedTwice() throws {
        let registry = AgentTaskRegistry()
        let identity = project("/tmp/pine-agent-token-once")
        let launchContext = context(
            project: identity,
            routeSeed: 62,
            origin: .pineLaunched
        )
        guard case .reserved(let reservation) = registry.preparePineLaunch(
            descriptor: AgentDescriptor(agentType: .codex),
            context: launchContext,
            title: nil,
            objective: nil
        ) else {
            Issue.record("launch reservation was rejected")
            return
        }
        #expect(registry.armLaunch(reservation))
        #expect(!registry.armLaunch(reservation))
        let first = makeSession(pid: 703, generation: 1, agentType: .codex)
        registry.bridge(
            first,
            replacing: nil,
            context: launchContext,
            reservation: reservation
        )
        let duplicate = makeSession(pid: 704, generation: 2, agentType: .codex)
        registry.bridge(
            duplicate,
            replacing: first,
            context: launchContext,
            reservation: reservation
        )
        let task = try #require(registry.task(for: reservation.taskID))
        #expect(task.runs.map(\.id) == [first.id])
        #expect(registry.taskID(forSessionID: duplicate.id) == nil)
    }

    @Test("claims reject another real token and clean both initial tasks")
    func wrongRealTokenCancelsClaims() {
        let registry = AgentTaskRegistry()
        let identity = project("/tmp/pine-agent-wrong-token")
        let first = context(
            project: identity, routeSeed: 63, origin: .pineLaunched
        )
        let second = context(
            project: identity, routeSeed: 64, origin: .pineLaunched
        )
        guard case .reserved(let firstClaim) = registry.preparePineLaunch(
            descriptor: AgentDescriptor(agentType: .codex),
            context: first, title: nil, objective: nil
        ), case .reserved(let secondClaim) = registry.preparePineLaunch(
            descriptor: AgentDescriptor(agentType: .codex),
            context: second, title: nil, objective: nil
        ) else {
            Issue.record("reservations were rejected")
            return
        }
        #expect(registry.armLaunch(firstClaim))
        #expect(registry.armLaunch(secondClaim))
        registry.bridge(
            makeSession(pid: 705, generation: 1, agentType: .codex),
            replacing: nil,
            context: first,
            reservation: secondClaim
        )
        #expect(registry.task(for: firstClaim.taskID) == nil)
        #expect(registry.task(for: secondClaim.taskID) == nil)
    }

    @Test("done or stale evidence cannot reserve resume")
    func resumeRequiresTerminatedPineTail() throws {
        let registry = AgentTaskRegistry()
        let identity = project("/tmp/pine-agent-resume-negative")
        let launchContext = context(
            project: identity, routeSeed: 65, origin: .pineLaunched
        )
        guard case .reserved(let claim) = registry.preparePineLaunch(
            descriptor: AgentDescriptor(agentType: .claudeCode),
            context: launchContext, title: nil, objective: nil
        ) else {
            Issue.record("reservation was rejected")
            return
        }
        #expect(registry.armLaunch(claim))
        let session = makeSession(pid: 706, generation: 1)
        registry.bridge(
            session, replacing: nil, context: launchContext,
            reservation: claim
        )
        session.state = .done
        registry.refresh(sessions: [session])
        #expect(
            registry.prepareResume(taskID: claim.taskID, context: launchContext)
                == .rejected
        )
        session.applyLiveness(.stale)
        registry.refresh(sessions: [session])
        #expect(
            registry.prepareResume(taskID: claim.taskID, context: launchContext)
                == .rejected
        )
        #expect(registry.taskID(forSessionID: session.id) == claim.taskID)
    }

    @Test("cancelled termination restores pending launch ownership")
    func terminationRestoresPendingLaunch() throws {
        let registry = AgentTaskRegistry()
        let identity = project("/tmp/pine-agent-quit-rollback")
        let launchContext = context(
            project: identity, routeSeed: 66, origin: .pineLaunched
        )
        guard case .reserved(let claim) = registry.preparePineLaunch(
            descriptor: AgentDescriptor(agentType: .codex),
            context: launchContext, title: nil, objective: nil
        ) else {
            Issue.record("reservation was rejected")
            return
        }
        #expect(registry.armLaunch(claim))
        let before = try #require(registry.task(for: claim.taskID))
        registry.prepareForApplicationTermination(
            at: before.updatedAt.addingTimeInterval(10)
        )
        #expect(registry.task(for: claim.taskID) != nil)
        #expect(registry.isLaunchPending(claim))
        registry.cancelApplicationTermination()
        #expect(registry.isLaunchPending(claim))
        #expect(registry.task(for: claim.taskID)?.updatedAt == before.updatedAt)
        let observed = makeSession(pid: 707, generation: 1, agentType: .codex)
        registry.bridge(
            observed,
            replacing: nil,
            context: launchContext,
            reservation: claim
        )
        #expect(registry.taskID(forSessionID: observed.id) == claim.taskID)
    }

    @Test("pending launch follows pane move and background state")
    func pendingLaunchRouteCanMove() throws {
        let registry = AgentTaskRegistry()
        let identity = project("/tmp/pine-agent-pending-move")
        let initial = context(
            project: identity,
            routeSeed: 667,
            origin: .pineLaunched
        )
        let boundary = Date(timeIntervalSince1970: 1_785_672_000.75)
        guard case .reserved(let reservation) = registry.preparePineLaunch(
            descriptor: AgentDescriptor(agentType: .claudeCode),
            context: initial,
            title: nil,
            objective: nil,
            boundary: AgentTaskLaunchBoundary(
                generationFloor: 4,
                capturedAt: boundary
            )
        ) else {
            Issue.record("reservation was rejected")
            return
        }
        #expect(registry.armLaunch(reservation))
        let movedRoute = AgentTaskRoute(
            paneID: uuid(668),
            tabID: initial.route.tabID,
            terminalID: initial.route.terminalID
        )
        registry.updateRoute(
            terminalID: initial.route.terminalID,
            project: identity,
            route: movedRoute
        )
        registry.setWindowOpen(false, projectPath: identity.canonicalProjectPath)
        let moved = AgentTaskBridgeContext(
            project: identity,
            route: AgentTaskRoute(
                paneID: movedRoute.paneID,
                tabID: movedRoute.tabID,
                terminalID: movedRoute.terminalID,
                availability: .background
            ),
            origin: .pineLaunched,
            observedAt: boundary
        )
        let observed = makeSession(
            pid: 708,
            generation: 5,
            start: processStartIdentifier(boundary),
            preciseStartedAt: boundary.addingTimeInterval(0.001)
        )

        registry.bridge(
            observed,
            replacing: nil,
            context: moved,
            reservation: reservation
        )
        let task = try #require(registry.task(for: reservation.taskID))
        #expect(task.runs.last?.id == observed.id)
        #expect(task.route == moved.route)
    }

    @Test("stale evidence clears attention without changing state")
    func staleClearsAttention() throws {
        let registry = AgentTaskRegistry()
        let identity = project("/tmp/pine-agent-stale")
        let session = makeSession(
            pid: 801,
            generation: 1,
            state: .waitingInput
        )
        registry.bridge(
            session,
            replacing: nil,
            context: context(project: identity, routeSeed: 70)
        )
        var task = try #require(registry.task(forSessionID: session.id))
        #expect(task.attention == .waitingInput)
        #expect(task.isUnread)

        session.applyLiveness(.stale)
        registry.refresh(sessions: [session])
        task = try #require(registry.historicalTask(forSessionID: session.id))
        #expect(task.runs.last?.state == .waitingInput)
        #expect(task.runs.last?.liveness == .stale)
        #expect(task.attention == .none)
    }

    @Test("route changes retain task identity")
    func canonicalRouteUpdate() throws {
        let registry = AgentTaskRegistry()
        let identity = project("/tmp/../tmp/pine-agent-route")
        let firstContext = context(project: identity, routeSeed: 80)
        let session = makeSession(pid: 901, generation: 1)
        registry.bridge(session, replacing: nil, context: firstContext)
        let taskID = try #require(
            registry.taskID(forSessionID: session.id)
        )

        let movedContext = AgentTaskBridgeContext(
            project: identity,
            route: AgentTaskRoute(
                paneID: uuid(81),
                tabID: firstContext.route.tabID,
                terminalID: firstContext.route.terminalID
            ),
            origin: .discoveredInTerminal
        )
        registry.bridge(session, replacing: session, context: movedContext)

        let task = try #require(registry.task(for: taskID))
        #expect(task.id == taskID)
        #expect(task.route == movedContext.route)
        #expect(task.project.canonicalProjectPath == "/tmp/pine-agent-route")
    }

    @Test("legacy session IDs still bridge Activity and History")
    func legacyBridgePreservesLinks() throws {
        let registry = AgentTaskRegistry()
        let session = makeSession(pid: 1_001, generation: 1)
        let activity = AgentActivityStore()
        let history = AgentHistoryStore()
        let action = AgentAction(
            sessionID: session.id,
            agentType: session.agentType,
            kind: .command,
            status: .completed,
            summary: "legacy"
        )
        activity.record(action)

        registry.bridge(
            session,
            replacing: nil,
            context: context(
                project: project("/tmp/pine-agent-migration"),
                routeSeed: 90
            )
        )
        session.applyLiveness(.terminated)
        session.state = .done
        history.finalize(
            session: session,
            summary: "legacy",
            affectedRelativePaths: []
        )

        let task = try #require(registry.task(forSessionID: session.id))
        #expect(task.runs.first?.id == session.id)
        #expect(activity.actions(forSession: session.id) == [action])
        #expect(history.entries.first?.sessionID == session.id)
    }

    @Test("pane close terminates route but window close does not")
    func terminalAndWindowLifecycle() throws {
        let registry = AgentTaskRegistry()
        let identity = project("/tmp/pine-agent-lifecycle")
        let bridgeContext = context(project: identity, routeSeed: 100)
        let session = makeSession(pid: 1_101, generation: 1)
        registry.bridge(session, replacing: nil, context: bridgeContext)

        registry.setWindowOpen(false, projectPath: identity.canonicalProjectPath)
        var task = try #require(registry.task(forSessionID: session.id))
        #expect(task.route.availability == .background)
        #expect(task.runs.last?.liveness == .live)

        registry.markTerminalClosed(
            terminalID: bridgeContext.route.terminalID,
            project: identity,
            at: Date(timeIntervalSince1970: 2_000)
        )
        task = try #require(registry.historicalTask(forSessionID: session.id))
        #expect(task.route.availability == .missing)
        #expect(task.runs.last?.liveness == .terminated)
        #expect(task.lifecycle == .paused)
        #expect(task.attention == .none)
    }

    @Test("launch authority accepts only an exact canonical executable token")
    func exactAgentLaunchCommandClassification() {
        #expect(
            TerminalManager.exactAgentLaunchDescriptor(for: "codex")
                == AgentDescriptor(
                    agentType: .codex,
                    launchExecutable: "codex"
                )
        )
        for untrusted in [
            " codex", "codex ", "codex\n", "CODEX", "codex --help",
            "env codex", "codex; echo injected", "./codex",
        ] {
            #expect(TerminalManager.exactAgentLaunchDescriptor(for: untrusted) == nil)
        }
    }

    @Test("terminal launch owner carries reservation to exact new process")
    func productionLaunchReservationHandoff() async throws {
        let fixture = try PersistenceFixture()
        defer { fixture.cleanup() }
        let store = AgentTaskMetadataStore(storageRoot: fixture.storage)
        let taskRegistry = AgentTaskRegistry(persistence: store)
        let projectRegistry = ProjectRegistry(agentTasks: taskRegistry)
        let manager = try #require(
            projectRegistry.projectManager(for: fixture.project)
        )
        #expect(await taskRegistry.flushPersistence() == .saved)
        let pane = manager.paneManager.createTerminalPaneAtBottom(
            workingDirectory: fixture.project
        )
        let state = try #require(
            manager.paneManager.terminalState(for: pane)
        )
        let tab = try #require(state.terminalTabs.first)
        guard case .reserved(let reservation) = manager.terminal.prepareAgentLaunch(
            in: tab,
            descriptor: AgentDescriptor(
                agentType: .claudeCode,
                launchExecutable: "claude"
            ),
            title: nil,
            objective: nil
        ) else {
            Issue.record("terminal launch reservation was rejected")
            return
        }
        #expect(taskRegistry.armLaunch(reservation))
        let now = Date()
        let preexisting = makeSession(
            pid: 1_109,
            generation: 1,
            start: processStartIdentifier(now.addingTimeInterval(-60)),
            preciseStartedAt: now.addingTimeInterval(-60)
        )
        manager.terminal.bridgeAgentSession(
            preexisting,
            replacing: nil,
            in: tab
        )
        #expect(taskRegistry.task(for: reservation.taskID)?.runs.isEmpty == true)

        let launched = makeSession(
            pid: 1_110,
            generation: 2,
            start: processStartIdentifier(now),
            preciseStartedAt: now.addingTimeInterval(0.001)
        )
        manager.terminal.bridgeAgentSession(
            launched,
            replacing: preexisting,
            in: tab
        )
        #expect(
            taskRegistry.taskID(forSessionID: launched.id)
                == reservation.taskID
        )
        #expect(
            await projectRegistry.resolveAgentTaskRoute(reservation.taskID)?.paneID
                == pane.id
        )

        launched.applyLiveness(.terminated)
        manager.terminal.bridgeAgentSession(
            launched,
            replacing: launched,
            in: tab
        )
        tab.agentSession = nil
        #expect(
            await projectRegistry.resolveAgentTaskRoute(
                reservation.taskID,
                targetTerminalID: tab.id
            )?.terminalID == tab.id
        )
        guard case .reserved(let resumeReservation) = manager.terminal.prepareAgentResume(
            taskID: reservation.taskID,
            in: tab
        ) else {
            Issue.record("production resume reservation was rejected")
            return
        }
        #expect(taskRegistry.armLaunch(resumeReservation))
        let resumed = makeSession(
            pid: 1_111,
            generation: 3,
            start: processStartIdentifier(now.addingTimeInterval(1)),
            preciseStartedAt: now.addingTimeInterval(1.001)
        )
        manager.terminal.bridgeAgentSession(
            resumed,
            replacing: nil,
            in: tab
        )
        #expect(taskRegistry.taskID(forSessionID: resumed.id) == reservation.taskID)
        #expect(taskRegistry.task(for: reservation.taskID)?.runs.count == 2)
    }

    @Test("failed PTY write cancels live launch reservation before expiry")
    func failedWriteCancelsLaunchReservation() async throws {
        let fixture = try PersistenceFixture()
        defer { fixture.cleanup() }
        let taskRegistry = AgentTaskRegistry(claimTTL: .seconds(1))
        let projectRegistry = ProjectRegistry(agentTasks: taskRegistry)
        let manager = try #require(
            projectRegistry.projectManager(for: fixture.project)
        )
        let pane = manager.paneManager.createTerminalPaneAtBottom(
            workingDirectory: fixture.project
        )
        let state = try #require(
            manager.paneManager.terminalState(for: pane)
        )
        let tab = try #require(state.terminalTabs.first)
        let descriptor = AgentDescriptor(
            agentType: .codex,
            launchExecutable: "codex"
        )

        let failed = await manager.terminal.launchAgentCommandForTesting(
            "codex",
            descriptor: descriptor,
            in: tab
        ) {
            false
        }
        #expect(failed == .rejected)
        #expect(taskRegistry.tasks.isEmpty)

        var retryWriteCalled = false
        let retry = await manager.terminal.launchAgentCommandForTesting(
            "codex",
            descriptor: descriptor,
            in: tab
        ) {
            retryWriteCalled = true
            return true
        }
        #expect(retryWriteCalled)
        guard case .reserved = retry else {
            Issue.record("failed write left the terminal reservation occupied")
            return
        }
        manager.terminal.cancelAgentLaunch(in: tab)
    }

    @Test("stale successful PTY acknowledgement cannot arm launch authority")
    func staleAcknowledgementCannotArmLaunchAuthority() async throws {
        let fixture = try PersistenceFixture()
        defer { fixture.cleanup() }
        let taskRegistry = AgentTaskRegistry(claimTTL: .milliseconds(50))
        let projectRegistry = ProjectRegistry(agentTasks: taskRegistry)
        let manager = try #require(
            projectRegistry.projectManager(for: fixture.project)
        )
        let pane = manager.paneManager.createTerminalPaneAtBottom(
            workingDirectory: fixture.project
        )
        let state = try #require(
            manager.paneManager.terminalState(for: pane)
        )
        let tab = try #require(state.terminalTabs.first)
        let descriptor = AgentDescriptor(
            agentType: .codex,
            launchExecutable: "codex"
        )
        let gate = AgentLaunchWriteGate()
        let launch = Task { @MainActor in
            await manager.terminal.launchAgentCommandForTesting(
                "codex",
                descriptor: descriptor,
                in: tab
            ) {
                await gate.waitForCompletion()
            }
        }
        #expect(await gate.waitUntilStarted())
        let dormantTaskID = try #require(taskRegistry.tasks.first?.id)
        let observed = makeSession(
            pid: 1_109,
            generation: 1,
            preciseStartedAt: Date().addingTimeInterval(60),
            agentType: .codex
        )
        manager.terminal.bridgeAgentSession(
            observed,
            replacing: nil,
            in: tab
        )
        #expect(taskRegistry.task(for: dormantTaskID)?.runs.isEmpty == true)
        try await ContinuousClock().sleep(for: .milliseconds(100))
        #expect(taskRegistry.task(for: dormantTaskID) == nil)

        var duplicateWriteCalled = false
        let duplicate = await manager.terminal.launchAgentCommandForTesting(
            "codex",
            descriptor: descriptor,
            in: tab
        ) {
            duplicateWriteCalled = true
            return true
        }
        #expect(duplicate == .rejected)
        #expect(!duplicateWriteCalled)

        gate.finish(true)
        #expect(await launch.value == .sentWithoutReservation)
        #expect(taskRegistry.task(for: dormantTaskID) == nil)

        let armed = await manager.terminal.launchAgentCommandForTesting(
            "codex",
            descriptor: descriptor,
            in: tab
        ) {
            true
        }
        guard case .reserved(let reservation) = armed else {
            Issue.record("acknowledged launch was not armed")
            return
        }
        let launched = makeSession(
            pid: 1_110,
            generation: 2,
            preciseStartedAt: Date().addingTimeInterval(120),
            agentType: .codex
        )
        manager.terminal.bridgeAgentSession(
            launched,
            replacing: observed,
            in: tab
        )
        #expect(
            taskRegistry.taskID(forSessionID: launched.id)
                == reservation.taskID
        )
        #expect(!taskRegistry.armLaunch(reservation))
    }

    @Test("closing a dormant launch cancels its authority")
    func closingDormantLaunchCancelsClaim() throws {
        let registry = AgentTaskRegistry()
        let identity = project("/tmp/pine-agent-dormant-close")
        let launchContext = context(
            project: identity,
            routeSeed: 669,
            origin: .pineLaunched
        )
        guard case .reserved(let reservation) = registry.preparePineLaunch(
            descriptor: AgentDescriptor(
                agentType: .claudeCode,
                launchExecutable: "claude"
            ),
            context: launchContext,
            title: nil,
            objective: nil
        ) else {
            Issue.record("reservation was rejected")
            return
        }

        registry.markTerminalClosed(
            terminalID: launchContext.route.terminalID,
            project: identity
        )

        #expect(!registry.isLaunchPending(reservation))
        #expect(!registry.armLaunch(reservation))
        #expect(registry.task(for: reservation.taskID) == nil)
    }

    @Test("unacknowledged launch is never published")
    func unacknowledgedLaunchIsNotPersisted() async throws {
        let identity = project("/tmp/pine-agent-dormant-persistence")
        let store = ScriptedAgentTaskStore()
        let registry = AgentTaskRegistry(persistence: store)
        registry.registerProject(identity)
        #expect(await registry.flushPersistence() == .saved)
        let callsBeforeReservation = await store.saveCallCount()
        let launchContext = context(
            project: identity,
            routeSeed: 670,
            origin: .pineLaunched
        )
        guard case .reserved(let reservation) = registry.preparePineLaunch(
            descriptor: AgentDescriptor(
                agentType: .claudeCode,
                launchExecutable: "claude"
            ),
            context: launchContext,
            title: nil,
            objective: nil
        ) else {
            Issue.record("reservation was rejected")
            return
        }

        #expect(await registry.flushPersistence() == .saved)
        #expect(await store.saveCallCount() == callsBeforeReservation)

        registry.prepareForApplicationTermination()
        #expect(await registry.flushPersistence() == .saved)
        #expect(await store.savedTaskCounts().last == 0)
        #expect(await registry.cancelApplicationTerminationAndFlush())
        #expect(await store.savedTaskCounts().last == 0)

        registry.cancelLaunch(reservation)
        #expect(await registry.flushPersistence() == .saved)
        #expect(await store.savedTaskCounts().last == 0)
    }

    @Test("acknowledged initial launch is not published before observation")
    func armedInitialLaunchIsNotPersisted() async throws {
        let identity = project("/tmp/pine-agent-armed-persistence")
        let store = ScriptedAgentTaskStore()
        let registry = AgentTaskRegistry(persistence: store)
        registry.registerProject(identity)
        #expect(await registry.flushPersistence() == .saved)
        let launchContext = context(
            project: identity,
            routeSeed: 671,
            origin: .pineLaunched
        )
        guard case .reserved(let reservation) = registry.preparePineLaunch(
            descriptor: AgentDescriptor(
                agentType: .claudeCode,
                launchExecutable: "claude"
            ),
            context: launchContext,
            title: nil,
            objective: nil
        ) else {
            Issue.record("reservation was rejected")
            return
        }
        let callsBeforeArm = await store.saveCallCount()

        #expect(registry.armLaunch(reservation))
        #expect(await registry.flushPersistence() == .saved)
        #expect(await store.saveCallCount() == callsBeforeArm)

        registry.prepareForApplicationTermination()
        #expect(await registry.flushPersistence() == .saved)
        #expect(await store.savedTaskCounts().last == 0)
        #expect(await registry.cancelApplicationTerminationAndFlush())
        #expect(await store.savedTaskCounts().last == 0)

        registry.cancelLaunch(reservation)
        #expect(await registry.flushPersistence() == .saved)
        #expect(await store.savedTaskCounts().last == 0)
    }

    @Test("successful launch acknowledgement survives Quit rollback")
    func acknowledgedLaunchSurvivesTerminationRollback() async throws {
        let fixture = try PersistenceFixture()
        defer { fixture.cleanup() }
        let taskRegistry = AgentTaskRegistry(claimTTL: .seconds(1))
        let projectRegistry = ProjectRegistry(agentTasks: taskRegistry)
        let manager = try #require(
            projectRegistry.projectManager(for: fixture.project)
        )
        #expect(await taskRegistry.flushPersistence() == .saved)
        let pane = manager.paneManager.createTerminalPaneAtBottom(
            workingDirectory: fixture.project
        )
        let state = try #require(
            manager.paneManager.terminalState(for: pane)
        )
        let tab = try #require(state.terminalTabs.first)
        let descriptor = AgentDescriptor(
            agentType: .codex,
            launchExecutable: "codex"
        )
        let gate = AgentLaunchWriteGate()
        let launch = Task { @MainActor in
            await manager.terminal.launchAgentCommandForTesting(
                "codex",
                descriptor: descriptor,
                in: tab
            ) {
                await gate.waitForCompletion()
            }
        }
        #expect(await gate.waitUntilStarted())

        projectRegistry.freezeAgentTasksForTermination()
        taskRegistry.prepareForApplicationTermination()
        gate.finish(true)
        guard case .reserved(let reservation) = await launch.value else {
            Issue.record("successful write lost its reservation during Quit")
            return
        }
        #expect(await projectRegistry.cancelAgentTaskTermination())
        #expect(taskRegistry.isLaunchPending(reservation))

        let launched = makeSession(
            pid: 1_495,
            generation: 2,
            preciseStartedAt: Date().addingTimeInterval(60),
            agentType: .codex
        )
        manager.terminal.bridgeAgentSession(
            launched,
            replacing: nil,
            in: tab
        )
        #expect(taskRegistry.taskID(forSessionID: launched.id) == reservation.taskID)
    }

    @Test("expired local reservation permits a new terminal launch")
    func expiredTerminalReservationCanBeReplaced() async throws {
        let fixture = try PersistenceFixture()
        defer { fixture.cleanup() }
        let taskRegistry = AgentTaskRegistry(claimTTL: .milliseconds(1))
        let projectRegistry = ProjectRegistry(agentTasks: taskRegistry)
        let manager = try #require(
            projectRegistry.projectManager(for: fixture.project)
        )
        #expect(await taskRegistry.flushPersistence() == .saved)
        let pane = manager.paneManager.createTerminalPaneAtBottom(
            workingDirectory: fixture.project
        )
        let state = try #require(
            manager.paneManager.terminalState(for: pane)
        )
        let tab = try #require(state.terminalTabs.first)
        guard case .reserved(let expired) = manager.terminal.prepareAgentLaunch(
            in: tab,
            descriptor: AgentDescriptor(agentType: .codex)
        ) else {
            Issue.record("first reservation was rejected")
            return
        }
        try await ContinuousClock().sleep(for: .milliseconds(10))
        #expect(!taskRegistry.isLaunchPending(expired))

        guard case .reserved = manager.terminal.prepareAgentLaunch(
            in: tab,
            descriptor: AgentDescriptor(agentType: .codex)
        ) else {
            Issue.record("expired local slot was not reconciled")
            return
        }
        manager.terminal.cancelAgentLaunch(in: tab)
    }

    @Test("project and pane wiring moves then closes a task route")
    func productionPaneLifecycleWiring() async throws {
        let fixture = try PersistenceFixture()
        defer { fixture.cleanup() }
        let store = AgentTaskMetadataStore(storageRoot: fixture.storage)
        let taskRegistry = AgentTaskRegistry(persistence: store)
        let projectRegistry = ProjectRegistry(agentTasks: taskRegistry)
        let manager = try #require(
            projectRegistry.projectManager(for: fixture.project)
        )
        await taskRegistry.flushPersistence()
        let firstPane = manager.paneManager.createTerminalPaneAtBottom(
            workingDirectory: fixture.project
        )
        let firstState = try #require(
            manager.paneManager.terminalState(for: firstPane)
        )
        let tab = try #require(firstState.terminalTabs.first)
        let session = makeSession(pid: 1_111, generation: 1)
        manager.terminal.bridgeAgentSession(
            session,
            replacing: nil,
            in: tab
        )
        tab.agentSession = session
        let historicalTaskID = try #require(
            taskRegistry.taskID(forSessionID: session.id)
        )
        #expect(
            await projectRegistry.resolveAgentTaskRoute(historicalTaskID)?.paneID
                == firstPane.id
        )
        session.applyLiveness(.terminated)
        session.state = .done
        let replacement = makeSession(pid: 1_112, generation: 2)
        manager.terminal.bridgeAgentSession(
            replacement,
            replacing: session,
            in: tab
        )
        tab.agentSession = replacement
        let taskID = try #require(
            taskRegistry.taskID(forSessionID: replacement.id)
        )
        #expect(taskID != historicalTaskID)
        #expect(
            taskRegistry.task(for: historicalTaskID)?.route.availability
                == .missing
        )
        let secondPane = try #require(manager.paneManager.createTerminalPane(
            relativeTo: firstPane,
            axis: .horizontal,
            workingDirectory: fixture.project
        ))

        #expect(manager.paneManager.moveTerminalTab(
            tab.id,
            from: firstPane,
            to: secondPane
        ))
        #expect(taskRegistry.task(for: taskID)?.route.paneID == secondPane.id)
        #expect(
            await projectRegistry.resolveAgentTaskRoute(taskID)?.paneID
                == secondPane.id
        )
        manager.paneManager.removePane(secondPane)
        let task = try #require(taskRegistry.task(for: taskID))
        #expect(task.route.availability == .missing)
        #expect(task.attention == .none)
        #expect(await projectRegistry.resolveAgentTaskRoute(taskID) == nil)
    }

    @Test("duplicate live tab ownership fails route resolution closed")
    func duplicateLiveTabRouteIsRejected() async throws {
        let fixture = try PersistenceFixture()
        defer { fixture.cleanup() }
        let taskRegistry = AgentTaskRegistry()
        let projectRegistry = ProjectRegistry(agentTasks: taskRegistry)
        let manager = try #require(
            projectRegistry.projectManager(for: fixture.project)
        )
        let firstPane = manager.paneManager.createTerminalPaneAtBottom(
            workingDirectory: fixture.project
        )
        let firstState = try #require(
            manager.paneManager.terminalState(for: firstPane)
        )
        let tab = try #require(firstState.terminalTabs.first)
        let session = makeSession(pid: 1_113, generation: 1)
        manager.terminal.bridgeAgentSession(
            session,
            replacing: nil,
            in: tab
        )
        tab.agentSession = session
        let taskID = try #require(taskRegistry.taskID(forSessionID: session.id))
        #expect(await projectRegistry.resolveAgentTaskRoute(taskID) != nil)
        let secondPane = try #require(manager.paneManager.createTerminalPane(
            relativeTo: firstPane,
            axis: .horizontal,
            workingDirectory: fixture.project
        ))
        let secondState = try #require(
            manager.paneManager.terminalState(for: secondPane)
        )
        secondState.terminalTabs.append(tab)

        #expect(await projectRegistry.resolveAgentTaskRoute(taskID) == nil)
        secondState.terminalTabs.removeAll { $0 === tab }
    }

    @Test("persistence trims task and run bounds")
    func boundedPersistence() async throws {
        let fixture = try PersistenceFixture()
        defer { fixture.cleanup() }
        let limits = AgentTaskPersistenceLimits(
            maxTasksPerProject: 3,
            maxRunsPerTask: 2,
            maxFileBytes: 128_000
        )
        let store = AgentTaskMetadataStore(
            storageRoot: fixture.storage,
            limits: limits
        )
        let registry = AgentTaskRegistry()
        let identity = project(fixture.project.path)
        let sharedContext = context(
            project: identity,
            routeSeed: 110,
            origin: .pineLaunched
        )
        var previous = makeSession(pid: 1_201, generation: 1)
        guard case .reserved(let initial) = registry.preparePineLaunch(
            descriptor: AgentDescriptor(
                agentType: previous.agentType,
                launchExecutable: "claude"
            ),
            context: sharedContext,
            title: nil,
            objective: nil
        ) else {
            Issue.record("initial reservation was rejected")
            return
        }
        #expect(registry.armLaunch(initial))
        registry.bridge(
            previous,
            replacing: nil,
            context: sharedContext,
            reservation: initial
        )
        let retainedTaskID = try #require(
            registry.taskID(forSessionID: previous.id)
        )
        for sequence in 2...4 {
            previous.applyLiveness(.terminated)
            previous.state = .done
            registry.refresh(sessions: [previous])
            let next = makeSession(
                pid: 1_200 + Int32(sequence),
                generation: UInt64(sequence)
            )
            let resumeContext = AgentTaskBridgeContext(
                project: identity,
                route: sharedContext.route,
                origin: .pineLaunched,
                observedAt: Date(timeIntervalSince1970: 0)
            )
            guard case .reserved(let reservation) = registry.prepareResume(
                taskID: retainedTaskID,
                context: resumeContext
            ) else {
                Issue.record("resume reservation was rejected")
                return
            }
            #expect(registry.armLaunch(reservation))
            registry.bridge(
                next,
                replacing: previous,
                context: resumeContext,
                reservation: reservation
            )
            previous = next
        }
        for seed in 111...112 {
            registry.bridge(
                makeSession(
                    pid: 1_300 + Int32(seed),
                    generation: UInt64(seed)
                ),
                replacing: nil,
                context: context(project: identity, routeSeed: seed)
            )
        }

        let save = await store.save(
            tasks: registry.tasks,
            project: identity
        )
        let loaded = await store.load(project: identity)

        #expect(save == .saved(taskCount: 3))
        #expect(loaded.tasks.count == 3)
        #expect(loaded.tasks.allSatisfy { $0.runs.count <= 2 })
        let retained = try #require(
            loaded.tasks.first(where: { $0.id == retainedTaskID })
        )
        #expect(retained.runs.map(\.process.processGeneration) == [3, 4])
    }

    @Test("active retention overflow fails instead of truncating")
    func activeRetentionOverflowFailsClosed() async throws {
        let fixture = try PersistenceFixture()
        defer { fixture.cleanup() }
        let limits = AgentTaskPersistenceLimits(maxTasksPerProject: 1)
        let store = AgentTaskMetadataStore(
            storageRoot: fixture.storage,
            limits: limits
        )
        let identity = project(fixture.project.path)
        let registry = AgentTaskRegistry()
        for seed in 201...202 {
            registry.bridge(
                makeSession(pid: 2_000 + Int32(seed), generation: UInt64(seed)),
                replacing: nil,
                context: context(project: identity, routeSeed: seed)
            )
        }

        #expect(await store.save(tasks: registry.tasks, project: identity)
            == .rejected(.storageLimit))
    }

    @Test("paused retention overflow fails instead of deleting resumable tasks")
    func pausedRetentionOverflowFailsClosed() async throws {
        let fixture = try PersistenceFixture()
        defer { fixture.cleanup() }
        let store = AgentTaskMetadataStore(
            storageRoot: fixture.storage,
            limits: AgentTaskPersistenceLimits(maxTasksPerProject: 1)
        )
        let identity = project(fixture.project.path)
        let registry = AgentTaskRegistry()
        for seed in 203...204 {
            let session = makeSession(
                pid: 2_000 + Int32(seed),
                generation: UInt64(seed)
            )
            let bridgeContext = context(project: identity, routeSeed: seed)
            registry.bridge(session, replacing: nil, context: bridgeContext)
            session.applyLiveness(.terminated)
            registry.bridge(session, replacing: session, context: bridgeContext)
        }

        #expect(registry.tasks.allSatisfy { $0.lifecycle == .paused })
        #expect(await store.save(tasks: registry.tasks, project: identity)
            == .rejected(.storageLimit))
    }

    @Test("impossible lifecycle route and attention metadata is rejected")
    func impossibleMetadataIsRejected() async throws {
        let fixture = try PersistenceFixture()
        defer { fixture.cleanup() }
        let store = AgentTaskMetadataStore(storageRoot: fixture.storage)
        let identity = project(fixture.project.path)
        let discovered = context(project: identity, routeSeed: 210)
        var activeWithoutRun = AgentTask(
            descriptor: AgentDescriptor(agentType: .claudeCode),
            context: discovered
        )
        #expect(await store.save(tasks: [activeWithoutRun], project: identity)
            == .rejected(.invalidMetadata))

        activeWithoutRun.lifecycle = .paused
        #expect(await store.save(tasks: [activeWithoutRun], project: identity)
            == .rejected(.invalidMetadata))
        activeWithoutRun.route.availability = .missing
        #expect(await store.save(tasks: [activeWithoutRun], project: identity)
            == .saved(taskCount: 1))

        let registry = AgentTaskRegistry()
        let session = makeSession(pid: 2_211, generation: 1)
        registry.bridge(session, replacing: nil, context: discovered)
        var task = try #require(registry.tasks.first)
        task.attention = .waitingInput
        #expect(await store.save(tasks: [task], project: identity)
            == .rejected(.invalidMetadata))
        task.attention = .none
        task.route = AgentTaskRoute(
            paneID: task.route.paneID,
            tabID: uuid(9_999),
            terminalID: task.route.terminalID
        )
        #expect(await store.save(tasks: [task], project: identity)
            == .rejected(.invalidMetadata))
    }

    @Test("hostile decoded no-run active task fails closed")
    func hostileDecodedTaskFailsClosed() async throws {
        let fixture = try PersistenceFixture()
        defer { fixture.cleanup() }
        let store = AgentTaskMetadataStore(storageRoot: fixture.storage)
        let identity = project(fixture.project.path)
        let registry = AgentTaskRegistry()
        registry.bridge(
            makeSession(pid: 2_301, generation: 1),
            replacing: nil,
            context: context(project: identity, routeSeed: 220)
        )
        #expect(await store.save(tasks: registry.tasks, project: identity)
            == .saved(taskCount: 1))
        let fileURL = AgentTaskMetadataStore.metadataURL(
            for: identity,
            storageRoot: fixture.storage
        )
        let original = try Data(contentsOf: fileURL)
        let hostile = try metadataWithoutRuns(original)
        try hostile.write(to: fileURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: fileURL.path
        )

        #expect(await store.load(project: identity).status
            == .rejected(.invalidMetadata))
        #expect(try Data(contentsOf: fileURL) == hostile)
    }

    @Test("atomic failed save preserves previous metadata")
    func atomicSaveLoad() async throws {
        let fixture = try PersistenceFixture()
        defer { fixture.cleanup() }
        let store = AgentTaskMetadataStore(storageRoot: fixture.storage)
        let identity = project(fixture.project.path)
        let registry = AgentTaskRegistry()
        let first = makeSession(pid: 1_401, generation: 1)
        registry.bridge(
            first,
            replacing: nil,
            context: context(project: identity, routeSeed: 120)
        )
        #expect(
            await store.save(tasks: registry.tasks, project: identity)
                == .saved(taskCount: 1)
        )
        let fileURL = AgentTaskMetadataStore.metadataURL(
            for: identity,
            storageRoot: fixture.storage
        )
        let originalData = try Data(contentsOf: fileURL)

        var invalid = try #require(registry.tasks.first)
        invalid.title = String(repeating: "x", count: 10_000)
        #expect(
            await store.save(tasks: [invalid], project: identity)
                == .rejected(.invalidMetadata)
        )
        #expect(try Data(contentsOf: fileURL) == originalData)

        let second = makeSession(pid: 1_402, generation: 2)
        registry.bridge(
            second,
            replacing: nil,
            context: context(project: identity, routeSeed: 121)
        )
        #expect(
            await store.save(tasks: registry.tasks, project: identity)
                == .saved(taskCount: 2)
        )
        let loaded = await store.load(project: identity)
        #expect(loaded.tasks.count == 2)
        #expect(!FileManager.default.fileExists(
            atPath: fileURL.appendingPathExtension("tmp").path
        ))
    }

    @Test("corrupt and future schemas fail closed")
    func invalidSchemaFailsClosed() async throws {
        let fixture = try PersistenceFixture()
        defer { fixture.cleanup() }
        let store = AgentTaskMetadataStore(storageRoot: fixture.storage)
        let identity = project(fixture.project.path)
        let fileURL = AgentTaskMetadataStore.metadataURL(
            for: identity,
            storageRoot: fixture.storage
        )
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: fileURL.deletingLastPathComponent().path
        )

        try Data("not-json".utf8).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: fileURL.path
        )
        var loaded = await store.load(project: identity)
        #expect(loaded.status == .rejected(.corrupt))
        #expect(loaded.tasks.isEmpty)

        let future = """
        {"schemaVersion":999,"canonicalProjectPath":"\(identity.canonicalProjectPath)","tasks":[]}
        """
        try Data(future.utf8).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: fileURL.path
        )
        loaded = await store.load(project: identity)
        #expect(loaded.status == .rejected(.unknownSchema))
        #expect(loaded.tasks.isEmpty)
    }

    @Test("future schema quarantines normal registry writes")
    func futureSchemaQuarantinesRegistryWrites() async throws {
        let fixture = try PersistenceFixture()
        defer { fixture.cleanup() }
        let identity = project(fixture.project.path)
        let store = AgentTaskMetadataStore(storageRoot: fixture.storage)
        let fileURL = AgentTaskMetadataStore.metadataURL(
            for: identity,
            storageRoot: fixture.storage
        )
        try FileManager.default.createDirectory(
            at: fixture.storage,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let original = Data("{\"schemaVersion\":999,\"future\":true}\n".utf8)
        try original.write(to: fileURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
        let registry = AgentTaskRegistry(persistence: store)
        registry.registerProject(identity)
        #expect(await registry.flushPersistence() == .saved)
        registry.bridge(
            makeSession(pid: 1_490, generation: 1),
            replacing: nil,
            context: context(project: identity, routeSeed: 149)
        )
        registry.prepareForApplicationTermination()

        #expect(await registry.flushPersistence() == .failed)
        #expect(try Data(contentsOf: fileURL) == original)
        #expect(
            registry.saveResultByProject[identity.persistenceKey] == nil
        )
    }

    @Test("every rejected load quarantines later registry mutations")
    func rejectedLoadQuarantinesRegistryWrites() async throws {
        let rejections: [AgentTaskMetadataRejection] = [
            .corrupt,
            .unknownSchema,
            .missingProject,
            .invalidMetadata,
            .storageLimit,
            .ioFailure,
            .unsafeFilesystemObject,
            .lockContention,
            .transientIO,
            .durabilityUnknown,
            .concurrentMutation,
            .superseded
        ]
        for (offset, rejection) in rejections.enumerated() {
            let identity = project(
                "/tmp/pine-agent-rejected-load-\(offset)"
            )
            let store = LoadedAgentTaskStore(
                status: .rejected(rejection),
                tasks: []
            )
            let registry = AgentTaskRegistry(persistence: store)
            registry.registerProject(identity)
            #expect(await registry.flushPersistence() == .saved)
            #expect(registry.persistenceIsQuarantinedForTesting(identity))

            registry.bridge(
                makeSession(
                    pid: 1_492 + Int32(offset),
                    generation: UInt64(offset + 1)
                ),
                replacing: nil,
                context: context(
                    project: identity,
                    routeSeed: 152 + offset
                )
            )

            #expect(await registry.flushPersistence() == .failed)
            #expect(registry.saveResultByProject[identity.persistenceKey] == nil)
        }
    }

    @Test("oversized metadata quarantines registry writes byte-for-byte")
    func oversizedMetadataQuarantinesWrites() async throws {
        let fixture = try PersistenceFixture()
        defer { fixture.cleanup() }
        let identity = project(fixture.project.path)
        let store = AgentTaskMetadataStore(
            storageRoot: fixture.storage,
            limits: AgentTaskPersistenceLimits(maxFileBytes: 1_024)
        )
        let fileURL = AgentTaskMetadataStore.metadataURL(
            for: identity,
            storageRoot: fixture.storage
        )
        try FileManager.default.createDirectory(
            at: fixture.storage,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let original = Data(
            "{\"schemaVersion\":999,\"future\":\"\(String(repeating: "A", count: 2_048))\"}\n".utf8
        )
        try original.write(to: fileURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
        let registry = AgentTaskRegistry(persistence: store)
        registry.registerProject(identity)
        #expect(await registry.flushPersistence() == .saved)
        #expect(
            registry.loadStatusByProject[identity.persistenceKey]
                == .rejected(.storageLimit)
        )
        registry.bridge(
            makeSession(pid: 1_489, generation: 1),
            replacing: nil,
            context: context(project: identity, routeSeed: 148)
        )
        registry.prepareForApplicationTermination()

        #expect(await registry.flushPersistence() == .failed)
        #expect(try Data(contentsOf: fileURL) == original)
        #expect(registry.saveResultByProject[identity.persistenceKey] == nil)
    }

    @Test("quit snapshot is valid and rollback restores live ownership")
    func quitSnapshotPersistsAndRollsBack() async throws {
        let fixture = try PersistenceFixture()
        defer { fixture.cleanup() }
        let identity = project(fixture.project.path)
        let store = AgentTaskMetadataStore(storageRoot: fixture.storage)
        let registry = AgentTaskRegistry(persistence: store)
        registry.registerProject(identity)
        #expect(await registry.flushPersistence() == .saved)
        let session = makeSession(pid: 1_491, generation: 1)
        let route = context(project: identity, routeSeed: 150)
        registry.bridge(session, replacing: nil, context: route)
        let originalUpdatedAt = try #require(
            registry.task(forSessionID: session.id)?.updatedAt
        )
        registry.prepareForApplicationTermination(
            at: Date(timeIntervalSince1970: 10)
        )

        #expect(await registry.flushPersistence() == .saved)
        let stored = await store.load(project: identity)
        let snapshot = try #require(stored.tasks.first)
        #expect(snapshot.lifecycle == .paused)
        #expect(snapshot.route.availability == .missing)
        #expect(snapshot.runs.last?.liveness == .stale)

        #expect(await registry.cancelApplicationTerminationAndFlush())
        let restored = try #require(registry.task(forSessionID: session.id))
        #expect(restored.lifecycle == .active)
        #expect(restored.route.availability == .available)
        #expect(restored.runs.last?.liveness == .live)
        #expect(restored.updatedAt == originalUpdatedAt)
        #expect(registry.taskID(forSessionID: session.id) == restored.id)
        #expect(await registry.flushPersistence() == .saved)
        let rolledBack = try #require(
            await store.load(project: identity).tasks.first
        )
        #expect(rolledBack.lifecycle == .active)
        #expect(rolledBack.route.availability == .available)
        #expect(rolledBack.runs.last?.liveness == .live)
        #expect(
            abs(rolledBack.updatedAt.timeIntervalSince(originalUpdatedAt)) < 0.001
        )
    }

    @Test("failed durable rollback still releases termination admission")
    func failedRollbackReleasesTerminationAdmission() async throws {
        let identity = project("/tmp/pine-agent-failed-rollback")
        let store = ScriptedAgentTaskStore()
        let registry = AgentTaskRegistry(
            persistence: store,
            flushTotal: .milliseconds(100),
            flushTail: .milliseconds(20)
        )
        registry.registerProject(identity)
        #expect(await registry.flushPersistence() == .saved)
        registry.bridge(
            makeSession(pid: 1_493, generation: 1),
            replacing: nil,
            context: context(project: identity, routeSeed: 153)
        )
        #expect(await registry.flushPersistence() == .saved)
        registry.prepareForApplicationTermination()
        #expect(await registry.flushPersistence() == .saved)
        await store.setSaveResult(.rejected(.ioFailure))

        let didPersistRollback = await registry.cancelApplicationTerminationAndFlush(
            maximumDuration: .milliseconds(100)
        )
        #expect(!didPersistRollback)
        let replacement = makeSession(pid: 1_494, generation: 2)
        registry.bridge(
            replacement,
            replacing: nil,
            context: context(project: identity, routeSeed: 154)
        )
        #expect(registry.task(forSessionID: replacement.id) != nil)
    }

    @Test("failed durable rollback still thaws project terminal callbacks")
    func failedRollbackThawsProjectTerminalCallbacks() async throws {
        let fixture = try PersistenceFixture()
        defer { fixture.cleanup() }
        let identity = project(fixture.project.path)
        let store = ScriptedAgentTaskStore()
        let agentTasks = AgentTaskRegistry(
            persistence: store,
            flushTotal: .milliseconds(100),
            flushTail: .milliseconds(20)
        )
        let projects = ProjectRegistry(agentTasks: agentTasks)
        let manager = try #require(projects.projectManager(for: fixture.project))
        #expect(await agentTasks.flushPersistence() == .saved)
        agentTasks.bridge(
            makeSession(pid: 1_496, generation: 1),
            replacing: nil,
            context: context(project: identity, routeSeed: 155)
        )
        #expect(await agentTasks.flushPersistence() == .saved)
        projects.freezeAgentTasksForTermination()
        #expect(manager.terminal.agentCallbacksFrozenForTesting)
        agentTasks.prepareForApplicationTermination()
        #expect(await agentTasks.flushPersistence() == .saved)
        await store.setSaveResult(.rejected(.ioFailure))

        let didPersistRollback = await projects.cancelAgentTaskTermination(
            maximumDuration: .milliseconds(100)
        )

        #expect(!didPersistRollback)
        #expect(!manager.terminal.agentCallbacksFrozenForTesting)
    }

    @Test("one rejected project cannot starve another project save")
    func rejectedProjectDoesNotStarveOtherProjects() async {
        let first = project("/tmp/pine-agent-failing-project")
        let second = project("/tmp/pine-agent-healthy-project")
        let store = SelectiveAgentTaskStore(failingProjectKey: first.persistenceKey)
        let registry = AgentTaskRegistry(persistence: store)
        registry.registerProject(first)
        registry.registerProject(second)
        #expect(await registry.flushPersistence() == .saved)

        registry.bridge(
            makeSession(pid: 1_480, generation: 1),
            replacing: nil,
            context: context(project: first, routeSeed: 120)
        )
        registry.bridge(
            makeSession(pid: 1_481, generation: 2),
            replacing: nil,
            context: context(project: second, routeSeed: 121)
        )

        #expect(await store.waitForSave(projectKey: second.persistenceKey))
        #expect(await store.savedTaskCount(projectKey: second.persistenceKey) == 1)
    }

    @Test("missing worktrees and projects fail closed")
    func missingPathsFailClosed() async throws {
        let fixture = try PersistenceFixture(makeWorktree: true)
        defer { fixture.cleanup() }
        let worktree = try #require(fixture.worktree)
        let identity = AgentTaskProjectIdentity(
            canonicalProjectPath: fixture.project.path,
            canonicalWorktreePath: worktree.path
        )
        let registry = AgentTaskRegistry()
        registry.bridge(
            makeSession(pid: 1_501, generation: 1),
            replacing: nil,
            context: context(project: identity, routeSeed: 130)
        )
        let store = AgentTaskMetadataStore(storageRoot: fixture.storage)
        #expect(
            await store.save(tasks: registry.tasks, project: identity)
                == .saved(taskCount: 1)
        )

        try FileManager.default.removeItem(at: worktree)
        var loaded = await store.load(project: identity)
        #expect(loaded.status == .loadedWithMissingWorktrees(1))
        #expect(loaded.tasks.count == 1)
        #expect(loaded.tasks.first?.route.availability == .missing)

        try FileManager.default.removeItem(at: fixture.project)
        loaded = await store.load(project: identity)
        #expect(loaded.status == .rejected(.missingProject))
        #expect(loaded.tasks.isEmpty)
    }

    @Test("persisted metadata excludes session-private content")
    func persistencePrivacy() async throws {
        let fixture = try PersistenceFixture()
        defer { fixture.cleanup() }
        let identity = project(fixture.project.path)
        let registry = AgentTaskRegistry()
        let session = makeSession(pid: 987_654_321, generation: 1)
        let secretPrompt = "PROMPT_DO_NOT_PERSIST"
        let terminalOutput = "TERMINAL_OUTPUT_DO_NOT_PERSIST"
        let credential = "TOKEN_DO_NOT_PERSIST"
        session.currentTask = secretPrompt
        session.filesRead = [URL(fileURLWithPath: terminalOutput)]
        session.filesModified = [URL(fileURLWithPath: credential)]
        let launchContext = context(
            project: identity,
            routeSeed: 140,
            origin: .pineLaunched
        )
        guard case .reserved(let reservation) = registry.preparePineLaunch(
            descriptor: AgentDescriptor(
                agentType: session.agentType,
                launchExecutable: "claude"
            ),
            context: launchContext,
            title: "User title",
            objective: "User objective"
        ) else {
            Issue.record("launch reservation was rejected")
            return
        }
        #expect(registry.armLaunch(reservation))
        registry.bridge(
            session,
            replacing: nil,
            context: launchContext,
            reservation: reservation
        )
        var privateTask = try #require(registry.tasks.first)
        let vendorCanary = "VENDOR_IDENTITY_DO_NOT_PERSIST"
        privateTask.runs[0].vendorIdentity = AgentVendorSessionIdentity(
            provider: "PRIVATE_PROVIDER",
            opaqueIdentifier: vendorCanary
        )
        let store = AgentTaskMetadataStore(storageRoot: fixture.storage)
        #expect(
            await store.save(tasks: [privateTask], project: identity)
                == .saved(taskCount: 1)
        )

        let fileURL = AgentTaskMetadataStore.metadataURL(
            for: identity,
            storageRoot: fixture.storage
        )
        let data = try Data(contentsOf: fileURL)
        let persisted = try #require(String(data: data, encoding: .utf8))
        #expect(!persisted.contains(secretPrompt))
        #expect(!persisted.contains(terminalOutput))
        #expect(!persisted.contains(credential))
        #expect(!persisted.contains(vendorCanary))
        #expect(!persisted.contains("environment"))
        #expect(!persisted.contains("transcript"))
        #expect(!persisted.contains("prompt"))
        #expect(!persisted.contains("Mon Aug 3 10:00:00 2026"))
        #expect(!persisted.contains("987654321"))
        let root = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(Set(root.keys) == [
            "schemaVersion", "revision", "canonicalProjectPath",
            "canonicalWorktreePath", "tasks",
        ])
        let task = try #require((root["tasks"] as? [[String: Any]])?.first)
        #expect(Set(task.keys) == [
            "attention", "createdAt", "descriptor", "id", "isUnread",
            "lastActivityAt", "lifecycle", "origin", "project", "route",
            "runs", "title", "objective", "updatedAt",
        ])
        let projectObject = try #require(task["project"] as? [String: Any])
        #expect(Set(projectObject.keys) == [
            "canonicalProjectPath", "canonicalWorktreePath",
        ])
        let route = try #require(task["route"] as? [String: Any])
        #expect(Set(route.keys) == [
            "availability", "paneID", "tabID", "terminalID",
        ])
        let descriptor = try #require(task["descriptor"] as? [String: Any])
        #expect(Set(descriptor.keys) == ["launchExecutable", "typeIdentifier"])
        #expect(descriptor["launchExecutable"] as? String == "claude")
        let run = try #require((task["runs"] as? [[String: Any]])?.first)
        #expect(Set(run.keys) == [
            "id", "lastObservedAt", "liveness", "process", "startedAt",
            "state", "terminalID",
        ])
        let process = try #require(run["process"] as? [String: Any])
        #expect(Set(process.keys) == [
            "observedStartedAt", "processGeneration",
        ])
        let forbiddenKeys: Set<String> = [
            "prompt", "command", "arguments", "environment", "output",
            "transcript", "fileContents", "activitySummary", "credentials",
            "vendorIdentity", "processIdentifier", "startIdentifier",
        ]
        func assertNoForbiddenKeys(_ value: Any) {
            if let object = value as? [String: Any] {
                #expect(forbiddenKeys.isDisjoint(with: object.keys))
                object.values.forEach(assertNoForbiddenKeys)
            } else if let array = value as? [Any] {
                array.forEach(assertNoForbiddenKeys)
            }
        }
        assertNoForbiddenKeys(root)
    }

    @Test("schema v1 metadata migrates to revisioned v2")
    func legacyMetadataMigratesToRevisionedEnvelope() async throws {
        let fixture = try PersistenceFixture()
        defer { fixture.cleanup() }
        let identity = project(fixture.project.path)
        try FileManager.default.createDirectory(
            at: fixture.storage,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let fileURL = AgentTaskMetadataStore.metadataURL(
            for: identity,
            storageRoot: fixture.storage
        )
        let legacy: [String: Any] = [
            "schemaVersion": 1,
            "canonicalProjectPath": identity.canonicalProjectPath,
            "canonicalWorktreePath": identity.canonicalWorktreePath,
            "tasks": [],
        ]
        try JSONSerialization.data(withJSONObject: legacy).write(to: fileURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )

        let store = AgentTaskMetadataStore(storageRoot: fixture.storage)
        let loadedLegacy = await store.load(project: identity)
        let staleRevision = try #require(loadedLegacy.revision)
        var changedLegacy = try Data(contentsOf: fileURL)
        changedLegacy.append(0x0A)
        try changedLegacy.write(to: fileURL)
        let generation = UUID()
        let ticket = AgentTaskPersistenceTicket(
            generation: generation,
            sequence: 1,
            projectKey: identity.persistenceKey,
            expectedDiskRevision: staleRevision
        )
        let fence = AgentTaskPublicationFence(generation: generation)
        fence.authorize(ticket)
        #expect(
            await store.save(
                tasks: [],
                project: identity,
                authorization: AgentTaskPublicationAuthorization(
                    ticket: ticket,
                    fence: fence
                )
            ) == .rejected(.superseded)
        )
        #expect(try Data(contentsOf: fileURL) == changedLegacy)

        let registry = AgentTaskRegistry(persistence: store)
        registry.registerProject(identity)
        #expect(await registry.flushPersistence() == .saved)

        let root = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: fileURL)
            ) as? [String: Any]
        )
        #expect(root["schemaVersion"] as? Int == 2)
        #expect(UUID(uuidString: root["revision"] as? String ?? "") != nil)
    }

    @Test("post-rename durability uncertainty advances CAS and retry converges")
    func durabilityUnknownAfterPublicationCanRetry() async throws {
        let fixture = try PersistenceFixture()
        defer { fixture.cleanup() }
        let fault = OneShotStorageSyncFault()
        let store = AgentTaskMetadataStore(
            storageRoot: fixture.storage,
            configuration: AgentTaskStoreConfiguration(
                hooks: AgentTaskStoreHooks(shouldSync: fault.shouldSync)
            )
        )
        let identity = project(fixture.project.path)
        let registry = AgentTaskRegistry(persistence: store)
        registry.registerProject(identity)
        #expect(await registry.flushPersistence() == .saved)
        let session = makeSession(pid: 1_387, generation: 1)
        registry.bridge(
            session,
            replacing: nil,
            context: context(project: identity, routeSeed: 140)
        )

        #expect(await registry.flushPersistence() == .saved)
        #expect(fault.storageFailureCount == 1)
        #expect(
            registry.saveResultByProject[identity.persistenceKey]
                == .saved(taskCount: 1)
        )
        let loaded = await store.load(project: identity)
        #expect(loaded.tasks.first?.runs.map(\.id) == [session.id])
    }

    @Test("timeout after publication carries CAS revision into retry")
    func timeoutAfterRenameCannotDesynchronizeCAS() async throws {
        let store = PostPublicationBlockingStore()
        let identity = project("/tmp/pine-agent-post-publication-timeout")
        let registry = AgentTaskRegistry(
            persistence: store,
            flushTotal: .milliseconds(25),
            flushTail: .milliseconds(5)
        )
        registry.registerProject(identity)
        #expect(await registry.flushPersistence() == .saved)
        let session = makeSession(pid: 1_391, generation: 1)
        registry.bridge(
            session,
            replacing: nil,
            context: context(project: identity, routeSeed: 141)
        )
        await store.waitUntilFirstPublication()

        #expect(await registry.flushPersistence() == .failed)
        await store.releaseFirstSave()
        await store.waitUntilFirstSaveReturned()

        session.state = .thinking
        registry.refresh(sessions: [session])
        #expect(await registry.flushPersistence() == .saved)
        #expect(await store.retryUsedPublishedRevision())
    }

    @Test("stale registry snapshot cannot overwrite another store instance")
    func diskRevisionRejectsCrossStoreLostUpdate() async throws {
        let fixture = try PersistenceFixture()
        defer { fixture.cleanup() }
        let identity = project(fixture.project.path)
        let first = AgentTaskRegistry(
            persistence: AgentTaskMetadataStore(storageRoot: fixture.storage)
        )
        let second = AgentTaskRegistry(
            persistence: AgentTaskMetadataStore(storageRoot: fixture.storage)
        )
        first.registerProject(identity)
        second.registerProject(identity)
        #expect(await first.flushPersistence() == .saved)
        #expect(await second.flushPersistence() == .saved)

        let firstSession = makeSession(pid: 1_385, generation: 1)
        first.bridge(
            firstSession,
            replacing: nil,
            context: context(project: identity, routeSeed: 138)
        )
        #expect(await first.flushPersistence() == .saved)

        let staleSession = makeSession(pid: 1_386, generation: 1)
        second.bridge(
            staleSession,
            replacing: nil,
            context: context(project: identity, routeSeed: 139)
        )
        #expect(await second.flushPersistence() == .failed)

        let loaded = await AgentTaskMetadataStore(
            storageRoot: fixture.storage
        ).load(project: identity)
        #expect(loaded.status == .loaded)
        #expect(loaded.tasks.count == 1)
        #expect(loaded.tasks[0].runs.map(\.id) == [firstSession.id])
    }

    @Test("in-memory task cap never evicts a paused resumable task")
    func runtimeTaskCapProtectsPausedIdentity() {
        let identity = project("/tmp/pine-agent-runtime-cap")
        let registry = AgentTaskRegistry(
            limits: AgentTaskPersistenceLimits(maxTasksPerProject: 1)
        )
        let first = makeSession(pid: 1_392, generation: 1)
        let firstContext = context(project: identity, routeSeed: 142)
        registry.bridge(first, replacing: nil, context: firstContext)
        let firstTaskID = registry.tasks.first?.id
        first.applyLiveness(.terminated)
        registry.bridge(first, replacing: first, context: firstContext)

        registry.bridge(
            makeSession(pid: 1_393, generation: 1),
            replacing: nil,
            context: context(project: identity, routeSeed: 143)
        )

        #expect(registry.tasks.count == 1)
        #expect(registry.tasks.first?.id == firstTaskID)
        #expect(registry.tasks.first?.lifecycle == .paused)
    }

    @Test("historical run tombstones are exact and admission-bounded")
    func historicalRunAdmissionCapFailsClosed() {
        let identity = project("/tmp/pine-agent-run-tombstone-cap")
        let registry = AgentTaskRegistry(
            limits: AgentTaskPersistenceLimits(
                maxHistoricalRunIDs: 2
            )
        )
        let first = makeSession(pid: 1_394, generation: 1)
        let second = makeSession(pid: 1_395, generation: 1)
        let third = makeSession(pid: 1_396, generation: 1)
        registry.bridge(
            first,
            replacing: nil,
            context: context(project: identity, routeSeed: 144)
        )
        registry.bridge(
            second,
            replacing: nil,
            context: context(project: identity, routeSeed: 145)
        )
        registry.bridge(
            third,
            replacing: nil,
            context: context(project: identity, routeSeed: 146)
        )

        #expect(registry.tasks.count == 2)
        #expect(registry.taskID(forSessionID: third.id) == nil)
        first.applyLiveness(.terminated)
        registry.bridge(
            first,
            replacing: first,
            context: context(project: identity, routeSeed: 144)
        )
        #expect(registry.tasks.count == 2)
        #expect(registry.historicalTask(forSessionID: first.id) != nil)
    }

    @Test("loaded run tombstones enforce cap without partial project merge")
    func loadedRunTombstonesFailClosed() async throws {
        let identity = project("/tmp/pine-agent-loaded-run-cap")
        let seed = AgentTaskRegistry()
        let first = makeSession(pid: 1_399, generation: 1)
        let second = makeSession(pid: 1_400, generation: 1)
        let firstContext = context(project: identity, routeSeed: 148)
        let secondContext = context(project: identity, routeSeed: 149)
        seed.bridge(first, replacing: nil, context: firstContext)
        seed.bridge(second, replacing: nil, context: secondContext)
        first.applyLiveness(.terminated)
        second.applyLiveness(.terminated)
        seed.bridge(first, replacing: first, context: firstContext)
        seed.bridge(second, replacing: second, context: secondContext)
        let loadedTasks = seed.tasks
        #expect(loadedTasks.count == 2)
        let registry = AgentTaskRegistry(
            persistence: LoadedAgentTaskStore(tasks: loadedTasks),
            limits: AgentTaskPersistenceLimits(maxHistoricalRunIDs: 1)
        )

        registry.registerProject(identity)
        #expect(await registry.flushPersistence() == .saved)

        #expect(registry.tasks.isEmpty)
        #expect(
            registry.loadStatusByProject[identity.persistenceKey]
                == .rejected(.storageLimit)
        )
    }

    @Test("load identity collision rejects whole persisted project")
    func loadedIdentityCollisionIsAtomic() async throws {
        let identity = project("/tmp/pine-agent-loaded-collision")
        let store = LoadedAgentTaskStore(tasks: [])
        let registry = AgentTaskRegistry(persistence: store)
        let runtimeSession = makeSession(pid: 1_401, generation: 1)
        let runtimeContext = context(project: identity, routeSeed: 151)
        registry.bridge(runtimeSession, replacing: nil, context: runtimeContext)
        let runtimeTask = try #require(registry.tasks.first)
        let seed = AgentTaskRegistry()
        let otherSession = makeSession(pid: 1_402, generation: 1)
        let otherContext = context(project: identity, routeSeed: 152)
        seed.bridge(otherSession, replacing: nil, context: otherContext)
        let otherTask = try #require(seed.tasks.first)
        await store.replaceTasks([runtimeTask, otherTask])

        registry.registerProject(identity)
        #expect(await registry.flushPersistence() == .failed)

        #expect(registry.tasks == [runtimeTask])
        #expect(
            registry.loadStatusByProject[identity.persistenceKey]
                == .rejected(.invalidMetadata)
        )
    }

    @Test("loaded tasks cannot exceed combined per-project runtime cap")
    func loadedTasksRespectCombinedRuntimeCap() async throws {
        let identity = project("/tmp/pine-agent-loaded-task-cap")
        let seed = AgentTaskRegistry()
        seed.bridge(
            makeSession(pid: 1_404, generation: 1),
            replacing: nil,
            context: context(project: identity, routeSeed: 154)
        )
        let loadedTask = try #require(seed.tasks.first)
        let registry = AgentTaskRegistry(
            persistence: LoadedAgentTaskStore(tasks: [loadedTask]),
            limits: AgentTaskPersistenceLimits(maxTasksPerProject: 1)
        )
        registry.bridge(
            makeSession(pid: 1_405, generation: 1),
            replacing: nil,
            context: context(project: identity, routeSeed: 155)
        )
        let admittedRuntimeTask = try #require(registry.tasks.first)

        registry.registerProject(identity)
        #expect(await registry.flushPersistence() == .failed)

        #expect(registry.tasks == [admittedRuntimeTask])
        #expect(
            registry.loadStatusByProject[identity.persistenceKey]
                == .rejected(.storageLimit)
        )
    }

    @Test("quarantined project mutations fail persistence barrier")
    func quarantinedMutationFailsFlush() async {
        let identity = project("/tmp/pine-agent-quarantine-mutation")
        let registry = AgentTaskRegistry(
            persistence: LoadedAgentTaskStore(
                status: .rejected(.unknownSchema),
                tasks: []
            )
        )
        registry.registerProject(identity)
        #expect(await registry.flushPersistence() == .saved)

        registry.bridge(
            makeSession(pid: 1_406, generation: 1),
            replacing: nil,
            context: context(project: identity, routeSeed: 156)
        )

        #expect(await registry.flushPersistence() == .failed)
    }

    @Test("failed resume admission preserves claim and run history")
    func failedResumeAdmissionIsNonDestructive() throws {
        let identity = project("/tmp/pine-agent-resume-admission")
        let registry = AgentTaskRegistry(
            limits: AgentTaskPersistenceLimits(
                maxRunsPerTask: 1,
                maxHistoricalRunIDs: 1
            )
        )
        let launchContext = context(
            project: identity,
            routeSeed: 147,
            origin: .pineLaunched
        )
        let firstBoundary = AgentTaskLaunchBoundary(
            generationFloor: 0,
            capturedAt: launchContext.observedAt
        )
        let firstReservation: AgentTaskLaunchReservation
        switch registry.preparePineLaunch(
            descriptor: AgentDescriptor(
                agentType: .claudeCode,
                launchExecutable: "claude"
            ),
            context: launchContext,
            title: nil,
            objective: nil,
            boundary: firstBoundary
        ) {
        case .reserved(let reservation):
            firstReservation = reservation
        case .sentWithoutReservation, .rejected:
            Issue.record("initial reservation was rejected")
            return
        }
        #expect(registry.armLaunch(firstReservation))
        let first = makeSession(
            pid: 1_397,
            generation: 1,
            preciseStartedAt: launchContext.observedAt.addingTimeInterval(1)
        )
        registry.bridge(
            first,
            replacing: nil,
            context: launchContext,
            reservation: firstReservation
        )
        first.applyLiveness(.terminated)
        registry.bridge(first, replacing: first, context: launchContext)
        let before = try #require(registry.task(for: firstReservation.taskID))
        let resumeBoundary = AgentTaskLaunchBoundary(
            generationFloor: 1,
            capturedAt: launchContext.observedAt.addingTimeInterval(2)
        )
        let resume: AgentTaskLaunchReservation
        switch registry.prepareResume(
            taskID: before.id,
            context: launchContext,
            boundary: resumeBoundary
        ) {
        case .reserved(let reservation): resume = reservation
        case .sentWithoutReservation, .rejected:
            Issue.record("Expected resume reservation")
            return
        }
        #expect(registry.armLaunch(resume))
        let second = makeSession(
            pid: 1_398,
            generation: 2,
            preciseStartedAt: launchContext.observedAt.addingTimeInterval(3)
        )

        registry.bridge(
            second,
            replacing: nil,
            context: launchContext,
            reservation: resume
        )

        #expect(registry.task(for: before.id) == before)
        #expect(registry.isLaunchPending(resume))
    }

    @Test("late detector termination cannot duplicate a terminal-closed run")
    func lateDetectorTerminationUsesRunTombstone() throws {
        let registry = AgentTaskRegistry()
        let identity = project("/tmp/pine-agent-terminal-close-tombstone")
        let route = context(project: identity, routeSeed: 139)
        let session = makeSession(pid: 1_390, generation: 1)
        registry.bridge(session, replacing: nil, context: route)
        let taskID = try #require(registry.taskID(forSessionID: session.id))

        registry.markTerminalClosed(
            terminalID: route.route.terminalID,
            project: identity,
            at: route.observedAt.addingTimeInterval(1)
        )
        session.applyLiveness(.terminated)
        registry.bridge(session, replacing: nil, context: route)

        #expect(registry.tasks.count == 1)
        #expect(registry.tasks[0].id == taskID)
        #expect(registry.tasks[0].runs.map(\.id) == [session.id])
        #expect(registry.historicalTask(forSessionID: session.id)?.id == taskID)
    }

    @Test("metadata with an extended ACL is rejected")
    func metadataExtendedACLIsRejected() async throws {
        let fixture = try PersistenceFixture()
        defer { fixture.cleanup() }
        let identity = project(fixture.project.path)
        let store = AgentTaskMetadataStore(storageRoot: fixture.storage)
        #expect(await store.save(tasks: [], project: identity)
            == .saved(taskCount: 0))
        let fileURL = AgentTaskMetadataStore.metadataURL(
            for: identity,
            storageRoot: fixture.storage
        )
        let chmod = Process()
        chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmod.arguments = [
            "+a",
            "\(NSUserName()) allow read",
            fileURL.path,
        ]
        try chmod.run()
        chmod.waitUntilExit()
        #expect(chmod.terminationStatus == 0)

        #expect(await store.load(project: identity).status
            == .rejected(.unsafeFilesystemObject))
    }

    @Test("metadata storage is private and rejects symlink files")
    func privateStorageRejectsSymlink() async throws {
        let fixture = try PersistenceFixture()
        defer { fixture.cleanup() }
        let identity = project(fixture.project.path)
        let store = AgentTaskMetadataStore(storageRoot: fixture.storage)
        #expect(await store.save(tasks: [], project: identity) == .saved(taskCount: 0))
        let fileURL = AgentTaskMetadataStore.metadataURL(
            for: identity,
            storageRoot: fixture.storage
        )
        let attributes = try FileManager.default.attributesOfItem(
            atPath: fileURL.path
        )
        #expect(attributes[.posixPermissions] as? Int == 0o600)
        let directoryAttributes = try FileManager.default.attributesOfItem(
            atPath: fixture.storage.path
        )
        #expect(directoryAttributes[.posixPermissions] as? Int == 0o700)

        try FileManager.default.removeItem(at: fileURL)
        let target = fixture.root.appendingPathComponent("target")
        try Data("sentinel".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: fileURL,
            withDestinationURL: target
        )
        let loaded = await store.load(project: identity)
        #expect(loaded.tasks.isEmpty)
        #expect(loaded.status == .rejected(.unsafeFilesystemObject))
        #expect(try String(contentsOf: target, encoding: .utf8) == "sentinel")
    }

    @Test("natural exit then close reports terminal lifecycle exactly once")
    func naturalExitThenCloseReportsOnce() {
        let tab = TerminalTab(name: "lifecycle")
        var reports = 0
        tab.onLifecycleEnded = { _ in reports += 1 }
        tab.processDidTerminate()
        #expect(reports == 1)
        tab.stop()
        tab.stop()
        #expect(reports == 1)
    }

    @Test("symlinked storage root fails closed without changing target")
    func symlinkedStorageRootFailsClosed() async throws {
        let fixture = try PersistenceFixture()
        defer { fixture.cleanup() }
        let target = fixture.root.appendingPathComponent("target-store")
        try FileManager.default.createDirectory(
            at: target,
            withIntermediateDirectories: false
        )
        try FileManager.default.createSymbolicLink(
            at: fixture.storage,
            withDestinationURL: target
        )
        let store = AgentTaskMetadataStore(storageRoot: fixture.storage)
        let identity = project(fixture.project.path)
        #expect(
            await store.save(tasks: [], project: identity)
                == .rejected(.unsafeFilesystemObject)
        )
        let loaded = await store.load(project: identity)
        #expect(loaded.status == .rejected(.unsafeFilesystemObject))
        #expect(try FileManager.default.contentsOfDirectory(
            atPath: target.path
        ).isEmpty)
    }

    @Test("metadata mode links and size are classified fail closed")
    func metadataSecurityClassifications() async throws {
        let fixture = try PersistenceFixture()
        defer { fixture.cleanup() }
        let identity = project(fixture.project.path)
        let limits = AgentTaskPersistenceLimits(maxFileBytes: 1_024)
        let store = AgentTaskMetadataStore(
            storageRoot: fixture.storage,
            limits: limits
        )
        #expect(await store.save(tasks: [], project: identity) == .saved(taskCount: 0))
        let fileURL = AgentTaskMetadataStore.metadataURL(
            for: identity,
            storageRoot: fixture.storage
        )

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: fileURL.path
        )
        var loaded = await store.load(project: identity)
        #expect(loaded.status == .rejected(.unsafeFilesystemObject))

        try FileManager.default.removeItem(at: fileURL)
        let hardLinkSource = fixture.root.appendingPathComponent("hard-link")
        try Data("{}".utf8).write(to: hardLinkSource)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: hardLinkSource.path
        )
        try FileManager.default.linkItem(at: hardLinkSource, to: fileURL)
        loaded = await store.load(project: identity)
        #expect(loaded.status == .rejected(.unsafeFilesystemObject))

        try FileManager.default.removeItem(at: fileURL)
        try Data(repeating: 0x41, count: 1_025).write(to: fileURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: fileURL.path
        )
        loaded = await store.load(project: identity)
        #expect(loaded.status == .rejected(.storageLimit))
    }

    @Test("terminal callback then detector reconciliation keeps one durable run")
    func productionTerminalCloseReconciliationUsesTombstone() async throws {
        let fixture = try PersistenceFixture()
        defer { fixture.cleanup() }
        let taskRegistry = AgentTaskRegistry()
        let projectRegistry = ProjectRegistry(agentTasks: taskRegistry)
        let manager = try #require(
            projectRegistry.projectManager(for: fixture.project)
        )
        #expect(await taskRegistry.flushPersistence() == .saved)
        let pane = manager.paneManager.createTerminalPaneAtBottom(
            workingDirectory: fixture.project
        )
        let state = try #require(manager.paneManager.terminalState(for: pane))
        let tab = try #require(state.terminalTabs.first)
        let session = makeSession(pid: 1_391, generation: 1)
        manager.terminal.bridgeAgentSession(
            session,
            replacing: nil,
            in: tab
        )
        tab.agentSession = session
        let taskID = try #require(taskRegistry.taskID(forSessionID: session.id))

        tab.processDidTerminate()
        session.applyLiveness(.terminated)
        manager.terminal.bridgeAgentSession(
            session,
            replacing: session,
            in: tab
        )

        #expect(taskRegistry.tasks.count == 1)
        #expect(taskRegistry.tasks[0].id == taskID)
        #expect(taskRegistry.tasks[0].runs.map(\.id) == [session.id])
    }

    @Test("worktrees in one project use distinct metadata files")
    func worktreeMetadataDoesNotCollide() async throws {
        let fixture = try PersistenceFixture(makeWorktree: true)
        defer { fixture.cleanup() }
        let worktree = try #require(fixture.worktree)
        let first = project(fixture.project.path)
        let second = AgentTaskProjectIdentity(
            canonicalProjectPath: fixture.project.path,
            canonicalWorktreePath: worktree.path
        )
        let store = AgentTaskMetadataStore(storageRoot: fixture.storage)
        #expect(await store.save(tasks: [], project: first) == .saved(taskCount: 0))
        #expect(await store.save(tasks: [], project: second) == .saved(taskCount: 0))

        let firstURL = AgentTaskMetadataStore.metadataURL(
            for: first,
            storageRoot: fixture.storage
        )
        let secondURL = AgentTaskMetadataStore.metadataURL(
            for: second,
            storageRoot: fixture.storage
        )
        #expect(firstURL != secondURL)
        #expect(FileManager.default.fileExists(atPath: firstURL.path))
        #expect(FileManager.default.fileExists(atPath: secondURL.path))
    }

    @Test("loaded routes are hints and never enter runtime ownership maps")
    func loadedRouteIsNotRuntimeOwned() async throws {
        let fixture = try PersistenceFixture()
        defer { fixture.cleanup() }
        let identity = project(fixture.project.path)
        let session = makeSession(pid: 1_650, generation: 1)
        let writer = AgentTaskRegistry()
        writer.bridge(
            session,
            replacing: nil,
            context: context(project: identity, routeSeed: 149)
        )
        let store = AgentTaskMetadataStore(storageRoot: fixture.storage)
        #expect(
            await store.save(tasks: writer.tasks, project: identity)
                == .saved(taskCount: 1)
        )

        let reader = AgentTaskRegistry(persistence: store)
        reader.registerProject(identity)
        #expect(await reader.flushPersistence() == .saved)
        #expect(reader.tasks.count == 1)
        #expect(reader.tasks[0].route.availability == .missing)
        #expect(reader.tasks[0].lifecycle == .paused)
        #expect(reader.tasks[0].runs[0].liveness == .stale)
        #expect(reader.taskID(forSessionID: session.id) == nil)
    }

    @Test("loaded Pine interruption resumes as a fresh run")
    func loadedInterruptionResumesFreshRun() async throws {
        let fixture = try PersistenceFixture()
        defer { fixture.cleanup() }
        let identity = project(fixture.project.path)
        let store = AgentTaskMetadataStore(storageRoot: fixture.storage)
        let writer = AgentTaskRegistry()
        let launchContext = context(
            project: identity,
            routeSeed: 151,
            origin: .pineLaunched
        )
        guard case .reserved(let launch) = writer.preparePineLaunch(
            descriptor: AgentDescriptor(
                agentType: .claudeCode,
                launchExecutable: "claude"
            ),
            context: launchContext,
            title: nil,
            objective: nil
        ) else {
            Issue.record("launch reservation was rejected")
            return
        }
        #expect(writer.armLaunch(launch))
        let original = makeSession(pid: 1_651, generation: 1)
        writer.bridge(
            original,
            replacing: nil,
            context: launchContext,
            reservation: launch
        )
        #expect(
            await store.save(tasks: writer.tasks, project: identity)
                == .saved(taskCount: 1)
        )

        let reader = AgentTaskRegistry(persistence: store)
        reader.registerProject(identity)
        #expect(await reader.flushPersistence() == .saved)
        #expect(
            reader.task(for: launch.taskID)?.descriptor.launchExecutable
                == "claude"
        )
        let resumeContext = context(
            project: identity,
            routeSeed: 152,
            origin: .pineLaunched
        )
        guard case .reserved(let resume) = reader.prepareResume(
            taskID: launch.taskID,
            context: resumeContext
        ) else {
            Issue.record("loaded interruption was not resumable")
            return
        }
        #expect(reader.armLaunch(resume))
        let resumed = makeSession(pid: 1_652, generation: 2)
        reader.bridge(
            resumed,
            replacing: nil,
            context: resumeContext,
            reservation: resume
        )

        let task = try #require(reader.task(for: launch.taskID))
        #expect(task.runs.map(\.id) == [original.id, resumed.id])
        #expect(task.runs[0].liveness == .terminated)
        #expect(task.runs[0].endedAt != nil)
        #expect(task.runs[1].liveness == .live)
        #expect(task.lifecycle == .active)
        #expect(reader.taskID(forSessionID: resumed.id) == launch.taskID)
        #expect(await reader.flushPersistence() == .saved)
        let reloaded = try #require(
            await store.load(project: identity).tasks.first
        )
        #expect(reloaded.runs.map(\.id) == [original.id, resumed.id])
    }

    @Test("failed save remains dirty and retries deterministically")
    func failedSaveRetriesAfterProjectReturns() async throws {
        let fixture = try PersistenceFixture()
        defer { fixture.cleanup() }
        try FileManager.default.removeItem(at: fixture.project)
        let identity = project(fixture.project.path)
        let store = AgentTaskMetadataStore(storageRoot: fixture.storage)
        let registry = AgentTaskRegistry(persistence: store)
        registry.registerProject(identity)
        await registry.flushPersistence()
        let session = makeSession(pid: 1_701, generation: 1)
        registry.bridge(
            session,
            replacing: nil,
            context: context(project: identity, routeSeed: 150)
        )
        await registry.flushPersistence()
        #expect(
            registry.saveResultByProject[identity.persistenceKey]
                == .rejected(.missingProject)
        )

        try FileManager.default.createDirectory(
            at: fixture.project,
            withIntermediateDirectories: true
        )
        await registry.flushPersistence()
        #expect(
            registry.saveResultByProject[identity.persistenceKey]
                == .saved(taskCount: 1)
        )
    }

    @Test("flush follows a newer mutation scheduled during a suspended save")
    func flushFollowsMutatingSaveTail() async throws {
        let fixture = try PersistenceFixture()
        defer { fixture.cleanup() }
        let identity = project(fixture.project.path)
        let store = ScriptedAgentTaskStore(suspendFirstSave: true)
        let registry = AgentTaskRegistry(persistence: store)
        registry.registerProject(identity)
        #expect(await registry.flushPersistence() == .saved)
        registry.bridge(
            makeSession(pid: 1_801, generation: 1),
            replacing: nil,
            context: context(project: identity, routeSeed: 160)
        )
        let flush = Task { await registry.flushPersistence() }
        #expect(await store.waitForFirstSave())
        registry.bridge(
            makeSession(pid: 1_802, generation: 2),
            replacing: nil,
            context: context(project: identity, routeSeed: 161)
        )
        await store.releaseFirstSave()

        #expect(await flush.value == .saved)
        #expect(await store.savedTaskCounts() == [1, 2])
        #expect(await registry.flushPersistence() == .saved)
    }

    @Test("timed-out save detaches and late completion is fenced")
    func timedOutSaveCannotBlockOrOverwriteRetry() async throws {
        let fixture = try PersistenceFixture()
        defer { fixture.cleanup() }
        let identity = project(fixture.project.path)
        let store = ScriptedAgentTaskStore(suspendFirstSave: true)
        let registry = AgentTaskRegistry(
            persistence: store,
            flushTotal: .milliseconds(100),
            flushTail: .milliseconds(20)
        )
        registry.registerProject(identity)
        #expect(await registry.flushPersistence() == .saved)
        registry.bridge(
            makeSession(pid: 1_811, generation: 1),
            replacing: nil,
            context: context(project: identity, routeSeed: 162)
        )
        #expect(await store.waitForFirstSave())
        #expect(await registry.flushPersistence() == .failed)

        registry.bridge(
            makeSession(pid: 1_812, generation: 2),
            replacing: nil,
            context: context(project: identity, routeSeed: 163)
        )
        #expect(await registry.flushPersistence() == .saved)
        #expect(await store.savedTaskCounts() == [2])
        await store.releaseFirstSave()
        #expect(await store.waitForCompletedSaveCount(2))
        #expect(await store.savedTaskCounts() == [2])
        #expect(
            registry.saveResultByProject[identity.persistenceKey]
                == .saved(taskCount: 2)
        )
    }

    @Test("repeated persistence timeouts bound abandoned writers")
    func repeatedTimeoutsDoNotAccumulateWriters() async throws {
        let fixture = try PersistenceFixture()
        defer { fixture.cleanup() }
        let identity = project(fixture.project.path)
        let store = ScriptedAgentTaskStore(suspendEverySave: true)
        let registry = AgentTaskRegistry(
            persistence: store,
            flushTotal: .milliseconds(100),
            flushTail: .milliseconds(20)
        )
        registry.registerProject(identity)
        #expect(await registry.flushPersistence() == .saved)

        for generation in 1...3 {
            registry.bridge(
                makeSession(
                    pid: 1_820 + Int32(generation),
                    generation: UInt64(generation)
                ),
                replacing: nil,
                context: context(
                    project: identity,
                    routeSeed: 180 + generation
                )
            )
            #expect(await registry.flushPersistence() == .failed)
        }

        #expect(await store.saveCallCount() == 2)
        await store.releaseAllSaves()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while clock.now < deadline {
            if await store.completedSaveCount() >= 2 {
                break
            }
            try await clock.sleep(for: .milliseconds(1))
        }
        #expect(await store.completedSaveCount() == 2)
    }

    @Test("flush reports failure after its bounded retry policy")
    func flushReportsRepeatedFailure() async throws {
        let fixture = try PersistenceFixture()
        defer { fixture.cleanup() }
        let identity = project(fixture.project.path)
        let store = ScriptedAgentTaskStore(
            saveResult: .rejected(.ioFailure)
        )
        let registry = AgentTaskRegistry(persistence: store)
        registry.registerProject(identity)
        #expect(await registry.flushPersistence() == .saved)
        registry.bridge(
            makeSession(pid: 1_901, generation: 1),
            replacing: nil,
            context: context(project: identity, routeSeed: 170)
        )

        #expect(await registry.flushPersistence() == .failed)
        #expect(await store.saveCallCount() == 3)
    }

    private func metadataWithoutRuns(_ data: Data) throws -> Data {
        guard var root = try JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              var tasks = root["tasks"] as? [[String: Any]],
              !tasks.isEmpty else {
            throw CocoaError(.fileReadCorruptFile)
        }
        tasks[0]["runs"] = []
        root["tasks"] = tasks
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    private func project(_ path: String) -> AgentTaskProjectIdentity {
        AgentTaskProjectIdentity(
            canonicalProjectPath: URL(fileURLWithPath: path)
                .standardizedFileURL.path,
            canonicalWorktreePath: URL(fileURLWithPath: path)
                .standardizedFileURL.path
        )
    }

    private func context(
        project: AgentTaskProjectIdentity,
        routeSeed: Int,
        origin: AgentTaskOrigin = .discoveredInTerminal
    ) -> AgentTaskBridgeContext {
        AgentTaskBridgeContext(
            project: project,
            route: AgentTaskRoute(
                paneID: uuid(routeSeed),
                tabID: uuid(routeSeed + 2_000),
                terminalID: uuid(routeSeed + 2_000)
            ),
            origin: origin
        )
    }

    private func processStartIdentifier(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return formatter.string(from: date)
    }

    private func makeSession(
        pid: Int32,
        generation: UInt64,
        start: String = "Mon Aug 3 10:00:00 2026",
        preciseStartedAt: Date = Date(timeIntervalSince1970: 0),
        startIsAuthoritative: Bool = true,
        agentType: AgentType = .claudeCode,
        state: AgentState = .idle
    ) -> AgentSession {
        let session = AgentSession(
            agentType: agentType,
            state: state,
            startedAt: Date(timeIntervalSince1970: TimeInterval(generation))
        )
        _ = session.bindProcessEvidence(
            AgentProcessEvidence(
                processIdentifier: pid,
                processGeneration: generation,
                startIdentifier: start,
                observedStartedAt: preciseStartedAt,
                startIsAuthoritative: startIsAuthoritative
            )
        )
        return session
    }

    private func uuid(_ seed: Int) -> UUID {
        let suffix = String(format: "%012llX", UInt64(seed))
        return UUID(uuidString: "00000000-0000-0000-0000-\(suffix)")
            ?? UUID()
    }
}

@MainActor
private extension AgentTaskRegistry {
    func preparePineLaunch(
        descriptor: AgentDescriptor,
        context: AgentTaskBridgeContext,
        title: String?,
        objective: String?
    ) -> AgentTaskLaunchResult {
        preparePineLaunch(
            descriptor: descriptor,
            context: context,
            title: title,
            objective: objective,
            boundary: AgentTaskLaunchBoundary(
                generationFloor: 0,
                capturedAt: .distantPast
            )
        )
    }

    func prepareResume(
        taskID: UUID,
        context: AgentTaskBridgeContext
    ) -> AgentTaskLaunchResult {
        prepareResume(
            taskID: taskID,
            context: context,
            boundary: AgentTaskLaunchBoundary(
                generationFloor: 0,
                capturedAt: .distantPast
            )
        )
    }
}

private final class PersistenceFixture {
    let root: URL
    let project: URL
    let storage: URL
    let worktree: URL?

    init(makeWorktree: Bool = false) throws {
        root = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("PineAgentTasks-\(UUID().uuidString)")
        project = root.appendingPathComponent("project", isDirectory: true)
        storage = root.appendingPathComponent("storage", isDirectory: true)
        worktree = makeWorktree
            ? root.appendingPathComponent("worktree", isDirectory: true)
            : nil
        try FileManager.default.createDirectory(
            at: project,
            withIntermediateDirectories: true
        )
        if let worktree {
            try FileManager.default.createDirectory(
                at: worktree,
                withIntermediateDirectories: true
            )
        }
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

private actor PostPublicationBlockingStore: AgentTaskPersisting {
    private var saveCount = 0
    private var firstPublished = false
    private var firstReturned = false
    private var releaseFirst = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstRevision: UUID?
    private var retryMatchedRevision = false

    func load(project: AgentTaskProjectIdentity) -> AgentTaskMetadataLoadResult {
        AgentTaskMetadataLoadResult(status: .missing, tasks: [])
    }

    func save(
        tasks: [AgentTask],
        project: AgentTaskProjectIdentity,
        authorization: AgentTaskPublicationAuthorization?
    ) async -> AgentTaskMetadataSaveResult {
        guard let authorization else { return .rejected(.superseded) }
        saveCount += 1
        let call = saveCount
        if call == 1 {
            firstRevision = authorization.ticket.nextDiskRevision
        } else if let firstRevision {
            retryMatchedRevision = authorization.ticket.expectedDiskRevision
                == .versioned(firstRevision)
        }
        guard authorization.publishForTesting(operation: { true }) == .published else {
            return .rejected(.superseded)
        }
        if call == 1 {
            firstPublished = true
            if !releaseFirst {
                await withCheckedContinuation { continuation in
                    releaseWaiters.append(continuation)
                }
            }
            firstReturned = true
        }
        return .saved(taskCount: tasks.count)
    }

    func waitUntilFirstPublication() async {
        while !firstPublished { await Task.yield() }
    }

    func releaseFirstSave() {
        releaseFirst = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func waitUntilFirstSaveReturned() async {
        while !firstReturned { await Task.yield() }
    }

    func retryUsedPublishedRevision() -> Bool { retryMatchedRevision }
}

nonisolated private final class OneShotStorageSyncFault: @unchecked Sendable {
    private let lock = NSLock()
    private var didFailStorageSync = false

    var storageFailureCount: Int {
        lock.withLock { didFailStorageSync ? 1 : 0 }
    }

    func shouldSync(_ target: AgentTaskSyncTarget) -> Bool {
        lock.withLock {
            guard target == .storageDirectory, !didFailStorageSync else {
                return true
            }
            didFailStorageSync = true
            return false
        }
    }
}

private actor LoadedAgentTaskStore: AgentTaskPersisting {
    private let status: AgentTaskMetadataLoadStatus
    private var tasks: [AgentTask]

    init(
        status: AgentTaskMetadataLoadStatus = .loaded,
        tasks: [AgentTask]
    ) {
        self.status = status
        self.tasks = tasks
    }

    func load(
        project: AgentTaskProjectIdentity
    ) async -> AgentTaskMetadataLoadResult {
        AgentTaskMetadataLoadResult(status: status, tasks: tasks)
    }

    func replaceTasks(_ tasks: [AgentTask]) {
        self.tasks = tasks
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
private final class AgentLaunchWriteGate {
    private var started = false
    private var completion: Bool?

    func waitForCompletion(
        maximumDuration: Duration = .seconds(2)
    ) async -> Bool {
        started = true
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: maximumDuration)
        while completion == nil, clock.now < deadline {
            do {
                try await clock.sleep(for: .milliseconds(1))
            } catch {
                return false
            }
        }
        return completion ?? false
    }

    func waitUntilStarted(
        maximumDuration: Duration = .seconds(1)
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: maximumDuration)
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

private actor SelectiveAgentTaskStore: AgentTaskPersisting {
    private let failingProjectKey: String
    private var savedTaskCounts: [String: Int] = [:]

    init(failingProjectKey: String) {
        self.failingProjectKey = failingProjectKey
    }

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
        guard project.persistenceKey != failingProjectKey else {
            return .rejected(.transientIO)
        }
        let decision = authorization?.publishForTesting(operation: { true }) ?? .published
        switch decision {
        case .published:
            savedTaskCounts[project.persistenceKey] = tasks.count
            return .saved(taskCount: tasks.count)
        case .failed:
            return .rejected(.transientIO)
        case .superseded:
            return .rejected(.superseded)
        }
    }

    func waitForSave(projectKey: String) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while savedTaskCounts[projectKey] == nil, clock.now < deadline {
            do {
                try await clock.sleep(for: .milliseconds(1))
            } catch {
                return false
            }
        }
        return savedTaskCounts[projectKey] != nil
    }

    func savedTaskCount(projectKey: String) -> Int? {
        savedTaskCounts[projectKey]
    }
}

private actor ScriptedAgentTaskStore: AgentTaskPersisting {
    private var saveResult: AgentTaskMetadataSaveResult
    private let suspendFirstSave: Bool
    private let suspendEverySave: Bool
    private var saveSnapshots: [[AgentTask]] = []
    private var publishedSnapshots: [[AgentTask]] = []
    private var completedSaves = 0
    private var firstSaveContinuation: CheckedContinuation<Void, Never>?
    private var saveContinuations: [CheckedContinuation<Void, Never>] = []

    init(
        saveResult: AgentTaskMetadataSaveResult = .saved(taskCount: 0),
        suspendFirstSave: Bool = false,
        suspendEverySave: Bool = false
    ) {
        self.saveResult = saveResult
        self.suspendFirstSave = suspendFirstSave
        self.suspendEverySave = suspendEverySave
    }

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
        saveSnapshots.append(tasks)
        defer { completedSaves += 1 }
        if suspendEverySave {
            await withCheckedContinuation { continuation in
                saveContinuations.append(continuation)
            }
        } else if suspendFirstSave, saveSnapshots.count == 1 {
            await withCheckedContinuation { continuation in
                firstSaveContinuation = continuation
            }
        }
        guard case .saved = saveResult else { return saveResult }
        let decision: AgentTaskPublicationDecision
        if let authorization {
            decision = authorization.publishForTesting {
                publishedSnapshots.append(tasks)
                return true
            }
        } else {
            publishedSnapshots.append(tasks)
            decision = .published
        }
        switch decision {
        case .published:
            return .saved(taskCount: tasks.count)
        case .failed:
            return .rejected(.transientIO)
        case .superseded:
            return .rejected(.superseded)
        }
    }

    func setSaveResult(_ result: AgentTaskMetadataSaveResult) {
        saveResult = result
    }

    func waitForFirstSave() async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while saveSnapshots.isEmpty, clock.now < deadline {
            do {
                try await clock.sleep(for: .milliseconds(1))
            } catch {
                return false
            }
        }
        return !saveSnapshots.isEmpty
    }

    func releaseFirstSave() {
        firstSaveContinuation?.resume()
        firstSaveContinuation = nil
    }

    func releaseAllSaves() {
        let continuations = saveContinuations
        saveContinuations.removeAll()
        continuations.forEach { $0.resume() }
    }

    func savedTaskCounts() -> [Int] {
        publishedSnapshots.map(\.count)
    }

    func saveCallCount() -> Int {
        saveSnapshots.count
    }

    func completedSaveCount() -> Int {
        completedSaves
    }

    func waitForCompletedSaveCount(_ expected: Int) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while completedSaves < expected, clock.now < deadline {
            do {
                try await clock.sleep(for: .milliseconds(1))
            } catch {
                return false
            }
        }
        return completedSaves >= expected
    }
}
