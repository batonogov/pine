//
//  WorkspaceManager.swift
//  Pine
//
//  Created by Claude on 11.03.2026.
//

import os
import SwiftUI

/// Manages the project file tree, root directory, and git integration.
///
/// All public/internal methods and property access must happen on the
/// main thread (enforced by SwiftUI's @Observable and @MainActor).
@MainActor
@Observable
final class WorkspaceManager {
    nonisolated private static let logger = Logger.fileTree
    var rootNodes: [FileNode] = []
    var projectName: String = "Pine"
    var rootURL: URL?
    /// True while the initial directory load is in progress (shallow or full phase).
    /// Views use this to show stable placeholder content instead of flashing empty state.
    var isLoading = false
    let gitProvider = GitStatusProvider()
    /// Shared progress tracker — set by ProjectManager after init.
    weak var progressTracker: ProgressTracker?
    // nonisolated(unsafe) allows deinit to access fileWatcher.
    // FileSystemWatcher.stop() is thread-safe (uses queue.sync internally).
    nonisolated(unsafe) private var fileWatcher: FileSystemWatcher?

    /// Incremented on every file-watcher event so ContentView can trigger
    /// external change detection on open tabs.
    var externalChangeToken: Int = 0

    /// Monotonically increasing token that invalidates stale async loads.
    /// Bumped on every loadDirectory / refreshFileTree call so that
    /// a slow background task never overwrites a newer result.
    private var loadGeneration: Int = 0

    /// Called on main thread whenever `rootNodes` changes so dependents
    /// (e.g. QuickOpenProvider) can rebuild their caches.
    /// Debounced with 200ms delay so rapid sequential updates
    /// (shallow → full phase) trigger only one rebuild.
    private(set) var onRootNodesChanged: (([FileNode]) -> Void)?

    /// Pending debounced notification work item.
    private var rootNodesChangedWorkItem: DispatchWorkItem?

    /// Debounce interval for `onRootNodesChanged` notifications.
    private static let rootNodesChangedDebounce: TimeInterval = 0.2

    /// Sets the callback invoked when `rootNodes` changes.
    func setOnRootNodesChanged(_ handler: (([FileNode]) -> Void)?) {
        onRootNodesChanged = handler
    }

    /// Tracks the in-flight async git refresh so it can be cancelled
    /// when a new refresh starts (prevents stale data from overwriting newer results).
    private var gitRefreshTask: Task<Void, Never>?

    /// After a synchronous refreshFileTree(), watcher events within this
    /// window are suppressed because they echo the action we just handled.
    /// Kept short (150ms) so external changes (e.g. `mkdir` in the built-in
    /// terminal) are not silently dropped — issue #774. Previously this was
    /// 1s, which was long enough to swallow rapid terminal-driven changes
    /// following any sidebar edit.
    private var suppressWatcherUntil: Date?
    private static let watcherSuppressWindow: TimeInterval = 0.15

    /// Schedules a debounced `onRootNodesChanged` notification.
    /// Cancels any pending notification so rapid updates coalesce into one.
    private func notifyRootNodesChanged(_ nodes: [FileNode]) {
        rootNodesChangedWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.onRootNodesChanged?(nodes)
        }
        rootNodesChangedWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.rootNodesChangedDebounce,
            execute: workItem
        )
    }

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

        let isSameProject = (rootURL == url)
        rootURL = url
        projectName = url.lastPathComponent
        isLoading = true
        loadGeneration += 1
        let generation = loadGeneration

        // When switching to a *different* project, clear stale git state
        // immediately so the UI doesn't show the previous project's branch.
        // When re-loading the same project we keep the existing state to
        // avoid the bottom-left indicator flickering between empty and
        // populated (issue #738).
        // rootNodes are intentionally preserved to avoid sidebar flash —
        // the shallow phase replaces them within milliseconds.
        if !isSameProject {
            gitProvider.applyEmptyState()
        }

        // Start watching *before* the async load begins so that any FS
        // activity during the initial load (e.g. user opens Cmd+` and types
        // `mkdir foo` immediately) is not lost. FSEvents buffers events so
        // there is no race between watcher start and the first callback.
        // Fixes issue #774.
        startWatching(url: url)

        loadDirectoryContentsAsync(url: url, generation: generation)
    }

    private func startWatching(url: URL) {
        // Short debounce (150ms) so changes made in the built-in terminal
        // (or any external process) appear in the sidebar almost immediately.
        // The previous default (500ms) combined with the watcher's own event
        // coalescing made the sidebar feel unresponsive to shell commands.
        let watcher = FileSystemWatcher(debounceInterval: 0.15) { [weak self] in
            // This closure runs on main (guaranteed by FileSystemWatcher).
            self?.externalChangeToken += 1
            self?.refreshFileTreeAsync()
        }
        watcher.watch(directory: url)
        fileWatcher = watcher
    }

    /// Depth limit for the initial shallow pass — shows the first few
    /// levels instantly while the full tree loads in the background.
    private static let shallowDepth = 3

    /// Heavy I/O (file tree + git) runs on a background queue;
    /// results are assigned back on the main thread.
    /// Uses two-phase progressive loading: a shallow tree appears fast,
    /// then the full tree replaces it once ready.
    private func loadDirectoryContentsAsync(
        url: URL,
        generation: Int
    ) {
        let progressID = progressTracker?.beginOperation(Strings.progressLoadingProject)
        // nonisolated-check:ignore — pre-existing pattern; tracked in #720
        DispatchQueue.global(qos: .userInitiated).async {
            // Run git setup first so we know which paths are ignored
            let bgGit = GitStatusProvider()
            bgGit.setup(repositoryURL: url)

            // Phase 1: shallow tree for fast initial render
            let shallowResult = FileNode.loadTree(
                url: url, projectRoot: url,
                ignoredPaths: bgGit.ignoredPaths,
                maxDepth: Self.shallowDepth
            )
            let shallowChildren = shallowResult.root.children ?? []

            DispatchQueue.main.async { [weak self] in
                guard let self, self.loadGeneration == generation else {
                    if let progressID { self?.progressTracker?.endOperation(progressID) }
                    return
                }
                self.rootNodes = shallowChildren
                self.notifyRootNodesChanged(shallowChildren)
                self.gitProvider.repositoryURL = bgGit.repositoryURL
                self.gitProvider.gitRootPath = bgGit.gitRootPath
                // Atomically apply git state in a single equality-checked
                // pass so SwiftUI does not observe transient empty values
                // between individual property writes (issue #738).
                self.gitProvider.applyFetched(
                    branch: bgGit.currentBranch,
                    statuses: bgGit.fileStatuses,
                    ignored: bgGit.ignoredPaths,
                    branches: bgGit.branches,
                    isRepository: bgGit.isGitRepository
                )

                // For shallow projects, loading is done — no Phase 2 needed.
                if !shallowResult.wasDepthLimited {
                    self.isLoading = false
                    if let progressID { self.progressTracker?.endOperation(progressID) }
                }
            }

            // Phase 2: full tree only if Phase 1 hit the depth limit.
            // For shallow projects this avoids redundant tree construction.
            guard shallowResult.wasDepthLimited else { return }

            let fullChildren = Self.loadTopLevelInParallel(
                url: url, ignoredPaths: bgGit.ignoredPaths
            )

            // Safe ordering: main queue is FIFO, so Phase 2 always runs after Phase 1.
            // Completion (file watcher) starts after Phase 2 to avoid watcher events
            // racing with and invalidating the in-flight full tree load.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.loadGeneration == generation else {
                    if let progressID { self?.progressTracker?.endOperation(progressID) }
                    return
                }
                self.rootNodes = fullChildren
                self.notifyRootNodesChanged(fullChildren)
                self.isLoading = false
                if let progressID { self.progressTracker?.endOperation(progressID) }
            }
        }
    }

    /// Loads top-level directory entries in parallel using `concurrentPerform`.
    ///
    /// Each top-level subdirectory builds its full subtree on a separate GCD thread,
    /// while files are collected as-is. Results are merged and sorted to match
    /// the standard display order (directories first, then case-insensitive by name).
    nonisolated private static func loadTopLevelInParallel(
        url: URL, ignoredPaths: Set<String>
    ) -> [FileNode] {
        let hiddenNames: Set<String> = [".git", ".DS_Store"]

        let topContents: [URL]
        do {
            topContents = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: []
            )
        } catch {
            logger.error("Failed to list directory \(url.lastPathComponent): \(error)")
            return []
        }

        let filtered = topContents.filter { !hiddenNames.contains($0.lastPathComponent) }
        guard !filtered.isEmpty else { return [] }

        // Pre-allocate array for thread-safe indexed writes.
        // Each index is written by exactly one iteration — no synchronization needed.
        let results = UnsafeMutableBufferPointer<FileNode?>.allocate(capacity: filtered.count)
        results.initialize(repeating: nil)
        defer { results.deallocate() }

        DispatchQueue.concurrentPerform(iterations: filtered.count) { index in
            let childURL = filtered[index]
            results[index] = FileNode(
                url: childURL, projectRoot: url, ignoredPaths: ignoredPaths
            )
        }

        let nodes = (0..<filtered.count).compactMap { results[$0] }

        return nodes.sorted { lhs, rhs in
            if lhs.isDirectory == rhs.isDirectory {
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            return lhs.isDirectory && !rhs.isDirectory
        }
    }

    /// Reload the file tree from disk (e.g. after creating/renaming/deleting files).
    /// A shallow tree (depth-limited) is built synchronously for immediate UI feedback;
    /// the full tree and git status refresh run asynchronously on background queues.
    func refreshFileTree() {
        guard let url = rootURL else { return }
        loadGeneration += 1
        let generation = loadGeneration
        let ignoredPaths = gitProvider.ignoredPaths

        // Phase 1 (sync): shallow tree for immediate feedback
        let shallowResult = FileNode.loadTree(
            url: url, projectRoot: url,
            ignoredPaths: ignoredPaths,
            maxDepth: Self.shallowDepth
        )
        rootNodes = shallowResult.root.children ?? []
        notifyRootNodesChanged(rootNodes)

        // Phase 2 (async): full tree only if Phase 1 hit the depth limit
        if shallowResult.wasDepthLimited {
            // nonisolated-check:ignore — pre-existing pattern; tracked in #720
            DispatchQueue.global(qos: .userInitiated).async {
                let fullChildren = Self.loadTopLevelInParallel(
                    url: url, ignoredPaths: ignoredPaths
                )
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.loadGeneration == generation else { return }
                    self.rootNodes = fullChildren
                    self.notifyRootNodesChanged(fullChildren)
                }
            }
        }

        // Cancel any in-flight git refresh to avoid stale data overwriting newer results.
        gitRefreshTask?.cancel()
        gitRefreshTask = Task { await gitProvider.refreshAsync() }
        // Suppress watcher echoes — we just refreshed, so any watcher event
        // within the next second is redundant and could break inline editing.
        suppressWatcherUntil = Date().addingTimeInterval(Self.watcherSuppressWindow)
    }

    /// Background variant called by the file watcher.
    /// Runs on main (watcher dispatches here) so loadGeneration
    /// access is safe; heavy I/O is dispatched to a background queue.
    private func refreshFileTreeAsync() {
        if let until = suppressWatcherUntil, Date() < until {
            return
        }
        guard let url = rootURL else { return }
        loadGeneration += 1
        let generation = loadGeneration
        loadDirectoryContentsAsync(url: url, generation: generation)
    }
}
