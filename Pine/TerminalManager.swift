//
//  TerminalManager.swift
//  Pine
//
//  Created by Claude on 11.03.2026.
//

import SwiftUI

/// Manages terminal tabs, sessions, and visibility state.
@Observable
final class TerminalManager {
    var isTerminalVisible = false
    var isTerminalMaximized = false
    var terminalTabs: [TerminalTab] = [TerminalTab(name: "Terminal")]
    var activeTerminalID: UUID?

    var activeTerminalTab: TerminalTab? {
        guard let id = activeTerminalID else { return nil }
        return terminalTabs.first { $0.id == id }
    }

    func startTerminals(workingDirectory: URL?) {
        for tab in terminalTabs {
            tab.configure(workingDirectory: workingDirectory)
        }
        if activeTerminalID == nil {
            activeTerminalID = terminalTabs.first?.id
        }
    }

    func addTerminalTab(workingDirectory: URL?) {
        let number = terminalTabs.count + 1
        let tab = TerminalTab(name: "Terminal \(number)")
        tab.configure(workingDirectory: workingDirectory)
        terminalTabs.append(tab)
        activeTerminalID = tab.id
    }

    func closeTerminalTab(_ tab: TerminalTab) {
        tab.stop()
        terminalTabs.removeAll { $0.id == tab.id }
        if activeTerminalID == tab.id {
            activeTerminalID = terminalTabs.last?.id
        }
    }
}
