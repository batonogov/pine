//
//  ContentView.swift
//  Pine
//
//  Created by Федор Батоногов on 09.03.2026.
//

import SwiftUI

// MARK: - Main ContentView (composition root)

struct ContentView: View {
    @Environment(ProjectManager.self) var projectManager
    @Environment(WorkspaceManager.self) var workspace
    @Environment(TerminalManager.self) var terminal
    /// The project's *primary* TabManager (root editor pane), injected from
    /// `PineApp.ProjectWindowView`. This is **not** the active pane's
    /// TabManager — for command/action routing that must target the focused
    /// editor pane, use ``activeTabManager`` instead. The environment
    /// injection is kept so sidebar rows (`FileNodeRow`) and other subviews
    /// that do not depend on focus can still resolve a TabManager.
    ///
    /// See issues #971 and #998: the previous `tabManager` naming conflated
    /// primary with active and caused commands to target the wrong pane in
    /// split layouts.
    @Environment(TabManager.self) var primaryTabManager
    @Environment(PaneManager.self) var paneManager
    @Environment(ProjectRegistry.self) var registry
    @Environment(\.openWindow) var openWindow

    @Environment(\.controlActiveState) var controlActiveState

    // MARK: - State (internal for cross-file extension access in ContentView+Helpers)

    @State var selectedNode: FileNode?
    @State var columnVisibility: NavigationSplitViewVisibility = .all
    @State var lineDiffs: [GitLineDiff] = []
    @State var didRestoreSession = false
    @State var isSearchPresented = false
    @State var recoveryEntries: [(UUID, RecoveryEntry)] = []
    @State var showRecoveryDialog = false
    @State var isDragTargeted = false
    @State var isQuickOpenPresented = false
    @State var isCommandPalettePresented = false
    @State var isSymbolNavigatorPresented = false
    @State var isBranchSwitcherPresented = false
    @State var showGoToLine = false
    @State var isAgentActivityPresented = false
    @State var isAgentHistoryPresented = false
    /// Agent attention-list overlay (#1112).
    @State var showAgentAttention = false
    @AppStorage("minimapVisible") var isMinimapVisible = true
    @AppStorage(BlameConstants.storageKey) var isBlameVisible = true
    @AppStorage("wordWrapEnabled") var isWordWrapEnabled = true

    /// The TabManager for the currently focused editor pane. Use this for
    /// any menu command, go-to request, search result, status bar binding,
    /// or diff/inline-diff action that should target the active editor.
    /// Falls back to ``primaryTabManager`` when no editor pane is focused
    /// (e.g. terminals-only layout), matching ``ProjectManager/activeTabManager``.
    var activeTabManager: TabManager { projectManager.activeTabManager }

    var activeTab: EditorTab? { activeTabManager.activeTab }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarSearchableContent(
                selectedNode: $selectedNode,
                onFileOpen: { node, disposition in
                    handleFileSelection(node, disposition: disposition)
                }
            )
            .accessibilityIdentifier(AccessibilityID.sidebar)
            .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 400)
            .toolbar {
                ToolbarItem {
                    Button {
                        if let url = registry.openProjectViaPanel() {
                            openWindow(value: url)
                        }
                    } label: {
                        Image(systemName: "folder.badge.plus")
                    }
                    .help(Strings.openFolderTooltip)
                }
            }
        } detail: {
            detailContent
        }
        .overlay(alignment: .top) {
            ToastOverlay()
        }
        .modifier(ProjectSearchModifier(
            projectManager: projectManager,
            isSearchPresented: $isSearchPresented
        ))
        .frame(minWidth: 800, minHeight: 500)
        .navigationTitle(workspace.projectName)
        .navigationSubtitle(branchSubtitle)
        .background {
            BranchSubtitleClickHandler(
                gitProvider: workspace.gitProvider,
                isGitRepository: workspace.gitProvider.isGitRepository
            )
            DocumentEditedTracker(isEdited: projectManager.hasUnsavedChanges)
            RepresentedFileTracker(url: activeTab?.url ?? workspace.rootURL)
        }
        .task {
            if restoreSessionIfNeeded() {
                refreshLineDiffs()
            }
            checkForRecovery()
            syncSidebarSelection()
            applySearchQueryFromEnvironment()
            refreshBlame()
        }
        .sheet(isPresented: $showRecoveryDialog) {
            RecoveryDialogView(
                entries: recoveryEntries,
                onRecover: { recoverTabs() },
                onDiscard: { discardRecovery() }
            )
        }
        .overlay { agentAttentionOverlay }
        .sheet(isPresented: $isQuickOpenPresented) {
            QuickOpenView(isPresented: $isQuickOpenPresented)
                .environment(projectManager)
        }
        .onReceive(NotificationCenter.default.publisher(for: .showQuickOpen)) { _ in
            // Defer to break reentrancy (#1051): mutating @State
            // synchronously from a menu→notification callstack collides with
            // the button-action's exclusive access to SwiftUI storage →
            // exclusivity abort.
            DispatchQueue.main.async {
                isQuickOpenPresented = true
            }
        }
        .sheet(isPresented: $isCommandPalettePresented) {
            CommandPaletteView(
                isPresented: $isCommandPalettePresented,
                items: CommandPaletteCatalog.makeItems(
                    tasks: ExtensibilityManager.shared.tasks.tasks,
                    keybindings: ExtensibilityManager.shared.keybindings,
                    context: UserCommandInvocationRouter.context(
                        for: projectManager
                    )
                ),
                onInvoke: invokeCommandPaletteItem
            )
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .showCommandPalette)
        ) { _ in
            // Notification delivery is synchronous. Defer the @State write
            // to avoid re-entering SwiftUI storage from a menu/keybinding
            // dispatch call stack (the #1051 exclusivity-abort family).
            DispatchQueue.main.async {
                isCommandPalettePresented = true
            }
        }
        .sheet(isPresented: $isSymbolNavigatorPresented) {
            SymbolNavigatorView(isPresented: $isSymbolNavigatorPresented)
                .environment(projectManager)
        }
        .onReceive(NotificationCenter.default.publisher(for: .showSymbolNavigator)) { _ in
            guard activeTabManager.activeTab != nil else { return }
            // Defer to break reentrancy (#1051).
            DispatchQueue.main.async {
                isSymbolNavigatorPresented = true
            }
        }
        .sheet(isPresented: $isBranchSwitcherPresented) {
            BranchSwitcherView(
                gitProvider: workspace.gitProvider,
                isPresented: $isBranchSwitcherPresented
            )
            .padding(12)
        }
        .onReceive(NotificationCenter.default.publisher(for: .showBranchSwitcher)) { notification in
            guard Self.shouldPresentBranchSwitcher(
                notificationObject: notification.object,
                currentProject: projectManager,
                isKeyWindow: controlActiveState == .key,
                isGitRepository: workspace.gitProvider.isGitRepository
            ) else { return }
            // Defer to break reentrancy (#1051).
            DispatchQueue.main.async {
                isBranchSwitcherPresented = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .symbolNavigate)) { notification in
            guard let offset = notification.userInfo?["offset"] as? Int,
                  let tab = activeTabManager.activeTab else { return }
            // Defer to break reentrancy (#1051): pendingGoToLine is an
            // @Observable mutation on TabManager.
            DispatchQueue.main.async {
                // Convert the symbol's UTF-16 offset to a 1-based line and route
                // through `pendingGoToLine` on the active pane's TabManager so
                // the focused `PaneLeafView` performs the actual navigation.
                // The previous implementation wrote a `GoToRequest` into root
                // `ContentView` state that no `PaneLeafView` ever consumed.
                let line = Self.lineNumber(forOffset: offset, in: tab.content)
                activeTabManager.pendingGoToLine = line
            }
        }
        .sheet(isPresented: $showGoToLine) {
            GoToLineView(
                totalLines: totalLineCount,
                isPresented: $showGoToLine,
                onGoTo: { line, column in
                    guard activeTabManager.activeTab != nil else { return }
                    // Route through `pendingGoToLine` so the focused
                    // `PaneLeafView` performs the navigation. `column` is
                    // honored by the line-based protocol as the line's start.
                    _ = column
                    activeTabManager.pendingGoToLine = line
                }
            )
        }
        .modifier(AgentActivityPresenter(
            isPresented: $isAgentActivityPresented,
            store: projectManager.agentActivity,
            onSelect: { url in
                isAgentActivityPresented = false
                openFileFromActivity(url)
            }
        ))
        .modifier(AgentHistoryPresenter(
            isPresented: $isAgentHistoryPresented,
            store: projectManager.agentHistory
        ))
        .onChange(of: workspace.rootURL) { _, _ in
            lineDiffs = []
            projectManager.quickOpenProvider.invalidateIndex()
            projectManager.saveSession()
            applySearchQueryFromEnvironment()
        }
        .onChange(of: activeTabManager.activeTabID) { _, _ in
            syncSidebarSelection()
            refreshLineDiffs()
            refreshBlame()
            projectManager.saveSession()
        }
        .modifier(BlameObserver(
            isBlameVisible: isBlameVisible,
            onRefresh: { refreshBlame() }
        ))
        .onChange(of: workspace.rootNodes) { _, _ in
            if restoreSessionIfNeeded() {
                refreshLineDiffs()
                refreshBlame()
            }
            syncSidebarSelection()
        }
        .onChange(of: primaryTabManager.tabs.count) { _, _ in
            // Note: this observes only the primary pane's tab count. Tabs in
            // other split panes are still saved by `projectManager.saveSession()`
            // (which iterates every pane); this observer is a best-effort
            // trigger for the common single-pane case and is preserved for
            // backward compatibility.
            projectManager.saveSession()
        }
        .modifier(GitAndNotificationObserver(
            lineDiffs: $lineDiffs,
            columnVisibility: $columnVisibility,
            isSearchPresented: $isSearchPresented,
            showGoToLine: $showGoToLine,
            onRefreshLineDiffs: { refreshLineDiffs() },
            onRefreshBlame: { refreshBlame() },
            onCloseTab: { closeTabWithConfirmation($0) },
            onOpenNewProject: { openNewProject() },
            onHandleFileDeletion: { handleFileDeletion($0) },
            onHandleExternalChanges: { handleExternalChanges($0) },
            onNavigateToChange: { navigateToChange(direction: $0) },
            onInlineDiffAction: { handleInlineDiffAction($0) }
        ))
        .onReceive(NotificationCenter.default.publisher(for: .toggleWordWrap)) { _ in
            handleToggleWordWrap()
        }
        .onReceive(NotificationCenter.default.publisher(for: .revealInSidebar)) { notification in
            handleRevealInSidebar(notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: .sendTextToTerminal)) { notification in
            handleSendTextToTerminal(notification)
        }
    }

    /// Detail pane content: editor area + status bar. Broken out into its
    /// own computed property because the `StatusBarView(…)` initializer with
    /// its multi-line terminal-toggle closure pushes the `body` modifier
    /// chain past the SwiftUI type-checker's budget (#1112).
    @ViewBuilder
    private var detailContent: some View {
        VStack(spacing: 0) {
            editorArea
                .frame(maxHeight: .infinity)
            StatusBarView(
                gitProvider: workspace.gitProvider,
                paneManager: paneManager,
                tabManager: activeTabManager,
                progress: projectManager.progress,
                onToggleTerminal: {
                    if paneManager.terminalPaneIDs.isEmpty {
                        terminal.focusOrCreateTerminal(
                            relativeTo: paneManager.activePaneID,
                            workingDirectory: workspace.rootURL
                        )
                    } else {
                        // Warn before stopping tabs with foreground processes
                        guard TabCloseHelper.confirmTerminalProcessStop(
                            tabs: terminal.allTerminalTabs
                        ) else { return }
                        // Hide all terminal panes
                        for paneID in paneManager.terminalPaneIDs {
                            if let state = paneManager.terminalState(for: paneID) {
                                for tab in state.terminalTabs { tab.stop() }
                            }
                            paneManager.removePane(paneID)
                        }
                    }
                },
                onShowAttention: {
                    withAnimation(PineAnimation.overlay) {
                        showAgentAttention = true
                    }
                }
            )
        }
    }

    /// Agent attention-list overlay (#1112). Broken out into its own
    /// computed property so the SwiftUI type-checker can resolve `body` in
    /// reasonable time — an inline `.overlay { CommandOverlayView { … } }`
    /// pushes the already-large `body` past the type-checker's budget.
    /// Returns `AnyView` to erase the `CommandOverlayView<…>` generic from the
    /// call site (the body modifier chain is already near the inference
    /// limit); the cost is negligible since the overlay is rarely shown.
    private var agentAttentionOverlay: AnyView {
        guard showAgentAttention else { return AnyView(EmptyView()) }
        return AnyView(
            CommandOverlayView(isPresented: $showAgentAttention) {
                AgentAttentionOverlay(
                    summaries: AgentStatusSummary.activeSummaries(in: paneManager)
                ) { paneID, tabID in
                    paneManager.activePaneID = paneID
                    paneManager.terminalState(for: paneID)?.activeTerminalID = tabID
                    withAnimation(PineAnimation.overlay) {
                        showAgentAttention = false
                    }
                }
            }
        )
    }

    /// Branch subtitle as a plain String to avoid generating a localization key.
    var branchSubtitle: String {
        Self.branchSubtitle(
            isGitRepo: workspace.gitProvider.isGitRepository,
            branchName: workspace.gitProvider.currentBranch
        )
    }

    /// Builds the toolbar subtitle for the current git branch.
    /// Kept as a static function for testability.
    static func branchSubtitle(isGitRepo: Bool, branchName: String) -> String {
        isGitRepo ? "\(branchName) ▾" : ""
    }

    static func shouldPresentBranchSwitcher(
        notificationObject: Any?,
        currentProject: ProjectManager,
        isKeyWindow: Bool,
        isGitRepository: Bool
    ) -> Bool {
        guard isGitRepository else { return false }
        guard let notificationObject else { return isKeyWindow }
        guard let targetProject = notificationObject as? ProjectManager else { return false }
        return targetProject === currentProject
    }

    private func invokeCommandPaletteItem(_ item: CommandPaletteItem) {
        switch item.id {
        case .builtIn(let command):
            UserCommandInvocationRouter.dispatch(
                command,
                projectManager: projectManager
            )
        case .task(let id):
            guard let task = ExtensibilityManager.shared.tasks.task(forID: id) else {
                return
            }
            UserTaskInvocationController.invoke(
                task,
                projectManager: projectManager
            )
        }
    }

    // MARK: - Subview builders

    @ViewBuilder
    var editorArea: some View {
        PaneTreeView(node: paneManager.root)
    }

}

// MARK: - Preview

#Preview {
    let projectManager = ProjectManager()
    let registry = ProjectRegistry()
    ContentView()
        .environment(projectManager)
        .environment(projectManager.workspace)
        .environment(projectManager.terminal)
        .environment(projectManager.primaryTabManager)
        .environment(projectManager.paneManager)
        .environment(projectManager.toastManager)
        .environment(registry)
}
