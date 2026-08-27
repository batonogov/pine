//
//  PaneLeafView.swift
//  Pine
//
//  A single leaf pane showing the editor area with its own tab bar.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Presentation routing also determines which AppKit content view owns a
/// pending destination-focus request after a tab drag commits.
enum EditorContentPresentation: Equatable {
    case codeEditor
    case quickLook
    case markdownPreview
    case markdownSplit

    static func resolve(for tab: EditorTab) -> EditorContentPresentation {
        switch tab.kind {
        case .preview:
            return .quickLook
        case .text where tab.isMarkdownFile:
            switch tab.previewMode {
            case .source:
                return .codeEditor
            case .preview:
                return .markdownPreview
            case .split:
                return .markdownSplit
            }
        case .text:
            return .codeEditor
        }
    }
}

/// Keeps pane-body routing consistent with whether a real tab strip exists.
/// An optional count distinguishes missing backing state from a valid empty
/// strip: zero tabs still expose the single N=0 insertion gap.
nonisolated enum PaneLeafTabStripComposition {
    static func rendersStrip(
        content: PaneContent,
        editorTabCount: Int?,
        terminalTabCount: Int?
    ) -> Bool {
        switch content {
        case .editor:
            editorTabCount != nil
        case .terminal:
            terminalTabCount != nil
        }
    }

    static func excludedTopInset(
        content: PaneContent,
        editorTabCount: Int?,
        terminalTabCount: Int?,
        tabBarHeight: CGFloat
    ) -> CGFloat {
        rendersStrip(
            content: content,
            editorTabCount: editorTabCount,
            terminalTabCount: terminalTabCount
        ) ? tabBarHeight : 0
    }
}

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
    /// Monotonic counter bumped after every diff refresh to force SwiftUI
    /// to call `CodeEditorView.updateNSView` even when `@State lineDiffs`
    /// changes inside a `Task` are optimized away (issue #809).
    @State private var diffVersion: UInt64 = 0
    @State private var blameLines: [GitBlameLine] = []
    @State private var blameTask: Task<Void, Never>?
    /// Handle for the most recently scheduled diff refresh so new triggers
    /// can cancel a stale run (e.g. rapid typing or overlapping observers).
    @State private var diffTask: Task<Void, Never>?
    @State private var configValidator = ConfigValidator()
    @State private var isDragTargeted = false
    @State private var goToLineOffset: GoToRequest?
    @State private var paneSize: CGSize = .zero
    /// Definition quick-pick controller — shared with the editor coordinator
    /// via the `CodeEditorView` environment for multiple-definition navigation.
    @State private var definitionQuickPickController = DefinitionQuickPickController()

    @AppStorage("minimapVisible") private var isMinimapVisible = true
    @AppStorage(BlameConstants.storageKey) private var isBlameVisible = true
    @AppStorage("wordWrapEnabled") private var isWordWrapEnabled = true

    private var tabManager: TabManager? { paneManager.tabManager(for: paneID) }
    private var terminalState: TerminalPaneState? { paneManager.terminalState(for: paneID) }
    private var isActive: Bool { paneManager.activePaneID == paneID }
    private var tabStripExcludedTopInset: CGFloat {
        PaneLeafTabStripComposition.excludedTopInset(
            content: content,
            editorTabCount: tabManager?.tabs.count,
            terminalTabCount: terminalState?.terminalTabs.count,
            tabBarHeight: LayoutMetrics.tabBarHeight
        )
    }

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
            paneSize: paneSize,
            excludedTopInset: tabStripExcludedTopInset
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
                .onChange(of: tabManager.pendingGoToLocation) { _, location in
                    // Per-pane go-to handler (issue #971). ContentView and
                    // SearchResultsView route line-based navigation requests
                    // through the focused pane's `TabManager`; this observer
                    // preserves an optional diagnostic column instead of
                    // silently reducing every target to the start of its line.
                    guard let location,
                          let tab = tabManager.activeTab else { return }
                    tabManager.pendingGoToLocation = nil
                    goToLineOffset = GoToRequest(
                        offset: ContentView.cursorOffset(
                            forLine: location.line,
                            column: location.column,
                            in: tab.content
                        )
                    )
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
                .onChange(of: tabManager.activeTab?.isDirty) { _, isDirty in
                    // When a tab transitions dirty → clean (save completed),
                    // the on-disk content now matches HEAD and diff markers
                    // must be refreshed. Without this, markers become stale
                    // after undo-all + save because no other observer fires:
                    // contentVersion didn't change (undo restores original),
                    // and fileStatuses may not differ if the provider drops
                    // clean entries from the dict. Issue #809.
                    if isDirty == false {
                        refreshLineDiffs(tabManager: tabManager)
                    }
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
            // Keep the strip visible at N=0: its full-width surface is the
            // one valid insertion gap for a tab dragged from another pane.
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
                isMarkdownFile: tabManager.activeTab?.isMarkdownFile ?? false,
                previewMode: tabManager.activeTab?.previewMode ?? .source,
                onTogglePreview: {
                    tabManager.togglePreviewMode()
                },
                overridePaneID: paneID
            )

            if let tab = tabManager.activeTab,
               let fileURL = tab.fileURL,
               let rootURL = workspace.rootURL {
                BreadcrumbPathBar(
                    fileURL: fileURL,
                    projectRoot: rootURL,
                    onOpenFile: { url in tabManager.openTab(url: url) }
                )
            }

            if let tab = tabManager.activeTab {
                Group {
                    let focusRequestID = tabManager.pendingFocusTabID == tab.id
                        ? tabManager.pendingFocusRequestID
                        : nil
                    switch EditorContentPresentation.resolve(for: tab) {
                    case .quickLook:
                        QuickLookPreviewView(
                            url: tab.url,
                            focusRequestID: focusRequestID,
                            canAttemptFocusRequest: { requestID in
                                paneManager.activePaneID == paneID
                                    && tabManager.activeTabID == tab.id
                                    && tabManager.pendingFocusTabID == tab.id
                                    && tabManager.pendingFocusRequestID == requestID
                            },
                            onFocusRequestResult: { requestID, succeeded in
                                tabManager.acknowledgeFocusRequest(
                                    requestID: requestID,
                                    for: tab.id,
                                    succeeded: succeeded
                                )
                            }
                        )
                            .accessibilityIdentifier(AccessibilityID.quickLookPreview)
                    case .markdownPreview:
                        MarkdownPreviewView(
                            content: tab.content,
                            focusRequestID: focusRequestID,
                            canAttemptFocusRequest: { requestID in
                                paneManager.activePaneID == paneID
                                    && tabManager.activeTabID == tab.id
                                    && tabManager.pendingFocusTabID == tab.id
                                    && tabManager.pendingFocusRequestID == requestID
                            },
                            onFocusRequestResult: { requestID, succeeded in
                                tabManager.acknowledgeFocusRequest(
                                    requestID: requestID,
                                    for: tab.id,
                                    succeeded: succeeded
                                )
                            }
                        )
                        .accessibilityIdentifier(AccessibilityID.markdownPreviewView)
                    case .markdownSplit:
                        HSplitView {
                            codeEditorView(for: tab, tabManager: tabManager)
                                .frame(minWidth: 200)
                            MarkdownPreviewView(content: tab.content)
                                .accessibilityIdentifier(AccessibilityID.markdownPreviewView)
                                .frame(minWidth: 200)
                        }
                    case .codeEditor:
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
        .overlay {
            // Definition quick-pick (multiple go-to-definition results)
            if definitionQuickPickController.isVisible {
                DefinitionQuickPickOverlay(controller: definitionQuickPickController)
            }
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
            fileURL: tab.fileURL,
            documentIdentityURL: tab.url,
            commandTarget: projectManager,
            canHandleCommands: {
                paneManager.activePaneID == paneID
                    && tabManager.activeTabID == tab.id
            },
            canHandleFindStepping: {
                // Window-wide ⌘G / ⇧⌘G routing (#1551): the editor's find
                // bar takes the step only when no visible terminal search bar
                // claims it. Unaffected by which editor pane/tab is active —
                // `canHandleCommands` above already narrows to one editor.
                FindStepTargetPolicy.target(
                    activePaneID: paneManager.activePaneID,
                    visibleTerminalSearchPaneIDs:
                        paneManager.visibleTerminalSearchPaneIDs
                ) == .editor
            },
            lineDiffs: lineDiffs,
            diffVersion: diffVersion,
            diffHunks: diffHunks,
            validationDiagnostics: mergedDiagnostics(for: tab),
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
            definitionQuickPickController: definitionQuickPickController,
            lspFoldRangeRequester: { url, text in
                await projectManager.lspManager.foldingRanges(
                    url: url,
                    text: text
                )
            },
            lspFoldRefreshGeneration:
                projectManager.lspManager.foldingRefreshGeneration,
            onStateChange: { cursor, scroll in
                tabManager.updateEditorState(cursorPosition: cursor, scrollOffset: scroll)
            },
            onHighlightCacheUpdate: { result in
                tabManager.updateHighlightCache(result)
            },
            cachedHighlightResult: tab.cachedHighlightResult,
            goToOffset: goToLineOffset,
            focusRequestID: tabManager.pendingFocusTabID == tab.id
                ? tabManager.pendingFocusRequestID
                : nil,
            canAttemptFocusRequest: { requestID in
                paneManager.activePaneID == paneID
                    && tabManager.activeTabID == tab.id
                    && tabManager.pendingFocusTabID == tab.id
                    && tabManager.pendingFocusRequestID == requestID
            },
            onFocusRequestResult: { requestID, succeeded in
                tabManager.acknowledgeFocusRequest(
                    requestID: requestID,
                    for: tab.id,
                    succeeded: succeeded
                )
            },
            canBecomeInitialFirstResponder: {
                paneManager.activePaneID == paneID
                    && tabManager.activeTabID == tab.id
                    && SidebarKeyboardFocusPolicy.allowsEditorInitialFocus(
                        tabID: tab.id,
                        pendingFocusTabID: tabManager.pendingFocusTabID,
                        firstResponder: NSApp.keyWindow?.firstResponder
                    )
            },
            indentStyle: tab.cachedIndentation,
            fontSize: FontSizeSettings.shared.fontSize
        )
        .id(tab.id)
        .accessibilityIdentifier(AccessibilityID.codeEditor)
        .background {
            LSPDocumentPresentationLifecycle(
                manager: projectManager.lspManager,
                url: tab.fileURL,
                contentRevision: tab.contentVersion,
                text: tab.content
            )
            .id(tab.id)
        }
        .onAppear {
            goToLineOffset = nil
            projectManager.problemsController.refreshDocumentOwnership()
            if let fileURL = tab.fileURL {
                configValidator.validate(
                    url: fileURL,
                    content: tab.content,
                    revision: tab.contentVersion
                )
            }
            installLSPUIEndpoint(tabManager: tabManager)
        }
        .onDisappear {
            configValidator.clear()
            if let fileURL = tab.fileURL {
                projectManager.problemsController.removeConfigDiagnostics(
                    owner: problemsOwner(
                        for: tab,
                        fileURL: fileURL
                    )
                )
            }
            clearLSPUIEndpoint()
        }
        .onChange(of: tab.content) { _, newValue in
            // The prior result is stale as soon as contentVersion changes.
            // Refreshing ownership makes it disappear before the debounced
            // validator commits the replacement.
            projectManager.problemsController.refreshDocumentOwnership()
            guard let fileURL = tab.fileURL else { return }
            configValidator.validate(
                url: fileURL,
                content: newValue,
                revision: tab.contentVersion
            )
        }
        .onChange(of: tab.fileURL) { _, newURL in
            configValidator.clear()
            if let newURL {
                configValidator.validate(
                    url: newURL,
                    content: tab.content,
                    revision: tab.contentVersion
                )
            }
            projectManager.problemsController.refreshDocumentOwnership()
        }
        .onChange(of: configValidator.diagnosticsResultGeneration) { _, _ in
            guard let fileURL = tab.fileURL,
                  let revision = configValidator.diagnosticsRevision else {
                return
            }
            projectManager.problemsController.setConfigDiagnostics(
                configValidator.diagnostics,
                owner: problemsOwner(for: tab, fileURL: fileURL),
                contentRevision: revision
            )
        }
    }

    // MARK: - LSP UI endpoint installation

    private func problemsOwner(
        for tab: EditorTab,
        fileURL: URL
    ) -> ProblemsDocumentOwner {
        projectManager.problemsController.documentOwner(
            paneID: paneID,
            tabID: tab.id,
            uri: fileURL.absoluteString
        )
    }

    /// Installs the LSP UI endpoint handlers so the editor coordinator can
    /// route hover, definition, code action, and rename requests to this
    /// project's `LSPManager`.
    private func installLSPUIEndpoint(tabManager: TabManager) {
        let lspManager = projectManager.lspManager

        LSPUIEndpoint.shared.hoverHandler = { url, offset, text in
            await lspManager.hover(url: url, offset: offset, text: text)
        }
        LSPUIEndpoint.shared.definitionHandler = { url, offset, text in
            await lspManager.definition(url: url, offset: offset, text: text)
        }
        LSPUIEndpoint.shared.codeActionHandler = { url, offset, text in
            await lspManager.codeAction(url: url, offset: offset, text: text)
        }
        LSPUIEndpoint.shared.renameHandler = { url, offset, text, newName in
            await lspManager.rename(url: url, offset: offset, text: text, newName: newName)
        }
        LSPUIEndpoint.shared.applyEditHandler = { edit in
            lspManager.applyWorkspaceEdit(
                edit,
                tabManager: tabManager,
                workspaceURL: workspace.rootURL
            )
        }
        LSPUIEndpoint.shared.openFileAtLineHandler = { [weak tabManager] url, line, character in
            guard let tabManager else { return }
            Self.openLSPFile(
                url: url,
                line: line,
                character: character,
                in: tabManager
            )
        }
    }

    /// Routes a 0-based LSP destination through the location-aware open path.
    /// `TabManager` installs the destination only after a pending large-file
    /// decision succeeds, so the source tab cannot consume it prematurely.
    @discardableResult
    static func openLSPFile(
        url: URL,
        line: Int,
        character: Int,
        in tabManager: TabManager,
        completion: TabManager.OpenCompletion? = nil
    ) -> TabManager.OpenRequestResult {
        tabManager.openTabAndGoToLocation(
            url: url,
            line: oneBasedLSPCoordinate(line),
            column: oneBasedLSPCoordinate(character),
            completion: completion
        )
    }

    /// Converts an untrusted 0-based LSP coordinate to Pine's 1-based
    /// coordinate without trapping on a negative or `Int.max` server value.
    private static func oneBasedLSPCoordinate(_ value: Int) -> Int {
        guard value > 0 else { return 1 }
        return value == .max ? .max : value + 1
    }

    /// Clears the LSP UI endpoint handlers.
    private func clearLSPUIEndpoint() {
        LSPUIEndpoint.shared.hoverHandler = nil
        LSPUIEndpoint.shared.definitionHandler = nil
        LSPUIEndpoint.shared.codeActionHandler = nil
        LSPUIEndpoint.shared.renameHandler = nil
        LSPUIEndpoint.shared.applyEditHandler = nil
        LSPUIEndpoint.shared.openFileAtLineHandler = nil
    }

    // MARK: - Diagnostics merging

    /// Merges config-validator diagnostics (yamllint, shellcheck, etc.) with
    /// LSP diagnostics for the given file. LSP diagnostics are keyed by
    /// document URI; config diagnostics are per-active-file in the validator.
    private func mergedDiagnostics(for tab: EditorTab) -> [ValidationDiagnostic] {
        guard let fileURL = tab.fileURL else { return [] }
        var combined = configValidator.diagnostics
        combined.append(
            contentsOf: projectManager.lspManager.diagnostics(for: fileURL)
        )
        return combined
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
        guard let tab = tabManager.activeTab,
              let fileURL = tab.fileURL else {
            lineDiffs = []
            diffHunks = []
            diffVersion &+= 1
            return
        }
        let provider = workspace.gitProvider
        guard provider.isGitRepository, let repoURL = workspace.rootURL else {
            lineDiffs = []
            diffHunks = []
            diffVersion &+= 1
            return
        }
        let tabID = tab.id
        let contentVersion = tab.contentVersion
        let content = tab.content
        let isDirty = tab.isDirty
        diffTask = Task { @MainActor in
            if debounce {
                try? await Task.sleep(for: Self.diffDebounce)
                if Task.isCancelled { return }
            }

            if isDirty {
                let resolvedDiffs = await provider.diffForBufferAsync(
                    at: fileURL,
                    content: content
                )
                if Task.isCancelled { return }
                guard let activeTab = tabManager.activeTab,
                      activeTab.id == tabID,
                      activeTab.fileURL == fileURL,
                      activeTab.contentVersion == contentVersion else { return }
                lineDiffs = resolvedDiffs
                // Hunk actions mutate the worktree/index and therefore must
                // never be offered from a diff calculated from unsaved text.
                diffHunks = []
                diffVersion &+= 1
                return
            }

            async let diffs = provider.diffForFileAsync(at: fileURL)
            async let hunks = InlineDiffProvider.fetchHunks(for: fileURL, repoURL: repoURL)
            let (resolvedDiffs, resolvedHunks) = await (diffs, hunks)
            if Task.isCancelled { return }
            guard let activeTab = tabManager.activeTab,
                  activeTab.id == tabID,
                  activeTab.fileURL == fileURL,
                  activeTab.contentVersion == contentVersion else { return }
            lineDiffs = resolvedDiffs
            diffHunks = resolvedHunks
            diffVersion &+= 1
        }
    }

    /// Refreshes cached blame data for the active tab.
    private func refreshBlame(tabManager: TabManager) {
        blameTask?.cancel()
        guard isBlameVisible else {
            blameLines = []
            return
        }
        guard let tab = tabManager.activeTab,
              let fileURL = tab.fileURL else {
            blameLines = []
            return
        }
        let provider = workspace.gitProvider
        guard provider.isGitRepository, let repoURL = provider.repositoryURL else {
            blameLines = []
            return
        }
        let filePath = fileURL.path
        blameTask = Task.detached {
            let result = await GitStatusProvider.runGitAsync(
                ["blame", "--porcelain", "--", filePath], at: repoURL
            )
            guard !Task.isCancelled else { return }
            let lines: [GitBlameLine]
            if result.succeeded, !result.output.isEmpty {
                lines = GitStatusProvider.parseBlame(result.output)
            } else {
                lines = []
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                if tabManager.activeTab?.fileURL == fileURL {
                    blameLines = lines
                }
            }
        }
    }

    // MARK: - Gutter accept/revert

    private func handleGutterAccept(_ hunk: DiffHunk, tabManager: TabManager) {
        guard let tab = tabManager.activeTab,
              let fileURL = tab.fileURL,
              let repoURL = workspace.rootURL else { return }
        Task {
            await InlineDiffProvider.acceptHunk(
                hunk,
                fileURL: fileURL,
                repoURL: repoURL
            )
            await workspace.gitProvider.refreshAsync()
            refreshLineDiffs(tabManager: tabManager)
        }
    }

    private func handleGutterRevert(_ hunk: DiffHunk, tabManager: TabManager) {
        guard let tab = tabManager.activeTab,
              let fileURL = tab.fileURL,
              let repoURL = workspace.rootURL else { return }
        Task {
            if let newContent = await InlineDiffProvider.revertHunk(
                hunk,
                fileURL: fileURL,
                repoURL: repoURL
            ) {
                tabManager.updateContent(newContent)
                tabManager.reloadTab(url: fileURL)
                await workspace.gitProvider.refreshAsync()
                refreshLineDiffs(tabManager: tabManager)
            }
        }
    }

    // MARK: - Tab close with dirty confirmation

    private func closeTabWithConfirmation(_ tab: EditorTab, tabManager: TabManager) {
        let context = DialogPresenter.forProject(projectManager)
        Task { @MainActor in
            let didClose = await TabCloseHelper.closeTab(
                tab,
                in: tabManager,
                gitProvider: workspace.gitProvider,
                context: context,
                saveTab: { index in
                    guard tabManager.tabs.indices.contains(index) else {
                        return false
                    }
                    return await projectManager.saveTab(
                        tabID: tabManager.tabs[index].id,
                        in: tabManager,
                        forceSaveAs: false,
                        context: context
                    )
                }
            )
            if didClose && tabManager.tabs.isEmpty {
                paneManager.removePane(paneID)
            }
        }
    }

    private func closeOtherTabsWithConfirmation(keeping tabID: UUID, tabManager: TabManager) {
        let context = DialogPresenter.forProject(projectManager)
        Task { @MainActor in
            _ = await TabCloseHelper.closeOtherTabs(
                keeping: tabID,
                in: tabManager,
                gitProvider: workspace.gitProvider,
                context: context,
                saveTab: { index in
                    guard tabManager.tabs.indices.contains(index) else {
                        return false
                    }
                    return await projectManager.saveTab(
                        tabID: tabManager.tabs[index].id,
                        in: tabManager,
                        forceSaveAs: false,
                        context: context
                    )
                }
            )
        }
    }

    private func closeTabsToTheRightWithConfirmation(of tabID: UUID, tabManager: TabManager) {
        let context = DialogPresenter.forProject(projectManager)
        Task { @MainActor in
            _ = await TabCloseHelper.closeTabsToTheRight(
                of: tabID,
                in: tabManager,
                gitProvider: workspace.gitProvider,
                context: context,
                saveTab: { index in
                    guard tabManager.tabs.indices.contains(index) else {
                        return false
                    }
                    return await projectManager.saveTab(
                        tabID: tabManager.tabs[index].id,
                        in: tabManager,
                        forceSaveAs: false,
                        context: context
                    )
                }
            )
        }
    }

    private func closeAllTabsWithConfirmation(tabManager: TabManager) {
        let context = DialogPresenter.forProject(projectManager)
        Task { @MainActor in
            let didClose = await TabCloseHelper.closeAllTabs(
                in: tabManager,
                gitProvider: workspace.gitProvider,
                context: context,
                saveTab: { index in
                    guard tabManager.tabs.indices.contains(index) else {
                        return false
                    }
                    return await projectManager.saveTab(
                        tabID: tabManager.tabs[index].id,
                        in: tabManager,
                        forceSaveAs: false,
                        context: context
                    )
                }
            )
            if didClose && tabManager.tabs.isEmpty {
                paneManager.removePane(paneID)
            }
        }
    }
}

/// Owns one LSP document lease for one mounted editor presentation. A durable
/// tab ID can be reused across a window reopen, while these UUIDs cannot; an
/// old view's delayed disappearance therefore removes only its own buffer.
private struct LSPDocumentPresentationLifecycle: View {
    let manager: LSPManager
    let url: URL?
    let contentRevision: UInt64
    let text: String
    @State private var ownerID = UUID()

    var body: some View {
        Color.clear
            .onAppear {
                guard let url else { return }
                manager.didOpen(
                    url: url,
                    ownerID: ownerID,
                    contentRevision: contentRevision,
                    text: text
                )
            }
            .onDisappear {
                guard let url else { return }
                manager.didClose(url: url, ownerID: ownerID)
            }
            .onChange(of: text) { _, newText in
                guard let url else { return }
                manager.didChange(
                    url: url,
                    ownerID: ownerID,
                    contentRevision: contentRevision,
                    text: newText
                )
            }
            .onChange(of: url) { oldURL, newURL in
                if let oldURL {
                    manager.didClose(url: oldURL, ownerID: ownerID)
                }
                if let newURL {
                    manager.didOpen(
                        url: newURL,
                        ownerID: ownerID,
                        contentRevision: contentRevision,
                        text: text
                    )
                }
            }
    }
}
