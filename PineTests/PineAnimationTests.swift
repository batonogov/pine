//
//  PineAnimationTests.swift
//  PineTests
//
//  Tests for PineAnimation motion system constants.
//
//  The Reduce Motion policy these constants are resolved through lives in
//  `PineAnimationReduceMotionTests` (#1534).
//

import Foundation
import SwiftUI
import Testing

@testable import Pine

@Suite("PineAnimation Motion System")
@MainActor
struct PineAnimationTests {

    // MARK: - Base curves

    // These are the design tokens: what Pine plays when the user has not asked
    // for less motion. They are distinct from each other, so a call site that
    // picks the wrong one is observable.

    @Test("The base curves are three distinct animations")
    func baseCurvesAreDistinct() {
        let curves = [
            PineAnimation.quickCurve,
            PineAnimation.overlayCurve,
            PineAnimation.contentCurve,
            PineAnimation.reducedCrossFade,
        ]
        #expect(Set(curves).count == curves.count)
    }

    @Test("The overlay curve is the only spring")
    func overlayCurveIsTheSpring() {
        // A spring overshoots, which is why the Reduce Motion policy may never
        // fall back to this curve.
        #expect(PineAnimation.overlayCurve == .spring(response: 0.3, dampingFraction: 0.9))
        #expect(PineAnimation.quickCurve == .easeInOut(duration: 0.2))
        #expect(PineAnimation.contentCurve == .easeInOut(duration: 0.25))
        #expect(PineAnimation.reducedCrossFade == .easeInOut(duration: 0.15))
    }

    @Test("Fade transition is defined")
    func fadeTransitionExists() {
        let transition = PineAnimation.fadeTransition
        #expect(type(of: transition) == AnyTransition.self)
    }

}
