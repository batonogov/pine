//
//  CommandOverlayWindow.swift
//  Pine
//
//  Lightweight `NSPanel` that hosts command-overlay content (Quick Open,
//  Symbol Navigator, Go to Line, Command Palette) as a real window so the
//  hosted SwiftUI views get a complete accessibility tree (#975).
//
//  Why a window and not SwiftUI `.overlay`:
//    PR #986 migrated the navigation flows to `CommandOverlayView` (a SwiftUI
//    ZStack overlay) but had to revert because the overlay's inner TextFields
//    were not reliably exposed to XCUITest / VoiceOver on macOS 26 — a ZStack
//    overlay lives in the same accessibility tree as the document and SwiftUI
//    collapsed/obscured the hosted fields under `.isModal`. A real `NSPanel`
//    (like `.sheet` and `NSPopover`) creates its own accessibility subtree, so
//    role-based queries (`app.textFields[id]`, VoiceOver navigation) resolve
//    the hosted content reliably while remaining non-document-modal.
//

import AppKit
import SwiftUI

/// A borderless, non-activating-but-key `NSPanel` used to present command
/// overlays. Mimics `.sheet`'s accessibility guarantees without stealing the
/// document window or blocking interaction behind a modal stack.
@MainActor
final class CommandOverlayPanel: NSPanel {

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.isMovable = false
        self.hidesOnDeactivate = false
        self.level = .floating
        self.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces]
        // The panel becomes key so the hosted search field can receive
        // keyboard focus, but does not activate the app away from the
        // document window that owns it.
        self.becomesKeyOnlyIfNeeded = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Bridges a SwiftUI overlay view into a `CommandOverlayPanel` window.
///
/// When `isPresented` flips to `true`, a panel is created and shown above the
/// owner window's content. When it flips to `false`, the panel closes and the
/// window reference is released. The hosted SwiftUI view is wrapped in an
/// `NSHostingController`, giving it the same accessibility surface as a sheet.
struct CommandOverlayWindow<Content: View>: NSViewRepresentable {

    @Binding var isPresented: Bool
    let containerIdentifier: String
    @ViewBuilder var content: () -> Content

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.alphaValue = 0
        context.coordinator.hostView = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.parent = self
        guard let window = nsView.window else { return }
        context.coordinator.ownerWindow = window

        if isPresented {
            context.coordinator.presentIfNeeded(
                ownerWindow: window,
                content: content
            )
            // Keep the hosted content fresh across SwiftUI updates.
            context.coordinator.updateContent(content)
        } else {
            context.coordinator.dismiss()
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.dismiss()
    }

    @MainActor
    final class Coordinator: NSObject, NSWindowDelegate {

        var parent: CommandOverlayWindow
        weak var hostView: NSView?
        weak var ownerWindow: NSWindow?
        weak var panel: CommandOverlayPanel?
        var hostingController: NSHostingController<ContentWrapper>?

        init(parent: CommandOverlayWindow) {
            self.parent = parent
        }

        func presentIfNeeded(
            ownerWindow: NSWindow,
            content: () -> Content
        ) {
            guard panel == nil else { return }

            let wrapper = ContentWrapper(
                content: content(),
                containerIdentifier: parent.containerIdentifier
            )
            let controller = NSHostingController(rootView: wrapper)
            controller.view.frame = NSRect(x: 0, y: 0, width: 520, height: 380)
            self.hostingController = controller

            let panel = CommandOverlayPanel(
                contentRect: controller.view.bounds
            )
            panel.contentViewController = controller
            panel.delegate = self
            panel.contentView = controller.view
            self.panel = panel

            position(panel: panel, above: ownerWindow)
            ownerWindow.addChildWindow(panel, ordered: .above)
            panel.makeKeyAndOrderFront(nil)
        }

        func updateContent(_ content: () -> Content) {
            guard let controller = hostingController else { return }
            controller.rootView = ContentWrapper(
                content: content(),
                containerIdentifier: parent.containerIdentifier
            )
        }

        func dismiss() {
            guard let panel else { return }
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
            panel.delegate = nil
            self.panel = nil
            hostingController = nil
        }

        private func position(panel: NSPanel, above ownerWindow: NSWindow) {
            let ownerFrame = ownerWindow.frame
            let panelSize = panel.frame.size
            // Center horizontally; sit slightly above vertical center, like
            // a command palette (VS Code, Raycast).
            let centerX = ownerFrame.midX - panelSize.width / 2
            let centerY = ownerFrame.midY - panelSize.height / 2
                + ownerFrame.height * 0.12
            panel.setFrame(
                NSRect(
                    x: centerX,
                    y: max(ownerFrame.minY + 20, centerY),
                    width: panelSize.width,
                    height: panelSize.height
                ),
                display: true
            )
        }

        // MARK: - NSWindowDelegate

        func windowDidResignKey(_ notification: Notification) {
            // The owner window regaining key (user clicked the document) closes
            // the non-modal overlay, matching `.sheet`'s click-outside-to-cancel
            // behavior without a backdrop.
            guard let panel = notification.object as? NSPanel,
                  panel === self.panel else { return }
            parent.isPresented = false
        }
    }

    /// Wrapper that paints the translucent backdrop + card and exposes a stable
    /// container accessibility identifier for VoiceOver / XCUITest.
    struct ContentWrapper: View {
        let content: Content
        let containerIdentifier: String

        var body: some View {
            ZStack {
                Color.primary.opacity(0.15)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        NotificationCenter.default.post(
                            name: .commandOverlayDismissRequested,
                            object: nil
                        )
                    }

                content
                    .background {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(.regularMaterial)
                            .shadow(color: .black.opacity(0.2), radius: 24, y: 6)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(containerIdentifier)
            .accessibilityAddTraits(.isModal)
        }
    }
}

extension Notification.Name {
    /// Posted by the overlay's backdrop tap so the router can dismiss without
    /// mutating document state. Observed by `CommandOverlayContainer`.
    static let commandOverlayDismissRequested = Notification.Name(
        "commandOverlayDismissRequested"
    )
}
