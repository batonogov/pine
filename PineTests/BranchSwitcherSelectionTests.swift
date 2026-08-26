//
//  BranchSwitcherSelectionTests.swift
//  PineTests
//
//  Locks the keyboard contract of the Branch Switcher (#1522).
//
//  The switcher's only side effect is a real `git checkout`, so the tests
//  below are written around one invariant: no cancellation path may ever
//  produce a `.checkout` action, in any state.
//

import Foundation
import Testing

@testable import Pine

@Suite("BranchSwitcherSelection")
struct BranchSwitcherSelectionTests {

    private static let branches = [
        "main",
        "feature/keyboard-trap",
        "fix/branch-switcher",
        "release/2.6"
    ]

    private func selection(
        filter: String = "",
        index: Int = 0,
        branches: [String] = BranchSwitcherSelectionTests.branches
    ) -> BranchSwitcherSelection {
        BranchSwitcherSelection(
            branches: branches,
            filter: filter,
            selectedIndex: index
        )
    }

    // MARK: - Escape / Cancel never checks out

    @Test("Escape dismisses without checking out")
    func cancelDismisses() {
        #expect(selection().action(for: .cancel) == .dismiss)
    }

    @Test("Escape dismisses from every reachable state")
    func cancelNeverCheckoutsInAnyState() {
        let filters = ["", "fix", "FIX", "release", "nothing-matches", "/"]
        let indices = [-3, -1, 0, 1, 2, 3, 7, Int.max]
        let branchLists: [[String]] = [
            [],
            ["main"],
            Self.branches
        ]

        for list in branchLists {
            for filter in filters {
                for index in indices {
                    let state = selection(
                        filter: filter,
                        index: index,
                        branches: list
                    )
                    #expect(
                        state.action(for: .cancel) == .dismiss,
                        """
                        Escape must dismiss, never mutate the working tree \
                        (branches: \(list.count), filter: '\(filter)', \
                        index: \(index))
                        """
                    )
                }
            }
        }
    }

    @Test("Escape cancels even when a switchable branch is selected")
    func cancelWithNonCurrentBranchSelected() {
        let state = selection(index: 1)
        #expect(state.selectedBranch == "feature/keyboard-trap")
        #expect(state.action(for: .cancel) == .dismiss)
    }

    // MARK: - Filtering

    @Test("An empty filter shows every branch")
    func emptyFilterShowsAll() {
        #expect(selection().filteredBranches == Self.branches)
    }

    @Test("Filtering is a case-insensitive substring match")
    func filterIsCaseInsensitiveSubstring() {
        #expect(
            selection(filter: "FIX").filteredBranches == ["fix/branch-switcher"]
        )
        #expect(
            selection(filter: "e/").filteredBranches
                == ["feature/keyboard-trap", "release/2.6"]
        )
    }

    @Test("A filter that matches nothing yields no rows")
    func filterWithNoMatches() {
        #expect(selection(filter: "zzz").filteredBranches.isEmpty)
    }

    // MARK: - Index resolution

    @Test("The resolved index clamps into the filtered range")
    func resolvedIndexClamps() {
        #expect(selection(index: -5).resolvedIndex == 0)
        #expect(selection(index: 2).resolvedIndex == 2)
        #expect(selection(index: 99).resolvedIndex == 3)
    }

    @Test("A stale index survives the list shrinking under it")
    func staleIndexAfterFilterNarrows() {
        // Selected row 3 of the unfiltered list, then the filter narrows the
        // list to a single row. The stale index must not select out of bounds.
        let state = selection(filter: "fix", index: 3)
        #expect(state.filteredBranches.count == 1)
        #expect(state.resolvedIndex == 0)
        #expect(state.selectedBranch == "fix/branch-switcher")
    }

    @Test("A stale index survives the filter emptying the list")
    func staleIndexAfterFilterEmptiesList() {
        // The adjacent case to `staleIndexAfterFilterNarrows`: the filter cuts
        // the list all the way to zero rows while a high index is still held.
        let state = selection(filter: "zzz", index: 3)
        #expect(state.filteredBranches.isEmpty)
        #expect(state.resolvedIndex == nil)
        #expect(state.selectedBranch == nil)
        #expect(!state.isSelected(index: 3))
        #expect(state.action(for: .activate) == .none)
        #expect(state.action(for: .up) == .none)
        #expect(state.action(for: .down) == .none)
        #expect(state.action(for: .cancel) == .dismiss)
    }

    @Test("A stale index survives the branch list disappearing entirely")
    func staleIndexAfterBranchesVanish() {
        // git refresh can empty `branches` outright (repository closed, or a
        // failed status read) while the view still holds its last row.
        let state = selection(index: 3, branches: [])
        #expect(state.resolvedIndex == nil)
        #expect(state.selectedBranch == nil)
        #expect(state.action(for: .activate) == .none)
        #expect(state.action(for: .cancel) == .dismiss)
    }

    @Test("An empty list resolves to no index and no branch")
    func emptyListHasNoSelection() {
        let state = selection(filter: "zzz")
        #expect(state.resolvedIndex == nil)
        #expect(state.selectedBranch == nil)
    }

    @Test("isSelected marks exactly the resolved row")
    func isSelectedMarksResolvedRow() {
        let state = selection(index: 2)
        #expect(!state.isSelected(index: 0))
        #expect(!state.isSelected(index: 1))
        #expect(state.isSelected(index: 2))
        #expect(!state.isSelected(index: 3))
    }

    @Test("isSelected marks nothing when the list is empty")
    func isSelectedOnEmptyList() {
        let state = selection(filter: "zzz")
        #expect(!state.isSelected(index: 0))
    }

    // MARK: - Selected branch

    @Test("The selected branch follows the filtered list, not the full list")
    func selectedBranchFollowsFilteredList() {
        #expect(selection(index: 1).selectedBranch == "feature/keyboard-trap")
        #expect(
            selection(filter: "e/", index: 1).selectedBranch == "release/2.6"
        )
    }

    // MARK: - Arrow navigation

    @Test("Down moves the selection one row forward")
    func downMovesForward() {
        #expect(selection(index: 0).action(for: .down) == .move(to: 1))
        #expect(selection(index: 1).action(for: .down) == .move(to: 2))
    }

    @Test("Up moves the selection one row back")
    func upMovesBack() {
        #expect(selection(index: 3).action(for: .up) == .move(to: 2))
        #expect(selection(index: 1).action(for: .up) == .move(to: 0))
    }

    @Test("Arrow keys stop at the ends instead of wrapping")
    func arrowsClampAtBounds() {
        #expect(selection(index: 0).action(for: .up) == .none)
        #expect(selection(index: 3).action(for: .down) == .none)
    }

    @Test("Arrow keys move relative to the clamped index")
    func arrowsUseClampedIndex() {
        // A stale out-of-range index must not stride further out of range.
        #expect(selection(index: 99).action(for: .up) == .move(to: 2))
        #expect(selection(index: -9).action(for: .down) == .move(to: 1))
    }

    @Test("Arrow keys do nothing on an empty list")
    func arrowsOnEmptyList() {
        #expect(selection(filter: "zzz").action(for: .up) == .none)
        #expect(selection(filter: "zzz").action(for: .down) == .none)
    }

    @Test("Arrow navigation is bounded by the filtered list")
    func arrowsBoundedByFilter() {
        let state = selection(filter: "e/", index: 1)
        #expect(state.filteredBranches.count == 2)
        #expect(state.action(for: .down) == .none)
        #expect(state.action(for: .up) == .move(to: 0))
    }

    // MARK: - Return activates

    @Test("Return checks out the selected branch")
    func activateChecksOutSelection() {
        #expect(
            selection(index: 2).action(for: .activate)
                == .checkout("fix/branch-switcher")
        )
    }

    @Test("Return respects the active filter")
    func activateRespectsFilter() {
        #expect(
            selection(filter: "e/", index: 1).action(for: .activate)
                == .checkout("release/2.6")
        )
    }

    @Test("Return does nothing when nothing is selectable")
    func activateOnEmptyList() {
        #expect(selection(filter: "zzz").action(for: .activate) == .none)
        #expect(selection(branches: []).action(for: .activate) == .none)
    }

    @Test("Return with a stale index checks out the clamped row")
    func activateWithStaleIndex() {
        #expect(
            selection(index: 99).action(for: .activate)
                == .checkout("release/2.6")
        )
    }
}
