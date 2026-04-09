//
//  SidebarFileTree.swift
//  Pine
//
//  Recursive sidebar tree where a click on the folder row toggles
//  expansion (in addition to clicking the disclosure chevron). See #739.
//

import SwiftUI

/// Custom `DisclosureGroup` style that draws its own SwiftUI chevron and
/// hides the AppKit-native `NSOutlineViewDisclosureButton`.
///
/// Why: the promoted `NSOutlineView` inside `List` installs a native
/// disclosure button whose click state is independent from our SwiftUI
/// `isExpanded` binding. XCUITest helpers that locate disclosure triangles
/// by type would then click the native button and put the SwiftUI model
/// out of sync with the visible state. Drawing our own chevron keeps the
/// single source of truth in `SidebarExpansionState`.
private struct SidebarDisclosureGroupStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            configuration.label
                .contentShape(Rectangle())
                .onTapGesture {
                    configuration.isExpanded.toggle()
                }
            if configuration.isExpanded {
                configuration.content
                    .padding(.leading, 14)
            }
        }
    }
}

/// Recursive sidebar file tree built on top of `DisclosureGroup` so that the
/// expansion state is bindable. Tap on a folder row toggles expansion; tap on
/// a file row selects it (which the parent translates into "open tab").
///
/// Rendered inside a `List` so that AppKit promotes the host `NSTableView` to
/// `NSOutlineView` (any `DisclosureGroup` inside a `List` triggers this), which
/// makes the sidebar discoverable as `app.outlines["sidebar"]` in UI tests.
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
                    .padding(.leading, 14)
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
        FileNodeRow(node: node, isLeaf: !isFolder)
            .font(.system(size: fontSize))
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 20)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.accentColor.opacity(isSelected ? 0.25 : 0))
                    .padding(.horizontal, 4)
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
