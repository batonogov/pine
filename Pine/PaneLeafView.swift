//
//  PaneLeafView.swift
//  Pine
//
//  A single leaf pane showing the editor area with its own tab bar.
//

import SwiftUI

/// A single leaf pane showing the editor area with its own tab bar.
struct PaneLeafView: View {
    let paneID: PaneID
    @Environment(PaneManager.self) private var paneManager
    @Environment(WorkspaceManager.self) private var workspace
    @Environment(ProjectManager.self) private var projectManager
    @Environment(TerminalManager.self) private var terminal
    @Environment(ProjectRegistry.self) private var registry
    @Environment(\.openWindow) private var openWindow

    @State private var lineDiffs: [GitLineDiff] = []
    @State private var diffHunks: [DiffHunk] = []
    @State private var blameLines: [GitBlameLine] = []
    @State private var blameTask: Task<Void, Never>?
    @State private var isDragTargeted = false
    @State private var goToLineOffset: GoToRequest?
    @State private var dropZone: PaneDropZone?
    @State private var paneSize: CGSize = .zero

    @AppStorage("minimapVisible") private var isMinimapVisible = true
    @AppStorage(BlameConstants.storageKey) private var isBlameVisible = true
    @AppStorage("wordWrapEnabled") private var isWordWrapEnabled = true

    private var tabManager: TabManager? { paneManager.tabManager(for: paneID) }
    private var isActive: Bool { paneManager.activePaneID == paneID }

    var body: some View {
        if let tabManager {
            paneContent(tabManager: tabManager)
                .environment(tabManager)
                .background {
                    PaneFocusDetector(paneID: paneID, paneManager: paneManager)
                }
                .overlay {
                    GeometryReader { geometry in
                        Color.clear
                            .preference(key: PaneSizePreferenceKey.self, value: geometry.size)
                    }
                }
                .onPreferenceChange(PaneSizePreferenceKey.self) { paneSize = $0 }
                .overlay {
                    PaneDropOverlay(dropZone: dropZone)
                }
                .onDrop(of: [.paneTabDrag], delegate: PaneSplitDropDelegate(
                    paneID: paneID,
                    paneManager: paneManager,
                    paneSize: paneSize,
                    dropZone: $dropZone
                ))
                .border(
                    isActive && paneManager.root.leafCount > 1
                        ? Color.accentColor.opacity(0.5)
                        : Color.clear,
                    width: 1
                )
                .onChange(of: tabManager.activeTabID) { _, _ in
                    refreshLineDiffs(tabManager: tabManager)
                    refreshBlame(tabManager: tabManager)
                }
                .modifier(BlameObserver(
                    isBlameVisible: isBlameVisible,
                    onRefresh: { refreshBlame(tabManager: tabManager) }
                ))
                .accessibilityIdentifier(AccessibilityID.paneLeaf(paneID.id.uuidString))
        }
    }

    @ViewBuilder
    private func paneContent(tabManager: TabManager) -> some View {
        VStack(spacing: 0) {
            if !tabManager.tabs.isEmpty {
                EditorTabBar(
                    tabManager: tabManager,
                    onCloseTab: { tab in
                        closeTabWithConfirmation(tab, tabManager: tabManager)
                    },
                    onCloseOtherTabs: { tabID in
                        closeOtherTabsWithConfirmation(keeping: tabID, tabManager: tabManager)
                    },
                    onCloseTabsToTheRight: { tabID in
                        closeTabsToTheRightWithConfirmation(of: tabID, tabManager: tabManager)
                    },
                    onCloseAllTabs: {
                        closeAllTabsWithConfirmation(tabManager: tabManager)
                    },
                    overridePaneID: paneID
                )
            }

            if let tab = tabManager.activeTab, let rootURL = workspace.rootURL {
                BreadcrumbPathBar(
                    fileURL: tab.url,
                    projectRoot: rootURL,
                    onOpenFile: { url in tabManager.openTab(url: url) }
                )
            }

            if let tab = tabManager.activeTab {
                codeEditorView(for: tab, tabManager: tabManager)
            } else {
                ContentUnavailableView {
                    Label(Strings.noFileSelected, systemImage: "doc.text")
                } description: {
                    Text(Strings.selectFilePrompt)
                }
                .accessibilityIdentifier(AccessibilityID.editorPlaceholder)
            }

            StatusBarView(
                gitProvider: workspace.gitProvider,
                terminal: terminal,
                tabManager: tabManager,
                progress: projectManager.progress
            )
        }
    }

    @ViewBuilder
    private func codeEditorView(for tab: EditorTab, tabManager: TabManager) -> some View {
        CodeEditorView(
            text: Binding(
                get: { tab.content },
                set: { tabManager.updateContent($0) }
            ),
            contentVersion: tab.contentVersion,
            language: tab.language,
            fileName: tab.fileName,
            lineDiffs: lineDiffs,
            diffHunks: diffHunks,
            isBlameVisible: isBlameVisible,
            blameLines: blameLines,
            foldState: Binding(
                get: { tab.foldState },
                set: { tabManager.updateFoldState($0) }
            ),
            isMinimapVisible: isMinimapVisible,
            isWordWrapEnabled: isWordWrapEnabled,
            syntaxHighlightingDisabled: tab.syntaxHighlightingDisabled,
            initialCursorPosition: goToLineOffset?.offset ?? tab.cursorPosition,
            initialScrollOffset: goToLineOffset != nil ? 0 : tab.scrollOffset,
            onStateChange: { cursor, scroll in
                tabManager.updateEditorState(cursorPosition: cursor, scrollOffset: scroll)
            },
            onHighlightCacheUpdate: { result in
                tabManager.updateHighlightCache(result)
            },
            cachedHighlightResult: tab.cachedHighlightResult,
            goToOffset: goToLineOffset,
            indentStyle: tab.cachedIndentation,
            fontSize: FontSizeSettings.shared.fontSize
        )
        .id(tab.id)
        .accessibilityIdentifier(AccessibilityID.codeEditor)
        .onAppear { goToLineOffset = nil }
    }

    // MARK: - Git diff & blame

    /// Refreshes cached line diffs and diff hunks for the active tab.
    private func refreshLineDiffs(tabManager: TabManager) {
        guard let tab = tabManager.activeTab else {
            lineDiffs = []
            diffHunks = []
            return
        }
        let fileURL = tab.url
        let provider = workspace.gitProvider
        guard provider.isGitRepository, let repoURL = workspace.rootURL else {
            lineDiffs = []
            diffHunks = []
            return
        }
        Task {
            async let diffs = provider.diffForFileAsync(at: fileURL)
            async let hunks = InlineDiffProvider.fetchHunks(for: fileURL, repoURL: repoURL)
            let (resolvedDiffs, resolvedHunks) = await (diffs, hunks)
            if tabManager.activeTab?.url == fileURL {
                lineDiffs = resolvedDiffs
                diffHunks = resolvedHunks
            }
        }
    }

    /// Refreshes cached blame data for the active tab.
    private func refreshBlame(tabManager: TabManager) {
        blameTask?.cancel()
        guard isBlameVisible else {
            blameLines = []
            return
        }
        guard let tab = tabManager.activeTab else {
            blameLines = []
            return
        }
        let fileURL = tab.url
        let provider = workspace.gitProvider
        guard provider.isGitRepository, let repoURL = provider.repositoryURL else {
            blameLines = []
            return
        }
        let filePath = fileURL.path
        blameTask = Task.detached {
            let result = GitStatusProvider.runGit(
                ["blame", "--porcelain", "--", filePath], at: repoURL
            )
            guard !Task.isCancelled else { return }
            let lines: [GitBlameLine]
            if result.exitCode == 0, !result.output.isEmpty {
                lines = GitStatusProvider.parseBlame(result.output)
            } else {
                lines = []
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                if tabManager.activeTab?.url == fileURL {
                    blameLines = lines
                }
            }
        }
    }

    // MARK: - Gutter accept/revert

    private func handleGutterAccept(_ hunk: DiffHunk, tabManager: TabManager) {
        guard let tab = tabManager.activeTab,
              let repoURL = workspace.rootURL else { return }
        Task {
            await InlineDiffProvider.acceptHunk(hunk, fileURL: tab.url, repoURL: repoURL)
            await workspace.gitProvider.refreshAsync()
            refreshLineDiffs(tabManager: tabManager)
        }
    }

    private func handleGutterRevert(_ hunk: DiffHunk, tabManager: TabManager) {
        guard let tab = tabManager.activeTab,
              let repoURL = workspace.rootURL else { return }
        Task {
            if let newContent = await InlineDiffProvider.revertHunk(
                hunk, fileURL: tab.url, repoURL: repoURL
            ) {
                tabManager.updateContent(newContent)
                tabManager.reloadTab(url: tab.url)
                await workspace.gitProvider.refreshAsync()
                refreshLineDiffs(tabManager: tabManager)
            }
        }
    }

    // MARK: - Tab close with dirty confirmation

    private func closeTabWithConfirmation(_ tab: EditorTab, tabManager: TabManager) {
        TabCloseHelper.closeTab(tab, in: tabManager, gitProvider: workspace.gitProvider)
        if tabManager.tabs.isEmpty {
            paneManager.removePane(paneID)
        }
    }

    private func closeOtherTabsWithConfirmation(keeping tabID: UUID, tabManager: TabManager) {
        TabCloseHelper.closeOtherTabs(keeping: tabID, in: tabManager, gitProvider: workspace.gitProvider)
    }

    private func closeTabsToTheRightWithConfirmation(of tabID: UUID, tabManager: TabManager) {
        TabCloseHelper.closeTabsToTheRight(of: tabID, in: tabManager, gitProvider: workspace.gitProvider)
    }

    private func closeAllTabsWithConfirmation(tabManager: TabManager) {
        TabCloseHelper.closeAllTabs(in: tabManager, gitProvider: workspace.gitProvider)
        paneManager.removePane(paneID)
    }
}
