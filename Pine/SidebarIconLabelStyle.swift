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
}
