//
//  SessionState.swift
//  Pine
//
//  Created by Claude on 11.03.2026.
//

import Foundation
import os

/// Stable, portable identity for a tab in the global session MRU order.
///
/// Runtime tab UUIDs are intentionally not persisted: editor tabs are
/// recreated from their project-scoped file path and terminal processes are
/// recreated from their pane-local ordinal on every launch.
struct SessionTabReference: Codable, Equatable, Sendable {
    let paneID: String
    let contentType: PaneContent
    let editorFilePath: String?
    let terminalTabIndex: Int?

    static func editor(paneID: PaneID, filePath: String) -> Self {
        Self(
            paneID: paneID.id.uuidString,
            contentType: .editor,
            editorFilePath: filePath,
            terminalTabIndex: nil
        )
    }

    static func terminal(paneID: PaneID, tabIndex: Int) -> Self {
        Self(
            paneID: paneID.id.uuidString,
            contentType: .terminal,
            editorFilePath: nil,
            terminalTabIndex: tabIndex
        )
    }
}

/// Persists and restores per-project editor tab state (open files + active tab).
/// Sessions are preserved across window close and app quit so that reopening
/// a project from Welcome or Open Recent restores its last workspace state.
struct SessionState: Codable, Sendable {
    private static let logger = Logger.app
    static let currentSchemaVersion = 1
    var schemaVersion: Int?
    var projectPath: String
    var openFilePaths: [String]
    var activeFilePath: String?
    /// Preview modes for markdown files. Key is file path, value is MarkdownPreviewMode raw value.
    /// Optional for backwards compatibility with sessions saved before this field existed.
    var previewModes: [String: String]?
    /// File paths where syntax highlighting was disabled (e.g. large files opened without highlighting).
    /// Optional for backwards compatibility with sessions saved before this field existed.
    var highlightingDisabledPaths: [String]?
    /// Per-file editor state (cursor position, scroll offset, fold state).
    /// Key is the file path. Optional for backwards compatibility.
    var editorStates: [String: PerTabEditorState]?
    /// File paths of pinned tabs. Optional for backwards compatibility.
    var pinnedPaths: [String]?

    // MARK: - Pane layout (optional for backwards compatibility)

    /// JSON-encoded PaneNode tree representing the split pane layout.
    var paneLayoutData: Data?
    /// Maps pane leaf ID (UUID string) to ordered list of file paths in that pane.
    var paneTabAssignments: [String: [String]]?
    /// The active pane leaf ID (UUID string).
    var activePaneID: String?
    /// Active editor file in every editor pane, keyed by pane UUID.
    var paneActiveEditorPaths: [String: String]?
    /// Ordered pinned group in every editor pane, keyed by pane UUID.
    var panePinnedPaths: [String: [String]]?
    /// At most one transient preview file per editor pane, keyed by pane UUID.
    var paneTransientPreviewPaths: [String: String]?
    /// Global editor/terminal MRU order expressed through stable references.
    var globalTabSwitchOrder: [SessionTabReference]?

    // MARK: - Terminal state (optional for backwards compatibility)

    /// Legacy single-terminal-panel fields (kept for migration from older sessions).
    var terminalTabCount: Int?
    var activeTerminalIndex: Int?
    var isTerminalVisible: Bool?
    var isTerminalMaximized: Bool?

    /// Per-terminal-pane tab counts. Key is pane UUID string.
    var terminalPaneTabCounts: [String: Int]?
    /// Per-terminal-pane active tab indices. Key is pane UUID string.
    var terminalPaneActiveIndices: [String: Int]?

    var hasSupportedSchema: Bool {
        guard let schemaVersion else { return true }
        return (0...Self.currentSchemaVersion).contains(schemaVersion)
    }

    init(
        schemaVersion: Int? = Self.currentSchemaVersion,
        projectPath: String,
        openFilePaths: [String],
        activeFilePath: String? = nil,
        previewModes: [String: String]? = nil,
        highlightingDisabledPaths: [String]? = nil,
        editorStates: [String: PerTabEditorState]? = nil,
        pinnedPaths: [String]? = nil,
        paneLayoutData: Data? = nil,
        paneTabAssignments: [String: [String]]? = nil,
        activePaneID: String? = nil,
        paneActiveEditorPaths: [String: String]? = nil,
        panePinnedPaths: [String: [String]]? = nil,
        paneTransientPreviewPaths: [String: String]? = nil,
        globalTabSwitchOrder: [SessionTabReference]? = nil,
        terminalTabCount: Int? = nil,
        activeTerminalIndex: Int? = nil,
        isTerminalVisible: Bool? = nil,
        isTerminalMaximized: Bool? = nil,
        terminalPaneTabCounts: [String: Int]? = nil,
        terminalPaneActiveIndices: [String: Int]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.projectPath = projectPath
        self.openFilePaths = openFilePaths
        self.activeFilePath = activeFilePath
        self.previewModes = previewModes
        self.highlightingDisabledPaths = highlightingDisabledPaths
        self.editorStates = editorStates
        self.pinnedPaths = pinnedPaths
        self.paneLayoutData = paneLayoutData
        self.paneTabAssignments = paneTabAssignments
        self.activePaneID = activePaneID
        self.paneActiveEditorPaths = paneActiveEditorPaths
        self.panePinnedPaths = panePinnedPaths
        self.paneTransientPreviewPaths = paneTransientPreviewPaths
        self.globalTabSwitchOrder = globalTabSwitchOrder
        self.terminalTabCount = terminalTabCount
        self.activeTerminalIndex = activeTerminalIndex
        self.isTerminalVisible = isTerminalVisible
        self.isTerminalMaximized = isTerminalMaximized
        self.terminalPaneTabCounts = terminalPaneTabCounts
        self.terminalPaneActiveIndices = terminalPaneActiveIndices
    }

    // MARK: - UserDefaults keys

    /// Legacy single-project key (kept for migration from older versions).
    private static let legacyKey = "lastSessionState"
    /// Per-project session key prefix.
    private static let perProjectPrefix = "sessionState:"

    private static func key(for projectURL: URL) -> String {
        perProjectPrefix + projectURL.resolvingSymlinksInPath().path
    }

    // MARK: - Clear

    /// Removes the saved tab session for a specific project.
    static func clear(for projectURL: URL, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key(for: projectURL))
    }

    /// Removes all saved sessions (used by `--reset-state` launch argument for UI testing).
    static func removeAll(defaults: UserDefaults = .standard) {
        let allKeys = defaults.dictionaryRepresentation().keys
        for key in allKeys where key.hasPrefix(perProjectPrefix) {
            defaults.removeObject(forKey: key)
        }
        defaults.removeObject(forKey: legacyKey)
    }

    // MARK: - Save

    @discardableResult
    static func save(
        projectURL: URL,
        openFileURLs: [URL],
        activeFileURL: URL? = nil,
        previewModes: [String: String]? = nil,
        highlightingDisabledPaths: [String]? = nil,
        editorStates: [String: PerTabEditorState]? = nil,
        pinnedPaths: [String]? = nil,
        terminalPaneTabCounts: [String: Int]? = nil,
        terminalPaneActiveIndices: [String: Int]? = nil,
        paneLayoutData: Data? = nil,
        paneTabAssignments: [String: [String]]? = nil,
        activePaneID: String? = nil,
        paneActiveEditorPaths: [String: String]? = nil,
        panePinnedPaths: [String: [String]]? = nil,
        paneTransientPreviewPaths: [String: String]? = nil,
        globalTabSwitchOrder: [SessionTabReference]? = nil,
        defaults: UserDefaults = .standard,
        faultInjector: PersistenceFaultInjector = .processEnvironment
    ) -> Bool {
        let state = SessionState(
            projectPath: projectURL.path,
            openFilePaths: openFileURLs.map(\.path),
            activeFilePath: activeFileURL?.path,
            previewModes: previewModes,
            highlightingDisabledPaths: highlightingDisabledPaths,
            editorStates: editorStates,
            pinnedPaths: pinnedPaths,
            paneLayoutData: paneLayoutData,
            paneTabAssignments: paneTabAssignments,
            activePaneID: activePaneID,
            paneActiveEditorPaths: paneActiveEditorPaths,
            panePinnedPaths: panePinnedPaths,
            paneTransientPreviewPaths: paneTransientPreviewPaths,
            globalTabSwitchOrder: globalTabSwitchOrder,
            terminalPaneTabCounts: terminalPaneTabCounts,
            terminalPaneActiveIndices: terminalPaneActiveIndices
        )
        do {
            try faultInjector.checkpoint(
                store: .session,
                phase: .beforeWrite
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(state)
            try faultInjector.checkpoint(
                store: .session,
                phase: .afterTemporaryWrite
            )
            try faultInjector.checkpoint(
                store: .session,
                phase: .beforeSync
            )
            try faultInjector.checkpoint(
                store: .session,
                phase: .beforeAtomicReplace
            )
            defaults.set(data, forKey: key(for: projectURL))
            do {
                try faultInjector.checkpoint(
                    store: .session,
                    phase: .afterAtomicReplace
                )
            } catch {
                let projectName = projectURL.lastPathComponent
                logger.error(
                    "Session state replaced but durability is unknown for \(projectName): \(error)"
                )
                return false
            }
            return true
        } catch {
            let projectName = projectURL.lastPathComponent
            logger.error(
                "Failed to persist session state for \(projectName): \(error)"
            )
            return false
        }
    }

    // MARK: - Load

    /// Returns the saved tab session for a specific project, if the folder still exists.
    static func load(for projectURL: URL, defaults: UserDefaults = .standard) -> SessionState? {
        guard let data = defaults.data(forKey: key(for: projectURL)) else {
            return loadLegacy(for: projectURL, defaults: defaults)
        }
        let state: SessionState
        do {
            state = try JSONDecoder().decode(SessionState.self, from: data)
        } catch {
            logger.error("Failed to decode session state for \(projectURL.lastPathComponent): \(error)")
            // Try legacy key as fallback for migration
            return loadLegacy(for: projectURL, defaults: defaults)
        }
        guard state.hasSupportedSchema else {
            logger.error(
                "Refusing unsupported session schema for \(projectURL.lastPathComponent)"
            )
            return nil
        }
        guard directoryExists(at: state.projectPath) else { return nil }
        return state
    }

    /// Loads from legacy single-project key if it matches the given project.
    private static func loadLegacy(for projectURL: URL, defaults: UserDefaults) -> SessionState? {
        guard let data = defaults.data(forKey: legacyKey) else {
            return nil
        }
        let state: SessionState
        do {
            state = try JSONDecoder().decode(SessionState.self, from: data)
        } catch {
            logger.error("Failed to decode legacy session state: \(error)")
            return nil
        }
        guard state.hasSupportedSchema else {
            logger.error("Refusing unsupported legacy session schema")
            return nil
        }
        let canonical = projectURL.resolvingSymlinksInPath().path
        guard state.projectPath == canonical || URL(fileURLWithPath: state.projectPath)
            .resolvingSymlinksInPath().path == canonical else { return nil }
        guard directoryExists(at: state.projectPath) else { return nil }
        return state
    }

    private static func directoryExists(at path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    // MARK: - Resolved URLs

    var projectURL: URL { URL(fileURLWithPath: projectPath) }

    /// Project root path prefix used for scoping (includes trailing slash).
    private var rootPrefix: String { projectPath + "/" }

    /// File URLs filtered to those that still exist on disk and belong to the project root.
    var existingFileURLs: [URL] {
        let prefix = rootPrefix
        return openFilePaths.compactMap { path in
            guard path.hasPrefix(prefix),
                  FileManager.default.fileExists(atPath: path) else { return nil }
            return URL(fileURLWithPath: path)
        }
    }

    /// The active file URL if it still exists on disk and belongs to the project root.
    var activeFileURL: URL? {
        guard let path = activeFilePath,
              path.hasPrefix(rootPrefix),
              FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// Preview modes filtered to entries within the project root that still exist on disk.
    var existingPreviewModes: [String: String]? {
        guard let modes = previewModes else { return nil }
        let prefix = rootPrefix
        let filtered = modes.filter {
            $0.key.hasPrefix(prefix) && FileManager.default.fileExists(atPath: $0.key)
        }
        return filtered.isEmpty ? nil : filtered
    }

    /// Per-file editor states filtered to entries within the project root.
    var existingEditorStates: [String: PerTabEditorState]? {
        guard let states = editorStates else { return nil }
        let prefix = rootPrefix
        let filtered = states.filter {
            $0.key.hasPrefix(prefix) && FileManager.default.fileExists(atPath: $0.key)
        }
        return filtered.isEmpty ? nil : filtered
    }

    /// Pinned paths filtered to entries within the project root that still exist on disk.
    var existingPinnedPaths: Set<String>? {
        guard let paths = pinnedPaths else { return nil }
        let prefix = rootPrefix
        let filtered = paths.filter {
            $0.hasPrefix(prefix) && FileManager.default.fileExists(atPath: $0)
        }
        return filtered.isEmpty ? nil : Set(filtered)
    }

    /// Highlighting-disabled paths filtered to entries within the project root that still exist on disk.
    var existingHighlightingDisabledPaths: [String]? {
        guard let paths = highlightingDisabledPaths else { return nil }
        let prefix = rootPrefix
        let filtered = paths.filter {
            $0.hasPrefix(prefix) && FileManager.default.fileExists(atPath: $0)
        }
        return filtered.isEmpty ? nil : filtered
    }
}
