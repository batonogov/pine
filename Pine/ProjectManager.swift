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
    }
}
