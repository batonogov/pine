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
    /// The primary TabManager (first pane). For the *focused* pane's TabManager,
    /// use ``activeTabManager`` which delegates to ``PaneManager/activeTabManager``.
    let tabManager = TabManager()
    let searchProvider = ProjectSearchProvider()
    let quickOpenProvider = QuickOpenProvider()
    let progress = ProgressTracker()
    let contextFileWriter = ContextFileWriter()
    @ObservationIgnored
    private(set) lazy var paneManager = PaneManager(existingTabManager: tabManager)

    /// Returns the TabManager for the currently focused pane.
    /// Falls back to the primary ``tabManager`` when paneManager has a single pane.
    var activeTabManager: TabManager {
        paneManager.activeTabManager ?? tabManager
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
    let toastManager = ToastManager()
    // nonisolated(unsafe) allows deinit to call stopPeriodicSnapshots().
    // RecoveryManager is only mutated on @MainActor; deinit is the only
    // nonisolated access point, and it runs after the last reference is dropped.
    nonisolated(unsafe) private(set) var recoveryManager: RecoveryManager?

    init() {
        workspace.setOnRootNodesChanged { [weak self] nodes in
            guard let self, let rootURL = self.workspace.rootURL else { return }
            self.quickOpenProvider.rebuildIndex(from: nodes, rootURL: rootURL)
        }
        workspace.progressTracker = progress
        workspace.gitProvider.progressTracker = progress
        tabManager.onEditorContextChanged = { [weak self] in
            self?.updateEditorContext()
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
        tabManager.recoveryManager = manager
        manager.startPeriodicSnapshots()
        recoveryManager = manager
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

        paneLayoutData = try? JSONEncoder().encode(paneManager.root)
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
        Task { await contextFileWriter.setProjectRoot(url) }
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
}
