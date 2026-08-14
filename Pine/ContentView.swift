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
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    // MARK: - State (internal for cross-file extension access in ContentView+Helpers)

    @State var selectedNode: FileNode?
    @State var columnVisibility: NavigationSplitViewVisibility = .all
    @State var lineDiffs: [GitLineDiff] = []
    @State var didRestoreSession = false
    @State var isSearchPresented = false
    @State var recoveryEntries: [(UUID, RecoveryEntry)] = []
    @State var showRecoveryDialog = false
    @State var isDragTargeted = false
    @State var isBranchSwitcherPresented = false
    @State var isAgentActivityPresented = false
    @State var isAgentHistoryPresented = false
    #if DEBUG
    @State var didSeedAccessibilityDirtyBuffer = false
    #endif
    /// Shared command-overlay router (#975). Owns the single active navigation
    /// overlay (including Agent Attention)
    /// and captures/restores the previous AppKit first responder.
    @State var commandOverlayRouter = CommandOverlayRouter()
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
                        Task { @MainActor in
                            // Wait for the project window to bind its dialog
                            // owner before capturing the presentation context;
                            // otherwise the panel silently aborts right after
                            // the window appears or is replaced (#1344).
                            if let url = await registry.openProjectViaPanel(for: projectManager) {
                                openWindow(value: url)
                            }
                        }
                    } label: {
                        Image(systemName: "folder.badge.plus")
                    }
                    .help(Strings.openFolderTooltip)
                    .accessibilityIdentifier(
                        AccessibilityID.openFolderToolbarButton
                    )
                }
            }
        } detail: {
            detailContent
        }
        .overlay(alignment: .top) {
            ToastOverlay()
        }
        .modifier(UserTaskRunPresenter(store: projectManager.taskRunStore))
        .modifier(ProjectSearchModifier(
            projectManager: projectManager,
            isSearchPresented: $isSearchPresented
        ))
        .frame(minWidth: 800, minHeight: 500)
        .navigationTitle(workspace.projectName)
        .navigationSubtitle(branchSubtitle)
        .toolbar {
            // Agent Inbox entry point in the project window toolbar (#1337).
            // Additive to the existing ⌘⇧I chord and Window menu item.
            ToolbarItem(placement: .primaryAction) {
                AgentInboxToolbarButton(
                    attentionCount: agentInboxAttentionCount
                ) {
                    openWindow(id: "agent-inbox")
                    NSApp.activate()
                }
            }
        }
        .background {
            BranchSubtitleClickHandler(
                gitProvider: workspace.gitProvider,
                isGitRepository: workspace.gitProvider.isGitRepository,
                projectManager: projectManager
            )
            DocumentEditedTracker(isEdited: projectManager.hasUnsavedChanges)
            RepresentedFileTracker(
                url: activeTab?.fileURL ?? workspace.rootURL
            )
        }
        .task {
            let disposition = restoreSessionIfNeeded()
            if case .restored(let result) = disposition, result.didRestoreEditorTabs {
                refreshLineDiffs()
            }
            checkForRecovery()
            // #1251: a project with no saved session and no pending recovery
            // opens directly into a focused terminal rooted in the project,
            // instead of an empty editor canvas. This runs only after session
            // restoration and recovery discovery so it never clobbers real
            // restored content. `deferred` (no rootURL yet) and `skipped`
            // (content already present) do nothing.
            seedInitialTerminalIfNeeded(disposition: disposition)
            syncSidebarSelection()
            applySearchQueryFromEnvironment()
            #if DEBUG
            seedAccessibilityDirtyBufferIfNeeded()
            #endif
            refreshBlame()
            #if DEBUG
            // Seed only after the project window has installed its native
            // delegate. The #1407 fixture must reproduce the live-agent UI
            // transition that invalidates an already-mounted scene.
            await registry.seedLiveAgentUITestFixture(
                afterWindowBindingFor: projectManager
            )
            #endif
        }
        .sheet(isPresented: $showRecoveryDialog) {
            RecoveryDialogView(
                entries: recoveryEntries,
                onRecover: { recoverTabs() },
                onDiscard: { discardRecovery() }
            )
        }
        .overlay {
            // The controller pins every gesture to the key project window and
            // discards it when that window resigns. Mirror that ownership in
            // the render gate so a shared/stale scene can never show another
            // window's switcher session.
            //
            // The animation is scoped to this overlay's own subtree (via the
            // ZStack wrapper) so it animates the switcher's appear/disappear
            // transition without bleeding into sibling modifiers such as the
            // task output panel's safeAreaInset. A top-level .animation here
            // wraps the entire ContentView in an animation context, which
            // delays conditional content — e.g. the copy button inside the
            // task run LazyVStack — from becoming interactive when the panel
            // is toggled closed and reopened.
            ZStack {
                if paneManager.isGlobalTabSwitcherActive,
                   controlActiveState == .key {
                    GlobalTabSwitcherOverlay()
                        .transition(
                            reduceMotion
                                ? .identity
                                : .opacity.combined(with: .scale(scale: 0.96))
                        )
                        .zIndex(100)
                }
            }
            .animation(
                reduceMotion ? nil : PineAnimation.overlay,
                value: paneManager.isGlobalTabSwitcherActive
            )
        }
        // MARK: - Command overlays (#975)
        // Quick Open, Symbol Navigator, Go to Line, and Command Palette route
        // through a single document-scoped router so at most one overlay is
        // active per window. The shared container renders whichever flow the
        // router reports, replacing any prior presentation deterministically.
        .modifier(CommandOverlayContainer(
            router: commandOverlayRouter,
            projectManager: projectManager
        ))
        .modifier(CommandOverlayNotificationObserver(
            router: commandOverlayRouter,
            projectManager: projectManager,
            isKeyWindow: controlActiveState == .key
        ))
        .sheet(isPresented: $isBranchSwitcherPresented) {
            BranchSwitcherView(
                gitProvider: workspace.gitProvider,
                isPresented: $isBranchSwitcherPresented,
                projectManager: projectManager
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
        .modifier(AgentActivityPresenter(
            isPresented: $isAgentActivityPresented,
            projectManager: projectManager,
            store: projectManager.agentActivity,
            paneManager: paneManager,
            terminalManager: terminal,
            onSelect: { url in
                isAgentActivityPresented = false
                openFileFromActivity(url)
            }
        ))
        .modifier(AgentHistoryPresenter(
            isPresented: $isAgentHistoryPresented,
            projectManager: projectManager,
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
            #if DEBUG
            seedAccessibilityDirtyBufferIfNeeded()
            #endif
            refreshLineDiffs()
            refreshBlame()
            projectManager.saveSession()
        }
        .modifier(BlameObserver(
            isBlameVisible: isBlameVisible,
            onRefresh: { refreshBlame() }
        ))
        .onChange(of: workspace.rootNodes) { _, _ in
            let disposition = restoreSessionIfNeeded()
            if case .restored(let result) = disposition, result.didRestoreEditorTabs {
                refreshLineDiffs()
                refreshBlame()
            }
            // Seed an initial terminal for a no-session project once the file
            // tree is ready. The `rootNodes` change is the deferred-retry
            // signal: when the initial `.task` returned `.deferred` (rootURL
            // not yet set), this is where restoration finally succeeds.
            seedInitialTerminalIfNeeded(disposition: disposition)
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
        .modifier(ProblemsPanelRefreshObserver(
            diagnosticsGeneration: projectManager.lspManager.diagnosticsGeneration,
            activePaneID: paneManager.activePaneID,
            controller: projectManager.problemsController
        ))
        .modifier(GitAndNotificationObserver(
            lineDiffs: $lineDiffs,
            columnVisibility: $columnVisibility,
            isSearchPresented: $isSearchPresented,
            onPresentGoToLine: {
                commandOverlayRouter.present(.goToLine)
            },
            onRefreshLineDiffs: { refreshLineDiffs() },
            onRefreshBlame: { refreshBlame() },
            onOpenNewProject: { openNewProject() },
            onHandleFileDeletion: { handleFileDeletion($0) },
            onHandleExternalChanges: { handleExternalChanges($0) },
            onNavigateToChange: { navigateToChange(direction: $0) },
            onInlineDiffAction: { handleInlineDiffAction($0) }
        ))
        .onReceive(NotificationCenter.default.publisher(for: .toggleWordWrap)) { notification in
            guard Self.shouldHandleTargetedCommand(
                notificationObject: notification.object,
                currentProject: projectManager,
                isKeyWindow: controlActiveState == .key
            ) else { return }
            handleToggleWordWrap()
        }
        .onReceive(NotificationCenter.default.publisher(for: .revealInSidebar)) { notification in
            handleRevealInSidebar(notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: .sendTextToTerminal)) { notification in
            handleSendTextToTerminal(notification)
        }
    }

    /// Detail pane content: editor area + Problems panel + status bar. Broken
    /// out into its own computed property because the `StatusBarView(…)`
    /// initializer with its multi-line terminal-toggle closure pushes the
    /// `body` modifier chain past the SwiftUI type-checker's budget (#1112).
    @ViewBuilder
    private var detailContent: some View {
        VStack(spacing: 0) {
            editorArea
                .frame(maxHeight: .infinity)
            // Collapsible Problems panel (#1236): a bottom pane between the
            // editor area and the status bar, driven by the project-scoped
            // `ProblemsPanelController`. Previously dead code — never rendered.
            if projectManager.problemsController.isPanelVisible {
                ProblemsPanelChrome(
                    controller: projectManager.problemsController,
                    onSelect: { diagnostic in
                        navigateToDiagnostic(diagnostic)
                    },
                    onClose: {
                        projectManager.problemsController.isPanelVisible = false
                    }
                )
                .frame(height: LayoutMetrics.problemsPanelHeight)
            }
            StatusBarView(
                gitProvider: workspace.gitProvider,
                paneManager: paneManager,
                tabManager: activeTabManager,
                terminalManager: terminal,
                progress: projectManager.progress,
                onToggleTerminal: {
                    if paneManager.terminalPaneIDs.isEmpty {
                        terminal.focusOrCreateTerminal(
                            relativeTo: paneManager.activePaneID,
                            workingDirectory: workspace.rootURL
                        )
                    } else {
                        // Warn before stopping tabs with foreground processes.
                        // Presented as a window-scoped sheet (issue #1241).
                        let targetPaneIDs = Set(paneManager.terminalPaneIDs)
                        let targetTabs = terminal.allTerminalTabs
                        let targetTabIDs = Set(targetTabs.map(\.id))
                        Task { @MainActor in
                            // Resolve the owner resiliently: a transiently-nil
                            // weak project→window anchor during scene
                            // restoration must not silently abort the close
                            // (#1335 H3).
                            let context = await TabCloseHelper.terminalCloseContext(
                                for: projectManager
                            )
                            guard await TabCloseHelper.confirmTerminalProcessStop(
                                tabs: targetTabs,
                                context: context
                            ) else { return }
                            // `confirmTerminalProcessStop` already revalidates
                            // process coverage through the stable-identity
                            // authorization. Re-checking a volatile pgid here
                            // silently discarded the user's confirmation
                            // whenever an agent spawned a child (#1348); only
                            // the pane/tab composition still needs a guard.
                            let currentPaneIDs = Set(paneManager.terminalPaneIDs)
                            let currentTabIDs = Set(
                                terminal.allTerminalTabs.map(\.id)
                            )
                            guard currentPaneIDs.isSubset(of: targetPaneIDs),
                                  currentTabIDs.isSubset(of: targetTabIDs) else {
                                return
                            }
                            // Hide all terminal panes
                            for paneID in targetPaneIDs {
                                if let state = paneManager.terminalState(for: paneID) {
                                    for tab in state.terminalTabs { tab.stop() }
                                }
                                paneManager.removePane(paneID)
                            }
                        }
                    }
                },
                diagnosticsSummary: projectManager.problemsController.summary,
                onToggleProblems: {
                    projectManager.problemsController.togglePanel()
                },
                onShowAttention: {
                    commandOverlayRouter.present(.agentAttention)
                }
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .showProblems)) { notification in
            guard Self.shouldHandleTargetedCommand(
                notificationObject: notification.object,
                currentProject: projectManager,
                isKeyWindow: controlActiveState == .key
            ) else { return }
            // Defer to break reentrancy (#1051): mutating @Observable state
            // synchronously from a menu→notification callstack collides with
            // the button-action's exclusive access to SwiftUI storage.
            DispatchQueue.main.async {
                projectManager.problemsController.togglePanel()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .nextDiagnostic)) { notification in
            guard Self.shouldHandleTargetedCommand(
                notificationObject: notification.object,
                currentProject: projectManager,
                isKeyWindow: controlActiveState == .key
            ) else { return }
            DispatchQueue.main.async {
                if let diagnostic = projectManager.problemsController.nextDiagnostic() {
                    self.navigateToDiagnostic(diagnostic)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .previousDiagnostic)) { notification in
            guard Self.shouldHandleTargetedCommand(
                notificationObject: notification.object,
                currentProject: projectManager,
                isKeyWindow: controlActiveState == .key
            ) else { return }
            DispatchQueue.main.async {
                if let diagnostic = projectManager.problemsController.previousDiagnostic() {
                    self.navigateToDiagnostic(diagnostic)
                }
            }
        }
    }

    /// Branch subtitle as a plain String to avoid generating a localization key.
    var branchSubtitle: String {
        Self.branchSubtitle(
            isGitRepo: workspace.gitProvider.isGitRepository,
            branchName: workspace.gitProvider.currentBranch
        )
    }

    /// Number of the focused project's durable agent tasks currently in the
    /// Agent Inbox "needs attention" section. Drives the toolbar badge
    /// (#1337). Returns 0 before the project URL is bound.
    private var agentInboxAttentionCount: Int {
        guard let rootURL = workspace.rootURL else { return 0 }
        return registry.agentInboxAttentionCount(for: rootURL)
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

    static func shouldHandleTargetedCommand(
        notificationObject: Any?,
        currentProject: ProjectManager,
        isKeyWindow: Bool
    ) -> Bool {
        guard let notificationObject else { return isKeyWindow }
        guard let targetProject = notificationObject as? ProjectManager else {
            return false
        }
        return targetProject === currentProject
    }

    // MARK: - Subview builders

    @ViewBuilder
    var editorArea: some View {
        PaneTreeView(node: paneManager.root)
    }

}

/// Keeps the Problems panel synchronized without adding more generic closure
/// layers to `ContentView.body`, which is already close to SwiftUI's
/// type-checking complexity limit.
private struct ProblemsPanelRefreshObserver: ViewModifier {
    let diagnosticsGeneration: Int
    let activePaneID: PaneID
    let controller: ProblemsPanelController

    func body(content: Content) -> some View {
        content
            .onChange(of: diagnosticsGeneration) { _, _ in
                // Refresh the Problems panel when LSP diagnostics change so
                // stale cached state (selection, summary) is invalidated.
                controller.refreshFromLSPDiagnostics()
            }
            .onChange(of: activePaneID) { _, _ in
                controller.refreshDocumentOwnership()
            }
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
