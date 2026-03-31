//
//  PaneTreeView.swift
//  Pine
//
//  Recursive SwiftUI view that renders a PaneNode tree as split editor panes.
//  Each leaf renders its own EditorAreaView with its own TabManager.
//

import SwiftUI
import UniformTypeIdentifiers

// MARK: - Pane Tree View

/// Recursively renders the PaneNode tree as nested split views.
struct PaneTreeView: View {
    let node: PaneNode
    @Environment(PaneManager.self) private var paneManager

    var body: some View {
        switch node {
        case .leaf(let paneID, _):
            PaneLeafView(paneID: paneID)

        case .split(let axis, let first, let second, let ratio):
            PaneSplitView(
                axis: axis,
                first: first,
                second: second,
                ratio: ratio
            )
        }
    }
}

// MARK: - Split View with Divider

/// A split view that renders two child nodes with a draggable divider.
struct PaneSplitView: View {
    let axis: SplitAxis
    let first: PaneNode
    let second: PaneNode
    let ratio: CGFloat

    @Environment(PaneManager.self) private var paneManager
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            let totalSize = axis == .horizontal ? geometry.size.width : geometry.size.height
            let dividerThickness: CGFloat = PaneDividerView.thickness
            let usableSize = totalSize - dividerThickness
            let firstSize = usableSize * ratio + dragOffset
            let clampedFirstSize = min(max(firstSize, usableSize * 0.1), usableSize * 0.9)

            if axis == .horizontal {
                HStack(spacing: 0) {
                    PaneTreeView(node: first)
                        .frame(width: clampedFirstSize)

                    PaneDividerView(
                        axis: axis,
                        onDrag: { offset in
                            dragOffset = offset
                        },
                        onDragEnd: {
                            let newRatio = clampedFirstSize / usableSize
                            applyRatio(newRatio)
                            dragOffset = 0
                        }
                    )

                    PaneTreeView(node: second)
                        .frame(maxWidth: .infinity)
                }
            } else {
                VStack(spacing: 0) {
                    PaneTreeView(node: first)
                        .frame(height: clampedFirstSize)

                    PaneDividerView(
                        axis: axis,
                        onDrag: { offset in
                            dragOffset = offset
                        },
                        onDragEnd: {
                            let newRatio = clampedFirstSize / usableSize
                            applyRatio(newRatio)
                            dragOffset = 0
                        }
                    )

                    PaneTreeView(node: second)
                        .frame(maxHeight: .infinity)
                }
            }
        }
    }

    private func applyRatio(_ newRatio: CGFloat) {
        // Find any leaf in the second subtree and update via its parent
        if let secondLeafID = second.firstLeafID {
            paneManager.updateRatio(for: secondLeafID, ratio: newRatio)
        }
    }
}

// MARK: - Divider

/// A draggable divider between two panes.
struct PaneDividerView: View {
    let axis: SplitAxis
    var onDrag: (CGFloat) -> Void
    var onDragEnd: () -> Void

    /// Visual thickness of the divider line.
    static let thickness: CGFloat = 1

    /// Hit target width for easier grabbing.
    private static let hitTarget: CGFloat = 8

    @State private var isHovering = false
    @State private var isCursorPushed = false

    var body: some View {
        Rectangle()
            .fill(isHovering ? Color.accentColor : Color(nsColor: .separatorColor))
            .frame(
                width: axis == .horizontal ? Self.thickness : nil,
                height: axis == .vertical ? Self.thickness : nil
            )
            .contentShape(Rectangle().size(
                width: axis == .horizontal ? Self.hitTarget : 10_000,
                height: axis == .vertical ? Self.hitTarget : 10_000
            ))
            .onHover { isHovering = $0 }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let offset = axis == .horizontal
                            ? value.translation.width
                            : value.translation.height
                        onDrag(offset)
                    }
                    .onEnded { _ in
                        onDragEnd()
                    }
            )
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    guard !isCursorPushed else { return }
                    isCursorPushed = true
                    if axis == .horizontal {
                        NSCursor.resizeLeftRight.push()
                    } else {
                        NSCursor.resizeUpDown.push()
                    }
                case .ended:
                    guard isCursorPushed else { return }
                    isCursorPushed = false
                    NSCursor.pop()
                }
            }
            .onDisappear {
                if isCursorPushed {
                    NSCursor.pop()
                    isCursorPushed = false
                }
            }
            .accessibilityIdentifier(AccessibilityID.paneDivider)
    }
}

// MARK: - Leaf View

/// A single leaf pane showing the editor area with its own tab bar.
struct PaneLeafView: View {
    let paneID: PaneID
    @Environment(PaneManager.self) private var paneManager
    @Environment(WorkspaceManager.self) private var workspace
    @Environment(ProjectManager.self) private var projectManager
    @Environment(ProjectRegistry.self) private var registry
    @Environment(\.openWindow) private var openWindow

    @State private var lineDiffs: [GitLineDiff] = []
    @State private var isDragTargeted = false
    @State private var goToLineOffset: GoToRequest?
    @State private var dropZone: PaneDropZone?
    @State private var paneSize: CGSize = .zero

    @AppStorage("minimapVisible") private var isMinimapVisible = true
    @AppStorage(BlameConstants.storageKey) private var isBlameVisible = true
    @AppStorage("wordWrapEnabled") private var isWordWrapEnabled = true

    private var tabManager: TabManager? { paneManager.tabManager(for: paneID) }
    private var isActive: Bool { paneManager.activePaneID == paneID }

    var body: some View {
        if let tabManager {
            paneContent(tabManager: tabManager)
                .environment(tabManager)
                .onTapGesture {
                    paneManager.activePaneID = paneID
                }
                .overlay {
                    GeometryReader { geometry in
                        Color.clear
                            .preference(key: PaneSizePreferenceKey.self, value: geometry.size)
                    }
                }
                .onPreferenceChange(PaneSizePreferenceKey.self) { paneSize = $0 }
                .overlay {
                    PaneDropOverlay(dropZone: dropZone)
                }
                .onDrop(of: [.paneTabDrag], delegate: PaneSplitDropDelegate(
                    paneID: paneID,
                    paneManager: paneManager,
                    paneSize: paneSize,
                    dropZone: $dropZone
                ))
                .border(
                    isActive && paneManager.root.leafCount > 1
                        ? Color.accentColor.opacity(0.5)
                        : Color.clear,
                    width: 1
                )
                .accessibilityIdentifier(AccessibilityID.paneLeaf(paneID.id.uuidString))
        }
    }

    @ViewBuilder
    private func paneContent(tabManager: TabManager) -> some View {
        VStack(spacing: 0) {
            if !tabManager.tabs.isEmpty {
                EditorTabBar(
                    tabManager: tabManager,
                    onCloseTab: { tab in
                        tabManager.closeTab(id: tab.id, force: false)
                        if tabManager.tabs.isEmpty {
                            paneManager.removePane(paneID)
                        }
                    },
                    overridePaneID: paneID
                )
            }

            if let tab = tabManager.activeTab, let rootURL = workspace.rootURL {
                BreadcrumbPathBar(
                    fileURL: tab.url,
                    projectRoot: rootURL,
                    onOpenFile: { url in tabManager.openTab(url: url) }
                )
            }

            if let tab = tabManager.activeTab {
                codeEditorView(for: tab, tabManager: tabManager)
            } else {
                ContentUnavailableView {
                    Label(Strings.noFileSelected, systemImage: "doc.text")
                } description: {
                    Text(Strings.selectFilePrompt)
                }
                .accessibilityIdentifier(AccessibilityID.editorPlaceholder)
            }
        }
    }

    @ViewBuilder
    private func codeEditorView(for tab: EditorTab, tabManager: TabManager) -> some View {
        CodeEditorView(
            text: Binding(
                get: { tab.content },
                set: { tabManager.updateContent($0) }
            ),
            contentVersion: tab.contentVersion,
            language: tab.language,
            fileName: tab.fileName,
            lineDiffs: lineDiffs,
            isBlameVisible: isBlameVisible,
            blameLines: [],
            foldState: Binding(
                get: { tab.foldState },
                set: { tabManager.updateFoldState($0) }
            ),
            isMinimapVisible: isMinimapVisible,
            isWordWrapEnabled: isWordWrapEnabled,
            syntaxHighlightingDisabled: tab.syntaxHighlightingDisabled,
            initialCursorPosition: goToLineOffset?.offset ?? tab.cursorPosition,
            initialScrollOffset: goToLineOffset != nil ? 0 : tab.scrollOffset,
            onStateChange: { cursor, scroll in
                tabManager.updateEditorState(cursorPosition: cursor, scrollOffset: scroll)
            },
            onHighlightCacheUpdate: { result in
                tabManager.updateHighlightCache(result)
            },
            cachedHighlightResult: tab.cachedHighlightResult,
            goToOffset: goToLineOffset,
            indentStyle: tab.cachedIndentation,
            fontSize: FontSizeSettings.shared.fontSize
        )
        .id(tab.id)
        .accessibilityIdentifier(AccessibilityID.codeEditor)
        .onAppear { goToLineOffset = nil }
    }
}

// MARK: - Drop Zones

/// Represents where a tab can be dropped relative to a pane.
enum PaneDropZone: Equatable, Sendable {
    case right
    case bottom
    case center

    /// Fraction of pane width/height that triggers edge drop zones (right/bottom).
    static let edgeThreshold: CGFloat = 0.7

    /// Determines the drop zone based on cursor location within a container of the given size.
    /// Uses percentage-based thresholds: right 30% = split right, bottom 30% = split down,
    /// center = move to pane.
    static func zone(for location: CGPoint, in size: CGSize) -> PaneDropZone {
        let width = size.width
        let height = size.height

        let inRightZone = width > 0 && location.x > width * edgeThreshold
        let inBottomZone = height > 0 && location.y > height * edgeThreshold

        if inRightZone && (!inBottomZone || location.x / width > location.y / height) {
            return .right
        } else if inBottomZone {
            return .bottom
        } else {
            return .center
        }
    }
}

/// Visual overlay that shows the drop zone indicator.
struct PaneDropOverlay: View {
    let dropZone: PaneDropZone?

    var body: some View {
        if let zone = dropZone {
            GeometryReader { geometry in
                let rect = dropRect(zone: zone, size: geometry.size)
                Rectangle()
                    .fill(Color.accentColor.opacity(0.2))
                    .border(Color.accentColor.opacity(0.5), width: 2)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
            }
            .allowsHitTesting(false)
            .accessibilityIdentifier(AccessibilityID.paneDropOverlay)
        }
    }

    private func dropRect(zone: PaneDropZone, size: CGSize) -> CGRect {
        switch zone {
        case .right:
            return CGRect(x: size.width / 2, y: 0, width: size.width / 2, height: size.height)
        case .bottom:
            return CGRect(x: 0, y: size.height / 2, width: size.width, height: size.height / 2)
        case .center:
            return CGRect(x: 0, y: 0, width: size.width, height: size.height)
        }
    }
}

// MARK: - Preference Key for Pane Size

/// Captures the pane size via GeometryReader for use in drop zone calculations.
private struct PaneSizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

// MARK: - Drop Delegate

/// Handles drop events on a pane to determine split direction.
struct PaneSplitDropDelegate: DropDelegate {
    let paneID: PaneID
    let paneManager: PaneManager
    /// Actual pane size from GeometryReader, used for percentage-based drop zone detection.
    let paneSize: CGSize
    @Binding var dropZone: PaneDropZone?

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.paneTabDrag])
    }

    func dropEntered(info: DropInfo) {
        updateDropZone(info: info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        updateDropZone(info: info)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        dropZone = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let zone = dropZone else { return false }
        dropZone = nil

        // Extract the drag data
        let providers = info.itemProviders(for: [.paneTabDrag])
        guard let provider = providers.first else { return false }

        provider.loadItem(forTypeIdentifier: UTType.paneTabDrag.identifier, options: nil) { data, _ in
            guard let data = data as? Data,
                  let string = String(data: data, encoding: .utf8),
                  let dragInfo = TabDragInfo.decode(from: string) else { return }

            DispatchQueue.main.async {
                let sourcePaneID = PaneID(id: dragInfo.paneID)

                switch zone {
                case .right:
                    paneManager.splitPane(
                        paneID,
                        axis: .horizontal,
                        tabURL: dragInfo.fileURL,
                        sourcePane: sourcePaneID
                    )
                case .bottom:
                    paneManager.splitPane(
                        paneID,
                        axis: .vertical,
                        tabURL: dragInfo.fileURL,
                        sourcePane: sourcePaneID
                    )
                case .center:
                    // Move tab to this existing pane
                    if sourcePaneID != paneID {
                        paneManager.moveTabBetweenPanes(
                            tabURL: dragInfo.fileURL,
                            from: sourcePaneID,
                            to: paneID
                        )
                    }
                }
            }
        }
        return true
    }

    private func updateDropZone(info: DropInfo) {
        dropZone = PaneDropZone.zone(for: info.location, in: paneSize)
    }
}
