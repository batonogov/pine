//
//  ProjectSessionRestorer.swift
//  Pine
//
//  Deterministic restoration of pane-local tab state and the global MRU cycle.
//

import Foundation

struct ProjectSessionRestoreResult: Equatable, Sendable {
    let didRestoreEditorTabs: Bool
    let restoredTerminalPanes: Bool
}

/// Outcome of a session startup attempt (`ContentView.restoreSessionIfNeeded`).
///
/// Distinguishes the reasons restoration did not produce content so the
/// startup path can decide whether to seed the workspace with a focused
/// terminal (#1251): a project with no saved session and no recovery entries
/// opens directly into a terminal instead of an empty editor canvas.
///
/// - deferred: `rootURL` was not yet available. Restoration is retried on the
///   next eligible signal (e.g. the first `rootNodes` change). No content
///   should be injected yet.
/// - noSavedSession: No persisted session exists for this project root.
///   Candidate for terminal seeding (subject to recovery discovery).
/// - restored: A saved session was found and applied.
/// - skipped: Real content (editor tabs or terminal tabs) already exists in
///   the pane tree — overlaying a saved session would duplicate it, and a
///   terminal seed would replace content the user or an extension added.
enum SessionStartupDisposition: Equatable, Sendable {
    case deferred
    case noSavedSession
    case restored(ProjectSessionRestoreResult)
    case skipped
}

@MainActor
enum ProjectSessionRestorer {
    private static let maximumRestoredTerminalTabsPerPane = 1_000

    private struct EditorRestoreContext {
        let session: SessionState
        let rootPrefix: String
        let disabledSet: Set<String>
        let previewModes: [String: String]?
        let editorStates: [String: PerTabEditorState]?
        let legacyPinnedSet: Set<String>?
    }

    static func restore(
        _ session: SessionState,
        into projectManager: ProjectManager,
        rootURL: URL
    ) -> ProjectSessionRestoreResult {
        let paneManager = projectManager.paneManager
        let rootPath = rootURL.resolvingSymlinksInPath().path
        let rootPrefix = rootPath + "/"
        let disabledSet = Set(session.existingHighlightingDisabledPaths ?? [])
        let previewModes = session.existingPreviewModes
        let editorStates = session.existingEditorStates
        let legacyPinnedSet = session.existingPinnedPaths
        let activePaneUUID = session.activePaneID.flatMap(UUID.init(uuidString:))
        let editorContext = EditorRestoreContext(
            session: session,
            rootPrefix: rootPrefix,
            disabledSet: disabledSet,
            previewModes: previewModes,
            editorStates: editorStates,
            legacyPinnedSet: legacyPinnedSet
        )

        let restoredLayout = restoreLayout(
            from: session,
            paneManager: paneManager,
            activePaneUUID: activePaneUUID
        )

        if restoredLayout {
            populateRestoredEditorPanes(
                paneManager: paneManager,
                context: editorContext
            )
        } else {
            populateLegacySingleEditorPane(
                tabManager: projectManager.primaryTabManager,
                context: editorContext
            )
        }

        restoreLegacyActiveEditorIfNeeded(
            session: session,
            paneManager: paneManager
        )

        // Empty editor placeholders next to a real editor/terminal are not
        // session content. Prune them before restoring the active pane and MRU.
        paneManager.pruneEmptyEditorLeaves()

        restoreTerminalPanes(
            session: session,
            projectManager: projectManager,
            rootURL: rootURL
        )

        paneManager.restoreActivePane(uuid: activePaneUUID)
        projectManager.terminal.lastActiveTerminalPaneID = {
            if paneManager.root.content(for: paneManager.activePaneID) == .terminal {
                return paneManager.activePaneID
            }
            return paneManager.terminalPaneIDs.first
        }()
        let restoredSwitchOrder = resolveGlobalSwitchOrder(
            session.globalTabSwitchOrder ?? [],
            paneManager: paneManager,
            rootPrefix: rootPrefix
        )
        paneManager.restoreGlobalTabSwitchOrder(restoredSwitchOrder)
        paneManager.requestFocusForActivePane()

        return ProjectSessionRestoreResult(
            didRestoreEditorTabs: !projectManager.allTabs.isEmpty,
            restoredTerminalPanes: !paneManager.terminalPaneIDs.isEmpty
        )
    }

    private static func restoreLayout(
        from session: SessionState,
        paneManager: PaneManager,
        activePaneUUID: UUID?
    ) -> Bool {
        guard let layoutData = session.paneLayoutData,
              let restoredNode = try? JSONDecoder().decode(PaneNode.self, from: layoutData) else {
            return false
        }
        return paneManager.restoreLayout(
            from: restoredNode,
            activePaneUUID: activePaneUUID
        )
    }

    private static func populateRestoredEditorPanes(
        paneManager: PaneManager,
        context: EditorRestoreContext
    ) {
        let assignments = context.session.paneTabAssignments ?? [:]
        for paneID in paneManager.root.leafIDs {
            guard let tabManager = paneManager.tabManager(for: paneID) else { continue }
            let paneKey = paneID.id.uuidString
            let paths = assignments[paneKey] ?? fallbackPaths(
                session: context.session,
                paneManager: paneManager,
                paneID: paneID
            )
            openExistingProjectFiles(
                paths,
                in: tabManager,
                rootPrefix: context.rootPrefix,
                disabledSet: context.disabledSet
            )
            applyTabState(
                to: tabManager,
                paneKey: paneKey,
                context: context
            )
        }
    }

    private static func fallbackPaths(
        session: SessionState,
        paneManager: PaneManager,
        paneID: PaneID
    ) -> [String] {
        let editorPaneIDs = paneManager.root.leafIDs.filter {
            paneManager.root.content(for: $0) == .editor
        }
        guard editorPaneIDs.count == 1, editorPaneIDs[0] == paneID else { return [] }
        return session.existingFileURLs.map(\.path)
    }

    private static func populateLegacySingleEditorPane(
        tabManager: TabManager,
        context: EditorRestoreContext
    ) {
        for url in context.session.existingFileURLs {
            tabManager.openTab(
                url: url,
                syntaxHighlightingDisabled: context.disabledSet.contains(url.path)
            )
        }
        applyLegacyTabState(
            to: tabManager,
            context: context,
            pinnedPaths: context.legacyPinnedSet
        )
    }

    private static func openExistingProjectFiles(
        _ paths: [String],
        in tabManager: TabManager,
        rootPrefix: String,
        disabledSet: Set<String>
    ) {
        for path in paths {
            guard path.hasPrefix(rootPrefix),
                  FileManager.default.fileExists(atPath: path) else { continue }
            tabManager.openTab(
                url: URL(fileURLWithPath: path),
                syntaxHighlightingDisabled: disabledSet.contains(path)
            )
        }
    }

    private static func applyTabState(
        to tabManager: TabManager,
        paneKey: String,
        context: EditorRestoreContext
    ) {
        let pinnedPaths: Set<String>? = if let pathsByPane = context.session.panePinnedPaths {
            Set(pathsByPane[paneKey] ?? [])
        } else {
            context.legacyPinnedSet
        }
        applyLegacyTabState(
            to: tabManager,
            context: context,
            pinnedPaths: pinnedPaths
        )

        if let previewPath = context.session.paneTransientPreviewPaths?[paneKey],
           let index = tabManager.tabs.firstIndex(where: { $0.url.path == previewPath }),
           !tabManager.tabs[index].isPinned {
            tabManager.tabs[index].isTransientPreview = true
        }

        if let activePath = context.session.paneActiveEditorPaths?[paneKey],
           let tab = tabManager.tabs.first(where: { $0.url.path == activePath }) {
            tabManager.activeTabID = tab.id
        }
    }

    private static func applyLegacyTabState(
        to tabManager: TabManager,
        context: EditorRestoreContext,
        pinnedPaths: Set<String>?
    ) {
        for index in tabManager.tabs.indices {
            let path = tabManager.tabs[index].url.path
            if let rawMode = context.previewModes?[path],
               let mode = MarkdownPreviewMode(rawValue: rawMode) {
                tabManager.tabs[index].previewMode = mode
            }
            if let state = context.editorStates?[path] {
                state.apply(to: &tabManager.tabs[index])
            }
        }
        if let pinnedPaths {
            tabManager.restorePinnedState(pinnedPaths: pinnedPaths)
        }
    }

    private static func restoreLegacyActiveEditorIfNeeded(
        session: SessionState,
        paneManager: PaneManager
    ) {
        guard session.paneActiveEditorPaths == nil,
              let activeURL = session.activeFileURL else { return }

        let preferredPaneID = session.activePaneID
            .flatMap(UUID.init(uuidString:))
            .flatMap { uuid in
                paneManager.root.leafIDs.first(where: { $0.id == uuid })
            }
        let orderedPaneIDs = [preferredPaneID].compactMap { $0 }
            + paneManager.root.leafIDs.filter { $0 != preferredPaneID }

        for paneID in orderedPaneIDs {
            guard let tabManager = paneManager.tabManager(for: paneID),
                  let tab = tabManager.tab(for: activeURL) else { continue }
            tabManager.activeTabID = tab.id
            paneManager.activePaneID = paneID
            return
        }
    }

    private static func restoreTerminalPanes(
        session: SessionState,
        projectManager: ProjectManager,
        rootURL: URL
    ) {
        let paneManager = projectManager.paneManager
        if let counts = session.terminalPaneTabCounts {
            for paneID in paneManager.terminalPaneIDs {
                let paneIDString = paneID.id.uuidString
                guard let state = paneManager.terminalState(for: paneID) else { continue }
                let rawCount = counts[paneIDString] ?? 1
                let count = min(
                    max(1, rawCount),
                    maximumRestoredTerminalTabsPerPane
                )
                for _ in state.tabCount..<count {
                    state.addTab(workingDirectory: rootURL)
                }
                if let activeIndex = session.terminalPaneActiveIndices?[paneIDString],
                   state.terminalTabs.indices.contains(activeIndex) {
                    state.activeTerminalID = state.terminalTabs[activeIndex].id
                }
            }
            return
        }

        // Legacy migration from the pre-pane terminal panel.
        guard session.isTerminalVisible == true,
              let rawCount = session.terminalTabCount,
              rawCount >= 1 else {
            for paneID in paneManager.terminalPaneIDs {
                guard let state = paneManager.terminalState(for: paneID),
                      state.terminalTabs.isEmpty else { continue }
                state.addTab(workingDirectory: rootURL)
            }
            return
        }
        let count = min(rawCount, maximumRestoredTerminalTabsPerPane)
        if let existingPaneID = (
            paneManager.root.content(for: paneManager.activePaneID) == .terminal
                ? paneManager.activePaneID
                : paneManager.terminalPaneIDs.first
        ), let state = paneManager.terminalState(for: existingPaneID) {
            for _ in state.tabCount..<count {
                state.addTab(workingDirectory: rootURL)
            }
            if let activeIndex = session.activeTerminalIndex,
               state.terminalTabs.indices.contains(activeIndex) {
                state.activeTerminalID = state.terminalTabs[activeIndex].id
            }
            projectManager.terminal.lastActiveTerminalPaneID = existingPaneID
            return
        }

        projectManager.terminal.createTerminalTab(
            relativeTo: paneManager.activePaneID,
            workingDirectory: rootURL
        )
        guard let paneID = projectManager.terminal.lastActiveTerminalPaneID,
              let state = paneManager.terminalState(for: paneID) else { return }
        for _ in 1..<count {
            state.addTab(workingDirectory: rootURL)
        }
        if let activeIndex = session.activeTerminalIndex,
           state.terminalTabs.indices.contains(activeIndex) {
            state.activeTerminalID = state.terminalTabs[activeIndex].id
        }
    }

    private static func resolveGlobalSwitchOrder(
        _ references: [SessionTabReference],
        paneManager: PaneManager,
        rootPrefix: String
    ) -> [GlobalTabIdentity] {
        references.compactMap { reference in
            guard let uuid = UUID(uuidString: reference.paneID),
                  let paneID = paneManager.root.leafIDs.first(where: { $0.id == uuid }),
                  paneManager.root.content(for: paneID) == reference.contentType else {
                return nil
            }

            switch reference.contentType {
            case .editor:
                guard let path = reference.editorFilePath,
                      path.hasPrefix(rootPrefix),
                      let tabID = paneManager.tabManager(for: paneID)?.tabs
                        .first(where: { $0.url.path == path })?.id else {
                    return nil
                }
                return GlobalTabIdentity(
                    paneID: paneID,
                    tabID: tabID,
                    contentType: .editor
                )
            case .terminal:
                guard let index = reference.terminalTabIndex,
                      let state = paneManager.terminalState(for: paneID),
                      state.terminalTabs.indices.contains(index) else {
                    return nil
                }
                return GlobalTabIdentity(
                    paneID: paneID,
                    tabID: state.terminalTabs[index].id,
                    contentType: .terminal
                )
            }
        }
    }
}
