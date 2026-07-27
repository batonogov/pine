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
    /// The MRU-ordered identities captured at session start. Immutable for the
    /// life of the session so cycling is deterministic.
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

    /// `true` when the cursor points back at the tab the session started on.
    /// Used to short-circuit a redundant restore on cancel.
    var isSelectionAtOriginal: Bool {
        guard let originalIdentity, let selectedIdentity else { return false }
        return selectedIdentity == originalIdentity
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

    /// Project-relative path for editor tabs when one can be derived; `nil`
    /// for terminals or files outside the project root.
    let relativePath: String?
}
