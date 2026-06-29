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

    @Test func parsePsOutputExtractsPidAndCommand() {
        let output = "1234 /bin/bash\n5678 claude --verbose\n9012 codex"
        let processes = AgentDetectionCoordinator.parsePsOutput(output)
        #expect(processes.count == 3)
        #expect(processes[0].pid == 1234)
        #expect(processes[1].command == "claude --verbose")
    }

    @Test func parsePsOutputSkipsNonNumericLines() {
        let processes = AgentDetectionCoordinator.parsePsOutput("PID COMMAND\n42 claude")
        #expect(processes.count == 1)
        #expect(processes[0].pid == 42)
    }

    @Test func parsePsOutputHandlesEmptyInput() {
        #expect(AgentDetectionCoordinator.parsePsOutput("").isEmpty)
    }

    @Test func coordinatorFeedsSnapshotsToDetector() {
        let detector = AgentDetector()
        let runner: ProcessRunner = { _, _, _, _ in
            ProcessRunResult(stdout: "100 claude\n200 codex\n300 bash", stderr: "", exitCode: 0, timedOut: false)
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
        let mockOutput = MockOutput("100 claude")
        let runner: ProcessRunner = { _, _, _, _ in
            ProcessRunResult(stdout: mockOutput.value, stderr: "", exitCode: 0, timedOut: false)
        }
        let coordinator = AgentDetectionCoordinator(detector: detector, terminalManager: nil, processRunner: runner, pollInterval: 0.05)
        coordinator.runSnapshotForTesting()
        #expect(detector.activeCount == 1)
        mockOutput.value = ""
        coordinator.runSnapshotForTesting()
        #expect(detector.detectedSessions[0].state == .done)
        #expect(detector.activeCount == 0)
    }

    @Test func coordinatorDoesNotDoubleCount() {
        let detector = AgentDetector()
        let runner: ProcessRunner = { _, _, _, _ in
            ProcessRunResult(stdout: "100 claude", stderr: "", exitCode: 0, timedOut: false)
        }
        let coordinator = AgentDetectionCoordinator(detector: detector, terminalManager: nil, processRunner: runner, pollInterval: 0.05)
        coordinator.runSnapshotForTesting()
        coordinator.runSnapshotForTesting()
        #expect(detector.detectedSessions.count == 1)
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
        let detector = AgentDetector()
        let runner: ProcessRunner = { _, _, _, _ in
            ProcessRunResult(stdout: "100 claude", stderr: "", exitCode: 0, timedOut: false)
        }
        let coordinator = AgentDetectionCoordinator(
            detector: detector, terminalManager: nil,
            processRunner: runner, pollInterval: 0.05
        )
        coordinator.start()
        // ~6 polls on pollQueue; the bug would kill the process in this window.
        try await Task.sleep(for: .milliseconds(300))
        coordinator.stop()
        #expect(!coordinator.isRunning)
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
        #expect(expected == "Claude Code — Executing")
    }
}
