//
//  SymbolCoordinator.swift
//  Pine
//
//  Document-symbol revision tracking for #1008.
//

import Foundation

/// Tracks the current immutable document revision and invalidates stale work.
nonisolated final class SymbolCoordinator: @unchecked Sendable {
    private let generation = StructuralGeneration()

    /// Starts a new immutable document revision and invalidates older work.
    func beginRevision() -> DocumentRevision {
        DocumentRevision(generation.increment())
    }

    /// Invalidates pending provider work when the navigator closes.
    func invalidate() {
        generation.increment()
    }

    /// Whether a local fallback computed for `revision` may still be shown.
    func isCurrent(_ revision: DocumentRevision) -> Bool {
        generation.current == revision.value
    }

}
