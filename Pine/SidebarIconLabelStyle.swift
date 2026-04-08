//
//  SidebarIconLabelStyle.swift
//  Pine
//
//  Fixes issue #763: file/folder names in the sidebar were not vertically
//  aligned because SF Symbols used by `FileIconMapper` have variable
//  intrinsic widths (e.g. `shield`, `book.closed`, `list.bullet`, `doc`,
//  `folder`). SwiftUI's default `Label` puts the text flush against the
//  icon, so each row's text started at a different x-coordinate.
//
//  This `LabelStyle` reserves a fixed-width slot for the icon so every row
//  starts its text on the same baseline — matching Finder/Xcode behaviour.
//
//  Apple-way notes:
//    * Implemented as a `LabelStyle`, not an HStack wrapper. This keeps the
//      `Label` as the root view of the row so SwiftUI's `List` / `OutlineGroup`
//      selection highlighting and XCUITest accessibility lookups continue to
//      work. PR #770 was reverted precisely because an HStack wrapper broke
//      both of those.
//    * Uses `.frame(width:)` with `.center` alignment so asymmetric glyphs
//      (e.g. `list.bullet`) are optically centred inside the slot.
//    * Spacing between icon and title is explicit (6pt) — matches the default
//      `Label` visual rhythm and Finder's list view.
//

import SwiftUI

/// A `LabelStyle` that gives the icon a fixed-width slot so titles across
/// rows line up on the same vertical baseline regardless of which SF Symbol
/// the row uses.
struct SidebarIconLabelStyle: LabelStyle {
    /// Width of the icon slot in points. 18pt comfortably fits the widest
    /// SF Symbol used by `FileIconMapper` (`list.bullet`, `folder`,
    /// `doc.text`) at the default sidebar font size without clipping, while
    /// staying tight enough to not look sparse.
    static let iconSlotWidth: CGFloat = 18

    /// Horizontal spacing between the icon slot and the title, in points.
    /// Mirrors SwiftUI's default `Label` spacing.
    static let iconTitleSpacing: CGFloat = 6

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: Self.iconTitleSpacing) {
            configuration.icon
                .frame(width: Self.iconSlotWidth, alignment: .center)
            configuration.title
        }
    }
}

extension LabelStyle where Self == SidebarIconLabelStyle {
    /// Sugar so call sites read `.labelStyle(.sidebarIcon)`.
    static var sidebarIcon: SidebarIconLabelStyle { SidebarIconLabelStyle() }
}
