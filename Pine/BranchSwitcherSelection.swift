//
//  BranchSwitcherSelection.swift
//  Pine
//
//  Keyboard and selection state for the Branch Switcher (#1522).
//

import Foundation

/// Pure keyboard/selection state behind `BranchSwitcherView`.
///
/// The switcher's activation path runs a real `git checkout`, so the decision
/// of *what a key does* is kept here — free of SwiftUI, AppKit, and git — and
/// is covered by unit tests. The single invariant this type exists to
/// guarantee: `.cancel` resolves to `.dismiss` in every state, so Escape and
/// the Cancel button can never touch the working tree.
nonisolated struct BranchSwitcherSelection: Equatable, Sendable {

    /// The keys the switcher interprets. Everything else falls through to the
    /// filter field's normal text editing.
    enum Key: Equatable, Sendable {
        case up
        case down
        case activate
        case cancel
    }

    /// What the view must do in response to a key.
    enum Action: Equatable, Sendable {
        case none
        case move(to: Int)
        case checkout(String)
        case dismiss
    }

    /// Every branch known to the repository, in git's order.
    let branches: [String]
    /// The current contents of the filter field.
    let filter: String
    /// The caller's selected row. May be stale or out of range — the list can
    /// shrink underneath it when the filter changes or git refreshes.
    let selectedIndex: Int

    init(branches: [String], filter: String = "", selectedIndex: Int = 0) {
        self.branches = branches
        self.filter = filter
        self.selectedIndex = selectedIndex
    }

    /// The rows the user can actually see and act on.
    var filteredBranches: [String] {
        guard !filter.isEmpty else { return branches }
        return branches.filter { $0.localizedCaseInsensitiveContains(filter) }
    }

    /// `selectedIndex` clamped into the visible rows, or `nil` when there are
    /// none. Reading selection through this keeps a stale index harmless.
    var resolvedIndex: Int? {
        Self.resolve(selectedIndex, rowCount: filteredBranches.count)
    }

    /// The branch a Return would act on, if any.
    ///
    /// Every read is bounds-checked against the live row array rather than
    /// trusting the clamp above. The filter can shrink the list — to zero rows
    /// — under a stale `selectedIndex`, and a raw subscript there is the same
    /// defect class as the empty-recorder crash in #1506.
    var selectedBranch: String? {
        let rows = filteredBranches
        guard let index = Self.resolve(selectedIndex, rowCount: rows.count),
              rows.indices.contains(index) else { return nil }
        return rows[index]
    }

    private static func resolve(_ index: Int, rowCount: Int) -> Int? {
        guard rowCount > 0 else { return nil }
        return min(max(0, index), rowCount - 1)
    }

    /// Whether the row at `index` of `filteredBranches` is the selected one.
    func isSelected(index: Int) -> Bool {
        resolvedIndex == index
    }

    func action(for key: Key) -> Action {
        switch key {
        case .cancel:
            // Unconditional: no state may turn a cancellation into a checkout.
            return .dismiss
        case .activate:
            guard let selectedBranch else { return .none }
            return .checkout(selectedBranch)
        case .up:
            return move(by: -1)
        case .down:
            return move(by: 1)
        }
    }

    private func move(by delta: Int) -> Action {
        let rows = filteredBranches
        guard let index = Self.resolve(selectedIndex, rowCount: rows.count) else {
            return .none
        }
        let target = index + delta
        guard rows.indices.contains(target) else { return .none }
        return .move(to: target)
    }
}
