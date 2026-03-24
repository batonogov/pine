//
//  ContentView.swift
//  Pine
//
//  Created by Федор Батоногов on 09.03.2026.
//

import os
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Главный ContentView

struct ContentView: View {
    @Environment(ProjectManager.self) var projectManager
    @Environment(WorkspaceManager.self) var workspace
    @Environment(TerminalManager.self) var terminal
    @Environment(TabManager.self) var tabManager
    @Environment(ProjectRegistry.self) var registry
    @Environment(\.openWindow) var openWindow

    @Environment(\.controlActiveState) var controlActiveState

    @State private var selectedNode: FileNode?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var lineDiffs: [GitLineDiff] = []
    @State private var blameLines: [GitBlameLine] = []
    @State private var blameTask: Task<Void, Never>?
    @State private var didRestoreSession = false
    @State private var isSearchPresented = false
    @State private var goToLineOffset: GoToRequest?
    @State private var recoveryEntries: [(UUID, RecoveryEntry)] = []
    @State private var showRecoveryDialog = false
    @State private var isDragTargeted = false
    @State private var isQuickOpenPresented = false
    @State private var showGoToLine = false
    @AppStorage("minimapVisible") private var isMinimapVisible = true
    @AppStorage(BlameConstants.storageKey) private var isBlameVisible = true

    private var activeTab: EditorTab? { tabManager.activeTab }

    private var currentFileName: String {
        activeTab?.fileName ?? workspace.projectName
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarSearchableContent(
                selectedNode: $selectedNode,
                workspace: workspace
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
        .onChange(of: tabManager.pendingGoToLine) { _, newLine in
            guard let line = newLine, let tab = tabManager.activeTab else { return }
            tabManager.pendingGoToLine = nil
            goToLineOffset = GoToRequest(offset: Self.cursorOffset(forLine: line, in: tab.content))
        }
    }

    /// Branch subtitle as a plain String to avoid generating a localization key.
    private var branchSubtitle: String {
        workspace.gitProvider.isGitRepository ? "⎇ \(workspace.gitProvider.currentBranch) ▾" : ""
    }

    // MARK: - Search

    // MARK: - Session restoration

    private func restoreSessionIfNeeded() {
        guard !didRestoreSession else { return }
        didRestoreSession = true

        guard let rootURL = workspace.rootURL else {
            didRestoreSession = false // Allow retry when rootURL becomes available
            return
        }

        guard let session = SessionState.load(for: rootURL) else { return }

        // Restore editor tabs only if PM has no tabs (fresh or after restart)
        if tabManager.tabs.isEmpty {
            let disabledSet = Set(session.existingHighlightingDisabledPaths ?? [])
            for url in session.existingFileURLs {
                let disabled = disabledSet.contains(url.path)
                tabManager.openTab(url: url, syntaxHighlightingDisabled: disabled)
            }

            // Restore preview modes for markdown tabs
            if let previewModes = session.existingPreviewModes {
                for index in tabManager.tabs.indices {
                    let path = tabManager.tabs[index].url.path
                    if let rawMode = previewModes[path],
                       let mode = MarkdownPreviewMode(rawValue: rawMode) {
                        tabManager.tabs[index].previewMode = mode
                    }
                }
            }

            // Restore per-tab editor state (cursor, scroll, folds)
            if let editorStates = session.existingEditorStates {
                for index in tabManager.tabs.indices {
                    let path = tabManager.tabs[index].url.path
                    if let state = editorStates[path] {
                        state.apply(to: &tabManager.tabs[index])
                    }
                }
            }

            if let activeURL = session.activeFileURL,
               let tab = tabManager.tab(for: activeURL) {
                tabManager.activeTabID = tab.id
            }
        }

        // Restore terminal state
        if let visible = session.isTerminalVisible {
            terminal.isTerminalVisible = visible
        }
        if let maximized = session.isTerminalMaximized {
            terminal.isTerminalMaximized = maximized
        }

        // Create terminal tabs only if PM has a single default (unused) tab
        // (i.e., fresh PM after restart, not reused from background)
        if let count = session.terminalTabCount, count > 1,
           terminal.terminalTabs.count == 1 {
            for _ in 1..<count {
                terminal.addTerminalTab(workingDirectory: rootURL)
            }
        }
        if let activeIndex = session.activeTerminalIndex,
           activeIndex < terminal.terminalTabs.count {
            terminal.activeTerminalID = terminal.terminalTabs[activeIndex].id
        }
    }

    // MARK: - Crash recovery

    private func checkForRecovery() {
        guard let entries = projectManager.recoveryManager?.pendingRecoveryEntries(),
              !entries.isEmpty else { return }
        recoveryEntries = entries
        showRecoveryDialog = true
    }

    private func recoverTabs() {
        for (_, entry) in recoveryEntries {
            // Skip untitled tabs with empty paths — the original file no longer exists
            guard !entry.originalPath.isEmpty else { continue }

            let url = URL(fileURLWithPath: entry.originalPath)
            tabManager.openTab(url: url)

            // Replace content with recovered version and mark dirty
            if let index = tabManager.tabs.firstIndex(where: { $0.url == url }) {
                tabManager.tabs[index].content = entry.content
                tabManager.tabs[index].encoding = entry.encoding
                tabManager.tabs[index].recomputeContentCaches()
            }
        }
        projectManager.recoveryManager?.deleteAllRecoveryFiles()
        showRecoveryDialog = false
        recoveryEntries = []
    }

    private func discardRecovery() {
        projectManager.recoveryManager?.deleteAllRecoveryFiles()
        showRecoveryDialog = false
        recoveryEntries = []
    }

    /// Reads `PINE_SEARCH_QUERY` from the environment (used by UI tests) and
    /// applies it to the search provider, activating the search UI.
    private func applySearchQueryFromEnvironment() {
        guard let query = ProcessInfo.processInfo.environment["PINE_SEARCH_QUERY"],
              !query.isEmpty,
              let rootURL = workspace.rootURL else { return }
        projectManager.searchProvider.query = query
        isSearchPresented = true
        projectManager.searchProvider.search(in: rootURL)
    }

    // MARK: - Открытие нового проекта

    /// Opens a new project via folder picker, opening it in a new window.
    private func openNewProject() {
        guard let url = registry.openProjectViaPanel() else { return }
        openWindow(value: url)
    }

    // MARK: - Drag & Drop

    /// Handles file URLs dropped onto the editor area.
    /// Files are opened as tabs; directories open as new project windows.
    private func handleFileDrop(providers: [NSItemProvider]) {
        for provider in providers {
            Task {
                guard let url = try? await provider.loadItem(
                    forTypeIdentifier: UTType.fileURL.identifier
                ) as? URL else { return }

                let classified = DropHandler.classifyURLs([url])

                await MainActor.run {
                    // Open directories as new project windows
                    for dir in classified.directories {
                        let canonical = dir.resolvingSymlinksInPath()
                        guard registry.projectManager(for: canonical) != nil else { continue }
                        openWindow(value: canonical)
                    }
                    // Open files as tabs in current project
                    DropHandler.openFilesAsTabs(classified.files, in: tabManager)
                }
            }
        }
    }

    // MARK: - Управление файлами

    private func handleFileSelection(_ node: FileNode) {
        tabManager.openTab(url: node.url)
    }

    /// Syncs sidebar selection to match the active editor tab.
    private func syncSidebarSelection() {
        guard let url = tabManager.activeTab?.url else {
            selectedNode = nil
            return
        }
        // Already pointing at the right node — skip tree traversal
        if selectedNode?.url == url { return }
        selectedNode = findNode(url: url, in: workspace.rootNodes)
    }

    /// Recursively searches the file tree for a node with the given URL.
    private func findNode(url: URL, in nodes: [FileNode]) -> FileNode? {
        for node in nodes {
            if node.url == url { return node }
            if let children = node.children,
               let found = findNode(url: url, in: children) {
                return found
            }
        }
        return nil
    }

    /// Used by GitAndNotificationObserver — internal visibility required for cross-struct access.
    enum ChangeDirection { case next, previous }

    private func navigateToChange(direction: ChangeDirection) {
        guard let tab = tabManager.activeTab, !lineDiffs.isEmpty else { return }
        let currentLine = Self.lineNumber(forOffset: tab.cursorPosition, in: tab.content)
        let starts = GitLineDiff.changeRegionStarts(lineDiffs)
        let targetLine: Int?
        switch direction {
        case .next:
            targetLine = GitLineDiff.nextChangeLine(from: currentLine, regionStarts: starts, diffs: lineDiffs)
        case .previous:
            targetLine = GitLineDiff.previousChangeLine(from: currentLine, regionStarts: starts, diffs: lineDiffs)
        }
        if let line = targetLine {
            goToLineOffset = GoToRequest(offset: Self.cursorOffset(forLine: line, in: tab.content))
        }
    }

    /// Refreshes cached blame data for the active tab.
    /// Cancels any in-flight blame task to avoid stale results.
    private func refreshBlame() {
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

    /// Refreshes cached line diffs for the active tab.
    /// Runs git diff on a background thread to avoid blocking the UI.
    private func refreshLineDiffs() {
        guard let tab = tabManager.activeTab else {
            lineDiffs = []
            return
        }
        let fileURL = tab.url
        let provider = workspace.gitProvider
        guard provider.isGitRepository else {
            lineDiffs = []
            return
        }
        Task {
            let diffs = await provider.diffForFileAsync(at: fileURL)
            if tabManager.activeTab?.url == fileURL {
                lineDiffs = diffs
            }
        }
    }

    /// Closes a tab with unsaved-changes protection.
    /// Used by both the tab bar close button and Cmd+W.
    private func closeTabWithConfirmation(_ tab: EditorTab) {
        if tab.isDirty {
            let alert = NSAlert()
            alert.messageText = Strings.unsavedChangesTitle
            alert.informativeText = Strings.unsavedChangesMessage
            alert.addButton(withTitle: Strings.dialogSave)
            alert.addButton(withTitle: Strings.dialogDontSave)
            alert.addButton(withTitle: Strings.dialogCancel)
            alert.alertStyle = .warning

            let response = alert.runModal()
            switch response {
            case .alertFirstButtonReturn:
                guard let index = tabManager.tabs.firstIndex(where: { $0.id == tab.id }) else { return }
                guard tabManager.saveTab(at: index) else { return }
                Task { await workspace.gitProvider.refreshAsync() }
                tabManager.closeTab(id: tab.id)
            case .alertSecondButtonReturn:
                tabManager.closeTab(id: tab.id)
            default:
                return
            }
        } else {
            tabManager.closeTab(id: tab.id)
        }
    }

    private func handleExternalConflicts(_ conflicts: [TabManager.ExternalConflict]) {
        let modified = conflicts.filter { $0.kind == .modified }
        let deleted = conflicts.filter { $0.kind == .deleted }

        // Single grouped alert for all externally modified dirty tabs
        if !modified.isEmpty {
            let names = modified.map(\.url.lastPathComponent).joined(separator: ", ")
            let alert = NSAlert()
            alert.messageText = Strings.externalModifyTitle
            alert.informativeText = Strings.externalModifyMessage(names)
            alert.addButton(withTitle: Strings.externalModifyReload)
            alert.addButton(withTitle: Strings.externalModifyKeep)
            alert.alertStyle = .warning

            if alert.runModal() == .alertFirstButtonReturn {
                for conflict in modified {
                    tabManager.reloadTab(url: conflict.url)
                }
            }
        }

        // Handle deleted files via existing flow
        for conflict in deleted {
            handleFileDeletion(conflict.url)
        }
    }

    private func handleFileDeletion(_ deletedURL: URL) {
        let affected = tabManager.tabsAffectedByDeletion(url: deletedURL)
        guard !affected.isEmpty else { return }

        let dirtyTabs = affected.filter { $0.isDirty }
        if !dirtyTabs.isEmpty {
            let alert = NSAlert()
            alert.messageText = Strings.fileDeletedTitle
            alert.informativeText = Strings.fileDeletedMessage
            alert.addButton(withTitle: Strings.fileDeletedSaveAs)
            alert.addButton(withTitle: Strings.dialogDontSave)
            alert.addButton(withTitle: Strings.dialogCancel)
            alert.alertStyle = .warning

            let response = alert.runModal()
            switch response {
            case .alertFirstButtonReturn:
                // Save As… for each dirty tab — abort entirely on cancel/error
                for tab in dirtyTabs {
                    let panel = NSSavePanel()
                    panel.nameFieldStringValue = tab.fileName
                    guard panel.runModal() == .OK, let saveURL = panel.url else { return }
                    do {
                        try tab.content.write(to: saveURL, atomically: true, encoding: .utf8)
                    } catch {
                        let errAlert = NSAlert()
                        errAlert.messageText = Strings.fileOperationErrorTitle
                        errAlert.informativeText = error.localizedDescription
                        errAlert.alertStyle = .warning
                        errAlert.runModal()
                        return
                    }
                }
            case .alertSecondButtonReturn:
                break // Don't save — proceed to close
            default:
                return // Cancel — keep tabs open
            }
        }

        tabManager.closeTabsForDeletedFile(url: deletedURL)
    }

    // MARK: - Область редактора

    @ViewBuilder
    private var editorArea: some View {
        VStack(spacing: 0) {
            if !tabManager.tabs.isEmpty {
                EditorTabBar(
                    tabManager: tabManager,
                    onCloseTab: { tab in closeTabWithConfirmation(tab) },
                    onReorder: { projectManager.saveSession() },
                    isMarkdownFile: activeTab?.isMarkdownFile ?? false,
                    previewMode: activeTab?.previewMode ?? .source,
                    onTogglePreview: { tabManager.togglePreviewMode() },
                    isAutoSaving: tabManager.isAutoSaving
                )
            }

            if let tab = activeTab {
                Group {
                    if tab.kind == .preview {
                        QuickLookPreviewView(url: tab.url)
                            .accessibilityIdentifier(AccessibilityID.quickLookPreview)
                    } else if tab.isMarkdownFile {
                        switch tab.previewMode {
                        case .source:
                            codeEditorView(for: tab)
                        case .preview:
                            MarkdownPreviewView(content: tab.content)
                                .accessibilityIdentifier(AccessibilityID.markdownPreviewView)
                        case .split:
                            HSplitView {
                                codeEditorView(for: tab)
                                    .frame(minWidth: 200)
                                MarkdownPreviewView(content: tab.content)
                                    .accessibilityIdentifier(AccessibilityID.markdownPreviewView)
                                    .frame(minWidth: 200)
                            }
                        }
                    } else {
                        codeEditorView(for: tab)
                    }
                }

            } else {
                ContentUnavailableView {
                    Label(Strings.noFileSelected, systemImage: "doc.text")
                } description: {
                    Text(Strings.selectFilePrompt)
                }
                .accessibilityIdentifier(AccessibilityID.editorPlaceholder)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDragTargeted) { providers in
            handleFileDrop(providers: providers)
            return true
        }
        .overlay {
            if isDragTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.blue, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private func codeEditorView(for tab: EditorTab) -> some View {
        CodeEditorView(
            text: Binding(
                get: { tab.content },
                set: { tabManager.updateContent($0) }
            ),
            contentVersion: tab.contentVersion,
            language: tab.language,
            fileName: tab.fileName,
            lineDiffs: lineDiffs,
            isBlameVisible: isBlameVisible,
            blameLines: blameLines,
            foldState: Binding(
                get: { tab.foldState },
                set: { tabManager.updateFoldState($0) }
            ),
            isMinimapVisible: isMinimapVisible,
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
            fontSize: FontSizeSettings.shared.fontSize
        )
        .id(tab.id)
        .accessibilityIdentifier(AccessibilityID.codeEditor)
        .onAppear { goToLineOffset = nil }
    }

    private var totalLineCount: Int {
        guard let content = activeTab?.content else { return 1 }
        let ns = content as NSString
        var count = 1
        var pos = 0
        while pos < ns.length {
            pos = NSMaxRange(ns.lineRange(for: NSRange(location: pos, length: 0)))
            count += 1
        }
        return max(1, count - 1)
    }

    /// Converts a 1-based line number to a UTF-16 cursor offset within content.
    static func cursorOffset(forLine line: Int, in content: String) -> Int {
        let nsContent = content as NSString
        var currentLine = 1
        var offset = 0
        while currentLine < line && offset < nsContent.length {
            let lineRange = nsContent.lineRange(for: NSRange(location: offset, length: 0))
            offset = NSMaxRange(lineRange)
            currentLine += 1
        }
        return min(offset, nsContent.length)
    }

    /// Converts a 1-based line and optional column to a UTF-16 cursor offset.
    static func cursorOffset(forLine line: Int, column: Int?, in content: String) -> Int {
        let lineOffset = cursorOffset(forLine: line, in: content)
        guard let column, column > 1 else { return lineOffset }
        let nsContent = content as NSString
        let lineRange = nsContent.lineRange(for: NSRange(location: lineOffset, length: 0))
        // lineRange.length includes the newline; limit column to actual content length
        let lineText = nsContent.substring(with: lineRange)
        let lineContentLength = lineText.hasSuffix("\n") ? lineRange.length - 1 : lineRange.length
        let colOffset = min(column - 1, lineContentLength)
        return min(lineOffset + colOffset, nsContent.length)
    }

    /// Converts a UTF-16 cursor offset to a 1-based line number.
    static func lineNumber(forOffset offset: Int, in content: String) -> Int {
        let nsContent = content as NSString
        let clamped = min(offset, nsContent.length)
        var line = 1
        var pos = 0
        while pos < clamped {
            let lineRange = nsContent.lineRange(for: NSRange(location: pos, length: 0))
            let lineEnd = NSMaxRange(lineRange)
            if lineEnd > clamped { break }
            // Only advance to next line if a newline actually ends this line
            if lineEnd == clamped && (clamped == 0 || nsContent.character(at: clamped - 1) != ASCII.newline) {
                break
            }
            line += 1
            pos = lineEnd
        }
        return line
    }

    // MARK: - Область терминала

    @ViewBuilder
    private var terminalArea: some View {
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

// MARK: - Sidebar search field

/// Extracted modifier to reduce body complexity for the type-checker.
private struct ProjectSearchModifier: ViewModifier {
    var projectManager: ProjectManager
    @Binding var isSearchPresented: Bool

    func body(content: Content) -> some View {
        content
            .searchable(
                text: Bindable(projectManager.searchProvider).query,
                isPresented: $isSearchPresented,
                placement: .toolbar,
                prompt: Strings.searchPlaceholder
            )
            .onChange(of: projectManager.searchProvider.query) { _, _ in
                guard let rootURL = projectManager.rootURL else { return }
                projectManager.searchProvider.search(in: rootURL)
            }
            .onAppear {
                configureSearchToolbarItem()
            }
    }

    /// Finds the NSSearchToolbarItem in the window toolbar and sets preferred width (Finder-style).
    private func configureSearchToolbarItem() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard let window = NSApp.keyWindow,
                  let toolbar = window.toolbar else { return }
            for item in toolbar.items {
                if let searchItem = item as? NSSearchToolbarItem {
                    searchItem.preferredWidthForSearchField = 180
                    break
                }
            }
        }
    }
}

/// Wrapper view that switches between file tree and search results based on query state.
/// Does not rely on `@Environment(\.isSearching)` or `isSearchPresented` because neither
/// updates reliably when text is entered via XCUITest synthetic events into `NSSearchToolbarItem`.
private struct SidebarSearchableContent: View {
    @Binding var selectedNode: FileNode?
    var workspace: WorkspaceManager
    @Environment(ProjectManager.self) var projectManager

    var body: some View {
        if !projectManager.searchProvider.query.isEmpty {
            SearchResultsView()
        } else {
            SidebarView(workspace: workspace, selectedFile: $selectedNode)
        }
    }
}

// MARK: - Terminal session state observer

/// Saves terminal state to session when visibility, tab count, or active tab changes.
/// Extracted into a ViewModifier to reduce body complexity for the type-checker.
/// Refreshes blame when visibility changes.
/// Extracted into a ViewModifier to reduce body complexity for the type-checker.
private struct BlameObserver: ViewModifier {
    let isBlameVisible: Bool
    let onRefresh: () -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: isBlameVisible) { _, _ in onRefresh() }
    }
}

private struct TerminalSessionObserver: ViewModifier {
    let terminal: TerminalManager
    let onSave: () -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: terminal.isTerminalVisible) { _, _ in onSave() }
            .onChange(of: terminal.isTerminalMaximized) { _, _ in onSave() }
            .onChange(of: terminal.terminalTabs.count) { _, _ in onSave() }
            .onChange(of: terminal.activeTerminalID) { _, _ in onSave() }
    }
}

// MARK: - Git and notification observer

/// Extracted to reduce body complexity for the type-checker.
/// Handles git status changes, file notifications, and menu command notifications.
private struct GitAndNotificationObserver: ViewModifier {
    @Environment(WorkspaceManager.self) private var workspace
    @Environment(TabManager.self) private var tabManager
    @Environment(ProjectManager.self) private var projectManager
    @Environment(\.controlActiveState) private var controlActiveState
    @Binding var lineDiffs: [GitLineDiff]
    @Binding var columnVisibility: NavigationSplitViewVisibility
    @Binding var isSearchPresented: Bool
    @Binding var showGoToLine: Bool
    var onRefreshLineDiffs: () -> Void
    var onRefreshBlame: () -> Void
    var onCloseTab: (EditorTab) -> Void
    var onOpenNewProject: () -> Void
    var onHandleFileDeletion: (URL) -> Void
    var onHandleExternalConflicts: ([TabManager.ExternalConflict]) -> Void
    var onNavigateToChange: (ContentView.ChangeDirection) -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: workspace.gitProvider.isGitRepository) { _, isRepo in
                if isRepo {
                    onRefreshLineDiffs()
                } else {
                    lineDiffs = []
                }
            }
            .onChange(of: workspace.gitProvider.currentBranch) { _, _ in
                onRefreshLineDiffs()
                onRefreshBlame()
            }
            .onChange(of: workspace.gitProvider.fileStatuses) { _, _ in
                onRefreshLineDiffs()
            }
            .onReceive(NotificationCenter.default.publisher(for: .refreshLineDiffs)) { _ in
                guard controlActiveState == .key else { return }
                onRefreshLineDiffs()
                onRefreshBlame()
            }
            .onReceive(NotificationCenter.default.publisher(for: .closeTab)) { _ in
                guard controlActiveState == .key,
                      let tab = tabManager.activeTab else { return }
                onCloseTab(tab)
            }
            .onReceive(NotificationCenter.default.publisher(for: .openFolder)) { _ in
                guard controlActiveState == .key else { return }
                onOpenNewProject()
            }
            .onReceive(NotificationCenter.default.publisher(for: .fileRenamed)) { notification in
                guard let oldURL = notification.userInfo?["oldURL"] as? URL,
                      let newURL = notification.userInfo?["newURL"] as? URL else { return }
                tabManager.handleFileRenamed(oldURL: oldURL, newURL: newURL)
                projectManager.saveSession()
            }
            .onReceive(NotificationCenter.default.publisher(for: .fileDeleted)) { notification in
                guard let deletedURL = notification.userInfo?["url"] as? URL else { return }
                onHandleFileDeletion(deletedURL)
            }
            .onChange(of: workspace.externalChangeToken) { _, _ in
                guard controlActiveState == .key else { return }
                let conflicts = tabManager.checkExternalChanges()
                onHandleExternalConflicts(conflicts)
            }
            .onChange(of: controlActiveState) { _, newState in
                // When the window becomes key, check for external changes that
                // may have been missed while the window was inactive (issue #438).
                guard newState == .key else { return }
                let conflicts = tabManager.checkExternalChanges()
                onHandleExternalConflicts(conflicts)
            }
            .onReceive(NotificationCenter.default.publisher(for: .showProjectSearch)) { _ in
                columnVisibility = .all
                isSearchPresented = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .goToLine)) { _ in
                guard controlActiveState == .key,
                      tabManager.activeTab != nil else { return }
                showGoToLine = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .navigateChange)) { notification in
                guard controlActiveState == .key,
                      let direction = notification.userInfo?["direction"] as? String else { return }
                onNavigateToChange(direction == "next" ? .next : .previous)
            }
    }
}

// MARK: - Terminal search bar container

/// Isolated view to keep TerminalSearchBar's closures out of ContentView's type-checking scope.
private struct TerminalSearchBarContainer: View {
    var terminal: TerminalManager

    var body: some View {
        if terminal.isSearchVisible {
            TerminalSearchBar(
                query: Bindable(terminal).terminalSearchQuery,
                caseSensitive: Bindable(terminal).isSearchCaseSensitive,
                matchCount: terminal.activeTerminalTab?.searchMatches.count ?? 0,
                currentMatch: terminal.activeTerminalTab?.currentMatchIndex ?? -1,
                onNext: {
                    terminal.activeTerminalTab?.nextMatch()
                },
                onPrevious: {
                    terminal.activeTerminalTab?.previousMatch()
                },
                onDismiss: {
                    terminal.isSearchVisible = false
                    terminal.terminalSearchQuery = ""
                    terminal.activeTerminalTab?.clearSearch()
                }
            )
        }
    }
}

// MARK: - Terminal search observer

/// Extracted modifier to reduce body complexity for the type-checker.
/// Handles debounced search, case-sensitivity changes, and tab switching.
private struct TerminalSearchObserver: ViewModifier {
    var terminal: TerminalManager
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var searchTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .findInTerminal)) { _ in
                guard controlActiveState == .key, terminal.isTerminalVisible else { return }
                terminal.isSearchVisible = true
            }
            .onChange(of: terminal.terminalSearchQuery) { _, newQuery in
                searchTask?.cancel()
                searchTask = Task {
                    try? await Task.sleep(for: .milliseconds(150))
                    guard !Task.isCancelled else { return }
                    await terminal.activeTerminalTab?.search(
                        for: newQuery,
                        caseSensitive: terminal.isSearchCaseSensitive
                    )
                }
            }
            .onChange(of: terminal.isSearchCaseSensitive) { _, _ in
                guard terminal.isSearchVisible, !terminal.terminalSearchQuery.isEmpty else { return }
                searchTask?.cancel()
                searchTask = Task {
                    await terminal.activeTerminalTab?.search(
                        for: terminal.terminalSearchQuery,
                        caseSensitive: terminal.isSearchCaseSensitive
                    )
                }
            }
            .onChange(of: terminal.activeTerminalID) { _, _ in
                guard terminal.isSearchVisible, !terminal.terminalSearchQuery.isEmpty else { return }
                searchTask?.cancel()
                searchTask = Task {
                    await terminal.activeTerminalTab?.search(
                        for: terminal.terminalSearchQuery,
                        caseSensitive: terminal.isSearchCaseSensitive
                    )
                }
            }
    }
}

// MARK: - Панель вкладок терминала (стиль нативных macOS window tabs)

struct TerminalNativeTabBar: View {
    var terminal: TerminalManager
    var workingDirectory: URL?

    private func closeTerminalTabWithConfirmation(_ tab: TerminalTab) {
        if tab.hasForegroundProcess {
            let alert = NSAlert()
            alert.messageText = Strings.terminalTabCloseWarningTitle
            alert.informativeText = Strings.terminalTabCloseWarningMessage
            alert.addButton(withTitle: Strings.terminalTabCloseWarningClose)
            alert.addButton(withTitle: Strings.dialogCancel)
            alert.alertStyle = .warning

            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        terminal.closeTerminalTab(tab)
    }

    var body: some View {
        HStack(spacing: 0) {
            // Вкладки терминалов
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(terminal.terminalTabs) { tab in
                        TerminalNativeTabItem(
                            tab: tab,
                            isActive: tab.id == terminal.activeTerminalID,
                            canClose: terminal.terminalTabs.count > 1,
                            onSelect: { terminal.activeTerminalID = tab.id },
                            onClose: { closeTerminalTabWithConfirmation(tab) }
                        )
                    }
                }
                .padding(.horizontal, 4)
            }

            // Кнопка "+" — новый терминал
            Button {
                terminal.addTerminalTab(workingDirectory: workingDirectory)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help(Strings.newTerminal)
            .accessibilityIdentifier(AccessibilityID.newTerminalButton)
            .accessibilityAddTraits(.isButton)

            Spacer()

            // Развернуть / свернуть терминал на весь экран
            Button {
                withAnimation { terminal.isTerminalMaximized.toggle() }
            } label: {
                Image(systemName: terminal.isTerminalMaximized
                      ? "arrow.down.right.and.arrow.up.left"
                      : "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help(terminal.isTerminalMaximized ? Strings.restoreTerminal : Strings.maximizeTerminal)
            .accessibilityIdentifier(AccessibilityID.maximizeTerminalButton)

            // Кнопка скрытия терминала
            Button {
                withAnimation {
                    terminal.isTerminalVisible = false
                    terminal.isTerminalMaximized = false
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 4)
            .help(Strings.hideTerminal)
            .accessibilityIdentifier(AccessibilityID.hideTerminalButton)
        }
        .frame(height: 30)
        .background(.bar)
    }
}

/// Вкладка терминала в стиле macOS window tab (capsule).
struct TerminalNativeTabItem: View {
    let tab: TerminalTab
    let isActive: Bool
    let canClose: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 4) {
            // Кнопка закрытия — видна при hover или активной вкладке
            if canClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 14, height: 14)
                        .background(
                            isHovering ? Color.primary.opacity(0.1) : .clear,
                            in: Circle()
                        )
                }
                .buttonStyle(.plain)
                .opacity(isHovering || isActive ? 1 : 0)
            }

            Image(systemName: "terminal")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)

            Text(tab.name)
                .font(.system(size: 11))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            isActive
                ? Color.primary.opacity(0.12)
                : isHovering ? Color.primary.opacity(0.05) : .clear,
            in: Capsule()
        )
        .contentShape(Capsule())
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
        .accessibilityIdentifier(AccessibilityID.terminalTab(tab.name))
    }
}

// MARK: - Sidebar edit state

/// Tracks inline rename / new-item state for the sidebar file tree.
@Observable
final class SidebarEditState {
    var renamingURL: URL?
    var editingText: String = ""
    var isNewlyCreated: Bool = false
    /// URL of the newly created node to scroll to in the sidebar.
    var scrollToNodeID: URL?

    func startRename(for node: FileNode) {
        renamingURL = node.url
        editingText = node.name
        isNewlyCreated = false
    }

    func startNewItem(url: URL) {
        renamingURL = url
        editingText = url.lastPathComponent
        isNewlyCreated = true
    }

    func clear() {
        renamingURL = nil
        editingText = ""
        isNewlyCreated = false
    }

    /// Creates a file or folder with a unique "untitled" name, then starts inline rename.
    ///
    /// When creating a new item, undo registration is deferred to `commitRename` so that
    /// the entire create+rename sequence is undone as a single Cmd+Z action (#527).
    /// The `undoManager` is stored and used later by `commitRename`.
    func createNewItem(
        in parentURL: URL,
        isDirectory: Bool,
        workspace: WorkspaceManager,
        undoManager: UndoManager? = nil
    ) {
        if let root = workspace.rootURL, !FileNode.isWithinProjectRoot(parentURL, projectRoot: root) {
            Self.showFileError(Strings.operationOutsideProject)
            return
        }

        let baseName = isDirectory ? "untitled folder" : "untitled"
        let name = Self.uniqueName(baseName, in: parentURL)
        let newURL = parentURL.appendingPathComponent(name)

        do {
            // Do NOT register undo here — undo is deferred to commitRename so that
            // create + rename are grouped as a single undo action (#527).
            if isDirectory {
                try FileManager.default.createDirectory(at: newURL, withIntermediateDirectories: false)
            } else if !FileManager.default.createFile(atPath: newURL.path, contents: nil) {
                Self.showFileError(Strings.fileCreateError(name))
                return
            }
            workspace.refreshFileTree()
            startNewItem(url: newURL)
            scrollToNodeID = newURL
        } catch {
            Self.showFileError(error.localizedDescription)
        }
    }

    /// Duplicates a file or folder with Finder-style naming, then starts inline rename.
    func duplicateItem(
        at url: URL,
        isDirectory: Bool,
        workspace: WorkspaceManager,
        tabManager: TabManager
    ) {
        if let root = workspace.rootURL, !FileNode.isWithinProjectRoot(url, projectRoot: root) {
            Self.showFileError(Strings.operationOutsideProject)
            return
        }

        guard let copyURL = Self.finderCopyURL(for: url) else { return }

        do {
            try FileManager.default.copyItem(at: url, to: copyURL)
            workspace.refreshFileTree()
            // Start inline rename — same pattern as createNewItem.
            // isNewlyCreated is false so cancelling rename keeps the copy.
            renamingURL = copyURL
            editingText = copyURL.lastPathComponent
            isNewlyCreated = false
            scrollToNodeID = copyURL
            if !isDirectory {
                tabManager.openTab(url: copyURL)
            }
        } catch {
            Self.showFileError(error.localizedDescription)
        }
    }

    /// Returns a unique name by appending a counter if the name already exists.
    static func uniqueName(_ baseName: String, in parentURL: URL) -> String {
        FileNameGenerator.uniqueName(baseName, in: parentURL)
    }

    /// Generates a Finder-style copy URL: "name copy", "name copy 2", etc.
    static func finderCopyURL(for url: URL) -> URL? {
        FileNameGenerator.finderCopyURL(for: url)
    }

    /// Shows an AppKit error alert for file operations.
    static func showFileError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = Strings.fileOperationErrorTitle
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}

// MARK: - Сайдбар

struct SidebarView: View {
    var workspace: WorkspaceManager
    @Binding var selectedFile: FileNode?
    @Environment(ProjectRegistry.self) var registry
    @Environment(\.openWindow) var openWindow
    @Environment(\.undoManager) private var undoManager
    @State private var editState = SidebarEditState()

    var body: some View {
        Group {
            if workspace.rootURL == nil {
                List {
                    ContentUnavailableView {
                        Label(Strings.noFolderOpen, systemImage: "folder")
                    } description: {
                        Text(Strings.openFolderPrompt)
                    } actions: {
                        Button(Strings.openFolderButton) {
                            openNewProject()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .navigationTitle(Strings.filesTitle)
            } else {
                ScrollViewReader { scrollProxy in
                    List(workspace.rootNodes, children: \.optionalChildren, selection: $selectedFile) { node in
                        FileNodeRow(node: node)
                            .id(node.id)
                    }
                    .environment(editState)
                    .contextMenu {
                        if let rootURL = workspace.rootURL {
                            Button {
                                editState.createNewItem(
                                    in: rootURL,
                                    isDirectory: false,
                                    workspace: workspace,
                                    undoManager: undoManager
                                )
                            } label: {
                                Label(Strings.contextNewFile, systemImage: MenuIcons.newFile)
                            }

                            Button {
                                editState.createNewItem(
                                    in: rootURL,
                                    isDirectory: true,
                                    workspace: workspace,
                                    undoManager: undoManager
                                )
                            } label: {
                                Label(Strings.contextNewFolder, systemImage: MenuIcons.newFolder)
                            }

                            Divider()

                            Button {
                                NSWorkspace.shared.activateFileViewerSelecting([rootURL])
                            } label: {
                                Label(Strings.contextRevealInFinder, systemImage: MenuIcons.revealInFinder)
                            }
                        }
                    }
                    .navigationTitle(workspace.projectName)
                    .onChange(of: editState.renamingURL) { _, newURL in
                        if newURL != nil {
                            // Defer to avoid modifying state during view update
                            DispatchQueue.main.async {
                                selectedFile = nil
                            }
                        }
                    }
                    .onChange(of: editState.scrollToNodeID) { _, targetID in
                        guard let targetID else { return }
                        // Defer scroll to next run loop so the file tree has time to update.
                        DispatchQueue.main.async {
                            withAnimation {
                                scrollProxy.scrollTo(targetID, anchor: .center)
                            }
                            editState.scrollToNodeID = nil
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 200, idealWidth: 250)
    }

    /// Opens a new project via folder picker in a new window.
    private func openNewProject() {
        guard let url = registry.openProjectViaPanel() else { return }
        openWindow(value: url)
    }

}

// MARK: - Window document-edited dot tracker

/// Sets `NSWindow.isDocumentEdited` based on whether any tab has unsaved changes.
/// This shows/hides the dot in the window's close button (standard macOS behavior).
private struct DocumentEditedTracker: NSViewRepresentable {
    let isEdited: Bool

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.window?.isDocumentEdited = isEdited
    }
}

// MARK: - Строка файла/папки в дереве

struct FileNodeRow: View {
    private static let logger = Logger.editor
    var node: FileNode
    @Environment(WorkspaceManager.self) var workspace
    @Environment(TabManager.self) var tabManager
    @Environment(SidebarEditState.self) var editState
    @Environment(\.undoManager) private var undoManager
    @FocusState private var isTextFieldFocused: Bool

    private var isEditing: Bool {
        guard let renamingURL = editState.renamingURL else { return false }
        // Compare by path to ignore trailing-slash differences between
        // URLs built via appendingPathComponent (no slash) and URLs
        // returned by contentsOfDirectory (trailing slash for directories).
        return renamingURL.path == node.url.path
    }

    private var gitStatus: GitFileStatus? {
        let provider = workspace.gitProvider
        return node.isDirectory
            ? provider.statusForDirectory(at: node.url)
            : provider.statusForFile(at: node.url)
    }

    private var isGitIgnored: Bool {
        workspace.gitProvider.isIgnored(at: node.url)
    }

    private var iconName: String {
        node.isDirectory
            ? FileIconMapper.iconForFolder(node.name)
            : FileIconMapper.iconForFile(node.name)
    }

    var body: some View {
        Group {
            if isEditing {
                inlineEditor
            } else {
                Label(node.name, systemImage: iconName)
                    .foregroundStyle(gitStatus?.color ?? .primary)
                    .opacity(isGitIgnored ? 0.5 : 1.0)
            }
        }
        .tag(node)
        .accessibilityIdentifier(AccessibilityID.fileNode(node.name))
        .contextMenu { fileNodeContextMenu }
    }

    // MARK: - Inline editor

    @ViewBuilder
    private var inlineEditor: some View {
        @Bindable var state = editState
        HStack(spacing: 4) {
            Image(systemName: iconName)
                .foregroundStyle(.secondary)
            TextField("", text: $state.editingText)
                .textFieldStyle(.plain)
                .onSubmit { commitRename() }
                .onExitCommand { cancelRename() }
                .focused($isTextFieldFocused)
                .onAppear {
                    DispatchQueue.main.async {
                        isTextFieldFocused = true
                    }
                }
                .onChange(of: isTextFieldFocused) { _, focused in
                    // Guard against double-commit: onSubmit clears editState,
                    // then focus loss fires — skip if already committed.
                    guard !focused, editState.renamingURL?.path == node.url.path else { return }
                    commitRename()
                }
        }
    }

    // MARK: - Context menu

    @ViewBuilder
    private var fileNodeContextMenu: some View {
        if node.isDirectory {
            Button {
                createNewItem(isDirectory: false)
            } label: {
                Label(Strings.contextNewFile, systemImage: MenuIcons.newFile)
            }

            Button {
                createNewItem(isDirectory: true)
            } label: {
                Label(Strings.contextNewFolder, systemImage: MenuIcons.newFolder)
            }

            Divider()
        }

        Button {
            duplicateItem()
        } label: {
            Label(Strings.contextDuplicate, systemImage: MenuIcons.duplicate)
        }

        Button {
            editState.startRename(for: node)
        } label: {
            Label(Strings.contextRename, systemImage: MenuIcons.rename)
        }

        Button(role: .destructive) {
            deleteItem()
        } label: {
            Label(Strings.contextDelete, systemImage: MenuIcons.delete)
        }

        Divider()

        Button {
            NSWorkspace.shared.activateFileViewerSelecting([node.url])
        } label: {
            Label(Strings.contextRevealInFinder, systemImage: MenuIcons.revealInFinder)
        }
    }

    // MARK: - File operations

    private func createNewItem(isDirectory: Bool) {
        editState.createNewItem(
            in: node.url,
            isDirectory: isDirectory,
            workspace: workspace,
            undoManager: undoManager
        )
    }

    private func duplicateItem() {
        editState.duplicateItem(
            at: node.url,
            isDirectory: node.isDirectory,
            workspace: workspace,
            tabManager: tabManager
        )
    }

    private func commitRename() {
        guard editState.renamingURL?.path == node.url.path else { return }

        let newName = editState.editingText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty else {
            cancelRename()
            return
        }

        let oldURL = node.url
        let newURL = oldURL.deletingLastPathComponent().appendingPathComponent(newName)

        if let root = workspace.rootURL,
           !FileNode.isWithinProjectRoot(oldURL, projectRoot: root)
            || !FileNode.isWithinProjectRoot(newURL, projectRoot: root) {
            SidebarEditState.showFileError(Strings.operationOutsideProject)
            editState.clear()
            return
        }
        let wasNewlyCreated = editState.isNewlyCreated

        // Name unchanged — accept as-is
        if newURL == oldURL {
            editState.clear()
            // For newly created items, register a single undo that deletes the file (#527)
            if wasNewlyCreated, let undoManager {
                try? FileOperationUndoManager.registerCreateUndo(at: oldURL, undoManager: undoManager)
            }
            if wasNewlyCreated && !node.isDirectory {
                tabManager.openTab(url: oldURL)
            }
            return
        }

        do {
            if wasNewlyCreated {
                // For newly created items: rename without undo registration, then register
                // a single undo that deletes the final file — so Cmd+Z removes it entirely (#527).
                try FileManager.default.moveItem(at: oldURL, to: newURL)
                if let undoManager {
                    try? FileOperationUndoManager.registerCreateUndo(at: newURL, undoManager: undoManager)
                }
            } else if let undoManager {
                try FileOperationUndoManager.renameItem(from: oldURL, to: newURL, undoManager: undoManager)
            } else {
                try FileManager.default.moveItem(at: oldURL, to: newURL)
            }
            editState.clear()
            workspace.refreshFileTree()
            NotificationCenter.default.post(
                name: .fileRenamed,
                object: nil,
                userInfo: ["oldURL": oldURL, "newURL": newURL]
            )
            // Auto-open newly created files in an editor tab
            if wasNewlyCreated && !node.isDirectory {
                tabManager.openTab(url: newURL)
            }
        } catch {
            // Keep editing so the user can try a different name
            SidebarEditState.showFileError(error.localizedDescription)
        }
    }

    private func cancelRename() {
        let wasNewlyCreated = editState.isNewlyCreated
        let url = editState.renamingURL
        editState.clear()

        // Delete placeholder item if creation was cancelled
        if wasNewlyCreated, let url {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                Self.logger.error("Failed to delete placeholder item \(url.lastPathComponent): \(error)")
            }
            workspace.refreshFileTree()
        }
    }

    private func deleteItem() {
        let deletedURL = node.url

        if let root = workspace.rootURL, !FileNode.isWithinProjectRoot(deletedURL, projectRoot: root) {
            SidebarEditState.showFileError(Strings.operationOutsideProject)
            return
        }

        do {
            if let undoManager {
                try FileOperationUndoManager.deleteItem(at: deletedURL, undoManager: undoManager)
            } else {
                try FileManager.default.trashItem(at: deletedURL, resultingItemURL: nil)
            }
            workspace.refreshFileTree()
            NotificationCenter.default.post(
                name: .fileDeleted,
                object: nil,
                userInfo: ["url": deletedURL]
            )
        } catch {
            SidebarEditState.showFileError(error.localizedDescription)
        }
    }
}

// MARK: - Status Bar

struct StatusBarView: View {
    var gitProvider: GitStatusProvider
    var terminal: TerminalManager
    var tabManager: TabManager
    var progress: ProgressTracker?

    var body: some View {
        HStack(spacing: LayoutMetrics.statusBarItemSpacing) {
            if let progress, progress.isLoading {
                HStack(spacing: 4) {
                    ProgressView()
                        .controlSize(.mini)
                    Text(verbatim: progress.message)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .accessibilityIdentifier(AccessibilityID.progressIndicator)
            }

            if gitProvider.isGitRepository {
                // Git file change summary
                if !gitProvider.fileStatuses.isEmpty {
                    let counts = gitStatusCounts
                    HStack(spacing: 8) {
                        if counts.modified > 0 {
                            Label {
                                Text(verbatim: "\(counts.modified)")
                            } icon: {
                                Image(systemName: "pencil")
                            }
                            .foregroundStyle(.orange)
                        }
                        if counts.added > 0 {
                            Label {
                                Text(verbatim: "\(counts.added)")
                            } icon: {
                                Image(systemName: "plus")
                            }
                            .foregroundStyle(.green)
                        }
                        if counts.untracked > 0 {
                            Label {
                                Text(verbatim: "\(counts.untracked)")
                            } icon: {
                                Image(systemName: "questionmark")
                            }
                            .foregroundStyle(.teal)
                        }
                    }
                    .font(.system(size: LayoutMetrics.captionFontSize))
                }
            }

            Spacer()

            if let activeTab = tabManager.activeTab, activeTab.kind == .text {
                // Line / Column indicator (cached in EditorTab by TabManager)
                Text(verbatim: "Ln \(activeTab.cursorLine), Col \(activeTab.cursorColumn)")
                    .font(.system(size: LayoutMetrics.bodySmallFontSize))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(AccessibilityID.cursorPosition)

                statusDivider

                // Indentation style indicator (cached, recomputed on content change)
                Text(verbatim: activeTab.cachedIndentation.displayName)
                    .font(.system(size: LayoutMetrics.bodySmallFontSize))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(AccessibilityID.indentationIndicator)

                statusDivider

                // Line ending indicator (cached, recomputed on content change)
                Text(verbatim: activeTab.cachedLineEnding.displayName)
                    .font(.system(size: LayoutMetrics.bodySmallFontSize))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(AccessibilityID.lineEndingIndicator)

                statusDivider

                // File encoding indicator with menu to change encoding
                Menu {
                    ForEach(String.Encoding.availableEncodings, id: \.rawValue) { encoding in
                        Button {
                            tabManager.reopenActiveTab(withEncoding: encoding)
                        } label: {
                            HStack {
                                Text(encoding.displayName)
                                if encoding == activeTab.encoding {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    Text(activeTab.encoding.displayName)
                        .font(.system(size: LayoutMetrics.bodySmallFontSize))
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(activeTab.isDirty)
                .accessibilityIdentifier(AccessibilityID.encodingMenu)

                // File size indicator (cached in EditorTab)
                if let size = activeTab.fileSizeBytes {
                    statusDivider

                    Text(verbatim: FileSizeFormatter.format(size))
                        .font(.system(size: LayoutMetrics.bodySmallFontSize))
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier(AccessibilityID.fileSizeIndicator)
                }
            }

            // Кнопка показа/скрытия терминала
            Button {
                withAnimation { terminal.isTerminalVisible.toggle() }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: terminal.isTerminalVisible
                          ? "chevron.down" : "chevron.up")
                        .font(.system(size: LayoutMetrics.iconSmallFontSize, weight: .semibold))
                    Image(systemName: "terminal")
                        .font(.system(size: LayoutMetrics.captionFontSize))
                    Text(Strings.terminalLabel)
                        .font(.system(size: LayoutMetrics.bodySmallFontSize))
                }
                .foregroundStyle(terminal.isTerminalVisible ? .primary : .secondary)
            }
            .buttonStyle(.plain)
            .help(terminal.isTerminalVisible ? Strings.hideTerminalShortcut : Strings.showTerminalShortcut)
            .accessibilityIdentifier(AccessibilityID.terminalToggleButton)
            .accessibilityAddTraits(.isButton)
        }
        .padding(.horizontal, LayoutMetrics.statusBarHorizontalPadding)
        .frame(height: LayoutMetrics.statusBarHeight)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.statusBar)
    }

    private var statusDivider: some View {
        Text(verbatim: "·")
            .font(.system(size: LayoutMetrics.bodySmallFontSize))
            .foregroundStyle(.quaternary)
    }

    private var gitStatusCounts: (modified: Int, added: Int, untracked: Int) {
        var m = 0, a = 0, u = 0
        for (_, status) in gitProvider.fileStatuses {
            switch status {
            case .modified, .mixed: m += 1
            case .staged, .added:   a += 1
            case .untracked:        u += 1
            default: break
            }
        }
        return (m, a, u)
    }
}

#Preview {
    let projectManager = ProjectManager()
    let registry = ProjectRegistry()
    ContentView()
        .environment(projectManager)
        .environment(projectManager.workspace)
        .environment(projectManager.terminal)
        .environment(projectManager.tabManager)
        .environment(registry)
}
