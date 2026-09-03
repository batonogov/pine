//
//  BoundedMainActorWaitTests.swift
//  PineTests
//
//  Contract tests for the shared bounded wait (#1568). Ceilings here are
//  deliberately small so the suite stays fast; the default 5 s ceiling is
//  only ever exercised on the failure path and is not tested.
//

import Foundation
import Testing

@testable import Pine

@Suite("BoundedMainActorWait")
@MainActor
struct BoundedMainActorWaitTests {
    @Test("An already-true condition returns true without sleeping")
    func alreadyTrueConditionReturnsImmediately() async {
        let result = await waitUntilMainActor(
            { true },
            ceiling: .milliseconds(50)
        )

        #expect(result)
    }

    @Test("A never-true condition exhausts an explicit small ceiling")
    func neverTrueConditionReturnsFalse() async {
        let result = await waitUntilMainActor(
            { false },
            ceiling: .milliseconds(50)
        )

        #expect(!result)
    }

    @Test("A condition that flips mid-wait is noticed")
    func flippingConditionIsNoticed() async {
        var satisfied = false
        let flipper = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(20))
            satisfied = true
        }

        let result = await waitUntilMainActor(
            { satisfied },
            ceiling: .seconds(5)
        )

        #expect(result)
        _ = await flipper.value
    }

    @Test("A cancelled caller returns false promptly instead of spinning")
    func cancelledCallerStopsPromptly() async {
        let clock = ContinuousClock()
        let startedAt = clock.now
        let waiter = Task { @MainActor in
            await waitUntilMainActor(
                { false },
                ceiling: .seconds(10)
            )
        }
        // Give the waiter one poll iteration, then cancel it. Without the
        // explicit Task.isCancelled check, the swallowed CancellationError
        // would spin the poll hot until the 10 s ceiling and this test
        // would exceed the 5 s bound below.
        try? await Task.sleep(for: .milliseconds(10))
        waiter.cancel()

        let result = await waiter.value
        let elapsed = startedAt.duration(to: clock.now)

        #expect(!result)
        #expect(elapsed < .seconds(5))
    }
}
