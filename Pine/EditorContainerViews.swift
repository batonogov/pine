//
//  EditorContainerViews.swift
//  Pine
//
//  Extracted from CodeEditorView.swift on 2026-04-09 (issue #755).
//
//  Hosts the two AppKit container views that make up the editor layout:
//    • EditorScrollView — NSScrollView subclass that tracks the find-bar
//      height after tile() and pushes contentView below the overlay on
//      macOS 26.
//    • EditorContainerView — NSView that lays out the scroll view,
//      LineNumberView, and MinimapView side by side without relying on
//      autoresizingMask.
//
//  Also hosts GoToRequest — the unique navigation request value used by
//  CodeEditorView's updateNSView to scroll to a specific offset exactly once.
//

import AppKit

// MARK: - Editor scroll view with find bar height tracking

/// NSScrollView subclass that detects the find bar height after tile() layout.
/// On macOS 26 with Liquid Glass the find bar overlays content without resizing
/// contentView, so we compute the offset by scanning subviews for NSTextFinder's bar.
final class EditorScrollView: NSScrollView {
    /// Height of the find bar (0 when hidden). Updated after every tile().
    private(set) var findBarOffset: CGFloat = 0

    override func tile() {
        super.tile()
        let newOffset = findBarHeight()
        if abs(newOffset - findBarOffset) > 0.5 {
            findBarOffset = newOffset
            superview?.needsLayout = true
        }
        // On macOS 26 the find bar overlays content without resizing contentView.
        // Manually shrink and offset contentView to push text below the find bar.
        if findBarOffset > 0 {
            var cvFrame = contentView.frame
            if cvFrame.origin.y < findBarOffset {
                let savedBounds = contentView.bounds
                cvFrame.origin.y = findBarOffset
                cvFrame.size.height = bounds.height - findBarOffset
                contentView.frame = cvFrame
                contentView.bounds.origin = savedBounds.origin
            }
        }
    }

    /// Scans scrollView subviews for the find bar and returns its height.
    private func findBarHeight() -> CGFloat {
        // The find bar is an NSView added by NSTextFinder as a direct subview
        // of the scroll view, distinct from contentView and scrollers.
        for sub in subviews {
            if sub === contentView { continue }
            if sub === verticalScroller { continue }
            if sub === horizontalScroller { continue }
            let className = String(describing: type(of: sub))
            if className.contains("Find") || className.contains("find") {
                return sub.frame.height
            }
        }
        return 0
    }
}

// MARK: - Editor container that manages scroll view + minimap layout

/// Custom container view that lays out the scroll view and minimap side by side.
/// Replaces autoresizingMask with explicit layout so the minimap width is
/// always accounted for.
final class EditorContainerView: NSView {
    // Match NSScrollView's flipped coordinate system for correct find bar clipping
    override var isFlipped: Bool { true }
    var minimapWidth: CGFloat = 0

    override func layout() {
        super.layout()
        let findBarOffset = (subviews.compactMap { $0 as? EditorScrollView }.first)?.findBarOffset ?? 0
        for sub in subviews {
            if let minimap = sub as? MinimapView {
                if minimap.isHidden {
                    continue
                }
                minimap.frame = NSRect(
                    x: bounds.width - minimapWidth,
                    y: 0,
                    width: minimapWidth,
                    height: bounds.height
                )
                minimap.needsDisplay = true
            } else if sub is NSScrollView {
                sub.frame = NSRect(
                    x: 0, y: 0,
                    width: bounds.width - minimapWidth,
                    height: bounds.height
                )
            } else {
                // LineNumberView — offset below the find bar when Cmd+F is open.
                sub.frame = NSRect(
                    x: 0, y: findBarOffset,
                    width: sub.frame.width,
                    height: bounds.height - findBarOffset
                )
            }
        }
    }
}

// MARK: - Navigation request

/// A unique navigation request so each "go to" action is processed exactly once.
/// Each instance gets a unique `id`, so two requests to the same offset are distinct.
struct GoToRequest {
    let offset: Int
    let id: UUID = UUID()
}
