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
    /// Projects whose window was closed but whose ProjectManager (and terminal processes)
    /// are kept alive. Reopening the same project returns the existing PM.
    private(set) var backgroundProjects: Set<URL> = []
    /// Recently opened project paths (most recent first), persisted to UserDefaults.
    var recentProjects: [URL] = []

    private static let recentProjectsKey = "recentProjectPaths"
    private static let maxRecentProjects = 10

    init() {
        if CommandLine.arguments.contains("--clear-recent-projects") {
            UserDefaults.standard.removeObject(forKey: Self.recentProjectsKey)
        }
        loadRecentProjects()
    }

    /// Returns the ProjectManager for a given project URL, creating one if needed.
    /// URLs are resolved to their canonical (real) path to prevent duplicates via symlinks.
    /// Returns nil if the directory no longer exists on disk.
    func projectManager(for projectURL: URL) -> ProjectManager? {
        let canonical = projectURL.resolvingSymlinksInPath()
        if let existing = openProjects[canonical] {
            // Verify directory still exists when reopening from background
            if backgroundProjects.contains(canonical) {
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: canonical.path, isDirectory: &isDir),
                      isDir.boolValue else {
                    // Directory was deleted while in background — clean up
                    existing.terminal.terminateAll()
                    openProjects.removeValue(forKey: canonical)
                    backgroundProjects.remove(canonical)
                    recentProjects.removeAll { $0 == canonical }
                    saveRecentProjects()
                    return nil
                }
                backgroundProjects.remove(canonical)
            }
            return existing
        }
        // Validate that the directory still exists
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: canonical.path, isDirectory: &isDir),
              isDir.boolValue else {
            recentProjects.removeAll { $0 == canonical }
            saveRecentProjects()
            return nil
        }
        let pm = ProjectManager()
        pm.workspace.loadDirectory(url: canonical)
        openProjects[canonical] = pm
        addToRecent(canonical)
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
        let canonical = url.resolvingSymlinksInPath()
        guard projectManager(for: canonical) != nil else { return nil }
        return canonical
    }

    /// Closes the project window but keeps the ProjectManager alive (preserving terminal sessions).
    /// The PM moves to `backgroundProjects` and will be reused if the project is reopened.
    func closeProjectWindow(_ url: URL) {
        let canonical = url.resolvingSymlinksInPath()
        guard openProjects[canonical] != nil else { return }
        backgroundProjects.insert(canonical)
    }

    /// Closes a project and removes it from open projects.
    /// For backwards compatibility, delegates to `closeProjectWindow`.
    func closeProject(_ url: URL) {
        closeProjectWindow(url)
    }

    /// Fully destroys all project managers. Called during app termination.
    func destroyAllProjects() {
        for (_, pm) in openProjects {
            pm.terminal.terminateAll()
        }
        openProjects.removeAll()
        backgroundProjects.removeAll()
    }

    /// Returns true if the project has an open (non-background) window.
    func isWindowOpen(_ url: URL) -> Bool {
        let canonical = url.resolvingSymlinksInPath()
        return openProjects[canonical] != nil && !backgroundProjects.contains(canonical)
    }

    /// Checks if a project is already open (including background).
    func isProjectOpen(_ url: URL) -> Bool {
        openProjects[url.resolvingSymlinksInPath()] != nil
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
