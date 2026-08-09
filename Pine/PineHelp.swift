//
//  PineHelp.swift
//  Pine
//
//  Stable Apple Help book and anchor identifiers shared by native HelpLink
//  controls and HelpBookTests.
//

import AppKit

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
