//
//  AgentTaskHydrationBarrier.swift
//  Pine
//
//  The race-free hydration barrier of the ADE lifecycle contract (#1722).
//
//  A structured stream reconnecting to an already-live attempt must not
//  apply deltas against a stale view. The barrier is the shared ordering
//  contract the structured adapters (#1723, #1756) implement against:
//
//  1. Buffer incoming deltas while the current state is fetched.
//  2. Obtain the reconciled current state of one attempt (the snapshot):
//     outstanding turns and requests reconciled, identity revalidated.
//  3. Apply only the buffered deltas proven newer than that state within
//     the same attempt, through the ONE shared evidence fence.
//
//  A quiet stream (no deltas, no positive provider state) reconciles to
//  `unknown`, never to a positive execution state, and never settles an
//  outcome: silence is not completion.
//

import Foundation

/// One attempt's reconciled current state obtained during hydration.
///
/// `runID` and `processGeneration` revalidate the attempt identity against
/// the durable task; `vendorSession` revalidates the provider session
/// reference when both sides carry one. `watermark` is the source sequence
/// the provider reports as last-seen in the fetched state — present only
/// for documented ordered delivery. For unordered/no-replay delivery it is
/// `nil`, and no "newer" ordering is manufactured: deltas then pass only
/// the shared fence.
nonisolated struct AgentTaskHydrationSnapshot: Equatable, Sendable {
    let runID: UUID
    let processGeneration: UInt64
    let vendorSession: AgentVendorSessionIdentity?
    let watermark: UInt64?
    /// The reconciled execution dimension. A quiet or failed reconciliation
    /// reports `.unknown` — the barrier never upgrades it to a positive
    /// state.
    let executionState: AgentTaskExecutionState
}

/// The disposition of one buffered delta through the barrier.
nonisolated enum AgentTaskHydrationDeltaDisposition: Equatable, Sendable {
    /// Proven newer within the same attempt and applied through the shared
    /// evidence fence.
    case applied
    /// An ordered delta at or below the fetched state's watermark: the
    /// fetched state already reflects it (replay or re-emission).
    case staleReplay
    /// An ordered stream delivered a delta without a source sequence, so
    /// it cannot be proven newer than the fetched state. Fail closed.
    case unprovenNewer
    /// The shared evidence fence refused the delta (attempt identity,
    /// process incarnation, provider session, chronology, duplicate,
    /// validity, or bound).
    case fenced(AgentTaskEvidenceFence)
}

/// Pure hydration barrier over the durable task model.
///
/// The caller buffers deltas, fetches the reconciled state, and hands both
/// to `hydrate` in one call; the barrier is the only place the ordering
/// between them is decided. It mutates the task in place exactly like the
/// registry's `recordEvidence` seam: admitted facts append, a fact for the
/// latest settled run re-settles the attempt, and nothing else changes.
nonisolated enum AgentTaskHydrationBarrier {
    @discardableResult
    static func hydrate(
        _ task: inout AgentTask,
        snapshot: AgentTaskHydrationSnapshot,
        deltas: [AgentTaskEvidenceFact]
    ) -> [AgentTaskHydrationDeltaDisposition] {
        guard let runIndex = task.runs.firstIndex(where: {
            $0.id == snapshot.runID
        }) else {
            // The fetched state references an attempt this task does not
            // own: nothing is applied and the task keeps its honest view.
            return deltas.map { _ in .fenced(.unknownRun) }
        }
        let run = task.runs[runIndex]
        guard run.process.processGeneration == snapshot.processGeneration else {
            return deltas.map { _ in .fenced(.foreignProcess) }
        }
        if let snapshotSession = snapshot.vendorSession,
           let runIdentity = run.vendorIdentity,
           snapshotSession.provider != runIdentity.provider
               || snapshotSession.opaqueIdentifier != runIdentity.opaqueIdentifier {
            // The reconciled state's identity does not revalidate against
            // the bound run: the snapshot is not trusted.
            return deltas.map { _ in .fenced(.foreignVendorSession) }
        }
        // Reconciliation: the fetched state is the current execution
        // dimension for the attempt it describes. A snapshot of a replaced
        // (non-latest) attempt never overwrites the current attempt's view.
        if runIndex == task.runs.indices.last {
            task.executionState = snapshot.executionState
        }
        return deltas.map {
            applyDelta($0, to: &task, at: runIndex, watermark: snapshot.watermark)
        }
    }

    private static func applyDelta(
        _ delta: AgentTaskEvidenceFact,
        to task: inout AgentTask,
        at runIndex: Int,
        watermark: UInt64?
    ) -> AgentTaskHydrationDeltaDisposition {
        guard let watermark else {
            // Unordered/no-replay delivery: no "newer" ordering exists or is
            // manufactured; the shared fence is the whole protection.
            return admitAndApply(delta, to: &task, at: runIndex)
        }
        guard let sequence = delta.sourceSequence else {
            // Ordered delivery without a sequence cannot be proven newer
            // than the fetched state.
            return .unprovenNewer
        }
        guard sequence > watermark else {
            return .staleReplay
        }
        return admitAndApply(delta, to: &task, at: runIndex)
    }

    /// Mirrors the registry's `recordEvidence` effects exactly: one fence,
    /// one append, re-settlement of a latest settled run, chronological
    /// `updatedAt`.
    private static func admitAndApply(
        _ delta: AgentTaskEvidenceFact,
        to task: inout AgentTask,
        at runIndex: Int
    ) -> AgentTaskHydrationDeltaDisposition {
        let admission = AgentTaskLifecycleReducer.admit(delta, into: task)
        guard case .accepted = admission else {
            if case let .fencedOut(fence) = admission { return .fenced(fence) }
            return .fenced(.invalidFact)
        }
        task.evidence.append(delta)
        AgentTaskLifecycleReducer.settleLatestRun(of: &task, runIndex: runIndex)
        task.updatedAt = max(task.updatedAt, delta.observedAt)
        return .applied
    }
}
