//
//  WindowRoutingReachTests.swift
//  PineTests
//
//  The reach rule that decides whether a window in the Dock may receive
//  routed work (#1507).
//

import Foundation
import Testing

@testable import Pine

@Suite("Window routing reach")
struct WindowRoutingReachTests {
    /// Every combination of the two AppKit flags, for both reaches. The rule
    /// is four lines long, so an exhaustive table is cheaper than choosing
    /// which cases matter — and it is the table that documents the decision
    /// #1507 had to make.
    @Test(
        "each pair of AppKit facts admits exactly the intended windows",
        arguments: [
            // On screen: every caller may route here.
            (true, false, true, true),
            // In the Dock: only a caller that restores its host first.
            (false, true, false, true),
            // Ordered out, closed, or never shown: nobody may route here.
            (false, false, false, false),
            // AppKit never reports this pair; both reaches read it as
            // "not on screen" rather than trusting one flag over the other.
            (true, true, false, true),
        ]
    )
    func admissionTable(
        isVisible: Bool,
        isMiniaturized: Bool,
        onScreenOnlyAdmits: Bool,
        onScreenOrDockAdmits: Bool
    ) {
        #expect(
            WindowRoutingReach.onScreenOnly.admitsWindow(
                isVisible: isVisible,
                isMiniaturized: isMiniaturized
            ) == onScreenOnlyAdmits
        )
        #expect(
            WindowRoutingReach.onScreenOrDock.admitsWindow(
                isVisible: isVisible,
                isMiniaturized: isMiniaturized
            ) == onScreenOrDockAdmits
        )
    }

    /// The regression #1507 is about: the Inbox reach must not depend on
    /// `isVisible` being `true` for a window in the Dock, because measured on
    /// macOS 27.0 (26A5416b) it is `false`.
    @Test("a window in the Dock is reachable without being visible")
    func dockWindowIsReachable() {
        #expect(
            WindowRoutingReach.onScreenOrDock.admitsWindow(
                isVisible: false,
                isMiniaturized: true
            )
        )
    }

    /// The other half of that fix: widening the reach must not turn a closed
    /// or hidden window into a destination. Both flags are `false` for an
    /// ordered-out window, which is exactly the shape a weakened check would
    /// let through.
    @Test("widening the reach never admits an ordered-out window")
    func widerReachStillRefusesHiddenWindows() {
        #expect(
            !WindowRoutingReach.onScreenOrDock.admitsWindow(
                isVisible: false,
                isMiniaturized: false
            )
        )
    }

    /// In-place command paths — New File, Close Tab — keep the narrow reach,
    /// so the deliberate divergence between them and the Inbox is asserted
    /// rather than left to a comment.
    @Test("the two reaches disagree only about a window in the Dock")
    func reachesDivergeOnlyInTheDock() {
        let facts = [(true, false), (false, true), (false, false), (true, true)]
        let divergent = facts.filter { isVisible, isMiniaturized in
            WindowRoutingReach.onScreenOnly.admitsWindow(
                isVisible: isVisible,
                isMiniaturized: isMiniaturized
            ) != WindowRoutingReach.onScreenOrDock.admitsWindow(
                isVisible: isVisible,
                isMiniaturized: isMiniaturized
            )
        }

        #expect(divergent.allSatisfy { $0.1 })
        #expect(divergent.count == 2)
    }
}
