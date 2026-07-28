//
//  UserTaskRunStoreTests.swift
//  PineTests
//

import Darwin
import Foundation
import Testing

@testable import Pine

@Suite("User task run store lifecycle")
@MainActor
struct UserTaskRunStoreTests {
    @Test("Cancel before handle arrival forwards cancellation exactly once")
    func cancelBeforeHandleArrival() {
        let store = UserTaskRunStore()
        let run = store.start(makeRun())
        let counter = CancellationCounter()

        store.cancelRun(id: run.id)
        #expect(run.state == .pending)
        #expect(store.cancellationHandleCount == 0)
        #expect(store.pendingCancellationCount == 1)

        store.registerCancellation(
            makeCancellation(counter: counter),
            forRunID: run.id
        )
        #expect(counter.value == 1)
        #expect(run.state == .cancelling)
        #expect(run.state.isActive)
        #expect(store.cancellationHandleCount == 1)
        #expect(store.pendingCancellationCount == 0)

        #expect(store.finishRun(
            id: run.id,
            outcome: outcome(exitCode: SIGTERM, stdout: "partial"),
            cancelled: true
        ))
        #expect(run.state == .cancelled)
        #expect(run.stdout == "partial")
        #expect(counter.value == 1)
        #expect(store.cancellationHandleCount == 0)
        #expect(!store.finishRun(
            id: run.id,
            outcome: outcome(exitCode: 9, stdout: "late"),
            cancelled: true
        ))
        #expect(run.stdout == "partial")
    }

    @Test("Normal finish releases its handle without cancelling it")
    func normalFinishReleasesHandle() {
        let store = UserTaskRunStore()
        let run = store.start(makeRun())
        let counter = CancellationCounter()
        store.registerCancellation(
            makeCancellation(counter: counter),
            forRunID: run.id
        )
        #expect(store.cancellationHandleCount == 1)

        #expect(store.finishRun(
            id: run.id,
            outcome: outcome(exitCode: 0, stdout: "complete"),
            cancelled: false
        ))

        #expect(run.state == .succeeded)
        #expect(run.stdout == "complete")
        #expect(counter.value == 0)
        #expect(store.cancellationHandleCount == 0)
        #expect(!store.finishRun(
            id: run.id,
            outcome: outcome(exitCode: 9, stdout: "late"),
            cancelled: false
        ))
        #expect(run.state == .succeeded)
        #expect(run.stdout == "complete")
    }

    @Test("Rejected late cancellation preserves the completed outcome")
    func rejectedLateCancellationPreservesOutcome() {
        let store = UserTaskRunStore()
        let run = store.start(makeRun())
        let counter = CancellationCounter()

        store.cancelRun(id: run.id)
        #expect(store.pendingCancellationCount == 1)
        store.registerCancellation(
            makeCancellation(counter: counter, accepted: false),
            forRunID: run.id
        )

        #expect(counter.value == 1)
        #expect(run.state == .pending)
        #expect(store.pendingCancellationCount == 0)

        store.finishRun(
            id: run.id,
            outcome: outcome(exitCode: 0, stdout: "complete"),
            cancelled: false
        )
        #expect(run.state == .succeeded)
        #expect(run.stdout == "complete")
    }

    @Test("Late handle for a normally finished run is discarded")
    func lateHandleAfterFinishIsDiscarded() {
        let store = UserTaskRunStore()
        let run = store.start(makeRun())
        let counter = CancellationCounter()
        store.finishRun(
            id: run.id,
            outcome: outcome(exitCode: 0),
            cancelled: false
        )

        store.registerCancellation(
            makeCancellation(counter: counter),
            forRunID: run.id
        )

        #expect(run.state == .succeeded)
        #expect(counter.value == 0)
        #expect(store.cancellationHandleCount == 0)
    }

    @Test("Clear all cancels every retained handle before dropping it")
    func clearAllCancelsHandles() {
        let store = UserTaskRunStore()
        let first = store.start(makeRun(taskID: "first"))
        let second = store.start(makeRun(taskID: "second"))
        let counter = CancellationCounter()
        store.registerCancellation(
            makeCancellation(counter: counter),
            forRunID: first.id
        )
        store.registerCancellation(
            makeCancellation(counter: counter),
            forRunID: second.id
        )
        #expect(store.cancellationHandleCount == 2)

        store.clearAll()

        #expect(store.runs.isEmpty)
        #expect(store.cancellationHandleCount == 0)
        #expect(store.pendingCancellationCount == 0)
        #expect(counter.value == 2)
    }

    @Test("Clear all forwards cancellation to a handle that arrives later")
    func clearAllCancelsLateHandle() {
        let store = UserTaskRunStore()
        let run = store.start(makeRun())
        let counter = CancellationCounter()

        store.clearAll()
        #expect(store.runs.isEmpty)
        #expect(store.pendingCancellationCount == 1)

        store.registerCancellation(
            makeCancellation(counter: counter),
            forRunID: run.id
        )
        #expect(counter.value == 1)
        #expect(store.pendingCancellationCount == 0)
        #expect(!store.finishRun(
            id: run.id,
            outcome: outcome(exitCode: SIGTERM),
            cancelled: true
        ))
    }

    @Test("Accepted cancellation remains active until cleanup outcome")
    func cancellingRemainsActiveUntilFinish() {
        let store = UserTaskRunStore()
        let run = store.start(makeRun())
        let counter = CancellationCounter()
        store.registerCancellation(
            makeCancellation(counter: counter),
            forRunID: run.id
        )

        store.cancelRun(id: run.id)

        #expect(run.state == .cancelling)
        #expect(store.hasActiveRuns)
        #expect(store.cancellationHandleCount == 1)

        #expect(store.finishRun(
            id: run.id,
            outcome: outcome(exitCode: SIGTERM),
            cancelled: true
        ))
        #expect(run.state == .cancelled)
        #expect(!store.hasActiveRuns)
        #expect(store.cancellationHandleCount == 0)
    }

    @Test("Cleanup failure is visible failure even after cancellation")
    func cleanupFailureOverridesCancelledPresentation() {
        let store = UserTaskRunStore()
        let run = store.start(makeRun())
        let counter = CancellationCounter()
        store.registerCancellation(
            makeCancellation(counter: counter),
            forRunID: run.id
        )
        store.cancelRun(id: run.id)
        store.isOutputVisible = false

        #expect(store.finishRun(
            id: run.id,
            outcome: UserTaskOutcome(
                taskID: "task",
                stdout: "",
                stderr: "cleanup failed",
                exitCode: -1,
                timedOut: false,
                cleanupSucceeded: false
            ),
            cancelled: true
        ))

        #expect(run.state == .failed)
        #expect(store.isOutputVisible)
    }

    @Test("Terminal transitions trim count while preserving active runs")
    func terminalTrimCount() {
        let store = UserTaskRunStore(
            maximumRuns: 2,
            maximumRetainedOutputBytes: 1_024
        )
        let active = store.start(makeRun(taskID: "active"))
        let first = store.start(makeRun(taskID: "first"))
        let second = store.start(makeRun(taskID: "second"))
        let third = store.start(makeRun(taskID: "third"))

        for run in [first, second, third] {
            #expect(store.finishRun(
                id: run.id,
                outcome: outcome(exitCode: 0, stdout: run.taskID),
                cancelled: false
            ))
        }

        #expect(store.runs.count == 3)
        #expect(store.run(forID: active.id) != nil)
        #expect(store.run(forID: third.id) != nil)
        #expect(store.run(forID: second.id) != nil)
        #expect(store.run(forID: first.id) == nil)
    }

    @Test("Terminal transitions enforce retained UTF-8 byte budget")
    func terminalTrimByteBudget() {
        let store = UserTaskRunStore(
            maximumRuns: 10,
            maximumRetainedOutputBytes: 8
        )
        let first = store.start(makeRun(taskID: "first"))
        let second = store.start(makeRun(taskID: "second"))

        store.finishRun(
            id: first.id,
            outcome: outcome(exitCode: 0, stdout: "123456"),
            cancelled: false
        )
        store.finishRun(
            id: second.id,
            outcome: outcome(exitCode: 0, stdout: "abcdef"),
            cancelled: false
        )

        #expect(store.run(forID: first.id) == nil)
        #expect(store.run(forID: second.id) != nil)
        #expect(store.retainedOutputByteCount == 6)
    }

    @Test("Shutdown cancels and waits on every registered active handle")
    func shutdownCancelsAndWaits() {
        let store = UserTaskRunStore()
        let first = store.start(makeRun(taskID: "first"))
        let second = store.start(makeRun(taskID: "second"))
        let counter = CancellationCounter()
        let waits = CancellationCounter()
        let handle = {
            UserTaskCancellation(
                terminate: {
                    counter.increment()
                    return true
                },
                waitForCompletion: { _ in
                    waits.increment()
                    return true
                }
            )
        }
        store.registerCancellation(handle(), forRunID: first.id)
        store.registerCancellation(handle(), forRunID: second.id)

        #expect(store.shutdownAll(until: .now() + 1))
        #expect(counter.value == 2)
        #expect(waits.value == 2)
        #expect(store.runs.isEmpty)
    }

    @Test("Shutdown timeout retains cancelling run and its handle")
    func shutdownTimeoutRetainsOwnership() {
        let store = UserTaskRunStore()
        let run = store.start(makeRun())
        let counter = CancellationCounter()
        store.registerCancellation(
            UserTaskCancellation(
                terminate: {
                    counter.increment()
                    return true
                },
                waitForCompletion: { _ in false }
            ),
            forRunID: run.id
        )

        #expect(!store.shutdownAll(until: .now()))
        #expect(run.state == .cancelling)
        #expect(store.run(forID: run.id)?.id == run.id)
        #expect(store.cancellationHandleCount == 1)
        #expect(counter.value == 1)
    }

    @Test("Elapsed time advances while active and freezes at completion")
    func elapsedTimeLifecycle() {
        let startedAt = Date(timeIntervalSinceReferenceDate: 1_000)
        let run = makeRun(startedAt: startedAt)

        #expect(run.elapsedSeconds(at: startedAt - 10) == 0)
        #expect(run.elapsedText(at: startedAt + 65.9) == "1:05")

        run.markRunning()
        run.applyOutcome(
            stdout: "",
            stderr: "",
            exitCode: 0,
            timedOut: false,
            cancelled: false,
            finishedAt: startedAt + 3_661.9
        )

        #expect(run.state == .succeeded)
        #expect(run.elapsedText(at: startedAt + 10_000) == "1:01:01")
        #expect(
            abs(run.elapsedSeconds(at: startedAt + 10_000) - 3_661.9)
                < 0.001
        )
    }

    @Test("Elapsed formatter covers minute and hour boundaries")
    func elapsedFormatterBoundaries() {
        #expect(UserTaskRun.formatElapsedDuration(0) == "0:00")
        #expect(UserTaskRun.formatElapsedDuration(59.999) == "0:59")
        #expect(UserTaskRun.formatElapsedDuration(60) == "1:00")
        #expect(UserTaskRun.formatElapsedDuration(3_599) == "59:59")
        #expect(UserTaskRun.formatElapsedDuration(3_600) == "1:00:00")
        #expect(UserTaskRun.formatElapsedDuration(90_061) == "25:01:01")
    }

    @Test("Copy payload exactly matches the displayed combined output")
    func outputCopyPayload() {
        let stdoutOnly = makeRun(taskID: "stdout")
        stdoutOnly.applyOutcome(
            stdout: "standard output",
            stderr: "",
            exitCode: 0,
            timedOut: false,
            cancelled: false
        )
        #expect(stdoutOnly.outputCopyPayload == "standard output")

        let stderrOnly = makeRun(taskID: "stderr")
        stderrOnly.applyOutcome(
            stdout: "",
            stderr: "standard error",
            exitCode: 7,
            timedOut: false,
            cancelled: false
        )
        #expect(stderrOnly.outputCopyPayload == "standard error")

        let combined = makeRun(taskID: "combined")
        combined.applyOutcome(
            stdout: "standard output",
            stderr: "standard error",
            exitCode: 7,
            timedOut: false,
            cancelled: false
        )
        #expect(
            combined.outputCopyPayload
                == "standard output\nstandard error"
        )
        #expect(combined.outputCopyPayload == combined.combinedOutput)
    }

    private func makeRun(
        taskID: String = "task",
        startedAt: Date = Date()
    ) -> UserTaskRun {
        UserTaskRun(
            taskID: taskID,
            taskLabel: taskID,
            command: "printf done",
            replacesFileContent: false,
            startedAt: startedAt
        )
    }

    private func makeCancellation(
        counter: CancellationCounter,
        accepted: Bool = true
    ) -> UserTaskCancellation {
        UserTaskCancellation {
            counter.increment()
            return accepted
        }
    }

    private func outcome(
        exitCode: Int32,
        stdout: String = ""
    ) -> UserTaskOutcome {
        UserTaskOutcome(
            taskID: "task",
            stdout: stdout,
            stderr: "",
            exitCode: exitCode,
            timedOut: false
        )
    }
}

nonisolated private final class CancellationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.withLock { storage }
    }

    func increment() {
        lock.withLock {
            storage += 1
        }
    }
}
