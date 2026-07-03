//
//  GutterTextView+LSPMouseTracking.swift
//  Pine
//
//  Phase 5 of LSP support (milestone #1088, item 1).
//
//  Supporting extension for `GutterTextView` that provides LSP-related
//  mouse tracking state and helper methods. The actual `override` methods
//  (`mouseMoved`, `mouseExited`, `mouseDown`, `rightMouseDown`,
//  `updateTrackingAreas`) are implemented directly inside the
//  `GutterTextView` class body because Swift does not allow `override` in
//  extensions on non-`@objc` framework classes.
//
//  This extension provides:
//    • Stored property shims via associated objects (`lspMouseHandler`,
//      `hoverTimer`, `lastHoverLocation`)
//    • Character-index lookup (`lspCharacterIndex(at:)`)
//    • Tracking area installation (`installLSPTrackingArea`)
//    • Scroll dismissal helper (`lspDismissHoverOnScroll`)
//

import AppKit

extension GutterTextView {

    // MARK: - Associated object keys

    private static var lspHandlerKey: UInt8 = 0
    private static var hoverTimerKey: UInt8 = 0
    private static var lastHoverLocationKey: UInt8 = 0

    // MARK: - Properties via associated objects

    /// The weak reference to the LSP mouse handler (the coordinator).
    var lspMouseHandler: LSPMouseHandling? {
        get { objc_getAssociatedObject(self, &Self.lspHandlerKey) as? LSPMouseHandling }
        set { objc_setAssociatedObject(self, &Self.lspHandlerKey, newValue, .OBJC_ASSOCIATION_RETAIN) }
    }

    /// The debounce timer for hover. Reset on every mouseMoved.
    var hoverTimer: Timer? {
        get { objc_getAssociatedObject(self, &Self.hoverTimerKey) as? Timer }
        set { objc_setAssociatedObject(self, &Self.hoverTimerKey, newValue, .OBJC_ASSOCIATION_RETAIN) }
    }

    /// The last mouse location (in text view coordinates) for hover tracking.
    var lastHoverLocation: NSPoint? {
        get { objc_getAssociatedObject(self, &Self.lastHoverLocationKey) as? NSPoint }
        set { objc_setAssociatedObject(self, &Self.lastHoverLocationKey, newValue, .OBJC_ASSOCIATION_RETAIN) }
    }

    // MARK: - Tracking area installation

    /// Installs or refreshes the LSP mouse-tracking area covering the
    /// visible bounds. Called from `updateTrackingAreas()` override.
    func installLSPTrackingArea() {
        // Remove old LSP tracking areas.
        for area in trackingAreas where area.userInfo?["lsp"] as? Bool == true {
            removeTrackingArea(area)
        }

        let rect = visibleRect
        guard rect.width > 0, rect.height > 0 else { return }
        let area = NSTrackingArea(
            rect: rect,
            options: [
                .mouseEnteredAndExited,
                .mouseMoved,
                .activeInActiveApp,
                .inVisibleRect
            ],
            owner: self,
            userInfo: ["lsp": true]
        )
        addTrackingArea(area)
    }

    // MARK: - Hover scheduling

    /// Schedules a hover request after the 200ms debounce. The timer fires
    /// `lspMouseHandler?.lspHover(at:)` on the main thread. Called from the
    /// `mouseMoved` override.
    func scheduleLSPHover(at location: NSPoint) {
        guard lspMouseHandler != nil else { return }

        lastHoverLocation = location

        // If the mouse hasn't moved to a different character, don't reset.
        let offset = lspCharacterIndex(at: location)
        if let oldLocation = lastHoverLocation {
            let oldOffset = lspCharacterIndex(at: oldLocation)
            if oldOffset == offset { return }
        }

        hoverTimer?.invalidate()
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard let location = self.lastHoverLocation else { return }
                let offset = self.lspCharacterIndex(at: location)
                guard offset >= 0 else { return }
                self.lspMouseHandler?.lspHover(at: offset)
            }
        }
    }

    /// Cancels the hover timer and notifies the handler that hover ended.
    func cancelLSPHover() {
        hoverTimer?.invalidate()
        hoverTimer = nil
        lastHoverLocation = nil
        lspMouseHandler?.lspHoverEnded()
    }

    /// Called by the coordinator when the scroll view bounds change —
    /// dismisses the hover popover.
    func lspDismissHoverOnScroll() {
        cancelLSPHover()
    }

    // MARK: - Character index

    /// Returns the UTF-16 character index at `point`, or -1 if the point is
    /// not over any character.
    func lspCharacterIndex(at point: NSPoint) -> Int {
        guard let layoutManager = layoutManager,
              let textContainer = textContainer else { return -1 }

        // Adjust for the text container origin (gutter inset).
        let adjustedPoint = NSPoint(
            x: point.x - textContainerOrigin.x,
            y: point.y - textContainerOrigin.y
        )

        let index = layoutManager.characterIndex(
            for: adjustedPoint,
            in: textContainer,
            fractionOfDistanceBetweenInsertionPoints: nil
        )

        guard index != NSNotFound,
              index < (string as NSString).length else { return -1 }

        // Check if the point is actually near a glyph (not in empty space).
        let glyphIndex = layoutManager.glyphIndex(
            for: adjustedPoint,
            in: textContainer
        )
        let glyphRect = layoutManager.boundingRect(
            forGlyphRange: NSRange(location: glyphIndex, length: 1),
            in: textContainer
        )
        // Allow a small margin around the glyph.
        let margin: CGFloat = 2
        let expandedRect = glyphRect.insetBy(dx: -margin, dy: -margin)
        if !expandedRect.contains(adjustedPoint) {
            return -1
        }

        return index
    }
}
