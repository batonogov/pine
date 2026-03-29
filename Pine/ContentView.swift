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
    @Environment(TabManager.self) var tabManager
    @Environment(PaneManager.self) var paneManager
    @Environment(ProjectRegistry.self) var registry
    @Environment(\.openWindow) var openWindow

    @Environment(\.controlActiveState) var controlActiveState

    // MARK: - State (internal for cross-file extension access in ContentView+Helpers)

    @State var selectedNode: FileNode?
    @State var columnVisibility: NavigationSplitViewVisibility = .all
    @State var lineDiffs: [GitLineDiff] = []
    @State var blameLines: [GitBlameLine] = []
    @State var blameTask: Task<Void, Never>?
    @State var didRestoreSession = false
    @State var isSearchPresented = false
    @State var goToLineOffset: GoToRequest?
    @State var recoveryEntries: [(UUID, RecoveryEntry)] = []
    @State var showRecoveryDialog = false
    @State var isDragTargeted = false
    @State var isQuickOpenPresented = false
    @State var isSymbolNavigatorPresented = false
    @State var showGoToLine = false
    @AppStorage("minimapVisible") var isMinimapVisible = true
    @AppStorage(BlameConstants.storageKey) var isBlameVisible = true
    @AppStorage("wordWrapEnabled") var isWordWrapEnabled = true

    var activeTab: EditorTab? { tabManager.activeTab }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarSearchableContent(
                selectedNode: $selectedNode
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
            VStack(spacing: 0) {
                if terminal.isTerminalVisible {
                    if terminal.isTerminalMaximized {
                        terminalArea
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        VSplitView {
                            editorArea
                                .frame(maxWidth: .infinity, minHeight: 200, maxHeight: .infinity)
                            terminalArea
                                .frame(maxWidth: .infinity, minHeight: 100, idealHeight: 150, maxHeight: .infinity)
                        }
                        .frame(maxHeight: .infinity)
                    }
                } else {
                    editorArea
                        .frame(maxHeight: .infinity)
                }
                StatusBarView(
                    gitProvider: workspace.gitProvider,
                    terminal: terminal,
                    tabManager: tabManager,
                    progress: projectManager.progress
                )
            }
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
            DocumentEditedTracker(isEdited: tabManager.hasUnsavedChanges)
            RepresentedFileTracker(url: activeTab?.url ?? workspace.rootURL)
        }
        .task {
            restoreSessionIfNeeded()
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
        .sheet(isPresented: $isQuickOpenPresented) {
            QuickOpenView(isPresented: $isQuickOpenPresented)
                .environment(projectManager)
        }
        .onReceive(NotificationCenter.default.publisher(for: .showQuickOpen)) { _ in
            isQuickOpenPresented = true
        }
        .sheet(isPresented: $isSymbolNavigatorPresented) {
            SymbolNavigatorView(isPresented: $isSymbolNavigatorPresented)
                .environment(projectManager)
        }
        .onReceive(NotificationCenter.default.publisher(for: .showSymbolNavigator)) { _ in
            guard tabManager.activeTab != nil else { return }
            isSymbolNavigatorPresented = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .symbolNavigate)) { notification in
            guard let offset = notification.userInfo?["offset"] as? Int else { return }
            goToLineOffset = GoToRequest(offset: offset)
        }
        .sheet(isPresented: $showGoToLine) {
            GoToLineView(
                totalLines: totalLineCount,
                isPresented: $showGoToLine,
                onGoTo: { line, column in
                    guard let tab = tabManager.activeTab else { return }
                    goToLineOffset = GoToRequest(
                        offset: Self.cursorOffset(forLine: line, column: column, in: tab.content)
                    )
                }
            )
        }
        .onChange(of: selectedNode) { _, newNode in
            guard let node = newNode, !node.isDirectory else { return }
            handleFileSelection(node)
        }
        .onChange(of: workspace.rootURL) { _, _ in
            lineDiffs = []
            projectManager.quickOpenProvider.invalidateIndex()
            projectManager.saveSession()
            applySearchQueryFromEnvironment()
        }
        .onChange(of: tabManager.activeTabID) { _, _ in
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
            restoreSessionIfNeeded()
            syncSidebarSelection()
        }
        .onChange(of: tabManager.tabs.count) { _, _ in
            projectManager.saveSession()
        }
        .modifier(TerminalSessionObserver(
            terminal: terminal,
            onSave: { projectManager.saveSession() }
        ))
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
            onHandleExternalConflicts: { handleExternalConflicts($0) },
            onNavigateToChange: { navigateToChange(direction: $0) }
        ))
        .onReceive(NotificationCenter.default.publisher(for: .toggleWordWrap)) { _ in
            isWordWrapEnabled.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: .sendTextToTerminal)) { notification in
            guard controlActiveState == .key,
                  let text = notification.userInfo?["text"] as? String,
                  !text.isEmpty else { return }
            sendTextToTerminal(text)
        }
        .onChange(of: tabManager.pendingGoToLine) { _, newLine in
            guard let line = newLine, let tab = tabManager.activeTab else { return }
            tabManager.pendingGoToLine = nil
            goToLineOffset = GoToRequest(offset: Self.cursorOffset(forLine: line, in: tab.content))
        }
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

    // MARK: - Subview builders

    @ViewBuilder
    var editorArea: some View {
        if paneManager.root.leafCount > 1 {
            PaneTreeView(node: paneManager.root)
        } else {
            EditorAreaView(
                lineDiffs: $lineDiffs,
                isDragTargeted: $isDragTargeted,
                goToLineOffset: $goToLineOffset,
                isBlameVisible: isBlameVisible,
                blameLines: blameLines,
                isMinimapVisible: isMinimapVisible,
                isWordWrapEnabled: isWordWrapEnabled,
                onCloseTab: { closeTabWithConfirmation($0) },
                onSaveSession: { projectManager.saveSession() }
            )
        }
    }

    @ViewBuilder
    var terminalArea: some View {
        VStack(spacing: 0) {
            TerminalNativeTabBar(terminal: terminal, workingDirectory: workspace.rootURL)
            TerminalSearchBarContainer(terminal: terminal)
            TerminalContentView(terminal: terminal)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear { terminal.startTerminals(workingDirectory: workspace.rootURL) }
        .modifier(TerminalSearchObserver(terminal: terminal))
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
        .environment(projectManager.tabManager)
        .environment(projectManager.paneManager)
        .environment(registry)
}
