//
//  UserTaskProcessTelemetry.swift
//  Pine
//

#if DEBUG
import Foundation

/// Debug-only counters for observing process-tree monitoring cost (issue #1718).
///
/// The counters let a controlled build report how often terminal capture
/// passes run, how long they take, and how many libproc enumeration calls
/// they issue. Release builds compile this file out entirely; no production
/// path depends on it.
nonisolated final class UserTaskProcessTelemetryCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0

    func increment() {
        lock.withLock { value &+= 1 }
    }

    func add(_ amount: UInt64) {
        lock.withLock { value &+= amount }
    }

    var current: UInt64 {
        lock.withLock { value }
    }

    func reset() {
        lock.withLock { value = 0 }
    }
}

nonisolated enum UserTaskProcessTelemetry {
    struct Snapshot: Sendable, Codable {
        var scheduledCaptures: UInt64
        var captureDurationNanoseconds: UInt64
        var listChildPidsFills: UInt64
        var listChildPidsSizings: UInt64
        var listPgrpPidsFills: UInt64
        var listPgrpPidsSizings: UInt64
        var bsdInfoLookups: UInt64
    }

    private static let scheduledCaptures = UserTaskProcessTelemetryCounter()
    private static let captureDurationNanoseconds = UserTaskProcessTelemetryCounter()
    private static let listChildPidsFills = UserTaskProcessTelemetryCounter()
    private static let listChildPidsSizings = UserTaskProcessTelemetryCounter()
    private static let listPgrpPidsFills = UserTaskProcessTelemetryCounter()
    private static let listPgrpPidsSizings = UserTaskProcessTelemetryCounter()
    private static let bsdInfoLookups = UserTaskProcessTelemetryCounter()

    static func snapshot() -> Snapshot {
        Snapshot(
            scheduledCaptures: scheduledCaptures.current,
            captureDurationNanoseconds: captureDurationNanoseconds.current,
            listChildPidsFills: listChildPidsFills.current,
            listChildPidsSizings: listChildPidsSizings.current,
            listPgrpPidsFills: listPgrpPidsFills.current,
            listPgrpPidsSizings: listPgrpPidsSizings.current,
            bsdInfoLookups: bsdInfoLookups.current
        )
    }

    static func reset() {
        scheduledCaptures.reset()
        captureDurationNanoseconds.reset()
        listChildPidsFills.reset()
        listChildPidsSizings.reset()
        listPgrpPidsFills.reset()
        listPgrpPidsSizings.reset()
        bsdInfoLookups.reset()
    }

    static func recordScheduledCapture(durationNanoseconds: UInt64) {
        scheduledCaptures.increment()
        captureDurationNanoseconds.add(durationNanoseconds)
    }

    static func recordListChildPidsCall(sizing: Bool) {
        if sizing {
            listChildPidsSizings.increment()
        } else {
            listChildPidsFills.increment()
        }
    }

    static func recordListPgrpPidsCall(sizing: Bool) {
        if sizing {
            listPgrpPidsSizings.increment()
        } else {
            listPgrpPidsFills.increment()
        }
    }

    static func recordBsdInfoLookup() {
        bsdInfoLookups.increment()
    }
}
#endif
