//
//  AgentDetectionCoordinatorTests.swift
//  PineTests
//
//  Unit tests for AgentDetectionCoordinator (issue #951).
//

import AppKit
import Testing
@testable import Pine

@MainActor
@Suite("AgentDetectionCoordinator Tests")
struct AgentDetectionCoordinatorTests {

    @Test func legacyTestParserExtractsPidAndCommand() {
        let output = "1234 /bin/bash\n5678 claude --verbose\n9012 codex"
        let processes = AgentDetectionCoordinator.parseLegacyPsOutputForTesting(
            output
        )
        #expect(processes.count == 3)
        #expect(processes[0].pid == 1234)
        #expect(processes[1].command == "claude --verbose")
    }

    @Test func legacyTestParserSkipsNonNumericLines() {
        let processes = AgentDetectionCoordinator.parseLegacyPsOutputForTesting(
            "PID COMMAND\n42 claude"
        )
        #expect(processes.count == 1)
        #expect(processes[0].pid == 42)
    }

    @Test func parsePsOutputHandlesEmptyInput() {
        #expect(AgentDetectionCoordinator.parsePsOutput("").isEmpty)
    }

    @Test func coordinatorFeedsSnapshotsToDetector() {
        let detector = AgentDetector()
        let runner: ProcessRunner = { _, _, _, _ in
            ProcessRunResult(
                stdout: completePsOutput(
                    (100, "claude"),
                    (200, "codex"),
                    (300, "bash")
                ),
                stderr: "",
                exitCode: 0,
                timedOut: false
            )
        }
        let coordinator = AgentDetectionCoordinator(detector: detector, terminalManager: nil, processRunner: runner, pollInterval: 0.05)
        coordinator.runSnapshotForTesting()
        #expect(detector.detectedSessions.count == 2)
        #expect(detector.detectedSessions[0].agentType == .claudeCode)
        #expect(detector.detectedSessions[1].agentType == .codex)
    }

    @Test func coordinatorReconcilesDoneWhenProcessExits() {
        let detector = AgentDetector()
        // Reference-type box so the @Sendable mock runner can read a
        // mutable value without capturing a mutable local (strict
        // concurrency forbids capturing `var` in @Sendable closures).
        nonisolated final class MockOutput: @unchecked Sendable { var value: String; init(_ v: String) { value = v } }
        let mockOutput = MockOutput(completePsOutput((100, "claude")))
        let runner: ProcessRunner = { _, _, _, _ in
            ProcessRunResult(stdout: mockOutput.value, stderr: "", exitCode: 0, timedOut: false)
        }
        let coordinator = AgentDetectionCoordinator(detector: detector, terminalManager: nil, processRunner: runner, pollInterval: 0.05)
        coordinator.runSnapshotForTesting()
        #expect(detector.activeCount == 1)
        // A valid non-agent row represents an authoritative full snapshot
        // containing no agents.
        mockOutput.value = completePsOutput()
        coordinator.runSnapshotForTesting()
        #expect(detector.detectedSessions[0].state == .done)
        #expect(detector.activeCount == 0)
    }

    @Test func emptyExitZeroPollIsFailedEvidenceNotTermination() throws {
        nonisolated final class MockOutput: @unchecked Sendable {
            var value = completePsOutput((100, "claude"))
        }
        let detector = AgentDetector(staleAfter: 0)
        let output = MockOutput()
        let coordinator = AgentDetectionCoordinator(
            detector: detector,
            terminalManager: nil,
            processRunner: { _, _, _, _ in
                ProcessRunResult(
                    stdout: output.value,
                    stderr: "",
                    exitCode: 0,
                    timedOut: false
                )
            }
        )
        coordinator.runSnapshotForTesting()
        let session = try #require(detector.session(forPID: 100))

        output.value = ""
        coordinator.runSnapshotForTesting()

        #expect(detector.session(forPID: 100) === session)
        #expect(session.state != .done)
        #expect(session.liveness == .stale)
    }

    @Test func whollyMalformedExitZeroPollIsFailedEvidenceNotTermination() throws {
        nonisolated final class MockOutput: @unchecked Sendable {
            var value = completePsOutput((100, "claude"))
        }
        let detector = AgentDetector(staleAfter: 0)
        let output = MockOutput()
        let coordinator = AgentDetectionCoordinator(
            detector: detector,
            terminalManager: nil,
            processRunner: { _, _, _, _ in
                ProcessRunResult(
                    stdout: output.value,
                    stderr: "",
                    exitCode: 0,
                    timedOut: false
                )
            }
        )
        coordinator.runSnapshotForTesting()
        let session = try #require(detector.session(forPID: 100))

        output.value = "PID COMMAND\nnot-a-pid claude"
        coordinator.runSnapshotForTesting()

        #expect(detector.session(forPID: 100) === session)
        #expect(session.state != .done)
        #expect(session.liveness == .stale)
    }

    @Test func partiallyMalformedExitZeroPollIsFailedEvidenceNotTermination() throws {
        nonisolated final class MockOutput: @unchecked Sendable {
            var value = completePsOutput((100, "claude"))
        }
        let detector = AgentDetector(staleAfter: 0)
        let output = MockOutput()
        let coordinator = AgentDetectionCoordinator(
            detector: detector,
            terminalManager: nil,
            processRunner: { _, _, _, _ in
                ProcessRunResult(
                    stdout: output.value,
                    stderr: "",
                    exitCode: 0,
                    timedOut: false
                )
            }
        )
        coordinator.runSnapshotForTesting()
        let session = try #require(detector.session(forPID: 100))

        output.value = completePsOutput() + "\nnot-a-pid claude"
        coordinator.runSnapshotForTesting()

        #expect(detector.session(forPID: 100) === session)
        #expect(session.state != .done)
        #expect(session.liveness == .stale)
    }

    @Test func missingWeekdayExitZeroPollIsFailedEvidenceNotTermination() throws {
        nonisolated final class MockOutput: @unchecked Sendable {
            var value = completePsOutput((100, "claude"))
        }
        let detector = AgentDetector(staleAfter: 0)
        let output = MockOutput()
        let coordinator = AgentDetectionCoordinator(
            detector: detector,
            terminalManager: nil,
            processRunner: { _, _, _, _ in
                ProcessRunResult(
                    stdout: output.value,
                    stderr: "",
                    exitCode: 0,
                    timedOut: false
                )
            }
        )
        coordinator.runSnapshotForTesting()
        let session = try #require(detector.session(forPID: 100))

        output.value = completePsOutput()
            + "\n100 1 100 Jul 22 15:08:40 2026 0:12.45 claude"
        coordinator.runSnapshotForTesting()

        #expect(detector.session(forPID: 100) === session)
        #expect(session.state != .done)
        #expect(session.liveness == .stale)
    }

    @Test func cleanLineBoundaryTruncationIsFailedEvidence() throws {
        nonisolated final class MockOutput: @unchecked Sendable {
            var value = completePsOutput((100, "claude"))
        }
        let detector = AgentDetector(staleAfter: 0)
        let output = MockOutput()
        let coordinator = AgentDetectionCoordinator(
            detector: detector,
            terminalManager: nil,
            processRunner: { _, _, _, _ in
                ProcessRunResult(
                    stdout: output.value,
                    stderr: "",
                    exitCode: 0,
                    timedOut: false
                )
            }
        )
        coordinator.runSnapshotForTesting()
        let session = try #require(detector.session(forPID: 100))

        // Every row is individually valid and PID 1 is present, but the ps
        // wrapper's end marker is missing.
        output.value = [
            psRow(pid: 1, command: "/sbin/launchd"),
            psRow(pid: 200, command: "codex"),
            psRow(
                pid: 99_999,
                command: "/bin/ps -eo pid=,ppid=,pgid=,lstart=,cputime=,command="
            ),
        ].joined(separator: "\n")
        coordinator.runSnapshotForTesting()

        #expect(detector.session(forPID: 100) === session)
        #expect(detector.session(forPID: 200) == nil)
        #expect(session.state != .done)
        #expect(session.liveness == .stale)
    }

    @Test func nonzeroPollPreservesSessionAsUncertain() throws {
        nonisolated final class MockResult: @unchecked Sendable {
            var value: ProcessRunResult
            init(_ value: ProcessRunResult) { self.value = value }
        }
        let detector = AgentDetector(staleAfter: 0)
        let result = MockResult(
            ProcessRunResult(
                stdout: completePsOutput((100, "claude")),
                stderr: "",
                exitCode: 0,
                timedOut: false
            )
        )
        let runner: ProcessRunner = { _, _, _, _ in result.value }
        let coordinator = AgentDetectionCoordinator(
            detector: detector,
            terminalManager: nil,
            processRunner: runner,
            pollInterval: 0.05
        )
        coordinator.runSnapshotForTesting()
        let session = try #require(detector.session(forPID: 100))
        let lastObservedAt = session.lastObservedAt

        result.value = ProcessRunResult(
            stdout: "",
            stderr: "ps failed",
            exitCode: 1,
            timedOut: false
        )
        coordinator.runSnapshotForTesting()

        #expect(detector.session(forPID: 100) === session)
        #expect(session.state == .idle)
        #expect(session.liveness == .stale)
        #expect(session.lastObservedAt == lastObservedAt)
    }

    @Test func timedOutPollDoesNotTreatPartialOutputAsAuthoritative() throws {
        nonisolated final class MockResult: @unchecked Sendable {
            var value: ProcessRunResult
            init(_ value: ProcessRunResult) { self.value = value }
        }
        let detector = AgentDetector(staleAfter: 60)
        let result = MockResult(
            ProcessRunResult(
                stdout: completePsOutput((100, "claude")),
                stderr: "",
                exitCode: 0,
                timedOut: false
            )
        )
        let runner: ProcessRunner = { _, _, _, _ in result.value }
        let coordinator = AgentDetectionCoordinator(
            detector: detector,
            terminalManager: nil,
            processRunner: runner,
            pollInterval: 0.05
        )
        coordinator.runSnapshotForTesting()
        let session = try #require(detector.session(forPID: 100))

        result.value = ProcessRunResult(
            stdout: completePsOutput((200, "codex")),
            stderr: "",
            exitCode: 0,
            timedOut: true
        )
        coordinator.runSnapshotForTesting()

        #expect(detector.session(forPID: 100) === session)
        #expect(detector.detectedSessions.count == 1)
        #expect(detector.detectedSessions.first?.agentType == .claudeCode)
    }

    @Test func newlyTerminatedTabSessionIsRetainedForOneSuccessfulPoll() throws {
        let detector = AgentDetector()
        detector.processSnapshotDidUpdate([
            DetectedProcess(pid: 500, command: "claude"),
        ])
        let previous = try #require(detector.session(forPID: 500))

        detector.processSnapshotDidUpdate([])
        let retained = AgentDetectionCoordinator.reconciledSession(
            previous: previous,
            ownership: TerminalAgentOwnershipEvidence(
                foreground: .idle,
                processes: []
            ),
            detector: detector,
            agentIdentityStillMatches: { _ in false },
            newlyTerminated: [previous.id]
        )

        #expect(previous.state == .done)
        #expect(previous.liveness == .terminated)
        #expect(retained === previous)
    }

    @Test func previouslyTerminatedTabSessionIsRemovedOnNextSuccessfulPoll() throws {
        let detector = AgentDetector()
        detector.processSnapshotDidUpdate([
            DetectedProcess(pid: 501, command: "codex"),
        ])
        let previous = try #require(detector.session(forPID: 501))
        detector.processSnapshotDidUpdate([])

        let reconciled = AgentDetectionCoordinator.reconciledSession(
            previous: previous,
            ownership: TerminalAgentOwnershipEvidence(
                foreground: .idle,
                processes: []
            ),
            detector: detector,
            agentIdentityStillMatches: { _ in false },
            newlyTerminated: []
        )

        #expect(reconciled == nil)
    }

    @Test func badgeRetentionSurvivesDetectorHistoryCleanup() throws {
        let detector = AgentDetector()
        detector.processSnapshotDidUpdate([
            DetectedProcess(pid: 502, command: "claude"),
        ])
        let previous = try #require(detector.session(forPID: 502))
        let newlyTerminated = detector.processSnapshotDidUpdate([])
        detector.clearFinishedSessions()

        let retained = AgentDetectionCoordinator.reconciledSession(
            previous: previous,
            ownership: TerminalAgentOwnershipEvidence(
                foreground: .idle,
                processes: []
            ),
            detector: detector,
            agentIdentityStillMatches: { _ in false },
            newlyTerminated: newlyTerminated
        )
        let dismissed = AgentDetectionCoordinator.reconciledSession(
            previous: retained,
            ownership: TerminalAgentOwnershipEvidence(
                foreground: .idle,
                processes: []
            ),
            detector: detector,
            agentIdentityStillMatches: { _ in false },
            newlyTerminated: []
        )

        #expect(retained === previous)
        #expect(dismissed == nil)
        #expect(detector.detectedSessions.isEmpty)
    }

    @Test func productionReconciliationRetainsAgentThroughForegroundChild()
        throws {
        let project = ProjectManager()
        project.paneManager.createTerminalPaneAtBottom(workingDirectory: nil)
        let tab = try #require(project.terminal.allTerminalTabs.first)
        let coordinator = AgentDetectionCoordinator(
            detector: project.terminal.agentDetector,
            terminalManager: project.terminal,
            processRunner: { _, _, _, _ in
                ProcessRunResult(
                    stdout: "",
                    stderr: "",
                    exitCode: 1,
                    timedOut: false
                )
            }
        )
        let agent = process(
            pid: 500,
            parent: 400,
            group: 500,
            command: "claude",
            startedAt: 500
        )
        let child = process(
            pid: 600,
            parent: 500,
            group: 600,
            command: "swift test",
            startedAt: 600
        )

        setLiveAgent(agent, on: tab)
        setForeground(agent, on: tab)
        coordinator.applySnapshotForTesting(processes: [agent])
        let session = try #require(tab.agentSession)

        setForeground(child, on: tab)
        coordinator.applySnapshotForTesting(processes: [agent, child])
        #expect(tab.agentSession === session)

        setLiveAgent(agent, on: tab)
        setForeground(agent, on: tab)
        coordinator.applySnapshotForTesting(processes: [agent])
        #expect(tab.agentSession === session)
    }

    @Test func unavailablePreciseStartPreservesDurableIdentityAndEvents()
        throws {
        let taskRegistry = AgentTaskRegistry()
        let project = configuredProject(
            path: "/tmp/pine-precise-loss-durable",
            registry: taskRegistry
        )
        let pane = project.paneManager.createTerminalPaneAtBottom(
            workingDirectory: nil
        )
        let tab = try #require(
            project.paneManager.terminalState(for: pane)?.activeTab
        )
        let coordinator = AgentDetectionCoordinator(
            detector: project.terminal.agentDetector,
            terminalManager: project.terminal
        )
        let agent = process(
            pid: 505,
            parent: 400,
            group: 505,
            command: "claude",
            startedAt: 505
        )

        setLiveAgent(agent, on: tab)
        setForeground(agent, on: tab)
        coordinator.applySnapshotForTesting(processes: [agent])
        let session = try #require(tab.agentSession)
        let evidence = try #require(session.processEvidence)
        let taskID = try #require(
            taskRegistry.taskID(forSessionID: session.id)
        )
        let initialTasks = taskRegistry.tasks
        let initialTask = try #require(taskRegistry.task(for: taskID))
        let runID = try #require(initialTask.runs.first?.id)

        coordinator.applySnapshotForTesting(processes: [
            replacing(agent, preciseStartedAt: nil, cpuTime: 1),
        ])

        let unavailableTask = try #require(taskRegistry.task(for: taskID))
        #expect(project.terminal.agentDetector.session(forPID: 505) === session)
        #expect(session.processEvidence == evidence)
        #expect(project.terminal.agentDetector.detectedSessions == [session])
        #expect(tab.agentSession == nil)
        #expect(taskRegistry.tasks.count == 1)
        #expect(unavailableTask.runs.map(\.id) == [runID])
        #expect(unavailableTask.runs.first?.liveness == .live)
        #expect(unavailableTask.runs.first?.endedAt == nil)
        #expect(unavailableTask.lifecycle == .active)
        #expect(unavailableTask.attention == initialTask.attention)
        #expect(unavailableTask.isUnread == initialTask.isUnread)
        #expect(AgentNotificationTransitionResolver.events(
            from: initialTasks,
            to: taskRegistry.tasks,
            accuracy: { _ in .processTerminationOnly }
        ).isEmpty)

        let unavailableTasks = taskRegistry.tasks
        coordinator.applySnapshotForTesting(processes: [
            replacing(agent, preciseStartedAt: evidence.observedStartedAt, cpuTime: 2),
        ])

        let confirmedTask = try #require(taskRegistry.task(for: taskID))
        #expect(tab.agentSession === session)
        #expect(session.processEvidence == evidence)
        #expect(taskRegistry.tasks.count == 1)
        #expect(confirmedTask.runs.map(\.id) == [runID])
        #expect(confirmedTask.runs.first?.liveness == .live)
        #expect(confirmedTask.runs.first?.endedAt == nil)
        #expect(confirmedTask.isUnread == initialTask.isUnread)
        #expect(AgentNotificationTransitionResolver.events(
            from: unavailableTasks,
            to: taskRegistry.tasks,
            accuracy: { _ in .processTerminationOnly }
        ).isEmpty)
    }

    @Test func preciseLossIsIsolatedAcrossAgentsAndProjects() throws {
        let taskRegistry = AgentTaskRegistry()
        let firstProject = configuredProject(
            path: "/tmp/pine-precise-loss-project-a",
            registry: taskRegistry
        )
        let secondProject = configuredProject(
            path: "/tmp/pine-precise-loss-project-b",
            registry: taskRegistry
        )
        let firstPane = firstProject.paneManager.createTerminalPaneAtBottom(
            workingDirectory: nil
        )
        let firstState = try #require(
            firstProject.paneManager.terminalState(for: firstPane)
        )
        let affectedTab = try #require(firstState.activeTab)
        let siblingTab = firstState.addTab(workingDirectory: nil)
        let secondPane = secondProject.paneManager.createTerminalPaneAtBottom(
            workingDirectory: nil
        )
        let otherProjectTab = try #require(
            secondProject.paneManager.terminalState(for: secondPane)?.activeTab
        )
        let affected = process(
            pid: 506,
            parent: 400,
            group: 506,
            command: "claude",
            startedAt: 506
        )
        let sibling = process(
            pid: 507,
            parent: 400,
            group: 507,
            command: "codex",
            startedAt: 507
        )
        let otherProjectAgent = process(
            pid: 508,
            parent: 400,
            group: 508,
            command: "pi",
            startedAt: 508
        )
        let firstCoordinator = AgentDetectionCoordinator(
            detector: firstProject.terminal.agentDetector,
            terminalManager: firstProject.terminal
        )
        let secondCoordinator = AgentDetectionCoordinator(
            detector: secondProject.terminal.agentDetector,
            terminalManager: secondProject.terminal
        )

        setLiveAgent(affected, on: affectedTab)
        setForeground(affected, on: affectedTab)
        setLiveAgent(sibling, on: siblingTab)
        setForeground(sibling, on: siblingTab)
        setLiveAgent(otherProjectAgent, on: otherProjectTab)
        setForeground(otherProjectAgent, on: otherProjectTab)
        firstCoordinator.applySnapshotForTesting(processes: [affected, sibling])
        secondCoordinator.applySnapshotForTesting(processes: [otherProjectAgent])

        let affectedSession = try #require(affectedTab.agentSession)
        let siblingSession = try #require(siblingTab.agentSession)
        let otherProjectSession = try #require(otherProjectTab.agentSession)
        let affectedTaskID = try #require(
            taskRegistry.taskID(forSessionID: affectedSession.id)
        )
        let siblingTaskID = try #require(
            taskRegistry.taskID(forSessionID: siblingSession.id)
        )
        let otherProjectTaskID = try #require(
            taskRegistry.taskID(forSessionID: otherProjectSession.id)
        )
        let otherProjectTask = try #require(
            taskRegistry.task(for: otherProjectTaskID)
        )

        firstCoordinator.applySnapshotForTesting(processes: [
            replacing(affected, preciseStartedAt: nil, cpuTime: 1),
            replacing(
                sibling,
                preciseStartedAt: sibling.preciseStartedAt,
                cpuTime: 1
            ),
        ])

        #expect(affectedTab.agentSession == nil)
        #expect(siblingTab.agentSession === siblingSession)
        #expect(otherProjectTab.agentSession === otherProjectSession)
        #expect(
            firstProject.terminal.agentDetector.session(forPID: affected.pid)
                === affectedSession
        )
        #expect(taskRegistry.tasks.count == 3)
        #expect(taskRegistry.task(for: affectedTaskID)?.runs.count == 1)
        #expect(taskRegistry.task(for: siblingTaskID)?.runs.count == 1)
        #expect(taskRegistry.task(for: otherProjectTaskID) == otherProjectTask)
    }

    @Test func pendingLaunchClaimSurvivesUnavailableAndWrongReplacement()
        throws {
        let taskRegistry = AgentTaskRegistry(claimTTL: .seconds(30))
        let project = configuredProject(
            path: "/tmp/pine-precise-loss-claim",
            registry: taskRegistry
        )
        let pane = project.paneManager.createTerminalPaneAtBottom(
            workingDirectory: nil
        )
        let tab = try #require(
            project.paneManager.terminalState(for: pane)?.activeTab
        )
        let coordinator = AgentDetectionCoordinator(
            detector: project.terminal.agentDetector,
            terminalManager: project.terminal
        )
        let original = process(
            pid: 509,
            parent: 400,
            group: 509,
            command: "codex",
            startedAt: 509,
            startIdentifier: "same-coarse-second"
        )

        coordinator.applySnapshotForTesting(processes: [original])
        let originalSession = try #require(
            project.terminal.agentDetector.session(forPID: original.pid)
        )
        let originalGeneration = try #require(
            originalSession.processEvidence?.processGeneration
        )
        guard case .reserved(let reservation) =
                project.terminal.prepareAgentLaunch(
                    in: tab,
                    descriptor: AgentDescriptor(
                        agentType: .codex,
                        launchExecutable: "codex"
                    ),
                    title: nil,
                    objective: nil
                ) else {
            Issue.record("terminal launch reservation was rejected")
            return
        }
        #expect(taskRegistry.armLaunch(reservation))
        setLiveAgent(original, on: tab)
        setForeground(original, on: tab)

        coordinator.applySnapshotForTesting(processes: [
            replacing(original, preciseStartedAt: nil, cpuTime: 1),
        ])

        #expect(taskRegistry.isLaunchPending(reservation))
        #expect(taskRegistry.task(for: reservation.taskID)?.runs.isEmpty == true)
        #expect(tab.agentSession == nil)
        #expect(
            project.terminal.agentDetector.session(forPID: original.pid)
                === originalSession
        )
        #expect(
            originalSession.processEvidence?.processGeneration
                == originalGeneration
        )

        coordinator.applySnapshotForTesting(processes: [
            replacing(
                original,
                preciseStartedAt: original.preciseStartedAt,
                cpuTime: 2
            ),
        ])

        #expect(tab.agentSession === originalSession)
        #expect(taskRegistry.isLaunchPending(reservation))
        #expect(taskRegistry.task(for: reservation.taskID)?.runs.isEmpty == true)
        #expect(
            originalSession.processEvidence?.processGeneration
                == originalGeneration
        )

        let wrongReplacement = replacing(
            original,
            preciseStartedAt: Date(timeIntervalSince1970: 509.25),
            cpuTime: 3
        )
        setLiveAgent(wrongReplacement, on: tab)
        setForeground(wrongReplacement, on: tab)
        coordinator.applySnapshotForTesting(processes: [wrongReplacement])

        let replacementSession = try #require(
            project.terminal.agentDetector.session(forPID: original.pid)
        )
        #expect(replacementSession !== originalSession)
        #expect(originalSession.state == .done)
        #expect(originalSession.liveness == .terminated)
        #expect(
            replacementSession.processEvidence?.processGeneration
                == originalGeneration + 1
        )
        #expect(taskRegistry.isLaunchPending(reservation))
        #expect(taskRegistry.task(for: reservation.taskID)?.runs.isEmpty == true)
        #expect(taskRegistry.taskID(forSessionID: replacementSession.id) == nil)
        #expect(taskRegistry.tasks.count == 1)
    }

    @Test func pineOwnedRunSurvivesPreciseLossAndEndsOnceOnReplacement()
        throws {
        let taskRegistry = AgentTaskRegistry(claimTTL: .seconds(30))
        let project = configuredProject(
            path: "/tmp/pine-precise-loss-owned",
            registry: taskRegistry
        )
        let pane = project.paneManager.createTerminalPaneAtBottom(
            workingDirectory: nil
        )
        let tab = try #require(
            project.paneManager.terminalState(for: pane)?.activeTab
        )
        let coordinator = AgentDetectionCoordinator(
            detector: project.terminal.agentDetector,
            terminalManager: project.terminal
        )
        guard case .reserved(let reservation) =
                project.terminal.prepareAgentLaunch(
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
        let startedAt = Date().addingTimeInterval(1)
        let agent = process(
            pid: 511,
            parent: 400,
            group: 511,
            command: "claude",
            startedAt: startedAt.timeIntervalSince1970,
            startIdentifier: "same-coarse-second"
        )

        setLiveAgent(agent, on: tab)
        setForeground(agent, on: tab)
        coordinator.applySnapshotForTesting(processes: [agent])

        let session = try #require(tab.agentSession)
        let evidence = try #require(session.processEvidence)
        let originalTask = try #require(
            taskRegistry.task(for: reservation.taskID)
        )
        let runID = try #require(originalTask.runs.first?.id)
        #expect(!taskRegistry.isLaunchPending(reservation))
        #expect(taskRegistry.taskID(forSessionID: session.id) == reservation.taskID)
        #expect(originalTask.origin == .pineLaunched)
        #expect(originalTask.lifecycle == .active)
        #expect(originalTask.runs.count == 1)
        #expect(originalTask.runs.first?.liveness == .live)

        let beforeUnavailable = taskRegistry.tasks
        coordinator.applySnapshotForTesting(processes: [
            replacing(agent, preciseStartedAt: nil, cpuTime: 1),
        ])

        let unavailableTask = try #require(
            taskRegistry.task(for: reservation.taskID)
        )
        #expect(tab.agentSession == nil)
        #expect(project.terminal.agentDetector.session(forPID: 511) === session)
        #expect(session.processEvidence == evidence)
        #expect(taskRegistry.tasks.count == 1)
        #expect(unavailableTask.lifecycle == .active)
        #expect(unavailableTask.route.availability == .available)
        #expect(unavailableTask.runs.map(\.id) == [runID])
        #expect(unavailableTask.runs.first?.liveness == .live)
        #expect(unavailableTask.runs.first?.endedAt == nil)
        #expect(unavailableTask.isUnread == originalTask.isUnread)
        #expect(AgentNotificationTransitionResolver.events(
            from: beforeUnavailable,
            to: taskRegistry.tasks,
            accuracy: { _ in .processTerminationOnly }
        ).isEmpty)

        coordinator.applySnapshotForTesting(processes: [
            replacing(
                agent,
                preciseStartedAt: evidence.observedStartedAt,
                cpuTime: 2
            ),
        ])

        let confirmedTask = try #require(
            taskRegistry.task(for: reservation.taskID)
        )
        #expect(tab.agentSession === session)
        #expect(session.processEvidence == evidence)
        #expect(taskRegistry.tasks.count == 1)
        #expect(confirmedTask.lifecycle == .active)
        #expect(confirmedTask.runs.map(\.id) == [runID])
        #expect(confirmedTask.runs.first?.liveness == .live)
        #expect(confirmedTask.runs.first?.endedAt == nil)

        let beforeReplacement = taskRegistry.tasks
        let replacement = replacing(
            agent,
            preciseStartedAt: startedAt.addingTimeInterval(0.25),
            cpuTime: 3
        )
        setLiveAgent(replacement, on: tab)
        setForeground(replacement, on: tab)
        coordinator.applySnapshotForTesting(processes: [replacement])

        let replacementSession = try #require(tab.agentSession)
        let endedTask = try #require(
            taskRegistry.task(for: reservation.taskID)
        )
        let replacementTaskID = try #require(
            taskRegistry.taskID(forSessionID: replacementSession.id)
        )
        let replacementTask = try #require(
            taskRegistry.task(for: replacementTaskID)
        )
        let endedAt = try #require(endedTask.runs.first?.endedAt)
        let events = AgentNotificationTransitionResolver.events(
            from: beforeReplacement,
            to: taskRegistry.tasks,
            accuracy: { _ in .processTerminationOnly }
        )
        #expect(replacementSession !== session)
        #expect(session.state == .done)
        #expect(session.liveness == .terminated)
        #expect(endedTask.lifecycle == .paused)
        #expect(endedTask.runs.map(\.id) == [runID])
        #expect(endedTask.runs.first?.liveness == .terminated)
        #expect(replacementTaskID != reservation.taskID)
        #expect(replacementTask.origin == .discoveredInTerminal)
        #expect(replacementTask.lifecycle == .active)
        #expect(replacementTask.runs.map(\.id) == [replacementSession.id])
        #expect(taskRegistry.tasks.count == 2)
        #expect(taskRegistry.tasks.filter {
            $0.lifecycle == .active && $0.runs.last?.liveness == .live
        }.count == 1)
        #expect(events.map(\.kind) == [.processEnded])

        coordinator.applySnapshotForTesting(processes: [
            replacing(
                replacement,
                preciseStartedAt: replacement.preciseStartedAt,
                cpuTime: 4
            ),
        ])

        #expect(taskRegistry.tasks.count == 2)
        #expect(
            taskRegistry.task(for: reservation.taskID)?
                .runs.first?.endedAt == endedAt
        )
        #expect(
            taskRegistry.task(for: reservation.taskID)?.runs.count == 1
        )
        #expect(
            taskRegistry.task(for: replacementTaskID)?.runs.count == 1
        )
    }

    @Test func unrelatedForegroundGroupDoesNotInheritAgentSession() throws {
        let project = ProjectManager()
        project.paneManager.createTerminalPaneAtBottom(workingDirectory: nil)
        let tab = try #require(project.terminal.allTerminalTabs.first)
        let coordinator = AgentDetectionCoordinator(
            detector: project.terminal.agentDetector,
            terminalManager: project.terminal
        )
        let agent = process(
            pid: 510,
            parent: 400,
            group: 510,
            command: "codex",
            startedAt: 510
        )
        let unrelated = process(
            pid: 710,
            parent: 400,
            group: 710,
            command: "git status",
            startedAt: 710
        )

        setLiveAgent(agent, on: tab)
        setForeground(agent, on: tab)
        coordinator.applySnapshotForTesting(processes: [agent])
        #expect(tab.agentSession != nil)

        setForeground(unrelated, on: tab)
        coordinator.applySnapshotForTesting(processes: [agent, unrelated])
        #expect(tab.agentSession == nil)
    }

    @Test func exactForegroundWitnessMustDescendFromAgent() throws {
        let project = ProjectManager()
        project.paneManager.createTerminalPaneAtBottom(workingDirectory: nil)
        let tab = try #require(project.terminal.allTerminalTabs.first)
        let coordinator = AgentDetectionCoordinator(
            detector: project.terminal.agentDetector,
            terminalManager: project.terminal
        )
        let agent = process(
            pid: 515,
            parent: 400,
            group: 515,
            command: "claude",
            startedAt: 515
        )
        let unrelatedWitness = process(
            pid: 715,
            parent: 400,
            group: 715,
            command: "git status",
            startedAt: 715
        )
        let staleGroupMember = process(
            pid: 716,
            parent: 515,
            group: 715,
            command: "swift test",
            startedAt: 716
        )

        setLiveAgent(agent, on: tab)
        setForeground(agent, on: tab)
        coordinator.applySnapshotForTesting(processes: [agent])
        #expect(tab.agentSession != nil)

        setForeground(unrelatedWitness, on: tab)
        coordinator.applySnapshotForTesting(
            processes: [agent, unrelatedWitness, staleGroupMember]
        )
        #expect(tab.agentSession == nil)
    }

    @Test func replacementAgentInvalidatesPreviousGeneration() throws {
        let project = ProjectManager()
        project.paneManager.createTerminalPaneAtBottom(workingDirectory: nil)
        let tab = try #require(project.terminal.allTerminalTabs.first)
        let coordinator = AgentDetectionCoordinator(
            detector: project.terminal.agentDetector,
            terminalManager: project.terminal
        )
        let original = process(
            pid: 520,
            parent: 400,
            group: 520,
            command: "claude",
            startedAt: 520.1,
            startIdentifier: "same-coarse-second"
        )
        let replacement = process(
            pid: 520,
            parent: 400,
            group: 520,
            command: "codex",
            startedAt: 520.2,
            startIdentifier: "same-coarse-second"
        )

        setLiveAgent(original, on: tab)
        setForeground(original, on: tab)
        coordinator.applySnapshotForTesting(processes: [original])
        let previous = try #require(tab.agentSession)
        let previousGeneration = try #require(
            previous.processEvidence?.processGeneration
        )

        setLiveAgent(replacement, on: tab)
        setForeground(replacement, on: tab)
        coordinator.applySnapshotForTesting(processes: [replacement])
        let current = try #require(tab.agentSession)

        #expect(current !== previous)
        #expect(previous.liveness == .terminated)
        #expect(current.agentType == .codex)
        #expect(
            current.processEvidence?.processGeneration != previousGeneration
        )
    }

    @Test func unrelatedPIDReuseInvalidatesPreviousAssociation() throws {
        let project = ProjectManager()
        project.paneManager.createTerminalPaneAtBottom(workingDirectory: nil)
        let tab = try #require(project.terminal.allTerminalTabs.first)
        let coordinator = AgentDetectionCoordinator(
            detector: project.terminal.agentDetector,
            terminalManager: project.terminal
        )
        let agent = process(
            pid: 530,
            parent: 400,
            group: 530,
            command: "pi",
            startedAt: 530
        )
        let reused = process(
            pid: 530,
            parent: 400,
            group: 530,
            command: "git status",
            startedAt: 531
        )

        setLiveAgent(agent, on: tab)
        setForeground(agent, on: tab)
        coordinator.applySnapshotForTesting(processes: [agent])
        let previous = try #require(tab.agentSession)

        setForeground(reused, on: tab)
        coordinator.applySnapshotForTesting(processes: [reused])

        #expect(tab.agentSession == nil)
        #expect(previous.liveness == .terminated)
    }

    @Test func foregroundGroupChangeDuringSamplingFailsClosed() throws {
        let project = ProjectManager()
        project.paneManager.createTerminalPaneAtBottom(workingDirectory: nil)
        let tab = try #require(project.terminal.allTerminalTabs.first)
        let coordinator = AgentDetectionCoordinator(
            detector: project.terminal.agentDetector,
            terminalManager: project.terminal
        )
        let agent = process(
            pid: 540,
            parent: 400,
            group: 540,
            command: "claude",
            startedAt: 540
        )
        let child = process(
            pid: 640,
            parent: 540,
            group: 640,
            command: "swift test",
            startedAt: 640
        )

        setLiveAgent(agent, on: tab)
        setForeground(agent, on: tab)
        coordinator.applySnapshotForTesting(processes: [agent])
        #expect(tab.agentSession != nil)

        setForeground(child, on: tab)
        var samples: [Int32] = [640, 740]
        tab.foregroundProcessIDResolverForTesting = {
            samples.isEmpty ? 740 : samples.removeFirst()
        }
        coordinator.applySnapshotForTesting(processes: [agent, child])

        #expect(tab.agentSession == nil)
        #expect(samples.isEmpty)
    }

    @Test func nonAuthoritativeAgentGenerationCannotOwnChildGroup() throws {
        let project = ProjectManager()
        project.paneManager.createTerminalPaneAtBottom(workingDirectory: nil)
        let tab = try #require(project.terminal.allTerminalTabs.first)
        let coordinator = AgentDetectionCoordinator(
            detector: project.terminal.agentDetector,
            terminalManager: project.terminal
        )
        let agent = DetectedProcess(
            pid: 550,
            parentProcessID: 400,
            processGroupID: 550,
            command: "claude",
            cpuTime: 0,
            startIdentifier: "coarse-only"
        )
        let child = process(
            pid: 650,
            parent: 550,
            group: 650,
            command: "swift test",
            startedAt: 650
        )

        setForeground(child, on: tab)
        coordinator.applySnapshotForTesting(processes: [agent, child])

        #expect(project.terminal.agentDetector.session(forPID: 550) != nil)
        #expect(tab.agentSession == nil)
    }

    @Test func mismatchedAgentStartWitnessCannotOwnChildGroup() throws {
        let detector = AgentDetector()
        let agent = process(
            pid: 560,
            parent: 400,
            group: 560,
            command: "codex",
            startedAt: 560
        )
        detector.processSnapshotDidUpdate([agent])
        let session = try #require(detector.session(forPID: 560))
        let mismatchedAgent = process(
            pid: 560,
            parent: 400,
            group: 560,
            command: "codex",
            startedAt: 560.5,
            startIdentifier: agent.startIdentifier
        )
        let child = process(
            pid: 660,
            parent: 560,
            group: 660,
            command: "swift test",
            startedAt: 660
        )
        let childStartedAt = try #require(child.preciseStartedAt)
        let childIdentity = try #require(
            TerminalProcessStartIdentity(
                processID: child.pid,
                startedAt: childStartedAt
            )
        )

        let result = AgentDetectionCoordinator.reconciledSession(
            previous: session,
            ownership: TerminalAgentOwnershipEvidence(
                foreground: .running(
                    processGroupID: 660,
                    identity: childIdentity
                ),
                processes: [mismatchedAgent, child]
            ),
            detector: detector,
            agentIdentityStillMatches: { _ in true },
            newlyTerminated: []
        )

        #expect(result == nil)
    }

    @Test func exitedAgentDuringReconciliationCannotRetainChildOwnership()
        throws {
        let project = ProjectManager()
        project.paneManager.createTerminalPaneAtBottom(workingDirectory: nil)
        let tab = try #require(project.terminal.allTerminalTabs.first)
        let coordinator = AgentDetectionCoordinator(
            detector: project.terminal.agentDetector,
            terminalManager: project.terminal
        )
        let agent = process(
            pid: 570,
            parent: 400,
            group: 570,
            command: "claude",
            startedAt: 570
        )
        let child = process(
            pid: 670,
            parent: 570,
            group: 670,
            command: "swift test",
            startedAt: 670
        )

        setLiveAgent(agent, on: tab)
        setForeground(agent, on: tab)
        coordinator.applySnapshotForTesting(processes: [agent])
        #expect(tab.agentSession != nil)

        setForeground(child, on: tab)
        tab.agentProcessIdentityResolverForTesting = { _ in nil }
        coordinator.applySnapshotForTesting(processes: [agent, child])

        #expect(tab.agentSession == nil)
    }

    @Test func replacedAgentDuringReconciliationCannotRetainChildOwnership()
        throws {
        let project = ProjectManager()
        project.paneManager.createTerminalPaneAtBottom(workingDirectory: nil)
        let tab = try #require(project.terminal.allTerminalTabs.first)
        let coordinator = AgentDetectionCoordinator(
            detector: project.terminal.agentDetector,
            terminalManager: project.terminal
        )
        let agent = process(
            pid: 580,
            parent: 400,
            group: 580,
            command: "codex",
            startedAt: 580
        )
        let child = process(
            pid: 680,
            parent: 580,
            group: 680,
            command: "swift test",
            startedAt: 680
        )

        setLiveAgent(agent, on: tab)
        setForeground(agent, on: tab)
        coordinator.applySnapshotForTesting(processes: [agent])
        #expect(tab.agentSession != nil)

        let replacementIdentity = try #require(
            TerminalProcessStartIdentity(
                processID: agent.pid,
                startedAt: Date(timeIntervalSince1970: 580.5)
            )
        )
        setForeground(child, on: tab)
        tab.agentProcessIdentityResolverForTesting = { processID in
            processID == agent.pid ? replacementIdentity : nil
        }
        coordinator.applySnapshotForTesting(processes: [agent, child])

        #expect(tab.agentSession == nil)
    }

    @Test func failedPollExpiryRuleOnlyRemovesTerminatedAssociation() {
        let live = AgentSession(agentType: .claudeCode)
        let stale = AgentSession(
            agentType: .codex,
            state: .executing,
            liveness: .stale
        )
        let terminated = AgentSession(
            agentType: .pi,
            state: .done,
            liveness: .terminated
        )

        #expect(
            AgentDetectionCoordinator.shouldExpireAfterFailedSnapshot(live)
                == false
        )
        #expect(
            AgentDetectionCoordinator.shouldExpireAfterFailedSnapshot(stale)
                == false
        )
        #expect(
            AgentDetectionCoordinator.shouldExpireAfterFailedSnapshot(terminated)
                == true
        )
    }

    @Test func coordinatorDoesNotDoubleCount() {
        let detector = AgentDetector()
        let runner: ProcessRunner = { _, _, _, _ in
            ProcessRunResult(
                stdout: completePsOutput((100, "claude")),
                stderr: "",
                exitCode: 0,
                timedOut: false
            )
        }
        let coordinator = AgentDetectionCoordinator(detector: detector, terminalManager: nil, processRunner: runner, pollInterval: 0.05)
        coordinator.runSnapshotForTesting()
        coordinator.runSnapshotForTesting()
        #expect(detector.detectedSessions.count == 1)
    }

    @Test func coordinatorRunsPsWithFixedUTCAndCLocale() {
        nonisolated final class Invocation: @unchecked Sendable {
            private let lock = NSLock()
            private var executable = ""
            private var arguments: [String] = []

            func record(executable: String, arguments: [String]) {
                lock.lock()
                self.executable = executable
                self.arguments = arguments
                lock.unlock()
            }

            var captured: (String, [String]) {
                lock.lock()
                defer { lock.unlock() }
                return (executable, arguments)
            }
        }

        let invocation = Invocation()
        let coordinator = AgentDetectionCoordinator(
            detector: AgentDetector(),
            terminalManager: nil,
            processRunner: { executable, arguments, _, _ in
                invocation.record(
                    executable: executable,
                    arguments: arguments
                )
                return ProcessRunResult(
                    stdout: completePsOutput(),
                    stderr: "",
                    exitCode: 0,
                    timedOut: false
                )
            }
        )

        coordinator.runSnapshotForTesting()

        let captured = invocation.captured
        #expect(captured.0 == "/bin/sh")
        #expect(captured.1.first == "-c")
        let command = captured.1.last ?? ""
        #expect(command.contains("TZ=UTC LC_ALL=C /bin/ps"))
        #expect(
            command.contains(
                "pid=,ppid=,pgid=,lstart=,cputime=,command="
            )
        )
        #expect(command.contains(AgentDetectionCoordinator.psCompletionMarker))
    }

    @Test func startStopIsIdempotent() {
        let detector = AgentDetector()
        let runner: ProcessRunner = { _, _, _, _ in ProcessRunResult(stdout: "", stderr: "", exitCode: 0, timedOut: false) }
        let coordinator = AgentDetectionCoordinator(detector: detector, terminalManager: nil, processRunner: runner, pollInterval: 0.05)
        #expect(!coordinator.isRunning)
        coordinator.start()
        #expect(coordinator.isRunning)
        coordinator.start()
        coordinator.stop()
        #expect(!coordinator.isRunning)
        coordinator.stop()
    }

    @Test func start_pollsOffMainWithoutCrashing() async throws {
        // Regression for the macOS 27 crash shipped in release 1.31.1: the
        // timer's `setEventHandler` closure was written inline inside the
        // `@MainActor` `start()`, so under `SWIFT_DEFAULT_ACTOR_ISOLATION =
        // MainActor` the closure literal inherited MainActor isolation. The
        // `DispatchSource` timer invokes its handler directly on `pollQueue`
        // (no actor hop), so Swift's `swift_task_isCurrentExecutorWithFlagsImpl`
        // check tripped `dispatch_assert_queue(main)` and trapped the process
        // ~2s after the first terminal was created — i.e. right after opening
        // a project. The handler is now built in the `nonisolated`
        // `makePollHandler()` so the closure is nonisolated.
        //
        // `runSnapshotForTesting()` cannot catch this — it bypasses the
        // dispatch queue entirely. This test lets the real timer fire several
        // times on `pollQueue`: with the bug the process traps here (failing
        // the whole suite); with the nonisolated handler it completes.
        //
        // This is the SOLE automated guard for the timer-handler isolation
        // class — the repo's `check_nonisolated.py` lint operates at type
        // granularity and its queue patterns do not cover `DispatchSource` /
        // `setEventHandler`, so it cannot see closure-literal isolation. Keep
        // this test behavioral (assert the handler fired AND the snapshot
        // reached the detector), not just "process survived".
        //
        // Reference-type box so the @Sendable mock runner can bump a counter
        // without capturing a mutable local (strict concurrency forbids
        // capturing `var` in @Sendable closures). Atomic via NSLock.
        nonisolated final class FireCounter: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0
            func increment() { lock.lock(); value += 1; lock.unlock() }
            var count: Int { lock.lock(); defer { lock.unlock() }; return value }
        }
        let detector = AgentDetector()
        let fires = FireCounter()
        let runner: ProcessRunner = { _, _, _, _ in
            fires.increment()
            return ProcessRunResult(
                stdout: completePsOutput((100, "claude")),
                stderr: "",
                exitCode: 0,
                timedOut: false
            )
        }
        let coordinator = AgentDetectionCoordinator(
            detector: detector, terminalManager: nil,
            processRunner: runner, pollInterval: 0.05
        )
        coordinator.start()
        // ~6 polls on pollQueue; the bug would kill the process in this window.
        try await Task.sleep(for: .milliseconds(300))
        coordinator.stop()
        // The timer handler actually fired on pollQueue (guards against a
        // false pass under extreme CI load where no fire occurs).
        #expect(fires.count >= 1)
        // The snapshot reached the detector via the real dispatch path
        // (pollQueue -> captureSnapshot -> DispatchQueue.main.async hop ->
        // applySnapshot). The main hop drains while `Task.sleep` suspends the
        // @MainActor test, so `detectedSessions` is populated by now. This is
        // the assertion that proves end-to-end polling works — without it the
        // test reduces to "the process didn't trap".
        #expect(detector.detectedSessions.count >= 1)
        #expect(detector.detectedSessions.first?.agentType == .claudeCode)
        #expect(!coordinator.isRunning)
    }

    @Test func stoppedLifecycleDiscardsBlockedInFlightResult() async throws {
        nonisolated final class BlockingRunner: @unchecked Sendable {
            private let condition = NSCondition()
            private var started = false
            private var released = false

            func run() -> ProcessRunResult {
                condition.lock()
                started = true
                condition.broadcast()
                while !released {
                    condition.wait()
                }
                condition.unlock()
                return ProcessRunResult(
                    stdout: completePsOutput((100, "claude")),
                    stderr: "",
                    exitCode: 0,
                    timedOut: false
                )
            }

            var hasStarted: Bool {
                condition.lock()
                defer { condition.unlock() }
                return started
            }

            func release() {
                condition.lock()
                released = true
                condition.broadcast()
                condition.unlock()
            }
        }

        let blocked = BlockingRunner()
        let detector = AgentDetector()
        let coordinator = AgentDetectionCoordinator(
            detector: detector,
            terminalManager: nil,
            processRunner: { _, _, _, _ in blocked.run() },
            pollInterval: 0.01
        )
        coordinator.start()
        for _ in 0..<100 where !blocked.hasStarted {
            try await Task.sleep(for: .milliseconds(5))
        }
        let didStart = blocked.hasStarted

        coordinator.stop()
        blocked.release()
        try await Task.sleep(for: .milliseconds(100))

        #expect(didStart)
        #expect(!coordinator.isRunning)
        #expect(detector.detectedSessions.isEmpty)
    }

    @Test func restartedLifecycleRejectsPriorBlockedGeneration() async throws {
        nonisolated final class RestartRunner: @unchecked Sendable {
            private let condition = NSCondition()
            private var callCount = 0
            private var firstStarted = false
            private var firstReleased = false

            func run() -> ProcessRunResult {
                condition.lock()
                callCount += 1
                let call = callCount
                if call == 1 {
                    firstStarted = true
                    condition.broadcast()
                    while !firstReleased {
                        condition.wait()
                    }
                }
                condition.unlock()
                let output = call == 1
                    ? completePsOutput((100, "claude"))
                    : completePsOutput((200, "codex"))
                return ProcessRunResult(
                    stdout: output,
                    stderr: "",
                    exitCode: 0,
                    timedOut: false
                )
            }

            var hasStarted: Bool {
                condition.lock()
                defer { condition.unlock() }
                return firstStarted
            }

            func releaseFirst() {
                condition.lock()
                firstReleased = true
                condition.broadcast()
                condition.unlock()
            }

            var calls: Int {
                condition.lock()
                defer { condition.unlock() }
                return callCount
            }
        }

        let runner = RestartRunner()
        let detector = AgentDetector()
        let coordinator = AgentDetectionCoordinator(
            detector: detector,
            terminalManager: nil,
            processRunner: { _, _, _, _ in runner.run() },
            pollInterval: 0.01
        )
        coordinator.start()
        for _ in 0..<100 where !runner.hasStarted {
            try await Task.sleep(for: .milliseconds(5))
        }
        let didStart = runner.hasStarted

        coordinator.stop()
        coordinator.start()
        runner.releaseFirst()
        for _ in 0..<100 where runner.calls < 2 {
            try await Task.sleep(for: .milliseconds(5))
        }
        for _ in 0..<100 where detector.session(forPID: 200) == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        coordinator.stop()

        #expect(didStart)
        #expect(runner.calls >= 2)
        #expect(detector.detectedSessions.count == 1)
        #expect(detector.session(forPID: 100) == nil)
        #expect(detector.session(forPID: 200)?.agentType == .codex)
    }

    @Test func sessionForPIDReturnsActiveSession() {
        let detector = AgentDetector()
        detector.processSnapshotDidUpdate([DetectedProcess(pid: 500, command: "claude")])
        let session = detector.session(forPID: 500)
        #expect(session != nil)
        #expect(session?.agentType == .claudeCode)
    }

    @Test func sessionForPIDReturnsNilForUnknown() {
        let detector = AgentDetector()
        detector.processSnapshotDidUpdate([DetectedProcess(pid: 500, command: "claude")])
        #expect(detector.session(forPID: 999) == nil)
    }

    @Test func sessionForPIDReturnsNilForDone() {
        let detector = AgentDetector()
        detector.processSnapshotDidUpdate([DetectedProcess(pid: 500, command: "claude")])
        detector.processSnapshotDidUpdate([])
        #expect(detector.session(forPID: 500) == nil)
    }

    @Test func badgeColorUsesAgentTypeColor() {
        for agentType in [AgentType.claudeCode, .codex, .aider, .copilot, .pi] {
            let session = AgentSession(agentType: agentType)
            #expect(session.agentType.color == agentType.color)
        }
    }

    @Test func badgeColorForGenericIsGray() {
        let session = AgentSession(agentType: .generic(name: "custom"))
        #expect(session.agentType.color == .systemGray)
    }

    @Test func tooltipFormatIsDisplayNameAndState() {
        let session = AgentSession(agentType: .claudeCode, state: .executing)
        let expected = "\(session.agentType.displayName) — \(session.state.displayName)"
        #expect(expected.hasPrefix("Claude Code — "))
        #expect(expected.hasSuffix(session.state.displayName))
    }

    // MARK: - cputime parsing (#1112 fix: `times=` was an invalid ps keyword;
    // the coordinator now polls `cputime=` and parses `[[DD-]HH:]MM:SS[.cc]`.)

    @Test func parseCpuTimeHandlesMmSs() {
        #expect(AgentDetectionCoordinator.parseCpuTime("0:00.08") == 0)
        #expect(AgentDetectionCoordinator.parseCpuTime("1:15") == 75)
        #expect(AgentDetectionCoordinator.parseCpuTime("99:15.60") == 5955)
    }

    @Test func parseCpuTimeHandlesHhMmSsAndDayField() {
        #expect(AgentDetectionCoordinator.parseCpuTime("1:23:45") == 5025)
        // 2 days, 4 hours, 10 minutes, 27 seconds.
        #expect(AgentDetectionCoordinator.parseCpuTime("2-04:10:27") == 187827)
    }

    @Test func parseCpuTimeRejectsBareIntegerAndGarbage() {
        // A bare integer is a command argument (e.g. `--port 8080`), NOT a
        // cputime value — must return nil so the command string is preserved.
        #expect(AgentDetectionCoordinator.parseCpuTime("8080") == nil)
        #expect(AgentDetectionCoordinator.parseCpuTime("--verbose") == nil)
        #expect(AgentDetectionCoordinator.parseCpuTime("") == nil)
    }

    @Test func parseCpuTimeRejectsInvalidRangesAndShapes() {
        #expect(AgentDetectionCoordinator.parseCpuTime("1:60") == nil)
        #expect(AgentDetectionCoordinator.parseCpuTime("24:00:00") == nil)
        #expect(AgentDetectionCoordinator.parseCpuTime("1:60:00") == nil)
        #expect(AgentDetectionCoordinator.parseCpuTime("1-24:00:00") == nil)
        #expect(AgentDetectionCoordinator.parseCpuTime("1-23:00") == nil)
        #expect(AgentDetectionCoordinator.parseCpuTime("0:00.1") == nil)
        #expect(AgentDetectionCoordinator.parseCpuTime("0:00.123") == nil)
    }

    @Test func parsePsOutputExtractsCpuTimeFromThreeColumnForm() {
        // Realistic `ps -eo pid=,command=,cputime=` output: multi-word
        // command followed by an `MM:SS.cc` cputime.
        let output = """
          1234 /usr/local/bin/claude 0:12.45
          5678 node /opt/homebrew/bin/pi 1:23:01
          """
        let processes = AgentDetectionCoordinator.parseLegacyPsOutputForTesting(
            output
        )
        #expect(processes.count == 2)
        #expect(processes[0].pid == 1234)
        #expect(processes[0].command == "/usr/local/bin/claude")
        #expect(processes[0].cpuTime == 12)
        #expect(processes[1].pid == 5678)
        #expect(processes[1].command == "node /opt/homebrew/bin/pi")
        #expect(processes[1].cpuTime == 4981)
    }

    @Test func parsePsOutputExtractsStableStartIdentifier() throws {
        let output = """
            1234 100 1234 Wed Jul 22 15:08:40 2026 0:12.45 /usr/local/bin/claude --verbose
            5678 1 5678 Wed Jul 22 15:09:39 2026 1:23.01 /sbin/launchd
            """

        let processes = AgentDetectionCoordinator.parsePsOutput(output)
        let claude = try #require(processes.first)
        #expect(processes.count == 2)
        #expect(claude.pid == 1234)
        #expect(claude.parentProcessID == 100)
        #expect(claude.processGroupID == 1234)
        #expect(claude.command == "/usr/local/bin/claude --verbose")
        #expect(claude.cpuTime == 12)
        #expect(claude.startIdentifier == "Wed Jul 22 15:08:40 2026")
    }

    @Test func parsePsOutputRejectsMalformedLongStartRow() {
        let output = "1234 100 1234 Wed Jul 22 not-a-time 2026 0:12.45 claude"
        #expect(AgentDetectionCoordinator.parsePsOutput(output).isEmpty)
    }

    @Test func parsePsOutputRejectsMissingWeekdayAndBadMonth() {
        #expect(
            AgentDetectionCoordinator.parsePsOutput(
                "1234 100 1234 Jul 22 15:08:40 2026 0:12.45 claude"
            ).isEmpty
        )
        #expect(
            AgentDetectionCoordinator.parsePsOutput(
                "1234 100 1234 Wed Xxx 22 15:08:40 2026 0:12.45 claude"
            ).isEmpty
        )
    }

    @Test func parsePsOutputRejectsInvalidDateTimeAndWeekday() {
        let malformedRows = [
            "1234 100 1234 Thu Jul 22 15:08:40 2026 0:12.45 claude",
            "1234 100 1234 Wed Feb 30 15:08:40 2026 0:12.45 claude",
            "1234 100 1234 Wed Jul 22 24:08:40 2026 0:12.45 claude",
            "1234 100 1234 Wed Jul 22 15:60:40 2026 0:12.45 claude",
            "1234 100 1234 Wed Jul 22 15:08:60 2026 0:12.45 claude",
            "1234 100 1234 Wed Jul 22 15:08:40 1969 0:12.45 claude",
            "1234 100 1234 Wed Jul 22 15:08:40 2026 0:60.00 claude",
        ]
        for row in malformedRows {
            #expect(AgentDetectionCoordinator.parsePsOutput(row).isEmpty)
        }
    }

    @Test func legacyTestParserDoesNotCorruptCommandEndingInNumericArg() {
        // `claude --port 8080` — the trailing `8080` is a command arg, not a
        // cputime value (no colon). Must stay in the command string.
        let output = "  1234 claude --port 8080\n"
        let processes = AgentDetectionCoordinator.parseLegacyPsOutputForTesting(
            output
        )
        #expect(processes.count == 1)
        #expect(processes[0].command == "claude --port 8080")
        #expect(processes[0].cpuTime == nil)
    }
}

@MainActor
private func setLiveAgent(
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
private func setForeground(
    _ process: DetectedProcess,
    on tab: TerminalTab
) {
    tab.foregroundProcessIDOverrideForTesting = process.processGroupID
    tab.foregroundStartOverrideForTesting = process.preciseStartedAt.flatMap {
        TerminalProcessStartIdentity(processID: process.pid, startedAt: $0)
    }
}

nonisolated private func process(
    pid: Int32,
    parent: Int32,
    group: Int32,
    command: String,
    startedAt: TimeInterval,
    startIdentifier: String? = nil
) -> DetectedProcess {
    DetectedProcess(
        pid: pid,
        parentProcessID: parent,
        processGroupID: group,
        command: command,
        cpuTime: 0,
        startIdentifier: startIdentifier ?? "generation-\(startedAt)",
        preciseStartedAt: Date(timeIntervalSince1970: startedAt)
    )
}

nonisolated private func replacing(
    _ process: DetectedProcess,
    preciseStartedAt: Date?,
    cpuTime: Int?
) -> DetectedProcess {
    DetectedProcess(
        pid: process.pid,
        parentProcessID: process.parentProcessID,
        processGroupID: process.processGroupID,
        command: process.command,
        cwd: process.cwd,
        cpuTime: cpuTime,
        startIdentifier: process.startIdentifier,
        preciseStartedAt: preciseStartedAt
    )
}

@MainActor private func configuredProject(
    path: String,
    registry: AgentTaskRegistry
) -> ProjectManager {
    let project = ProjectManager(agentTaskRegistry: registry)
    project.terminal.configureAgentTaskProject(
        URL(fileURLWithPath: path)
    )
    return project
}

nonisolated private func completePsOutput(
    _ rows: (pid: Int32, command: String)...
) -> String {
    var output = [psRow(pid: 1, command: "/sbin/launchd")]
    output.append(contentsOf: rows.map { psRow(pid: $0.pid, command: $0.command) })
    output.append(
        psRow(
            pid: 99_999,
            command: "/bin/ps -eo pid=,ppid=,pgid=,lstart=,cputime=,command="
        )
    )
    output.append(AgentDetectionCoordinator.psCompletionMarker)
    return output.joined(separator: "\n")
}

nonisolated private func psRow(pid: Int32, command: String) -> String {
    "\(pid) \(pid == 1 ? 0 : 1) \(pid) Wed Jul 22 15:08:40 2026 0:12.45 \(command)"
}
