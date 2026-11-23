//
//  ProjectSessionRestorer.swift
//  Pine
//
//  Restores documents and merges legacy multi-pane assignments into the fixed workspace.
//

import Foundation

struct ProjectSessionRestoreResult: Equatable, Sendable {
    let didRestoreEditorTabs: Bool
    let restoredTerminalPanes: Bool
}

enum SessionStartupDisposition: Equatable, Sendable {
    case deferred
    case noSavedSession
    case restored(ProjectSessionRestoreResult)
    case skipped
}

@MainActor
enum ProjectSessionRestorer {
    private static let maximumRestoredTerminalTabs = 1_000

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
        let context = EditorRestoreContext(
            session: session,
            rootPrefix: rootPath + "/",
            disabledSet: Set(session.existingHighlightingDisabledPaths ?? []),
            previewModes: session.existingPreviewModes,
            editorStates: session.existingEditorStates,
            legacyPinnedSet: session.existingPinnedPaths
        )
        let activePaneUUID = session.activePaneID.flatMap(UUID.init(uuidString:))
        let migration = restoreLayout(
            from: session,
            paneManager: paneManager,
            activePaneUUID: activePaneUUID
        )

        if let migration {
            populateMergedEditorPane(
                migration: migration,
                activePaneUUID: activePaneUUID,
                paneManager: paneManager,
                context: context
            )
        } else {
            populateLegacySingleEditorPane(
                tabManager: projectManager.primaryTabManager,
                context: context
            )
        }

        paneManager.pruneEmptyEditorLeaves()
        restoreTerminalPanes(
            session: session,
            migration: migration,
            projectManager: projectManager,
            rootURL: rootURL
        )

        paneManager.restoreActivePane(uuid: activePaneUUID)
        let preferredTerminalPane =
            paneManager.root.content(for: paneManager.activePaneID) == .terminal
            ? paneManager.activePaneID
            : nil
        projectManager.terminal.restoreTerminalDestination(
            preferredPaneID: preferredTerminalPane
        )
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
    ) -> PaneLayoutMigration? {
        guard let layoutData = session.paneLayoutData,
              let restoredNode = try? JSONDecoder().decode(PaneNode.self, from: layoutData) else {
            return nil
        }
        return paneManager.restoreLayout(
            from: restoredNode,
            activePaneUUID: activePaneUUID
        )
    }

    private static func populateMergedEditorPane(
        migration: PaneLayoutMigration,
        activePaneUUID: UUID?,
        paneManager: PaneManager,
        context: EditorRestoreContext
    ) {
        guard let tabManager = paneManager.tabManager(for: migration.editorPaneID) else {
            return
        }
        let assignments = context.session.paneTabAssignments ?? [:]
        var paths = migration.editorSourcePaneIDs.flatMap {
            assignments[$0.id.uuidString] ?? []
        }
        // The legacy union is a safety net for partially written assignments.
        for url in context.session.existingFileURLs where !paths.contains(url.path) {
            paths.append(url.path)
        }
        openExistingProjectFiles(
            paths,
            in: tabManager,
            rootPrefix: context.rootPrefix,
            disabledSet: context.disabledSet
        )

        var pinnedPaths = context.legacyPinnedSet ?? []
        for paneID in migration.editorSourcePaneIDs {
            pinnedPaths.formUnion(
                context.session.panePinnedPaths?[paneID.id.uuidString] ?? []
            )
        }
        applyEditorState(
            to: tabManager,
            context: context,
            pinnedPaths: pinnedPaths
        )

        let sourceKeys = migration.editorSourcePaneIDs.map(\.id.uuidString)
        let activeKey = activePaneUUID?.uuidString
        let activePath = activeKey.flatMap {
            context.session.paneActiveEditorPaths?[$0]
        } ?? sourceKeys.compactMap {
            context.session.paneActiveEditorPaths?[$0]
        }.first ?? context.session.activeFileURL?.path
        if let activePath,
           let tab = tabManager.tabs.first(where: { $0.fileURL?.path == activePath }) {
            tabManager.activeTabID = tab.id
        }

        let previewPath = activeKey.flatMap {
            context.session.paneTransientPreviewPaths?[$0]
        } ?? sourceKeys.compactMap {
            context.session.paneTransientPreviewPaths?[$0]
        }.first
        if let previewPath,
           let index = tabManager.tabs.firstIndex(where: {
               $0.fileURL?.path == previewPath
           }), !tabManager.tabs[index].isPinned {
            tabManager.tabs[index].isTransientPreview = true
        }
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
        applyEditorState(
            to: tabManager,
            context: context,
            pinnedPaths: context.legacyPinnedSet
        )
        if let activeURL = context.session.activeFileURL,
           let tab = tabManager.tab(for: activeURL) {
            tabManager.activeTabID = tab.id
        }
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

    private static func applyEditorState(
        to tabManager: TabManager,
        context: EditorRestoreContext,
        pinnedPaths: Set<String>?
    ) {
        for index in tabManager.tabs.indices {
            guard let path = tabManager.tabs[index].fileURL?.path else { continue }
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

    private static func restoreTerminalPanes(
        session: SessionState,
        migration: PaneLayoutMigration?,
        projectManager: ProjectManager,
        rootURL: URL
    ) {
        let paneManager = projectManager.paneManager
        if let counts = session.terminalPaneTabCounts, let migration {
            guard let terminalPaneID = migration.terminalPaneID,
                  let state = paneManager.terminalState(for: terminalPaneID) else { return }
            var totalCount = 0
            var activeIndex: Int?
            for sourcePaneID in migration.terminalSourcePaneIDs {
                let key = sourcePaneID.id.uuidString
                let count = min(max(1, counts[key] ?? 1), maximumRestoredTerminalTabs)
                let offset = totalCount
                totalCount = min(
                    totalCount + count,
                    maximumRestoredTerminalTabs
                )
                let isActiveSource = session.activePaneID == key
                if isActiveSource || activeIndex == nil {
                    let sourceActive = session.terminalPaneActiveIndices?[key] ?? 0
                    activeIndex = min(offset + max(0, sourceActive), totalCount - 1)
                }
                if totalCount == maximumRestoredTerminalTabs { break }
            }
            totalCount = max(1, totalCount)
            for _ in state.tabCount..<totalCount {
                state.addTab(workingDirectory: rootURL)
            }
            if let activeIndex, state.terminalTabs.indices.contains(activeIndex) {
                state.activeTerminalID = state.terminalTabs[activeIndex].id
            }
            return
        }

        guard session.isTerminalVisible == true,
              let rawCount = session.terminalTabCount,
              rawCount >= 1 else {
            if let terminalPaneID = migration?.terminalPaneID,
               let state = paneManager.terminalState(for: terminalPaneID),
               state.terminalTabs.isEmpty {
                state.addTab(workingDirectory: rootURL)
            }
            return
        }

        let count = min(rawCount, maximumRestoredTerminalTabs)
        if let existingPaneID = migration?.terminalPaneID,
           let state = paneManager.terminalState(for: existingPaneID) {
            for _ in state.tabCount..<count {
                state.addTab(workingDirectory: rootURL)
            }
            if let activeIndex = session.activeTerminalIndex,
               state.terminalTabs.indices.contains(activeIndex) {
                state.activeTerminalID = state.terminalTabs[activeIndex].id
            }
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
}
