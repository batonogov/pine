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

/// Immutable configuration shared by `CommandOverlayPanel` construction and
/// model-level tests. Keeping this value separate lets tests validate the
/// macOS 26 key-window requirements without repeatedly constructing NSPanel
/// instances inside the Swift Testing host.
struct CommandOverlayPanelConfiguration {
    let styleMask: NSWindow.StyleMask
    let collectionBehavior: NSWindow.CollectionBehavior
    let canBecomeKey: Bool
    let canBecomeMain: Bool

    static let overlay = CommandOverlayPanelConfiguration(
        styleMask: [
            .borderless,
            .nonactivatingPanel,
            .titled,
            .fullSizeContentView
        ],
        collectionBehavior: [.fullScreenAuxiliary, .ignoresCycle],
        canBecomeKey: true,
        canBecomeMain: false
    )
}

/// A borderless, non-activating-but-key `NSPanel` used to present command
/// overlays. Mimics `.sheet`'s accessibility guarantees without stealing the
/// document window or blocking interaction behind a modal stack.
@MainActor
final class CommandOverlayPanel: NSPanel {

    /// The document window that owns this command overlay.
    ///
    /// Keep this explicit instead of relying solely on `parent`: AppKit can
    /// clear the child-window relationship while the outgoing panel is still
    /// key and event routing still needs to resolve the originating document.
    private(set) weak var documentOwner: NSWindow?
    var onCancel: (() -> Void)?

    init(contentRect: NSRect, documentOwner: NSWindow?) {
        let configuration = CommandOverlayPanelConfiguration.overlay
        self.documentOwner = documentOwner
        super.init(
            contentRect: contentRect,
            styleMask: configuration.styleMask,
            backing: .buffered,
            defer: false
        )
        // A titled style is required for a borderless NSPanel to become key on
        // macOS 26. Hide the titlebar chrome while preserving key-window
        // eligibility for the hosted search field.
        self.titleVisibility = .hidden
        self.titlebarAppearsTransparent = true
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.isMovable = false
        self.hidesOnDeactivate = false
        self.isReleasedWhenClosed = false
        // This is a document child, not a global utility panel. Joining every
        // Space would expose one project's overlay above unrelated windows.
        self.collectionBehavior = configuration.collectionBehavior
        // The panel becomes key so the hosted search field can receive
        // keyboard focus, but does not activate the app away from the
        // document window that owns it.
        self.becomesKeyOnlyIfNeeded = false
    }

    /// Updates the explicit owner used by command routing.
    ///
    /// The coordinator normally establishes this relationship at creation.
    /// Keeping the binding independent from AppKit's child-window relationship
    /// also makes owner resolution deterministic while a panel is closing.
    func bindDocumentOwner(_ owner: NSWindow?) {
        documentOwner = owner
    }

    override var canBecomeKey: Bool {
        CommandOverlayPanelConfiguration.overlay.canBecomeKey
    }

    override var canBecomeMain: Bool {
        CommandOverlayPanelConfiguration.overlay.canBecomeMain
    }

    override func cancelOperation(_ sender: Any?) {
        guard let onCancel else {
            super.cancelOperation(sender)
            return
        }
        onCancel()
    }
}

/// Resolves the document window while a command panel owns key focus.
///
/// User keybindings are dispatched from an AppDelegate event monitor that
/// normally identifies the active project through the key window's
/// `CloseDelegate`. A command panel has its own coordinator delegate, so the
/// monitor must unwrap this specific child-window type to its document owner.
@MainActor
enum CommandOverlayOwnerResolver {
    static func documentWindow(for keyWindow: NSWindow?) -> NSWindow? {
        guard let keyWindow else { return nil }
        guard let panel = keyWindow as? CommandOverlayPanel else {
            return keyWindow
        }
        return preferredDocumentOwner(
            explicitOwner: panel.documentOwner,
            parent: panel.parent
        )
    }

    /// Pure owner-precedence seam. The generic form avoids constructing AppKit
    /// windows merely to verify that the explicit document owner wins over
    /// AppKit's transient child-window parent relationship.
    static func preferredDocumentOwner<Window>(
        explicitOwner: Window?,
        parent: Window?
    ) -> Window? {
        explicitOwner ?? parent
    }
}

/// Invisible representable host that reports every AppKit window attachment.
///
/// SwiftUI may call `updateNSView` before the representable has entered a
/// window. There is no guaranteed follow-up update after AppKit attaches the
/// view, so presentation must also be driven by `viewDidMoveToWindow`.
@MainActor
final class CommandOverlayAttachmentView: NSView {
    var onWindowChange: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?(window)
    }
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
    let onDocumentOwnerResolved: @MainActor (NSWindow) -> Void
    let onExternalFocusChange: @MainActor () -> Void
    @ViewBuilder var content: () -> Content

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> CommandOverlayAttachmentView {
        let view = CommandOverlayAttachmentView(frame: .zero)
        view.alphaValue = 0
        let coordinator = context.coordinator
        view.onWindowChange = { [weak coordinator] ownerWindow in
            coordinator?.sync(ownerWindow: ownerWindow)
        }
        context.coordinator.hostView = view
        return view
    }

    func updateNSView(
        _ nsView: CommandOverlayAttachmentView,
        context: Context
    ) {
        context.coordinator.parent = self
        context.coordinator.sync(ownerWindow: nsView.window)
    }

    static func dismantleNSView(
        _ nsView: CommandOverlayAttachmentView,
        coordinator: Coordinator
    ) {
        nsView.onWindowChange = nil
        coordinator.hostView = nil
        coordinator.ownerWindow = nil
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

        /// Reconciles the SwiftUI presentation state with the current AppKit
        /// host. Called both from SwiftUI updates and the guaranteed AppKit
        /// window-attachment lifecycle callback.
        func sync(ownerWindow: NSWindow?) {
            if self.ownerWindow !== ownerWindow {
                dismiss()
            }
            self.ownerWindow = ownerWindow

            guard let ownerWindow else {
                dismiss()
                return
            }
            guard parent.isPresented else {
                dismiss()
                return
            }

            let didPresent = presentIfNeeded(
                ownerWindow: ownerWindow,
                content: parent.content
            )
            guard !didPresent else { return }
            // Keep the hosted content fresh across SwiftUI updates.
            updateContent(parent.content)
        }

        func presentIfNeeded(
            ownerWindow: NSWindow,
            content: () -> Content
        ) -> Bool {
            guard panel == nil else { return false }

            // Capture focus from this representable's actual document window
            // before the child panel becomes key. `NSApp.keyWindow` can belong
            // to another project when a targeted command addresses a
            // background window.
            parent.onDocumentOwnerResolved(ownerWindow)

            let wrapper = ContentWrapper(
                content: content(),
                containerIdentifier: parent.containerIdentifier,
                onDismiss: { [weak self] in
                    self?.parent.isPresented = false
                }
            )
            let controller = NSHostingController(rootView: wrapper)
            let panelSize = targetSize(
                for: controller,
                ownerWindow: ownerWindow
            )
            controller.view.frame = NSRect(origin: .zero, size: panelSize)
            self.hostingController = controller

            let panel = CommandOverlayPanel(
                contentRect: controller.view.bounds,
                documentOwner: ownerWindow
            )
            panel.identifier = NSUserInterfaceItemIdentifier(
                parent.containerIdentifier
            )
            panel.setAccessibilityIdentifier(parent.containerIdentifier)
            panel.level = ownerWindow.level
            panel.contentViewController = controller
            panel.delegate = self
            panel.onCancel = { [weak self, weak panel] in
                guard let self, panel === self.panel else { return }
                self.parent.isPresented = false
            }
            self.panel = panel

            position(panel: panel, above: ownerWindow)
            ownerWindow.addChildWindow(panel, ordered: .above)
            panel.makeKeyAndOrderFront(nil)
            controller.view.layoutSubtreeIfNeeded()
            initialFocusField(in: controller.view)?.requestInitialFocus()
            return true
        }

        func updateContent(_ content: () -> Content) {
            guard let controller = hostingController else { return }
            controller.rootView = ContentWrapper(
                content: content(),
                containerIdentifier: parent.containerIdentifier,
                onDismiss: { [weak self] in
                    self?.parent.isPresented = false
                }
            )
            guard let panel, let ownerWindow else { return }
            let panelSize = targetSize(
                for: controller,
                ownerWindow: ownerWindow
            )
            panel.setContentSize(panelSize)
            controller.view.frame = NSRect(origin: .zero, size: panelSize)
            position(panel: panel, above: ownerWindow)
        }

        func dismiss() {
            guard let panel else { return }
            // Clear the delegate before ordering out. A resign-key callback
            // from an obsolete panel must not dismiss a newer presentation.
            panel.delegate = nil
            panel.onCancel = nil
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
            panel.contentViewController = nil
            panel.close()
            self.panel = nil
            hostingController = nil
        }

        private func initialFocusField(
            in view: NSView
        ) -> CommandOverlayTextField? {
            if let field = view as? CommandOverlayTextField {
                return field
            }
            for subview in view.subviews {
                if let field = initialFocusField(in: subview) {
                    return field
                }
            }
            return nil
        }

        private func targetSize(
            for controller: NSHostingController<ContentWrapper>,
            ownerWindow: NSWindow
        ) -> NSSize {
            let ownerSize = ownerWindow.contentLayoutRect.size
            let maximumSize = NSSize(
                width: max(1, ownerSize.width - 32),
                height: max(1, ownerSize.height - 48)
            )
            let fittingSize = controller.sizeThatFits(in: maximumSize)
            let minimumSize = NSSize(
                width: min(240, maximumSize.width),
                height: min(140, maximumSize.height)
            )
            return NSSize(
                width: min(
                    maximumSize.width,
                    max(minimumSize.width, fittingSize.width)
                ),
                height: min(
                    maximumSize.height,
                    max(minimumSize.height, fittingSize.height)
                )
            )
        }

        private func position(panel: NSPanel, above ownerWindow: NSWindow) {
            let ownerFrame = ownerWindow.frame
            let panelSize = panel.frame.size
            // Center horizontally; sit slightly above vertical center, like
            // a command palette (VS Code, Raycast).
            let centerX = ownerFrame.midX - panelSize.width / 2
            let centerY = ownerFrame.midY - panelSize.height / 2
                + ownerFrame.height * 0.12
            let minimumY = ownerFrame.minY + 20
            let maximumY = max(
                minimumY,
                ownerFrame.maxY - panelSize.height - 20
            )
            panel.setFrame(
                NSRect(
                    x: centerX,
                    y: min(maximumY, max(minimumY, centerY)),
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
            // behavior without a backdrop. Focus has already moved, so this
            // path must not restore the responder captured before presentation.
            guard let panel = notification.object as? NSPanel,
                  panel === self.panel else { return }
            parent.onExternalFocusChange()
        }
    }

    /// Wrapper that paints the translucent backdrop + card and exposes a stable
    /// container accessibility identifier for VoiceOver / XCUITest.
    struct ContentWrapper: View {
        let content: Content
        let containerIdentifier: String
        let onDismiss: () -> Void

        var body: some View {
            ZStack {
                Color.primary.opacity(0.15)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onDismiss)
                    .accessibilityHidden(true)

                content
                    .background {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(.regularMaterial)
                            .shadow(color: .black.opacity(0.2), radius: 24, y: 6)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(10)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(containerIdentifier)
            .accessibilityAddTraits(.isModal)
            .onExitCommand(perform: onDismiss)
        }
    }
}
