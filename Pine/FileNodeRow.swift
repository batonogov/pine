//
//  FileNodeRow.swift
//  Pine
//
//  Created by Федор Батоногов on 09.03.2026.
//

import os
import SwiftUI

// MARK: - File/folder row in the sidebar tree

struct FileNodeRow: View {
    private static let logger = Logger.editor
    var node: FileNode
    @Environment(WorkspaceManager.self) var workspace
    @Environment(TabManager.self) var tabManager
    @Environment(PaneManager.self) var paneManager
    @Environment(SidebarEditState.self) var editState
    @Environment(\.undoManager) private var undoManager
    @FocusState private var isTextFieldFocused: Bool

    private var isEditing: Bool {
        guard let renamingURL = editState.renamingURL else { return false }
        // Compare by path to ignore trailing-slash differences between
        // URLs built via appendingPathComponent (no slash) and URLs
        // returned by contentsOfDirectory (trailing slash for directories).
        return renamingURL.path == node.url.path
    }

    private var gitStatus: GitFileStatus? {
        let provider = workspace.gitProvider
        return node.isDirectory
            ? provider.statusForDirectory(at: node.url)
            : provider.statusForFile(at: node.url)
    }

    private var isGitIgnored: Bool {
        workspace.gitProvider.isIgnored(at: node.url)
    }

    private var iconName: String {
        node.isDirectory
            ? FileIconMapper.iconForFolder(node.name)
            : FileIconMapper.iconForFile(node.name)
    }

    private var iconColor: Color {
        node.isDirectory
            ? FileIconMapper.colorForFolder(node.name)
            : FileIconMapper.colorForFile(node.name)
    }

    var body: some View {
        Group {
            if isEditing {
                inlineEditor
            } else {
                Label {
                    Text(node.name)
                        .foregroundStyle(gitStatus?.color ?? .primary)
                } icon: {
                    Image(systemName: iconName)
                        .foregroundStyle(iconColor)
                }
                .opacity(isGitIgnored ? 0.5 : 1.0)
                // Apply the row identifier only on the non-editing branch.
                // Applying it on the outer Group would cascade onto the
                // inline rename TextField and shadow its own
                // `inlineRenameTextField` identifier in the accessibility
                // tree, breaking UI tests that look up the editor by id.
                .accessibilityIdentifier(AccessibilityID.fileNode(node.name))
            }
        }
        .tag(node)
        .contextMenu { fileNodeContextMenu }
        .draggable(SidebarFileDragInfo(fileURL: node.url)) {
            sidebarDragPreview()
        }
    }

    // MARK: - Drag support

    /// Drag preview label shown while dragging.
    @ViewBuilder
    private func sidebarDragPreview() -> some View {
        Label(node.name, systemImage: iconName)
            .font(.body)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Inline editor

    @ViewBuilder
    private var inlineEditor: some View {
        @Bindable var state = editState
        // Use Label (same structure as the non-editing branch) so SwiftUI's
        // List/OutlineGroup applies identical leading insets and the row does
        // not visually jump on commit. See #736.
        Label {
            TextField("", text: $state.editingText)
                .textFieldStyle(.plain)
                .accessibilityIdentifier(AccessibilityID.inlineRenameTextField)
                .onSubmit { commitRename() }
                .onExitCommand { cancelRename() }
                .focused($isTextFieldFocused)
                .onAppear {
                    DispatchQueue.main.async {
                        isTextFieldFocused = true
                        // Finder-style stem selection: select only the part of the
                        // name before the extension so the user can retype the stem
                        // without re-typing the extension. The field editor (NSTextView)
                        // is created asynchronously by AppKit after focus is set, so
                        // we retry up to 3 runloop ticks until firstResponder becomes
                        // a NSTextView.
                        applyStemSelectionWithRetry(remaining: 3)
                    }
                }
                .onChange(of: isTextFieldFocused) { _, focused in
                    // Guard against double-commit: onSubmit clears editState,
                    // then focus loss fires — skip if already committed.
                    guard !focused, editState.renamingURL?.path == node.url.path else { return }
                    commitRename()
                }
        } icon: {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
        }
    }

    // MARK: - Context menu

    @ViewBuilder
    private var fileNodeContextMenu: some View {
        if node.isDirectory {
            Button {
                createNewItem(isDirectory: false)
            } label: {
                Label(Strings.contextNewFile, systemImage: MenuIcons.newFile)
            }

            Button {
                createNewItem(isDirectory: true)
            } label: {
                Label(Strings.contextNewFolder, systemImage: MenuIcons.newFolder)
            }

            Divider()
        }

        Button {
            duplicateItem()
        } label: {
            Label(Strings.contextDuplicate, systemImage: MenuIcons.duplicate)
        }

        Button {
            editState.startRename(for: node)
        } label: {
            Label(Strings.contextRename, systemImage: MenuIcons.rename)
        }

        Button(role: .destructive) {
            deleteItem()
        } label: {
            Label(Strings.contextDelete, systemImage: MenuIcons.delete)
        }

        Divider()

        Button {
            NSWorkspace.shared.activateFileViewerSelecting([node.url])
        } label: {
            Label(Strings.contextRevealInFinder, systemImage: MenuIcons.revealInFinder)
        }
    }

    // MARK: - File operations

    private func createNewItem(isDirectory: Bool) {
        editState.createNewItem(
            in: node.url,
            isDirectory: isDirectory,
            workspace: workspace,
            undoManager: undoManager
        )
    }

    private func duplicateItem() {
        editState.duplicateItem(
            at: node.url,
            isDirectory: node.isDirectory,
            workspace: workspace,
            tabManager: tabManager
        )
    }

    /// Selects the stem (name without extension) in the rename text field, Finder-style.
    /// Retries up to `remaining` runloop ticks because AppKit creates the field
    /// editor asynchronously after focus is set, so the first attempt may not yet
    /// see an NSTextView as firstResponder.
    private func applyStemSelectionWithRetry(remaining: Int) {
        if let window = NSApp.keyWindow ?? NSApp.mainWindow,
           let editor = window.firstResponder as? NSTextView {
            let range = SidebarRenameStem.stemRange(
                for: editState.editingText, isDirectory: node.isDirectory
            )
            editor.selectedRange = range
            return
        }
        guard remaining > 0 else { return }
        DispatchQueue.main.async {
            applyStemSelectionWithRetry(remaining: remaining - 1)
        }
    }

    /// Returns the set of sibling names in the parent directory (excluding `oldURL` itself).
    private func siblingNames(of oldURL: URL) -> Set<String> {
        let parent = oldURL.deletingLastPathComponent()
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
        var names = Set(contents)
        names.remove(oldURL.lastPathComponent)
        return names
    }

    private func commitRename() {
        guard editState.renamingURL?.path == node.url.path else { return }

        let oldURL = node.url
        let rawName = editState.editingText
        let newName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)

        // Validate before touching disk. Empty name = cancel (Finder behavior).
        if newName.isEmpty {
            cancelRename()
            return
        }
        if let validationError = SidebarRenameStem.validationError(
            for: newName,
            oldURL: oldURL,
            existingNames: siblingNames(of: oldURL)
        ) {
            SidebarEditState.showFileError(validationError)
            return
        }

        let newURL = oldURL.deletingLastPathComponent().appendingPathComponent(newName)

        if let root = workspace.rootURL,
           !FileNode.isWithinProjectRoot(oldURL, projectRoot: root)
            || !FileNode.isWithinProjectRoot(newURL, projectRoot: root) {
            SidebarEditState.showFileError(Strings.operationOutsideProject)
            editState.clear()
            return
        }
        let wasNewlyCreated = editState.isNewlyCreated

        // Name unchanged — accept as-is
        if newURL == oldURL {
            editState.clear()
            // For newly created items, register a single undo that deletes the file (#527)
            if wasNewlyCreated, let undoManager {
                try? FileOperationUndoManager.finalizeNewItem(from: oldURL, to: oldURL, undoManager: undoManager)
            }
            if wasNewlyCreated && !node.isDirectory {
                tabManager.openTab(url: oldURL)
            }
            return
        }

        do {
            if wasNewlyCreated {
                // For newly created items: finalizeNewItem renames and registers
                // a single undo that deletes the final file — so Cmd+Z removes it entirely (#527).
                if let undoManager {
                    try FileOperationUndoManager.finalizeNewItem(from: oldURL, to: newURL, undoManager: undoManager)
                } else {
                    try FileManager.default.moveItem(at: oldURL, to: newURL)
                }
            } else if let undoManager {
                try FileOperationUndoManager.renameItem(from: oldURL, to: newURL, undoManager: undoManager)
            } else {
                try FileManager.default.moveItem(at: oldURL, to: newURL)
            }
            editState.clear()
            workspace.refreshFileTree()
            NotificationCenter.default.post(
                name: .fileRenamed,
                object: nil,
                userInfo: ["oldURL": oldURL, "newURL": newURL]
            )
            // Auto-open newly created files in an editor tab
            if wasNewlyCreated && !node.isDirectory {
                tabManager.openTab(url: newURL)
            }
        } catch {
            // Keep editing so the user can try a different name
            SidebarEditState.showFileError(error.localizedDescription)
        }
    }

    private func cancelRename() {
        let wasNewlyCreated = editState.isNewlyCreated
        let url = editState.renamingURL
        editState.clear()

        // Delete placeholder item if creation was cancelled
        if wasNewlyCreated, let url {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                Self.logger.error("Failed to delete placeholder item \(url.lastPathComponent): \(error)")
            }
            workspace.refreshFileTree()
        }
    }

    private func deleteItem() {
        let deletedURL = node.url

        if let root = workspace.rootURL, !FileNode.isWithinProjectRoot(deletedURL, projectRoot: root) {
            SidebarEditState.showFileError(Strings.operationOutsideProject)
            return
        }

        do {
            if let undoManager {
                try FileOperationUndoManager.deleteItem(at: deletedURL, undoManager: undoManager)
            } else {
                try FileManager.default.trashItem(at: deletedURL, resultingItemURL: nil)
            }
            workspace.refreshFileTree()
            NotificationCenter.default.post(
                name: .fileDeleted,
                object: nil,
                userInfo: ["url": deletedURL]
            )
        } catch {
            SidebarEditState.showFileError(error.localizedDescription)
        }
    }
}
