//
//  AgentAttentionStateTests.swift
//  PineTests
//
//  Tests for the CPU-time state refinement (#1112) and the AgentState
//  attention helpers that drive per-tab glyphs + the global attention bell.
//

import Testing
@testable import Pine

@MainActor
struct AgentAttentionStateTests {

    // MARK: - CPU-time state refinement (#1112)

    @Test("First snapshot seeds baseline (.idle), no refinement yet")
    func firstSnapshotIsBaseline() {
        let detector = AgentDetector()
        detector.processSnapshotDidUpdate([
            DetectedProcess(pid: 100, command: "claude", cpuTime: 5),
        ])
        let session = detector.detectedSessions[0]
        #expect(session.state == .idle)
    }

    @Test("CPU time advancing → .executing")
    func cpuAdvancingIsExecuting() {
        let detector = AgentDetector()
        // Baseline.
        detector.processSnapshotDidUpdate([
            DetectedProcess(pid: 100, command: "claude", cpuTime: 5),
        ])
        // Next poll: CPU time went up — agent is doing work.
        detector.processSnapshotDidUpdate([
            DetectedProcess(pid: 100, command: "claude", cpuTime: 9),
        ])
        #expect(detector.detectedSessions[0].state == .executing)
    }

    @Test("32 seconds of flat CPU stays honestly unknown")
    func cpuStalledStaysUnknown() {
        let detector = AgentDetector()
        detector.processSnapshotDidUpdate([
            DetectedProcess(pid: 100, command: "codex", cpuTime: 12),
        ])
        // Sixteen polls represent 32 seconds at the production two-second
        // interval, without making the test wait in real time.
        for _ in 0..<16 {
            detector.processSnapshotDidUpdate([
                DetectedProcess(pid: 100, command: "codex", cpuTime: 12),
            ])
        }
        #expect(detector.detectedSessions[0].state == .idle)
        #expect(
            detector.detectedSessions[0].lifecycleAccuracy
                == .processTerminationOnly
        )
    }

    @Test("Executing state survives flat CPU and later work")
    func executingSurvivesFlatCPU() {
        let detector = AgentDetector()
        detector.processSnapshotDidUpdate([
            DetectedProcess(pid: 100, command: "claude", cpuTime: 0),
        ])
        detector.processSnapshotDidUpdate([
            DetectedProcess(pid: 100, command: "claude", cpuTime: 3),
        ])
        #expect(detector.detectedSessions[0].state == .executing)

        // Flat CPU can be a network wait, so even a sustained run of flat
        // process snapshots preserves the last honest working state.
        for _ in 0..<16 {
            detector.processSnapshotDidUpdate([
                DetectedProcess(pid: 100, command: "claude", cpuTime: 3),
            ])
        }
        #expect(detector.detectedSessions[0].state == .executing)

        detector.processSnapshotDidUpdate([
            DetectedProcess(pid: 100, command: "claude", cpuTime: 7),
        ])
        #expect(detector.detectedSessions[0].state == .executing)
    }

    @Test("Legacy snapshots without cpuTime leave state untouched")
    func legacySnapshotNoCpuTime() {
        let detector = AgentDetector()
        // No cpuTime — legacy parse path / older tests.
        detector.processSnapshotDidUpdate([
            DetectedProcess(pid: 100, command: "claude"),
        ])
        #expect(detector.detectedSessions[0].state == .idle)

        // Second legacy snapshot must NOT refine (no baseline to compare).
        detector.processSnapshotDidUpdate([
            DetectedProcess(pid: 100, command: "claude"),
        ])
        #expect(detector.detectedSessions[0].state == .idle)
    }

    @Test(".done sessions are not refined back to active")
    func doneNotRefined() {
        let detector = AgentDetector()
        detector.processSnapshotDidUpdate([
            DetectedProcess(pid: 100, command: "claude", cpuTime: 5),
        ])
        // Process disappears → reconciled to .done.
        detector.processSnapshotDidUpdate([])
        #expect(detector.detectedSessions[0].state == .done)

        // A stale snapshot referencing the same pid must not resurrect it.
        detector.processSnapshotDidUpdate([
            DetectedProcess(pid: 100, command: "claude", cpuTime: 99),
        ])
        // pid reused creates a fresh session; the done one stays done.
        let doneCount = detector.detectedSessions.filter { $0.state == .done }.count
        #expect(doneCount == 1)
    }

    // MARK: - AgentState attention helpers (#1112)

    @Test("isActive covers thinking and executing only")
    func isActiveCases() {
        #expect(AgentState.thinking.isActive == true)
        #expect(AgentState.executing.isActive == true)
        #expect(AgentState.idle.isActive == false)
        #expect(AgentState.waitingInput.isActive == false)
        #expect(AgentState.done.isActive == false)
    }

    @Test("needsAttention is waitingInput only")
    func needsAttentionCases() {
        #expect(AgentState.waitingInput.needsAttention == true)
        #expect(AgentState.thinking.needsAttention == false)
        #expect(AgentState.executing.needsAttention == false)
        #expect(AgentState.idle.needsAttention == false)
        #expect(AgentState.done.needsAttention == false)
    }

    @Test("only verified lifecycle evidence presents a genuine prompt")
    func accuracyGatesUserFacingPrompt() {
        let verifiedPolicy = AgentLifecycleAccuracyPolicy { _ in
            .verifiedLifecycleTransitions
        }
        #expect(
            AgentState.waitingInput.userFacing(
                stableIdentifier: "codex",
                evidenceAccuracy: .verifiedLifecycleTransitions
            ) == .idle
        )
        #expect(
            AgentState.waitingInput.userFacing(
                stableIdentifier: "codex",
                evidenceAccuracy: .verifiedLifecycleTransitions,
                policy: verifiedPolicy
            ) == .waitingInput
        )
    }

    @Test("glyphName maps each state")
    func glyphNameCases() {
        #expect(AgentState.idle.glyphName == nil)
        #expect(AgentState.thinking.glyphName == "ellipsis")
        #expect(AgentState.executing.glyphName == "ellipsis")
        #expect(AgentState.waitingInput.glyphName == "exclamationmark")
        #expect(AgentState.done.glyphName == "checkmark")
    }
}
