//
//  AgentTaskEventBoundariesTests.swift
//  PineTests
//
//  Bounded event traffic for concurrent ADE tasks (#1728): per-task and
//  cross-task queue bounds, non-authoritative coalescing (per task,
//  attempt, and launch generation), authoritative fail-closed overflow,
//  captured-output and diagnostics byte bounds, per-task teardown with no
//  cross-task leak, and a concurrent burst that must hold the bounds.
//

import Foundation
import Testing
@testable import Pine

@Suite("Bounded ADE task event traffic (#1728)")
struct AgentTaskEventBoundariesTests {
    /// One stable attempt identity for every event in a test, so the
    /// per-(task, run, generation) coalescing rule is what is exercised.
    private let runID = UUID()

    private func task(_ seed: Int) -> UUID {
        let suffix = String(format: "%012llX", UInt64(seed + 1))
        return UUID(uuidString: "00000000-0000-0000-0000-\(suffix)") ?? UUID()
    }

    private func event(
        _ taskID: UUID,
        generation: UInt64 = 1,
        authoritative: Bool = false,
        key: String? = nil,
        payload: Data = Data([0x01])
    ) -> AgentTaskQueuedEvent {
        AgentTaskQueuedEvent(
            taskID: taskID,
            runID: runID,
            launchGeneration: generation,
            isAuthoritative: authoritative,
            coalescingKey: key,
            payload: payload
        )
    }

    @Test func perTaskQueueIsBoundedAndOtherTasksAreUnaffected() async {
        let boundaries = AgentTaskEventBoundaries()
        let a = task(1)
        let b = task(2)
        for _ in 0..<AgentTaskEventQueueLimits.maximumQueuedEventsPerTask {
            #expect(await boundaries.enqueue(event(a)) == .accepted)
        }
        #expect(await boundaries.enqueue(event(a)) == .dropped)
        #expect(await boundaries.enqueue(event(b)) == .accepted)
        #expect(await boundaries.drain(taskID: a).count
            == AgentTaskEventQueueLimits.maximumQueuedEventsPerTask)
        #expect(await boundaries.drain(taskID: b).count == 1)
    }

    @Test func crossTaskQueueIsBoundedAcrossTasks() async {
        let boundaries = AgentTaskEventBoundaries()
        let tasksPerLimit = AgentTaskEventQueueLimits.maximumQueuedEventsAcrossTasks
            / AgentTaskEventQueueLimits.maximumQueuedEventsPerTask
        for seed in 0..<tasksPerLimit {
            for _ in 0..<AgentTaskEventQueueLimits.maximumQueuedEventsPerTask {
                let admission = await boundaries.enqueue(event(task(seed)))
                #expect(admission == .accepted)
            }
        }
        // The project-wide budget is exhausted; a new task's first event is
        // dropped (non-authoritative), never admitted over the bound.
        let newcomer = task(900)
        #expect(await boundaries.enqueue(event(newcomer)) == .dropped)
        #expect(await boundaries.drain(taskID: newcomer).isEmpty)
    }

    @Test func concurrentBurstNeverExceedsQueueBounds() async {
        let boundaries = AgentTaskEventBoundaries()
        let perTask = AgentTaskEventQueueLimits.maximumQueuedEventsPerTask
        let taskCount = AgentTaskEventQueueLimits.maximumQueuedEventsAcrossTasks / perTask
        // Sixteen tasks enqueue their per-task quota concurrently. The
        // project-wide bound is exactly saturated; nothing may exceed it.
        let batches = await withTaskGroup(of: [AgentTaskEventAdmission].self) { group in
            for seed in 0..<taskCount {
                let id = task(seed)
                group.addTask {
                    var results: [AgentTaskEventAdmission] = []
                    for _ in 0..<perTask {
                        results.append(await boundaries.enqueue(event(id)))
                    }
                    return results
                }
            }
            var collected: [[AgentTaskEventAdmission]] = []
            for await batch in group {
                collected.append(batch)
            }
            return collected
        }
        let flat = batches.flatMap { $0 }
        #expect(flat.count == perTask * taskCount)
        #expect(flat.allSatisfy { $0 == .accepted })
        // One more event anywhere is dropped: the bound is exact.
        #expect(await boundaries.enqueue(event(task(900))) == .dropped)
        // Every task retains exactly its own quota.
        var drainedTotal = 0
        for seed in 0..<taskCount {
            drainedTotal += await boundaries.drain(taskID: task(seed)).count
        }
        #expect(drainedTotal == perTask * taskCount)
        #expect(await boundaries.drain(taskID: task(900)).isEmpty)
    }

    @Test func nonAuthoritativeDeltasCoalesceWithRetainedCount() async {
        let boundaries = AgentTaskEventBoundaries()
        let a = task(3)
        #expect(await boundaries.enqueue(event(a, key: "activity")) == .accepted)
        for round in 1...9 {
            #expect(
                await boundaries.enqueue(
                    event(a, key: "activity", payload: Data([UInt8(round)]))
                ) == .coalesced
            )
        }
        let drained = await boundaries.drain(taskID: a)
        #expect(drained.count == 1)
        #expect(drained.first?.coalescedCount == 9)
        #expect(drained.first?.payload == Data([9]))
        #expect(drained.first?.isAuthoritative == false)
    }

    @Test func coalescingIsScopedToAttemptAndLaunchGeneration() async {
        let boundaries = AgentTaskEventBoundaries()
        let a = task(3)
        #expect(await boundaries.enqueue(event(a, generation: 1, key: "activity")) == .accepted)
        // A NEW attempt (new launch generation) with the same key does not
        // fold into the old attempt's entry — it stands alone.
        #expect(await boundaries.enqueue(event(a, generation: 2, key: "activity")) == .accepted)
        // Same attempt/generation still coalesces.
        #expect(await boundaries.enqueue(event(a, generation: 2, key: "activity")) == .coalesced)
        let drained = await boundaries.drain(taskID: a)
        #expect(drained.count == 2)
        #expect(drained.first?.launchGeneration == 1)
        #expect(drained.first?.coalescedCount == 0)
        #expect(drained.last?.launchGeneration == 2)
        #expect(drained.last?.coalescedCount == 1)
    }

    @Test func authoritativeDeltasNeverCoalesce() async {
        let boundaries = AgentTaskEventBoundaries()
        let a = task(4)
        _ = await boundaries.enqueue(event(a, authoritative: true, key: "req-1"))
        // An authoritative event is never coalesced even with a key: it
        // occupies its own queue slot.
        #expect(await boundaries.enqueue(event(a, authoritative: true, key: "req-1")) == .accepted)
        let drained = await boundaries.drain(taskID: a)
        #expect(drained.count == 2)
    }

    @Test func coalescingKeyIsByteBounded() async {
        let boundaries = AgentTaskEventBoundaries()
        let a = task(5)
        let atBound = String(
            repeating: "k",
            count: AgentTaskEventQueueLimits.maximumCoalescingKeyBytes
        )
        #expect(await boundaries.enqueue(event(a, key: atBound)) == .accepted)
        let overlong = atBound + "k"
        #expect(await boundaries.enqueue(event(a, key: overlong)) == .dropped)
        let drained = await boundaries.drain(taskID: a)
        #expect(drained.count == 1)
        #expect(drained.first?.coalescingKey == atBound)
        // Authoritative traffic carrying an over-long key fails closed like
        // any other authoritative overflow.
        #expect(await boundaries.enqueue(event(a, authoritative: true, key: overlong)) == .overflow)
        #expect(await boundaries.hasAuthoritativeOverflow(a) == true)
    }

    @Test func authoritativeOverflowFailsClosedStickyUntilTaskTeardown() async {
        let boundaries = AgentTaskEventBoundaries()
        let a = task(6)
        for _ in 0..<AgentTaskEventQueueLimits.maximumQueuedEventsPerTask {
            #expect(await boundaries.enqueue(event(a, authoritative: true)) == .accepted)
        }
        #expect(await boundaries.enqueue(event(a, authoritative: true)) == .overflow)
        #expect(await boundaries.hasAuthoritativeOverflow(a) == true)
        // Traffic for the task stays unusable: non-authoritative events are
        // dropped, and the overflow is not cleared by traffic.
        #expect(await boundaries.enqueue(event(a)) == .dropped)
        #expect(await boundaries.hasAuthoritativeOverflow(a) == true)
        // Another task is unaffected and can still receive authoritative
        // traffic.
        let b = task(7)
        #expect(await boundaries.enqueue(event(b, authoritative: true)) == .accepted)
        #expect(await boundaries.hasAuthoritativeOverflow(b) == false)
        // Only the task's own teardown clears the marker.
        await boundaries.clear(taskID: a)
        #expect(await boundaries.hasAuthoritativeOverflow(a) == false)
        #expect(await boundaries.enqueue(event(a, authoritative: true)) == .accepted)
    }

    @Test func payloadIsTruncatedToTheDocumentedBound() async {
        let boundaries = AgentTaskEventBoundaries()
        let a = task(8)
        let oversized = Data(count: AgentTaskEventQueueLimits.maximumEventPayloadBytes + 4_096)
        #expect(await boundaries.enqueue(event(a, payload: oversized)) == .truncated)
        let drained = await boundaries.drain(taskID: a)
        #expect(
            drained.first?.payload.count
                == AgentTaskEventQueueLimits.maximumEventPayloadBytes
        )
    }

    @Test func coalescingKeysAreBoundedPerTask() async {
        let boundaries = AgentTaskEventBoundaries()
        let a = task(9)
        for keyIndex in 0..<AgentTaskEventQueueLimits.maximumCoalescingKeysPerTask {
            #expect(
                await boundaries.enqueue(event(a, key: "key-\(keyIndex)")) == .accepted
            )
        }
        #expect(await boundaries.enqueue(event(a, key: "key-new")) == .dropped)
        // An existing key still coalesces at the bound.
        #expect(await boundaries.enqueue(event(a, key: "key-0")) == .coalesced)
    }

    @Test func capturedOutputIsBoundedPerTaskAndIndependentAcrossTasks() async {
        let boundaries = AgentTaskEventBoundaries()
        let a = task(10)
        let b = task(11)
        let bound = AgentTaskEventQueueLimits.maximumCapturedOutputBytesPerTask
        #expect(await boundaries.recordCapturedOutput(taskID: a, bytes: bound / 2) == .appended)
        #expect(
            await boundaries.recordCapturedOutput(
                taskID: a, bytes: bound / 2 + 1
            ) == .truncatedToBound
        )
        #expect(await boundaries.isOutputTruncated(a) == true)
        #expect(
            await boundaries.recordCapturedOutput(taskID: a, bytes: 1)
                == .truncatedToBound
        )
        // The other task keeps its own full budget.
        #expect(await boundaries.recordCapturedOutput(taskID: b, bytes: bound) == .appended)
        #expect(await boundaries.isOutputTruncated(b) == false)
    }

    @Test func retainedDiagnosticsAreBoundedForTheProject() async {
        let boundaries = AgentTaskEventBoundaries()
        let bound = AgentTaskEventQueueLimits.maximumRetainedDiagnosticsBytes
        #expect(await boundaries.retainDiagnostics(taskID: task(12), bytes: bound / 2) == .retained)
        #expect(await boundaries.retainDiagnostics(taskID: task(13), bytes: bound / 2) == .retained)
        #expect(await boundaries.retainDiagnostics(taskID: task(14), bytes: 1) == .overflowed)
        #expect(await boundaries.isDiagnosticsOverflowed() == true)
        #expect(await boundaries.retainDiagnostics(taskID: task(14), bytes: 1) == .overflowed)
    }

    @Test func teardownRemovesOnlyTheTasksOwnResources() async {
        let boundaries = AgentTaskEventBoundaries()
        let a = task(15)
        let b = task(16)
        for _ in 0..<10 {
            _ = await boundaries.enqueue(event(a, authoritative: true))
            _ = await boundaries.enqueue(event(b))
        }
        #expect(await boundaries.hasAuthoritativeOverflow(a) == false)
        await boundaries.clear(taskID: a)
        #expect(await boundaries.drain(taskID: a).isEmpty)
        #expect(await boundaries.drain(taskID: b).count == 10)
        #expect(await boundaries.recordCapturedOutput(taskID: a, bytes: 1) == .appended)
    }
}
