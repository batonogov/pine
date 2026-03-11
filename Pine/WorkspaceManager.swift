//
//  WorkspaceManager.swift
//  Pine
//
//  Created by Claude on 11.03.2026.
//

import SwiftUI

/// Manages the project file tree, root directory, and git integration.
@Observable
final class WorkspaceManager {
    var rootNodes: [FileNode] = []
    var projectName: String = "Pine"
    var rootURL: URL?
    let gitProvider = GitStatusProvider()

    init() {
        // Восстанавливаем последний открытый проект
        if let session = SessionState.load() {
            loadDirectory(url: session.projectURL)
        }
    }

    func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = Strings.openPanelMessage
        panel.prompt = Strings.openPanelPrompt

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

    /// Reload the file tree from disk (e.g. after creating/renaming/deleting files).
    func refreshFileTree() {
        guard let url = rootURL else { return }
        let root = FileNode(url: url)
        root.loadChildren()
        rootNodes = root.children ?? []
        gitProvider.refresh()
    }
}
