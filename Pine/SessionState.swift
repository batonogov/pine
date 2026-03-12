//
//  SessionState.swift
//  Pine
//
//  Created by Claude on 11.03.2026.
//

import Foundation

/// Persists and restores the last session (project folder + open editor tabs).
struct SessionState: Codable {
    var projectPath: String
    var openFilePaths: [String]
    var activeFilePath: String?

    // MARK: - UserDefaults key

    private static let defaultsKey = "lastSessionState"

    // MARK: - Clear

    /// Removes the saved session so the next launch starts with Welcome.
    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
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
        defaults.set(data, forKey: defaultsKey)
    }

    // MARK: - Load

    /// Returns the saved session if the project folder still exists on disk.
    static func load(defaults: UserDefaults = .standard) -> SessionState? {
        guard let data = defaults.data(forKey: defaultsKey),
              let state = try? JSONDecoder().decode(SessionState.self, from: data) else {
            return nil
        }
        // Only restore if the project folder still exists
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: state.projectPath, isDirectory: &isDir),
              isDir.boolValue else {
            return nil
        }
        return state
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
