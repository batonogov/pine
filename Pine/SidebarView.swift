//
//  SidebarView.swift
//  Pine
//
//  Created by Федор Батоногов on 09.03.2026.
//

import AppKit
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
        AlertTemplate.fileOperationErrorWarning.runModal(
            messageText: Strings.fileOperationErrorTitle,
            informativeText: message
        )
    }
}

// MARK: - Sidebar keyboard focus

/// Owns the AppKit responder used by the plain ScrollView file tree.
///
/// `ScrollView.focusable()` is still useful for keyboard traversal, but a
/// mouse click on one of its gesture-driven rows does not reliably make the
/// SwiftUI key handler first responder. Keeping a real NSView target gives
/// row clicks the same synchronous responder semantics as NSOutlineView.
@MainActor
final class SidebarKeyboardFocusController {
    private weak var responderView: SidebarKeyboardResponderView?

    func attach(_ responderView: SidebarKeyboardResponderView) {
        self.responderView = responderView
    }

    @discardableResult
    func requestFocus() -> Bool {
        guard let responderView, let window = responderView.window else {
            return false
        }
        return window.makeFirstResponder(responderView)
            && window.firstResponder === responderView
    }
}

/// Prevents a newly-created preview editor from displacing the sidebar while
/// preserving implicit initial focus for non-sidebar open paths.
enum SidebarKeyboardFocusPolicy {
    static func allowsEditorInitialFocus(
        tabID: UUID,
        pendingFocusTabID: UUID?,
        firstResponder: NSResponder?
    ) -> Bool {
        pendingFocusTabID == tabID
            || !(firstResponder is SidebarKeyboardResponderView)
    }
}

/// Invisible responder embedded in the sidebar hierarchy.
@MainActor
final class SidebarKeyboardResponderView: NSView {
    var onKeyDown: ((NSEvent) -> Bool)?

    override var acceptsFirstResponder: Bool { true }

    /// The responder is focused programmatically by a row click and must not
    /// intercept pointer hit testing itself.
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) == true {
            return
        }
        super.keyDown(with: event)
    }
}

/// Keeps the AppKit responder attached to SwiftUI's sidebar lifecycle.
struct SidebarKeyboardFocusBridge: NSViewRepresentable {
    let controller: SidebarKeyboardFocusController
    let onKeyDown: (NSEvent) -> Bool

    func makeNSView(context: Context) -> SidebarKeyboardResponderView {
        let view = SidebarKeyboardResponderView()
        view.onKeyDown = onKeyDown
        controller.attach(view)
        return view
    }

    func updateNSView(_ nsView: SidebarKeyboardResponderView, context: Context) {
        nsView.onKeyDown = onKeyDown
        controller.attach(nsView)
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @Binding var selectedFile: FileNode?
    let onFileOpen: (FileNode, SidebarFileOpenDisposition) -> Void
    @Environment(WorkspaceManager.self) private var workspace
    @Environment(ProjectRegistry.self) private var registry
    @Environment(\.openWindow) var openWindow
    @Environment(\.undoManager) private var undoManager
    @State private var editState = SidebarEditState()
    @State private var expansion = SidebarExpansionState()
    @State private var keyboardFocusController = SidebarKeyboardFocusController()

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
                    // Plain `ScrollView + VStack` instead of `List(.sidebar)`:
                    // SwiftUI's sidebar List enforces a minimum row height
                    // via NSOutlineView that could not be overridden to
                    // reach Xcode/Zed-style compact density (#778). Rows
                    // are content-sized and handle their own selection,
                    // tap, and context-menu via `FileNodeRow` +
                    // `SidebarFileTree.row`.
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            SidebarFileTree(
                                nodes: workspace.rootNodes,
                                treeRevision: workspace.rootNodesRevision,
                                selection: $selectedFile,
                                onFileOpen: onFileOpen,
                                onKeyboardFocusRequested: {
                                    keyboardFocusController.requestFocus()
                                }
                            )
                        }
                        .padding(.vertical, 4)
                    }
                    .accessibilityIdentifier("sidebar")
                    .background(alignment: .topLeading) {
                        SidebarKeyboardFocusBridge(
                            controller: keyboardFocusController,
                            onKeyDown: handleSidebarKeyDown
                        )
                        .frame(width: 1, height: 1)
                    }
                    .focusable()
                    .environment(editState)
                    .environment(expansion)
                    .onChange(of: workspace.rootNodesRevision) { _, _ in
                        // Drop expanded entries for folders that disappeared
                        // (e.g. after delete) so the set stays bounded.
                        expansion.prune(toMatch: workspace.rootNodes)
                    }
                    .onKeyPress(.return, phases: .down) { press in
                        handleSidebarReturn(
                            commandPressed: press.modifiers.contains(.command),
                            hasAnyModifiers: !press.modifiers.isEmpty
                        ) ? .handled : .ignored
                    }
                    .onKeyPress(.space) {
                        handleSidebarSpace() ? .handled : .ignored
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
                            .accessibilityIdentifier(AccessibilityID.contextMenuNewFile)

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
                            .accessibilityIdentifier(AccessibilityID.contextMenuNewFolder)

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

    /// Handles real AppKit events when the sidebar was focused by a row click.
    private func handleSidebarKeyDown(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 36, 76: // Return and keypad Enter
            let modifiers = event.modifierFlags.intersection([
                .command, .option, .control, .shift
            ])
            return handleSidebarReturn(
                commandPressed: modifiers.contains(.command),
                hasAnyModifiers: !modifiers.isEmpty
            )
        case 49: // Space
            return handleSidebarSpace()
        default:
            return false
        }
    }

    /// Finder-style Return: rename in place. Command-Return is an explicit
    /// open and moves focus into the editor.
    private func handleSidebarReturn(
        commandPressed: Bool,
        hasAnyModifiers: Bool
    ) -> Bool {
        if commandPressed,
           let selected = selectedFile,
           !selected.isDirectory {
            onFileOpen(selected, .permanent)
            return true
        }
        guard !hasAnyModifiers,
              editState.renamingURL == nil,
              let selected = selectedFile else {
            return false
        }
        editState.startRename(for: selected)
        return true
    }

    private func handleSidebarSpace() -> Bool {
        guard let selected = selectedFile, !selected.isDirectory else {
            return false
        }
        onFileOpen(selected, .transientPreview)
        // Space can arrive through SwiftUI's keyboard-focus path rather than
        // the AppKit bridge. Normalize both paths to the real sidebar
        // responder before a newly-created preview gets initial focus.
        keyboardFocusController.requestFocus()
        return true
    }
}

// MARK: - Sidebar searchable content

/// Wrapper view that switches between file tree and search results based on query state.
/// Does not rely on `@Environment(\.isSearching)` or `isSearchPresented` because neither
/// updates reliably when text is entered via XCUITest synthetic events into `NSSearchToolbarItem`.
struct SidebarSearchableContent: View {
    @Binding var selectedNode: FileNode?
    let onFileOpen: (FileNode, SidebarFileOpenDisposition) -> Void
    @Environment(ProjectManager.self) private var projectManager

    var body: some View {
        Group {
            if !projectManager.searchProvider.query.isEmpty {
                SearchResultsView()
            } else {
                SidebarView(
                    selectedFile: $selectedNode,
                    onFileOpen: onFileOpen
                )
            }
        }
        .onKeyPress(.escape) {
            // Escape clears the search query and returns to the file tree.
            if !projectManager.searchProvider.query.isEmpty {
                projectManager.searchProvider.query = ""
                projectManager.searchProvider.cancel()
                return .handled
            }
            return .ignored
        }
    }
}
