//
//  SidebarFileTree.swift
//  Pine
//
//  Recursive sidebar tree where a click on the folder row toggles
//  expansion (in addition to clicking the disclosure chevron). See #739.
//

import SwiftUI

/// Recursive sidebar file tree built on top of `DisclosureGroup` so that the
/// expansion state is bindable. Tap on a folder row toggles expansion; tap on
/// a file row selects it (which the parent translates into "open tab").
struct SidebarFileTree: View {
    let nodes: [FileNode]
    @Binding var selection: FileNode?

    var body: some View {
        ForEach(nodes) { node in
            SidebarFileTreeNode(node: node, selection: $selection)
        }
    }
}

/// A single node row in the recursive sidebar tree.
private struct SidebarFileTreeNode: View {
    let node: FileNode
    @Binding var selection: FileNode?
    @Environment(SidebarExpansionState.self) private var expansion
    @Environment(SidebarEditState.self) private var editState

    var body: some View {
        if node.isDirectory, let children = node.optionalChildren {
            DisclosureGroup(
                isExpanded: Binding(
                    get: { expansion.isExpanded(node.url) },
                    set: { expansion.setExpanded(node.url, $0) }
                )
            ) {
                ForEach(children) { child in
                    SidebarFileTreeNode(node: child, selection: $selection)
                }
            } label: {
                folderLabel
            }
            .id(node.id)
        } else {
            FileNodeRow(node: node)
                .id(node.id)
                .contentShape(Rectangle())
                .onTapGesture {
                    handleFileTap()
                }
        }
    }

    /// Folder row body — shows the standard FileNodeRow content but expands
    /// the hit area to the full row width and toggles expansion on tap.
    @ViewBuilder
    private var folderLabel: some View {
        FileNodeRow(node: node)
            .contentShape(Rectangle())
            .onTapGesture {
                handleFolderTap()
            }
    }

    private var isRenamingThisNode: Bool {
        editState.renamingURL?.path == node.url.path
    }

    /// Tap handling for a folder row: toggle expansion unless we're in inline
    /// rename mode for this node (then the tap should be absorbed by the text
    /// field and not collapse the folder).
    private func handleFolderTap() {
        guard !isRenamingThisNode else { return }
        // Update selection to the folder so the row highlights, matching
        // what native sidebar List does on click.
        selection = node
        expansion.toggle(node.url)
    }

    /// Tap handling for a file row: just update selection. ContentView's
    /// onChange(of: selectedNode) opens the tab when a file is selected.
    private func handleFileTap() {
        guard !isRenamingThisNode else { return }
        selection = node
    }
}
