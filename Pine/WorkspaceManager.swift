//
//  WorkspaceManager.swift
//  Pine
//
//  Created by Claude on 11.03.2026.
//

import SwiftUI

/// Manages the project file tree, root directory, and git integration.
///
/// All public/internal methods and property access must happen on the
/// main thread (enforced by SwiftUI's @Observable).
@Observable
final class WorkspaceManager {
    var rootNodes: [FileNode] = []
    var projectName: String = "Pine"
    var rootURL: URL?
    let gitProvider = GitStatusProvider()
    private var fileWatcher: FileSystemWatcher?

    /// Monotonically increasing token that invalidates stale async loads.
    /// Bumped on every loadDirectory / refreshFileTree call so that
    /// a slow background task never overwrites a newer result.
    private var loadGeneration: Int = 0

    deinit {
        fileWatcher?.stop()
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
        // Stop old watcher immediately so it cannot fire events
        // that would bump loadGeneration and race with the new load.
        fileWatcher?.stop()
        fileWatcher = nil

        rootURL = url
        projectName = url.lastPathComponent
        loadGeneration += 1
        let generation = loadGeneration

        // Clear stale state immediately so the UI doesn't show
        // the previous project's sidebar/git while the async load runs.
        rootNodes = []
        gitProvider.isGitRepository = false
        gitProvider.currentBranch = ""
        gitProvider.fileStatuses = [:]
        gitProvider.branches = []

        loadDirectoryContentsAsync(url: url, generation: generation) { [weak self] in
            self?.startWatching(url: url)
        }
    }

    private func startWatching(url: URL) {
        let watcher = FileSystemWatcher { [weak self] in
            // This closure runs on main (guaranteed by FileSystemWatcher).
            self?.refreshFileTreeAsync()
        }
        watcher.watch(directory: url)
        fileWatcher = watcher
    }

    /// Heavy I/O (file tree + git) runs on a background queue;
    /// results are assigned back on the main thread.
    private func loadDirectoryContentsAsync(
        url: URL,
        generation: Int,
        completion: (() -> Void)? = nil
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let root = FileNode(url: url)
            root.loadChildren()
            let children = root.children ?? []

            let bgGit = GitStatusProvider()
            bgGit.setup(repositoryURL: url)

            DispatchQueue.main.async { [weak self] in
                guard let self, self.loadGeneration == generation else { return }
                self.rootNodes = children
                self.gitProvider.repositoryURL = bgGit.repositoryURL
                self.gitProvider.gitRootPath = bgGit.gitRootPath
                self.gitProvider.isGitRepository = bgGit.isGitRepository
                self.gitProvider.currentBranch = bgGit.currentBranch
                self.gitProvider.fileStatuses = bgGit.fileStatuses
                self.gitProvider.branches = bgGit.branches
                completion?()
            }
        }
    }

    /// Reload the file tree from disk (e.g. after creating/renaming/deleting files).
    /// Runs synchronously on the main thread for immediate UI feedback
    /// after explicit user actions (create/rename/delete).
    func refreshFileTree() {
        guard let url = rootURL else { return }
        loadGeneration += 1
        let root = FileNode(url: url)
        root.loadChildren()
        rootNodes = root.children ?? []
        gitProvider.refresh()
    }

    /// Background variant called by the file watcher.
    /// Runs on main (watcher dispatches here) so loadGeneration
    /// access is safe; heavy I/O is dispatched to a background queue.
    private func refreshFileTreeAsync() {
        guard let url = rootURL else { return }
        loadGeneration += 1
        let generation = loadGeneration
        loadDirectoryContentsAsync(url: url, generation: generation)
    }
}
