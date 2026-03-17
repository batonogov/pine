//
//  MinimapView.swift
//  Pine
//
//  Created by Claude on 17.03.2026.
//

import AppKit

// MARK: - Minimap Settings

/// Manages minimap visibility persistence in UserDefaults.
enum MinimapSettings {
    private static let key = "minimapVisible"

    static func isVisible(in defaults: UserDefaults = .standard) -> Bool {
        // Default to true if key is not set
        if defaults.object(forKey: key) == nil { return true }
        return defaults.bool(forKey: key)
    }

    static func setVisible(_ visible: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(visible, forKey: key)
    }
}

// MARK: - MinimapView

/// A miniature overview of the entire file, displayed alongside the code editor.
/// Shows a scaled-down representation of the syntax-highlighted text with a
/// viewport indicator showing the currently visible region.
/// Supports click-to-scroll and drag-to-scroll.
final class MinimapView: NSView {
    weak var textView: NSTextView?

    /// Default width of the minimap panel.
    static let defaultWidth: CGFloat = 80

    /// Scale factor for rendering the minimap text.
    static let scaleFactor: CGFloat = 0.15

    /// Font for minimap rendering — very small monospace.
    private let minimapFont = NSFont.monospacedSystemFont(ofSize: 2, weight: .regular)

    /// Background color — slightly different from editor for visual separation.
    private let bgColor = NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor(srgbRed: 0.14, green: 0.14, blue: 0.16, alpha: 1)
        } else {
            return NSColor(srgbRed: 0.96, green: 0.96, blue: 0.97, alpha: 1)
        }
    }

    /// Viewport indicator color.
    private let viewportColor = NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor.white.withAlphaComponent(0.12)
        } else {
            return NSColor.black.withAlphaComponent(0.08)
        }
    }

    /// Viewport indicator border color.
    private let viewportBorderColor = NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor.white.withAlphaComponent(0.2)
        } else {
            return NSColor.black.withAlphaComponent(0.12)
        }
    }

    /// Cached attributed string for the minimap content.
    private var cachedContent: NSAttributedString?
    /// Text hash to detect when content changes.
    private var cachedTextHash: Int = 0

    /// Whether user is currently dragging in the minimap.
    private var isDragging = false

    override var isFlipped: Bool { true }

    init(textView: NSTextView) {
        self.textView = textView
        super.init(frame: .zero)
        wantsLayer = true

        // Observe text changes to invalidate cache
        NotificationCenter.default.addObserver(
            self, selector: #selector(contentDidChange),
            name: NSText.didChangeNotification,
            object: textView
        )

        // Observe scroll changes for viewport indicator
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrollDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Notifications

    @objc private func contentDidChange() {
        cachedContent = nil
        needsDisplay = true
    }

    @objc private func scrollDidChange(_ notification: Notification) {
        guard let clipView = notification.object as? NSClipView,
              clipView == textView?.enclosingScrollView?.contentView else { return }
        needsDisplay = true
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let textView = textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }

        // Background
        bgColor.setFill()
        bounds.fill()

        let source = textView.string as NSString
        guard source.length > 0 else { return }

        // Ensure layout is complete
        layoutManager.ensureLayout(for: textContainer)

        // Total document height
        let usedRect = layoutManager.usedRect(for: textContainer)
        let documentHeight = usedRect.height + textView.textContainerOrigin.y

        guard documentHeight > 0 else { return }

        // Scale factor: map entire document height to minimap height
        let scale = bounds.height / documentHeight

        // Draw minimap content using colored rectangles per line
        drawMinimapContent(
            layoutManager: layoutManager,
            textContainer: textContainer,
            textView: textView,
            source: source,
            scale: scale
        )

        // Draw viewport indicator
        if let vpRect = computeViewportRect() {
            viewportColor.setFill()
            vpRect.fill()

            viewportBorderColor.setStroke()
            let border = NSBezierPath(rect: vpRect)
            border.lineWidth = 1
            border.stroke()
        }
    }

    /// Draws colored lines representing the code content.
    /// Uses the text storage attributes (syntax highlighting colors) directly.
    private func drawMinimapContent(
        layoutManager: NSLayoutManager,
        textContainer: NSTextContainer,
        textView: NSTextView,
        source: NSString,
        scale: CGFloat
    ) {
        guard let textStorage = textView.textStorage else { return }

        let originY = textView.textContainerOrigin.y
        let lineHeight = max(1, 2 * scale / Self.scaleFactor)
        let fullGlyphRange = layoutManager.glyphRange(for: textContainer)

        layoutManager.enumerateLineFragments(forGlyphRange: fullGlyphRange) { lineRect, _, _, glyphRange, _ in
            let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            let y = (lineRect.origin.y + originY) * scale

            // Skip lines outside visible area
            guard y + lineHeight >= 0 && y <= self.bounds.height else { return }

            // Get the visible text for this line (skip empty lines)
            let lineText = source.substring(with: charRange)
            let trimmed = lineText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }

            // Calculate leading whitespace offset
            let leadingSpaces = lineText.prefix(while: { $0 == " " || $0 == "\t" }).count
            let charWidth: CGFloat = 1.2
            let xOffset: CGFloat = CGFloat(leadingSpaces) * charWidth + 4

            // Draw colored segments based on syntax highlighting attributes
            var pos = charRange.location
            let end = NSMaxRange(charRange)

            while pos < end {
                var effectiveRange = NSRange()
                let color = textStorage.attribute(
                    .foregroundColor,
                    at: pos,
                    effectiveRange: &effectiveRange
                ) as? NSColor ?? .textColor

                let segStart = max(pos, charRange.location)
                let segEnd = min(NSMaxRange(effectiveRange), end)
                let segLen = segEnd - segStart

                if segLen > 0 {
                    // Map character position within line to x coordinate
                    let localStart = segStart - charRange.location
                    let x = xOffset + CGFloat(localStart) * charWidth
                    let width = CGFloat(segLen) * charWidth

                    let segRect = NSRect(
                        x: x,
                        y: y,
                        width: min(width, self.bounds.width - x),
                        height: max(lineHeight, 1.5)
                    )

                    if segRect.maxX > 0 && segRect.minX < self.bounds.width {
                        color.withAlphaComponent(0.7).setFill()
                        segRect.fill()
                    }
                }

                pos = segEnd
            }
        }
    }

    // MARK: - Viewport rect

    /// Computes the viewport indicator rectangle in minimap coordinates.
    func computeViewportRect() -> NSRect? {
        guard let textView = textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer,
              let scrollView = textView.enclosingScrollView else { return nil }

        let usedRect = layoutManager.usedRect(for: textContainer)
        let documentHeight = usedRect.height + textView.textContainerOrigin.y
        guard documentHeight > 0 else { return nil }

        let scale = bounds.height / documentHeight
        let visibleRect = scrollView.contentView.bounds

        let y = visibleRect.origin.y * scale
        let height = visibleRect.height * scale

        return NSRect(
            x: 0,
            y: max(0, y),
            width: bounds.width,
            height: min(height, bounds.height - max(0, y))
        )
    }

    // MARK: - Click / Drag to scroll

    /// Scrolls the editor to center on the position corresponding to the given minimap Y coordinate.
    func scrollToPosition(minimapY: CGFloat) {
        guard let textView = textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer,
              let scrollView = textView.enclosingScrollView else { return }

        let usedRect = layoutManager.usedRect(for: textContainer)
        let documentHeight = usedRect.height + textView.textContainerOrigin.y
        guard documentHeight > 0, bounds.height > 0 else { return }

        let scale = bounds.height / documentHeight
        let visibleHeight = scrollView.contentView.bounds.height

        // Convert minimap Y to document Y, centering the viewport
        let documentY = (minimapY / scale) - (visibleHeight / 2)

        // Clamp to valid range
        let maxScroll = max(0, documentHeight - visibleHeight)
        let clampedY = min(max(0, documentY), maxScroll)

        scrollView.contentView.scroll(to: NSPoint(x: 0, y: clampedY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    override func mouseDown(with event: NSEvent) {
        isDragging = true
        let point = convert(event.locationInWindow, from: nil)
        scrollToPosition(minimapY: point.y)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        let point = convert(event.locationInWindow, from: nil)
        scrollToPosition(minimapY: point.y)
    }

    override func mouseUp(with event: NSEvent) {
        isDragging = false
    }
}
