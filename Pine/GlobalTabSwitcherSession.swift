//
//  GlobalTabSwitcherSession.swift
//  Pine
//
//  Visual MRU tab switcher session state (issue #1239).
//
//  A `GlobalTabSwitcherSession` is the transient, frozen-in-time snapshot that
//  backs the Control-Tab overlay. It is created by `PaneManager` the moment the
//  user presses Control-Tab and is torn down on commit (Control release) or
//  cancellation (Escape). The long-lived MRU order itself lives on
//  `PaneManager.globalTabSwitchOrder` and remains the single source of truth —
//  this struct only captures a stable view of it so the overlay does not
//  re-shuffle while the user cycles.
//
//  Design notes:
//  - `identities` is a snapshot of `PaneManager.validGlobalTabSwitchOrder()`
//    taken at session start, so repeated Control-Tab presses walk a fixed,
//    deterministic list even if an organic activation would otherwise have
//    reordered it mid-cycle.
//  - `originalIdentity` records where the user started so Escape can restore it
//    exactly. It is optional because the active tab may not be in the MRU list
//    (e.g. a freshly opened, never-activated tab).
//  - `selectedIndex` is the live cursor the overlay highlights. Cycling wraps.
//

import Foundation
import SwiftUI

/// Frozen-in-time MRU snapshot backing the visual Control-Tab switcher.
///
/// Owned by `PaneManager` (`globalTabSwitcherSession`); `nil` when no switching
/// session is active. The overlay view observes `PaneManager` and renders while
/// this is non-`nil`.
struct GlobalTabSwitcherSession: Equatable {
    /// The MRU-ordered identities captured at session start. The order stays
    /// frozen, but identities that disappear while the overlay is open are
    /// removed by ``reconciled(keeping:)``.
    let identities: [GlobalTabIdentity]

    /// The tab that was active when the session began, used to restore on
    /// cancellation. `nil` when no tab was active (or the active tab was not
    /// eligible for switching).
    let originalIdentity: GlobalTabIdentity?

    /// Cursor into `identities` the overlay is currently highlighting.
    var selectedIndex: Int

    /// The identity currently under the cursor, if any.
    var selectedIdentity: GlobalTabIdentity? {
        guard identities.indices.contains(selectedIndex) else { return nil }
        return identities[selectedIndex]
    }

    /// Returns a session whose cursor and identity list agree with the tabs
    /// that still exist. Keeping reconciliation here gives the overlay and
    /// commit path one source of truth: a row can never be highlighted from a
    /// compacted list while commit indexes the older, unfiltered snapshot.
    ///
    /// If the selected tab disappeared, the nearest surviving item after it
    /// becomes selected, falling back to the nearest preceding item at the end
    /// of the list. This is based on the original order rather than the stale
    /// numeric index, so removing earlier rows cannot skip a valid neighbour.
    /// Fewer than two remaining tabs ends the switching gesture.
    func reconciled(keeping validIdentities: Set<GlobalTabIdentity>) -> Self? {
        let previouslySelected = selectedIdentity
        let remaining = identities.filter(validIdentities.contains)
        guard remaining.count >= 2 else { return nil }

        let replacement = previouslySelected.flatMap { selected in
            if validIdentities.contains(selected) {
                return selected
            }
            let nextIndex = identities.index(
                after: identities.startIndex + selectedIndex
            )
            return identities[nextIndex...].first(where: validIdentities.contains)
                ?? identities[..<(identities.startIndex + selectedIndex)]
                    .last(where: validIdentities.contains)
        }
        let reconciledIndex = replacement
            .flatMap { remaining.firstIndex(of: $0) }
            ?? 0

        return Self(
            identities: remaining,
            originalIdentity: originalIdentity,
            selectedIndex: reconciledIndex
        )
    }
}

/// Presentation model for a single row in the switcher overlay.
///
/// Built on demand from live pane/tab state so titles stay fresh even though
/// the identity *order* is frozen for the session. Value type so SwiftUI diffs
/// cheaply and the snapshot tests can construct it without a live process.
struct GlobalTabSwitcherEntry: Identifiable, Equatable {
    /// The pane-scoped identity. Drives activation on commit.
    let id: GlobalTabIdentity

    /// Primary label: file name for editor tabs, terminal name otherwise.
    let title: String

    /// SF Symbol name for the leading icon.
    let symbolName: String

    /// Tint for the leading icon. Matches the file-tree / tab-bar palette.
    let symbolColor: Color

    /// Human-readable pane context, e.g. "Pane 2". Deterministic position
    /// within the visible pane tree (left-to-right, top-to-bottom).
    let paneContext: String

    /// Stable secondary context that disambiguates duplicate titles. Editor
    /// rows use a project-relative path (or the external parent directory);
    /// terminal rows use their creation label plus working directory.
    let detail: String?
}

/// A self-consistent overlay projection. Both the rows and cursor come from
/// the same reconciled session snapshot.
struct GlobalTabSwitcherPresentation: Equatable {
    let entries: [GlobalTabSwitcherEntry]
    let selectedIndex: Int

    static let empty = Self(entries: [], selectedIndex: 0)
}
