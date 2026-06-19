//
//  TerminalScrollEventInfo.swift
//  Pine
//
//  Pure resolution of a scroll-wheel event's scalar properties into the
//  values the terminal scroll path consumes.
//
//  Extracted from `TerminalContainerView.installScrollMonitor`
//  (TerminalSession.swift) so three pieces of pure logic can be unit-tested
//  without constructing live NSEvents:
//    1. delta selection — `scrollingDeltaY` for trackpad (precise),
//       `deltaY` for a physical mouse wheel;
//    2. gesture/momentum phase-boundary detection (`.began` / `.ended` live
//       in either `phase` or `momentumPhase`);
//    3. the "should this event reach the per-branch scroll logic" decision
//       (events with zero delta and no phase boundary are inert and dropped).
//
//  Behaviour is identical to the previously inlined implementation — the
//  call site now constructs this struct and consults `shouldIntercept`.
//

import AppKit

/// Resolved, AppKit-free view of the scroll properties a terminal scroll
/// event carries.
///
/// The terminal scroll monitor (`TerminalContainerView.installScrollMonitor`)
/// builds this once per intercepted `scrollWheel` event and feeds its fields
/// into the shared `MouseScrollForwarder` accumulators.
///
/// Marked `nonisolated` so it is directly unit-testable from any isolation
/// context and stays a plain `Sendable` value crossing the main-thread scroll
/// monitor closure.
nonisolated struct TerminalScrollEventInfo {

    /// Resolved scroll delta. Positive scrolls up, negative scrolls down.
    /// `scrollingDeltaY` for trackpad input (precise), `deltaY` for a physical
    /// mouse wheel.
    let delta: CGFloat

    /// `true` when the gesture or momentum phase is `.began`. The per-branch
    /// accumulators use this to reset stale residual delta from a previous
    /// gesture.
    let phaseBegan: Bool

    /// `true` when the gesture or momentum phase is `.ended`. The per-branch
    /// logic uses this to flush residual delta above the settle threshold so
    /// the final partial line is committed rather than dropped.
    let phaseEnded: Bool

    /// Whether the event comes from a trackpad (`hasPreciseScrollingDeltas`).
    /// Selects the accumulator branch in `MouseScrollForwarder`.
    let isPrecise: Bool

    /// Whether the event must reach the per-branch scroll logic.
    ///
    /// Trackpad gesture/momentum phase boundaries (`.began` / `.ended`)
    /// frequently carry a zero scrolling delta but still must reach the
    /// per-branch logic: `.began` resets the active accumulator and `.ended`
    /// flushes residual delta. Non-phase events with zero delta (e.g. inert
    /// ticks) are dropped.
    var shouldIntercept: Bool { delta != 0 || phaseBegan || phaseEnded }

    /// Resolves the scroll properties of an `NSEvent` of type `scrollWheel`.
    init(event: NSEvent) {
        self.isPrecise = event.hasPreciseScrollingDeltas
        self.delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY
        self.phaseBegan = event.phase == .began || event.momentumPhase == .began
        self.phaseEnded = event.phase == .ended || event.momentumPhase == .ended
    }

    /// Scalar initializer for direct unit-testing without constructing NSEvents.
    init(delta: CGFloat, phaseBegan: Bool, phaseEnded: Bool, isPrecise: Bool) {
        self.delta = delta
        self.phaseBegan = phaseBegan
        self.phaseEnded = phaseEnded
        self.isPrecise = isPrecise
    }
}
