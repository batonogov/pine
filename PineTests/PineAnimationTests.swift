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

}
