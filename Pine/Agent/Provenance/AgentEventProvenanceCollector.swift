//
//  AgentEventProvenanceCollector.swift
//  Pine
//
//  Trusted event provenance slice (epic #933, section 1 — "Trusted event
//  provenance").
//
//  `AgentEventProvenanceCollector` is the seam a future provenance pipeline
//  adopts to RECORD `AgentEventEnvelope` values. This file ships the protocol
//  and a no-op default only; it deliberately performs NO live terminal or
//  file-system wiring (that belongs to a later slice, once #1183's safety gate
//  is in place).
//

import Foundation

/// The seam a provenance pipeline adopts to record trusted agent events.
///
/// Adopters (a future terminal/process observer, an explicit agent-event
/// channel, etc.) build an `AgentEventEnvelope` and hand it here. The
/// collector is responsible for persisting / indexing it. This protocol is
/// `Sendable` so it can be shared across isolation domains; concrete
/// adopters decide their own concurrency (actor, main-actor, queue).
///
/// - Important: Recording an envelope is metadata only. It must not perform
///   any working-tree mutation, and it must not authorize an undo — those
///   are separate, #1183-gated operations.
nonisolated protocol AgentEventProvenanceCollector: Sendable {
    /// Records a trusted (or explicitly heuristic) agent event.
    ///
    /// - Parameter envelope: The provenance envelope to store/index.
    func record(_ envelope: AgentEventEnvelope) async
}

/// A no-op collector used as a safe default and for tests.
///
/// Drops every recorded envelope. Pine can hold an instance as the default
/// collector until a real provenance pipeline is wired in (later slice), so
/// call sites never deal with optionality.
nonisolated struct NullAgentEventProvenanceCollector: AgentEventProvenanceCollector {
    func record(_ envelope: AgentEventEnvelope) async {
        // Intentionally empty: provenance recording is disabled.
    }
}
