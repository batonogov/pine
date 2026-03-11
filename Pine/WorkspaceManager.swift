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

        // Clear stale state immediately so the UI doesn't show
        // the previous project's sidebar/git while the async load runs.
        rootNodes = []
        gitProvider.isGitRepository = false
        gitProvider.currentBranch = ""
        gitProvider.fileStatuses = [:]
        gitProvider.branches = []

        loadDirectoryContentsAsync(url: url)
    }

    /// Heavy I/O (file tree + git) runs on a background queue;
    /// results are assigned back on the main thread.
    private func loadDirectoryContentsAsync(url: URL) {
        DispatchQueue.global(qos: .userInitiated).async {
            let root = FileNode(url: url)
            root.loadChildren()
            let children = root.children ?? []

            let bgGit = GitStatusProvider()
            bgGit.setup(repositoryURL: url)

            DispatchQueue.main.async { [weak self] in
                guard let self, self.rootURL == url else { return }
                self.rootNodes = children
                self.gitProvider.repositoryURL = bgGit.repositoryURL
                self.gitProvider.gitRootPath = bgGit.gitRootPath
                self.gitProvider.isGitRepository = bgGit.isGitRepository
                self.gitProvider.currentBranch = bgGit.currentBranch
                self.gitProvider.fileStatuses = bgGit.fileStatuses
                self.gitProvider.branches = bgGit.branches
            }
        }
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
