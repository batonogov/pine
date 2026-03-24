//
//  PineAnimation.swift
//  Pine
//
//  Standardized motion system for consistent animations across the app.
//  Follows Apple HIG: subtle, purposeful motion that communicates hierarchy.
//

import SwiftUI

/// Centralized animation constants for Pine.
/// Use these instead of ad-hoc animation values throughout the codebase.
enum PineAnimation {
    // MARK: - Quick Transitions (tab switch, sidebar toggle, state changes)

    /// Fast easeInOut for immediate UI responses (tab switch, sidebar toggle, indicators).
    static let quick: Animation = .easeInOut(duration: 0.2)

    // MARK: - Overlay Transitions (sheets, popovers, overlays)

    /// Spring animation for overlays (Quick Open, Go to Line, branch switcher).
    static let overlay: Animation = .spring(response: 0.3, dampingFraction: 0.9)

    // MARK: - Content Transitions (content appearing/disappearing)

    /// Standard content transition for views that swap between states.
    static let content: Animation = .easeInOut(duration: 0.25)

    // MARK: - Standard Transitions

    /// Opacity fade for appearing/disappearing content.
    static let fadeTransition: AnyTransition = .opacity
}
