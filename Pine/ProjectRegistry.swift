//
//  ProjectRegistry.swift
//  Pine
//
//  Created by Claude on 13.03.2026.
//

import SwiftUI

/// Manages open projects and recent project history.
/// Each project directory maps to a single ProjectManager instance.
@MainActor
@Observable
final class ProjectRegistry: LSPSettingsObserver {
    /// Open projects keyed by their root directory URL.
    private(set) var openProjects: [URL: ProjectManager] = [:]
    /// Projects whose window was closed but whose ProjectManager (and terminal processes)
    /// are kept alive. Reopening the same project returns the existing PM.
    private(set) var backgroundProjects: Set<URL> = []
    /// Project managers detached after their directory disappeared. They stay
    /// retained until user-task process cleanup completes, so a later Quit
    /// can still wait for and reap those executions.
    @ObservationIgnored
    private var detachedTaskCleanupProjects: [
        ObjectIdentifier: ProjectManager
    ] = [:]
    /// Recently opened project paths (most recent first), persisted to UserDefaults.
    var recentProjects: [URL] = []

    /// Application-wide LSP preferences shared by every project manager.
    let lspSettings: LSPSettings

    private static let recentProjectsKey = "recentProjectPaths"
    private static let maxRecentProjects = 10

    /// Serializes settings lifecycle changes so rapid Apply/Reset operations
    /// cannot race each other across projects.
    @ObservationIgnored
    private var lspSettingsChangeTask: Task<Void, Never>?

    init(lspSettings: LSPSettings = .shared) {
        self.lspSettings = lspSettings
        if CommandLine.arguments.contains("--clear-recent-projects") {
            UserDefaults.standard.removeObject(forKey: Self.recentProjectsKey)
        }
        loadRecentProjects()
        lspSettings.addObserver(self)
    }

    /// Returns the ProjectManager for a given project URL, creating one if needed.
    /// URLs are resolved to their canonical (real) path to prevent duplicates via symlinks.
    /// Returns nil if the directory no longer exists on disk.
    func projectManager(for projectURL: URL) -> ProjectManager? {
        let canonical = Self.canonicalProjectURL(projectURL)
        if let existing = openProjects[canonical] {
            // Verify directory still exists when reopening from background
            if backgroundProjects.contains(canonical) {
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: canonical.path, isDirectory: &isDir),
                      isDir.boolValue else {
                    // Directory was deleted while in background — clean up
                    existing.requestUserTaskShutdown()
                    existing.terminal.terminateAll()
                    existing.shutdownLanguageServers()
                    let ownerID = ObjectIdentifier(existing)
                    detachedTaskCleanupProjects[ownerID] = existing
                    Task { @MainActor [weak self] in
                        let didStop = await existing.shutdownUserTasks(
                            until: .now() + 2
                        )
                        if didStop {
                            self?.detachedTaskCleanupProjects.removeValue(
                                forKey: ownerID
                            )
                        }
                    }
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
        let pm = ProjectManager(lspSettings: lspSettings)
        pm.loadDirectory(url: canonical)
        openProjects[canonical] = pm
        addToRecent(canonical)
        return pm
    }

    /// Opens a project via folder picker. Returns the project URL if opened.
    @discardableResult
    func openProjectViaPanel(
        context: DialogPresentationContext
    ) async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = Strings.openPanelMessage
        panel.prompt = Strings.openPanelPrompt

        guard await panel.runSheet(on: context) == .OK,
              let url = panel.url else { return nil }
        let canonical = Self.canonicalProjectURL(url)
        guard projectManager(for: canonical) != nil else { return nil }
        return canonical
    }

    /// Closes the project window but keeps the ProjectManager alive. Terminal
    /// sessions and user tasks continue in the background; reopening the
    /// project restores access to their current state and output history.
    func closeProjectWindow(_ url: URL) {
        let canonical = Self.canonicalProjectURL(url)
        guard openProjects[canonical] != nil else { return }
        backgroundProjects.insert(canonical)
    }

    /// Closes a project and removes it from open projects.
    /// For backwards compatibility, delegates to `closeProjectWindow`.
    func closeProject(_ url: URL) {
        closeProjectWindow(url)
    }

    /// Cancels and waits for all project-owned user tasks against one shared
    /// absolute deadline. Blocking process waits happen off the main actor.
    @discardableResult
    func shutdownUserTasks(until deadline: DispatchTime) async -> Bool {
        // Snapshot before the first suspension point. Main-actor reentrancy may
        // otherwise mutate the registry while an iterator is held across an
        // `await`.
        let projectManagers = userTaskOwners
        for projectManager in projectManagers {
            projectManager.requestUserTaskShutdown()
        }
        for projectManager in projectManagers {
            _ = await projectManager.shutdownUserTasks(
                until: deadline
            )
        }

        detachedTaskCleanupProjects = detachedTaskCleanupProjects.filter {
            $0.value.hasOutstandingUserTaskExecution
        }

        // A project or task may have appeared while process waits ran off the
        // main actor. Treat that as an incomplete shutdown so Quit fails
        // closed instead of dropping its execution ownership.
        return !userTaskOwners.contains(where: {
            $0.hasOutstandingUserTaskExecution
        })
    }

    /// Fully destroys all project managers after task cleanup has completed.
    ///
    /// Fails closed instead of discarding cancellation handles if a caller
    /// attempts teardown while any user-task execution is still owned.
    @discardableResult
    func destroyAllProjects() -> Bool {
        guard !userTaskOwners.contains(where: {
            $0.hasOutstandingUserTaskExecution
        }) else {
            for projectManager in userTaskOwners {
                projectManager.requestUserTaskShutdown()
            }
            return false
        }

        lspSettingsChangeTask?.cancel()
        lspSettingsChangeTask = nil
        for (_, pm) in openProjects {
            pm.terminal.terminateAll()
            pm.shutdownLanguageServers()
        }
        openProjects.removeAll()
        backgroundProjects.removeAll()
        detachedTaskCleanupProjects.removeAll()
        return true
    }

    /// Internal lifecycle observability used by unit tests.
    var detachedUserTaskCleanupCount: Int {
        detachedTaskCleanupProjects.count
    }

    /// Returns true if the project has an open (non-background) window.
    func isWindowOpen(_ url: URL) -> Bool {
        let canonical = Self.canonicalProjectURL(url)
        return openProjects[canonical] != nil && !backgroundProjects.contains(canonical)
    }

    /// Checks if a project is already open (including background).
    func isProjectOpen(_ url: URL) -> Bool {
        openProjects[Self.canonicalProjectURL(url)] != nil
    }

    // MARK: - Language Server Settings

    func lspSettingsDidChange(_ change: LSPSettingsChange) {
        let previous = lspSettingsChangeTask
        lspSettingsChangeTask = Task { @MainActor [weak self] in
            if let previous {
                await previous.value
            }
            guard let self, !Task.isCancelled else { return }
            let projectManagers = Array(self.openProjects.values)
            for projectManager in projectManagers {
                guard !Task.isCancelled else { return }
                await projectManager.lspManager.applySettingsChange(change)
            }
        }
    }

    /// Test synchronization point for asynchronous graceful restarts.
    func waitForLSPSettingsChanges() async {
        await lspSettingsChangeTask?.value
    }

    // MARK: - Recent Projects

    /// Removes a single project from the recent projects list.
    func removeFromRecent(_ url: URL) {
        recentProjects.removeAll { $0 == url }
        saveRecentProjects()
    }

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

    /// Resolves a stable project identity even after the project directory is
    /// deleted. `resolvingSymlinksInPath()` requires the path to exist before
    /// it reliably resolves prefix symlinks such as `/var` → `/private/var`.
    /// Resolve the nearest existing ancestor, then append every missing
    /// component to preserve the key previously stored in `openProjects`.
    nonisolated static func canonicalProjectURL(_ projectURL: URL) -> URL {
        let standardized = projectURL.standardizedFileURL
        var existingAncestor = standardized
        var missingComponents: [String] = []

        while !FileManager.default.fileExists(
            atPath: existingAncestor.path
        ) {
            let parent = existingAncestor.deletingLastPathComponent()
            guard parent.path != existingAncestor.path else { break }
            missingComponents.append(existingAncestor.lastPathComponent)
            existingAncestor = parent
        }

        var canonical = existingAncestor.resolvingSymlinksInPath()
        for component in missingComponents.reversed() {
            canonical.appendPathComponent(component)
        }
        return URL(
            fileURLWithPath: canonical.path,
            isDirectory: true
        ).standardizedFileURL
    }

    private var userTaskOwners: [ProjectManager] {
        var owners: [ObjectIdentifier: ProjectManager] =
            detachedTaskCleanupProjects
        for projectManager in openProjects.values {
            owners[ObjectIdentifier(projectManager)] = projectManager
        }
        return Array(owners.values)
    }
}
