//
//  RenamePopover.swift
//  Pine
//
//  Phase 5 of LSP support (milestone #1088, item 1).
//
//  A lightweight popover that shows a text field for renaming a symbol.
//  The user types the new name and presses Enter to confirm, or Esc to
//  cancel. On confirm, the coordinator calls LSPManager.rename() and
//  applies the resulting WorkspaceEdit.
//

import AppKit

/// `@MainActor @Observable` controller for the rename popover.
@MainActor
@Observable
final class RenameController {

    /// Whether the rename popover is currently visible.
    private(set) var isVisible: Bool = false

    /// The current text in the rename field.
    var newName: String = ""

    /// The original symbol name (prefilled in the field).
    var originalName: String = ""

    /// Called when the user confirms the rename with a new name.
    var onConfirm: ((String) -> Void)?

    /// Called when the user cancels the rename.
    var onCancel: (() -> Void)?

    init() {}

    // MARK: - Presentation

    /// Presents the rename popover with the symbol's current name prefilled.
    /// The name is selected so the user can type over it immediately.
    func present(originalName: String) {
        self.originalName = originalName
        self.newName = originalName
        isVisible = true
    }

    /// Hides the popover.
    func dismiss() {
        isVisible = false
        newName = ""
        originalName = ""
    }

    // MARK: - Actions

    func confirm() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != originalName else {
            dismiss()
            return
        }
        let captured = name
        dismiss()
        onConfirm?(captured)
    }

    func cancel() {
        dismiss()
        onCancel?()
    }
}

/// AppKit container for the rename popover — hosts a text field with
/// Enter-to-confirm and Esc-to-cancel.
///
/// `@MainActor` because NSPopover and NSTextField must be manipulated on the
/// main thread.
@MainActor
final class RenamePopoverManager {

    /// The underlying popover.
    private var popover: NSPopover?

    /// The text field inside the popover.
    private var textField: NSTextField?

    /// Whether the popover is currently shown.
    var isVisible: Bool { popover?.isShown ?? false }

    init() {}

    // MARK: - Show

    /// Shows the rename popover anchored at `anchorRect` (in screen
    /// coordinates) with `currentName` prefilled and selected.
    func show(
        currentName: String,
        anchorRect: NSRect,
        positioningView: NSView,
        onConfirm: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        let pop = ensurePopover(onConfirm: onConfirm, onCancel: onCancel)
        guard let textField else { return }

        textField.stringValue = currentName
        textField.selectText(nil)
        // Select the entire name so the user can type over it.
        let currentEditor = textField.currentEditor()
        currentEditor?.selectedRange = NSRange(location: 0, length: currentName.utf16.count)

        let positionRect = positioningView.convert(anchorRect, from: nil)
        pop.show(relativeTo: positionRect, of: positioningView, preferredEdge: .maxY)

        // Focus the text field.
        DispatchQueue.main.async { [weak self] in
            guard let self, let pop = self.popover, pop.isShown else { return }
            self.textField?.window?.makeFirstResponder(self.textField)
        }
    }

    /// Hides the popover if visible.
    func hide() {
        guard let popover, popover.isShown else { return }
        popover.performClose(nil)
    }

    // MARK: - Lazy creation

    private var confirmCallback: ((String) -> Void)?
    private var cancelCallback: (() -> Void)?

    private func ensurePopover(
        onConfirm: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) -> NSPopover {
        self.confirmCallback = onConfirm
        self.cancelCallback = onCancel

        if let popover { return popover }

        let pop = NSPopover()
        pop.behavior = .transient
        pop.animates = true

        let viewController = NSViewController()
        let container = NSView()
        container.wantsLayer = true

        let label = NSTextField(labelWithString: "Rename symbol to:")
        label.font = NSFont.systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor

        let field = NSTextField(frame: .zero)
        field.font = NSFont.systemFont(ofSize: 13)
        field.placeholderString = "New name"
        field.delegate = self
        field.target = self
        field.action = #selector(fieldAction(_:))

        let stackView = NSStackView(views: [label, field])
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 4
        stackView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            stackView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
            stackView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            stackView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 200)
        ])

        viewController.view = container
        pop.contentViewController = viewController

        self.textField = field
        self.popover = pop
        return pop
    }
}

// MARK: - NSTextFieldDelegate

extension RenamePopoverManager: NSTextFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            let name = textField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            hide()
            if !name.isEmpty {
                confirmCallback?(name)
            } else {
                cancelCallback?()
            }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            hide()
            cancelCallback?()
            return true
        default:
            return false
        }
    }

    @objc private func fieldAction(_ sender: NSTextField) {
        // Enter key triggers action on the text field.
        let name = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        hide()
        if !name.isEmpty {
            confirmCallback?(name)
        } else {
            cancelCallback?()
        }
    }
}
