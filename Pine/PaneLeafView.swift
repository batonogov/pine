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
    /// Handle for the most recently scheduled diff refresh so new triggers
    /// can cancel a stale run (e.g. rapid typing or overlapping observers).
    @State private var diffTask: Task<Void, Never>?
    @State private var configValidator = ConfigValidator()
    @State private var goToLineOffset: GoToRequest?
    @AppStorage("wordWrapEnabled", store: PineStorageContext.defaults) private var isWordWrapEnabled = true

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
        .onDrop(
            of: [.sidebarFileDrag, .fileURL],
            delegate: EditorFileDropDelegate(
                paneID: paneID,
                paneManager: paneManager
            )
        )
        .border(
            isActive && paneManager.root.leafCount > 1
                ? Color.accentColor.opacity(0.5)
                : Color.clear,
            width: 1
        )
        // `.contain` makes the leaf itself the named container, so the
        // `paneLeaf_<id>` identifier cannot propagate into descendant
        // containers (tab bar, terminal search bar) and mask the identifiers
        // they set for themselves — the same propagation EditorTabBar and
        // TerminalPaneTabBar guard their inline controls against.
        .accessibilityElement(children: .contain)
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
                    // Initial load: refresh line diffs for the active tab
                    // even if `activeTabID` never changes (issue #780).
                    refreshLineDiffs(tabManager: tabManager)
                }
                .onChange(of: tabManager.activeTabID) { _, _ in
                    refreshLineDiffs(tabManager: tabManager)
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
                }
                .onChange(of: workspace.gitProvider.isGitRepository) { _, isRepo in
                    if isRepo {
                        refreshLineDiffs(tabManager: tabManager)
                    } else {
                        // Repo removed — clear every cached git-derived state,
                        diffTask?.cancel()
                        diffTask = nil
                        lineDiffs = []
                        diffHunks = []
                    }
                }
                .onDisappear {
                    diffTask?.cancel()
                    diffTask = nil
                }
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
            validationDiagnostics: configValidator.diagnostics,
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
        .onAppear {
            goToLineOffset = nil
            if let fileURL = tab.fileURL {
                configValidator.validate(
                    url: fileURL,
                    content: tab.content,
                    revision: tab.contentVersion
                )
            }
        }
        .onDisappear {
            configValidator.clear()
        }
        .onChange(of: tab.content) { _, newValue in
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
        }
    }

    // MARK: - Git diff

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
        projectManager.requestCloseOtherTabs(keeping: tabID, in: tabManager)
    }

    private func closeTabsToTheRightWithConfirmation(of tabID: UUID, tabManager: TabManager) {
        projectManager.requestCloseTabsToTheRight(of: tabID, in: tabManager)
    }

    private func closeAllTabsWithConfirmation(tabManager: TabManager) {
        projectManager.requestCloseAllTabs(in: tabManager, paneID: paneID)
    }
}

/// Opens sidebar/Finder files in the existing editor; it never creates a layout.
private struct EditorFileDropDelegate: DropDelegate {
    let paneID: PaneID
    let paneManager: PaneManager

    func validateDrop(info: DropInfo) -> Bool {
        paneManager.tabManager(for: paneID) != nil
    }

    func performDrop(info: DropInfo) -> Bool {
        guard paneManager.tabManager(for: paneID) != nil else { return false }
        if info.hasItemsConforming(to: [.sidebarFileDrag]) {
            let providers = info.itemProviders(for: [.sidebarFileDrag])
            Task {
                guard let provider = providers.first,
                      let data = try? await provider.loadItem(
                        forTypeIdentifier: UTType.sidebarFileDrag.identifier
                      ) as? Data,
                      let drag = try? JSONDecoder().decode(
                        SidebarFileDragInfo.self,
                        from: data
                      ) else { return }
                await MainActor.run {
                    paneManager.openFileInPane(url: drag.fileURL, paneID: paneID)
                }
            }
            return true
        }
        let providers = info.itemProviders(for: [.fileURL])
        for provider in providers {
            Task {
                guard let url = try? await provider.loadItem(
                    forTypeIdentifier: UTType.fileURL.identifier
                ) as? URL else { return }
                await MainActor.run {
                    paneManager.openFileInPane(url: url, paneID: paneID)
                }
            }
        }
        return !providers.isEmpty
    }
}
