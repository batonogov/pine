//
//  ProjectManager.swift
//  Pine
//
//  Created by Федор Батоногов on 10.03.2026.
//

import SwiftUI

/// Shared project state across all windows/tabs.
/// Manages the file tree and project root directory.
@Observable
final class ProjectManager {
    var rootNodes: [FileNode] = []
    var projectName: String = "No Project"
    var rootURL: URL?
    let gitProvider = GitStatusProvider()

    // Terminal state — shared across all editor tabs
    var isTerminalVisible = false
    var isTerminalMaximized = false
    var terminalTabs: [TerminalTab] = [TerminalTab(name: "Terminal")]
    var activeTerminalID: UUID?

    var activeTerminalTab: TerminalTab? {
        guard let id = activeTerminalID else { return nil }
        return terminalTabs.first { $0.id == id }
    }

    func startTerminals() {
        for tab in terminalTabs {
            tab.configure(workingDirectory: rootURL)
        }
        if activeTerminalID == nil {
            activeTerminalID = terminalTabs.first?.id
        }
    }

    func addTerminalTab() {
        let number = terminalTabs.count + 1
        let tab = TerminalTab(name: "Terminal \(number)")
        tab.configure(workingDirectory: rootURL)
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

    func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a project folder"
        panel.prompt = "Open"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadDirectory(url: url)
    }

    func loadDirectory(url: URL) {
        rootURL = url
        projectName = url.lastPathComponent

        let root = FileNode(url: url)
        root.loadChildren()
        rootNodes = root.children ?? []

        gitProvider.setup(repositoryURL: url)
    }
}
