//
//  InlineDiffToolbarView.swift
//  Pine
//
//  Floating action toolbar that appears alongside an expanded inline diff
//  hunk (#689). Hosts Restore + navigation buttons. Stage is added later
//  in #687 (PR2).
//

import AppKit

/// A small floating NSView containing inline diff actions for the currently
/// expanded hunk.
final class InlineDiffToolbarView: NSView {

    // MARK: - Callbacks

    /// Invoked when the user clicks the Restore button.
    var onRestore: (() -> Void)?
    /// Invoked when the user clicks the next-hunk button.
    var onNext: (() -> Void)?
    /// Invoked when the user clicks the previous-hunk button.
    var onPrevious: (() -> Void)?
    /// Invoked when the toolbar requests dismissal (Escape, click outside, edit, etc.).
    var onDismiss: (() -> Void)?

    // MARK: - Buttons

    let restoreButton: NSButton
    let nextButton: NSButton
    let previousButton: NSButton

    // MARK: - Layout constants

    private static let buttonHeight: CGFloat = 22
    private static let horizontalPadding: CGFloat = 8
    private static let verticalPadding: CGFloat = 4
    private static let buttonSpacing: CGFloat = 6

    // MARK: - Init

    init() {
        self.restoreButton = Self.makeTextButton(
            title: NSLocalizedString("Restore", comment: "Inline diff Restore button"),
            symbol: "arrow.uturn.backward",
            id: AccessibilityID.inlineDiffRestoreButton
        )
        self.previousButton = Self.makeIconButton(
            symbol: "chevron.up",
            id: AccessibilityID.inlineDiffPreviousButton,
            tooltip: NSLocalizedString("Previous Change", comment: "Inline diff prev button")
        )
        self.nextButton = Self.makeIconButton(
            symbol: "chevron.down",
            id: AccessibilityID.inlineDiffNextButton,
            tooltip: NSLocalizedString("Next Change", comment: "Inline diff next button")
        )

        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.95).cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.12
        layer?.shadowRadius = 4
        layer?.shadowOffset = NSSize(width: 0, height: -1)

        setAccessibilityIdentifier(AccessibilityID.inlineDiffToolbar)

        restoreButton.target = self
        restoreButton.action = #selector(restoreClicked(_:))
        nextButton.target = self
        nextButton.action = #selector(nextClicked(_:))
        previousButton.target = self
        previousButton.action = #selector(previousClicked(_:))

        addSubview(previousButton)
        addSubview(nextButton)
        addSubview(restoreButton)

        layoutButtons()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Layout

    override var intrinsicContentSize: NSSize {
        let buttons: [NSButton] = subviews.compactMap { $0 as? NSButton }
        let totalWidth = buttons.reduce(CGFloat(0)) { acc, btn in
            acc + max(btn.intrinsicContentSize.width, Self.buttonHeight)
        } + CGFloat(max(buttons.count - 1, 0)) * Self.buttonSpacing
            + Self.horizontalPadding * 2
        let height = Self.buttonHeight + Self.verticalPadding * 2
        return NSSize(width: totalWidth, height: height)
    }

    private func layoutButtons() {
        // Order (left → right): Previous, Next, Restore
        let buttons: [NSButton] = [previousButton, nextButton, restoreButton]
        var x = Self.horizontalPadding
        let y = Self.verticalPadding
        for btn in buttons {
            let w = max(btn.intrinsicContentSize.width, Self.buttonHeight)
            btn.frame = NSRect(x: x, y: y, width: w, height: Self.buttonHeight)
            x += w + Self.buttonSpacing
        }
        let size = intrinsicContentSize
        frame = NSRect(origin: frame.origin, size: size)
    }

    // MARK: - Public API

    /// Updates enabled state of the navigation arrows.
    func updateNavigationState(canGoNext: Bool, canGoPrevious: Bool) {
        nextButton.isEnabled = canGoNext
        previousButton.isEnabled = canGoPrevious
    }

    /// Forces a dismiss request (used by external triggers like Escape or
    /// outside click) — exposed for unit-test invocation as well.
    func requestDismiss() {
        onDismiss?()
    }

    // MARK: - Actions

    @objc private func restoreClicked(_ sender: Any?) {
        onRestore?()
    }

    @objc private func nextClicked(_ sender: Any?) {
        onNext?()
    }

    @objc private func previousClicked(_ sender: Any?) {
        onPrevious?()
    }

    // MARK: - Button factories

    private static func makeTextButton(title: String, symbol: String, id: String) -> NSButton {
        let btn = NSButton()
        btn.bezelStyle = .recessed
        btn.title = title
        btn.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        btn.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        btn.imagePosition = .imageLeading
        btn.imageScaling = .scaleProportionallyDown
        btn.identifier = NSUserInterfaceItemIdentifier(id)
        btn.setAccessibilityIdentifier(id)
        btn.toolTip = title
        return btn
    }

    private static func makeIconButton(symbol: String, id: String, tooltip: String) -> NSButton {
        let btn = NSButton()
        btn.bezelStyle = .recessed
        btn.title = ""
        btn.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        btn.imagePosition = .imageOnly
        btn.imageScaling = .scaleProportionallyDown
        btn.identifier = NSUserInterfaceItemIdentifier(id)
        btn.setAccessibilityIdentifier(id)
        btn.toolTip = tooltip
        return btn
    }
}
