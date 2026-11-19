//
//  AgentTaskHydrationBarrierTests.swift
//  PineTests
//
//  Hydration barrier contract (#1722): buffer deltas, obtain the
//  reconciled current state, then apply only deltas proven newer within
//  the same attempt. A quiet stream remains unknown, never success.
//

import Foundation
import Testing
@testable import Pine

@MainActor
@Suite("ADE hydration barrier", .serialized)
struct AgentTaskHydrationBarrierTests {
    private var codeState: AgentTaskCodeStateIdentity {
        ADEContractFixtures.codeState("a")
    }
    private var env: AgentTaskEnvironmentIdentity { ADEContractFixtures.environment }

    private func claim(
        run: AgentTaskRun,
        at: Date,
        sequence: UInt64? = nil
    ) -> AgentTaskEvidenceFact {
        ADEContractFixtures.fact(
            .agentReportedCompletion,
            runID: run.id,
            generation: run.process.processGeneration,
            result: .reported,
            at: at,
            codeState: codeState,
            environment: env,
            sequence: sequence
        )
    }

    private func check(
        run: AgentTaskRun,
        at: Date,
        sequence: UInt64? = nil
    ) -> AgentTaskEvidenceFact {
        ADEContractFixtures.fact(
            .independentCheck,
            runID: run.id,
            generation: run.process.processGeneration,
            result: .succeeded,
            at: at,
            codeState: codeState,
            environment: env,
            sequence: sequence,
            pre: codeState,
            post: codeState
        )
    }

    private func review(
        run: AgentTaskRun,
        at: Date,
        sequence: UInt64? = nil
    ) -> AgentTaskEvidenceFact {
        ADEContractFixtures.fact(
            .reviewerOutcome,
            runID: run.id,
            generation: run.process.processGeneration,
            result: .succeeded,
            at: at,
            codeState: codeState,
            environment: env,
            sequence: sequence,
            pre: codeState,
            post: codeState
        )
    }

    @Test("reordered unordered deltas all apply and converge to one settlement")
    func reorderedUnorderedDeltasConverge() throws {
        let base = ADEContractFixtures.settledTask(seed: 11)
        let run = try #require(base.runs.first)
        let now = Date()
        let snapshot = AgentTaskHydrationSnapshot(
            runID: run.id,
            processGeneration: run.process.processGeneration,
            vendorSession: nil,
            watermark: nil,
            executionState: .unknown
        )

        func hydrate(_ deltas: [AgentTaskEvidenceFact]) -> AgentTask {
            var task = base
            _ = AgentTaskHydrationBarrier.hydrate(
                &task,
                snapshot: snapshot,
                deltas: deltas
            )
            return task
        }

        let forward = hydrate([
            claim(run: run, at: now),
            check(run: run, at: now.addingTimeInterval(1)),
            review(run: run, at: now.addingTimeInterval(2)),
        ])
        // Legitimate cross-scope reordering: the same facts admitted in
        // reverse arrival order are all accepted, never rejected.
        let reordered = hydrate([
            review(run: run, at: now.addingTimeInterval(2)),
            claim(run: run, at: now),
            check(run: run, at: now.addingTimeInterval(1)),
        ])
        for task in [forward, reordered] {
            #expect(task.runs.last?.outcome == .success)
            #expect(task.verificationState == .verified)
            #expect(task.evidence.count == 4) // exit + three applied
        }
        #expect(
            Set(forward.evidence.map(\.eventIdentity))
                == Set(reordered.evidence.map(\.eventIdentity))
        )

        // A replay of the same deltas is fenced as duplicates.
        var replayed = forward
        let dispositions = AgentTaskHydrationBarrier.hydrate(
            &replayed,
            snapshot: snapshot,
            deltas: [
                claim(run: run, at: now),
                check(run: run, at: now.addingTimeInterval(1)),
                review(run: run, at: now.addingTimeInterval(2)),
            ]
        )
        #expect(dispositions == [
            .fenced(.duplicate), .fenced(.duplicate), .fenced(.duplicate),
        ])
        #expect(replayed == forward)
    }

    @Test("an ordered delta at or below the watermark is a stale replay")
    func orderedWatermarkGatesReplay() throws {
        var task = ADEContractFixtures.settledTask(seed: 12)
        let run = try #require(task.runs.first)
        let now = Date()
        let snapshot = AgentTaskHydrationSnapshot(
            runID: run.id,
            processGeneration: run.process.processGeneration,
            vendorSession: nil,
            watermark: 3,
            executionState: .unknown
        )
        let dispositions = AgentTaskHydrationBarrier.hydrate(
            &task,
            snapshot: snapshot,
            deltas: [
                claim(run: run, at: now, sequence: 2),
                check(run: run, at: now, sequence: 3),
                review(run: run, at: now, sequence: 4),
            ]
        )
        #expect(dispositions == [
            .staleReplay, .staleReplay, .applied,
        ])
        // Only the fact proven newer than the fetched state landed.
        #expect(task.evidence.map(\.sourceSequence) == [nil, 4])
    }

    @Test("an ordered delta without a sequence cannot be proven newer")
    func unorderedDeltaOnOrderedStreamFailsClosed() throws {
        let base = ADEContractFixtures.settledTask(seed: 13)
        var task = base
        let run = try #require(base.runs.first)
        let snapshot = AgentTaskHydrationSnapshot(
            runID: run.id,
            processGeneration: run.process.processGeneration,
            vendorSession: nil,
            watermark: 3,
            executionState: .unknown
        )
        let dispositions = AgentTaskHydrationBarrier.hydrate(
            &task,
            snapshot: snapshot,
            deltas: [claim(run: run, at: Date())]
        )
        #expect(dispositions == [.unprovenNewer])
        #expect(task == base)
    }

    @Test("a snapshot for an unknown attempt fences everything")
    func unknownAttemptSnapshotFences() throws {
        let base = ADEContractFixtures.settledTask(seed: 14)
        var task = base
        let snapshot = AgentTaskHydrationSnapshot(
            runID: ADEContractFixtures.uuid(999),
            processGeneration: 14,
            vendorSession: nil,
            watermark: nil,
            executionState: .unknown
        )
        let run = try #require(base.runs.first)
        let dispositions = AgentTaskHydrationBarrier.hydrate(
            &task,
            snapshot: snapshot,
            deltas: [claim(run: run, at: Date())]
        )
        #expect(dispositions == [.fenced(.unknownRun)])
        #expect(task == base)
    }

    @Test("a snapshot with a mismatched incarnation fences everything")
    func foreignIncarnationSnapshotFences() throws {
        let base = ADEContractFixtures.settledTask(seed: 15)
        var task = base
        let run = try #require(base.runs.first)
        let snapshot = AgentTaskHydrationSnapshot(
            runID: run.id,
            processGeneration: run.process.processGeneration + 1,
            vendorSession: nil,
            watermark: nil,
            executionState: .idle
        )
        let dispositions = AgentTaskHydrationBarrier.hydrate(
            &task,
            snapshot: snapshot,
            deltas: [claim(run: run, at: Date())]
        )
        #expect(dispositions == [.fenced(.foreignProcess)])
        #expect(task == base)
    }

    @Test("a snapshot whose vendor session does not revalidate fences everything")
    func foreignVendorSnapshotFences() throws {
        let base = ADEContractFixtures.settledTask(seed: 16)
        var task = base
        let run = try #require(base.runs.first)
        let identity = AgentVendorSessionIdentity(
            provider: "codex",
            opaqueIdentifier: "session-1"
        )
        task.runs[0].vendorIdentity = identity
        var expected = base
        expected.runs[0].vendorIdentity = identity
        let snapshot = AgentTaskHydrationSnapshot(
            runID: run.id,
            processGeneration: run.process.processGeneration,
            vendorSession: AgentVendorSessionIdentity(
                provider: "codex",
                opaqueIdentifier: "session-2"
            ),
            watermark: nil,
            executionState: .idle
        )
        let dispositions = AgentTaskHydrationBarrier.hydrate(
            &task,
            snapshot: snapshot,
            deltas: [claim(run: run, at: Date())]
        )
        #expect(dispositions == [.fenced(.foreignVendorSession)])
        // The untrusted snapshot applied nothing, including its state.
        #expect(task == expected)
    }

    @Test("a snapshot for a replaced attempt never overwrites the current view")
    func replacedAttemptSnapshotKeepsCurrentView() throws {
        var task = ADEContractFixtures.makeTask(seed: 17, now: Date(timeIntervalSince1970: 1_000))
        task.runs[0].liveness = .terminated
        task.runs[0].endedAt = Date(timeIntervalSince1970: 1_000)
        task.runs[0].outcome = .superseded
        let oldRun = task.runs[0]
        task.runs.append(AgentTaskRun(ADEContractFixtures.makeAttempt(
            seed: 18,
            state: .executing,
            liveness: .live,
            now: Date(timeIntervalSince1970: 2_000)
        )))
        task.lifecycle = .active
        task.executionState = AgentTaskLifecycleReducer.executionState(for: task)
        #expect(task.executionState == .working)

        // The fetched state describes the replaced attempt only.
        let snapshot = AgentTaskHydrationSnapshot(
            runID: oldRun.id,
            processGeneration: oldRun.process.processGeneration,
            vendorSession: nil,
            watermark: nil,
            executionState: .idle
        )
        let historyFact = ADEContractFixtures.fact(
            .agentReportedCompletion,
            runID: oldRun.id,
            generation: oldRun.process.processGeneration,
            result: .reported,
            at: Date(timeIntervalSince1970: 1_500)
        )
        let dispositions = AgentTaskHydrationBarrier.hydrate(
            &task,
            snapshot: snapshot,
            deltas: [historyFact]
        )
        // A historical fact for the replaced run is admitted as history.
        #expect(dispositions == [.applied])
        // ...but the current attempt's execution view is untouched.
        #expect(task.executionState == .working)
        #expect(task.runs.last?.outcome == nil)
    }

    @Test("a late delta after reconciliation is fenced by chronology")
    func lateDeltaAfterReconciliationFences() throws {
        let base = ADEContractFixtures.settledTask(seed: 19)
        var task = base
        let run = try #require(base.runs.first)
        let snapshot = AgentTaskHydrationSnapshot(
            runID: run.id,
            processGeneration: run.process.processGeneration,
            vendorSession: nil,
            watermark: nil,
            executionState: .unknown
        )
        let late = ADEContractFixtures.fact(
            .agentReportedCompletion,
            runID: run.id,
            generation: run.process.processGeneration,
            result: .reported,
            at: run.startedAt.addingTimeInterval(-1)
        )
        let dispositions = AgentTaskHydrationBarrier.hydrate(
            &task,
            snapshot: snapshot,
            deltas: [late]
        )
        #expect(dispositions == [.fenced(.lateEvent)])
        #expect(task.evidence.count == base.evidence.count)
    }

    @Test("a quiet stream reconciles to unknown, never success")
    func quietStreamStaysUnknown() throws {
        var task = ADEContractFixtures.makeTask(
            seed: 20,
            state: .idle,
            liveness: .live,
            accuracy: .verifiedLifecycleTransitions,
            now: Date(timeIntervalSince1970: 1_000)
        )
        #expect(task.executionState == .idle)
        let run = try #require(task.runs.first)
        // The provider reconnects but its stream is quiet: no active turn,
        // no outstanding request, no positive state.
        let snapshot = AgentTaskHydrationSnapshot(
            runID: run.id,
            processGeneration: run.process.processGeneration,
            vendorSession: nil,
            watermark: nil,
            executionState: .unknown
        )
        let dispositions = AgentTaskHydrationBarrier.hydrate(
            &task,
            snapshot: snapshot,
            deltas: []
        )
        #expect(dispositions.isEmpty)
        #expect(task.executionState == .unknown)
        #expect(task.runs.last?.outcome == nil)
        #expect(!AgentTaskLifecycleReducer.readiness(
            for: task,
            codeState: codeState,
            environment: env
        ).isReady)
    }

    @Test("newer deltas on a settled run re-settle the attempt")
    func newerDeltasReSettleSettledRun() throws {
        var task = ADEContractFixtures.settledTask(seed: 21)
        let run = try #require(task.runs.first)
        #expect(task.runs.last?.outcome == .unverified)
        let now = Date()
        let snapshot = AgentTaskHydrationSnapshot(
            runID: run.id,
            processGeneration: run.process.processGeneration,
            vendorSession: nil,
            watermark: nil,
            executionState: .unknown
        )
        // A buffered batch that carries the full required set, proved newer
        // than the (unverified) fetched state, settles the attempt.
        let dispositions = AgentTaskHydrationBarrier.hydrate(
            &task,
            snapshot: snapshot,
            deltas: [
                claim(run: run, at: now),
                check(run: run, at: now.addingTimeInterval(1)),
                review(run: run, at: now.addingTimeInterval(2)),
            ]
        )
        #expect(dispositions == [.applied, .applied, .applied])
        #expect(task.runs.last?.outcome == .success)
        #expect(task.verificationState == .verified)
        #expect(task.lifecycle == .completed)
    }
}
