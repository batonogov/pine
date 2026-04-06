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
            let previewModes = session.existingPreviewModes
            let editorStates = session.existingEditorStates
            let pinnedSet = session.existingPinnedPaths

            // Try to restore pane layout if available
            if let layoutData = session.paneLayoutData,
               let restoredNode = try? JSONDecoder().decode(PaneNode.self, from: layoutData),
               let assignments = session.paneTabAssignments,
               restoredNode.leafCount > 1 {
                let activePaneUUID = session.activePaneID.flatMap { UUID(uuidString: $0) }
                paneManager.restoreLayout(from: restoredNode, activePaneUUID: activePaneUUID)

                // Populate tabs into each pane's TabManager
                for (paneID, tm) in paneManager.tabManagers {
                    guard let paths = assignments[paneID.id.uuidString] else { continue }
                    for path in paths {
                        let url = URL(fileURLWithPath: path)
                        guard FileManager.default.fileExists(atPath: path) else { continue }
                        let disabled = disabledSet.contains(path)
                        tm.openTab(url: url, syntaxHighlightingDisabled: disabled)
                    }
                    Self.applyTabState(to: tm, previewModes: previewModes,
                                       editorStates: editorStates, pinnedPaths: pinnedSet)
                }
            } else {
                // Single-pane restore (backwards compatible)
                for url in session.existingFileURLs {
                    let disabled = disabledSet.contains(url.path)
                    tabManager.openTab(url: url, syntaxHighlightingDisabled: disabled)
                }
                Self.applyTabState(to: tabManager, previewModes: previewModes,
                                   editorStates: editorStates, pinnedPaths: pinnedSet)
            }

            if let activeURL = session.activeFileURL,
               let tab = tabManager.tab(for: activeURL) {
                tabManager.activeTabID = tab.id
            }

            // Collapse any restored editor leaves that ended up with no tabs
            // (e.g., persisted empty placeholders next to terminal panes).
            paneManager.pruneEmptyEditorLeaves()

            didRestoreTabs = !projectManager.allTabs.isEmpty
        }

        // Restore terminal tabs for terminal pane leaves
        if let tpCounts = session.terminalPaneTabCounts {
            for (paneIDStr, count) in tpCounts {
                guard let uuid = UUID(uuidString: paneIDStr),
                      let paneID = paneManager.root.leafIDs.first(where: { $0.id == uuid }),
                      let state = paneManager.terminalState(for: paneID) else { continue }
                // State was created with no tabs by restoreLayout; add the saved count
                let needed = max(0, count - state.tabCount)
                for _ in 0..<needed {
                    state.addTab(workingDirectory: rootURL)
                }
                if let activeIndices = session.terminalPaneActiveIndices,
                   let activeIdx = activeIndices[paneIDStr],
                   activeIdx < state.terminalTabs.count {
                    state.activeTerminalID = state.terminalTabs[activeIdx].id
                }
            }
        }

        // Legacy: migrate old single-terminal sessions to pane-based
        if session.terminalPaneTabCounts == nil,
           let visible = session.isTerminalVisible, visible,
           let count = session.terminalTabCount, count >= 1 {
            // Create a terminal pane with the right number of tabs
            terminal.createTerminalTab(
                relativeTo: paneManager.activePaneID,
                workingDirectory: rootURL
            )
            if count > 1, let tpID = terminal.lastActiveTerminalPaneID,
               let state = paneManager.terminalState(for: tpID) {
                for _ in 1..<count {
                    state.addTab(workingDirectory: rootURL)
                }
                if let activeIdx = session.activeTerminalIndex,
                   activeIdx < state.terminalTabs.count {
                    state.activeTerminalID = state.terminalTabs[activeIdx].id
                }
            }
        }

        return didRestoreTabs
    }

    /// Applies preview modes, editor states, and pinned status to a TabManager's tabs.
    private static func applyTabState(
        to tm: TabManager,
        previewModes: [String: String]?,
        editorStates: [String: PerTabEditorState]?,
        pinnedPaths: Set<String>?
    ) {
        for index in tm.tabs.indices {
            let path = tm.tabs[index].url.path
            if let rawMode = previewModes?[path],
               let mode = MarkdownPreviewMode(rawValue: rawMode) {
                tm.tabs[index].previewMode = mode
            }
            if let state = editorStates?[path] {
                state.apply(to: &tm.tabs[index])
            }
            if pinnedPaths?.contains(path) == true {
                tm.tabs[index].isPinned = true
            }
        }
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
        // Use the active editor pane's TabManager so files open in the
        // visible editor pane, even when focus is on a terminal pane.
        let tm = paneManager.activeEditorTabManager ?? tabManager
        tm.openTab(url: node.url)
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

// MARK: - Git blame & diff (stubs)

extension ContentView {

    /// No-op — each PaneLeafView manages its own blame data.
    /// Kept as a stub because GitAndNotificationObserver calls it.
    func refreshBlame() {}

    /// No-op — each PaneLeafView manages its own line diffs.
    /// Kept as a stub because GitAndNotificationObserver calls it.
    func refreshLineDiffs() {}
}

// MARK: - Git change navigation & inline diff

extension ContentView {

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

    func closeOtherTabsWithConfirmation(keeping tabID: UUID) {
        TabCloseHelper.closeOtherTabs(keeping: tabID, in: tabManager, gitProvider: workspace.gitProvider)
    }

    func closeTabsToTheRightWithConfirmation(of tabID: UUID) {
        TabCloseHelper.closeTabsToTheRight(of: tabID, in: tabManager, gitProvider: workspace.gitProvider)
    }

    func closeAllTabsWithConfirmation() {
        TabCloseHelper.closeAllTabs(in: tabManager, gitProvider: workspace.gitProvider)
    }

    func closeTabWithConfirmation(_ tab: EditorTab) {
        TabCloseHelper.closeTab(tab, in: tabManager, gitProvider: workspace.gitProvider)
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
    /// If no terminal pane exists, creates one. Focuses the terminal pane.
    func sendTextToTerminal(_ text: String) {
        // Ensure there is a terminal pane
        if paneManager.terminalPaneIDs.isEmpty {
            projectManager.addTerminalTab()
        }

        // Find the active terminal pane's state
        guard let tpID = terminal.lastActiveTerminalPaneID ?? paneManager.terminalPaneIDs.first,
              let state = paneManager.terminalState(for: tpID),
              let activeTab = state.activeTab else { return }

        // Send text followed by newline to execute
        activeTab.sendText(text + "\n")
    }
}
