//
//  SidebarAccessibilityRow.swift
//  Pine
//
//  AppKit accessibility representation for the custom SwiftUI sidebar tree.
//  SwiftUI does not expose an outline-row role or disclosure level modifier,
//  so each visual row is paired with this non-hit-testing AX element.
//

import AppKit
import SwiftUI

struct SidebarAccessibilityRowConfiguration: Equatable {
    let label: String
    let identifier: String
    let level: Int
    let isSelected: Bool
    let isFocused: Bool
    let isFolder: Bool
    let isExpanded: Bool
    let value: String?
    let help: String?
    let customActionName: String?
}

/// A semantic outline row that leaves pointer handling to the SwiftUI view
/// underneath while exposing the native role/state expected by VoiceOver.
@MainActor
final class SidebarAccessibilityRowView: NSView {
    private var onPress: (() -> Bool)?
    private var onCommand: ((SidebarKeyboardCommand) -> Bool)?
    private var isForwardingNavigationKey = false
    private var semanticIsFocused = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.row)
        setAccessibilitySubrole(.outlineRow)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    /// macOS 26 can keep an accessibility-pressed outline row in the key-event
    /// path after disclosure reconciliation outlives the focus bridge's
    /// bounded retries. Keep that native AX path command-capable instead of
    /// relying on a timed focus race before the user's next arrow key.
    override var acceptsFirstResponder: Bool { true }

    /// AppKit derives this value from first-responder state once a view can
    /// accept keyboard focus. Sidebar focus is instead owned by the shared
    /// bridge and applies to the selected semantic row, so preserve the value
    /// supplied by the tree rather than exposing this fallback responder's
    /// incidental state to VoiceOver.
    override func isAccessibilityFocused() -> Bool {
        semanticIsFocused
    }

    func configure(
        _ configuration: SidebarAccessibilityRowConfiguration,
        onPress: @escaping () -> Bool,
        onCommand: @escaping (SidebarKeyboardCommand) -> Bool,
        onCustomAction: (() -> Bool)?
    ) {
        self.onPress = onPress
        self.onCommand = onCommand
        semanticIsFocused = configuration.isFocused
        setAccessibilityLabel(configuration.label)
        setAccessibilityIdentifier(configuration.identifier)
        setAccessibilityDisclosureLevel(configuration.level)
        setAccessibilitySelected(configuration.isSelected)
        setAccessibilityFocused(configuration.isFocused)
        setAccessibilityValue(configuration.value)
        setAccessibilityHelp(configuration.help)

        setAccessibilityExpanded(
            configuration.isFolder && configuration.isExpanded
        )

        if let actionName = configuration.customActionName,
           let onCustomAction {
            setAccessibilityCustomActions([
                NSAccessibilityCustomAction(
                    name: actionName,
                    handler: onCustomAction
                ),
            ])
        } else {
            setAccessibilityCustomActions([])
        }
    }

    override func accessibilityPerformPress() -> Bool {
        onPress?() ?? false
    }

    override func keyDown(with event: NSEvent) {
        guard let command = SidebarKeyboardCommand(keyCode: event.keyCode) else {
            super.keyDown(with: event)
            return
        }
        let modifiers = SidebarKeyboardModifiers(event.modifierFlags)
        if modifiers.isEmpty, onCommand?(command) == true {
            return
        }
        isForwardingNavigationKey = true
        defer { isForwardingNavigationKey = false }
        super.keyDown(with: event)
    }

    override func doCommand(by selector: Selector) {
        if !isForwardingNavigationKey,
           let command = SidebarKeyboardCommand(selector: selector),
           onCommand?(command) == true {
            return
        }
        super.doCommand(by: selector)
    }
}

/// Embeds ``SidebarAccessibilityRowView`` without changing layout or pointer
/// hit testing. The visible SwiftUI content is hidden from accessibility so
/// VoiceOver sees exactly one stable outline row.
struct SidebarAccessibilityRow: NSViewRepresentable {
    let configuration: SidebarAccessibilityRowConfiguration
    let onPress: () -> Bool
    let onCommand: (SidebarKeyboardCommand) -> Bool
    let onCustomAction: (() -> Bool)?

    func makeNSView(context: Context) -> SidebarAccessibilityRowView {
        SidebarAccessibilityRowView(frame: .zero)
    }

    func updateNSView(
        _ nsView: SidebarAccessibilityRowView,
        context: Context
    ) {
        nsView.configure(
            configuration,
            onPress: onPress,
            onCommand: onCommand,
            onCustomAction: onCustomAction
        )
    }
}
