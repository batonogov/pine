//
//  SidebarIconLabelStyle.swift
//  Pine
//
//  Fixes issue #763: file/folder names in the sidebar were not vertically
//  aligned because SF Symbols used by `FileIconMapper` have variable
//  intrinsic glyph widths (e.g. `shield`, `book.closed`, `list.bullet`,
//  `doc`, `folder`). SwiftUI's default `Label` puts the text flush against
//  whatever the icon view actually measures, so each row's text started at
//  a different x-coordinate.
//
//  Approach (after PRs #766/#770/#775v1 were reverted):
//
//    * Do NOT introduce a custom `LabelStyle` that reserves an icon slot
//      via an HStack — SwiftUI's default `Label` already provides the
//      correct icon→text spacing and `List`/`OutlineGroup` selection
//      highlighting. Replacing the body with a custom HStack changes the
//      leading inset and inflates vertical rhythm (this is exactly what
//      Federico saw with #775v1: top-level rows visually drifted right and
//      grew taller).
//
//    * Instead, only constrain the *icon view itself* to a fixed width via
//      `Image(systemName:).frame(width:, alignment: .center)`. The icon is
//      still rendered by the default `Label` body, so spacing/insets stay
//      identical to a stock SwiftUI Label. The frame guarantees that every
//      row reports the same icon width to `Label`, which makes the text
//      column line up no matter which SF Symbol the row uses.
//
//    * 21pt is the empirical width of the widest SF Symbol used by
//      `FileIconMapper` (`chevron.left.forwardslash.chevron.right`, used
//      for xml/svg/go). `hammer` and `wrench.and.screwdriver` rasterise
//      to ~19pt; `terminal`/`photo`/`film` to 18pt; most others to 13–16pt.
//      Measured via `ImageRenderer` in
//      `SidebarIconMetricsTests.sfSymbolsFitInsideSlot`. The previous
//      value 22pt looked the same numerically but was applied via a
//      custom `LabelStyle` HStack body that replaced the native Label
//      layout — that inflated vertical rhythm and broke top-level
//      alignment. Here, the frame is applied directly on the `Image`
//      *inside* the icon closure, so the surrounding `Label` keeps its
//      native horizontal spacing and inset behaviour.
//

import Foundation
import SwiftUI

/// Geometry constants for sidebar file/folder icons.
///
/// Centralised so the value referenced by `FileNodeRow` and the regression
/// test stay in sync.
enum SidebarIconMetrics {
    /// Width of the icon view in points. Applied via
    /// `Image(systemName:).frame(width:)` so every row's icon reports the
    /// same width to its surrounding `Label`, producing a single x-coordinate
    /// for the text column.
    static let iconSlotWidth: CGFloat = 21

    /// Leading inset (in points) applied to *file-leaf* rows so their icon
    /// lines up horizontally with the icon of a sibling folder row.
    ///
    /// Folder rows are rendered as the label of a `DisclosureGroup` inside
    /// `SidebarDisclosureGroupStyle`, which prepends a custom chevron of
    /// `width: 10` followed by `HStack(spacing: 2)` before the label — so
    /// a folder's icon starts 12pt to the right of the row's leading edge.
    /// File-leaf rows have no chevron, so without compensation their icon
    /// sits at x = 0 and visually drifts left of every folder icon (#763,
    /// reported after PR #775 only equalised icons *between themselves*).
    ///
    /// Keep this in sync with `SidebarDisclosureGroupStyle` in
    /// `SidebarFileTree.swift` — if the chevron width or HStack spacing
    /// changes there, update this value too. A dedicated regression test
    /// in `SidebarIconLabelStyleTests` asserts the math stays consistent.
    ///
    /// Implementation note: the inset is applied as a
    /// `.padding(.leading, …)` *on the icon Image inside the Label's icon
    /// closure*, not as an HStack wrapper around the entire row. Wrapping
    /// the row in an HStack (as PR #770 did) moved `Label` out of the row
    /// root and broke XCUITest `outline.cells[...]` lookups plus SwiftUI
    /// `List` selection highlighting — both were reverted in #772/#773.
    static let fileLeafLeadingInset: CGFloat = 12
}
