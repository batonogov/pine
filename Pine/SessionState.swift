//
//  SessionState.swift
//  Pine
//
//  Created by Claude on 11.03.2026.
//

import Foundation

/// Persists and restores per-project editor tab state (open files + active tab).
/// Sessions are preserved across window close and app quit so that reopening
/// a project from Welcome or Open Recent restores its last workspace state.
struct SessionState: Codable {
    var projectPath: String
    var openFilePaths: [String]
    var activeFilePath: String?

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
        defaults: UserDefaults = .standard
    ) {
        let state = SessionState(
            projectPath: projectURL.path,
            openFilePaths: openFileURLs.map(\.path),
            activeFilePath: activeFileURL?.path
        )
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: key(for: projectURL))
    }

    // MARK: - Load

    /// Returns the saved tab session for a specific project, if the folder still exists.
    static func load(for projectURL: URL, defaults: UserDefaults = .standard) -> SessionState? {
        guard let data = defaults.data(forKey: key(for: projectURL)),
              let state = try? JSONDecoder().decode(SessionState.self, from: data) else {
            // Try legacy key as fallback for migration
            return loadLegacy(for: projectURL, defaults: defaults)
        }
        guard directoryExists(at: state.projectPath) else { return nil }
        return state
    }

    /// Loads from legacy single-project key if it matches the given project.
    private static func loadLegacy(for projectURL: URL, defaults: UserDefaults) -> SessionState? {
        guard let data = defaults.data(forKey: legacyKey),
              let state = try? JSONDecoder().decode(SessionState.self, from: data) else {
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

    /// File URLs filtered to those that still exist on disk.
    var existingFileURLs: [URL] {
        openFilePaths.compactMap { path in
            let url = URL(fileURLWithPath: path)
            return FileManager.default.fileExists(atPath: path) ? url : nil
        }
    }

    /// The active file URL if it still exists on disk.
    var activeFileURL: URL? {
        guard let path = activeFilePath,
              FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }
}
