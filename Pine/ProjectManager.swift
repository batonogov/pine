//
//  ProjectManager.swift
//  Pine
//
//  Created by Федор Батоногов on 10.03.2026.
//

import SwiftUI

/// Thin coordinator that owns the workspace and terminal managers.
/// Passed via environment so views can access both sub-managers.
@Observable
final class ProjectManager {
    let workspace = WorkspaceManager()
    let terminal = TerminalManager()

    /// Persists current session (project + open file tabs) to UserDefaults.
    /// Collects from all tab groups via tabbedWindows to preserve tab strip order.
    /// Only includes file URLs that live under the current project root.
    func saveSession() {
        guard let rootURL = workspace.rootURL else { return }
        let rootPath = rootURL.path + "/"

        // Use tabGroup.windows for authoritative visual tab order.
        // tabbedWindows returns nil when the tab bar is hidden (NSWindow.h:714),
        // but tabGroup.windows always reflects the correct order.
        // The seen set deduplicates across groups.
        var openFileURLs: [URL] = []
        var seen = Set<String>()
        for window in NSApplication.shared.windows
            where window.tabbingIdentifier == AppDelegate.editorTabbingID {
            let orderedTabs = window.tabGroup?.windows ?? [window]
            for tab in orderedTabs {
                guard let url = tab.representedURL,
                      url.path.hasPrefix(rootPath),
                      !seen.contains(url.path) else { continue }
                seen.insert(url.path)
                openFileURLs.append(url)
            }
        }

        let activeFileURL = NSApp.keyWindow?.representedURL
        SessionState.save(
            projectURL: rootURL,
            openFileURLs: openFileURLs,
            activeFileURL: activeFileURL
        )
    }

    // MARK: - Convenience accessors (workspace)

    var rootNodes: [FileNode] { workspace.rootNodes }
    var projectName: String { workspace.projectName }
    var rootURL: URL? { workspace.rootURL }
    var gitProvider: GitStatusProvider { workspace.gitProvider }

    func openFolder() { workspace.openFolder() }
    func loadDirectory(url: URL) { workspace.loadDirectory(url: url) }

    // MARK: - Convenience accessors (terminal)

    var isTerminalVisible: Bool {
        get { terminal.isTerminalVisible }
        set { terminal.isTerminalVisible = newValue }
    }

    var isTerminalMaximized: Bool {
        get { terminal.isTerminalMaximized }
        set { terminal.isTerminalMaximized = newValue }
    }

    var terminalTabs: [TerminalTab] { terminal.terminalTabs }
    var activeTerminalID: UUID? {
        get { terminal.activeTerminalID }
        set { terminal.activeTerminalID = newValue }
    }
    var activeTerminalTab: TerminalTab? { terminal.activeTerminalTab }

    func startTerminals() { terminal.startTerminals(workingDirectory: workspace.rootURL) }
    func addTerminalTab() { terminal.addTerminalTab(workingDirectory: workspace.rootURL) }
    func closeTerminalTab(_ tab: TerminalTab) { terminal.closeTerminalTab(tab) }
}
