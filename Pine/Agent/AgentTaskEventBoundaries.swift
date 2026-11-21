//
//  AgentTaskEventBoundaries.swift
//  Pine
//
//  Bounded per-task and cross-task event traffic for concurrent ADE tasks
//  (#1728).
//

import Foundation

/// The documented resource bounds for concurrent ADE task traffic (#1728).
///
/// Bounds apply to the sum of the concurrent tasks of one current project.
/// Authoritative traffic — lifecycle transitions, and provider request and
/// response pairs — is never coalesced or silently dropped: when it cannot
/// be retained, admission returns `.overflow` and the caller must fail
/// closed (the task degrades to needs-decision/`unknown`, never to a
/// fabricated positive state). Non-authoritative deltas — activity ticks,
/// output chunks, presentation hints — may be coalesced by their stable key
/// or dropped under pressure. Captured output and retained diagnostics are
/// byte-bounded per task and per project respectively.
nonisolated enum AgentTaskEventQueueLimits {
    static let maximumQueuedEventsPerTask = 256
    static let maximumQueuedEventsAcrossTasks = 4_096
    static let maximumEventPayloadBytes = 65_536
    static let maximumCoalescingKeysPerTask = 32
    static let maximumCoalescingKeyBytes = 256
    static let maximumCapturedOutputBytesPerTask = 1_048_576
    static let maximumRetainedDiagnosticsBytes = 4_194_304
}

/// One bounded unit of task traffic awaiting processing.
///
/// `launchGeneration` and `runID` are the fencing keys: a drained event is
/// attributed to exactly the attempt and admission generation that
/// produced it, and an event for another task, run, or generation settles
/// nothing.
nonisolated struct AgentTaskQueuedEvent: Equatable, Sendable {
    let taskID: UUID
    let runID: UUID
    let launchGeneration: UInt64
    /// Authoritative events (lifecycle, request/response) must survive
    /// intact; only non-authoritative events may be coalesced or dropped.
    let isAuthoritative: Bool
    /// Stable key of a non-authoritative delta that may be coalesced with
    /// its predecessor. `nil` means the event stands alone. Bounded to
    /// `maximumCoalescingKeyBytes`; over-long keys are never retained.
    let coalescingKey: String?
    var payload: Data
    /// Number of earlier deltas coalesced into this entry (0 = none).
    var coalescedCount: Int

    init(
        taskID: UUID,
        runID: UUID,
        launchGeneration: UInt64,
        isAuthoritative: Bool,
        coalescingKey: String?,
        payload: Data
    ) {
        self.taskID = taskID
        self.runID = runID
        self.launchGeneration = launchGeneration
        self.isAuthoritative = isAuthoritative
        self.coalescingKey = coalescingKey
        self.payload = payload
        coalescedCount = 0
    }
}

nonisolated enum AgentTaskEventAdmission: Equatable, Sendable {
    case accepted
    /// A non-authoritative delta replaced the earlier entry with the same
    /// coalescing key; the delta count is retained, not lost.
    case coalesced
    /// The payload was truncated to the documented byte bound before
    /// admission.
    case truncated
    /// The event was dropped under queue pressure. Only non-authoritative
    /// events are ever dropped.
    case dropped
    /// An authoritative event could not be retained. The caller MUST fail
    /// closed; the overflow marker stays set for the task until it is
    /// cleared with the task's own teardown.
    case overflow
}

nonisolated enum AgentTaskOutputRetention: Equatable, Sendable {
    case appended
    /// The per-task captured-output bound is reached; further output is
    /// retained no further. Presentation must say so, not pretend.
    case truncatedToBound
}

nonisolated enum AgentTaskDiagnosticsRetention: Equatable, Sendable {
    case retained
    /// The project-wide diagnostics pool is exhausted; the diagnostic was
    /// not retained.
    case overflowed
}

/// The bounded per-task event queue and the project-wide captured-output
/// and diagnostics budgets. Every bound is checked before mutation, so the
/// counts and byte totals never exceed the documented constants.
actor AgentTaskEventBoundaries {
    private var queues: [UUID: [AgentTaskQueuedEvent]] = [:]
    private var totalQueued = 0
    private var authoritativeOverflow: Set<UUID> = []
    private var capturedOutputBytes: [UUID: Int] = [:]
    private var outputTruncated: Set<UUID> = []
    private var retainedDiagnosticsBytes = 0
    private var diagnosticsOverflowed = false

    /// Sticky fail-closed marker: true while an authoritative event for the
    /// task could not be retained. It is only cleared by the task's own
    /// `clear`, never by traffic.
    func hasAuthoritativeOverflow(_ taskID: UUID) -> Bool {
        authoritativeOverflow.contains(taskID)
    }

    func isOutputTruncated(_ taskID: UUID) -> Bool {
        outputTruncated.contains(taskID)
    }

    func isDiagnosticsOverflowed() -> Bool { diagnosticsOverflowed }

    /// Admits one bounded event under the documented limits.
    func enqueue(_ event: AgentTaskQueuedEvent) -> AgentTaskEventAdmission {
        if let key = event.coalescingKey,
           key.utf8.count > AgentTaskEventQueueLimits.maximumCoalescingKeyBytes {
            // An over-long key is malformed traffic: never retained. An
            // authoritative event carrying one is authoritative traffic that
            // cannot be retained, so it fails closed like any other
            // authoritative overflow.
            if event.isAuthoritative {
                authoritativeOverflow.insert(event.taskID)
                return .overflow
            }
            return .dropped
        }
        var queued = event
        let wasTruncated =
            queued.payload.count > AgentTaskEventQueueLimits.maximumEventPayloadBytes
        if wasTruncated {
            queued.payload = Data(
                queued.payload.prefix(AgentTaskEventQueueLimits.maximumEventPayloadBytes)
            )
        }
        if !queued.isAuthoritative, let key = queued.coalescingKey {
            let entries = queues[queued.taskID, default: []]
            // Coalescing is per (task, attempt, launch generation): a
            // relaunch without a prior clear must not fold a new attempt's
            // deltas into the old attempt's entry.
            if let index = entries.firstIndex(where: {
                $0.coalescingKey == key
                    && $0.runID == queued.runID
                    && $0.launchGeneration == queued.launchGeneration
            }) {
                var updated = entries
                updated[index].payload = queued.payload
                updated[index].coalescedCount += 1
                queues[queued.taskID] = updated
                return .coalesced
            }
            let keyedCount = entries.reduce(0) { $0 + ($1.coalescingKey != nil ? 1 : 0) }
            guard keyedCount < AgentTaskEventQueueLimits.maximumCoalescingKeysPerTask else {
                return .dropped
            }
            return admit(queued, truncated: wasTruncated)
        }
        return admit(queued, truncated: wasTruncated)
    }

    private func admit(
        _ queued: AgentTaskQueuedEvent, truncated: Bool
    ) -> AgentTaskEventAdmission {
        let entries = queues[queued.taskID, default: []]
        let fitsPerTask =
            entries.count < AgentTaskEventQueueLimits.maximumQueuedEventsPerTask
        let fitsAcrossTasks =
            totalQueued < AgentTaskEventQueueLimits.maximumQueuedEventsAcrossTasks
        guard fitsPerTask, fitsAcrossTasks else {
            if queued.isAuthoritative {
                authoritativeOverflow.insert(queued.taskID)
                return .overflow
            }
            return .dropped
        }
        queues[queued.taskID, default: []].append(queued)
        totalQueued += 1
        return truncated ? .truncated : .accepted
    }

    /// Returns the task's queued events in admission order and clears them.
    /// Coalesced counts travel with their entries.
    func drain(taskID: UUID) -> [AgentTaskQueuedEvent] {
        let entries = queues[taskID] ?? []
        totalQueued -= entries.count
        queues[taskID] = nil
        return entries
    }

    /// Bounded captured output for one task. Bytes beyond the per-task
    /// bound are not retained; the task is then flagged so presentation can
    /// state the truncation honestly.
    func recordCapturedOutput(taskID: UUID, bytes: Int) -> AgentTaskOutputRetention {
        guard bytes > 0 else { return .appended }
        let bound = AgentTaskEventQueueLimits.maximumCapturedOutputBytesPerTask
        let current = capturedOutputBytes[taskID, default: 0]
        guard current < bound else { return .truncatedToBound }
        let next = current + bytes
        capturedOutputBytes[taskID] = min(next, bound)
        if next > bound {
            outputTruncated.insert(taskID)
        }
        return next > bound ? .truncatedToBound : .appended
    }

    /// Bounded retained diagnostics across all concurrent tasks of the
    /// project. Once the pool is exhausted nothing further is retained.
    func retainDiagnostics(taskID: UUID, bytes: Int) -> AgentTaskDiagnosticsRetention {
        guard bytes > 0 else { return .retained }
        let bound = AgentTaskEventQueueLimits.maximumRetainedDiagnosticsBytes
        guard retainedDiagnosticsBytes + bytes <= bound else {
            diagnosticsOverflowed = true
            return .overflowed
        }
        retainedDiagnosticsBytes += bytes
        return .retained
    }

    /// Task-owned teardown (cancellation, dismissal, relaunch cleanup):
    /// removes the task's queue, overflow marker, and output budget so no
    /// resource or failure state leaks into another task.
    func clear(taskID: UUID) {
        if let entries = queues[taskID] {
            totalQueued -= entries.count
            queues[taskID] = nil
        }
        authoritativeOverflow.remove(taskID)
        capturedOutputBytes.removeValue(forKey: taskID)
        outputTruncated.remove(taskID)
    }
}
