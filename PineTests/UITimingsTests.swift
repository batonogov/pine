//
//  UITimingsTests.swift
//  PineTests
//
//  Guards the centralised UI timings namespace from accidental drift.
//  These constants are referenced from many call-sites, and a silent
//  numeric change here would alter user-facing latency / debounce
//  behavior across the editor. The tests are deliberately strict:
//  pinning exact values, ordering relationships, and physical sanity
//  bounds.
//

import Foundation
import Testing
@testable import Pine

struct UITimingsTests {

    // MARK: - Exact values

    /// `Delay.short` pins the SwiftUI-tick acknowledgement window. If
    /// this drifts, every "verify a window exists" check after
    /// `openWindow(id:)` will fire either too soon (no window yet) or
    /// too late (perceived UI lag).
    @Test func delayShortIsExactly150ms() {
        #expect(UITimings.Delay.short == 0.15)
    }

    /// `Delay.standard` is the canonical "let SwiftUI breathe" value
    /// shared by drop-handler post-open, branch menu install, search
    /// toolbar configure, toast hand-off, markdown preview render.
    /// Unifying them is the whole point of this namespace — a value
    /// change here moves all of them.
    @Test func delayStandardIsExactly300ms() {
        #expect(UITimings.Delay.standard == 0.3)
    }

    /// `Delay.long` is the AppKit-fallback window for macOS 26 launches
    /// that bypass LaunchServices (XCUITest / direct binary). Too short
    /// and the SwiftUI window doesn't get a chance to appear before we
    /// force-create one; too long and slow-path users sit on a blank
    /// screen.
    @Test func delayLongIsExactly500ms() {
        #expect(UITimings.Delay.long == 0.5)
    }

    /// Scroll-debounce is calibrated to ~3 frames at 120 Hz ProMotion.
    @Test func debounceScrollIsExactly50ms() {
        #expect(UITimings.Debounce.scroll == 0.05)
    }

    @Test func debounceEditIsExactly100ms() {
        #expect(UITimings.Debounce.edit == 0.1)
    }

    @Test func debounceFoldRecalcIsExactly150ms() {
        #expect(UITimings.Debounce.foldRecalc == 0.15)
    }

    @Test func debounceFileWatcherIsExactly150ms() {
        #expect(UITimings.Debounce.fileWatcher == 0.15)
    }

    @Test func debounceProjectSearchIsExactly300ms() {
        #expect(UITimings.Debounce.projectSearch == 0.3)
    }

    @Test func debounceConfigValidationIsExactly300ms() {
        #expect(UITimings.Debounce.configValidation == 0.3)
    }

    @Test func renderMinimapRedrawIsExactly25ms() {
        #expect(UITimings.Render.minimapRedraw == 0.025)
    }

    // MARK: - Ordering invariants

    /// Render cadence must be at least as tight as the edit-debounce —
    /// otherwise the minimap would lag the syntax highlighter that
    /// drives its colors, briefly showing stale colors after each
    /// keystroke. Documents the contract in code so a casual tune of
    /// either constant can't violate it silently.
    @Test func renderMinimapRedrawIsTighterThanEditDebounce() {
        #expect(UITimings.Render.minimapRedraw <= UITimings.Debounce.edit)
    }

    /// Scroll highlighting fires faster than edit highlighting. Edits
    /// finish on key release; scrolls happen continuously and need a
    /// tighter loop to feel native.
    @Test func scrollDebounceIsTighterThanEditDebounce() {
        #expect(UITimings.Debounce.scroll < UITimings.Debounce.edit)
    }

    /// Fold recalculation is heavier than syntax highlighting (full
    /// bracket-matching + comment/string skip ranges) and is therefore
    /// debounced longer, never shorter, than `edit`.
    @Test func foldRecalcDebounceIsAtLeastEditDebounce() {
        #expect(UITimings.Debounce.foldRecalc >= UITimings.Debounce.edit)
    }

    /// Project-wide search fires far less often than per-tab edit
    /// highlighting — it walks the entire file tree and reads every
    /// matching file. Must outpace `edit` by a real margin.
    @Test func projectSearchDebounceIsLongerThanEditDebounce() {
        #expect(UITimings.Debounce.projectSearch > UITimings.Debounce.edit)
    }

    /// Delay tier ordering: short < standard < long. If anyone "tunes"
    /// these without checking, they'd silently invert the meaning.
    @Test func delayTiersAreInAscendingOrder() {
        #expect(UITimings.Delay.short < UITimings.Delay.standard)
        #expect(UITimings.Delay.standard < UITimings.Delay.long)
    }

    /// Render cadence must be the smallest constant in the namespace —
    /// it's a per-frame throttle, not a debounce. Sanity-check it
    /// against the entire namespace so a future addition doesn't slot
    /// in below.
    @Test func renderMinimapRedrawIsSmallestConstant() {
        let allDebounces = [
            UITimings.Debounce.scroll,
            UITimings.Debounce.edit,
            UITimings.Debounce.foldRecalc,
            UITimings.Debounce.fileWatcher,
            UITimings.Debounce.projectSearch,
            UITimings.Debounce.configValidation
        ]
        let allDelays = [
            UITimings.Delay.short,
            UITimings.Delay.standard,
            UITimings.Delay.long
        ]
        for value in allDebounces + allDelays {
            #expect(UITimings.Render.minimapRedraw <= value)
        }
    }

    // MARK: - Physical sanity bounds

    /// Every UI timing must be strictly positive. A zero or negative
    /// value would either skip the debounce entirely (lock-up risk in
    /// debounced computations) or, for `asyncAfter`, still fire but
    /// hide the bug from review.
    @Test func allTimingsArePositive() {
        let everything: [TimeInterval] = [
            UITimings.Delay.short,
            UITimings.Delay.standard,
            UITimings.Delay.long,
            UITimings.Debounce.scroll,
            UITimings.Debounce.edit,
            UITimings.Debounce.foldRecalc,
            UITimings.Debounce.fileWatcher,
            UITimings.Debounce.projectSearch,
            UITimings.Debounce.configValidation,
            UITimings.Render.minimapRedraw
        ]
        for value in everything {
            #expect(value > 0)
        }
    }

    /// No UI timing should exceed one second. Any longer and the user
    /// would notice the lag and file a bug — meaning the constant is
    /// in the wrong category and probably belongs to a different
    /// system (recovery snapshot interval, CLI watchdog, etc.).
    @Test func allTimingsAreUnderOneSecond() {
        let everything: [TimeInterval] = [
            UITimings.Delay.short,
            UITimings.Delay.standard,
            UITimings.Delay.long,
            UITimings.Debounce.scroll,
            UITimings.Debounce.edit,
            UITimings.Debounce.foldRecalc,
            UITimings.Debounce.fileWatcher,
            UITimings.Debounce.projectSearch,
            UITimings.Debounce.configValidation,
            UITimings.Render.minimapRedraw
        ]
        for value in everything {
            #expect(value <= 1.0)
        }
    }

    // MARK: - Duration bridging

    /// `Task.sleep(for:)` accepts `Duration`. Confirm that
    /// `.seconds(UITimings.…)` round-trips to the expected millisecond
    /// quantity — guards against a future Swift change to `Duration`'s
    /// conversion of `Double` seconds.
    @Test func projectSearchDurationRoundsTripToMilliseconds() {
        let asSeconds: Duration = .seconds(UITimings.Debounce.projectSearch)
        let asMilliseconds: Duration = .milliseconds(300)
        #expect(asSeconds == asMilliseconds)
    }

    @Test func delayLongDurationRoundsTripToMilliseconds() {
        let asSeconds: Duration = .seconds(UITimings.Delay.long)
        let asMilliseconds: Duration = .milliseconds(500)
        #expect(asSeconds == asMilliseconds)
    }
}
