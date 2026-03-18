//
//  BranchSubtitleClickHandler.swift
//  Pine
//
//  Makes the window subtitle (branch name) clickable.
//  Clicking shows a popover with BranchSwitcherView anchored to the subtitle.
//  Works around toolbarTitleMenu not functioning on macOS 26.
//

import AppKit
import SwiftUI

struct BranchSubtitleClickHandler: NSViewRepresentable {
    var gitProvider: GitStatusProvider
    var isGitRepository: Bool

    final class Coordinator: NSObject, NSPopoverDelegate {
        var parent: BranchSubtitleClickHandler
        weak var gestureTarget: NSTextField?
        var popover: NSPopover?

        init(parent: BranchSubtitleClickHandler) {
            self.parent = parent
        }

        @objc func subtitleClicked(_ sender: NSClickGestureRecognizer) {
            guard let view = sender.view else { return }

            // If popover is already shown, close it.
            if let popover, popover.isShown {
                popover.close()
                return
            }

            let isPresented = Binding<Bool>(
                get: { [weak self] in self?.popover?.isShown ?? false },
                set: { [weak self] newValue in
                    if !newValue { self?.popover?.close() }
                }
            )

            let content = BranchSwitcherView(
                gitProvider: parent.gitProvider,
                isPresented: isPresented
            )

            let hostingController = NSHostingController(rootView: content)
            hostingController.preferredContentSize = NSSize(width: 280, height: 340)

            let pop = NSPopover()
            pop.contentViewController = hostingController
            pop.behavior = .transient
            pop.delegate = self
            pop.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
            self.popover = pop
        }

        func popoverDidClose(_ notification: Notification) {
            popover = nil
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.alphaValue = 0
        // Delayed install — titlebar views may not exist yet at first layout.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard let window = view.window else { return }
            self.installIfNeeded(in: window, coordinator: context.coordinator)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.parent = self
        guard isGitRepository else { return }

        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            self.installIfNeeded(in: window, coordinator: context.coordinator)
        }
    }

    private func installIfNeeded(in window: NSWindow, coordinator: Coordinator) {
        // If gesture target is still valid, skip re-install.
        if let target = coordinator.gestureTarget,
           target.window != nil,
           !target.gestureRecognizers.isEmpty {
            return
        }

        guard let themeFrame = window.contentView?.superview else { return }
        let subtitle = window.subtitle
        guard !subtitle.isEmpty else { return }

        if let subtitleField = Self.findSubtitleLabel(in: themeFrame, subtitle: subtitle) {
            // Clear any previously installed gesture recognizers.
            subtitleField.gestureRecognizers.removeAll()

            let gesture = NSClickGestureRecognizer(
                target: coordinator,
                action: #selector(Coordinator.subtitleClicked(_:))
            )
            subtitleField.addGestureRecognizer(gesture)

            // Show pointing-hand cursor on hover to hint clickability.
            subtitleField.resetCursorRects()
            subtitleField.addCursorRect(subtitleField.bounds, cursor: .pointingHand)

            coordinator.gestureTarget = subtitleField
        }
    }

    private static func findSubtitleLabel(in view: NSView, subtitle: String) -> NSTextField? {
        for subview in view.subviews {
            if let textField = subview as? NSTextField,
               textField.stringValue == subtitle {
                return textField
            }
            if let found = findSubtitleLabel(in: subview, subtitle: subtitle) {
                return found
            }
        }
        return nil
    }
}
