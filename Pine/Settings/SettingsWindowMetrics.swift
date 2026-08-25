//
//  SettingsWindowMetrics.swift
//  Pine
//
//  Single source of truth for the Settings scene's size (#1531).
//

import AppKit
import SwiftUI

/// Size floors for the consolidated Settings scene.
///
/// Settings used to declare `720 × 540` in five separate files. Five localized
/// `.tabItem` titles have to share that width, and nothing reports when they
/// do not fit: SwiftUI's macOS `TabView` does not fold the tab strip into its
/// intrinsic size, so an overlong strip is simply truncated. German and
/// Russian titles need more than 720 pt, which cost eight of the nine shipped
/// locales part of their Settings navigation (#1531).
///
/// The window therefore derives its width floor from the titles it is about to
/// draw, and every surface declares floors instead of fixed dimensions so the
/// panes grow with the window. English still resolves to exactly 720 pt, so
/// locales that already fit are unchanged.
@MainActor
enum SettingsWindowMetrics {
    /// The historical Settings width, kept as the floor for short locales.
    static let baselineWidth: CGFloat = 720
    /// The historical Settings height, now a floor rather than a pin.
    static let baselineHeight: CGFloat = 540
    /// Height a single pane keeps before it starts scrolling.
    static let paneMinimumHeight: CGFloat = 500
    /// Height reserved for the agent-handoff section inside the Agents pane.
    static let handoffSectionMinimumHeight: CGFloat = 380

    /// Width a tab item spends on its SF Symbol and the symbol-to-title gap.
    /// `SettingsWindowMetricsTests.symbolAllowanceCoversRenderedLabels` pins
    /// this against SwiftUI's own `Label` measurement so it cannot drift into
    /// an underestimate.
    static let tabItemSymbolAllowance: CGFloat = 28
    /// Horizontal padding a tab item keeps around its label, both edges.
    static let tabItemPadding: CGFloat = 24
    /// Inset the strip keeps between the outermost tabs and the window edge.
    static let tabStripInset: CGFloat = 24

    /// The font the tab strip renders its titles in.
    static var tabStripFont: NSFont {
        .systemFont(ofSize: NSFont.systemFontSize)
    }

    /// Width one tab item needs to render `title` without truncating.
    static func tabItemWidth(
        for title: String,
        font: NSFont = tabStripFont
    ) -> CGFloat {
        let text = (title as NSString)
            .size(withAttributes: [.font: font])
            .width
        return text.rounded(.up) + tabItemSymbolAllowance + tabItemPadding
    }

    /// Width the whole tab strip needs for `titles`.
    static func tabStripWidth(
        forTabTitles titles: [String],
        font: NSFont = tabStripFont
    ) -> CGFloat {
        guard !titles.isEmpty else { return 0 }
        return titles.reduce(tabStripInset) {
            $0 + tabItemWidth(for: $1, font: font)
        }
    }

    /// The Settings window's width floor for `titles` — never below the
    /// historical 720 pt, and never below what the strip actually needs.
    static func minimumWidth(
        forTabTitles titles: [String],
        font: NSFont = tabStripFont
    ) -> CGFloat {
        max(baselineWidth, tabStripWidth(forTabTitles: titles, font: font))
    }
}

extension View {
    /// Applies the Settings window's locale-derived size floors (#1531).
    @MainActor
    func settingsWindowSize(tabTitles: [String]) -> some View {
        let width = SettingsWindowMetrics.minimumWidth(forTabTitles: tabTitles)
        return frame(
            minWidth: width,
            idealWidth: width,
            minHeight: SettingsWindowMetrics.baselineHeight,
            idealHeight: SettingsWindowMetrics.baselineHeight
        )
    }

    /// Applies the size floors shared by every Settings pane (#1531). Panes
    /// fill whatever the window hands them instead of pinning their own size.
    @MainActor
    func settingsPaneSize(
        minimumHeight: CGFloat = SettingsWindowMetrics.paneMinimumHeight
    ) -> some View {
        frame(
            minWidth: SettingsWindowMetrics.baselineWidth,
            maxWidth: .infinity,
            minHeight: minimumHeight,
            maxHeight: .infinity
        )
    }
}
