//
//  PaneDividerAccessibility.swift
//  Pine
//
//  Native splitter semantics for the SwiftUI pane divider (#1533).
//
//  The divider promised resizing in its accessibility hint and delivered a
//  drag gesture, which is the one input a VoiceOver or Full Keyboard Access
//  user does not have. SwiftUI has no splitter role and no way to publish a
//  position: `.accessibilityValue` is dropped outright on an element whose
//  bridged role is `AXUnknown`, which is what a bare `.accessibilityElement()`
//  produces. So the semantics live on a real `NSView`, the same shape the
//  sidebar already uses in `SidebarAccessibilityRow` — AppKit publishes
//  `AXSplitter`, the position, and increment/decrement, and VoiceOver's
//  standard adjust gesture reaches the pane tree.
//

import AppKit
import SwiftUI

/// Everything the divider publishes about itself.
struct PaneDividerAccessibilityConfiguration: Equatable {
    /// Orientation of the split, not of the divider: `.horizontal` puts the
    /// panes side by side and draws a vertical divider between them.
    let axis: SplitAxis
    /// Fraction of the split occupied by the leading pane.
    let ratio: CGFloat
    let label: String
    let help: String
    let identifier: String

    /// One increment. Matches the granularity a user can hit by dragging
    /// without making the divider tedious to walk from end to end.
    static let step: CGFloat = 0.05
    /// The same bounds `PaneNode` clamps a dragged ratio to, so an adjusted
    /// divider can never reach a position a dragged one could not.
    static let minimumRatio: CGFloat = 0.1
    static let maximumRatio: CGFloat = 0.9

    static func clamp(_ ratio: CGFloat) -> CGFloat {
        min(max(ratio, minimumRatio), maximumRatio)
    }

    /// The position VoiceOver reads, as a locale-formatted percentage of the
    /// leading pane.
    var accessibilityValue: String {
        Self.percentage(Self.clamp(ratio))
    }

    static func percentage(_ ratio: CGFloat) -> String {
        Double(ratio).formatted(.percent.precision(.fractionLength(0)))
    }

    /// The AppKit orientation of the divider itself.
    var orientation: NSAccessibilityOrientation {
        axis == .horizontal ? .vertical : .horizontal
    }
}

/// The divider as VoiceOver and Full Keyboard Access see it.
///
/// Pointer input stays with the SwiftUI gesture underneath — `hitTest` returns
/// `nil` — so this view adds semantics without taking a single mouse event.
@MainActor
final class PaneDividerAccessibilityView: NSView {
    private(set) var configuration: PaneDividerAccessibilityConfiguration?
    private var onAdjust: ((CGFloat) -> Void)?

    /// Injectable so a test never depends on the developer's own Full
    /// Keyboard Access setting, and so CI does not decide the result.
    var isFullKeyboardAccessEnabled: () -> Bool = {
        NSApp?.isFullKeyboardAccessEnabled ?? false
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    // MARK: - Keyboard

    /// Only joins the key view loop when the user has asked every control to
    /// be reachable by Tab. Outside Full Keyboard Access a divider in the
    /// loop would be a stop nobody asked for, between panes of text.
    override var acceptsFirstResponder: Bool {
        isFullKeyboardAccessEnabled()
    }

    override var canBecomeKeyView: Bool {
        acceptsFirstResponder
    }

    override var focusRingMaskBounds: NSRect {
        bounds
    }

    override func drawFocusRingMask() {
        bounds.fill()
    }

    override func keyDown(with event: NSEvent) {
        guard let steps = Self.adjustment(
            forKeyCode: event.keyCode,
            axis: configuration?.axis,
            modifiers: event.modifierFlags
        ) else {
            super.keyDown(with: event)
            return
        }
        if !adjust(by: steps) {
            NSSound.beep()
        }
    }

    /// Arrow keys along the split's own axis move the divider; anything else
    /// belongs to whatever the user was doing before they tabbed here.
    static func adjustment(
        forKeyCode keyCode: UInt16,
        axis: SplitAxis?,
        modifiers: NSEvent.ModifierFlags
    ) -> CGFloat? {
        guard let axis else { return nil }
        let interesting: NSEvent.ModifierFlags = [
            .command, .option, .control, .shift,
        ]
        guard modifiers.isDisjoint(with: interesting) else { return nil }

        let step = PaneDividerAccessibilityConfiguration.step
        switch (axis, keyCode) {
        case (.horizontal, 123), (.vertical, 126): return -step
        case (.horizontal, 124), (.vertical, 125): return step
        default: return nil
        }
    }

    // MARK: - Configuration

    func configure(
        _ configuration: PaneDividerAccessibilityConfiguration,
        onAdjust: @escaping (CGFloat) -> Void
    ) {
        self.configuration = configuration
        self.onAdjust = onAdjust
        setAccessibilityLabel(configuration.label)
        setAccessibilityHelp(configuration.help)
        setAccessibilityIdentifier(configuration.identifier)
        setAccessibilityValue(configuration.accessibilityValue)
        setAccessibilityOrientation(configuration.orientation)
    }

    // MARK: - Adjusting

    /// Moves the divider by `steps` of the split, reporting whether it moved.
    /// Returning `false` at either bound is what makes VoiceOver announce that
    /// the divider is already as far as it goes.
    @discardableResult
    func adjust(by steps: CGFloat) -> Bool {
        guard let configuration, let onAdjust else { return false }
        let current = PaneDividerAccessibilityConfiguration
            .clamp(configuration.ratio)
        let target = PaneDividerAccessibilityConfiguration
            .clamp(current + steps)
        guard abs(target - current) > .ulpOfOne else { return false }
        onAdjust(target)
        return true
    }

    override func accessibilityPerformIncrement() -> Bool {
        adjust(by: PaneDividerAccessibilityConfiguration.step)
    }

    override func accessibilityPerformDecrement() -> Bool {
        adjust(by: -PaneDividerAccessibilityConfiguration.step)
    }
}

/// Embeds ``PaneDividerAccessibilityView`` behind the drawn divider without
/// changing layout or pointer hit testing.
struct PaneDividerAccessibility: NSViewRepresentable {
    let configuration: PaneDividerAccessibilityConfiguration
    let onAdjust: (CGFloat) -> Void

    func makeNSView(context: Context) -> PaneDividerAccessibilityView {
        PaneDividerAccessibilityView(frame: .zero)
    }

    func updateNSView(
        _ nsView: PaneDividerAccessibilityView,
        context: Context
    ) {
        nsView.configure(configuration, onAdjust: onAdjust)
    }
}
