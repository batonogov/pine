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

    func configure(
        _ configuration: SidebarAccessibilityRowConfiguration,
        onPress: @escaping () -> Bool,
        onCustomAction: (() -> Bool)?
    ) {
        self.onPress = onPress
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
}

/// Embeds ``SidebarAccessibilityRowView`` without changing layout or pointer
/// hit testing. The visible SwiftUI content is hidden from accessibility so
/// VoiceOver sees exactly one stable outline row.
struct SidebarAccessibilityRow: NSViewRepresentable {
    let configuration: SidebarAccessibilityRowConfiguration
    let onPress: () -> Bool
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
            onCustomAction: onCustomAction
        )
    }
}
