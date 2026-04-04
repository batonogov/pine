//
//  PaneDividerView.swift
//  Pine
//
//  A draggable divider between two panes.
//

import SwiftUI

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
