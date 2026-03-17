//
//  MarkdownPreviewView.swift
//  Pine
//

import SwiftUI

/// Renders Markdown content as a read-only attributed string in a scrollable NSTextView.
struct MarkdownPreviewView: NSViewRepresentable {
    let content: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isAutomaticLinkDetectionEnabled = false
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 20, height: 20)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        scrollView.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.scheduleRender(content: content)

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.scheduleRender(content: content)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        weak var textView: NSTextView?
        private let renderer = MarkdownRenderer()
        private var pendingContent: String?
        private var renderWorkItem: DispatchWorkItem?

        func scheduleRender(content: String) {
            renderWorkItem?.cancel()
            pendingContent = content

            let workItem = DispatchWorkItem { [weak self] in
                guard let self, let content = self.pendingContent else { return }
                self.pendingContent = nil
                let attributed = self.renderer.render(content)
                self.textView?.textStorage?.setAttributedString(attributed)
            }
            renderWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: workItem)
        }
    }
}
