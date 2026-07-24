//
//  ConcurrentWriteBufferTests.swift
//  PineTests
//
//  Regression coverage for the `@unchecked Sendable` buffer wrapper used by
//  `WorkspaceManager.loadTopLevelInParallel` (issue #1197 — Xcode 26/27
//  warning debt). The pre-fix raw `UnsafeMutableBufferPointer` triggered a
//  `#SendableClosureCaptures` warning inside `DispatchQueue.concurrentPerform`.
//

import Foundation
import Testing

@testable import Pine

@Suite("ConcurrentWriteBuffer Tests")
struct ConcurrentWriteBufferTests {

    /// Indexed writes from a `DispatchQueue.concurrentPerform` closure must
    /// land at the correct index with no cross-index corruption. Each index
    /// is written by exactly one iteration — the documented invariant that
    /// justifies `@unchecked Sendable`.
    @Test("Indexed concurrent writes land at correct positions")
    func indexedWritesRoundTrip() {
        let count = 256
        let buffer = ConcurrentWriteBuffer<Int?>(
            storage: UnsafeMutableBufferPointer<Int?>.allocate(capacity: count)
        )
        buffer.storage.initialize(repeating: nil)
        defer { buffer.storage.deallocate() }

        DispatchQueue.concurrentPerform(iterations: count) { index in
            buffer.storage[index] = index * 3
        }

        let values = (0..<count).compactMap { buffer.storage[$0] }
        #expect(values.count == count)
        // Every slot holds exactly its index × 3 — no cross-index corruption.
        for (index, value) in values.enumerated() {
            #expect(value == index * 3)
        }
    }

    /// The wrapper crossing a `@Sendable` closure boundary is the regression
    /// guard: this compiles only because `ConcurrentWriteBuffer` is
    /// `@unchecked Sendable`. A raw `UnsafeMutableBufferPointer` would emit
    /// the `#SendableClosureCaptures` warning.
    @Test("Wrapper crosses @Sendable closure boundary")
    func crossesSendableBoundary() {
        let buffer = ConcurrentWriteBuffer<Int?>(
            storage: UnsafeMutableBufferPointer<Int?>.allocate(capacity: 1)
        )
        buffer.storage.initialize(repeating: nil)
        defer { buffer.storage.deallocate() }

        let writer: @Sendable (Int) -> Void = { value in
            buffer.storage[0] = value
        }
        writer(42)
        #expect(buffer.storage[0] == 42)
    }
}
