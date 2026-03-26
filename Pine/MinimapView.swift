//
//  MinimapView.swift
//  Pine
//
//  Created by Claude on 17.03.2026.
//

import AppKit
import os

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

    static func toggle(in defaults: UserDefaults = .standard) {
        setVisible(!isVisible(in: defaults), in: defaults)
    }
}

// MARK: - MinimapView

/// A miniature overview of the entire file, displayed alongside the code editor.
/// Renders each line as a thin (~2px) strip with syntax-colored segments.
/// The minimap scrolls proportionally with the editor — it does NOT squeeze
/// the entire document into the panel height. A viewport indicator shows
/// the currently visible region. Supports click-to-scroll and drag-to-scroll.
final class MinimapView: NSView {
    weak var textView: NSTextView?
    /// The clip view this minimap observes for scroll notifications.
    private weak var observedClipView: NSClipView?

    /// Git diff data — when set, colored markers appear on the right edge.
    var lineDiffs: [GitLineDiff] = [] {
        didSet {
            diffMap = Dictionary(uniqueKeysWithValues: lineDiffs.map { ($0.line, $0.kind) })
            needsDisplay = true
        }
    }
    private var diffMap: [Int: GitLineDiff.Kind] = [:]

    /// Default width of the minimap panel.
    static let defaultWidth: CGFloat = 100

    /// Scale factor: each editor line becomes this many points tall in the minimap.
    static let scaleFactor: CGFloat = 0.12

    /// Width of one character in minimap coordinates.
    private let charWidth: CGFloat = MinimapConstants.charWidth

    /// Total document height including top origin offset and bottom inset.
    /// Ensures layout is up-to-date before measuring to prevent stale values
    /// when text changes (e.g., pressing Enter at end of file) trigger a redraw
    /// before the layout manager has recalculated.
    private func documentHeight(
        layoutManager: NSLayoutManager,
        textContainer: NSTextContainer,
        textView: NSTextView
    ) -> CGFloat {
        layoutManager.ensureLayout(for: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)
        return usedRect.height + textView.textContainerOrigin.y + textView.textContainerInset.height
    }

    /// Background color — matches editor background.
    private let bgColor = NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor(srgbRed: 0.15, green: 0.15, blue: 0.17, alpha: 1)
        } else {
            return NSColor(srgbRed: 0.97, green: 0.97, blue: 0.98, alpha: 1)
        }
    }

    /// Viewport indicator fill.
    private let viewportColor = NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor.white.withAlphaComponent(0.08)
        } else {
            return NSColor.black.withAlphaComponent(0.05)
        }
    }

    /// Viewport indicator border.
    private let viewportBorderColor = NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor.white.withAlphaComponent(0.15)
        } else {
            return NSColor.black.withAlphaComponent(0.10)
        }
    }

    #if DEBUG
    /// Counter for scroll-change notifications received — debug-only, for testability.
    var scrollChangeCount = 0
    #endif

    /// Whether user is currently dragging in the minimap.
    private var isDragging = false

    override var isFlipped: Bool { true }

    init(textView: NSTextView, clipView: NSClipView? = nil) {
        self.textView = textView
        let resolvedClipView = clipView ?? textView.enclosingScrollView?.contentView
        self.observedClipView = resolvedClipView
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityIdentifier(AccessibilityID.minimap)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Minimap")

        NotificationCenter.default.addObserver(
            self, selector: #selector(contentDidChange),
            name: NSText.didChangeNotification,
            object: textView
        )
        // Frame changes cover initial layout completion and window resize
        NotificationCenter.default.addObserver(
            self, selector: #selector(contentDidChange),
            name: NSView.frameDidChangeNotification,
            object: textView
        )
        // Скролл — подписываемся на конкретный clipView (#465)
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrollDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: resolvedClipView
        )

        #if DEBUG
        if resolvedClipView == nil {
            Logger.editor.warning("MinimapView: clipView is nil at init — scroll observer will not fire. Pass clipView explicitly.")
        }
        #endif
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            // Defer to ensure layout is complete after initial text setup
            DispatchQueue.main.async { [weak self] in
                self?.needsDisplay = true
            }
        }
    }

    /// Throttle interval for scroll-triggered redraws (~3 frames at 120fps ProMotion).
    private static let scrollThrottleInterval: TimeInterval = 0.025
    /// Timestamp of last scroll-triggered redraw.
    private var lastScrollRedrawTime: CFTimeInterval = 0
    /// Pending throttled redraw work item.
    private var scrollRedrawWorkItem: DispatchWorkItem?

    deinit {
        scrollRedrawWorkItem?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Notifications

    @objc private func contentDidChange() {
        needsDisplay = true
    }

    @objc private func scrollDidChange(_ notification: Notification) {
        // Safety: if clipView was nil at init, subscription is unscoped — filter here
        guard observedClipView == nil || notification.object as AnyObject? === observedClipView else { return }
        #if DEBUG
        scrollChangeCount += 1
        #endif
        let now = CACurrentMediaTime()
        if now - lastScrollRedrawTime >= Self.scrollThrottleInterval {
            lastScrollRedrawTime = now
            scrollRedrawWorkItem?.cancel()
            scrollRedrawWorkItem = nil
            needsDisplay = true
        } else {
            // Coalesce: schedule a trailing redraw to catch the final scroll position.
            if scrollRedrawWorkItem == nil {
                let workItem = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.lastScrollRedrawTime = CACurrentMediaTime()
                    self.scrollRedrawWorkItem = nil
                    self.needsDisplay = true
                }
                scrollRedrawWorkItem = workItem
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + Self.scrollThrottleInterval,
                    execute: workItem
                )
            }
        }
    }

    // MARK: - Coordinate mapping

    /// The vertical offset applied to the minimap content so the viewport indicator
    /// stays within the visible panel area. When the document is taller than the
    /// minimap panel, the minimap "scrolls" proportionally.
    private func minimapOffset() -> (offset: CGFloat, scaledDocHeight: CGFloat) {
        guard let textView = textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer,
              let scrollView = textView.enclosingScrollView else {
            return (0, 0)
        }

        let docHeight = documentHeight(layoutManager: layoutManager, textContainer: textContainer, textView: textView)
        let scaledDocHeight = docHeight * Self.scaleFactor
        let panelHeight = bounds.height

        // If scaled document fits in panel — no offset needed
        guard scaledDocHeight > panelHeight else { return (0, scaledDocHeight) }

        // Scroll proportionally: when editor is scrolled to bottom,
        // minimap is scrolled to show the bottom of the document.
        let visibleRect = scrollView.contentView.bounds
        let maxEditorScroll = max(1, docHeight - visibleRect.height)
        // Clamp scroll position to prevent jump when scroll offset exceeds
        // document height during layout recalculation
        let currentScroll = min(visibleRect.origin.y, max(0, maxEditorScroll))
        let scrollFraction = min(max(currentScroll / maxEditorScroll, 0), 1)

        let maxMinimapOffset = scaledDocHeight - panelHeight
        let offset = scrollFraction * maxMinimapOffset

        return (offset, scaledDocHeight)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let textView = textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer,
              let textStorage = textView.textStorage else { return }

        // Background
        bgColor.setFill()
        bounds.fill()

        let source = textView.string as NSString
        guard source.length > 0 else { return }

        let (offset, _) = minimapOffset()
        let scale = Self.scaleFactor
        let originY = textView.textContainerOrigin.y
        let lineHeight: CGFloat = MinimapConstants.lineHeight

        // Calculate the document Y range that maps to the visible minimap area.
        // Only enumerate line fragments within this range to avoid iterating the entire document.
        let docYStart = max(0, offset / scale - originY)
        let docYEnd = (offset + bounds.height) / scale - originY
        let visibleDocRect = NSRect(x: 0, y: docYStart, width: textContainer.size.width, height: docYEnd - docYStart)
        let visibleGlyphRange = layoutManager.glyphRange(forBoundingRect: visibleDocRect, in: textContainer)
        guard visibleGlyphRange.location != NSNotFound else { return }

        // Diff marker state — tracked incrementally across fragments
        let hasDiffMarkers = !diffMap.isEmpty
        let markerWidth: CGFloat = MinimapConstants.diffMarkerWidth
        let markerX = bounds.width - markerWidth
        var diffLineNumber = 1
        var diffLastCharPos = 0

        layoutManager.enumerateLineFragments(forGlyphRange: visibleGlyphRange) { lineRect, _, _, glyphRange, _ in
            let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            let y = (lineRect.origin.y + originY) * scale - offset

            // Advance diff line counter for newlines between last position and this fragment
            if hasDiffMarkers {
                let scanEnd = min(charRange.location, source.length)
                for i in diffLastCharPos..<scanEnd where source.character(at: i) == ASCII.newline {
                    diffLineNumber += 1
                }
                diffLastCharPos = scanEnd
            }

            // Cull lines outside visible area
            guard y + lineHeight > 0 && y < self.bounds.height else { return }

            // Draw diff marker on the right edge
            if hasDiffMarkers, let kind = self.diffMap[diffLineNumber] {
                let color: NSColor
                switch kind {
                case .added:    color = .systemGreen
                case .modified: color = .systemBlue
                case .deleted:  color = .systemRed
                }
                color.setFill()
                NSRect(x: markerX, y: y, width: markerWidth, height: lineHeight).fill()
            }

            // Skip blank lines for syntax rendering
            let lineText = source.substring(with: charRange)
            let trimmed = lineText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }

            // Leading whitespace → x offset
            let leadingSpaces = lineText.prefix(while: { $0 == " " || $0 == "\t" }).count
            let xStart: CGFloat = CGFloat(leadingSpaces) * self.charWidth + MinimapConstants.leadingPadding

            // Walk through syntax-colored segments
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
                    let localStart = segStart - charRange.location
                    let x = xStart + CGFloat(localStart) * self.charWidth
                    let width = CGFloat(segLen) * self.charWidth

                    let segRect = NSRect(
                        x: x,
                        y: y,
                        width: min(width, self.bounds.width - x),
                        height: lineHeight
                    )

                    if segRect.maxX > 0 && segRect.minX < self.bounds.width {
                        color.withAlphaComponent(MinimapConstants.syntaxSegmentAlpha).setFill()
                        segRect.fill()
                    }
                }

                pos = segEnd
            }
        }

        // Draw viewport indicator
        if let vpRect = computeViewportRect() {
            viewportColor.setFill()
            vpRect.fill()

            viewportBorderColor.setStroke()
            let border = NSBezierPath(rect: vpRect.insetBy(dx: 0.5, dy: 0.5))
            border.lineWidth = 1
            border.stroke()
        }
    }

    // MARK: - Viewport rect

    /// Computes the viewport indicator rectangle in minimap coordinates.
    func computeViewportRect() -> NSRect? {
        guard let textView = textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer,
              let scrollView = textView.enclosingScrollView else { return nil }

        let docHeight = documentHeight(layoutManager: layoutManager, textContainer: textContainer, textView: textView)
        guard docHeight > 0 else { return nil }

        let scale = Self.scaleFactor
        let (offset, _) = minimapOffset()
        let visibleRect = scrollView.contentView.bounds

        // Clamp scroll position to document height to prevent viewport jump
        // when layout manager hasn't fully recalculated after text changes
        let clampedScrollY = min(visibleRect.origin.y, max(0, docHeight - visibleRect.height))
        let y = clampedScrollY * scale - offset
        let height = visibleRect.height * scale

        let clampedY = max(0, y)
        let clampedHeight = min(height, bounds.height - clampedY)

        guard clampedHeight > 0 else { return nil }

        return NSRect(x: 0, y: clampedY, width: bounds.width, height: clampedHeight)
    }

    // MARK: - Click / Drag to scroll

    /// Scrolls the editor to center on the position corresponding to the given minimap Y coordinate.
    func scrollToPosition(minimapY: CGFloat) {
        guard let textView = textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer,
              let scrollView = textView.enclosingScrollView else { return }

        let docHeight = documentHeight(layoutManager: layoutManager, textContainer: textContainer, textView: textView)
        guard docHeight > 0, bounds.height > 0 else { return }

        let scale = Self.scaleFactor
        let (offset, _) = minimapOffset()
        let visibleHeight = scrollView.contentView.bounds.height

        // Convert minimap Y back to document Y, centering the viewport
        let documentY = ((minimapY + offset) / scale) - (visibleHeight / 2)

        // Clamp
        let maxScroll = max(0, docHeight - visibleHeight)
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
