//
//  PineAnimationReduceMotionTests.swift
//  PineTests
//
//  Issue #1534: `PineAnimation` used to be a plain constant table, so honouring
//  Reduce Motion was optional at every call site and most call sites skipped it.
//  These tests pin the centralised policy: what the helper hands to SwiftUI must
//  differ by motion preference, not merely be "available" to a caller who
//  remembers to ask.
//

import AppKit
import SwiftUI
import Testing

@testable import Pine

@Suite("PineAnimation Reduce Motion policy", .serialized)
@MainActor
struct PineAnimationReduceMotionTests {

    // MARK: - Policy: geometry

    /// Every base curve the app ships. Declared as a property rather than as
    /// `@Test(arguments:)` because the attribute expression is evaluated
    /// outside the suite's main-actor isolation.
    private var baseCurves: [Animation] {
        [
            PineAnimation.quickCurve,
            PineAnimation.overlayCurve,
            PineAnimation.contentCurve,
        ]
    }

    @Test("Geometry motion resolves to no animation under Reduce Motion")
    func geometryIsSuppressed() {
        for curve in baseCurves {
            #expect(
                PineAnimation.resolve(
                    curve,
                    intent: .geometry,
                    reduceMotion: true
                ) == nil
            )
        }
    }

    @Test("A suppressed geometry animation is instant, not merely shorter")
    func geometryIsInstantNotDamped() {
        let resolved = PineAnimation.resolve(
            PineAnimation.overlayCurve,
            intent: .geometry,
            reduceMotion: true
        )
        // `nil` is the only value SwiftUI treats as "apply the new state now".
        // Any non-nil animation — however short or however damped — still plays
        // the spring's overshoot, which is exactly what a vestibular disorder
        // reacts to.
        #expect(resolved == nil)
        #expect(resolved != PineAnimation.reducedCrossFade)
        #expect(resolved != PineAnimation.overlayCurve)
    }

    // MARK: - Policy: cross-fade

    @Test("Cross-fades survive Reduce Motion as a plain curve")
    func crossFadeSurvivesAsPlainCurve() {
        let resolved = PineAnimation.resolve(
            PineAnimation.contentCurve,
            intent: .crossFade,
            reduceMotion: true
        )
        // HIG: replace movement with a cross-fade rather than a hard cut.
        #expect(resolved != nil)
        #expect(resolved == PineAnimation.reducedCrossFade)
        // ...but never with the spring, which overshoots.
        #expect(resolved != PineAnimation.overlayCurve)
    }

    // MARK: - Policy: motion allowed

    @Test("Reduce Motion off returns the base curve untouched")
    func basePreservedWhenMotionAllowed() {
        for curve in baseCurves {
            #expect(
                PineAnimation.resolve(
                    curve,
                    intent: .geometry,
                    reduceMotion: false
                ) == curve
            )
            #expect(
                PineAnimation.resolve(
                    curve,
                    intent: .crossFade,
                    reduceMotion: false
                ) == curve
            )
        }
    }

    // MARK: - Explicit-preference accessors

    @Test("Explicit accessors carry the same policy as resolve")
    func explicitAccessorsMatchPolicy() {
        #expect(PineAnimation.quick(reduceMotion: true) == nil)
        #expect(PineAnimation.overlay(reduceMotion: true) == nil)
        #expect(
            PineAnimation.content(reduceMotion: true)
                == PineAnimation.reducedCrossFade
        )

        #expect(
            PineAnimation.quick(reduceMotion: false)
                == PineAnimation.quickCurve
        )
        #expect(
            PineAnimation.overlay(reduceMotion: false)
                == PineAnimation.overlayCurve
        )
        #expect(
            PineAnimation.content(reduceMotion: false)
                == PineAnimation.contentCurve
        )
    }

    // MARK: - Ambient accessors (the 31 existing call sites)

    @Test("Ambient accessors go instant under Reduce Motion")
    func ambientAccessorsRespectPreference() {
        PineMotionPreference.withOverride(true) {
            #expect(PineAnimation.quick == nil)
            #expect(PineAnimation.overlay == nil)
            #expect(PineAnimation.content == PineAnimation.reducedCrossFade)
        }

        PineMotionPreference.withOverride(false) {
            #expect(PineAnimation.quick == PineAnimation.quickCurve)
            #expect(PineAnimation.overlay == PineAnimation.overlayCurve)
            #expect(PineAnimation.content == PineAnimation.contentCurve)
        }
    }

    @Test("The ambient preference returns whatever its source says")
    func ambientPreferenceTracksItsSource() {
        // The value must come from the source, not from a hard-coded default.
        // Asserting both directions is what makes this non-tautological on a
        // machine whose own Reduce Motion is off.
        PineMotionPreference.withSource({ true }, perform: {
            #expect(PineMotionPreference.reduceMotion)
        })
        PineMotionPreference.withSource({ false }, perform: {
            #expect(!PineMotionPreference.reduceMotion)
        })
    }

    @Test("The preference is re-read on every access, never cached")
    func ambientPreferenceIsNotCached() {
        let counter = CallCounter()
        PineMotionPreference.withSource({ counter.next() }, perform: {
            // Someone who flips the setting mid-session must not have to
            // relaunch Pine to be believed.
            #expect(PineAnimation.quick == nil)
            #expect(PineAnimation.quick == PineAnimation.quickCurve)
            #expect(PineAnimation.quick == nil)
        })
        #expect(counter.count == 3)
    }

    @Test("The default source is the live system setting")
    func defaultSourceIsTheSystem() {
        // Deliberately weak: on a machine (or CI runner) with Reduce Motion
        // off, every wrong answer is also `false`. Its only job is to catch a
        // hard-coded default; the two tests above carry the real weight.
        #expect(
            PineMotionPreference.systemSource()
                == NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
        #expect(
            PineMotionPreference.reduceMotion
                == NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
    }

    /// Counts how often the motion source is consulted, and alternates its
    /// answer so a cached read is visible as a wrong animation rather than
    /// only as a wrong call count.
    private final class CallCounter {
        private(set) var count = 0

        func next() -> Bool {
            count += 1
            return count.isMultiple(of: 2) == false
        }
    }

    @Test("A scoped override never leaks past its body")
    func overrideIsScoped() {
        let ambient = PineMotionPreference.reduceMotion
        PineMotionPreference.withOverride(!ambient) {
            #expect(PineMotionPreference.reduceMotion == !ambient)
            PineMotionPreference.withOverride(ambient) {
                #expect(PineMotionPreference.reduceMotion == ambient)
            }
            #expect(PineMotionPreference.reduceMotion == !ambient)
        }
        #expect(PineMotionPreference.reduceMotion == ambient)
    }

    @Test("A throwing body still restores the previous override")
    func overrideRestoredOnThrow() {
        struct Boom: Error {}
        let ambient = PineMotionPreference.reduceMotion
        #expect(throws: Boom.self) {
            try PineMotionPreference.withOverride(!ambient) {
                throw Boom()
            }
        }
        #expect(PineMotionPreference.reduceMotion == ambient)
    }

    // MARK: - The `.center` sidebar policy must be untouched

    @Test("Sidebar keyboard navigation is still unanimated and nearest-edge")
    func sidebarKeyboardPolicyUnchanged() {
        let request = SidebarScrollRequest.keyboardSelection(
            URL(fileURLWithPath: "/tmp/a.swift")
        )
        #expect(request.alignment == .nearestEdge)
        #expect(request.motion == .immediate)
    }

    @Test(
        "Intentional reveal keeps .center and becomes immediate under Reduce Motion",
        arguments: [false, true]
    )
    func sidebarRevealPolicyUnchanged(_ reduceMotion: Bool) {
        let request = SidebarScrollRequest.intentionalReveal(
            URL(fileURLWithPath: "/tmp/a.swift"),
            reduceMotion: reduceMotion
        )
        #expect(request.alignment == .center)
        #expect(request.motion == (reduceMotion ? .immediate : .animated))
    }
}
