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
    var terminalTabs: [TerminalTab] = [TerminalTab(name: Strings.terminalDefaultName)]
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
        let tab = TerminalTab(name: Strings.terminalNumberedName(number))
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

    // MARK: - Process management

    /// Whether any terminal tab has a foreground child process running.
    var hasActiveProcesses: Bool {
        terminalTabs.contains { $0.hasForegroundProcess }
    }

    /// Terminal tabs that currently have a foreground child process.
    var tabsWithForegroundProcesses: [TerminalTab] {
        terminalTabs.filter { $0.hasForegroundProcess }
    }

    /// Terminates all terminal processes.
    func terminateAll() {
        for tab in terminalTabs {
            tab.stop()
        }
    }
}
