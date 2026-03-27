//
//  PaneTreeView.swift
//  Pine
//
//  Created by Pine Team on 27.03.2026.
//

import AppKit
import SwiftUI

// MARK: - PaneTreeView

/// Recursively renders a `PaneNode` tree as nested split views.
///
/// Leaf nodes become `PaneLeafView` (wrapping `EditorAreaView` with
/// the correct `TabManager` injected). Split nodes become `PaneSplitView`
/// with a draggable divider.
struct PaneTreeView: View {
    let node: PaneNode
    @Environment(PaneManager.self) private var paneManager

    var body: some View {
        switch node {
        case .leaf(let id, let content):
            PaneLeafView(paneID: id, content: content)
        case .split(let axis, let first, let second, let ratio):
            PaneSplitView(axis: axis, first: first, second: second, ratio: ratio)
        }
    }
}

// MARK: - PaneLeafView

/// Wraps `EditorAreaView` for a single leaf pane.
///
/// Injects the pane's own `TabManager` into the environment so that
/// `EditorAreaView` (which reads `@Environment(TabManager.self)`)
/// picks up the correct instance without any changes.
struct PaneLeafView: View {
    let paneID: PaneID
    let content: PaneContent
    @Environment(PaneManager.self) private var paneManager

    private var isActive: Bool {
        paneManager.activePaneID == paneID
    }

    private var showBorder: Bool {
        isActive && paneManager.paneCount > 1
    }

    var body: some View {
        Group {
            if let tabManager = paneManager.tabManager(for: paneID) {
                PaneContentPlaceholder(paneID: paneID, content: content)
                    .environment(tabManager)
            } else {
                ContentUnavailableView {
                    Label("Pane Unavailable", systemImage: "rectangle.slash")
                }
            }
        }
        .overlay {
            if showBorder {
                RoundedRectangle(cornerRadius: 2)
                    .stroke(Color.accentColor.opacity(0.3), lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            paneManager.focusPane(paneID)
        }
        .accessibilityIdentifier(AccessibilityID.pane(paneID))
    }
}

// MARK: - PaneContentPlaceholder

/// Renders the appropriate content for a pane leaf based on its `PaneContent` type.
///
/// For `.editor` panes this is a placeholder that the parent view replaces
/// with `EditorAreaView` by injecting the correct bindings. For `.terminal`
/// panes it would render a terminal (Phase 3).
///
/// Currently renders a simple placeholder because `EditorAreaView` requires
/// bindings that are owned by `ContentView`. The integration in `ContentView`
/// wraps this with the real `EditorAreaView`.
struct PaneContentPlaceholder: View {
    let paneID: PaneID
    let content: PaneContent

    @Environment(TabManager.self) private var tabManager

    var body: some View {
        switch content {
        case .editor:
            // ContentView replaces this with the real EditorAreaView
            // by reading TabManager from the environment
            VStack(spacing: 0) {
                if tabManager.tabs.isEmpty {
                    ContentUnavailableView {
                        Label(Strings.noFileSelected, systemImage: "doc.text")
                    } description: {
                        Text(Strings.selectFilePrompt)
                    }
                    .accessibilityIdentifier(AccessibilityID.editorPlaceholder)
                } else {
                    Text("Editor Pane")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        case .terminal:
            ContentUnavailableView {
                Label("Terminal", systemImage: "terminal")
            } description: {
                Text("Terminal panes will be available in a future update.")
            }
        }
    }
}

// MARK: - PaneSplitView

/// Splits space between two child `PaneNode`s with a draggable divider.
///
/// Uses `GeometryReader` instead of `HSplitView`/`VSplitView` for precise
/// control over the split ratio and divider appearance.
struct PaneSplitView: View {
    let axis: SplitAxis
    let first: PaneNode
    let second: PaneNode
    let ratio: CGFloat

    /// Visible divider thickness in points.
    static let dividerThickness: CGFloat = 1

    /// Hit-test area for the divider drag gesture.
    static let dividerHitArea: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            let totalSize = axis == .horizontal ? geo.size.width : geo.size.height
            let divider = Self.dividerThickness
            let firstSize = max(0, totalSize * ratio - divider / 2)
            let secondSize = max(0, totalSize * (1 - ratio) - divider / 2)

            if axis == .horizontal {
                HStack(spacing: 0) {
                    PaneTreeView(node: first)
                        .frame(width: firstSize)
                    PaneDividerView(axis: axis, totalSize: totalSize, ratio: ratio)
                    PaneTreeView(node: second)
                        .frame(width: secondSize)
                }
            } else {
                VStack(spacing: 0) {
                    PaneTreeView(node: first)
                        .frame(height: firstSize)
                    PaneDividerView(axis: axis, totalSize: totalSize, ratio: ratio)
                    PaneTreeView(node: second)
                        .frame(height: secondSize)
                }
            }
        }
    }
}

// MARK: - PaneDividerView

/// A draggable resize divider between two panes.
///
/// The divider has a 4pt hit area for easy grabbing but renders as a
/// subtle 1pt line matching Xcode's split divider style.
struct PaneDividerView: View {
    let axis: SplitAxis
    let totalSize: CGFloat
    let ratio: CGFloat

    @Environment(PaneManager.self) private var paneManager
    @State private var isHovered = false
    @State private var isDragging = false

    /// The divider that the user is currently dragging.
    /// We find the split node in the tree that corresponds to this divider
    /// by matching the ratio and axis -- but for simplicity, we update
    /// the root node directly via the first child leaf.
    var body: some View {
        let isVerticalDivider = axis == .horizontal

        Rectangle()
            .fill(dividerColor)
            .frame(
                width: isVerticalDivider ? PaneSplitView.dividerThickness : nil,
                height: isVerticalDivider ? nil : PaneSplitView.dividerThickness
            )
            .contentShape(
                Rectangle()
                    .size(
                        width: isVerticalDivider ? PaneSplitView.dividerHitArea : .infinity,
                        height: isVerticalDivider ? .infinity : PaneSplitView.dividerHitArea
                    )
                    .offset(
                        x: isVerticalDivider ? -PaneSplitView.dividerHitArea / 2 : 0,
                        y: isVerticalDivider ? 0 : -PaneSplitView.dividerHitArea / 2
                    )
            )
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        isDragging = true
                        let delta = isVerticalDivider ? value.translation.width : value.translation.height
                        let newRatio = ratio + delta / totalSize
                        let clamped = min(max(newRatio, 0.1), 0.9)
                        updateRatio(clamped)
                    }
                    .onEnded { _ in
                        isDragging = false
                    }
            )
            .onHover { hovering in
                isHovered = hovering
                if hovering {
                    if isVerticalDivider {
                        NSCursor.resizeLeftRight.push()
                    } else {
                        NSCursor.resizeUpDown.push()
                    }
                } else {
                    NSCursor.pop()
                }
            }
            .accessibilityIdentifier(AccessibilityID.paneDivider)
    }

    private var dividerColor: Color {
        if isDragging {
            return Color.accentColor.opacity(0.5)
        }
        return Color.primary.opacity(isHovered ? 0.3 : 0.15)
    }

    /// Finds the matching split node and updates its ratio.
    ///
    /// Since `PaneSplitView` passes us `ratio`, we look for a split in the tree
    /// whose ratio matches and update it. For phase 2, a more direct approach
    /// (passing a path or split ID) would be cleaner.
    private func updateRatio(_ newRatio: CGFloat) {
        // Walk the tree to find the split that matches our axis and current ratio,
        // and replace it. For now, we use a direct tree replacement.
        if let updated = updateSplitRatio(
            in: paneManager.rootNode, axis: axis, oldRatio: ratio, newRatio: newRatio
        ) {
            paneManager.rootNode = updated
        }
    }

    /// Recursively finds the first split with matching axis/ratio and updates it.
    private func updateSplitRatio(
        in node: PaneNode, axis: SplitAxis, oldRatio: CGFloat, newRatio: CGFloat
    ) -> PaneNode? {
        switch node {
        case .leaf:
            return nil
        case .split(let ax, let first, let second, let currentRatio):
            if ax == axis && abs(currentRatio - oldRatio) < 1e-6 {
                return .split(ax, first: first, second: second, ratio: newRatio)
            }
            if let newFirst = updateSplitRatio(in: first, axis: axis, oldRatio: oldRatio, newRatio: newRatio) {
                return .split(ax, first: newFirst, second: second, ratio: currentRatio)
            }
            if let newSecond = updateSplitRatio(
                in: second, axis: axis, oldRatio: oldRatio, newRatio: newRatio
            ) {
                return .split(ax, first: first, second: newSecond, ratio: currentRatio)
            }
            return nil
        }
    }
}
