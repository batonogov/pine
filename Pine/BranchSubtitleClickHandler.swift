//
//  BranchSubtitleClickHandler.swift
//  Pine
//
//  Makes the window subtitle (branch name) clickable, showing an NSMenu
//  with all branches. Works around toolbarTitleMenu not functioning on macOS 26.
//

import AppKit
import SwiftUI

struct BranchSubtitleClickHandler: NSViewRepresentable {
    var branches: [String]
    var currentBranch: String
    var isGitRepository: Bool
    var onSwitchBranch: (String) -> Void

    final class Coordinator: NSObject {
        var parent: BranchSubtitleClickHandler
        weak var gestureTarget: NSTextField?

        init(parent: BranchSubtitleClickHandler) {
            self.parent = parent
        }

        @objc func subtitleClicked(_ sender: NSClickGestureRecognizer) {
            guard let view = sender.view else { return }
            let menu = NSMenu()
            for branch in parent.branches {
                let item = NSMenuItem(
                    title: branch,
                    action: #selector(branchSelected(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                if branch == parent.currentBranch {
                    item.state = .on
                }
                menu.addItem(item)
            }
            menu.popUp(
                positioning: nil,
                at: NSPoint(x: 0, y: view.bounds.height + 4),
                in: view
            )
        }

        @objc func branchSelected(_ sender: NSMenuItem) {
            parent.onSwitchBranch(sender.title)
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
