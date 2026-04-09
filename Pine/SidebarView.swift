//
//  SidebarView.swift
//  Pine
//
//  Created by Федор Батоногов on 09.03.2026.
//

import SwiftUI

// MARK: - Sidebar edit state

/// Tracks inline rename / new-item state for the sidebar file tree.
@MainActor
@Observable
final class SidebarEditState {
    var renamingURL: URL?
    var editingText: String = ""
    var isNewlyCreated: Bool = false
    /// URL of the newly created node to scroll to in the sidebar.
    var scrollToNodeID: URL?

    func startRename(for node: FileNode) {
        renamingURL = node.url
        editingText = node.name
        isNewlyCreated = false
    }

    func startNewItem(url: URL) {
        renamingURL = url
        editingText = url.lastPathComponent
        isNewlyCreated = true
    }

    func clear() {
        renamingURL = nil
        editingText = ""
        isNewlyCreated = false
    }

    /// Creates a file or folder with a unique "untitled" name, then starts inline rename.
    ///
    /// When creating a new item, undo registration is deferred to `commitRename` so that
    /// the entire create+rename sequence is undone as a single Cmd+Z action (#527).
    /// The `undoManager` is stored and used later by `commitRename`.
    func createNewItem(
        in parentURL: URL,
        isDirectory: Bool,
        workspace: WorkspaceManager,
        undoManager: UndoManager? = nil
    ) {
        if let root = workspace.rootURL, !FileNode.isWithinProjectRoot(parentURL, projectRoot: root) {
            Self.showFileError(Strings.operationOutsideProject)
            return
        }

        let baseName = isDirectory ? "untitled folder" : "untitled"
        let name = Self.uniqueName(baseName, in: parentURL)
        let newURL = parentURL.appendingPathComponent(name)

        do {
            // Do NOT register undo here — undo is deferred to commitRename so that
            // create + rename are grouped as a single undo action (#527).
            if isDirectory {
                try FileManager.default.createDirectory(at: newURL, withIntermediateDirectories: false)
            } else if !FileManager.default.createFile(atPath: newURL.path, contents: nil) {
                Self.showFileError(Strings.fileCreateError(name))
                return
            }
            workspace.refreshFileTree()
            startNewItem(url: newURL)
            scrollToNodeID = newURL
        } catch {
            Self.showFileError(error.localizedDescription)
        }
    }

    /// Duplicates a file or folder with Finder-style naming, then starts inline rename.
    func duplicateItem(
        at url: URL,
        isDirectory: Bool,
        workspace: WorkspaceManager,
        tabManager: TabManager
    ) {
        if let root = workspace.rootURL, !FileNode.isWithinProjectRoot(url, projectRoot: root) {
            Self.showFileError(Strings.operationOutsideProject)
            return
        }

        guard let copyURL = Self.finderCopyURL(for: url) else { return }

        do {
            try FileManager.default.copyItem(at: url, to: copyURL)
            workspace.refreshFileTree()
            // Start inline rename — same pattern as createNewItem.
            // isNewlyCreated is false so cancelling rename keeps the copy.
            renamingURL = copyURL
            editingText = copyURL.lastPathComponent
            isNewlyCreated = false
            scrollToNodeID = copyURL
            if !isDirectory {
                tabManager.openTab(url: copyURL)
            }
        } catch {
            Self.showFileError(error.localizedDescription)
        }
    }

    /// Returns a unique name by appending a counter if the name already exists.
    static func uniqueName(_ baseName: String, in parentURL: URL) -> String {
        FileNameGenerator.uniqueName(baseName, in: parentURL)
    }

    /// Generates a Finder-style copy URL: "name copy", "name copy 2", etc.
    static func finderCopyURL(for url: URL) -> URL? {
        FileNameGenerator.finderCopyURL(for: url)
    }

    /// Shows an AppKit error alert for file operations.
    static func showFileError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = Strings.fileOperationErrorTitle
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @Binding var selectedFile: FileNode?
    @Environment(WorkspaceManager.self) private var workspace
    @Environment(ProjectRegistry.self) private var registry
    @Environment(\.openWindow) var openWindow
    @Environment(\.undoManager) private var undoManager
    @State private var editState = SidebarEditState()
    @State private var expansion = SidebarExpansionState()

    var body: some View {
        Group {
            if workspace.rootURL == nil {
                List {
                    ContentUnavailableView {
                        Label(Strings.noFolderOpen, systemImage: "folder")
                    } description: {
                        Text(Strings.openFolderPrompt)
                    } actions: {
                        Button(Strings.openFolderButton) {
                            openNewProject()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .navigationTitle(Strings.filesTitle)
            } else if workspace.rootNodes.isEmpty && workspace.isLoading {
                List {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .listRowSeparator(.hidden)
                }
                .navigationTitle(workspace.projectName)
            } else {
                ScrollViewReader { scrollProxy in
                    // `List(selection:)` is required for the row to pick up
                    // the AppKit `selected` accessibility trait that
                    // `XCUIElement.isSelected` reads (plain
                    // `.accessibilityAddTraits(.isSelected)` only applies
                    // to the inner label, not the enclosing NSOutlineView
                    // cell that tests query for). Clicks still work
                    // because each row's `.onTapGesture` fires alongside
                    // `List`'s own row selection handling.
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            SidebarFileTree(nodes: workspace.rootNodes, selection: $selectedFile)
                        }
                        .padding(.vertical, 4)
                    }
                    .accessibilityIdentifier("sidebar")
                    .environment(editState)
                    .environment(expansion)
                    .onChange(of: workspace.rootNodes) { _, newNodes in
                        // Drop expanded entries for folders that disappeared
                        // (e.g. after delete) so the set stays bounded.
                        expansion.prune(toMatch: newNodes)
                    }
                    .onKeyPress(.return) {
                        // Finder-style: Enter on a selected sidebar item starts inline rename.
                        // No-op (and pass through) if nothing is selected or rename is already in progress.
                        guard editState.renamingURL == nil, let selected = selectedFile else {
                            return .ignored
                        }
                        editState.startRename(for: selected)
                        return .handled
                    }
                    .contextMenu {
                        if let rootURL = workspace.rootURL {
                            Button {
                                editState.createNewItem(
                                    in: rootURL,
                                    isDirectory: false,
                                    workspace: workspace,
                                    undoManager: undoManager
                                )
                            } label: {
                                Label(Strings.contextNewFile, systemImage: MenuIcons.newFile)
                            }

                            Button {
                                editState.createNewItem(
                                    in: rootURL,
                                    isDirectory: true,
                                    workspace: workspace,
                                    undoManager: undoManager
                                )
                            } label: {
                                Label(Strings.contextNewFolder, systemImage: MenuIcons.newFolder)
                            }

                            Divider()

                            Button {
                                NSWorkspace.shared.activateFileViewerSelecting([rootURL])
                            } label: {
                                Label(Strings.contextRevealInFinder, systemImage: MenuIcons.revealInFinder)
                            }
                        }
                    }
                    .navigationTitle(workspace.projectName)
                    .onChange(of: editState.renamingURL) { _, newURL in
                        if newURL != nil {
                            // Defer to avoid modifying state during view update
                            DispatchQueue.main.async {
                                selectedFile = nil
                            }
                        }
                    }
                    .onChange(of: editState.scrollToNodeID) { _, targetID in
                        guard let targetID else { return }
                        // Defer scroll to next run loop so the file tree has time to update.
                        DispatchQueue.main.async {
                            withAnimation {
                                scrollProxy.scrollTo(targetID, anchor: .center)
                            }
                            editState.scrollToNodeID = nil
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 200, idealWidth: 250)
    }

    /// Opens a new project via folder picker in a new window.
    private func openNewProject() {
        guard let url = registry.openProjectViaPanel() else { return }
        openWindow(value: url)
    }
}

// MARK: - Sidebar searchable content

/// Wrapper view that switches between file tree and search results based on query state.
/// Does not rely on `@Environment(\.isSearching)` or `isSearchPresented` because neither
/// updates reliably when text is entered via XCUITest synthetic events into `NSSearchToolbarItem`.
struct SidebarSearchableContent: View {
    @Binding var selectedNode: FileNode?
    @Environment(ProjectManager.self) private var projectManager

    var body: some View {
        if !projectManager.searchProvider.query.isEmpty {
            SearchResultsView()
        } else {
            SidebarView(selectedFile: $selectedNode)
        }
    }
}
