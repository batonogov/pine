//
//  HunkToolbarView.swift
//  Pine
//
//  A compact AppKit toolbar overlay for expanded diff hunks (#689).
//  Shows: ← Prev | ↑ summary (2/5) ↓ | Restore | ✕
//  Positioned above the first line of the expanded hunk, right-aligned.
//

import AppKit

/// A compact, pill-shaped toolbar shown above an expanded inline diff hunk.
/// Contains navigation arrows, hunk summary, restore button, and dismiss button.
final class HunkToolbarView: NSView {

    // MARK: - State

    /// Descriptive text like "2/5 +3 -1".
    var summaryText: String = "" {
        didSet { summaryLabel.stringValue = summaryText }
    }

    /// Callback for toolbar actions.
    var onAction: ((HunkToolbarAction) -> Void)?

    // MARK: - Subviews

    private let prevButton = NSButton()
    private let nextButton = NSButton()
    private let summaryLabel = NSTextField(labelWithString: "")
    private let restoreButton = NSButton()
    private let dismissButton = NSButton()
    private let stackView = NSStackView()
    private(set) var separatorViews: [NSView] = []

    // MARK: - Constants

    static let toolbarHeight: CGFloat = 24
    private static let cornerRadius: CGFloat = 6
    private static let horizontalPadding: CGFloat = 4
    private static let buttonFontSize: CGFloat = 11

    override var isFlipped: Bool { true }

    // MARK: - Init

    init() {
        super.init(frame: .zero)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Setup

    private func setupViews() {
        wantsLayer = true
        layer?.cornerRadius = Self.cornerRadius

        // Shadow (must not use masksToBounds, otherwise shadow is clipped)
        shadow = NSShadow()
        layer?.shadowColor = NSColor.black.withAlphaComponent(0.15).cgColor
        layer?.shadowOffset = CGSize(width: 0, height: 1)
        layer?.shadowRadius = 3
        layer?.shadowOpacity = 1

        // Apply appearance-dependent colors
        updateAppearanceColors()

        // Configure buttons
        configureButton(
            prevButton,
            symbolName: "chevron.up",
            tooltip: Strings.hunkToolbarPreviousChange,
            accessibilityID: AccessibilityID.hunkToolbarPrevious,
            action: #selector(prevClicked)
        )
        configureButton(
            nextButton,
            symbolName: "chevron.down",
            tooltip: Strings.hunkToolbarNextChange,
            accessibilityID: AccessibilityID.hunkToolbarNext,
            action: #selector(nextClicked)
        )
        configureButton(
            restoreButton,
            symbolName: "arrow.uturn.backward",
            tooltip: Strings.hunkToolbarRestore,
            accessibilityID: AccessibilityID.hunkToolbarRestore,
            action: #selector(restoreClicked)
        )
        configureButton(
            dismissButton,
            symbolName: "xmark",
            tooltip: Strings.hunkToolbarDismiss,
            accessibilityID: AccessibilityID.hunkToolbarDismiss,
            action: #selector(dismissClicked)
        )

        // Summary label
        summaryLabel.font = NSFont.monospacedSystemFont(ofSize: Self.buttonFontSize, weight: .medium)
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        summaryLabel.setAccessibilityIdentifier(AccessibilityID.hunkToolbarSummary)

        // Separator views
        let sep1 = makeSeparator()
        let sep2 = makeSeparator()
        separatorViews = [sep1, sep2]

        // Stack
        stackView.orientation = .horizontal
        stackView.spacing = 2
        stackView.alignment = .centerY
        stackView.edgeInsets = NSEdgeInsets(
            top: 0,
            left: Self.horizontalPadding,
            bottom: 0,
            right: Self.horizontalPadding
        )
        stackView.setViews(
            [prevButton, nextButton, sep1, summaryLabel, sep2, restoreButton, dismissButton],
            in: .center
        )

        addSubview(stackView)
        stackView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor),
            stackView.topAnchor.constraint(equalTo: topAnchor),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        setAccessibilityIdentifier(AccessibilityID.hunkToolbar)
    }

    private func configureButton(
        _ button: NSButton,
        symbolName: String,
        tooltip: String,
        accessibilityID: String,
        action: Selector
    ) {
        let config = NSImage.SymbolConfiguration(pointSize: Self.buttonFontSize, weight: .medium)
        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: tooltip)?
            .withSymbolConfiguration(config) {
            button.image = image
        }
        button.isBordered = false
        button.bezelStyle = .accessoryBarAction
        button.toolTip = tooltip
        button.target = self
        button.action = action
        button.setAccessibilityIdentifier(accessibilityID)
        button.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        button.setContentHuggingPriority(.defaultHigh, for: .vertical)
    }

    private func makeSeparator() -> NSView {
        let sep = NSView()
        sep.wantsLayer = true
        sep.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.3).cgColor
        sep.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            sep.widthAnchor.constraint(equalToConstant: 1),
            sep.heightAnchor.constraint(equalToConstant: 14)
        ])
        return sep
    }

    // MARK: - Actions

    @objc private func prevClicked() {
        onAction?(.previousHunk)
    }

    @objc private func nextClicked() {
        onAction?(.nextHunk)
    }

    @objc private func restoreClicked() {
        onAction?(.restore)
    }

    @objc private func dismissClicked() {
        onAction?(.dismiss)
    }

    // MARK: - Appearance Updates

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearanceColors()
    }

    /// Recomputes background and border colors for the current appearance (Dark/Light mode).
    private func updateAppearanceColors() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let bgColor = isDark
            ? NSColor.controlBackgroundColor.withAlphaComponent(0.95)
            : NSColor.controlBackgroundColor.withAlphaComponent(0.92)
        layer?.backgroundColor = bgColor.cgColor

        let border = isDark
            ? NSColor.separatorColor.withAlphaComponent(0.5)
            : NSColor.separatorColor.withAlphaComponent(0.3)
        layer?.borderColor = border.cgColor
        layer?.borderWidth = 0.5

        let separatorColor = NSColor.separatorColor.withAlphaComponent(0.3).cgColor
        for sep in separatorViews {
            sep.layer?.backgroundColor = separatorColor
        }
    }

    // MARK: - Sizing

    /// Calculates the ideal width for the toolbar based on its contents.
    func idealSize() -> NSSize {
        stackView.layoutSubtreeIfNeeded()
        let fittingSize = stackView.fittingSize
        return NSSize(
            width: fittingSize.width + Self.horizontalPadding * 2,
            height: Self.toolbarHeight
        )
    }
}
