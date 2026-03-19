//
//  ProjectManager.swift
//  Pine
//
//  Created by Федор Батоногов on 10.03.2026.
//

import SwiftUI

/// Thin coordinator that owns the workspace, terminal, and tab managers.
/// Passed via environment so views can access all sub-managers.
@Observable
final class ProjectManager {
    let workspace = WorkspaceManager()
    let terminal = TerminalManager()
    let tabManager = TabManager()
    let searchProvider = ProjectSearchProvider()

    /// Persists current session (project + open file tabs) to UserDefaults.
    /// Reads from tabManager.tabs for the authoritative tab list.
    func saveSession() {
        guard let rootURL = workspace.rootURL else { return }
        let rootPath = rootURL.path + "/"

        let openFileURLs = tabManager.tabs
            .map(\.url)
            .filter { $0.path.hasPrefix(rootPath) }

        let activeFileURL = tabManager.activeTab?.url

        // Collect preview modes for markdown tabs that aren't in default (.source) state
        var previewModes: [String: String]?
        let mdTabs = tabManager.tabs.filter { $0.isMarkdownFile && $0.previewMode != .source }
        if !mdTabs.isEmpty {
            previewModes = [:]
            for tab in mdTabs {
                previewModes?[tab.url.path] = tab.previewMode.rawValue
            }
        }

        // Collect tabs with syntax highlighting disabled (large files)
        let disabledTabs = tabManager.tabs.filter(\.syntaxHighlightingDisabled)
        let highlightingDisabledPaths: [String]? = disabledTabs.isEmpty
            ? nil
            : disabledTabs.map(\.url.path)

        // Split pane state
        var splitOpenFileURLs: [URL]?
        var splitActiveFileURL: URL?
        var splitHighlightingDisabledPaths: [String]?
        var splitPreviewModes: [String: String]?

        if let splitPane = tabManager.splitPane {
            splitOpenFileURLs = splitPane.tabs
                .map(\.url)
                .filter { $0.path.hasPrefix(rootPath) }
            splitActiveFileURL = splitPane.activeTab?.url

            let splitDisabled = splitPane.tabs.filter(\.syntaxHighlightingDisabled)
            splitHighlightingDisabledPaths = splitDisabled.isEmpty
                ? nil
                : splitDisabled.map(\.url.path)

            let splitMdTabs = splitPane.tabs.filter { $0.isMarkdownFile && $0.previewMode != .source }
            if !splitMdTabs.isEmpty {
                splitPreviewModes = [:]
                for tab in splitMdTabs {
                    splitPreviewModes?[tab.url.path] = tab.previewMode.rawValue
                }
            }
        }

        // Terminal state
        let terminalTabCount = terminal.terminalTabs.count
        let activeTerminalIndex: Int? = terminal.activeTerminalID.flatMap { id in
            terminal.terminalTabs.firstIndex { $0.id == id }
        }

        SessionState.save(
            projectURL: rootURL,
            openFileURLs: openFileURLs,
            activeFileURL: activeFileURL,
            previewModes: previewModes,
            highlightingDisabledPaths: highlightingDisabledPaths,
            splitOpenFileURLs: splitOpenFileURLs,
            splitActiveFileURL: splitActiveFileURL,
            splitHighlightingDisabledPaths: splitHighlightingDisabledPaths,
            splitPreviewModes: splitPreviewModes,
            terminalTabCount: terminalTabCount,
            activeTerminalIndex: activeTerminalIndex,
            isTerminalVisible: terminal.isTerminalVisible,
            isTerminalMaximized: terminal.isTerminalMaximized
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
