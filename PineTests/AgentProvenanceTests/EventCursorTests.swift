//
//  EventCursorTests.swift
//  PineTests
//
//  Tests for EventCursor (epic #933, slice 1 — trusted event provenance).
//

import Foundation
import Testing

@testable import Pine

struct EventCursorTests {

    // MARK: - Monotonicity

    @Test func firstValue_isOneByDefault() async {
        let cursor = EventCursor()
        #expect(await cursor.current == 0)
        let first = await cursor.next()
        #expect(first == 1)
        #expect(await cursor.current == 1)
    }

    @Test func next_isStrictlyMonotonic() async {
        let cursor = EventCursor()
        var previous: UInt64 = 0
        for _ in 0..<1_000 {
            let value = await cursor.next()
            #expect(value > previous)
            previous = value
        }
        #expect(await cursor.current == 1_000)
    }

    @Test func seed_advancesFromProvidedValue() async {
        let cursor = EventCursor(seed: 99)
        #expect(await cursor.current == 99)
        #expect(await cursor.next() == 100)
        #expect(await cursor.next() == 101)
        #expect(await cursor.current == 101)
    }

    @Test func next_canBeDiscarded() async {
        let cursor = EventCursor()
        // @discardableResult allows ignoring the return value.
        await cursor.next()
        await cursor.next()
        let third = await cursor.next()
        #expect(third == 3)
    }

    // MARK: - Thread safety / concurrency

    @Test func concurrentIncrements_neverRepeatOrReorder() async {
        // Many tasks each mint a batch of values concurrently. Because the
        // cursor is an actor, increments are serialized: every value must be
        // unique and the total count must equal tasks * batch.
        let cursor = EventCursor()
        let tasks = 16
        let perTask = 500

        let collected = await withTaskGroup(of: [UInt64].self, returning: [UInt64].self) { group in
            for _ in 0..<tasks {
                group.addTask {
                    var values: [UInt64] = []
                    values.reserveCapacity(perTask)
                    for _ in 0..<perTask {
                        values.append(await cursor.next())
                    }
                    return values
                }
            }
            var all: [UInt64] = []
            for await batch in group {
                all.append(contentsOf: batch)
            }
            return all
        }

        #expect(collected.count == tasks * perTask)
        // No duplicates across concurrent callers.
        let unique = Set(collected)
        #expect(unique.count == collected.count)
        // Values span 1...total with no gaps and no overflow.
        let total = UInt64(tasks * perTask)
        #expect(unique.min() == 1)
        #expect(unique.max() == total)
        let current = await cursor.current
        #expect(current == total)
    }

    @Test func concurrentIncrements_fromNonZeroSeed_preserveMonotonicity() async {
        let seed: UInt64 = 1_000
        let cursor = EventCursor(seed: seed)
        let tasks = 8
        let perTask = 100

        let collected = await withTaskGroup(of: [UInt64].self, returning: Set<UInt64>.self) { group in
            for _ in 0..<tasks {
                group.addTask {
                    var values: [UInt64] = []
                    for _ in 0..<perTask {
                        values.append(await cursor.next())
                    }
                    return values
                }
            }
            var unique: Set<UInt64> = []
            for await batch in group {
                unique.formUnion(batch)
            }
            return unique
        }

        let total = UInt64(tasks * perTask)
        #expect(collected.count == Int(total))
        #expect(collected.min() == seed + 1)
        #expect(collected.max() == seed + total)
    }
}
