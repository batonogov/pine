//
//  PaneTreeView.swift
//  Pine
//
//  Recursive SwiftUI view that renders a PaneNode tree as split editor panes.
//  Each leaf renders its own PaneLeafView with its own TabManager.
//

import SwiftUI

// MARK: - Pane Tree View

/// Recursively renders the PaneNode tree as nested split views.
struct PaneTreeView: View {
    let node: PaneNode
    @Environment(PaneManager.self) private var paneManager

    var body: some View {
        switch node {
        case .leaf(let paneID, let content):
            PaneLeafView(paneID: paneID, content: content)

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
