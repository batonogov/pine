//
//  TerminalSearchField.swift
//  Pine
//
//  AppKit-backed query field for the terminal search bar (issue #1523).
//

import AppKit
import SwiftUI

/// Keyboard commands the terminal search field answers.
///
/// Mapping lives here, as a pure function of the field-editor selector and
/// the shift modifier, so the binding can be verified without a window, a
/// live field editor, or a synthesised `NSEvent`.
enum TerminalSearchFieldCommand: Equatable {
    case findNext
    case findPrevious
    case dismiss

    /// Returns the command for an AppKit field-editor selector, or `nil` when
    /// the key is none of the search bar's business and must keep its default
    /// text-editing behaviour.
    static func forSelector(
        _ selector: Selector,
        shiftPressed: Bool
    ) -> TerminalSearchFieldCommand? {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)),
             #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            // Return walks the matches forward, Shift+Return backward. The
            // second selector is included because AppKit routes a modified
            // Return through it under some key-binding configurations.
            return shiftPressed ? .findPrevious : .findNext
        case #selector(NSResponder.cancelOperation(_:)):
            return .dismiss
        default:
            return nil
        }
    }
}

/// `NSTextField` that owns the focus request bridging SwiftUI's search state
/// to AppKit's first responder.
///
/// SwiftTerm's terminal view is a sibling `NSView` in the same window and
/// holds first responder for the pane. SwiftUI focus does not reliably take
/// it away from an AppKit view that never gives it up, so the field claims
/// first responder itself — the same approach `WelcomeSearchField` already
/// uses for the recent-projects filter.
final class TerminalSearchFieldView: NSTextField {
    /// Retains the claim until AppKit can actually evaluate it: the field is
    /// created in the same SwiftUI pass that reveals the bar and is not in a
    /// window yet on the first `updateNSView`.
    let focusCoordinator = AppKitFocusRequestCoordinator()

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        focusCoordinator.hostDidMoveToWindow(self)
    }
}

/// SwiftUI wrapper for the terminal search query field.
struct TerminalSearchField: NSViewRepresentable {
    @Binding var text: String
    /// Non-nil while the bar is asking for first responder. Each ⌘F issues a
    /// fresh identity so a repeat press re-focuses an already open bar.
    var focusRequestID: UUID?
    var onCommand: (TerminalSearchFieldCommand) -> Void
    var onFocusResult: (UUID, Bool) -> Void

    func makeNSView(context: Context) -> TerminalSearchFieldView {
        let field = TerminalSearchFieldView()
        field.delegate = context.coordinator
        field.placeholderString = Strings.terminalSearchPlaceholderString
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        // Let the surrounding HStack drive the width instead of the query text.
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setAccessibilityIdentifier(AccessibilityID.terminalSearchField)
        return field
    }

    func updateNSView(_ field: TerminalSearchFieldView, context: Context) {
        context.coordinator.text = $text
        context.coordinator.onCommand = onCommand
        if field.stringValue != text {
            field.stringValue = text
        }
        field.focusCoordinator.update(
            requestID: focusRequestID,
            hostView: field,
            targetView: field,
            onResult: onFocusResult
        )
    }

    static func dismantleNSView(
        _ field: TerminalSearchFieldView,
        coordinator: Coordinator
    ) {
        field.focusCoordinator.cancel()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onCommand: onCommand)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var onCommand: (TerminalSearchFieldCommand) -> Void
        /// Reads the modifiers of the key event being dispatched. Injected so
        /// the Shift+Return branch is testable without posting a real event.
        var modifierFlagsProvider: () -> NSEvent.ModifierFlags = {
            NSApp.currentEvent?.modifierFlags ?? []
        }

        init(
            text: Binding<String>,
            onCommand: @escaping (TerminalSearchFieldCommand) -> Void
        ) {
            self.text = text
            self.onCommand = onCommand
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            handleCommand(commandSelector)
        }

        /// Dispatches a field-editor selector. Returns `true` when the search
        /// bar consumed the key, which is what stops AppKit from also
        /// performing its default action for it.
        @discardableResult
        func handleCommand(_ commandSelector: Selector) -> Bool {
            guard let command = TerminalSearchFieldCommand.forSelector(
                commandSelector,
                shiftPressed: modifierFlagsProvider().contains(.shift)
            ) else {
                return false
            }
            onCommand(command)
            return true
        }
    }
}
