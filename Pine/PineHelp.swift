//
//  PineHelp.swift
//  Pine
//
//  Stable Apple Help book routes shared by native HelpLink controls, compact
//  AppKit help buttons, and HelpBookTests.
//

import AppKit
import SwiftUI

nonisolated enum PineHelp {
    static let bookName: NSHelpManager.BookName =
        "io.github.batonogov.pine.help"

    nonisolated enum Anchor {
        static let home: NSHelpManager.AnchorName = "pine-help-home"
        static let gettingStarted: NSHelpManager.AnchorName =
            "pine-getting-started"
        static let workspace: NSHelpManager.AnchorName = "pine-workspace"
        static let terminal: NSHelpManager.AnchorName = "pine-terminal"
        static let git: NSHelpManager.AnchorName = "pine-git"
        static let languageServers: NSHelpManager.AnchorName = "pine-lsp"
        static let agents: NSHelpManager.AnchorName = "pine-agents"
        static let agentInbox: NSHelpManager.AnchorName =
            "pine-agent-inbox"
        static let agentSettings: NSHelpManager.AnchorName =
            "pine-agent-settings"
        static let settings: NSHelpManager.AnchorName = "pine-settings"
        static let shortcuts: NSHelpManager.AnchorName = "pine-shortcuts"
        static let troubleshooting: NSHelpManager.AnchorName =
            "pine-troubleshooting"
    }
}

/// A native AppKit help button for compact SwiftUI chrome.
///
/// `HelpLink` remains the preferred control in regular SwiftUI layouts. The
/// Problems panel header is short enough that its represented help control can
/// be omitted from the accessibility hierarchy on macOS 26. This bridge uses
/// AppKit's standard help-button bezel and publishes the native accessibility
/// contract explicitly, matching Pine's other represented controls.
@MainActor
struct PineHelpButton: NSViewRepresentable {
    let anchor: NSHelpManager.AnchorName
    let book: NSHelpManager.BookName
    let accessibilityIdentifier: String
    var controlSize: NSControl.ControlSize = .regular

    func makeNSView(context: Context) -> PineNativeHelpButton {
        PineNativeHelpButton(
            anchor: anchor,
            book: book,
            accessibilityIdentifier: accessibilityIdentifier,
            controlSize: controlSize
        )
    }

    func updateNSView(
        _ nsView: PineNativeHelpButton,
        context: Context
    ) {
        nsView.configure(
            anchor: anchor,
            book: book,
            accessibilityIdentifier: accessibilityIdentifier,
            controlSize: controlSize
        )
    }
}

@MainActor
final class PineNativeHelpButton: NSButton {
    private var helpAnchor: NSHelpManager.AnchorName
    private var helpBook: NSHelpManager.BookName

    init(
        anchor: NSHelpManager.AnchorName,
        book: NSHelpManager.BookName,
        accessibilityIdentifier: String,
        controlSize: NSControl.ControlSize
    ) {
        self.helpAnchor = anchor
        self.helpBook = book
        super.init(frame: .zero)

        target = self
        action = #selector(openHelp)
        configure(
            anchor: anchor,
            book: book,
            accessibilityIdentifier: accessibilityIdentifier,
            controlSize: controlSize
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        anchor: NSHelpManager.AnchorName,
        book: NSHelpManager.BookName,
        accessibilityIdentifier: String,
        controlSize: NSControl.ControlSize
    ) {
        helpAnchor = anchor
        helpBook = book
        bezelStyle = .helpButton
        self.controlSize = controlSize
        identifier = NSUserInterfaceItemIdentifier(accessibilityIdentifier)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityIdentifier(accessibilityIdentifier)
    }

    @objc private func openHelp() {
        NSHelpManager.shared.openHelpAnchor(helpAnchor, inBook: helpBook)
    }
}
