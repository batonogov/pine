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
    /// Fraction of the split the leading pane currently occupies. Published as
    /// the splitter's accessibility value and used as the base for adjustment.
    let ratio: CGFloat
    var onDrag: (CGFloat) -> Void
    var onDragEnd: () -> Void
    /// Called with an absolute ratio when the divider is moved by an
    /// accessibility adjust or an arrow key rather than by dragging.
    var onAdjustRatio: (CGFloat) -> Void

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
            // The AppKit element below is the divider's only accessibility
            // representation: SwiftUI cannot publish a splitter role, a
            // position, or an adjustable action, and the hint here promised
            // a resize that only a mouse could perform.
            .accessibilityHidden(true)
            .background {
                PaneDividerAccessibility(
                    configuration: PaneDividerAccessibilityConfiguration(
                        axis: axis,
                        ratio: ratio,
                        label: Strings.a11yPaneDividerLabel,
                        help: Strings.a11yPaneDividerHint,
                        identifier: AccessibilityID.paneDivider
                    ),
                    onAdjust: onAdjustRatio
                )
            }
    }
}
