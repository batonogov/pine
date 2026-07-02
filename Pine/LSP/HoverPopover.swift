//
//  HoverPopover.swift
//  Pine
//
//  Phase 5 of LSP support (milestone #1088, item 1).
//
//  A lightweight popover that renders LSP hover content (Markdown or plain
//  text) as an attributed string in a read-only NSTextView. Hosted in an
//  NSPopover so it inherits Liquid Glass materials and proper dismissal
//  behavior (click-outside, scroll, etc.).
//
//  The popover is created lazily by the CodeEditorView coordinator and
//  repositioned at the hover target's screen rect before each show.
//

import AppKit

/// Manages the LSP hover popover lifecycle: show, hide, and content update.
///
/// `@MainActor` because NSPopover must be created and manipulated on the
/// main thread, and the coordinator that owns it is always on the main actor.
@MainActor
final class HoverPopoverManager {

    /// The underlying popover. Lazily created on first show.
    private var popover: NSPopover?

    /// The text view that renders the hover content inside the popover.
    private var contentTextView: NSTextView?

    /// Whether the popover is currently shown.
    var isVisible: Bool { popover?.isShown ?? false }

    init() {}

    // MARK: - Show

    /// Shows the hover popover anchored at `anchorRect` (in screen
    /// coordinates). If the popover is already shown, updates the content
    /// in place.
    /// - Parameters:
    ///   - content: The markdown or plain-text string to display.
    ///   - isMarkdown: Whether `content` is Markdown (parsed for rendering)
    ///     or plain text (shown verbatim).
    ///   - anchorRect: The screen rect of the symbol being hovered over.
    ///   - positioningView: The view used for coordinate conversion.
    func show(
        content: String,
        isMarkdown: Bool,
        anchorRect: NSRect,
        positioningView: NSView
    ) {
        let pop = ensurePopover()
        let textView = ensureContentTextView()

        // Render content as attributed string.
        let attributed = HoverMarkdownRenderer.render(content, isMarkdown: isMarkdown)
        textView.textStorage?.setAttributedString(attributed)

        // Size the popover to fit the content.
        let size = Self.contentSize(for: attributed, maxWidth: 500)
        pop.contentViewController?.view.frame = NSRect(
            origin: .zero,
            size: NSSize(width: size.width, height: size.height)
        )

        // Position the popover relative to the anchor rect in the
        // positioning view's coordinate space.
        let positionRect = positioningView.convert(anchorRect, from: nil)

        pop.show(
            relativeTo: positionRect,
            of: positioningView,
            preferredEdge: .maxY
        )
    }

    /// Hides the popover if visible.
    func hide() {
        guard let popover, popover.isShown else { return }
        popover.performClose(nil)
    }

    // MARK: - Lazy creation

    private func ensurePopover() -> NSPopover {
        if let popover { return popover }
        let pop = NSPopover()
        pop.behavior = .transient
        pop.animates = true
        let viewController = NSViewController()
        let container = NSView()
        container.wantsLayer = true
        let textView = NSTextView(frame: .zero)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 10, height: 8)
        textView.autoresizingMask = [.width, .height]
        container.addSubview(textView)
        viewController.view = container
        pop.contentViewController = viewController
        self.contentTextView = textView
        self.popover = pop
        return pop
    }

    private func ensureContentTextView() -> NSTextView {
        if contentTextView == nil {
            _ = ensurePopover()
        }
        return contentTextView ?? NSTextView()
    }

    // MARK: - Sizing

    /// Computes the content size needed to display the attributed string.
    private static func contentSize(
        for attributed: NSAttributedString,
        maxWidth: CGFloat
    ) -> NSSize {
        let padding: CGFloat = 20 // horizontal insets
        let verticalPadding: CGFloat = 16
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: maxWidth, height: 0))
        textView.textStorage?.setAttributedString(attributed)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.size = NSSize(
            width: maxWidth - padding,
            height: .greatestFiniteMagnitude
        )
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else {
            return NSSize(width: maxWidth, height: 60)
        }
        layoutManager.ensureLayout(for: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)
        let width = min(maxWidth, usedRect.width + padding)
        let height = min(max(usedRect.height + verticalPadding, 30), 400)
        return NSSize(width: max(width, 100), height: height)
    }
}
