//
//  PaneDividerAccessibilityTests.swift
//  PineTests
//
//  Whether the pane divider can be moved without a mouse (#1533).
//
//  The divider always had a label and a hint that promised resizing. What it
//  did not have was a role that says "this is adjustable", a value that says
//  where it is, or an action that moves it — so VoiceOver read out a promise
//  and offered nothing to act on. Every assertion below therefore reads the
//  published accessibility tree and, where it can, drives the divider through
//  it: an action that is published but wired to nothing fails here.
//

import AppKit
import SwiftUI
import Testing

@testable import Pine

@Suite("Pane divider accessibility (#1533)", .serialized)
@MainActor
struct PaneDividerAccessibilityTests {

    private static let dividerSize = NSSize(width: 40, height: 200)

    // MARK: - What the tree publishes

    @Test("the divider publishes a splitter role, not an unnamed group")
    func dividerPublishesSplitterRole() throws {
        let harness = Harness(axis: .horizontal, ratio: 0.5)
        let hosted = harness.host()
        defer { hosted.tearDown() }

        let divider = try #require(
            AccessibilityTreeProbe.element(
                under: hosted.root,
                identifier: AccessibilityID.paneDivider
            ),
            "the divider is not in the published accessibility tree"
        )

        #expect(
            AccessibilityTreeProbe.role(of: divider) == .splitter,
            """
            the divider publishes \
            \(String(describing: AccessibilityTreeProbe.role(of: divider))) — \
            without AXSplitter, VoiceOver has no reason to offer the adjust \
            gesture that moves it
            """
        )
        #expect(
            AccessibilityTreeProbe.label(of: divider)
                == Strings.a11yPaneDividerLabel
        )
        #expect(
            AccessibilityTreeProbe.help(of: divider)
                == Strings.a11yPaneDividerHint
        )
    }

    /// A splitter between side-by-side panes is a vertical one. Getting this
    /// backwards makes VoiceOver describe the wrong drag direction.
    @Test("the divider's orientation follows the split axis")
    func dividerOrientationFollowsAxis() throws {
        let cases: [(SplitAxis, NSAccessibilityOrientation)] = [
            (.horizontal, .vertical),
            (.vertical, .horizontal),
        ]

        for (axis, expected) in cases {
            let harness = Harness(axis: axis, ratio: 0.5)
            let hosted = harness.host()
            defer { hosted.tearDown() }

            let divider = try #require(
                AccessibilityTreeProbe.element(
                    under: hosted.root,
                    identifier: AccessibilityID.paneDivider
                )
            )
            #expect(
                AccessibilityTreeProbe.orientation(of: divider) == expected,
                "a \(axis) split publishes the wrong divider orientation"
            )
        }
    }

    /// The value has to be the position, not a constant. Two hosts at two
    /// ratios; a hardcoded string passes neither.
    @Test("the divider publishes its position and that position tracks the ratio")
    func dividerPublishesItsPosition() throws {
        let quarter = Harness(axis: .horizontal, ratio: 0.25).host()
        defer { quarter.tearDown() }
        let threeQuarters = Harness(axis: .horizontal, ratio: 0.75).host()
        defer { threeQuarters.tearDown() }

        let quarterValue = try #require(
            dividerValue(in: quarter),
            "the divider publishes no value, so its position is unreadable"
        )
        let threeQuartersValue = try #require(dividerValue(in: threeQuarters))

        #expect(
            digits(in: quarterValue) == "25",
            "a divider at 0.25 announces \"\(quarterValue)\""
        )
        #expect(
            digits(in: threeQuartersValue) == "75",
            "a divider at 0.75 announces \"\(threeQuartersValue)\""
        )
    }

    // MARK: - Driving it through the tree

    /// The load-bearing test: perform the action VoiceOver performs, and
    /// require the pane tree to have actually moved.
    @Test("VoiceOver's increment and decrement move the divider")
    func incrementAndDecrementMoveTheDivider() throws {
        let harness = Harness(axis: .horizontal, ratio: 0.5)
        let hosted = harness.host()
        defer { hosted.tearDown() }

        let divider = try #require(
            AccessibilityTreeProbe.element(
                under: hosted.root,
                identifier: AccessibilityID.paneDivider
            )
        )

        let incremented = AccessibilityTreeProbe.performIncrement(divider)
        #expect(
            incremented == true,
            """
            the divider publishes no working increment — this is the whole \
            defect: a splitter VoiceOver can read but not move
            """
        )
        #expect(harness.adjustments == [0.55])

        let decremented = AccessibilityTreeProbe.performDecrement(divider)
        #expect(decremented == true)
        #expect(
            harness.adjustments == [0.55, 0.45],
            """
            decrement moved the divider to \(harness.adjustments) — each \
            adjustment is measured from the ratio the divider was given, so \
            a step applied to the wrong base shows up here
            """
        )
    }

    /// The bounds a drag is clamped to are the bounds an adjustment gets.
    /// Reporting `true` at the end of the range would have VoiceOver announce
    /// a move that never happened.
    @Test("the divider refuses to adjust past the range a drag can reach")
    func adjustmentStopsAtTheDragBounds() throws {
        let atMaximum = Harness(axis: .horizontal, ratio: 0.9)
        let maximumHost = atMaximum.host()
        defer { maximumHost.tearDown() }
        let maximumDivider = try #require(
            AccessibilityTreeProbe.element(
                under: maximumHost.root,
                identifier: AccessibilityID.paneDivider
            )
        )

        #expect(AccessibilityTreeProbe.performIncrement(maximumDivider) == false)
        #expect(atMaximum.adjustments.isEmpty)
        #expect(AccessibilityTreeProbe.performDecrement(maximumDivider) == true)
        #expect(atMaximum.adjustments == [0.85])

        let atMinimum = Harness(axis: .horizontal, ratio: 0.1)
        let minimumHost = atMinimum.host()
        defer { minimumHost.tearDown() }
        let minimumDivider = try #require(
            AccessibilityTreeProbe.element(
                under: minimumHost.root,
                identifier: AccessibilityID.paneDivider
            )
        )

        #expect(AccessibilityTreeProbe.performDecrement(minimumDivider) == false)
        #expect(atMinimum.adjustments.isEmpty)
    }

    /// A step from just inside the bound lands exactly on it rather than
    /// overshooting into a ratio a drag could never produce.
    @Test("an adjustment near a bound lands on the bound")
    func adjustmentClampsToTheBound() {
        var adjusted: [CGFloat] = []
        let view = PaneDividerAccessibilityView(frame: .zero)
        view.configure(
            configuration(axis: .horizontal, ratio: 0.88)
        ) { adjusted.append($0) }

        #expect(view.adjust(by: 0.05))
        #expect(adjusted == [0.9])
    }

    // MARK: - Full Keyboard Access

    /// Arrow keys along the split's axis move the divider; the perpendicular
    /// pair and any modified arrow belong to whoever had focus before.
    @Test("arrow keys along the split axis adjust, others fall through")
    func arrowKeysAdjustAlongTheAxis() throws {
        let leftArrow: UInt16 = 123
        let rightArrow: UInt16 = 124
        let upArrow: UInt16 = 126
        let downArrow: UInt16 = 125
        let step = PaneDividerAccessibilityConfiguration.step

        let horizontal: [(UInt16, CGFloat?)] = [
            (leftArrow, -step),
            (rightArrow, step),
            (upArrow, nil),
            (downArrow, nil),
        ]
        for (keyCode, expected) in horizontal {
            #expect(
                PaneDividerAccessibilityView.adjustment(
                    forKeyCode: keyCode,
                    axis: .horizontal,
                    modifiers: []
                ) == expected,
                "key \(keyCode) on a horizontal split"
            )
        }

        let vertical: [(UInt16, CGFloat?)] = [
            (upArrow, -step),
            (downArrow, step),
            (leftArrow, nil),
            (rightArrow, nil),
        ]
        for (keyCode, expected) in vertical {
            #expect(
                PaneDividerAccessibilityView.adjustment(
                    forKeyCode: keyCode,
                    axis: .vertical,
                    modifiers: []
                ) == expected,
                "key \(keyCode) on a vertical split"
            )
        }

        for modifier: NSEvent.ModifierFlags in [
            .command, .option, .control, .shift,
        ] {
            #expect(
                PaneDividerAccessibilityView.adjustment(
                    forKeyCode: rightArrow,
                    axis: .horizontal,
                    modifiers: modifier
                ) == nil,
                "a modified arrow must stay with the previous responder"
            )
        }
    }

    /// A physical key press has to reach the same adjustment, not just the
    /// classifier: `keyDown` routing is what a Full Keyboard Access user hits.
    @Test("a physical arrow key press moves the divider")
    func physicalArrowKeyMovesTheDivider() throws {
        var adjusted: [CGFloat] = []
        let view = PaneDividerAccessibilityView(frame: .zero)
        view.configure(
            configuration(axis: .horizontal, ratio: 0.5)
        ) { adjusted.append($0) }

        view.keyDown(with: try keyEvent(keyCode: 124))
        #expect(adjusted == [0.55])

        view.keyDown(with: try keyEvent(keyCode: 123))
        #expect(adjusted == [0.55, 0.45])
    }

    /// The divider joins the key view loop only under Full Keyboard Access.
    /// Always accepting focus would put a stop between two panes of text for
    /// every user who never asked for one.
    @Test("the divider takes keyboard focus only under Full Keyboard Access")
    func focusFollowsFullKeyboardAccess() {
        let view = PaneDividerAccessibilityView(frame: .zero)

        view.isFullKeyboardAccessEnabled = { false }
        #expect(!view.acceptsFirstResponder)
        #expect(!view.canBecomeKeyView)

        view.isFullKeyboardAccessEnabled = { true }
        #expect(view.acceptsFirstResponder)
        #expect(view.canBecomeKeyView)
    }

    // MARK: - Pointer input is untouched

    @Test("the accessibility element never takes a mouse event")
    func accessibilityElementDoesNotHitTest() {
        let view = PaneDividerAccessibilityView(
            frame: NSRect(x: 0, y: 0, width: 8, height: 200)
        )

        #expect(view.hitTest(NSPoint(x: 4, y: 100)) == nil)
    }

    // MARK: - Helpers

    private func configuration(
        axis: SplitAxis,
        ratio: CGFloat
    ) -> PaneDividerAccessibilityConfiguration {
        PaneDividerAccessibilityConfiguration(
            axis: axis,
            ratio: ratio,
            label: Strings.a11yPaneDividerLabel,
            help: Strings.a11yPaneDividerHint,
            identifier: AccessibilityID.paneDivider
        )
    }

    private func dividerValue(
        in hosted: AccessibilityTreeProbe.Hosted
    ) -> String? {
        AccessibilityTreeProbe.element(
            under: hosted.root,
            identifier: AccessibilityID.paneDivider
        ).flatMap(AccessibilityTreeProbe.value(of:))
    }

    /// The digits in a locale-formatted percentage, so the assertion survives
    /// a runner whose locale writes "25 %" or "％".
    private func digits(in text: String) -> String {
        String(text.filter(\.isNumber))
    }

    private func keyEvent(keyCode: UInt16) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: keyCode
        ))
    }

    /// Hosts the real `PaneDividerView` and records what it asks the pane
    /// tree to do. Recording the ratio rather than a bare call count is what
    /// makes a step applied to the wrong base visible.
    @MainActor
    private final class Harness {
        private(set) var adjustments: [CGFloat] = []
        private let axis: SplitAxis
        private let ratio: CGFloat

        init(axis: SplitAxis, ratio: CGFloat) {
            self.axis = axis
            self.ratio = ratio
        }

        func host() -> AccessibilityTreeProbe.Hosted {
            AccessibilityTreeProbe.host(
                PaneDividerView(
                    axis: axis,
                    ratio: ratio,
                    onDrag: { _ in },
                    onDragEnd: {},
                    onAdjustRatio: { [weak self] in
                        self?.adjustments.append(
                            (($0 * 100).rounded() / 100)
                        )
                    }
                ),
                size: PaneDividerAccessibilityTests.dividerSize
            )
        }
    }
}
