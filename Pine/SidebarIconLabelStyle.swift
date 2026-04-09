//
//  SidebarIconLabelStyle.swift
//  Pine
//
//  Fixes issue #763: file/folder names in the sidebar were not vertically
//  aligned because SF Symbols used by `FileIconMapper` have variable
//  intrinsic glyph widths (e.g. `shield`, `book.closed`, `list.bullet`,
//  `doc`, `folder`). The fix is to constrain the icon view itself to a
//  fixed width via `Image(systemName:).frame(width:, alignment: .center)`
//  inside the `Label`'s icon closure, so every row's icon reports the
//  same width to `Label` and the text column lines up no matter which
//  SF Symbol the row uses.
//

import Foundation
import SwiftUI

/// Geometry constants for sidebar file/folder icons.
///
/// Centralised so the value referenced by `FileNodeRow` and its regression
/// tests stay in sync.
enum SidebarIconMetrics {
    /// Width of the icon view in points. Applied via
    /// `Image(systemName:).frame(width:)` so every row's icon reports the
    /// same width to its surrounding `Label`, producing a single x-coordinate
    /// for the text column.
    ///
    /// 21pt is the empirical width of the widest SF Symbol used by
    /// `FileIconMapper` (`chevron.left.forwardslash.chevron.right`). Measured
    /// via `ImageRenderer` in `SidebarIconMetricsTests.sfSymbolsFitInsideSlot`.
    static let iconSlotWidth: CGFloat = 21
}
