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
    /// Timestamp of the last accepted tap on this folder. Used to debounce a
    /// real double-click into a single expand action so synthesised
    /// `XCUIElement.doubleClick()` (used by some UI tests as a reliable
    /// expansion shortcut) does not immediately collapse the folder again.
    @State private var lastTapTimestamp: TimeInterval = 0

    var body: some View {
        if node.isDirectory, let children = node.optionalChildren {
            let bindingExpanded = Binding<Bool>(
                get: { expansion.isExpanded(node.url) },
                set: { expansion.setExpanded(node.url, $0) }
            )
            DisclosureGroup(isExpanded: bindingExpanded) {
                ForEach(children) { child in
                    SidebarFileTreeNode(node: child, selection: $selection)
                }
            } label: {
                row(isFolder: true)
            }
        } else {
            row(isFolder: false)
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
    /// so the rename text field keeps focus. A short debounce prevents
    /// `doubleClick()` from immediately collapsing a freshly expanded folder.
    private func handleTap(isFolder: Bool) {
        guard !isRenamingThisNode else { return }
        let now = Date().timeIntervalSinceReferenceDate
        if isFolder, now - lastTapTimestamp < 0.4 {
            // Treat the second click of a double-click as a no-op so that
            // expanding a folder via double-click leaves it expanded.
            return
        }
        lastTapTimestamp = now
        selection = node
        if isFolder {
            expansion.toggle(node.url)
        }
    }
}
