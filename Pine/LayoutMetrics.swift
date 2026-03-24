//
//  LayoutMetrics.swift
//  Pine
//
//  Centralized layout constants for consistent spacing, font sizes,
//  and dimensions across the UI. Avoids hardcoded magic numbers.
//

import Foundation

/// Shared layout metrics for Pine UI components.
///
/// Usage: `LayoutMetrics.statusBarHeight`, `LayoutMetrics.bodySmallFontSize`, etc.
/// Centralizing these values ensures visual consistency and makes
/// design changes a single-point edit.
enum LayoutMetrics {

    // MARK: - Font sizes

    /// Small icon size (close buttons, tab chevrons). 9pt.
    static let iconSmallFontSize: CGFloat = 9

    /// Caption / badge text. 10pt.
    static let captionFontSize: CGFloat = 10

    /// Body-small / status bar items. 11pt.
    static let bodySmallFontSize: CGFloat = 11

    /// Medium icon size (file icons in tabs, preview toggle). 11pt.
    static let iconMediumFontSize: CGFloat = 11

    // MARK: - Status bar

    /// Symmetric horizontal padding for the status bar.
    static let statusBarHorizontalPadding: CGFloat = 10

    /// Status bar fixed height.
    static let statusBarHeight: CGFloat = 22

    /// Spacing between status bar items.
    static let statusBarItemSpacing: CGFloat = 6

    // MARK: - Tab bar

    /// Editor / terminal tab bar height.
    static let tabBarHeight: CGFloat = 30

    // MARK: - Search results

    /// Vertical padding for individual match rows.
    static let searchResultRowVerticalPadding: CGFloat = 2

    /// Vertical padding for file group headers.
    static let searchResultHeaderVerticalPadding: CGFloat = 4

    /// Horizontal padding for search result rows and headers.
    static let searchResultHorizontalPadding: CGFloat = 8
}
