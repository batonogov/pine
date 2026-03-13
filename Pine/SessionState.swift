//
//  SessionState.swift
//  Pine
//
//  Created by Claude on 11.03.2026.
//

import Foundation

/// Persists and restores session state (project folder + open editor tabs).
/// Each project stores its own session keyed by its path.
/// A separate key tracks which projects were open at quit for multi-window restore.
struct SessionState: Codable {
    var projectPath: String
    var openFilePaths: [String]
    var activeFilePath: String?

    // MARK: - UserDefaults keys

    /// Legacy single-project key (kept for migration).
    private static let defaultsKey = "lastSessionState"
    /// Per-project session key prefix.
    private static let perProjectPrefix = "sessionState:"
    /// List of project paths that were open at last quit.
    private static let openProjectsKey = "openProjectPaths"

    // MARK: - Per-project key

    private static func key(for projectURL: URL) -> String {
        perProjectPrefix + projectURL.resolvingSymlinksInPath().path
    }

    // MARK: - Clear

    /// Removes the saved session for a specific project.
    static func clear(for projectURL: URL, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key(for: projectURL))
        // Also remove from open projects list
        var paths = defaults.stringArray(forKey: openProjectsKey) ?? []
        paths.removeAll { $0 == projectURL.resolvingSymlinksInPath().path }
        defaults.set(paths, forKey: openProjectsKey)
        // If no projects remain, clear legacy key too so fallback doesn't resurrect a project
        if paths.isEmpty {
            defaults.removeObject(forKey: defaultsKey)
        }
    }

    /// Loads legacy single-project session (for migration from older versions).
    static func loadLegacySingle(defaults: UserDefaults = .standard) -> SessionState? {
        guard let data = defaults.data(forKey: defaultsKey),
              let state = try? JSONDecoder().decode(SessionState.self, from: data) else {
            return nil
        }
        guard directoryExists(at: state.projectPath) else { return nil }
        return state
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
        // Also write to legacy key for backwards compat
        defaults.set(data, forKey: defaultsKey)
    }

    /// Records which project URLs are currently open (called on quit).
    static func saveOpenProjects(_ urls: [URL], defaults: UserDefaults = .standard) {
        let paths = urls.map { $0.resolvingSymlinksInPath().path }
        defaults.set(paths, forKey: openProjectsKey)
    }

    // MARK: - Load

    /// Returns the saved session for a specific project, if the folder still exists.
    static func load(for projectURL: URL, defaults: UserDefaults = .standard) -> SessionState? {
        guard let data = defaults.data(forKey: key(for: projectURL)),
              let state = try? JSONDecoder().decode(SessionState.self, from: data) else {
            // Try legacy key as fallback
            return loadLegacy(for: projectURL, defaults: defaults)
        }
        guard directoryExists(at: state.projectPath) else { return nil }
        return state
    }

    /// Loads from legacy single-project key if it matches the given project.
    private static func loadLegacy(for projectURL: URL, defaults: UserDefaults) -> SessionState? {
        guard let data = defaults.data(forKey: defaultsKey),
              let state = try? JSONDecoder().decode(SessionState.self, from: data) else {
            return nil
        }
        let canonical = projectURL.resolvingSymlinksInPath().path
        guard state.projectPath == canonical || URL(fileURLWithPath: state.projectPath)
            .resolvingSymlinksInPath().path == canonical else { return nil }
        guard directoryExists(at: state.projectPath) else { return nil }
        return state
    }

    /// Returns the project URLs that were open at last quit.
    static func loadOpenProjects(defaults: UserDefaults = .standard) -> [URL] {
        guard let paths = defaults.stringArray(forKey: openProjectsKey) else { return [] }
        return paths.compactMap { path in
            guard directoryExists(at: path) else { return nil }
            return URL(fileURLWithPath: path)
        }
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
