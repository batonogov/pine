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

    // MARK: - Autorelease pool hygiene (#1509)

    // `DispatchQueue.global()` work items run with **no** autorelease pool in
    // place. Anything the body autoreleases — every Foundation/AppKit bridge
    // that returns an autoreleased instance — is then parked in libobjc's
    // thread-wide fallback pool and stays alive until the dispatch worker
    // thread itself is torn down. A full `PineTests` run under
    // `OBJC_DEBUG_MISSING_POOLS=YES` logs thousands of
    // "autoreleased with no pool in place - just leaking" warnings because of
    // this. `runOnBackground` is Pine's single background-work choke point, so
    // it owns the pool.
    //
    // The probe below makes that observable: `Unmanaged.autorelease()` hands
    // the object to the current pool, so the object is deallocated when — and
    // only when — a pool drains.

    @Test("Non-throwing variant drains autoreleased objects before returning")
    func nonThrowingDrainsAutoreleasePool() async {
        let deallocations = AtomicCounter()
        _ = await runOnBackground {
            let probe = AutoreleaseProbe(deallocations: deallocations)
            _ = Unmanaged.passRetained(probe).autorelease()
        }
        #expect(deallocations.value == 1)
    }

    @Test("Throwing variant drains autoreleased objects before returning")
    func throwingDrainsAutoreleasePool() async throws {
        let deallocations = AtomicCounter()
        _ = try await runOnBackground { () -> Int in
            let probe = AutoreleaseProbe(deallocations: deallocations)
            _ = Unmanaged.passRetained(probe).autorelease()
            return 1
        }
        #expect(deallocations.value == 1)
    }

    @Test("Throwing variant drains the pool even when the body throws")
    func throwingDrainsAutoreleasePoolOnError() async {
        let deallocations = AtomicCounter()
        await #expect(throws: SentinelError.self) {
            try await runOnBackground { () -> Int in
                let probe = AutoreleaseProbe(deallocations: deallocations)
                _ = Unmanaged.passRetained(probe).autorelease()
                throw SentinelError(code: 1509)
            }
        }
        #expect(deallocations.value == 1)
    }

    @Test("Every closure gets its own drain, not one shared at thread death")
    func repeatedCallsEachDrainTheirOwnPool() async {
        let deallocations = AtomicCounter()
        for _ in 0..<8 {
            _ = await runOnBackground {
                let probe = AutoreleaseProbe(deallocations: deallocations)
                _ = Unmanaged.passRetained(probe).autorelease()
            }
        }
        #expect(deallocations.value == 8)
    }

    // MARK: - Autorelease pool hygiene on other dispatch surfaces (#1548)

    // `runOnBackground` is Pine's background-work choke point, but not the
    // only dispatch surface. Custom serial queues default to
    // `autoreleaseFrequency: .inherit`, which on GCD's pool-less worker
    // threads means no pool at all — the same shape as a raw
    // `DispatchQueue.global().async`. The surfaces fixed in #1548 declare
    // `.workItem` (the `pine.fswatcher`, `com.pine.tool-resolver-cache`,
    // `com.pine.lsp-transport`, `com.pine.lsp-transport.lifecycle`, and
    // `com.pine.agent-history` queues) or wrap
    // their bodies in `autoreleasepool` (the remaining raw global-queue work
    // items). The production queues are `private`, so these tests mirror the
    // configuration they now declare. Note what `.workItem` covers per
    // libdispatch: asynchronously drained work items — including contended
    // `sync` that turns into an async waiter hand-off. The uncontended
    // `queue.sync` fast path runs on the caller's thread, where pool
    // ownership stays with the caller. There is deliberately no test
    // asserting the *absence* of a drain on an unpooled surface: a worker
    // thread being torn down can drain the fallback pool and flip the result.

    @Test("A .workItem queue drains autoreleased objects when the work item returns")
    func workItemQueueDrainsAutoreleasedObjectsPerWorkItem() {
        let queue = DispatchQueue(
            label: "com.pine.tests.autorelease-workitem",
            qos: .utility,
            autoreleaseFrequency: .workItem
        )
        let deallocations = AtomicCounter()
        queue.async {
            let probe = AutoreleaseProbe(deallocations: deallocations)
            _ = Unmanaged.passRetained(probe).autorelease()
        }
        // Barrier: returns only after the enqueued item has fully drained.
        queue.sync {}
        #expect(deallocations.value == 1)
    }

    @Test("A .workItem queue drains per work item, not once at thread teardown")
    func workItemQueueGivesEachWorkItemItsOwnPool() {
        let queue = DispatchQueue(
            label: "com.pine.tests.autorelease-workitem-serial",
            qos: .utility,
            autoreleaseFrequency: .workItem
        )
        let deallocations = AtomicCounter()
        for _ in 0..<8 {
            queue.async {
                let probe = AutoreleaseProbe(deallocations: deallocations)
                _ = Unmanaged.passRetained(probe).autorelease()
            }
        }
        // Barrier: with a single shared fallback pool the probes would still
        // be alive here (count 0) — only a per-item drain reaches 8.
        queue.sync {}
        #expect(deallocations.value == 8)
    }

    @Test("A raw global-queue work item drains when its body wraps in autoreleasepool")
    func wrappedGlobalQueueWorkItemDrainsItsPool() {
        // Same shape as the wrapped sites in #1548 (GitFetcher's parallel
        // fetches, the zombie reaper in ExternalFileFormatter): the body is
        // wrapped, the group handshake stays outside the pool.
        let deallocations = AtomicCounter()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            autoreleasepool {
                let probe = AutoreleaseProbe(deallocations: deallocations)
                _ = Unmanaged.passRetained(probe).autorelease()
            }
            group.leave()
        }
        group.wait()
        #expect(deallocations.value == 1)
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

/// Object whose `deinit` records into an ``AtomicCounter``. Handed to
/// `Unmanaged.autorelease()` so its deallocation observes exactly one thing:
/// whether an autorelease pool drained while the closure body was on the
/// stack. `NSObject` because `objc_autorelease` is the mechanism under test.
nonisolated final class AutoreleaseProbe: NSObject, @unchecked Sendable {
    private let deallocations: AtomicCounter

    init(deallocations: AtomicCounter) {
        self.deallocations = deallocations
        super.init()
    }

    deinit { deallocations.increment() }
}
