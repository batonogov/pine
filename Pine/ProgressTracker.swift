//
//  ProgressTracker.swift
//  Pine
//
//  Tracks active long-running operations and provides a single
//  loading state for the UI (status bar spinner + message).
//

import Foundation

/// Thread-safe progress tracker for long-running operations.
/// Supports multiple concurrent operations — `isLoading` is true
/// while at least one operation is active.  The most recently
/// started operation's message is shown.
@Observable
final class ProgressTracker {
    /// Whether any operation is currently in progress.
    var isLoading: Bool { !operations.isEmpty }

    /// Human-readable message describing the current operation.
    /// Shows the most recently started operation.
    var message: String { operations.last?.message ?? "" }

    /// Number of active operations (useful for testing).
    var activeOperationCount: Int { operations.count }

    // Ordered list preserves insertion order for LIFO message display.
    private var operations: [Operation] = []

    private struct Operation: Identifiable {
        let id: UUID
        let message: String
    }

    /// Starts tracking a new operation.  Returns an ID to pass
    /// to `endOperation(_:)` when the work finishes.
    @discardableResult
    func beginOperation(_ message: String) -> UUID {
        let op = Operation(id: UUID(), message: message)
        operations.append(op)
        return op.id
    }

    /// Ends a previously started operation.  No-op if the ID
    /// is unknown or already ended.
    func endOperation(_ id: UUID) {
        operations.removeAll { $0.id == id }
    }
}
