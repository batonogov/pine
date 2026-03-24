//
//  PineAnimationTests.swift
//  PineTests
//
//  Tests for PineAnimation motion system constants.
//

import Foundation
import SwiftUI
import Testing

@testable import Pine

@Suite("PineAnimation Motion System")
struct PineAnimationTests {

    // MARK: - Constants existence and values

    @Test("Quick animation is defined")
    func quickAnimationExists() {
        let animation = PineAnimation.quick
        #expect(type(of: animation) == Animation.self)
    }

    @Test("Quick duration is 0.2 seconds")
    func quickDurationValue() {
        #expect(PineAnimation.quickDuration == 0.2)
    }

    @Test("Overlay animation is defined")
    func overlayAnimationExists() {
        let animation = PineAnimation.overlay
        #expect(type(of: animation) == Animation.self)
    }

    @Test("Content animation is defined")
    func contentAnimationExists() {
        let animation = PineAnimation.content
        #expect(type(of: animation) == Animation.self)
    }

    @Test("Fade transition is defined")
    func fadeTransitionExists() {
        let transition = PineAnimation.fadeTransition
        #expect(type(of: transition) == AnyTransition.self)
    }

    @Test("Slide up transition is defined")
    func slideUpTransitionExists() {
        let transition = PineAnimation.slideUpTransition
        #expect(type(of: transition) == AnyTransition.self)
    }

    // MARK: - Consistency checks

    @Test("Quick duration matches quick animation semantics")
    func quickDurationIsPositive() {
        #expect(PineAnimation.quickDuration > 0)
        #expect(PineAnimation.quickDuration <= 0.3, "Quick animations should be under 300ms")
    }
}
