//
//  PaneLeafView.swift
//  Pine
//
//  A single leaf pane showing the editor area with its own tab bar.
//

import SwiftUI
import UniformTypeIdentifiers

/// A single leaf pane showing the editor area with its own tab bar.
struct PaneLeafView: View {
    let paneID: PaneID
    let content: PaneContent
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
    /// Handle for the most recently scheduled diff refresh so new triggers
    /// can cancel a stale run (e.g. rapid typing or overlapping observers).
    @State private var diffTask: Task<Void, Never>?
    @State private var configValidator = ConfigValidator()
    @State private var isDragTargeted = false
    @State private var goToLineOffset: GoToRequest?
    @State private var paneSize: CGSize = .zero

    @AppStorage("minimapVisible") private var isMinimapVisible = true
    @AppStorage(BlameConstants.storageKey) private var isBlameVisible = true
    @AppStorage("wordWrapEnabled") private var isWordWrapEnabled = true

    private var tabManager: TabManager? { paneManager.tabManager(for: paneID) }
    private var terminalState: TerminalPaneState? { paneManager.terminalState(for: paneID) }
    private var isActive: Bool { paneManager.activePaneID == paneID }

    var body: some View {
        Group {
            switch content {
            case .editor:
                editorLeafBody
            case .terminal:
                terminalLeafBody
            }
        }
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
            PaneDropOverlay(dropZone: paneManager.dropZones[paneID])
        }
        .onDrop(of: [.paneTabDrag, .sidebarFileDrag, .fileURL], delegate: PaneSplitDropDelegate(
            paneID: paneID,
            paneManager: paneManager,
            paneSize: paneSize
        ))
        .border(
            isActive && paneManager.root.leafCount > 1
                ? Color.accentColor.opacity(0.5)
                : Color.clear,
            width: 1
        )
        .accessibilityIdentifier(AccessibilityID.paneLeaf(paneID.id.uuidString))
    }

    // MARK: - Terminal leaf

    @ViewBuilder
    private var terminalLeafBody: some View {
        if let terminalState {
            TerminalPaneContent(paneID: paneID, terminalState: terminalState)
        }
    }

    // MARK: - Editor leaf

    @ViewBuilder
    private var editorLeafBody: some View {
        if let tabManager {
            editorPaneContent(tabManager: tabManager)
                .environment(tabManager)
                .onAppear {
                    // Initial load: refresh line diffs/blame for the active tab
                    // even if `activeTabID` never changes (issue #780).
                    refreshLineDiffs(tabManager: tabManager)
                    refreshBlame(tabManager: tabManager)
                }
                .onChange(of: tabManager.activeTabID) { _, _ in
                    refreshLineDiffs(tabManager: tabManager)
                    refreshBlame(tabManager: tabManager)
                }
                .onChange(of: tabManager.activeTab?.contentVersion) { _, _ in
                    // Re-compute diff markers as the user edits. Debounced so
                    // `git diff` does not run on every keystroke (issue #780).
                    refreshLineDiffs(tabManager: tabManager, debounce: true)
                }
                .onChange(of: workspace.gitProvider.fileStatuses) { _, _ in
                    // External git state changes (save, stash, checkout from CLI)
                    // must refresh the gutter (issue #780).
                    refreshLineDiffs(tabManager: tabManager)
                }
                .onChange(of: workspace.gitProvider.currentBranch) { _, _ in
                    // Branch switch: `fileStatuses` will also change around the
                    // same time, but `diffTask` cancellation coalesces the two
                    // observers into a single refresh.
                    refreshLineDiffs(tabManager: tabManager)
                    refreshBlame(tabManager: tabManager)
                }
                .onChange(of: workspace.gitProvider.isGitRepository) { _, isRepo in
                    if isRepo {
                        refreshLineDiffs(tabManager: tabManager)
                    } else {
                        // Repo removed — clear every cached git-derived state,
                        // including blame (previous fix only cleared diffs).
                        diffTask?.cancel()
                        diffTask = nil
                        blameTask?.cancel()
                        blameTask = nil
                        lineDiffs = []
                        diffHunks = []
                        blameLines = []
                    }
                }
                .onDisappear {
                    diffTask?.cancel()
                    diffTask = nil
                }
                .modifier(BlameObserver(
                    isBlameVisible: isBlameVisible,
                    onRefresh: { refreshBlame(tabManager: tabManager) }
                ))
        }
    }

    @ViewBuilder
    private func editorPaneContent(tabManager: TabManager) -> some View {
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
                Group {
                    if tab.kind == .preview {
                        QuickLookPreviewView(url: tab.url)
                            .accessibilityIdentifier(AccessibilityID.quickLookPreview)
                    } else if tab.isMarkdownFile {
                        switch tab.previewMode {
                        case .source:
                            codeEditorView(for: tab, tabManager: tabManager)
                        case .preview:
                            MarkdownPreviewView(content: tab.content)
                                .accessibilityIdentifier(AccessibilityID.markdownPreviewView)
                        case .split:
                            HSplitView {
                                codeEditorView(for: tab, tabManager: tabManager)
                                    .frame(minWidth: 200)
                                MarkdownPreviewView(content: tab.content)
                                    .accessibilityIdentifier(AccessibilityID.markdownPreviewView)
                                    .frame(minWidth: 200)
                            }
                        }
                    } else {
                        codeEditorView(for: tab, tabManager: tabManager)
                    }
                }
                .contentTransition(.identity)
            } else {
                ContentUnavailableView {
                    Label(Strings.noFileSelected, systemImage: "doc.text")
                } description: {
                    Text(Strings.selectFilePrompt)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier(AccessibilityID.editorPlaceholder)
            }

            // StatusBar is rendered once in ContentView, not per-pane
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
            fileURL: tab.url,
            lineDiffs: lineDiffs,
            diffHunks: diffHunks,
            validationDiagnostics: configValidator.diagnostics,
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
        .onAppear {
            goToLineOffset = nil
            configValidator.validate(url: tab.url, content: tab.content)
        }
        .onDisappear {
            configValidator.clear()
        }
        .onChange(of: tab.content) { _, newValue in
            configValidator.validate(url: tab.url, content: newValue)
        }
    }

    // MARK: - Git diff & blame

    /// Debounce applied to content-edit triggered refreshes (keystrokes).
    /// Matches the ~150ms used by other git-derived work in Pine.
    private static let diffDebounce: Duration = .milliseconds(150)

    /// Refreshes cached line diffs and diff hunks for the active tab.
    /// - Parameter debounce: when `true`, waits `diffDebounce` before running
    ///   the diff so rapid typing coalesces into a single git invocation.
    ///   Immediate (`false`) refreshes are used by tab switches, save,
    ///   branch switch, and repo init — those already fire at human pace.
    ///
    /// The most recent invocation cancels any previously scheduled work
    /// via `diffTask`, so overlapping observers (e.g. `fileStatuses` +
    /// `currentBranch` firing in the same runloop tick) run only once.
    private func refreshLineDiffs(tabManager: TabManager, debounce: Bool = false) {
        diffTask?.cancel()
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
        diffTask = Task { @MainActor in
            if debounce {
                try? await Task.sleep(for: Self.diffDebounce)
                if Task.isCancelled { return }
            }
            async let diffs = provider.diffForFileAsync(at: fileURL)
            async let hunks = InlineDiffProvider.fetchHunks(for: fileURL, repoURL: repoURL)
            let (resolvedDiffs, resolvedHunks) = await (diffs, hunks)
            if Task.isCancelled { return }
            guard tabManager.activeTab?.url == fileURL else { return }
            lineDiffs = resolvedDiffs
            diffHunks = resolvedHunks
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
