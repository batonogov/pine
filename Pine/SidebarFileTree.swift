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
    @State private var fontSettings = FontSizeSettings.shared

    var body: some View {
        if node.isDirectory, let children = node.optionalChildren {
            let isExpanded = expansion.isExpanded(node.url)
            row(isFolder: true, isExpanded: isExpanded)
            if isExpanded {
                ForEach(children) { child in
                    SidebarFileTreeNode(node: child, selection: $selection)
                        .padding(.leading, fontSettings.fontSize)
                }
            }
        } else {
            row(isFolder: false, isExpanded: false)
        }
    }

    /// Single clickable row. Renders chevron for folders, then `FileNodeRow`.
    /// The whole row is hit-tested via `contentShape` and handles its own
    /// selection + folder expansion via a tap gesture. We do not rely on
    /// `List(selection:)` because the parent view uses `ScrollView` +
    /// `LazyVStack` to own click handling end-to-end (#739).
    @ViewBuilder
    private func row(isFolder: Bool, isExpanded: Bool) -> some View {
        let isSelected = selection?.url == node.url
        let fontSize = fontSettings.fontSize
        HStack(spacing: 4) {
            if isFolder {
                Image(systemName: "chevron.right")
                    .font(.system(size: max(fontSize - 3, 8), weight: .medium))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: fontSize)
            } else {
                Spacer().frame(width: fontSize)
            }
            FileNodeRow(node: node)
                .font(.system(size: fontSize))
            Spacer(minLength: 0)
        }
        .padding(.vertical, max(fontSize * 0.15, 2))
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            handleTap(isFolder: isFolder)
        }
        .id(node.id)
    }

    private var isRenamingThisNode: Bool {
        editState.renamingURL?.path == node.url.path
    }

    /// Single tap handler for both files and folders. Sets selection and
    /// (for folders) toggles expansion. Skipped while in inline rename mode
    /// so the rename text field keeps focus.
    private func handleTap(isFolder: Bool) {
        guard !isRenamingThisNode else { return }
        selection = node
        if isFolder {
            expansion.toggle(node.url)
        }
    }
}
