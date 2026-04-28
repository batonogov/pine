//
//  BackgroundDispatchTests.swift
//  PineTests
//
//  Unit tests for `runOnBackground` — the helper that bridges
//  `DispatchQueue.global(qos:).async` work back into Swift Concurrency.
//  Covers issue #898.
//

import Foundation
import Testing

@testable import Pine

@Suite("BackgroundDispatch Tests")
struct BackgroundDispatchTests {

    // MARK: - Result delivery

    @Test("Non-throwing variant returns the closure's value verbatim")
    func nonThrowingReturnsValue() async {
        let result = await runOnBackground { 42 }
        #expect(result == 42)
    }

    @Test("Non-throwing variant returns sentinel string unchanged")
    func nonThrowingReturnsString() async {
        let sentinel = "pine-runs-on-background"
        let result = await runOnBackground { sentinel }
        #expect(result == sentinel)
    }

    @Test("Non-throwing variant returns optional .none when closure does")
    func nonThrowingReturnsNilOptional() async {
        let result: Int? = await runOnBackground { Int?.none }
        #expect(result == nil)
    }

    // MARK: - Off-main-thread execution

    @Test("Closure body runs off the main thread")
    func closureRunsOffMain() async {
        let isMain = await runOnBackground { (pthread_main_np() != 0) }
        #expect(isMain == false)
    }

    @Test("Closure body runs off the main thread when invoked from MainActor")
    @MainActor
    func closureRunsOffMainFromMainActor() async {
        // Sanity: the test is genuinely starting from the main actor.
        #expect((pthread_main_np() != 0))
        let isMain = await runOnBackground { (pthread_main_np() != 0) }
        #expect(isMain == false)
    }

    // MARK: - QoS forwarding

    @Test("userInitiated QoS forwards to the queue (probed via qos_class_self)")
    func userInitiatedQoSForwarded() async {
        let qosClass = await runOnBackground(qos: .userInitiated) {
            qos_class_self()
        }
        #expect(qosClass == QOS_CLASS_USER_INITIATED)
    }

    @Test("utility QoS forwards to the queue (probed via qos_class_self)")
    func utilityQoSForwarded() async {
        let qosClass = await runOnBackground(qos: .utility) {
            qos_class_self()
        }
        #expect(qosClass == QOS_CLASS_UTILITY)
    }

    @Test("background QoS forwards to the queue (probed via qos_class_self)")
    func backgroundQoSForwarded() async {
        let qosClass = await runOnBackground(qos: .background) {
            qos_class_self()
        }
        #expect(qosClass == QOS_CLASS_BACKGROUND)
    }

    // MARK: - Concurrency

    @Test("Many concurrent runOnBackground calls all complete")
    func concurrentCallsAllComplete() async {
        let count = 64
        let results: [Int] = await withTaskGroup(of: Int.self) { group in
            for index in 0..<count {
                group.addTask {
                    await runOnBackground { index * 2 }
                }
            }
            var collected: [Int] = []
            for await value in group {
                collected.append(value)
            }
            return collected.sorted()
        }
        let expected = (0..<count).map { $0 * 2 }
        #expect(results == expected)
    }

    @Test("Concurrent calls execute on background threads (none of them on main)")
    func concurrentCallsAllOffMain() async {
        let count = 32
        let allOffMain: Bool = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<count {
                group.addTask {
                    await runOnBackground { !(pthread_main_np() != 0) }
                }
            }
            var allOk = true
            for await offMain in group where !offMain {
                allOk = false
            }
            return allOk
        }
        #expect(allOffMain)
    }

    // MARK: - Throwing variant — success path

    @Test("Throwing variant returns value when closure does not throw")
    func throwingReturnsValueOnSuccess() async throws {
        let result = try await runOnBackground { 7 * 6 }
        #expect(result == 42)
    }

    @Test("Throwing variant runs body off the main thread")
    func throwingRunsOffMain() async throws {
        let isMain = try await runOnBackground { (pthread_main_np() != 0) }
        #expect(isMain == false)
    }

    @Test("Throwing variant honours custom QoS")
    func throwingHonoursQoS() async throws {
        let qosClass = try await runOnBackground(qos: .utility) {
            qos_class_self()
        }
        #expect(qosClass == QOS_CLASS_UTILITY)
    }

    // MARK: - Throwing variant — error path

    /// Sentinel error type used to verify error propagation across the bridge.
    private struct SentinelError: Error, Equatable {
        let code: Int
    }

    @Test("Throwing variant propagates errors thrown by the closure")
    func throwingPropagatesError() async {
        await #expect(throws: SentinelError(code: 99)) {
            try await runOnBackground { () -> Int in
                throw SentinelError(code: 99)
            }
        }
    }

    @Test("Throwing variant propagates standard library errors")
    func throwingPropagatesStandardError() async {
        struct NotFound: Error {}
        await #expect(throws: NotFound.self) {
            try await runOnBackground { () -> String in
                throw NotFound()
            }
        }
    }

    @Test("Throwing variant succeeds even when closure could throw but does not")
    func throwingNoThrowSucceeds() async throws {
        // Closure typed as `throws` — branch taken is the success branch.
        let result = try await runOnBackground { () throws -> String in
            if false { throw SentinelError(code: 0) }
            return "ok"
        }
        #expect(result == "ok")
    }

    // MARK: - Sendable values flow correctly

    @Test("Closure can return a struct of Sendable values")
    func returnsSendableStruct() async {
        struct Bundle: Sendable, Equatable {
            let count: Int
            let label: String
        }
        let result = await runOnBackground {
            Bundle(count: 3, label: "ok")
        }
        #expect(result == Bundle(count: 3, label: "ok"))
    }

    @Test("Closure can return an array of Sendable values")
    func returnsSendableArray() async {
        let result = await runOnBackground { [1, 2, 3, 5, 8] }
        #expect(result == [1, 2, 3, 5, 8])
    }

    // MARK: - Closure runs only once

    @Test("Closure body executes exactly once per call")
    func closureRunsOnce() async {
        let counter = AtomicCounter()
        _ = await runOnBackground {
            counter.increment()
        }
        #expect(counter.value == 1)
    }

    @Test("Throwing closure body executes exactly once per call (success path)")
    func throwingClosureRunsOnceOnSuccess() async throws {
        let counter = AtomicCounter()
        _ = try await runOnBackground {
            counter.increment()
        }
        #expect(counter.value == 1)
    }

    @Test("Throwing closure body executes exactly once per call (error path)")
    func throwingClosureRunsOnceOnError() async {
        let counter = AtomicCounter()
        await #expect(throws: SentinelError.self) {
            try await runOnBackground { () -> Int in
                counter.increment()
                throw SentinelError(code: 1)
            }
        }
        #expect(counter.value == 1)
    }
}

// MARK: - Test helpers

/// Lock-backed counter used to verify a closure body fires exactly once
/// across thread boundaries. Marked `@unchecked Sendable` because the
/// underlying `NSLock` provides serialization. All members are `nonisolated`
/// so the struct's actor isolation cannot leak into the counter and confuse
/// the closure-isolation inference inside `runOnBackground` test bodies.
nonisolated final class AtomicCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = 0

    func increment() {
        lock.lock()
        storedValue += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }
}
