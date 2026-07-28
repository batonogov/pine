//
//  ProjectManager.swift
//  Pine
//
//  Created by Федор Батоногов on 10.03.2026.
//

import AppKit
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
    let lspManager: LSPManager
    /// Project-scoped diagnostics aggregate for the Problems panel (#1236).
    /// Merges LSP diagnostics (read live) with config-validator diagnostics
    /// (revision-guarded). Owned here so every window observes the same truth.
    let problemsController: ProblemsPanelController
    /// Weak anchor for every native dialog owned by this project.
    ///
    /// The window owns the visible project surface; keeping this reference
    /// weak prevents the project model (which may remain alive in the
    /// background) from extending the NSWindow lifetime.
    @ObservationIgnored
    private(set) weak var dialogOwnerWindow: NSWindow?
    @ObservationIgnored
    private var dialogOperationTail: Task<Void, Never>?
    @ObservationIgnored
    private var dialogOperationGeneration = 0
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

    /// Validates an exact dirty-buffer authorization across every editor
    /// pane. This is intentionally separate from commit so Quit can validate
    /// every project before mutating any project.
    func canCommitDiscard(
        _ authorization: DirtyEditorContentAuthorization
    ) -> Bool {
        authorization.covers(allDirtyTabs)
    }

    /// Commits an already validated "Don't Save" decision across panes.
    /// There is no suspension between the project-level validation and these
    /// per-manager commits, so another MainActor mutation cannot interleave.
    @discardableResult
    func commitDiscard(
        _ authorization: DirtyEditorContentAuthorization,
        postReloadNotifications: Bool = true
    ) -> Bool {
        guard canCommitDiscard(authorization) else { return false }
        let reloads = allDirtyTabs.map {
            ReloadedTab(url: $0.url, text: $0.savedContent)
        }
        for tabManager in paneManager.allTabManagers {
            guard tabManager.discardChanges(
                authorizedBy: authorization,
                postReloads: false
            ) else {
                return false
            }
        }
        if postReloadNotifications {
            for reload in reloads {
                NotificationCenter.default.post(
                    name: .tabReloadedFromDisk,
                    object: nil,
                    userInfo: ["url": reload.url, "text": reload.text]
                )
            }
        }
        return true
    }

    /// Saves all tabs across all panes. Returns false if any save fails.
    @discardableResult
    func saveAllPaneTabs() -> Bool {
        for tabMgr in paneManager.tabManagers.values {
            guard tabMgr.saveAllTabs() else { return false }
        }
        return true
    }

    /// Window-scoped save-all used by close and termination decisions.
    @discardableResult
    func saveAllPaneTabs(context: DialogPresentationContext) async -> Bool {
        for tabManager in paneManager.tabManagers.values {
            guard await tabManager.saveAllTabs(context: context) else { return false }
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
    /// Autosave uses the UI-free throwing primitive directly. Close and quit
    /// use async, window-scoped save overloads after their sheet decisions;
    /// neither runs inside a `ButtonAction`.
    ///
    /// The disk write is deferred by ~1 runloop (imperceptible at 60 Hz);
    /// the dirty indicator and git status settle one frame later.
    func saveActiveTabFromMenu() {
        let context = DialogPresenter.forProject(self)
        let tabManager = activeTabManager
        let activeID = tabManager.activeTabID
        performMenuSave { [weak tabManager] in
            guard let tabManager,
                  let activeID,
                  let index = tabManager.tabs.firstIndex(where: { $0.id == activeID }) else {
                return false
            }
            return await tabManager.saveTab(at: index, context: context)
        }
    }

    /// Cmd+Option+S (Save All) from the File menu. Same reentrancy rationale
    /// as ``saveActiveTabFromMenu`` — Save All can also mutate `@Observable`
    /// per-pane tab state synchronously when format-on-save changes content.
    func saveAllTabsFromMenu() {
        let context = DialogPresenter.forProject(self)
        performMenuSave { [weak self] in
            guard let self else { return false }
            return await saveAllPaneTabs(context: context)
        }
    }

    /// Shared deferral for menu-triggered saves. Runs the save `operation`
    /// on the next runloop (outside any `ButtonAction` callstack), then
    /// refreshes git status + line diffs when it succeeded.
    private func performMenuSave(
        _ operation: @escaping @MainActor () async -> Bool
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                guard await operation() else { return }
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
    /// Tracks active and recent user-task runs for the task execution UI
    /// (issue #1246). Owned by the project window so the output surface,
    /// toast, and Cancel button all share one source of truth.
    let taskRunStore = UserTaskRunStore()
    /// Recovery snapshots and their lifecycle are owned by the main actor.
    private(set) var recoveryManager: RecoveryManager?

    init(lspSettings: LSPSettings = .shared) {
        self.lspManager = LSPManager(settings: lspSettings)
        self.problemsController = ProblemsPanelController(lspManager: lspManager)
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
        problemsController.configureDocumentStatesProvider { [weak self] in
            self?.problemsDocumentStates ?? []
        }
        // Wire TerminalManager to PaneManager (lazy wiring)
        terminal.paneManager = paneManager
    }

    func bindDialogOwnerWindow(_ window: NSWindow) {
        dialogOwnerWindow = window
    }

    func unbindDialogOwnerWindow(_ window: NSWindow) {
        guard dialogOwnerWindow === window else { return }
        dialogOwnerWindow = nil
    }

    /// Waits for the project window to become a valid native dialog owner.
    /// Project scenes are created asynchronously, so launch/drop flows cannot
    /// safely assume a fixed delay is enough before opening a large file.
    ///
    /// The retry loop is bounded and cancellation-aware. Tests can inject the
    /// wait and eligibility predicate to exercise delayed binding without
    /// depending on AppKit timing.
    func awaitDialogOwnerWindow(
        maximumAttempts: Int = 80,
        waitForNextAttempt: (@MainActor () async -> Void)? = nil,
        isEligible: (@MainActor (NSWindow) -> Bool)? = nil
    ) async -> NSWindow? {
        let wait = waitForNextAttempt ?? {
            try? await Task.sleep(for: .milliseconds(25))
        }
        let acceptsWindow = isEligible ?? {
            DialogPresenter.isEligibleApplicationOwner($0)
        }

        for _ in 0..<max(0, maximumAttempts) {
            guard !Task.isCancelled else { return nil }
            if let window = dialogOwnerWindow, acceptsWindow(window) {
                return window
            }
            await wait()
        }

        guard !Task.isCancelled,
              let window = dialogOwnerWindow,
              acceptsWindow(window) else {
            return nil
        }
        return window
    }

    /// Serializes stateful dialog workflows whose model snapshot must be
    /// recomputed only after an earlier decision finishes. The native sheet
    /// coordinator serializes presentation, while this queue prevents two
    /// filesystem events from taking stale tab snapshots before either sheet
    /// resolves.
    func enqueueDialogOperation(
        _ operation: @escaping @MainActor () async -> Void
    ) {
        let previous = dialogOperationTail
        dialogOperationGeneration &+= 1
        let generation = dialogOperationGeneration
        dialogOperationTail = Task { @MainActor [weak self] in
            if let previous {
                await previous.value
            }
            guard let self, !Task.isCancelled else { return }
            await operation()
            if dialogOperationGeneration == generation {
                dialogOperationTail = nil
            }
        }
    }

    isolated deinit {
        dialogOperationTail?.cancel()
        recoveryManager?.stopPeriodicSnapshots()
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
        tabManager.dialogContextProvider = { [weak self] in
            guard let self else { return .unscoped }
            return DialogPresenter.forProject(self)
        }
        tabManager.onEditorContextChanged = { [weak self] in
            guard let self else { return }
            self.updateEditorContext()
            self.problemsController.refreshDocumentOwnership()
        }
    }

    /// Visible editor documents with exact project/pane/tab/revision
    /// ownership. Config validators and LSP views exist only for active tabs,
    /// so inactive tabs intentionally do not validate an old panel record.
    private var problemsDocumentStates: [ProblemsDocumentState] {
        paneManager.root.leafIDs.compactMap { paneID in
            guard paneManager.root.content(for: paneID) == .editor,
                  let tabManager = paneManager.tabManager(for: paneID) else {
                return nil
            }
            guard let tab = tabManager.activeTab else { return nil }
            return ProblemsDocumentState(
                owner: problemsController.documentOwner(
                    paneID: paneID,
                    tabID: tab.id,
                    uri: tab.url.absoluteString
                ),
                contentRevision: tab.contentVersion,
                isFocusedPane: paneManager.activePaneID == paneID
            )
        }
    }

    /// Routes a Problems row to the editor instance that produced it. The
    /// controller proves freshness first, then this final check confirms the
    /// live pane/tab/URL/content revision before changing focus.
    @discardableResult
    func navigateToProblem(
        _ diagnostic: ProblemsFlatDiagnostic
    ) -> Bool {
        guard let target = problemsController.navigationTarget(
            for: diagnostic
        ),
        let tabManager = paneManager.tabManager(for: target.owner.paneID),
        let tab = tabManager.activeTab,
        tab.id == target.owner.tabID,
        tab.url.absoluteString == target.owner.uri else {
            return false
        }

        let expectedContentRevision: UInt64
        switch target.revision {
        case .editor(let revision):
            expectedContentRevision = revision
        case .lsp(_, let contentRevision):
            expectedContentRevision = contentRevision
        }
        guard tab.contentVersion == expectedContentRevision,
              paneManager.selectEditorTab(
                  target.owner.tabID,
                  in: target.owner.paneID
              ) else {
            return false
        }

        tabManager.pendingGoToLocation = EditorNavigationLocation(
            line: target.line,
            column: target.column
        )
        return true
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
        var paneActiveEditorPaths: [String: String]?
        var panePinnedPaths: [String: [String]]?
        var paneTransientPreviewPaths: [String: String]?
        var globalTabSwitchOrder: [SessionTabReference]?
        var terminalPaneTabCounts: [String: Int]?
        var terminalPaneActiveIndices: [String: Int]?

        paneLayoutData = try? JSONEncoder().encode(paneManager.persistableRoot)
        var assignments: [String: [String]] = [:]
        var activeEditorPaths: [String: String] = [:]
        var pinnedPathsByPane: [String: [String]] = [:]
        var transientPreviewPaths: [String: String] = [:]
        for (paneID, tm) in paneManager.tabManagers {
            let paneKey = paneID.id.uuidString
            let paths = tm.tabs.map(\.url.path).filter { $0.hasPrefix(rootPath) }
            if !paths.isEmpty {
                assignments[paneKey] = paths
            }
            if let activePath = tm.activeTab?.url.path,
               activePath.hasPrefix(rootPath) {
                activeEditorPaths[paneKey] = activePath
            }
            let panePins = tm.tabs
                .filter { $0.isPinned && $0.url.path.hasPrefix(rootPath) }
                .map(\.url.path)
            if !panePins.isEmpty {
                pinnedPathsByPane[paneKey] = panePins
            }
            if let previewPath = tm.tabs.first(where: {
                $0.isTransientPreview && $0.url.path.hasPrefix(rootPath)
            })?.url.path {
                transientPreviewPaths[paneKey] = previewPath
            }
        }
        paneTabAssignments = assignments.isEmpty ? nil : assignments
        paneActiveEditorPaths = activeEditorPaths.isEmpty ? nil : activeEditorPaths
        panePinnedPaths = pinnedPathsByPane.isEmpty ? nil : pinnedPathsByPane
        paneTransientPreviewPaths = transientPreviewPaths.isEmpty ? nil : transientPreviewPaths
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
        let persistedSwitchOrder: [SessionTabReference] = paneManager
            .validGlobalTabSwitchOrder().compactMap { identity -> SessionTabReference? in
            switch identity.contentType {
            case .editor:
                guard let path = paneManager.tabManager(for: identity.paneID)?.tabs
                    .first(where: { $0.id == identity.tabID })?.url.path,
                      path.hasPrefix(rootPath) else { return nil }
                return SessionTabReference.editor(paneID: identity.paneID, filePath: path)
            case .terminal:
                guard let index = paneManager.terminalState(for: identity.paneID)?
                    .terminalTabs.firstIndex(where: { $0.id == identity.tabID }) else {
                    return nil
                }
                return SessionTabReference.terminal(paneID: identity.paneID, tabIndex: index)
            }
        }
        globalTabSwitchOrder = persistedSwitchOrder.isEmpty ? nil : persistedSwitchOrder

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
            activePaneID: activePaneIDString,
            paneActiveEditorPaths: paneActiveEditorPaths,
            panePinnedPaths: panePinnedPaths,
            paneTransientPreviewPaths: paneTransientPreviewPaths,
            globalTabSwitchOrder: globalTabSwitchOrder
        )
    }

    // MARK: - Convenience accessors (workspace)

    var rootNodes: [FileNode] { workspace.rootNodes }
    var projectName: String { workspace.projectName }
    var rootURL: URL? { workspace.rootURL }
    var gitProvider: GitStatusProvider { workspace.gitProvider }

    func openFolder() {
        let context = DialogPresenter.forProject(self)
        Task { @MainActor in
            await workspace.openFolder(context: context)
        }
    }
    func loadDirectory(url: URL) {
        workspace.loadDirectory(url: url)
        setupRecovery(projectURL: url)
        agentHistory.updateProjectRoot(url)
        synchronizeAgentHandoff(projectRoot: url)
        lspManager.setWorkspaceRoot(url)
        #if DEBUG
        seedAgentActivityUITestFixture(projectURL: url)
        seedAgentAttentionUITestFixture(projectURL: url)
        #endif
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

    #if DEBUG
    /// Seeds deterministic rows only when an explicit UI-test launch argument
    /// is present. Production builds contain no fixture path.
    private func seedAgentActivityUITestFixture(projectURL: URL) {
        let arguments = ProcessInfo.processInfo.arguments
        let seedAll = arguments.contains("--ui-test-agent-activity-all")
        let seedHeuristic = arguments.contains(
            "--ui-test-agent-activity-heuristic"
        )
        guard seedAll || seedHeuristic, agentActivity.actions.isEmpty else {
            return
        }

        let firstSession = UUID(
            uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1)
        )
        let secondSession = UUID(
            uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2)
        )
        let sessionLinkedActionID = UUID(
            uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1)
        )
        let inferredActionID = UUID(
            uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 2)
        )
        let ambiguousActionID = UUID(
            uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 3)
        )
        let toolActionID = UUID(
            uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 4)
        )
        let mainFile = projectURL.appendingPathComponent("main.swift")

        if seedAll {
            agentActivity.record(
                AgentAction(
                    id: sessionLinkedActionID,
                    sessionID: firstSession,
                    agentType: .claudeCode,
                    kind: .command,
                    status: .completed,
                    summary: "UI fixture: session-linked"
                )
            )
            agentActivity.record(
                AgentAction(
                    id: toolActionID,
                    sessionID: secondSession,
                    agentType: .codex,
                    kind: .toolCall,
                    status: .inProgress,
                    summary: "UI fixture: tool"
                )
            )
        }
        agentActivity.record(
            AgentAction(
                id: inferredActionID,
                attribution: .inferred(
                    AgentActionCandidate(
                        sessionID: firstSession,
                        agentType: .claudeCode
                    )
                ),
                kind: .fileWrite,
                status: .completed,
                fileURL: mainFile,
                summary: "UI fixture: inferred"
            )
        )
        agentActivity.record(
            AgentAction(
                id: ambiguousActionID,
                attribution: .ambiguous(candidates: [
                    AgentActionCandidate(
                        sessionID: firstSession,
                        agentType: .claudeCode
                    ),
                    AgentActionCandidate(
                        sessionID: secondSession,
                        agentType: .codex
                    )
                ]),
                kind: .fileWrite,
                status: .failed,
                fileURL: mainFile,
                summary: "UI fixture: ambiguous"
            )
        )
    }

    /// Creates two deterministic terminal-backed summaries for keyboard and
    /// accessibility UI tests. Production and ordinary debug launches never
    /// enter this path.
    private func seedAgentAttentionUITestFixture(projectURL: URL) {
        guard ProcessInfo.processInfo.arguments.contains(
            "--ui-test-agent-attention"
        ) else {
            return
        }
        let paneID = paneManager.createTerminalPaneAtBottom(
            workingDirectory: projectURL
        )
        guard let state = paneManager.terminalState(for: paneID),
              let firstTab = state.activeTab else {
            return
        }
        firstTab.name = "Waiting agent"
        firstTab.agentSession = AgentSession(
            id: UUID(
                uuid: (
                    0, 0, 0, 0, 0, 0, 0, 0,
                    0, 0, 0, 0, 0, 0, 0, 1
                )
            ),
            agentType: .claudeCode,
            state: .waitingInput
        )

        guard let secondTab = paneManager.addTerminalTab(
            in: paneID,
            workingDirectory: projectURL
        ) else {
            return
        }
        secondTab.name = "Executing agent"
        secondTab.agentSession = AgentSession(
            id: UUID(
                uuid: (
                    0, 0, 0, 0, 0, 0, 0, 0,
                    0, 0, 0, 0, 0, 0, 0, 2
                )
            ),
            agentType: .codex,
            state: .executing
        )
        state.activeTerminalID = firstTab.id
    }
    #endif

    /// Minimal real data source for the Activity Panel (#1072): attributes
    /// file-tree refreshes to the active agent session(s). The
    /// `FileSystemWatcher` signals only that *something* changed — not which
    /// file — so the changed set is read from `gitProvider.fileStatuses`.
    ///
    /// Conservative heuristic: ignored when no agent is active; the first
    /// refresh after an agent appears seeds the seen-set with whatever was
    /// already changed (so pre-existing changes aren't misattributed), and
    /// only subsequently-changed files are recorded. With several live
    /// sessions the action retains every candidate as ambiguous and selects
    /// no owner (see `AgentActivityStore`).
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
        let openFiles = allTabs.compactMap {
            ContextFileWriter.relativePath(fileURL: $0.url, rootURL: rootURL)
        }
        Task {
            await contextFileWriter.update(
                openFiles: openFiles,
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

    /// Applies the global opt-in to this project and immediately publishes or
    /// revokes its bounded read-only snapshot.
    func synchronizeAgentHandoff(projectRoot: URL? = nil) {
        let rootURL = projectRoot ?? workspace.rootURL
        let isEnabled = AgentHandoffSettings.shared.isReadOnlyContextEnabled
        Task {
            if let rootURL {
                await contextFileWriter.setProjectRoot(rootURL)
            }
            await contextFileWriter.setReadOnlySharingEnabled(isEnabled)
            if isEnabled {
                self.updateEditorContext()
            }
        }
    }

    /// Shuts down all language servers for this project. Called on window
    /// close and app termination so no orphan language-server process
    /// survives (acceptance criterion #1010). Safe to call multiple times.
    func shutdownLanguageServers() {
        lspManager.shutdownAll()
    }
}
