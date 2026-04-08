//
//  SidebarFileTree.swift
//  Pine
//
//  Recursive sidebar tree where a click on the folder row toggles
//  expansion (in addition to clicking the disclosure chevron). See #739.
//

import SwiftUI

/// Shared geometry for the sidebar disclosure chevron. This is the single
/// source of truth used by both `SidebarDisclosureGroupStyle` (which draws
/// the chevron in front of folder rows) and `SidebarFileTreeNode`'s
/// file-leaf branch (which inserts a transparent spacer of the same size
/// so file-leaf icons line up with folder icons at the same depth). See
/// issue #769 — before extracting these constants the two call sites drifted
/// and file rows rendered ~12pt to the left of sibling folder rows.
enum SidebarDisclosureMetrics {
    /// Width reserved for the chevron glyph itself.
    static let chevronWidth: CGFloat = 10
    /// Horizontal spacing between the chevron (or its spacer) and the row label.
    static let chevronSpacing: CGFloat = 2
}

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
            HStack(spacing: SidebarDisclosureMetrics.chevronSpacing) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                    .frame(width: SidebarDisclosureMetrics.chevronWidth)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        configuration.isExpanded.toggle()
                    }
                configuration.label
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
            // dependency. Accessing it only from inside the Binding's
            // `get` closure below is NOT enough — the closure runs later,
            // outside of body evaluation, so the view never re-renders
            // when `expandedPaths` mutates.
            let isExpanded = expansion.isExpanded(node.url)
            let bindingExpanded = Binding<Bool>(
                get: { isExpanded },
                set: { expansion.setExpanded(node.url, $0) }
            )
            DisclosureGroup(isExpanded: bindingExpanded) {
                ForEach(children) { child in
                    SidebarFileTreeNode(node: child, selection: $selection)
                }
            } label: {
                row(isFolder: true)
            }
            .disclosureGroupStyle(SidebarDisclosureGroupStyle())
        } else {
            // Insert a chevron-shaped transparent spacer so the file-leaf
            // icon lines up with sibling folder icons (which are pushed
            // right by the chevron drawn in `SidebarDisclosureGroupStyle`).
            // Both dimensions come from `SidebarDisclosureMetrics` so the
            // two call sites can never drift again. See #769.
            HStack(spacing: SidebarDisclosureMetrics.chevronSpacing) {
                Color.clear.frame(width: SidebarDisclosureMetrics.chevronWidth)
                row(isFolder: false)
            }
        }
    }

    /// Single clickable row. The whole row is hit-tested via `contentShape`
    /// and handles its own selection + folder expansion via a tap gesture.
    @ViewBuilder
    private func row(isFolder: Bool) -> some View {
        let isSelected = selection?.url == node.url
        let fontSize = fontSettings.fontSize
        FileNodeRow(node: node)
            .font(.system(size: fontSize))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, max(fontSize * 0.15, 2))
            .padding(.horizontal, 4)
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
