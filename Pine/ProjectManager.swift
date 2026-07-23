//
//  ProjectManager.swift
//  Pine
//
//  Created by Федор Батоногов on 10.03.2026.
//

import SwiftUI

/// Thin coordinator that owns the workspace, terminal, and tab managers.
/// Passed via environment so views can access all sub-managers.
@MainActor
@Observable
final class ProjectManager {
    let workspace = WorkspaceManager()
    let terminal = TerminalManager()
    /// Structured agent-action feed for the Activity Panel (vision #933,
    /// Phase 2 — Visibility, issue #1072).
    let agentActivity = AgentActivityStore()
    /// Persistent, review-only history of observed finished-agent activity
    /// (vision #933, Phase 2 — Visibility, issues #1073 and #1183).
    let agentHistory = AgentHistoryStore()
    /// The primary TabManager (initial root editor pane). Project-scoped
    /// services are wired to every pane-owned manager by `PaneManager`'s
    /// configurator. For the *focused* pane's TabManager, use
    /// ``activeTabManager`` which delegates to ``PaneManager/activeEditorTabManager``.
    ///
    /// Note: this instance can become an *orphan* — i.e. no pane in the
    /// `PaneManager` tree references it — after `pruneEmptyEditorLeaves`
    /// removes the root editor pane (terminals-only layout) or after a
    /// session restore that does not bind it to any leaf. In that state it
    /// is harmless: it holds no tabs, contributes nothing to `allTabs`, and
    /// is recreated as a leaf-bound TabManager via `ensureEditorPane()`
    /// when the user opens a file again. The reference remains as the stable
    /// fallback used by project-level commands while no editor pane exists.
    let primaryTabManager = TabManager()
    let searchProvider = ProjectSearchProvider()
    let quickOpenProvider = QuickOpenProvider()
    let progress = ProgressTracker()
    let contextFileWriter = ContextFileWriter()
    /// Language Server Protocol manager — owns per-language server processes
    /// and aggregates diagnostics (#1010, parent #994). Spawned lazily on the
    /// first open of a matching file; shut down on project close / app quit.
    let lspManager = LSPManager()
    @ObservationIgnored
    private(set) lazy var paneManager = PaneManager(existingTabManager: primaryTabManager)

    /// Returns the TabManager for the currently focused pane.
    /// Falls back to the primary ``primaryTabManager`` when no editor pane is active.
    var activeTabManager: TabManager {
        paneManager.activeEditorTabManager ?? primaryTabManager
    }

    /// Collects all tabs from every pane (for session save, dirty-tab checks, etc.).
    var allTabs: [EditorTab] {
        paneManager.tabManagers.values.flatMap(\.tabs)
    }

    /// Whether any tab in any pane has unsaved changes.
    var hasUnsavedChanges: Bool {
        paneManager.tabManagers.values.contains { $0.hasUnsavedChanges }
    }

    /// All dirty tabs across all panes.
    var allDirtyTabs: [EditorTab] {
        paneManager.tabManagers.values.flatMap(\.dirtyTabs)
    }

    /// Saves all tabs across all panes. Returns false if any save fails.
    @discardableResult
    func saveAllPaneTabs() -> Bool {
        for tabMgr in paneManager.tabManagers.values {
            guard tabMgr.saveAllTabs() else { return false }
        }
        return true
    }

    // MARK: - Menu-triggered saves (reentrancy-safe)

    /// Cmd+S from the File menu. Defers the save (and its synchronous
    /// `@Observable` model mutation when format-on-save changes content) to
    /// the next runloop so it does NOT execute inside the SwiftUI
    /// `ButtonAction` callstack. That reentrancy forced a synchronous SwiftUI
    /// body re-evaluation that collided with the button-action's exclusive
    /// access and triggered `_swift_reportExclusivityConflict` → `abort()`
    /// on macOS 26.5.1 when format-on-save reformatted the buffer (#1058).
    ///
    /// Autosave (`TabAutoSave`), close, and quit call
    /// `activeTabManager.saveActiveTab()` directly — they are not invoked
    /// from a `ButtonAction`, so there is no transactional exclusive access
    /// to collide with and no deferral is needed.
    ///
    /// The disk write is deferred by ~1 runloop (imperceptible at 60 Hz);
    /// the dirty indicator and git status settle one frame later.
    func saveActiveTabFromMenu() {
        performMenuSave { [weak self] in self?.activeTabManager.saveActiveTab() ?? false }
    }

    /// Cmd+Option+S (Save All) from the File menu. Same reentrancy rationale
    /// as ``saveActiveTabFromMenu`` — Save All can also mutate `@Observable`
    /// per-pane tab state synchronously when format-on-save changes content.
    func saveAllTabsFromMenu() {
        performMenuSave { [weak self] in self?.saveAllPaneTabs() ?? false }
    }

    /// Shared deferral for menu-triggered saves. Runs the save `operation`
    /// on the next runloop (outside any `ButtonAction` callstack), then
    /// refreshes git status + line diffs when it succeeded.
    private func performMenuSave(_ operation: @escaping () -> Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard operation() else { return }
            Task {
                await self.workspace.gitProvider.refreshAsync()
                NotificationCenter.default.post(name: .refreshLineDiffs, object: nil)
            }
        }
    }

    /// Checks every editor pane for externally modified or deleted files.
    /// Aggregates the per-pane results so global observers do not depend on
    /// the root environment's `TabManager`, which may be orphaned after pane
    /// pruning or simply not own the currently visible tab.
    func checkExternalChanges() -> TabManager.ExternalChangeResult {
        var conflicts: [TabManager.ExternalConflict] = []
        var reloadedFileNames: [String] = []
        var seenReloadedFileNames = Set<String>()

        for tabManager in paneManager.allTabManagers {
            let result = tabManager.checkExternalChanges()
            conflicts.append(contentsOf: result.conflicts)
            for fileName in result.reloadedFileNames
                where seenReloadedFileNames.insert(fileName).inserted {
                reloadedFileNames.append(fileName)
            }
        }

        // Tabs already closed by per-pane checkExternalChanges()
        return .init(conflicts: conflicts, reloadedFileNames: reloadedFileNames, cleanDeletedIDs: [])
    }

    /// Reloads matching tabs in every editor pane. The same file can be open
    /// in multiple panes, and the primary TabManager may not own any visible
    /// editor after pane pruning.
    func reloadTabs(url: URL) {
        for tabManager in paneManager.allTabManagers {
            tabManager.reloadTab(url: url)
        }
    }

    /// Returns all open tabs affected by deletion across every editor pane.
    func tabsAffectedByDeletion(url: URL) -> [EditorTab] {
        paneManager.allTabManagers.flatMap { $0.tabsAffectedByDeletion(url: url) }
    }

    /// Closes matching tabs for a deleted path across every editor pane.
    func closeTabsForDeletedFile(url: URL) {
        for tabManager in paneManager.allTabManagers {
            tabManager.closeTabsForDeletedFile(url: url)
        }
    }

    /// Updates tab URLs in every editor pane to reflect a renamed file or
    /// directory, preserving tab identity. The primary ``primaryTabManager``
    /// alone is not enough — the same file may be open in a split pane, and
    /// the primary TabManager may be orphaned after pane pruning.
    func handleFileRenamed(oldURL: URL, newURL: URL) {
        for tabManager in paneManager.allTabManagers {
            tabManager.handleFileRenamed(oldURL: oldURL, newURL: newURL)
        }
    }

    let toastManager = ToastManager()
    // nonisolated(unsafe) allows deinit to call stopPeriodicSnapshots().
    // RecoveryManager is only mutated on @MainActor; deinit is the only
    // nonisolated access point, and it runs after the last reference is dropped.
    nonisolated(unsafe) private(set) var recoveryManager: RecoveryManager?

    init() {
        workspace.setOnRootNodesChanged { [weak self] nodes in
            guard let self, let rootURL = self.workspace.rootURL else { return }
            self.quickOpenProvider.rebuildIndex(from: nodes, rootURL: rootURL)
            // Agent activity correlation (#1072): when the file tree refreshes
            // (typically a FileSystemWatcher event) and ≥1 agent session is
            // active, attribute newly-modified files to the active session(s).
            self.correlateAgentActivity(rootURL: rootURL)
        }
        workspace.progressTracker = progress
        workspace.gitProvider.progressTracker = progress
        paneManager.configureEditorTabManager = { [weak self] tabManager in
            self?.configureEditorTabManager(tabManager)
        }
        // Wire TerminalManager to PaneManager (lazy wiring)
        terminal.paneManager = paneManager
    }

    deinit {
        // Safe: ProjectManager is @MainActor, so deinit runs on main thread
        // when the last reference is dropped from a MainActor context.
        // recoveryManager is nonisolated(unsafe) to allow this access.
        MainActor.assumeIsolated {
            recoveryManager?.stopPeriodicSnapshots()
        }
    }

    /// Sets up crash recovery for the given project directory.
    /// Called once when the project URL becomes known (from `loadDirectory`).
    func setupRecovery(projectURL: URL) {
        guard recoveryManager == nil else { return }
        let manager = RecoveryManager(projectURL: projectURL)
        manager.tabsProvider = { [weak self] in
            self?.allTabs ?? []
        }
        // The primary manager can temporarily be orphaned from the pane tree,
        // so configure it explicitly as well as every currently visible pane.
        primaryTabManager.recoveryManager = manager
        for tabManager in paneManager.allTabManagers {
            tabManager.recoveryManager = manager
        }
        manager.startPeriodicSnapshots()
        recoveryManager = manager
    }

    /// Applies project-owned services to every editor group, including groups
    /// created later by pane splits or session restoration.
    private func configureEditorTabManager(_ tabManager: TabManager) {
        tabManager.recoveryManager = recoveryManager
        tabManager.onEditorContextChanged = { [weak self] in
            self?.updateEditorContext()
        }
    }

    /// Persists current session (project + open file tabs) to UserDefaults.
    /// Collects tabs from ALL panes so split-pane tabs are not lost on restore.
    func saveSession() {
        guard let rootURL = workspace.rootURL else { return }
        let rootPath = rootURL.path + "/"

        // Gather tabs from all panes (not just the primary tabManager)
        let everyTab = allTabs

        let openFileURLs = everyTab
            .map(\.url)
            .filter { $0.path.hasPrefix(rootPath) }

        // Only persist active file if it belongs to the project
        let activeFileURL: URL? = if let url = activeTabManager.activeTab?.url,
                                      url.path.hasPrefix(rootPath) { url } else { nil }

        // Collect preview modes for markdown tabs that aren't in default (.source) state
        // and belong to the project root
        var previewModes: [String: String]?
        let mdTabs = everyTab.filter {
            $0.isMarkdownFile && $0.previewMode != .source && $0.url.path.hasPrefix(rootPath)
        }
        if !mdTabs.isEmpty {
            previewModes = [:]
            for tab in mdTabs {
                previewModes?[tab.url.path] = tab.previewMode.rawValue
            }
        }

        // Collect tabs with syntax highlighting disabled (large files), scoped to project root
        let disabledTabs = everyTab.filter {
            $0.syntaxHighlightingDisabled && $0.url.path.hasPrefix(rootPath)
        }
        let highlightingDisabledPaths: [String]? = disabledTabs.isEmpty
            ? nil
            : disabledTabs.map(\.url.path)

        // Per-tab editor state (cursor, scroll, folds)
        var editorStates: [String: PerTabEditorState]?
        let tabsWithState = everyTab.filter { tab in
            tab.url.path.hasPrefix(rootPath) && tab.kind == .text
        }
        if !tabsWithState.isEmpty {
            editorStates = [:]
            for tab in tabsWithState {
                editorStates?[tab.url.path] = PerTabEditorState.capture(from: tab)
            }
        }

        // Pinned tabs, scoped to project root
        let pinnedTabs = everyTab.filter {
            $0.isPinned && $0.url.path.hasPrefix(rootPath)
        }
        let pinnedPaths: [String]? = pinnedTabs.isEmpty
            ? nil
            : pinnedTabs.map(\.url.path)

        // Pane layout — always persist (terminal panes need it even with a single editor pane)
        var paneLayoutData: Data?
        var paneTabAssignments: [String: [String]]?
        var activePaneIDString: String?
        var terminalPaneTabCounts: [String: Int]?
        var terminalPaneActiveIndices: [String: Int]?

        paneLayoutData = try? JSONEncoder().encode(paneManager.persistableRoot)
        var assignments: [String: [String]] = [:]
        for (paneID, tm) in paneManager.tabManagers {
            let paths = tm.tabs.map(\.url.path).filter { $0.hasPrefix(rootPath) }
            if !paths.isEmpty {
                assignments[paneID.id.uuidString] = paths
            }
        }
        paneTabAssignments = assignments.isEmpty ? nil : assignments
        activePaneIDString = paneManager.activePaneID.id.uuidString

        // Terminal pane state
        var tpCounts: [String: Int] = [:]
        var tpActiveIndices: [String: Int] = [:]
        for (paneID, state) in paneManager.terminalStates {
            tpCounts[paneID.id.uuidString] = state.tabCount
            if let activeID = state.activeTerminalID,
               let idx = state.terminalTabs.firstIndex(where: { $0.id == activeID }) {
                tpActiveIndices[paneID.id.uuidString] = idx
            }
        }
        terminalPaneTabCounts = tpCounts.isEmpty ? nil : tpCounts
        terminalPaneActiveIndices = tpActiveIndices.isEmpty ? nil : tpActiveIndices

        SessionState.save(
            projectURL: rootURL,
            openFileURLs: openFileURLs,
            activeFileURL: activeFileURL,
            previewModes: previewModes,
            highlightingDisabledPaths: highlightingDisabledPaths,
            editorStates: editorStates,
            pinnedPaths: pinnedPaths,
            terminalPaneTabCounts: terminalPaneTabCounts,
            terminalPaneActiveIndices: terminalPaneActiveIndices,
            paneLayoutData: paneLayoutData,
            paneTabAssignments: paneTabAssignments,
            activePaneID: activePaneIDString
        )
    }

    // MARK: - Convenience accessors (workspace)

    var rootNodes: [FileNode] { workspace.rootNodes }
    var projectName: String { workspace.projectName }
    var rootURL: URL? { workspace.rootURL }
    var gitProvider: GitStatusProvider { workspace.gitProvider }

    func openFolder() { workspace.openFolder() }
    func loadDirectory(url: URL) {
        workspace.loadDirectory(url: url)
        setupRecovery(projectURL: url)
        agentHistory.updateProjectRoot(url)
        Task { await contextFileWriter.setProjectRoot(url) }
        lspManager.setWorkspaceRoot(url)
    }

    // MARK: - Agent activity file-system correlation (#1072)

    /// Modified paths (relative to the project root) already attributed to an
    /// agent session, so the same change isn't recorded repeatedly while the
    /// `FileSystemWatcher` keeps firing for the same edit.
    private var attributedModifiedPaths: Set<String> = []
    /// Whether `attributedModifiedPaths` has been seeded with pre-existing
    /// modifications since an agent became active. Cleared when no agent is
    /// active, so a fresh run attributes only files changed *during* it.
    private var agentActivitySeeded = false

    /// Minimal real data source for the Activity Panel (#1072): attributes
    /// file-tree refreshes to the active agent session(s). The
    /// `FileSystemWatcher` signals only that *something* changed — not which
    /// file — so the changed set is read from `gitProvider.fileStatuses`.
    ///
    /// Conservative heuristic: ignored when no agent is active; the first
    /// refresh after an agent appears seeds the seen-set with whatever was
    /// already changed (so pre-existing changes aren't misattributed), and
    /// only subsequently-changed files are recorded. With several active
    /// sessions attribution falls back to the most-recently-active (see
    /// `AgentActivityStore`).
    ///
    /// "Changed" covers every working-tree state except `.deleted` — agents
    /// routinely create brand-new files (` .untracked`), `git add` files
    /// (`.staged`), and modify already-staged files (`.mixed`); dropping any
    /// of those would make the panel miss the most common agent action.
    private func correlateAgentActivity(rootURL: URL) {
        let active = terminal.agentDetector.activeSessions
        guard !active.isEmpty else {
            attributedModifiedPaths = []
            agentActivitySeeded = false
            return
        }
        let changed = gitProvider.fileStatuses
            .filter { Self.isAttributableStatus($0.value) }
            .map(\.key)
        if !agentActivitySeeded {
            // Seed: treat currently-changed files as pre-existing.
            attributedModifiedPaths = Set(changed)
            agentActivitySeeded = true
            return
        }
        // Prune paths no longer changed (e.g. an agent reverted a file) so a
        // later re-modification is recorded instead of silently dropped.
        attributedModifiedPaths.formIntersection(changed)
        for path in changed where !attributedModifiedPaths.contains(path) {
            attributedModifiedPaths.insert(path)
            agentActivity.noteFileSystemChange(
                at: rootURL.appendingPathComponent(path),
                activeSessions: active
            )
        }
    }

    /// `true` for working-tree states that represent a change an agent could
    /// have made. `.deleted` is excluded (the file no longer exists to open).
    /// `internal` so the attribution filter is unit-testable (the integration
    /// through `correlateAgentActivity` reads main-actor state with no DI seam).
    static func isAttributableStatus(_ status: GitFileStatus) -> Bool {
        switch status {
        case .untracked, .modified, .staged, .added, .conflict, .mixed:
            return true
        case .deleted:
            return false
        }
    }

    // MARK: - Agent history finalization (#1073)

    /// Finalizes any `.done` agent sessions not yet logged into the durable
    /// `AgentHistoryStore`. Called on app termination (and safe to call
    /// periodically). Records heuristically attributed relative paths and a
    /// file-count summary for review. These observations do not authorize
    /// undo; safe reversal requires exact provenance and an inverse change set
    /// (#1183).
    ///
    /// The summary is intentionally file-count only (no `+/-` line counts):
    /// `GitStatusProvider.diffForFile` collapses consecutive diff lines into
    /// block entries, so a line count would be misleading, and computing it
    /// synchronously per file on the main thread at termination would stall
    /// the UI (S2/S3 from the #1075 review).
    func finalizeAgentSessionsForHistory() {
        let doneSessions = terminal.agentDetector.detectedSessions.filter {
            $0.state == .done
        }
        guard !doneSessions.isEmpty else { return }
        guard let root = workspace.rootURL else { return }
        for session in doneSessions {
            let relativePaths = session.filesModified.compactMap { relativePath(from: $0, root: root) }
            agentHistory.finalize(
                session: session,
                summary: "",
                affectedRelativePaths: relativePaths,
                attribution: .heuristic
            )
        }
    }

    /// Returns `url` relative to `root`, or `nil` if `url` is not under `root`.
    /// Resolves symlinks on both sides so a file recorded via a symlinked path
    /// still matches the (resolved) project root (S4 from the #1075 review).
    private func relativePath(from url: URL, root: URL) -> String? {
        // `URL.path(relativeTo:)` was removed in newer SDKs, so derive the
        // relative path manually. `resolvingSymlinksInPath()` canonicalizes
        // both sides so symlinked roots/paths still match.
        let rootPath = root.resolvingSymlinksInPath().path
        let urlPath = url.resolvingSymlinksInPath().path
        guard urlPath == rootPath || urlPath.hasPrefix(rootPath + "/") else { return nil }
        if urlPath == rootPath { return "" }
        return String(urlPath.dropFirst(rootPath.count + 1))
    }

    // MARK: - Convenience accessors (terminal)

    /// All terminal tabs across all terminal panes.
    var allTerminalTabs: [TerminalTab] { terminal.allTerminalTabs }

    /// Whether any terminal pane exists in the layout.
    var hasTerminalPanes: Bool { !paneManager.terminalPaneIDs.isEmpty }

    func startTerminals() { terminal.startTerminals(workingDirectory: workspace.rootURL) }

    /// Creates a new terminal tab in the last-used terminal pane, or creates a new pane.
    func addTerminalTab() {
        terminal.createTerminalTab(
            relativeTo: paneManager.activePaneID,
            workingDirectory: workspace.rootURL
        )
    }

    // MARK: - Editor context for terminal

    /// Pushes the current editor context (active file, cursor position) to the
    /// context file writer. Called when the active tab or cursor position changes.
    func updateEditorContext() {
        guard let rootURL = workspace.rootURL else { return }
        let tab = activeTabManager.activeTab
        let relativePath = ContextFileWriter.relativePath(
            fileURL: tab?.url,
            rootURL: rootURL
        )
        Task {
            await contextFileWriter.update(
                currentFile: relativePath,
                cursorLine: tab?.cursorLine,
                cursorColumn: tab?.cursorColumn
            )
        }
    }

    /// Cleans up the context file. Called when the project window closes.
    func cleanupEditorContext() {
        Task {
            await contextFileWriter.cleanup()
        }
    }

    /// Shuts down all language servers for this project. Called on window
    /// close and app termination so no orphan language-server process
    /// survives (acceptance criterion #1010). Safe to call multiple times.
    func shutdownLanguageServers() {
        lspManager.shutdownAll()
    }
}
