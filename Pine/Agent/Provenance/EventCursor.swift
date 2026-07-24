//
//  EventCursor.swift
//  Pine
//
//  Trusted event provenance slice (epic #933, section 1 — "Trusted event
//  provenance"). `EventCursor` mints monotonically increasing, per-process
//  event sequence numbers that anchor each `AgentEventEnvelope` to a precise
//  position in the event stream.
//
//  A monotonic cursor lets the UI and a future safe-undo path order events
//  unambiguously and detect gaps/reordering when two agents touch the same
//  project (see the #933 Snailflyer comment: "event cursor before and after
//  the action"). `actor` isolation guarantees increments are atomic and
//  safe to call from any thread.
//

import Foundation

/// A monotonically increasing, thread-safe source of event sequence numbers.
///
/// Each call to `next()` returns a value strictly greater than every prior
/// return from the same cursor. The current value is also exposed as
/// `current` (the last minted value, or the seed before any call). Concurrency
/// safety comes from `actor` isolation: increments are serialized, so two
/// concurrent callers can never observe the same value or an out-of-order
/// pair.
///
/// This type mints values only; it is not itself persisted. The produced
/// `UInt64` is carried by `AgentEventEnvelope.cursorValue`, so a stored
/// envelope remains a plain `Codable` value.
actor EventCursor {
    /// The most recently minted value. Before any `next()` call this is the
    /// seed; afterwards it is the last returned value.
    private(set) var current: UInt64

    /// Creates a cursor whose first minted value will be `seed + 1`.
    ///
    /// - Parameter seed: The value `current` holds before the first `next()`.
    ///   Defaults to `0` so the first minted value is `1`. A non-default seed
    ///   supports deterministic testing and resuming after a restart.
    init(seed: UInt64 = 0) {
        self.current = seed
    }

    /// Mints the next sequence number.
    ///
    /// - Returns: A value strictly greater than every value previously
    ///   returned by this cursor.
    /// - Precondition: `current` has not overflowed `UInt64.max`.
    @discardableResult
    func next() -> UInt64 {
        precondition(current < UInt64.max, "EventCursor exhausted: UInt64 overflow")
        current &+= 1
        return current
    }
}
