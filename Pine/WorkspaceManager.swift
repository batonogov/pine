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
    /// Monotonically increasing counter bumped every time `rootNodes` is
    /// assigned. Sidebar observers use this to prune expansion state after
    /// refreshes without recreating the entire tree.
    private(set) var rootNodesRevision: Int = 0
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

    /// Debouncer for `onRootNodesChanged` notifications.
    private var rootNodesChangedDebouncer: Debouncer?

    /// Continuations waiting for `isLoading` to become `false`.
    private var loadingContinuations: [CheckedContinuation<Void, Never>] = []

    /// Debounce interval for `onRootNodesChanged` notifications.
    private static let rootNodesChangedDebounce: TimeInterval = 0.2

    /// Sets the callback invoked when `rootNodes` changes.
    func setOnRootNodesChanged(_ handler: (([FileNode]) -> Void)?) {
        onRootNodesChanged = handler
    }

    /// Tracks the in-flight directory-load task. Cancelled and replaced on
    /// every `loadDirectory` / `refreshFileTreeAsync` call so a slow run
    /// never resumes after a newer one has started.
    private var loadingTask: Task<Void, Never>?

    /// `FileSystemWatcher` debounce interval. Short enough that changes
    /// made in the built-in terminal or by external processes appear in
    /// the sidebar almost immediately while still coalescing rapid bursts
    /// (npm install, git checkout) into a handful of refreshes.
    ///
    /// Note: a previous post-refresh suppression window (`suppressWatcherUntil`)
    /// was removed in the fix for issue #839 — it was responsible for
    /// swallowing genuine external FSEvents that happened to land in the
    /// debounce window after any in-app sidebar action (rename / create /
    /// delete). `loadGeneration` already guarantees that overlapping
    /// refreshes never corrupt `rootNodes`, and `refreshFileTreeAsync` is
    /// cheap enough that the duplicate cost of an echoed event is invisible
    /// to users.
    static let watcherDebounce: TimeInterval = UITimings.Debounce.fileWatcher

    /// Sets `rootNodes`, bumps `rootNodesRevision`, and schedules a debounced
    /// `onRootNodesChanged` notification. Centralised so every assignment site
    /// (initial load, shallow refresh, full refresh) emits the same signals.
    private func setRootNodes(_ nodes: [FileNode]) {
        rootNodes = nodes
        rootNodesRevision += 1
        notifyRootNodesChanged()
    }

    /// Schedules a debounced `onRootNodesChanged` notification.
    /// Cancels any pending notification so rapid updates coalesce into one.
    private func notifyRootNodesChanged() {
        // Lazily create the debouncer (captures self weakly).
        if rootNodesChangedDebouncer == nil {
            rootNodesChangedDebouncer = Debouncer(
                delay: Self.rootNodesChangedDebounce
            ) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.onRootNodesChanged?(self.rootNodes)
                }
            }
        }
        rootNodesChangedDebouncer?.schedule()
    }

    deinit {
        fileWatcher?.stop()
    }

    /// Suspends until the current load completes (`isLoading` becomes `false`).
    /// Returns immediately if no load is in progress.
    /// The check is inside the continuation closure (which runs synchronously
    /// before the suspend point) to avoid a race where `isLoading` flips
    /// between the guard and the append.
    func waitForLoadingComplete() async {
        await withCheckedContinuation { continuation in
            if isLoading {
                loadingContinuations.append(continuation)
            } else {
                continuation.resume()
            }
        }
    }

    /// Resumes all continuations waiting for load completion.
    private func resumeLoadingContinuations() {
        let continuations = loadingContinuations
        loadingContinuations.removeAll()
        for continuation in continuations {
            continuation.resume()
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
        // Stop old watcher immediately so it cannot fire events
        // that would bump loadGeneration and race with the new load.
        fileWatcher?.stop()
        fileWatcher = nil

        // Resume any continuations from a previous load so they don't
        // hang forever when the old generation's guard-return skips
        // resumeLoadingContinuations().
        resumeLoadingContinuations()

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
        let watcher = FileSystemWatcher(debounceInterval: Self.watcherDebounce) { [weak self] in
            // This closure runs on main (guaranteed by FileSystemWatcher).
            self?.externalChangeToken += 1
            self?.refreshFileTreeAsync()
        }
        watcher.watch(directory: url)
        fileWatcher = watcher
    }

    /// Depth limit for the initial shallow pass — shows the first few
    /// levels instantly while the full tree loads in the background.
    /// `nonisolated` so the detached load task can read it without a
    /// main-actor hop.
    nonisolated private static let shallowDepth = 3

    /// Heavy I/O (file tree + git) runs in a detached `Task` at
    /// `userInitiated` priority; results are applied back on the main actor
    /// via `await MainActor.run { ... }`.
    ///
    /// Why pure Swift Concurrency (no GCD): mixing `DispatchQueue.global`
    /// with `DispatchQueue.main.async` and a `withCheckedContinuation`
    /// resume on the main actor caused scheduler starvation on single-core
    /// CI runners — the GCD main-queue block could sit behind cooperative
    /// thread work, taking 55–70 s to fire on an *empty* directory load
    /// (issue #837). Staying inside the structured-concurrency world lets
    /// the main actor and the detached worker interleave cooperatively.
    ///
    /// Uses two-phase progressive loading: a shallow tree appears fast,
    /// then the full tree replaces it once ready.
    private func loadDirectoryContentsAsync(
        url: URL,
        generation: Int,
        showProgress: Bool = true
    ) {
        // Cancel any prior in-flight load so its `MainActor.run` blocks
        // become no-ops after the generation check below.
        loadingTask?.cancel()

        let progressID = showProgress
            ? progressTracker?.beginOperation(Strings.progressLoadingProject)
            : nil

        loadingTask = Task.detached(priority: .userInitiated) { [weak self] in
            // Shared cleanup closure — ends the progress operation on MainActor.
            // Extracted to avoid repeating the same 5-line block at every
            // cancellation / early-return site.
            let cleanupProgress: () async -> Void = {
                if let progressID {
                    await MainActor.run { [weak self] in
                        self?.progressTracker?.endOperation(progressID)
                    }
                }
            }

            // 1. Git setup — pure nonisolated work using static helpers.
            //    No `@MainActor` object is created off-main: avoids the
            //    `nonisolated-check:ignore` workaround the GCD path needed.
            let gitInfo = Self.fetchGitInfo(at: url)

            // 2. Phase 1: shallow tree for fast initial render.
            let shallowResult = PerformanceSignposts.trace("filetree.shallow") {
                FileNode.loadTree(
                    url: url, projectRoot: url,
                    ignoredPaths: gitInfo.ignoredPaths,
                    maxDepth: Self.shallowDepth
                )
            }
            let shallowChildren = shallowResult.root.children ?? []

            if Task.isCancelled { await cleanupProgress(); return }

            await MainActor.run { [weak self] in
                guard let self, self.loadGeneration == generation else {
                    if let progressID { self?.progressTracker?.endOperation(progressID) }
                    return
                }
                self.setRootNodes(shallowChildren)
                self.gitProvider.repositoryURL = gitInfo.repositoryURL
                self.gitProvider.gitRootPath = gitInfo.gitRootPath
                // Atomically apply git state in a single equality-checked
                // pass so SwiftUI does not observe transient empty values
                // between individual property writes (issue #738).
                self.gitProvider.applyFetched(
                    branch: gitInfo.branch,
                    statuses: gitInfo.statuses,
                    ignored: gitInfo.ignoredPaths,
                    branches: gitInfo.branches,
                    isRepository: gitInfo.isRepository
                )

                // For shallow projects, loading is done — no Phase 2 needed.
                if !shallowResult.wasDepthLimited {
                    self.isLoading = false
                    self.resumeLoadingContinuations()
                    if let progressID { self.progressTracker?.endOperation(progressID) }
                }
            }

            // 3. Phase 2: full tree only if Phase 1 hit the depth limit.
            //    For shallow projects this avoids redundant tree construction.
            //    Safe to return without cleanup — endOperation was already called
            //    inside Phase 1's MainActor.run block for non-depth-limited trees.
            guard shallowResult.wasDepthLimited else { return }

            if Task.isCancelled { await cleanupProgress(); return }

            let fullChildren = PerformanceSignposts.trace("filetree.full") {
                Self.loadTopLevelInParallel(
                    url: url, ignoredPaths: gitInfo.ignoredPaths
                )
            }

            if Task.isCancelled { await cleanupProgress(); return }

            await MainActor.run { [weak self] in
                guard let self, self.loadGeneration == generation else {
                    if let progressID { self?.progressTracker?.endOperation(progressID) }
                    return
                }
                self.setRootNodes(fullChildren)
                self.isLoading = false
                self.resumeLoadingContinuations()
                if let progressID { self.progressTracker?.endOperation(progressID) }
            }
        }
    }

    /// Plain-data snapshot of the git state captured off-main during a load.
    private struct GitLoadSnapshot: Sendable {
        let repositoryURL: URL
        let gitRootPath: String?
        let branch: String
        let statuses: [String: GitFileStatus]
        let ignoredPaths: Set<String>
        let branches: [String]
        let isRepository: Bool
    }

    /// Pure background helper — runs git detection + a parallel fetch using
    /// `nonisolated` static helpers and returns a `Sendable` snapshot.
    /// No `@MainActor` object is created here, so this is safe to call
    /// from any thread / `Task.detached` context.
    nonisolated private static func fetchGitInfo(at url: URL) -> GitLoadSnapshot {
        let topLevel = GitStatusProvider.runGit(["rev-parse", "--show-toplevel"], at: url)
        guard topLevel.exitCode == 0 else {
            return GitLoadSnapshot(
                repositoryURL: url,
                gitRootPath: nil,
                branch: "",
                statuses: [:],
                ignoredPaths: [],
                branches: [],
                isRepository: false
            )
        }
        let rootPath = topLevel.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let fetched = GitStatusProvider.fetchAllInParallel(at: url)
        return GitLoadSnapshot(
            repositoryURL: url,
            gitRootPath: rootPath,
            branch: fetched.branch,
            statuses: fetched.statuses,
            ignoredPaths: fetched.ignored,
            branches: fetched.branches,
            isRepository: true
        )
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
    ///
    /// This is the **user-initiated** refresh path — called from sidebar
    /// actions (rename / create / delete / duplicate in `FileNodeRow` and
    /// `SidebarEditState`). The shallow `loadTree(maxDepth:)` runs
    /// **synchronously on the main thread** so `rootNodes` reflects the
    /// mutation in the same main-thread tick. This is required for the
    /// inline rename `TextField` in `FileNodeRow` to appear over the
    /// freshly-created `FileNode`: the field is keyed off
    /// `editState.renamingURL` matching a `FileNode` that must already be
    /// in the tree, and XCUITest's `waitForExistence` on that field
    /// (`InlineRenameAlignmentTests`) relies on the node rendering in the
    /// same pass.
    ///
    /// The full tree (when the shallow pass is depth-limited) and the git
    /// status refresh run asynchronously off the main thread via the shared
    /// two-phase loader (`loadDirectoryContentsAsync`), race-safe via
    /// `loadGeneration`.
    ///
    /// External file-system changes take a different entry point —
    /// `refreshFileTreeAsync()` — which runs the shallow pass off the main
    /// thread too. That split preserves the #1006 perf win (external
    /// watcher bursts no longer stutter the sidebar on large monorepos)
    /// without regressing sidebar inline-rename timing: the synchronous
    /// shallow cost is paid only for direct user mutations, which are
    /// infrequent, and not for every external FSEvents burst.
    func refreshFileTree() {
        guard let url = rootURL else { return }
        loadGeneration += 1
        let generation = loadGeneration
        let ignoredPaths = gitProvider.ignoredPaths

        // Phase 1 (sync): shallow tree for immediate `rootNodes` feedback.
        // MUST stay synchronous for sidebar inline-rename timing — the new
        // FileNode has to be in the tree on the same main-thread tick so
        // FileNodeRow renders the inline editor over it.
        let shallowResult = FileNode.loadTree(
            url: url, projectRoot: url,
            ignoredPaths: ignoredPaths,
            maxDepth: Self.shallowDepth
        )
        setRootNodes(shallowResult.root.children ?? [])

        // Phase 2 (async): full tree (if depth-limited) + git status refresh,
        // off the main thread. Reuses the shared two-phase loader so race
        // safety (`loadGeneration`) and git state stay consistent with the
        // initial load and the external watcher path. The loader repeats
        // the shallow pass; that is cheap and lands identical data, so
        // there is no visible flicker, and it carries the git fetch that
        // the pre-#1006 path used to trigger via a separate `gitRefreshTask`.
        loadDirectoryContentsAsync(url: url, generation: generation, showProgress: false)
    }

    /// Background variant called by the file watcher.
    /// Runs on main (watcher dispatches here) so loadGeneration
    /// access is safe; heavy I/O is dispatched to a background queue.
    /// `internal` (not `private`) so tests can drive it directly without
    /// depending on FSEvents timing.
    ///
    /// Issue #839: this used to early-return if a suppression window opened
    /// by `refreshFileTree()` was still active. That window dropped genuine
    /// external FSEvents (e.g. an external `touch` arriving within 150 ms
    /// of any sidebar edit), leaving the sidebar stale. The window has been
    /// removed; `loadGeneration` is enough to keep concurrent refreshes
    /// consistent and the duplicate cost of an echoed event is invisible.
    func refreshFileTreeAsync() {
        guard let url = rootURL else { return }
        loadGeneration += 1
        let generation = loadGeneration
        loadDirectoryContentsAsync(url: url, generation: generation, showProgress: false)
    }
}
