//
//  SidebarFileTree.swift
//  Pine
//
//  Recursive sidebar tree rendered as a plain SwiftUI VStack. A click on
//  a folder row toggles expansion; a click on a file row selects it
//  (which the parent translates into "open tab"). See #739, #763, #778.
//

import SwiftUI

/// Sidebar row layout constants.
///
/// Centralised so row metrics stay consistent across file-leaf and folder
/// rows. Tuned to match Xcode/Zed-style compact density (#778).
enum SidebarRowMetrics {
    /// Horizontal indent applied to child rows when their parent folder is
    /// expanded. Matches the visual rhythm of a single disclosure level.
    static let childIndent: CGFloat = 14
    /// Horizontal padding around the row's background highlight.
    static let rowHorizontalPadding: CGFloat = 6
    /// Horizontal inset of the selection background relative to the row
    /// bounds so the highlight does not touch the sidebar edge.
    static let selectionHorizontalInset: CGFloat = 4
    /// Selection background corner radius.
    static let selectionCornerRadius: CGFloat = 5
    /// Selection background opacity over the accent color.
    static let selectionOpacity: Double = 0.25
    /// Minimum row height. Actual height scales with font size so larger
    /// fonts do not clip descenders.
    static let minRowHeight: CGFloat = 20
    /// Extra vertical padding added on top of the font's ascender/descender
    /// so rows stay comfortable without inflating beyond Xcode-style density.
    static let rowVerticalPadding: CGFloat = 6
}

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
            // IMPORTANT: read `expansion.isExpanded(...)` directly in the
            // view body so SwiftUI's @Observable tracker registers the
            // dependency.
            let isExpanded = expansion.isExpanded(node.url)
            VStack(alignment: .leading, spacing: 0) {
                row(isFolder: true)
                if isExpanded {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(children) { child in
                            SidebarFileTreeNode(node: child, selection: $selection)
                        }
                    }
                    .padding(.leading, SidebarRowMetrics.childIndent)
                }
            }
        } else {
            row(isFolder: false)
        }
    }

    /// Single clickable row. The whole row is hit-tested via `contentShape`
    /// and handles its own selection + folder expansion via a tap gesture.
    @ViewBuilder
    private func row(isFolder: Bool) -> some View {
        let fontSize = fontSettings.fontSize
        let isSelected = selection?.id == node.id
        let rowHeight = max(SidebarRowMetrics.minRowHeight, fontSize + SidebarRowMetrics.rowVerticalPadding)
        FileNodeRow(node: node)
            .font(.system(size: fontSize))
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: rowHeight)
            .padding(.horizontal, SidebarRowMetrics.rowHorizontalPadding)
            .background(
                RoundedRectangle(cornerRadius: SidebarRowMetrics.selectionCornerRadius, style: .continuous)
                    .fill(Color.accentColor.opacity(isSelected ? SidebarRowMetrics.selectionOpacity : 0))
                    .padding(.horizontal, SidebarRowMetrics.selectionHorizontalInset)
            )
            .contentShape(Rectangle())
            .onTapGesture {
                handleTap(isFolder: isFolder)
            }
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .id(node.id)
    }

    private var isRenamingThisNode: Bool {
        editState.renamingURL?.path == node.url.path
    }

    /// Single tap handler for both files and folders. Sets selection and
    /// (for folders) toggles expansion. Skipped while in inline rename mode
    /// so the rename text field keeps focus. The folder toggle uses a
    /// shared per-folder debounce on `SidebarExpansionState` so a real
    /// double-click expands once instead of expand-then-collapse — and
    /// because the debounce lives on the @Observable state object it
    /// survives view re-renders triggered by async git status / file
    /// watcher updates that previously reset a row-local `@State`.
    private func handleTap(isFolder: Bool) {
        guard !isRenamingThisNode else { return }
        selection = node
        if isFolder {
            expansion.toggleDebounced(node.url)
        }
    }
}
