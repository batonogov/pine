//
//  SessionState.swift
//  Pine
//
//  Created by Claude on 11.03.2026.
//

import Foundation
import os

/// Persists and restores per-project editor tab state (open files + active tab).
/// Sessions are preserved across window close and app quit so that reopening
/// a project from Welcome or Open Recent restores its last workspace state.
struct SessionState: Codable, Sendable {
    private static let logger = Logger.app
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

    // MARK: - Terminal state (optional for backwards compatibility)

    var terminalTabCount: Int?
    var activeTerminalIndex: Int?
    var isTerminalVisible: Bool?
    var isTerminalMaximized: Bool?

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

    static func save(
        projectURL: URL,
        openFileURLs: [URL],
        activeFileURL: URL? = nil,
        previewModes: [String: String]? = nil,
        highlightingDisabledPaths: [String]? = nil,
        editorStates: [String: PerTabEditorState]? = nil,
        pinnedPaths: [String]? = nil,
        terminalTabCount: Int? = nil,
        activeTerminalIndex: Int? = nil,
        isTerminalVisible: Bool? = nil,
        isTerminalMaximized: Bool? = nil,
        paneLayoutData: Data? = nil,
        paneTabAssignments: [String: [String]]? = nil,
        activePaneID: String? = nil,
        defaults: UserDefaults = .standard
    ) {
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
            terminalTabCount: terminalTabCount,
            activeTerminalIndex: activeTerminalIndex,
            isTerminalVisible: isTerminalVisible,
            isTerminalMaximized: isTerminalMaximized
        )
        do {
            let data = try JSONEncoder().encode(state)
            defaults.set(data, forKey: key(for: projectURL))
        } catch {
            logger.error("Failed to encode session state for \(projectURL.lastPathComponent): \(error)")
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
