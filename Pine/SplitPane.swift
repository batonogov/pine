//
//  SplitPane.swift
//  Pine
//
//  Secondary editor pane for split view.
//

import SwiftUI

/// Identifies which side of a split editor is focused.
enum SplitSide {
    case leading
    case trailing
}

/// Lightweight tab container for the secondary (trailing) split pane.
/// Inherits all shared tab management from `TabContainer` protocol.
/// Only adds `openTab` methods (simplified vs TabManager — no large-file
/// alerts or preview detection, which are handled at open time).
@Observable
final class SplitPane: TabContainer {
    var tabs: [EditorTab] = []
    var activeTabID: UUID?

    /// Opens a file in the split pane, or activates the existing tab.
    func openTab(url: URL) {
        if let existing = tabs.first(where: { $0.url == url }) {
            activeTabID = existing.id
            return
        }

        let content: String
        do {
            content = try String(contentsOf: url, encoding: .utf8)
        } catch {
            content = "// Error: \(error.localizedDescription)"
        }

        var tab = EditorTab(url: url, content: content, savedContent: content)
        tab.lastModDate = modDate(for: url)
        tabs.append(tab)
        activeTabID = tab.id
    }

    /// Opens a file with an explicit syntax highlighting override (for session restoration).
    func openTab(url: URL, syntaxHighlightingDisabled: Bool) {
        if let existing = tabs.first(where: { $0.url == url }) {
            activeTabID = existing.id
            return
        }

        let content: String
        do {
            content = try String(contentsOf: url, encoding: .utf8)
        } catch {
            content = "// Error: \(error.localizedDescription)"
        }

        var tab = EditorTab(url: url, content: content, savedContent: content)
        tab.lastModDate = modDate(for: url)
        tab.syntaxHighlightingDisabled = syntaxHighlightingDisabled
        tabs.append(tab)
        activeTabID = tab.id
    }
}
