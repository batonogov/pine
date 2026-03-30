//
//  ContentView+Helpers.swift
//  Pine
//
//  Created by Федор Батоногов on 09.03.2026.
//

import SwiftUI

// MARK: - Session restoration & crash recovery

extension ContentView {

    /// Restores editor tabs, terminal state, and pinned state from the saved session.
    /// Returns `true` when editor tabs were actually restored (used by callers to
    /// trigger git diff / blame refresh that depends on an active tab existing).
    @discardableResult
    func restoreSessionIfNeeded() -> Bool {
        guard !didRestoreSession else { return false }
        didRestoreSession = true

        guard let rootURL = workspace.rootURL else {
            didRestoreSession = false // Allow retry when rootURL becomes available
            return false
        }

        guard let session = SessionState.load(for: rootURL) else { return false }

        var didRestoreTabs = false

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

            didRestoreTabs = !tabManager.tabs.isEmpty
        }

        // Restore terminal state
        if let visible = session.isTerminalVisible {
            terminal.isTerminalVisible = visible
        }
        if let maximized = session.isTerminalMaximized {
            terminal.isTerminalMaximized = maximized
        }

        // Create terminal tabs only if PM has a single default (unused) tab
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

        return didRestoreTabs
    }

    func checkForRecovery() {
        guard let entries = projectManager.recoveryManager?.pendingRecoveryEntries(),
              !entries.isEmpty else { return }
        recoveryEntries = entries
        showRecoveryDialog = true
    }

    func recoverTabs() {
        for (_, entry) in recoveryEntries {
            guard !entry.originalPath.isEmpty else { continue }

            let url = URL(fileURLWithPath: entry.originalPath)
            tabManager.openTab(url: url)

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

    func discardRecovery() {
        projectManager.recoveryManager?.deleteAllRecoveryFiles()
        showRecoveryDialog = false
        recoveryEntries = []
    }

    /// Reads `PINE_SEARCH_QUERY` from the environment (used by UI tests) and
    /// applies it to the search provider, activating the search UI.
    func applySearchQueryFromEnvironment() {
        guard let query = ProcessInfo.processInfo.environment["PINE_SEARCH_QUERY"],
              !query.isEmpty,
              let rootURL = workspace.rootURL else { return }
        projectManager.searchProvider.query = query
        isSearchPresented = true
        projectManager.searchProvider.search(in: rootURL)
    }
}

// MARK: - File management & sidebar sync

extension ContentView {

    func openNewProject() {
        guard let url = registry.openProjectViaPanel() else { return }
        openWindow(value: url)
    }

    func handleFileSelection(_ node: FileNode) {
        tabManager.openTab(url: node.url)
    }

    /// Syncs sidebar selection to match the active editor tab.
    func syncSidebarSelection() {
        guard let url = tabManager.activeTab?.url else {
            selectedNode = nil
            return
        }
        if selectedNode?.url == url { return }
        selectedNode = findNode(url: url, in: workspace.rootNodes)
    }

    /// Recursively searches the file tree for a node with the given URL.
    func findNode(url: URL, in nodes: [FileNode]) -> FileNode? {
        for node in nodes {
            if node.url == url { return node }
            if let children = node.children,
               let found = findNode(url: url, in: children) {
                return found
            }
        }
        return nil
    }
}

// MARK: - Git blame & diff

extension ContentView {

    /// Refreshes cached blame data for the active tab.
    func refreshBlame() {
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

    /// Refreshes cached line diffs and diff hunks for the active tab.
    func refreshLineDiffs() {
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

    /// Used by GitAndNotificationObserver — internal visibility required for cross-struct access.
    enum ChangeDirection { case next, previous }

    func navigateToChange(direction: ChangeDirection) {
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

    // MARK: - Gutter accept/revert buttons

    func handleGutterAccept(_ hunk: DiffHunk) {
        guard let tab = tabManager.activeTab,
              let repoURL = workspace.rootURL else { return }
        Task {
            await InlineDiffProvider.acceptHunk(hunk, fileURL: tab.url, repoURL: repoURL)
            await workspace.gitProvider.refreshAsync()
            refreshLineDiffs()
        }
    }

    func handleGutterRevert(_ hunk: DiffHunk) {
        guard let tab = tabManager.activeTab,
              let repoURL = workspace.rootURL else { return }
        Task {
            if let newContent = await InlineDiffProvider.revertHunk(hunk, fileURL: tab.url, repoURL: repoURL) {
                tabManager.updateContent(newContent)
                tabManager.reloadTab(url: tab.url)
                await workspace.gitProvider.refreshAsync()
                refreshLineDiffs()
            }
        }
    }

    // MARK: - Inline diff actions (menu/keyboard)

    func handleInlineDiffAction(_ action: InlineDiffAction) {
        guard let tab = tabManager.activeTab,
              let repoURL = workspace.rootURL,
              workspace.gitProvider.isGitRepository else { return }

        let fileURL = tab.url

        switch action {
        case .accept:
            Task {
                let hunks = await InlineDiffProvider.fetchHunks(for: fileURL, repoURL: repoURL)
                let currentLine = Self.lineNumber(forOffset: tab.cursorPosition, in: tab.content)
                guard let hunk = InlineDiffProvider.hunk(atLine: currentLine, in: hunks) else { return }
                await InlineDiffProvider.acceptHunk(hunk, fileURL: fileURL, repoURL: repoURL)
                await workspace.gitProvider.refreshAsync()
                refreshLineDiffs()
            }
        case .revert:
            Task {
                let hunks = await InlineDiffProvider.fetchHunks(for: fileURL, repoURL: repoURL)
                let currentLine = Self.lineNumber(forOffset: tab.cursorPosition, in: tab.content)
                guard let hunk = InlineDiffProvider.hunk(atLine: currentLine, in: hunks) else { return }
                if let newContent = await InlineDiffProvider.revertHunk(hunk, fileURL: fileURL, repoURL: repoURL) {
                    tabManager.updateContent(newContent)
                    tabManager.reloadTab(url: fileURL)
                    await workspace.gitProvider.refreshAsync()
                    refreshLineDiffs()
                }
            }
        case .acceptAll:
            Task {
                await InlineDiffProvider.acceptAllHunks(fileURL: fileURL, repoURL: repoURL)
                await workspace.gitProvider.refreshAsync()
                refreshLineDiffs()
            }
        case .revertAll:
            Self.confirmRevertAll(fileName: fileURL.lastPathComponent) { confirmed in
                guard confirmed else { return }
                Task {
                    if let newContent = await InlineDiffProvider.revertAllHunks(
                        fileURL: fileURL, repoURL: repoURL
                    ) {
                        self.tabManager.updateContent(newContent)
                        self.tabManager.reloadTab(url: fileURL)
                        await self.workspace.gitProvider.refreshAsync()
                        self.refreshLineDiffs()
                    }
                }
            }
        }
    }

    /// Shows a confirmation dialog before reverting all changes in a file.
    static func confirmRevertAll(fileName: String, completion: @escaping (Bool) -> Void) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Revert All Changes?"
            alert.informativeText = "All changes in \"\(fileName)\" will be permanently lost. This action cannot be undone."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Revert All")
            alert.addButton(withTitle: "Cancel")
            let response = alert.runModal()
            completion(response == .alertFirstButtonReturn)
        }
    }
}

// MARK: - Tab close & deletion handling

extension ContentView {

    /// Shows a confirmation dialog for bulk close operations when there are dirty tabs.
    /// Returns `true` if the operation should proceed (user chose Save All or Don't Save),
    /// `false` if cancelled. When the user chooses Save All, all dirty tabs are saved first.
    private func confirmBulkClose(dirtyTabs: [EditorTab]) -> Bool {
        guard !dirtyTabs.isEmpty else { return true }

        let fileList = dirtyTabs.map { "  \u{2022} \($0.fileName)" }.joined(separator: "\n")
        let alert = NSAlert()
        alert.messageText = Strings.unsavedChangesTitle
        alert.informativeText = Strings.unsavedChangesListMessage(fileList)
        alert.addButton(withTitle: Strings.dialogSaveAll)
        alert.addButton(withTitle: Strings.dialogDontSave)
        alert.addButton(withTitle: Strings.dialogCancel)
        alert.alertStyle = .warning

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            // Save all dirty tabs; abort if any save fails
            for tab in dirtyTabs {
                guard let index = tabManager.tabs.firstIndex(where: { $0.id == tab.id }) else { continue }
                guard tabManager.saveTab(at: index) else { return false }
            }
            Task { await workspace.gitProvider.refreshAsync() }
            return true
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    /// Closes all tabs except the one with the given ID, with unsaved-changes protection.
    func closeOtherTabsWithConfirmation(keeping tabID: UUID) {
        let dirty = tabManager.dirtyTabsForCloseOthers(keeping: tabID)
        guard confirmBulkClose(dirtyTabs: dirty) else { return }
        tabManager.closeOtherTabs(keeping: tabID, force: true)
    }

    /// Closes all tabs to the right of the given tab, with unsaved-changes protection.
    func closeTabsToTheRightWithConfirmation(of tabID: UUID) {
        let dirty = tabManager.dirtyTabsForCloseRight(of: tabID)
        guard confirmBulkClose(dirtyTabs: dirty) else { return }
        tabManager.closeTabsToTheRight(of: tabID, force: true)
    }

    /// Closes all tabs with unsaved-changes protection.
    func closeAllTabsWithConfirmation() {
        let dirty = tabManager.dirtyTabsForCloseAll()
        guard confirmBulkClose(dirtyTabs: dirty) else { return }
        tabManager.closeAllTabs(force: true)
    }

    /// Closes a tab with unsaved-changes protection.
    func closeTabWithConfirmation(_ tab: EditorTab) {
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

    func handleExternalChanges(_ result: TabManager.ExternalChangeResult) {
        // Show toast for silently reloaded files
        if !result.reloadedFileNames.isEmpty {
            projectManager.toastManager.showFilesReloaded(result.reloadedFileNames)
        }

        let modified = result.conflicts.filter { $0.kind == .modified }
        let deleted = result.conflicts.filter { $0.kind == .deleted }

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

        for conflict in deleted {
            handleFileDeletion(conflict.url)
        }
    }

    func handleFileDeletion(_ deletedURL: URL) {
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
                break
            default:
                return
            }
        }

        tabManager.closeTabsForDeletedFile(url: deletedURL)
    }
}

// MARK: - Line / offset helpers

extension ContentView {

    var totalLineCount: Int {
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
            if lineEnd == clamped && (clamped == 0 || nsContent.character(at: clamped - 1) != ASCII.newline) {
                break
            }
            line += 1
            pos = lineEnd
        }
        return line
    }

    // MARK: - Send to Terminal (issue #311)

    /// Sends text to the active terminal tab.
    /// If the terminal is hidden, shows it first. If no terminal tabs exist, creates one.
    func sendTextToTerminal(_ text: String) {
        // Ensure terminal is visible
        if !terminal.isTerminalVisible {
            terminal.isTerminalVisible = true
        }

        // Ensure there is an active terminal tab
        if terminal.activeTerminalTab == nil {
            projectManager.addTerminalTab()
        }

        // Send text followed by newline to execute
        guard let activeTab = terminal.activeTerminalTab else { return }
        activeTab.sendText(text + "\n")
    }
}
