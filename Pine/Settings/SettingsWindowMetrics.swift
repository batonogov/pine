//
//  SettingsWindowMetrics.swift
//  Pine
//
//  Single source of truth for the Settings scene's size (#1531).
//

import AppKit
import SwiftUI

/// Sizing for the consolidated Settings scene.
///
/// Settings declared `720 × 540` in six separate files. This type owns those
/// numbers once and lets the window widen when — and only when — the five
/// localized `.tabItem` titles genuinely need more room.
///
/// ## What the tab strip actually does
///
/// Measured on macOS 26 against a live Settings window (`XCUIElement.frame`
/// of each tab button), not estimated:
///
/// - Tab items stack the SF Symbol **above** the title, so an item's width is
///   driven by its text alone. The symbol costs height, not width.
/// - Item widths are identical whether the window is 720 pt or 900 pt wide:
///   `68, 66.5, 117, 123.5, 165` for Russian in both. Nothing is compressed
///   and nothing is ellipsised.
/// - The strip is centred, and the widest shipped locale (Russian) spans
///   540 pt inside the 720 pt window — 88 pt of slack on each side.
///
/// So no shipped locale overflows, and `windowWidth` resolves to exactly
/// `baselineWidth` for all nine of them: shipped geometry is unchanged.
///
/// ## The overflow that is real
///
/// Under `-NSDoubleLocalizedStrings` the strip needs roughly 815 pt, and at
/// 720 pt AppKit does not truncate — it drops the fifth tab out of the window
/// entirely, removing "Key Bindings & Tasks" from the accessibility tree. That
/// is the failure mode worth guarding: silent, total, and reachable by any
/// future translation longer than today's.
@MainActor
enum SettingsWindowMetrics {
    /// The Settings width every shipped locale resolves to.
    static let baselineWidth: CGFloat = 720
    /// The Settings content height.
    static let baselineHeight: CGFloat = 540
    /// Height of a single pane's viewport.
    static let paneHeight: CGFloat = 500
    /// Height reserved for the agent-handoff section inside the Agents pane.
    static let handoffSectionHeight: CGFloat = 380

    /// Tab titles render a little tighter than the 13 pt system font; 12 pt
    /// matches the measured item widths across en/de/ru to within a few points.
    static let tabTitleFontSize: CGFloat = 12
    /// Floor an individual tab item keeps regardless of how short its title is
    /// ("General" measures 55 pt for 47 pt of text).
    static let tabItemMinimumWidth: CGFloat = 56
    /// Padding a tab item adds around its title.
    static let tabItemPadding: CGFloat = 8
    /// Margin the strip keeps between its outermost tabs and the window edge.
    static let tabStripInset: CGFloat = 16

    /// The font the tab strip renders its titles in.
    static var tabTitleFont: NSFont {
        .systemFont(ofSize: tabTitleFontSize)
    }

    /// Width one tab item needs to render `title` in full.
    static func tabItemWidth(
        for title: String,
        font: NSFont = tabTitleFont
    ) -> CGFloat {
        let text = (title as NSString)
            .size(withAttributes: [.font: font])
            .width
        return max(tabItemMinimumWidth, text.rounded(.up) + tabItemPadding)
    }

    /// Width the whole tab strip needs for `titles`.
    static func tabStripWidth(
        forTabTitles titles: [String],
        font: NSFont = tabTitleFont
    ) -> CGFloat {
        guard !titles.isEmpty else { return 0 }
        return titles.reduce(tabStripInset) {
            $0 + tabItemWidth(for: $1, font: font)
        }
    }

    /// The Settings window's width: the historical 720 pt for every shipped
    /// locale, and wider only when the strip would otherwise lose a tab.
    static func windowWidth(
        forTabTitles titles: [String],
        font: NSFont = tabTitleFont
    ) -> CGFloat {
        max(baselineWidth, tabStripWidth(forTabTitles: titles, font: font))
    }
}

extension View {
    /// Sizes the Settings window to its localized tab strip (#1531).
    @MainActor
    func settingsWindowSize(tabTitles: [String]) -> some View {
        frame(
            width: SettingsWindowMetrics.windowWidth(forTabTitles: tabTitles),
            height: SettingsWindowMetrics.baselineHeight
        )
    }

    /// Sizes a Settings pane. Deliberately rigid, exactly as before #1531:
    /// the panes were never the problem, and making them flexible let a greedy
    /// `ScrollView` drive the English window from 720 pt to 900 pt.
    @MainActor
    func settingsPaneSize(
        height: CGFloat = SettingsWindowMetrics.paneHeight
    ) -> some View {
        frame(width: SettingsWindowMetrics.baselineWidth, height: height)
    }
}
