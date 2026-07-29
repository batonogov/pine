//
//  AgentKeyboardSelection.swift
//  Pine
//
//  Shared keyboard selection model for the Agent Attention overlay (#1245).
//
//  Provides arrow-key navigation (Up/Down), Return to activate the selected
//  row, and Escape to dismiss while restoring the previous first responder.
//  The model is a value-type `@Observable`-free helper: the owning view holds
//  `selectedIndex` in `@State` and calls these pure functions so the behaviour
//  stays snapshot-testable without a live window.
//

import Foundation

/// Pure keyboard-selection helpers for Agent Attention and any future overlay
/// that lists selectable rows.
///
/// Keeping the logic nonisolated and free of UI types lets it be unit-tested
/// directly (see `AgentKeyboardSelectionTests`) and reused by both the
/// Attention overlay and snapshot harnesses.
nonisolated enum AgentKeyboardSelection {
    /// Preserves a stable row identity across insertion and reordering.
    static func normalizeID<ID: Equatable>(
        _ current: ID?,
        ids: [ID]
    ) -> ID? {
        guard let first = ids.first else { return nil }
        guard let current, ids.contains(current) else { return first }
        return current
    }

    /// Moves a stable row identity by `delta` in the current visual order.
    static func moveID<ID: Equatable>(
        from current: ID?,
        by delta: Int,
        ids: [ID]
    ) -> ID? {
        guard let normalized = normalizeID(current, ids: ids),
              let index = ids.firstIndex(of: normalized),
              let destination = move(
                  from: index,
                  by: delta,
                  count: ids.count
              ) else {
            return nil
        }
        return ids[destination]
    }

    /// Normalizes a possibly stale selection after the backing rows change.
    ///
    /// A missing selection starts at the first row. An index outside the new
    /// bounds is clamped to the closest surviving row.
    static func normalize(
        _ current: Int?,
        count: Int
    ) -> Int? {
        guard count > 0 else { return nil }
        guard let current else { return 0 }
        return max(0, min(count - 1, current))
    }

    /// Returns the new selection after moving by `delta` positions, clamped to
    /// `[0, count - 1]`. Returns `nil` when there is nothing to select.
    ///
    /// - Parameters:
    ///   - current: The current selection index, or `nil` when nothing is
    ///     selected.
    ///   - delta: Signed step to move (e.g. `-1` for Up, `+1` for Down).
    ///   - count: Total number of selectable rows.
    /// - Returns: The new selection index, or `nil` if `count == 0`.
    static func move(
        from current: Int?,
        by delta: Int,
        count: Int
    ) -> Int? {
        guard let base = normalize(current, count: count) else { return nil }
        let (next, overflowed) = base.addingReportingOverflow(delta)
        if overflowed {
            return delta < 0 ? 0 : count - 1
        }
        return max(0, min(count - 1, next))
    }

    /// Resolves the selection to activate on Return.
    ///
    /// Returns the current selection, or — when nothing is selected — the first
    /// row so the overlay is operable immediately without an explicit arrow
    /// press. Returns `nil` when there are no rows.
    static func resolveReturn(
        current: Int?,
        count: Int
    ) -> Int? {
        guard count > 0 else { return nil }
        if let current, (0..<count).contains(current) { return current }
        return 0
    }
}
