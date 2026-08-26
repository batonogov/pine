//
//  PineAnimation.swift
//  Pine
//
//  Standardized motion system for consistent animations across the app.
//  Follows Apple HIG: subtle, purposeful motion that communicates hierarchy,
//  and no motion at all when the system asks for less of it.
//
//  Issue #1534: this used to be a plain constant table. Honouring Reduce Motion
//  was therefore optional at every call site, and most call sites skipped it —
//  a per-site obligation that thirty-one sites can only ever fulfil thirty of.
//  The Reduce Motion consultation now lives here, so `PineAnimation.quick`
//  already means "quick, unless the user asked for less movement".
//

import AppKit
import SwiftUI

/// What an animation is capable of moving on screen.
///
/// The distinction is the whole Reduce Motion policy: geometry is what a
/// vestibular disorder reacts to, a cross-fade is not. HIG asks for movement to
/// be *replaced* by a cross-fade, not merely shortened.
enum PineMotionIntent: Equatable, Sendable {
    /// The animation can move, scale, spring, or scroll something.
    case geometry
    /// The animation only cross-fades opacity or colour; nothing moves.
    case crossFade
}

/// The single ambient answer to "is Reduce Motion on right now".
///
/// SwiftUI views should prefer `@Environment(\.accessibilityReduceMotion)`,
/// which is reactive and overridable per view — see `GlobalTabSwitcherOverlay`.
/// This type exists for the code that has no environment to read: helper
/// methods, notification observers, and the ambient `PineAnimation` accessors
/// that keep the existing call sites correct without an edit each.
///
/// The system value is read live rather than cached. `PineAnimation` values are
/// only read while SwiftUI evaluates a body in response to the state change
/// being animated, so a live read is both cheap and always current — including
/// when the user flips the setting while Pine is running.
enum PineMotionPreference {
    /// The live system reading.
    ///
    /// Kept as a named closure rather than inlined into `reduceMotion` so a
    /// test can substitute it and prove that the returned value really does
    /// track its source. An inlined `NSWorkspace` read is untestable on a
    /// machine whose Reduce Motion happens to be off: every wrong answer and
    /// the right answer are both `false`.
    static let systemSource: () -> Bool = {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Where `reduceMotion` currently gets its answer. Production never assigns
    /// this; `withSource(_:perform:)` and `withOverride(_:perform:)` are the
    /// only supported ways to change it and both always restore the previous
    /// value. Main-actor isolated by the target's default isolation, like every
    /// consumer of the preference.
    private static var source: () -> Bool = systemSource

    /// `true` when System Settings › Accessibility › Display › Reduce Motion
    /// is enabled.
    ///
    /// Read on every access, never cached, so a user who flips the setting
    /// while Pine is running gets the new behaviour at the next state change.
    static var reduceMotion: Bool {
        source()
    }

    /// Runs `body` with the preference forced to `value`, restoring the
    /// previous source on every exit path including a thrown error.
    @discardableResult
    static func withOverride<Result>(
        _ value: Bool,
        perform body: () throws -> Result
    ) rethrows -> Result {
        try withSource({ value }, perform: body)
    }

    /// Runs `body` with the preference answered by `newSource`, restoring the
    /// previous source on every exit path including a thrown error.
    @discardableResult
    static func withSource<Result>(
        _ newSource: @escaping () -> Bool,
        perform body: () throws -> Result
    ) rethrows -> Result {
        let previous = source
        source = newSource
        defer { source = previous }
        return try body()
    }
}

/// Centralized animation constants for Pine.
/// Use these instead of ad-hoc animation values throughout the codebase.
enum PineAnimation {

    // MARK: - Base Curves

    // The design tokens. These describe what Pine looks like when the user has
    // not asked for less motion; nothing outside this file should read them
    // directly except to state an expectation about them.

    /// Fast easeInOut for immediate UI responses (tab switch, sidebar toggle, indicators).
    static let quickCurve: Animation = .easeInOut(duration: 0.2)

    /// Spring animation for overlays (Quick Open, Go to Line, branch switcher).
    static let overlayCurve: Animation = .spring(response: 0.3, dampingFraction: 0.9)

    /// Standard content transition for views that swap between states.
    static let contentCurve: Animation = .easeInOut(duration: 0.25)

    /// The only curve Pine plays while Reduce Motion is on: a short, plain
    /// cross-fade. Never a spring — a spring overshoots, and overshoot is
    /// movement.
    static let reducedCrossFade: Animation = .easeInOut(duration: 0.15)

    /// How far an overlay scales up from while it appears.
    static let overlayScale: CGFloat = 0.96

    // MARK: - Policy

    /// Applies Pine's Reduce Motion policy to a base curve.
    ///
    /// - Geometry becomes `nil`: SwiftUI applies the new state immediately.
    ///   A shorter or more damped spring is not an acceptable substitute —
    ///   it is still movement.
    /// - A cross-fade survives, de-sprung, because HIG asks for movement to be
    ///   replaced by a cross-fade rather than by a hard cut.
    static func resolve(
        _ base: Animation,
        intent: PineMotionIntent,
        reduceMotion: Bool
    ) -> Animation? {
        guard reduceMotion else { return base }
        switch intent {
        case .geometry:
            return nil
        case .crossFade:
            return reducedCrossFade
        }
    }

    // MARK: - Explicit-preference accessors

    // Preferred inside SwiftUI views, which can pass the environment value (or
    // a test override) instead of the ambient system reading.

    /// Quick transitions. Drives `scrollTo` and the sidebar column width, so it
    /// is classified as geometry.
    static func quick(reduceMotion: Bool) -> Animation? {
        resolve(quickCurve, intent: .geometry, reduceMotion: reduceMotion)
    }

    /// Overlay presentation. A spring, therefore geometry by construction.
    static func overlay(reduceMotion: Bool) -> Animation? {
        resolve(overlayCurve, intent: .geometry, reduceMotion: reduceMotion)
    }

    /// Content swaps. Only ever drives opacity in Pine, so it stays as a
    /// cross-fade under Reduce Motion.
    static func content(reduceMotion: Bool) -> Animation? {
        resolve(contentCurve, intent: .crossFade, reduceMotion: reduceMotion)
    }

    // MARK: - Ambient accessors

    // These keep every existing `PineAnimation.quick` call site correct without
    // asking it to remember the setting. `Animation?` is what both
    // `withAnimation(_:_:)` and `.animation(_:value:)` accept, so `nil` means
    // "apply now" at every one of them.

    /// Fast easeInOut for immediate UI responses, or no animation at all while
    /// Reduce Motion is on.
    static var quick: Animation? {
        quick(reduceMotion: PineMotionPreference.reduceMotion)
    }

    /// Spring animation for overlays, or no animation at all while Reduce
    /// Motion is on.
    static var overlay: Animation? {
        overlay(reduceMotion: PineMotionPreference.reduceMotion)
    }

    /// Standard content transition, degraded to a plain cross-fade while
    /// Reduce Motion is on.
    static var content: Animation? {
        content(reduceMotion: PineMotionPreference.reduceMotion)
    }

    // MARK: - Standard Transitions

    /// Opacity fade for appearing/disappearing content. Safe under Reduce
    /// Motion at any time: nothing moves.
    static let fadeTransition: AnyTransition = .opacity

    // MARK: - Overlay presentation

    /// The resolved description of how a command overlay appears.
    ///
    /// Modelled as an `Equatable` value rather than an `AnyTransition` (which
    /// cannot be compared) so a test can assert that the scale component is
    /// actually gone, and so the production transition below is built from the
    /// same decision the test inspects.
    struct OverlayPresentation: Equatable, Sendable {
        /// The cross-fade component. Always present — it is what replaces the
        /// scale under Reduce Motion.
        let usesOpacity: Bool
        /// The scale the overlay grows from, or `nil` when geometry is barred.
        let scale: CGFloat?
        /// The curve driving the presentation, or `nil` for an instant swap.
        let animation: Animation?

        /// `true` when the presentation still moves something on screen.
        var usesGeometry: Bool { scale != nil }

        static func resolve(reduceMotion: Bool) -> Self {
            Self(
                usesOpacity: true,
                scale: reduceMotion ? nil : PineAnimation.overlayScale,
                animation: PineAnimation.overlay(reduceMotion: reduceMotion)
            )
        }
    }

    /// Builds the SwiftUI transition described by `presentation`.
    static func overlayTransition(
        _ presentation: OverlayPresentation
    ) -> AnyTransition {
        guard let scale = presentation.scale else {
            return .opacity
        }
        return .opacity.combined(with: .scale(scale: scale))
    }
}
