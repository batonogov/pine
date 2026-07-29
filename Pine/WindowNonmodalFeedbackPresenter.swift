//
//  WindowNonmodalFeedbackPresenter.swift
//  Pine
//
//  Shared visible, non-blocking feedback for app-owned windows that do not
//  have a ProjectManager/ToastManager (Welcome and Settings).
//

import AppKit

@MainActor
protocol WindowNonmodalFeedbackPresenting {
    /// Shows feedback without activating a modal session or attaching a
    /// sheet. Returns false when there is no suitable live owner.
    @discardableResult
    func present(
        message: String,
        context: DialogPresentationContext
    ) -> Bool
}

/// Presents a compact non-activating child panel near the top of its owner.
/// The panel is deliberately window-scoped, ignores input, and auto-dismisses
/// so success feedback never blocks another command.
@MainActor
final class WindowNonmodalFeedbackPresenter:
    WindowNonmodalFeedbackPresenting {
    static let shared = WindowNonmodalFeedbackPresenter()

    private final class Presentation {
        weak var owner: NSWindow?
        let panel: NSPanel
        var dismissalTask: Task<Void, Never>?
        var closeObserver: Any?

        init(owner: NSWindow, panel: NSPanel) {
            self.owner = owner
            self.panel = panel
        }
    }

    private var presentations: [ObjectIdentifier: Presentation] = [:]
    private let displayDuration: Duration

    init(displayDuration: Duration = .seconds(3)) {
        self.displayDuration = displayDuration
    }

    @discardableResult
    func present(
        message: String,
        context: DialogPresentationContext
    ) -> Bool {
        let accessibilityElement: Any
        defer {
            NSAccessibility.post(
                element: accessibilityElement,
                notification: .announcementRequested,
                userInfo: [.announcement: message]
            )
        }

        guard let owner = context.nsWindow,
              owner.isVisible,
              !owner.isMiniaturized else {
            accessibilityElement = NSApplication.shared
            return false
        }
        accessibilityElement = owner

        dismiss(for: owner)
        let panel = makePanel(message: message)
        let identifier = ObjectIdentifier(owner)
        let presentation = Presentation(owner: owner, panel: panel)
        presentations[identifier] = presentation
        presentation.closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: owner,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.dismiss(identifier: identifier)
            }
        }

        owner.addChildWindow(panel, ordered: .above)
        position(panel, in: owner)
        panel.orderFront(nil)
        presentation.dismissalTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: self?.displayDuration ?? .seconds(3))
            guard !Task.isCancelled, let self else { return }
            self.dismiss(identifier: identifier)
        }
        return true
    }

    func dismiss(for owner: NSWindow) {
        dismiss(identifier: ObjectIdentifier(owner))
    }

    private func dismiss(identifier: ObjectIdentifier) {
        guard let presentation = presentations.removeValue(
            forKey: identifier
        ) else {
            return
        }
        presentation.dismissalTask?.cancel()
        if let closeObserver = presentation.closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
        }
        if let owner = presentation.owner,
           presentation.panel.parent === owner {
            owner.removeChildWindow(presentation.panel)
        }
        presentation.panel.orderOut(nil)
        presentation.panel.close()
    }

    func hasVisibleFeedback(for owner: NSWindow) -> Bool {
        presentations[ObjectIdentifier(owner)]?.panel.isVisible == true
    }

    private func makePanel(message: String) -> NSPanel {
        let text = NSTextField(wrappingLabelWithString: message)
        text.alignment = .center
        text.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        text.textColor = .labelColor
        text.maximumNumberOfLines = 3
        text.translatesAutoresizingMaskIntoConstraints = false

        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
        effect.layer?.masksToBounds = true
        effect.setAccessibilityElement(true)
        effect.setAccessibilityLabel(message)
        effect.addSubview(text)
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 16),
            text.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -16),
            text.topAnchor.constraint(equalTo: effect.topAnchor, constant: 10),
            text.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -10),
            text.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
        ])

        let fittingSize = effect.fittingSize
        let panel = NSPanel(
            contentRect: NSRect(
                origin: .zero,
                size: NSSize(
                    width: max(220, fittingSize.width),
                    height: max(44, fittingSize.height)
                )
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = effect
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        return panel
    }

    private func position(_ panel: NSPanel, in owner: NSWindow) {
        let ownerFrame = owner.frame
        let panelSize = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: ownerFrame.midX - panelSize.width / 2,
            y: ownerFrame.maxY - panelSize.height - 56
        ))
    }
}
