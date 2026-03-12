//
//  ProjectRegistry.swift
//  Pine
//
//  Created by Claude on 13.03.2026.
//

import SwiftUI

/// Manages open projects and recent project history.
/// Each project directory maps to a single ProjectManager instance.
@Observable
final class ProjectRegistry {
    /// Open projects keyed by their root directory URL.
    private(set) var openProjects: [URL: ProjectManager] = [:]
    /// Recently opened project paths (most recent first), persisted to UserDefaults.
    var recentProjects: [URL] = []
    /// Tracks the last active project for session save on quit.
    var lastActiveProjectURL: URL?

    private static let recentProjectsKey = "recentProjectPaths"
    private static let maxRecentProjects = 10

    init() {
        loadRecentProjects()
    }

    /// Returns the ProjectManager for a given project URL, creating one if needed.
    func projectManager(for projectURL: URL) -> ProjectManager {
        if let existing = openProjects[projectURL] {
            return existing
        }
        let pm = ProjectManager()
        pm.workspace.loadDirectory(url: projectURL)
        openProjects[projectURL] = pm
        addToRecent(projectURL)
        return pm
    }

    /// Opens a project via folder picker. Returns the project URL if opened.
    @discardableResult
    func openProjectViaPanel() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = Strings.openPanelMessage
        panel.prompt = Strings.openPanelPrompt

        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        _ = projectManager(for: url)
        return url
    }

    /// Closes a project and removes it from open projects.
    func closeProject(_ url: URL) {
        openProjects.removeValue(forKey: url)
    }

    /// Checks if a project is already open.
    func isProjectOpen(_ url: URL) -> Bool {
        openProjects[url] != nil
    }

    // MARK: - Recent Projects

    private func addToRecent(_ url: URL) {
        recentProjects.removeAll { $0 == url }
        recentProjects.insert(url, at: 0)
        if recentProjects.count > Self.maxRecentProjects {
            recentProjects = Array(recentProjects.prefix(Self.maxRecentProjects))
        }
        saveRecentProjects()
    }

    private func loadRecentProjects() {
        guard let paths = UserDefaults.standard.stringArray(forKey: Self.recentProjectsKey) else {
            return
        }
        recentProjects = paths.compactMap { path in
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir),
                  isDir.boolValue else { return nil }
            return URL(fileURLWithPath: path)
        }
    }

    private func saveRecentProjects() {
        let paths = recentProjects.map(\.path)
        UserDefaults.standard.set(paths, forKey: Self.recentProjectsKey)
    }
}
