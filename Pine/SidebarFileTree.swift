//
//  SidebarFileTree.swift
//  Pine
//
//  Recursive sidebar tree rendered as a plain SwiftUI VStack. A click on
//  a folder row toggles expansion; a click on a file row selects it
//  (which the parent translates into "open tab"). See #739, #763, #778.
//

import AppKit
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

enum SidebarFileOpenDisposition: Equatable, Sendable {
    case transientPreview
    case permanent

    /// AppKit reports each click in a multi-click sequence immediately.
    /// Opening a preview on click one and promoting it on click two avoids
    /// delaying selection while waiting to rule out a double-click.
    static func pointerClick(count: Int) -> Self {
        count >= 2 ? .permanent : .transientPreview
    }

    /// A preview should leave keyboard focus in the sidebar so Finder-style
    /// commands such as Return-to-rename keep working. Explicit opens move
    /// focus into the editor.
    var requestsEditorFocus: Bool {
        self == .permanent
    }
}

struct SidebarFileTree: View {
    let nodes: [FileNode]
    let treeRevision: Int
    @Binding var selection: FileNode?
    let onFileOpen: (FileNode, SidebarFileOpenDisposition) -> Void
    let isKeyboardFocused: Bool
    let onKeyboardFocusRequested: () -> Void

    var body: some View {
        ForEach(nodes) { node in
            SidebarFileTreeNode(
                node: node,
                treeRevision: treeRevision,
                selection: $selection,
                onFileOpen: onFileOpen,
                isKeyboardFocused: isKeyboardFocused,
                depth: 0,
                onKeyboardFocusRequested: onKeyboardFocusRequested
            )
        }
    }
}

/// A single node row in the recursive sidebar tree.
private struct SidebarFileTreeNode: View {
    let node: FileNode
    let treeRevision: Int
    @Binding var selection: FileNode?
    let onFileOpen: (FileNode, SidebarFileOpenDisposition) -> Void
    let isKeyboardFocused: Bool
    let depth: Int
    let onKeyboardFocusRequested: () -> Void
    @Environment(SidebarExpansionState.self) private var expansion
    @Environment(SidebarEditState.self) private var editState
    @Environment(SidebarTreeNavigation.self) private var navigation
    @Environment(PaneManager.self) private var paneManager
    @State private var fontSettings = FontSizeSettings.shared
    @State private var isHovered = false
    @State private var isLoadingDeferredChildren = false
    @State private var loadedChildrenRevision = 0
    /// Monotonic generation token for in-flight deferred loads. Bumps on
    /// every load start so a result computed against a pre-refresh subtree
    /// is dropped after a refresh re-triggers the load with a fresh node
    /// (see `loadDeferredChildrenIfNeeded`). Survives URL-stable row
    /// rebuilds because SwiftUI keys `@State` by view identity, not struct.
    @State private var deferredLoadGeneration = 0

    var body: some View {
        if node.isDirectory {
            // IMPORTANT: read `expansion.isExpanded(...)` directly in the
            // view body so SwiftUI's @Observable tracker registers the
            // dependency.
            let isExpanded = expansion.isExpanded(node.url)
            let children = visibleChildren
            VStack(alignment: .leading, spacing: 0) {
                row(isFolder: true)
                if isExpanded {
                    VStack(alignment: .leading, spacing: 0) {
                        if children.isEmpty && isLoadingDeferredChildren {
                            ProgressView()
                                .controlSize(.small)
                                .padding(.leading, SidebarRowMetrics.childIndent)
                                .padding(.vertical, 2)
                        }
                        ForEach(children) { child in
                            SidebarFileTreeNode(
                                node: child,
                                treeRevision: treeRevision,
                                selection: $selection,
                                onFileOpen: onFileOpen,
                                isKeyboardFocused: isKeyboardFocused,
                                depth: depth + 1,
                                onKeyboardFocusRequested: onKeyboardFocusRequested
                            )
                        }
                    }
                    .id(children.map(\.id))
                    .padding(.leading, SidebarRowMetrics.childIndent)
                }
            }
            .onAppear {
                if isExpanded {
                    loadDeferredChildrenIfNeeded()
                }
            }
            .onChange(of: isExpanded) { _, expanded in
                if expanded {
                    loadDeferredChildrenIfNeeded()
                }
            }
            .onChange(of: treeRevision) { _, _ in
                // A refresh (FSEvents/git) replaces this row's node with a
                // new instance that is deferred again. `.onAppear` and
                // `.onChange(of: isExpanded)` do not re-fire for URL-stable
                // rows, so re-trigger the deferred load on each revision.
                // Clearing the in-flight flag first lets the load restart
                // even if a previous load (capturing the now-orphaned node)
                // is still in flight; its result is dropped by the
                // generation guard in `loadDeferredChildrenIfNeeded`.
                if isExpanded, node.hasDeferredChildren {
                    isLoadingDeferredChildren = false
                    loadDeferredChildrenIfNeeded()
                }
            }
        } else {
            row(isFolder: false)
        }
    }

    private var visibleChildren: [FileNode] {
        // Reading `loadedChildrenRevision` in the body registers the
        // `@State` dependency so a deferred-load completion re-renders the
        // row. (`treeRevision` is a plain `let` propagated by the parent's
        // struct re-evaluation — no explicit read is needed.)
        _ = loadedChildrenRevision
        return node.children ?? []
    }

    /// Single clickable row. The whole row is hit-tested via `contentShape`
    /// and handles its own selection + folder expansion via a tap gesture.
    @ViewBuilder
    private func row(isFolder: Bool) -> some View {
        let fontSize = fontSettings.fontSize
        let nodeIdentity = SidebarPathIdentity(node.url)
        let isSelected = selection.map {
            SidebarPathIdentity($0.url)
        } == nodeIdentity
        let isExpanded = isFolder && expansion.isExpanded(node.url)
        let activeTab = paneManager.activeEditorTabManager?.activeTab
        let isActiveFile = activeTab.map {
            SidebarPathIdentity($0.url)
        } == nodeIdentity
        let isTransientPreview = isActiveFile
            && (activeTab?.isTransientPreview ?? false)
        let visualState = SidebarRowVisualState(
            isSelected: isSelected,
            isKeyboardFocused: isSelected && isKeyboardFocused,
            isHovered: isHovered,
            isActiveFile: isActiveFile,
            isTransientPreview: isTransientPreview,
            isExpanded: isExpanded,
            isMissing: false
        )
        let rowHeight = max(SidebarRowMetrics.minRowHeight, fontSize + SidebarRowMetrics.rowVerticalPadding)
        let rowContent = SidebarRowChrome(
            state: visualState,
            rowHeight: rowHeight
        ) {
            FileNodeRow(
                node: node,
                isExpanded: isExpanded,
                isActiveFile: isActiveFile,
                isTransientPreview: isTransientPreview
            )
            .font(.system(size: fontSize))
        }
            .id(node.id)
            .onHover { hovering in
                isHovered = hovering
            }

        if isRenamingThisNode {
            // Keep the inline TextField as its own accessibility element.
            // Combining or replacing the row while renaming hides
            // `inlineRenameTextField` from VoiceOver and XCUITest.
            rowContent
        } else if isFolder {
            rowContent.onTapGesture {
                handleFolderTap()
            }
            .accessibilityHidden(true)
            .background {
                SidebarAccessibilityRow(
                    configuration: accessibilityConfiguration(
                        isFolder: true,
                        isExpanded: isExpanded,
                        isSelected: isSelected
                    ),
                    onPress: {
                        activateFolder(
                            debounced: false,
                            requestKeyboardFocus: true
                        )
                        return true
                    },
                    onCustomAction: {
                        setFolderExpanded(!isExpanded)
                        return true
                    }
                )
            }
        } else {
            rowContent
                .onTapGesture {
                    openFile(.pointerClick(count: NSApp.currentEvent?.clickCount ?? 1))
                }
                .accessibilityHidden(true)
                .background {
                    SidebarAccessibilityRow(
                        configuration: accessibilityConfiguration(
                            isFolder: false,
                            isExpanded: false,
                            isSelected: isSelected
                        ),
                        onPress: {
                            openFile(.permanent)
                            return true
                        },
                        onCustomAction: {
                            openFile(
                                .transientPreview,
                                requestKeyboardFocus: false
                            )
                            return true
                        }
                    )
                }
        }
    }

    private func accessibilityConfiguration(
        isFolder: Bool,
        isExpanded: Bool,
        isSelected: Bool
    ) -> SidebarAccessibilityRowConfiguration {
        SidebarAccessibilityRowConfiguration(
            label: node.name,
            identifier: AccessibilityID.fileNode(node.name),
            level: depth,
            isSelected: isSelected,
            isFocused: isSelected && isKeyboardFocused,
            isFolder: isFolder,
            isExpanded: isExpanded,
            value: isFolder
                ? (isExpanded
                    ? Strings.a11ySidebarDisclosureExpanded
                    : Strings.a11ySidebarDisclosureCollapsed)
                : nil,
            help: isFolder
                ? Strings.a11ySidebarFolderHint
                : Strings.a11ySidebarFileOpenHint,
            customActionName: isFolder
                ? (isExpanded
                    ? Strings.a11ySidebarCollapseAction
                    : Strings.a11ySidebarExpandAction)
                : Strings.a11ySidebarOpenPreview
        )
    }

    private var isRenamingThisNode: Bool {
        editState.renamingURL.map {
            SidebarPathIdentity($0)
        } == SidebarPathIdentity(node.url)
    }

    /// Single tap handler for both files and folders. Sets selection and
    /// (for folders) toggles expansion. Skipped while in inline rename mode
    /// so the rename text field keeps focus. The folder toggle uses a
    /// shared per-folder debounce on `SidebarExpansionState` so a real
    /// double-click expands once instead of expand-then-collapse — and
    /// because the debounce lives on the @Observable state object it
    /// survives view re-renders triggered by async git status / file
    /// watcher updates that previously reset a row-local `@State`.
    private func handleFolderTap() {
        guard !isRenamingThisNode else { return }
        activateFolder(debounced: true, requestKeyboardFocus: true)
    }

    private func activateFolder(
        debounced: Bool,
        requestKeyboardFocus: Bool
    ) {
        selection = node
        navigation.resetTypeAhead()
        if !expansion.isExpanded(node.url) {
            loadDeferredChildrenIfNeeded()
        }
        navigation.toggleDisclosure(
            node,
            expansion: expansion,
            debounced: debounced
        )
        if requestKeyboardFocus {
            // Queue the responder retry only after disclosure has invalidated
            // the SwiftUI tree. That makes the retry follow reconciliation
            // instead of being displaced by it on accessibility presses.
            onKeyboardFocusRequested()
        }
    }

    private func setFolderExpanded(_ expanded: Bool) {
        selection = node
        navigation.resetTypeAhead()
        if expanded {
            loadDeferredChildrenIfNeeded()
        }
        navigation.setDisclosure(
            node,
            expanded: expanded,
            expansion: expansion
        )
    }

    private func openFile(
        _ disposition: SidebarFileOpenDisposition,
        requestKeyboardFocus: Bool = true
    ) {
        guard !isRenamingThisNode else { return }
        selection = node
        navigation.resetTypeAhead()
        if disposition == .transientPreview, requestKeyboardFocus {
            onKeyboardFocusRequested()
        }
        onFileOpen(node, disposition)
    }

    private func loadDeferredChildrenIfNeeded() {
        guard node.hasDeferredChildren, !isLoadingDeferredChildren else { return }
        isLoadingDeferredChildren = true
        deferredLoadGeneration += 1
        let generation = deferredLoadGeneration
        let capturedNode = node
        Task { @MainActor in
            let loadedChildren = await Task.detached(priority: .userInitiated) {
                capturedNode.loadedChildren()
            }.value
            // Generation guard: a refresh can re-trigger this load (bumping
            // `deferredLoadGeneration`) with a fresh node instance while the
            // detached load was in flight. Drop the stale result so we never
            // apply children computed against the pre-refresh subtree. This
            // is the sidebar-local equivalent of `WorkspaceManager.loadGeneration`.
            guard generation == deferredLoadGeneration else { return }
            capturedNode.replaceChildren(loadedChildren)
            loadedChildrenRevision += 1
            isLoadingDeferredChildren = false
        }
    }
}
