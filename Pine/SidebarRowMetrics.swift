//
//  SidebarRowMetrics.swift
//  Pine
//
//  Centralised vertical-rhythm constants for the sidebar file tree.
//
//  Why this exists: the sidebar mixes two render paths — top-level rows are
//  direct `List` children (subject to the default `.sidebar` listRowSpacing /
//  insets), while nested rows live inside our custom `SidebarDisclosureGroupStyle`
//  `VStack(spacing: 0)`. To get a single, consistent vertical rhythm at every
//  nesting level (#764), we strip the List-level spacing/insets to zero and
//  let `verticalPadding(forFontSize:)` be the *only* source of vertical
//  spacing. The same function is applied identically by every row regardless
//  of depth, so spacing is provably uniform.
//

import SwiftUI

/// Constants and helpers controlling the sidebar file tree's vertical rhythm.
///
/// All values are intentionally simple so they can be unit-tested without
/// instantiating SwiftUI views.
enum SidebarRowMetrics {
    /// Row insets applied at the `List` level. Zeroed so that the per-row
    /// `padding(.vertical/.horizontal, …)` inside
    /// `SidebarFileTreeNode.row(isFolder:)` is the single source of truth
    /// for row geometry — otherwise top-level rows would pick up extra
    /// `.sidebar`-style padding while nested children would not (#764).
    static let listRowInsets: EdgeInsets = EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)

    /// Minimum row height. Set to 16pt — roughly the cap height of the
    /// system font at the default sidebar size — so SwiftUI doesn't reserve
    /// an even larger sidebar-style minimum (which would inflate top-level
    /// rows past nested ones), while still leaving a sensible floor for
    /// hit-testing. The actual visible height is driven by the row's
    /// intrinsic content (font + vertical padding) whenever it exceeds 16pt.
    static let defaultMinListRowHeight: CGFloat = 16

    /// Vertical padding applied to a single sidebar row given the current
    /// editor font size. Must be a pure function of `fontSize` so that
    /// every row at every nesting level produces the *same* value for the
    /// same input.
    ///
    /// Mirrors the formula used inline in `SidebarFileTreeNode.row(isFolder:)`:
    /// `max(fontSize * 0.15, 2)`.
    static func verticalPadding(forFontSize fontSize: CGFloat) -> CGFloat {
        max(fontSize * 0.15, 2)
    }
}
