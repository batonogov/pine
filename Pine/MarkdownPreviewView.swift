//
//  MarkdownPreviewView.swift
//  Pine
//

import SwiftUI

/// Renders Markdown content as a read-only attributed string in a scrollable NSTextView.
struct MarkdownPreviewView: NSViewRepresentable {
    let content: String
    var focusRequestID: UUID?
    var canAttemptFocusRequest: ((UUID) -> Bool)?
    var onFocusRequestResult: ((UUID, Bool) -> Void)?

    func makeNSView(context: Context) -> MarkdownPreviewScrollView {
        let scrollView = MarkdownPreviewScrollView()
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
        scrollView.destinationFocusCoordinator.update(
            requestID: focusRequestID,
            hostView: scrollView,
            targetView: textView,
            canAttempt: canAttemptFocusRequest,
            onResult: onFocusRequestResult
        )

        return scrollView
    }

    func updateNSView(_ scrollView: MarkdownPreviewScrollView, context: Context) {
        context.coordinator.scheduleRender(content: content)
        scrollView.destinationFocusCoordinator.update(
            requestID: focusRequestID,
            hostView: scrollView,
            targetView: context.coordinator.textView,
            canAttempt: canAttemptFocusRequest,
            onResult: onFocusRequestResult
        )
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
            DispatchQueue.main.asyncAfter(deadline: .now() + UITimings.Delay.standard, execute: workItem)
        }
    }
}

final class MarkdownPreviewScrollView: NSScrollView {
    let destinationFocusCoordinator = AppKitFocusRequestCoordinator()

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        destinationFocusCoordinator.hostDidMoveToWindow(self)
    }
}
