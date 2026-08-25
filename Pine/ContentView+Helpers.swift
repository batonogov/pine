//
//  ContentView+Helpers.swift
//  Pine
//
//  Created by Федор Батоногов on 09.03.2026.
//

import SwiftUI

// MARK: - Session restoration & crash recovery

extension ContentView {

    /// Attempts session restoration for the current project root.
    ///
    /// Returns an explicit ``SessionStartupDisposition`` so the caller can
    /// decide whether to seed the workspace with a focused terminal (#1251).
    /// A project that has no saved session *and* no recovery entries should
    /// open directly into a terminal instead of an empty editor canvas;
    /// projects with a saved session restore normally and must not have a
    /// terminal injected.
    ///
    /// Idempotent via the `didRestoreSession` guard except for the `deferred`
    /// case, which clears the guard so restoration is retried once the
    /// project root becomes available.
    @discardableResult
    func restoreSessionIfNeeded() -> SessionStartupDisposition {
        guard !didRestoreSession else { return .skipped }
        didRestoreSession = true

        guard let rootURL = workspace.rootURL else {
            // Allow retry when rootURL becomes available. The `deferred`
            // disposition tells the caller that no content should be seeded
            // yet — the workspace is not ready.
            didRestoreSession = false
            return .deferred
        }

        // A partially populated pane tree must never be overlaid with a saved
        // session. This can occur when a delayed file-tree callback races with
        // an explicit open during launch, or when an extension/open-file path
        // already created content. Seeding a terminal here would replace that
        // real content, so report `skipped`.
        guard projectManager.allTabs.isEmpty,
              projectManager.allTerminalTabs.isEmpty else { return .skipped }

        guard let session = SessionState.load(
            for: rootURL,
            defaults: projectManager.sessionDefaults
        ) else {
            // No persisted session for this root — candidate for terminal
            // seeding (subject to recovery discovery in the caller).
            return .noSavedSession
        }

        let result = ProjectSessionRestorer.restore(
            session,
            into: projectManager,
            rootURL: rootURL
        )

        // Boot agent detection if any terminal panes were restored. The
        // primary restore path (terminalPaneTabCounts) creates tabs via
        // `state.addTab` directly, bypassing `createTerminalTab`, so the
        // coordinator would never start for restored sessions — detection must
        // be booted explicitly here (vision #933, #951). Idempotent: a no-op
        // if already started (e.g. the legacy path above called
        // `createTerminalTab`).
        if result.restoredTerminalPanes {
            terminal.ensureAgentDetectionStarted()
        }

        return .restored(result)
    }

    /// Discovers the crash-recovery offer for this project and presents it.
    ///
    /// `async` and awaited by the caller rather than launched into a detached
    /// `Task`: `seedInitialTerminalIfNeeded(disposition:)` runs straight after
    /// it and its guard reads exactly the two properties this sets. Ordered
    /// explicitly so a pending offer can never lose the race and have a
    /// terminal seeded over the empty editor leaf the user is about to recover
    /// into — `theTaskAwaitsRecoveryDiscoveryBeforeSeeding` pins the sequence
    /// in `ContentView`'s `.task`.
    func checkForRecovery() async {
        // `pendingRecoveryOffer()` and not `pendingRecoveryEntries()`: SwiftUI
        // re-runs this `.task` on scene restoration and when the window is
        // closed and reopened, and the snapshots are deliberately still on
        // disk after "Later". Asking the project, which outlives the window,
        // is what keeps "not now" from meaning "again in ten seconds" (#1503).
        // It suspends: the directory listing reads and decodes every snapshot,
        // and those are whole unsaved buffers with no size limit, so it must
        // not happen on the main thread before the window draws.
        let entries = await projectManager.pendingRecoveryOffer()
        guard !entries.isEmpty else { return }
        recoveryEntries = entries
        recoveryRestoreFailed = false
        showRecoveryDialog = true
    }

    /// Seeds the workspace with a focused terminal when a project opens with
    /// no saved session and no pending crash-recovery entries (#1251).
    ///
    /// Replaces the untouched initial empty editor leaf with a terminal leaf
    /// that fills the workspace. The terminal is created through the normal
    /// `PaneManager`/`TerminalPaneState` ownership path (`addTerminalTab` →
    /// `createTerminalTab` → `createTerminalPaneAtBottom` + `pruneEmptyEditorLeaves`),
    /// so agent detection starts through the same coordinator path as a
    /// manually created terminal and the shell is rooted in the project
    /// directory via current `ShellSettings`.
    ///
    /// Guards:
    ///   - Only seeds on `.noSavedSession`. `restored`, `skipped`, and
    ///     `deferred` never inject a terminal.
    ///   - A pending recovery dialog means the user may restore real editor
    ///     content — do not replace the empty leaf until they decide. Since
    ///     ``checkForRecovery()`` suspends, this guard is only meaningful
    ///     because the caller `await`s it first; see the note there.
    ///   - Defends against the empty editor leaf having been touched between
    ///     the restore attempt and this call (e.g. a rapid sidebar click).
    func seedInitialTerminalIfNeeded(disposition: SessionStartupDisposition) {
        guard case .noSavedSession = disposition else { return }
        // UI tests pass `--disable-terminal-seeding` to preserve the legacy
        // empty-editor behavior they were written against.
        guard !CommandLine.arguments.contains("--disable-terminal-seeding") else { return }
        // If recovery entries were discovered, the recovery dialog will be
        // presented; let the user recover into the existing editor leaf.
        guard !showRecoveryDialog, recoveryEntries.isEmpty else { return }
        // Re-check the pane tree: if real content appeared between the restore
        // attempt and now, the empty-leaf precondition no longer holds.
        guard projectManager.allTabs.isEmpty,
              projectManager.allTerminalTabs.isEmpty else { return }
        guard workspace.rootURL != nil else { return }
        // The sole editor leaf must be empty and untouched — this is the only
        // leaf we are allowed to replace. `addTerminalTab` routes through the
        // normal `PaneManager`/`TerminalPaneState` ownership path
        // (`createTerminalTab` → `createTerminalPaneAtBottom` +
        // `pruneEmptyEditorLeaves`), which collapses the redundant empty
        // editor and leaves the terminal as the root leaf filling the
        // workspace. Agent detection is booted on the same path
        // (`ensureAgentDetectionStarted` inside `createTerminalTab`) and the
        // shell is rooted in the project directory via current `ShellSettings`.
        // `addTab` sets `pendingFocusTabID`, so the bounded AppKit focus
        // coordinator requests first-responder once the terminal view attaches.
        // `ProjectManager.addTerminalTab` also performs canonical terminal
        // activation, so no pane-local focus repair is needed here.
        projectManager.addTerminalTab()
    }

    func recoverTabs() {
        // Recover into the focused editor pane (issue #971): the user is
        // looking at the active pane, so recovered tabs should appear there,
        // not in the possibly-orphaned primary TabManager.
        guard let recoveryManager = projectManager.recoveryManager else {
            return
        }
        let target = activeTabManager
        let entries = recoveryEntries
        let context = DialogPresenter.forProject(projectManager)

        // Dismiss the SwiftUI recovery sheet before presenting a native
        // large-file sheet on the same window. The restorer keeps cancelled
        // snapshots on disk, so closing this list cannot lose their content.
        showRecoveryDialog = false
        recoveryEntries = []

        // The restore is in flight from here until the `defer` below, and
        // `pendingRecoveryOffer()` is empty for as long as it is.
        //
        // Without that, `restorePendingEntries` parking on a large-file sheet
        // is a window in which a second sheet can be built from the same crash
        // entries: SwiftUI re-runs the scene's `.task` on restoration and on
        // close/reopen, `didAnswerRecoveryOffer` is deliberately still false
        // (a restore that never finishes must not silence the offer for good),
        // and both snapshots are still on disk under IDs no open tab owns. A
        // second Recover All then migrates them again — writing a snapshot
        // under a runtime ID no window owns, which comes back on the next
        // launch as a phantom "recovered file" — and leaves the parked restore
        // to resume against a detached `TabManager`.
        //
        // The flag and not `markRecoveryOfferAnswered()`, because they are
        // different claims: this says "being handled", that says "decided".
        // The two come apart exactly when the restorer hands entries back.
        //
        // No `Task.isCancelled` check: this is an unstructured task, which
        // inherits no cancellation, and its handle is discarded — nothing in
        // the app can cancel it, so the guard that used to sit after the
        // `await` could never fire and only made it look as though ⌘W were
        // being handled here. (It is not reachable in the first place: with
        // the sheet up, `documentWindow(for: NSApp.keyWindow)` resolves to the
        // sheet, whose delegate is not a `CloseDelegate`.)
        projectManager.beginRecoveryRestore()
        Task { @MainActor in
            defer { projectManager.endRecoveryRestore() }
            let retained = await recoveryManager.restorePendingEntries(
                entries,
                in: target,
                context: context
            )
            // Answered once the restore has actually finished, not before the
            // `await`. A successful restore leaves live snapshots under the
            // recovered tabs' runtime IDs, and re-running `checkForRecovery()`
            // after a scene restart would otherwise offer the user their own
            // open buffers back as "recovered" (#1503). Anything the restorer
            // hands back stays on disk for the next launch either way.
            projectManager.markRecoveryOfferAnswered()
            recoveryEntries = retained
            // These are the entries the restorer refused, so the sheet that
            // comes back must say so rather than repeat "Pine found unsaved
            // changes from a previous session" (#1541).
            recoveryRestoreFailed = !retained.isEmpty
            showRecoveryDialog = !retained.isEmpty
        }
    }

    /// Applies the user's answer to the crash-recovery offer.
    ///
    /// The single place in the app that can delete a displayed snapshot, and
    /// it holds no opinion about which answers delete: it asks the chosen
    /// option what it is allowed to unlink and passes that through.
    /// ``RecoveryDialogChoice/snapshotsToDelete(from:)`` answers with the
    /// empty list for everything but Discard, and it is the same value that
    /// decides the button's role and denies it a keyboard equivalent, so the
    /// three cannot drift apart. Written as an `if` here it would be one
    /// plausible "the guard above already handled the other case" edit away
    /// from #1503 — in a file the coverage gate excludes and no unit test
    /// loads.
    ///
    /// Escape and ⌘-. resolve to ``RecoveryDialogChoice/later``, which unlinks
    /// nothing: the clean-quit sweep only removes snapshots belonging to open
    /// tabs (``RecoveryManager/deleteSnapshotsOfOpenTabs(_:)``), and these
    /// belong to none, so they stay on disk and the offer returns on the next
    /// launch (#1503).
    ///
    /// Exhaustive and without a `default`, so a fourth choice is a compile
    /// error here rather than a silent "close the sheet and delete nothing".
    func resolveRecoveryOffer(_ choice: RecoveryDialogChoice) {
        switch choice {
        case .recoverAll:
            recoverTabs()
        case .discard, .later:
            projectManager.recoveryManager?.deleteSnapshots(
                withRecoveryIDs: choice.snapshotsToDelete(from: recoveryEntries)
            )
            projectManager.markRecoveryOfferAnswered()
            showRecoveryDialog = false
            recoveryEntries = []
            recoveryRestoreFailed = false
        }
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

    #if DEBUG
    /// Seeds one deterministic dirty buffer for focused accessibility tests.
    /// XCUITest cannot insert text into `GutterTextView`, so the fixture
    /// supplies content after the test itself opens the target file. Production
    /// and ordinary test launches cannot activate this path.
    func seedAccessibilityDirtyBufferIfNeeded() {
        let arguments = ProcessInfo.processInfo.arguments
        let environment = ProcessInfo.processInfo.environment
        guard !didSeedAccessibilityDirtyBuffer,
              arguments.contains("--ui-test-a11y-dirty-buffer"),
              let targetName = environment["PINE_UI_TEST_DIRTY_FILE"],
              let marker = environment["PINE_UI_TEST_DIRTY_MARKER"],
              marker.isEmpty == false,
              let activeTab = activeTabManager.activeTab,
              activeTab.fileName == targetName else { return }

        activeTabManager.updateContent(activeTab.content + marker)
        didSeedAccessibilityDirtyBuffer = true
    }
    #endif
}

// MARK: - File management & sidebar sync

extension ContentView {

    func openNewProject() {
        Task { @MainActor in
            guard let url = await registry.chooseProjectViaPanel(for: projectManager) else { return }
            await projectWindowSession.openProject(url, registry: registry)
        }
    }

    func handleFileSelection(
        _ node: FileNode,
        disposition: SidebarFileOpenDisposition
    ) {
        paneManager.openFileInActiveEditor(
            url: node.url,
            asTransientPreview: disposition == .transientPreview,
            requestFocus: disposition.requestsEditorFocus
        )
    }

    /// Opens a file from the Agent Activity Panel (#1072).
    func openFileFromActivity(_ url: URL) {
        paneManager.openFileInActiveEditor(url: url)
    }

    /// Syncs sidebar selection to match the active editor tab.
    func syncSidebarSelection() {
        guard let url = activeTabManager.activeTab?.fileURL else {
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
    enum ChangeDirection: Equatable, Sendable { case next, previous }

    /// Navigates to the next/previous git change region in the **active**
    /// editor pane. Fetches fresh diffs for the active tab so it does not
    /// depend on root `lineDiffs` state (which is never populated — see
    /// issue #971: the previous implementation read root state and so never
    /// moved the cursor). Routes the resulting line through
    /// `activeTabManager.pendingGoToLine` so the focused `PaneLeafView`
    /// performs the actual scroll/cursor update.
    func navigateToChange(direction: ChangeDirection) {
        guard let tab = activeTabManager.activeTab,
              let fileURL = tab.fileURL else {
            return
        }
        let provider = workspace.gitProvider
        guard provider.isGitRepository else { return }
        let activeTM = activeTabManager
        Task { @MainActor in
            let diffs = await provider.diffForFileAsync(at: fileURL)
            guard !diffs.isEmpty,
                  let currentTab = activeTM.activeTab,
                  currentTab.url == fileURL else { return }
            let currentLine = Self.lineNumber(forOffset: currentTab.cursorPosition, in: currentTab.content)
            let starts = GitLineDiff.changeRegionStarts(diffs)
            let targetLine: Int?
            switch direction {
            case .next:
                targetLine = GitLineDiff.nextChangeLine(from: currentLine, regionStarts: starts, diffs: diffs)
            case .previous:
                targetLine = GitLineDiff.previousChangeLine(from: currentLine, regionStarts: starts, diffs: diffs)
            }
            if let line = targetLine {
                activeTM.pendingGoToLine = line
            }
        }
    }

    // MARK: - Inline diff actions (menu/keyboard)

    /// Handles inline-diff menu/keyboard actions against the **active**
    /// editor pane (issue #971): accept / revert / accept-all / revert-all
    /// operate on the focused pane's active tab, never the primary
    /// TabManager's tab.
    func handleInlineDiffAction(_ action: InlineDiffAction) {
        guard let tab = activeTabManager.activeTab,
              let fileURL = tab.fileURL,
              let repoURL = workspace.rootURL,
              workspace.gitProvider.isGitRepository else { return }
        let activeTM = activeTabManager

        switch action {
        case .accept:
            Task {
                let hunks = await InlineDiffProvider.fetchHunks(for: fileURL, repoURL: repoURL)
                guard let currentTab = activeTM.activeTab,
                      currentTab.url == fileURL else { return }
                let currentLine = Self.lineNumber(forOffset: currentTab.cursorPosition, in: currentTab.content)
                guard let hunk = InlineDiffProvider.hunk(atLine: currentLine, in: hunks) else { return }
                await InlineDiffProvider.acceptHunk(hunk, fileURL: fileURL, repoURL: repoURL)
                await workspace.gitProvider.refreshAsync()
            }
        case .revert:
            Task {
                let hunks = await InlineDiffProvider.fetchHunks(for: fileURL, repoURL: repoURL)
                guard let currentTab = activeTM.activeTab,
                      currentTab.url == fileURL else { return }
                let currentLine = Self.lineNumber(forOffset: currentTab.cursorPosition, in: currentTab.content)
                guard let hunk = InlineDiffProvider.hunk(atLine: currentLine, in: hunks) else { return }
                if let newContent = await InlineDiffProvider.revertHunk(hunk, fileURL: fileURL, repoURL: repoURL) {
                    activeTM.updateContent(newContent)
                    activeTM.reloadTab(url: fileURL)
                    await workspace.gitProvider.refreshAsync()
                }
            }
        case .acceptAll:
            Task {
                await InlineDiffProvider.acceptAllHunks(fileURL: fileURL, repoURL: repoURL)
                await workspace.gitProvider.refreshAsync()
            }
        case .revertAll:
            let confirmedTabID = tab.id
            let confirmedContent = tab.content
            confirmRevertAll(fileName: fileURL.lastPathComponent) { confirmed in
                guard confirmed else { return }
                guard let currentTab = activeTM.activeTab,
                      currentTab.id == confirmedTabID,
                      currentTab.content == confirmedContent else {
                    return
                }
                let contentAtRevertStart = currentTab.content
                Task {
                    if let newContent = await InlineDiffProvider.revertAllHunks(
                        fileURL: fileURL, repoURL: repoURL
                    ) {
                        guard let latestTab = activeTM.activeTab,
                              latestTab.id == confirmedTabID,
                              latestTab.content == contentAtRevertStart else {
                            return
                        }
                        activeTM.updateContent(newContent)
                        activeTM.reloadTab(url: fileURL)
                        await workspace.gitProvider.refreshAsync()
                    }
                }
            }
        }
    }

    /// Shows a confirmation dialog before reverting all changes in a file.
    /// Presented as a window-scoped sheet so it does not block other project
    /// windows (issue #1241).
    func confirmRevertAll(fileName: String, completion: @escaping (Bool) -> Void) {
        let context = DialogPresenter.forProject(projectManager)
        Task { @MainActor in
            let response = await AlertTemplate.revertAllConfirmation.runSheet(
                on: context,
                messageText: Strings.revertAllTitle,
                informativeText: Strings.revertAllMessage(fileName)
            )
            completion(response == .alertFirstButtonReturn)
        }
    }
}

// MARK: - Deletion handling

extension ContentView {

    func handleExternalChanges(_ result: TabManager.ExternalChangeResult) {
        // Show toast for silently reloaded files
        if !result.reloadedFileNames.isEmpty {
            projectManager.toastManager.showFilesReloaded(result.reloadedFileNames)
        }

        let modified = result.conflicts.filter { $0.kind == .modified }
        let deleted = result.conflicts.filter { $0.kind == .deleted }
        guard !modified.isEmpty || !deleted.isEmpty else { return }

        let context = DialogPresenter.forProject(projectManager)
        let projectManager = self.projectManager
        projectManager.enqueueDialogOperation { @MainActor [weak projectManager] in
            guard let projectManager else { return }
            let currentModified = modified.filter { conflict in
                projectManager.allTabs.contains {
                    $0.fileURL?.standardizedFileURL ==
                        conflict.url.standardizedFileURL
                        && $0.isDirty
                }
            }
            if !currentModified.isEmpty {
                let names = Array(
                    Set(currentModified.map(\.url.lastPathComponent))
                )
                    .sorted()
                    .joined(separator: ", ")
                let modifiedURLs = Set(
                    currentModified.map { $0.url.standardizedFileURL }
                )
                let displayedAffectedTabs = projectManager.allTabs.filter {
                    modifiedURLs.contains($0.url.standardizedFileURL)
                }
                let displayedAuthorization = DirtyEditorContentAuthorization(
                    tabs: displayedAffectedTabs
                )
                let response = await AlertTemplate.externalModifyConflict.runSheet(
                    on: context,
                    messageText: Strings.externalModifyTitle,
                    informativeText: Strings.externalModifyMessage(names)
                )

                if response == .alertFirstButtonReturn {
                    let currentDirtyTabs = projectManager.allTabs.filter {
                        modifiedURLs.contains($0.url.standardizedFileURL)
                            && $0.isDirty
                    }
                    if displayedAuthorization.covers(currentDirtyTabs) {
                        for conflict in currentModified {
                            projectManager.reloadTab(conflict: conflict)
                        }
                    }
                } else if response == .alertSecondButtonReturn {
                    let currentDirtyTabs = projectManager.allTabs.filter {
                        modifiedURLs.contains($0.url.standardizedFileURL)
                            && $0.isDirty
                    }
                    if displayedAuthorization.covers(currentDirtyTabs) {
                        for conflict in currentModified {
                            projectManager.authorizeExternalChange(conflict)
                        }
                    }
                }
            }

            // Preserve the old synchronous ordering: each deletion decision
            // completes before the next one computes its affected tabs.
            for conflict in deleted {
                await Self.resolveFileDeletion(
                    conflict.url,
                    projectManager: projectManager,
                    context: context
                )
            }
        }
    }

    func handleFileDeletion(_ deletedURL: URL) {
        let context = DialogPresenter.forProject(projectManager)
        let projectManager = self.projectManager
        projectManager.enqueueDialogOperation { @MainActor [weak projectManager] in
            guard let projectManager else { return }
            await Self.resolveFileDeletion(
                deletedURL,
                projectManager: projectManager,
                context: context
            )
        }
    }

    private static func resolveFileDeletion(
        _ deletedURL: URL,
        projectManager: ProjectManager,
        context: DialogPresentationContext
    ) async {
        let affected = projectManager.tabsAffectedByDeletion(url: deletedURL)
        guard !affected.isEmpty else { return }

        let dirtyTabs = affected.filter { $0.isDirty }
        guard !dirtyTabs.isEmpty else {
            projectManager.closeTabsForDeletedFile(url: deletedURL)
            return
        }
        let affectedTabIDs = Set(affected.map(\.id))
        let displayedDirtyContent = Dictionary(
            dirtyTabs.map { ($0.id, $0.content) },
            uniquingKeysWith: { _, latest in latest }
        )
        var savedContent: [UUID: String] = [:]

        let response = await AlertTemplate.fileDeletedSaveAs.runSheet(
            on: context,
            messageText: Strings.fileDeletedTitle,
            informativeText: Strings.fileDeletedMessage
        )
        switch response {
        case .alertFirstButtonReturn:
            let dirtyTabIDs = projectManager.allTabs
                .filter {
                    affectedTabIDs.contains($0.id) && $0.isDirty
                }
                .map(\.id)
            for tabID in dirtyTabIDs {
                guard let tab = projectManager.allTabs.first(where: {
                    $0.id == tabID
                }) else {
                    continue
                }
                let panel = NSSavePanel()
                panel.nameFieldStringValue = tab.fileName
                guard await panel.runSheet(on: context) == .OK,
                      let saveURL = panel.url else { return }
                guard let currentTab = projectManager.allTabs.first(where: {
                    $0.id == tabID
                }) else {
                    continue
                }
                do {
                    try currentTab.content.write(
                        to: saveURL,
                        atomically: true,
                        encoding: .utf8
                    )
                    savedContent[tabID] = currentTab.content
                } catch {
                    _ = await AlertTemplate.fileOperationErrorWarning.runSheet(
                        on: context,
                        messageText: Strings.fileOperationErrorTitle,
                        informativeText: error.localizedDescription
                    )
                    return
                }
            }
        case .alertSecondButtonReturn:
            savedContent = displayedDirtyContent
        default:
            return
        }
        let currentDirtyTabs = projectManager
            .tabsAffectedByDeletion(url: deletedURL)
            .filter(\.isDirty)
        guard currentDirtyTabs.allSatisfy({
            savedContent[$0.id] == $0.content
        }) else {
            return
        }
        projectManager.closeTabsForDeletedFile(url: deletedURL)
    }
}

// MARK: - Line / offset helpers

extension ContentView {

    /// A key scene is authoritative evidence that its retained project is
    /// visible. Reconcile a restoration race, then self-heal an empty settled
    /// tree whose initial load may have been cancelled just before activation.
    /// File → Close Project, and the switcher's own item.
    ///
    /// The last project in a window is a window close, not a project close:
    /// Pine has no state for an empty project window, and routing it through
    /// `performClose` keeps one dialog, one code path, and the existing
    /// "show Welcome when the last window goes" behaviour.
    func closeActiveProject() {
        let session = projectWindowSession
        let target = session.activeRepositoryURL
        let context = DialogPresenter.forProject(projectManager)
        guard session.canCloseProject(target) else {
            context.nsWindow?.performClose(nil)
            return
        }
        Task { @MainActor in
            let decision = await ProjectCloseConfirmation.confirm(
                projectManager: projectManager,
                context: context
            )
            guard case .approve(let discard) = decision else { return }
            if let discard,
               !projectManager.commitDiscard(
                   discard,
                   postReloadNotifications: false
               ) {
                return
            }
            // Re-check rather than trusting the pre-sheet answer: the window
            // may have lost its other projects while the sheet was up, and
            // closing the last one has to become a window close.
            guard session.canCloseProject(target) else {
                context.nsWindow?.performClose(nil)
                return
            }
            await session.closeProject(target, registry: registry)
        }
    }

    func reconcileKeyProjectPresentation() {
        let wasSuspended = workspace.isSuspended
        guard controlActiveState == .key else { return }
        // Becoming key is what makes this the window a user means by "here",
        // and it is the signal a project with no window of its own is routed
        // by. Record it whether or not the reconcile below finds work.
        registry.noteKeyWindowSession(projectWindowSession)
        guard registry.reconcileKeyProjectPresentation(projectManager) else {
            return
        }
        if !wasSuspended,
           workspace.rootURL != nil,
           workspace.rootNodesRevision == 0,
           workspace.rootNodes.isEmpty,
           !workspace.isLoading,
           !workspace.isSuspended {
            workspace.refreshFileTreeAsync()
        }
    }

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

        // Resolve and activate one validated destination. A stale non-nil
        // pointer must never suppress the stable surviving-pane fallback.
        guard let destination = terminal.activateResolvedDestination() else {
            return
        }
        let activeTab = destination.tab

        // A single known agent executable is an explicit Pine-owned launch.
        // Shell expressions and argument-bearing commands remain ordinary,
        // untrusted terminal input and are attributed only by observation.
        if let descriptor = TerminalManager.exactAgentLaunchDescriptor(for: text) {
            Task { @MainActor in
                _ = await terminal.launchAgentCommand(
                    text,
                    descriptor: descriptor,
                    in: activeTab
                )
            }
            return
        }

        // Send ordinary text followed by newline to execute.
        terminal.sendText(text + "\n", to: destination)
    }

    // MARK: - Menu notification handlers (#1051, #1133)

    /// Keeps the mutation deferred so synchronous menu-notification delivery
    /// cannot re-enter SwiftUI's `@AppStorage` access (#1051).
    func handleToggleWordWrap() {
        DispatchQueue.main.async {
            self.isWordWrapEnabled.toggle()
        }
    }

    /// Extracted from `body` to keep Xcode 27's SwiftUI type-checker within
    /// budget while preserving the existing next-runloop mutation (#1133).
    func handleRevealInSidebar(_ notification: Notification) {
        guard let url = Self.resolveRevealInSidebarURL(from: notification) else { return }
        DispatchQueue.main.async {
            if let node = self.findNode(url: url, in: self.workspace.rootNodes) {
                self.selectedNode = node
                self.columnVisibility = .all
            }
        }
    }

    /// Extracted from `body` without changing focus gating or the reentrancy
    /// defer required before mutating terminal state (#1051, #1133).
    func handleSendTextToTerminal(_ notification: Notification) {
        guard let text = Self.resolveTerminalText(
            from: notification,
            isKeyWindow: controlActiveState == .key
        ) else { return }
        DispatchQueue.main.async {
            self.sendTextToTerminal(text)
        }
    }

    static func resolveRevealInSidebarURL(from notification: Notification) -> URL? {
        notification.userInfo?["url"] as? URL
    }

    /// Whitespace-only text remains valid; the pre-#1133 observer rejected
    /// only the empty string.
    static func resolveTerminalText(
        from notification: Notification,
        isKeyWindow: Bool
    ) -> String? {
        guard isKeyWindow,
              let text = notification.userInfo?["text"] as? String,
              !text.isEmpty else { return nil }
        return text
    }

    // MARK: - Problems panel navigation (#1236)

    /// Navigates only when the diagnostic still belongs to this exact
    /// project/pane/tab/revision. This avoids opening a stale URI in whichever
    /// pane happens to be focused after the row was captured.
    @discardableResult
    func navigateToDiagnostic(
        _ diagnostic: ProblemsFlatDiagnostic
    ) -> Bool {
        projectManager.navigateToProblem(diagnostic)
    }
}

// MARK: - Agent Activity presenter (#1072)

/// Presents the Agent Activity Panel sheet in response to the
/// `showAgentActivity` notification. Encapsulating the `.sheet` + `.onReceive`
/// wiring in a `ViewModifier` keeps `ContentView.body` within the Swift
/// compiler's type-checking budget (an inline `.sheet`/`.onReceive` pair with
/// inline row projection and terminal-target resolution push the surrounding
/// view over the “unable to type-check in reasonable time” limit).
///
/// The notification handler defers the state mutation to the next runloop to
/// avoid the `.onReceive` reentrancy class from #1051.
struct AgentActivityPresenter: ViewModifier {
    @Binding var isPresented: Bool
    let projectManager: ProjectManager
    let store: AgentActivityStore
    let paneManager: PaneManager
    let terminalManager: TerminalManager
    let onSelect: (URL) -> Void
    @Environment(\.controlActiveState) private var controlActiveState

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $isPresented) {
                AgentActivityView(
                    rows: store.actions.map { action in
                        AgentActivityRow(
                            action,
                            terminalTarget:
                                AgentActivityTerminalTargetResolver.resolve(
                                    attribution: action.attribution,
                                    in: paneManager
                                )
                        )
                    },
                    onSelectFile: onSelect,
                    onClose: { isPresented = false },
                    onGoToTerminal: { target in
                        let didRoute = AgentActivityTerminalRouter.route(
                            to: target,
                            paneManager: paneManager,
                            terminalManager: terminalManager
                        )
                        if didRoute {
                            isPresented = false
                        }
                        return didRoute
                    }
                )
            }
            .onReceive(NotificationCenter.default.publisher(for: .showAgentActivity)) { notification in
                guard ContentView.shouldHandleTargetedCommand(
                    notificationObject: notification.object,
                    currentProject: projectManager,
                    isKeyWindow: controlActiveState == .key
                ) else { return }
                // Defer to break reentrancy (#1051).
                DispatchQueue.main.async {
                    isPresented = true
                }
            }
    }
}

// MARK: - Agent History presenter (#1073)

/// Presents the Agent History sheet in response to the `showAgentHistory`
/// notification. Encapsulating the `.sheet` + `.onReceive` wiring in a
/// `ViewModifier` keeps `ContentView.body` within the Swift compiler's
/// type-checking budget (an inline `.sheet`/`.onReceive` pair pushed the
/// surrounding view over the “unable to type-check in reasonable time”
/// limit — same fix as the Activity Panel's `AgentActivityPresenter`).
///
/// The notification handler defers the state mutation to the next runloop to
/// avoid the `.onReceive` reentrancy class from #1051.
struct AgentHistoryPresenter: ViewModifier {
    @Binding var isPresented: Bool
    let projectManager: ProjectManager
    let store: AgentHistoryStore
    @Environment(\.controlActiveState) private var controlActiveState

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $isPresented) {
                AgentHistoryView(
                    store: store,
                    isPresented: $isPresented,
                    activities: projectManager.agentActivity.actions
                )
            }
            .onReceive(NotificationCenter.default.publisher(for: .showAgentHistory)) { notification in
                guard ContentView.shouldHandleTargetedCommand(
                    notificationObject: notification.object,
                    currentProject: projectManager,
                    isKeyWindow: controlActiveState == .key
                ) else { return }
                // Defer to break reentrancy (#1051).
                DispatchQueue.main.async {
                    isPresented = true
                }
            }
    }
}
