//
//  UITimings.swift
//  Pine
//
//  Centralised, named constants for UI delays, debounces, and render
//  cadences. Replaces scattered magic-number `TimeInterval` literals
//  (`.now() + 0.3`, `.milliseconds(300)`, `Task.sleep(for: .seconds(0.5))`,
//  …) with intent-tagged identifiers so the call site says *why* a delay
//  exists, not just *how long* it lasts.
//
//  Conventions:
//  - Values are `TimeInterval` (seconds). `Duration` call-sites convert
//    via `.seconds(UITimings.…)` so we keep one source of truth.
//  - Doc comments describe *intent* (why this delay exists), not the
//    numeric value — the constant declaration shows the value once and
//    is the only place to tune it.
//  - 120 Hz ProMotion targets <4 ms of main-thread work per scroll
//    frame; render-side cadences are tuned with that ceiling in mind.
//
//  Out of scope: SwiftUI `.animation()` durations, XCUITest timeouts,
//  business-logic `Task.sleep` (e.g. periodic snapshots) — those have
//  their own ergonomics and live with the code that owns them.
//

import Foundation

/// Typed namespace for UI-facing delays, debounces, and render cadences.
///
/// Marked `nonisolated` so the compile-time constants can be referenced
/// from `nonisolated` static properties (e.g. `ProjectSearchProvider.
/// debounceInterval`) under Pine's project-wide
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` setting. The whole enum
/// is pure constant data, so isolation never matters at runtime — but
/// without `nonisolated` Swift 6 inherits MainActor isolation and
/// rejects the cross-context reference.
nonisolated enum UITimings {

    /// One-shot delays before performing a UI action. Used when SwiftUI's
    /// own lifecycle hooks fire too early and we need AppKit / the run
    /// loop to catch up — e.g. a window has been requested but isn't yet
    /// installed in the hierarchy.
    enum Delay {
        /// Tiny pause to let SwiftUI process the previous tick before we
        /// verify state via AppKit (e.g. confirming a window appeared
        /// after `openWindow(id:)`). Short enough to feel instantaneous.
        static let short: TimeInterval = 0.15

        /// Standard "let the UI sync" pause used after asynchronous
        /// transitions: drop-to-open project, sheet → search-bar
        /// configuration, post-action menu shows. Long enough that
        /// SwiftUI has settled, short enough that users perceive it as
        /// part of the originating action.
        static let standard: TimeInterval = 0.3

        /// AppKit fallback window for paths where SwiftUI may silently
        /// skip window creation (macOS 26 + LaunchServices bypass — see
        /// `createWelcomeWindowViaAppKit`). Long enough that a real
        /// SwiftUI window has had time to appear before we force-create
        /// one, short enough that users on the slow path don't sit
        /// staring at an empty screen.
        static let long: TimeInterval = 0.5
    }

    /// Debounce intervals for trailing-edge work that's expensive to run
    /// per-event (regex highlighting, fold recalculation, project-wide
    /// search, FSEvents fan-out, validators).
    enum Debounce {
        /// Syntax highlight on scroll. Roughly three frames at 120 Hz —
        /// fast enough to feel instant on ProMotion, slow enough to
        /// coalesce a flick of scroll-wheel events into one regex pass.
        /// Stays under the 4 ms-per-frame budget on the main thread.
        static let scroll: TimeInterval = 0.05

        /// Syntax highlight on text edit. Coalesces fast typing into a
        /// single regex pass; long enough that every keystroke doesn't
        /// trigger a full repaint, short enough that highlight catches
        /// up before the user finishes a token.
        static let edit: TimeInterval = 0.1

        /// Fold-range recalculation. Heavier than highlighting (full
        /// bracket-matching scan with comment/string skip ranges), so
        /// it's debounced longer than `edit` to avoid stalling typing.
        static let foldRecalc: TimeInterval = 0.15

        /// FSEvents debounce for the workspace file watcher. Short
        /// enough that changes made in the built-in terminal show up in
        /// the sidebar almost immediately, long enough to coalesce
        /// bursts (npm install, git checkout) into a handful of
        /// refreshes. See WorkspaceManager#839.
        static let fileWatcher: TimeInterval = 0.15

        /// Project-wide search debounce — full-tree text scan with
        /// `.gitignore` filtering. Tuned so a fast typist sees results
        /// once they pause, not once per keystroke.
        static let projectSearch: TimeInterval = 0.3

        /// Config validator (yamllint / shellcheck / hadolint /
        /// terraform validate) debounce. Validators spawn external
        /// processes and write a temp file; this delay prevents
        /// per-keystroke fork+exec while keeping diagnostics current
        /// during a brief typing pause.
        static let configValidation: TimeInterval = 0.3
    }

    /// Render-side cadences — throttling for views that redraw on every
    /// scroll/edit notification. These are *upper bounds* on redraw
    /// frequency, not delays before a single action.
    enum Render {
        /// Minimap redraw throttle (~3 frames at 120 Hz ProMotion). Each
        /// minimap repaint enumerates layout-manager line fragments and
        /// re-walks per-glyph foreground colors, so it must stay under
        /// the per-frame budget; trailing redraws coalesce via a
        /// scheduled work item to capture the final scroll position.
        static let minimapRedraw: TimeInterval = 0.025
    }
}
