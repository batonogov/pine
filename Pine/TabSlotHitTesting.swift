//
//  TabSlotHitTesting.swift
//  Pine
//
//  Shared pointer routing for editor and terminal tab slots.
//

import SwiftUI

/// Action produced by a stationary click inside a tab slot.
enum TabSlotTapTarget: Equatable {
    case select
    case close
}

/// Geometry shared by editor and terminal tabs.
///
/// The entire rectangular 30-point slot remains one drag source. A completed
/// stationary click is routed to the close affordance only when it lands in
/// the leading close target; movement is left to SwiftUI's system drag
/// recognizer and therefore cannot accidentally close the tab.
nonisolated enum TabSlotHitTesting {
    static let closeGlyphSize: CGFloat = 14
    static let closeHitSlop: CGFloat = 4
    static let coordinateSpaceName = "pine.tab-slot"

    static func closeRect(for glyphFrame: CGRect) -> CGRect {
        guard !glyphFrame.isNull, !glyphFrame.isInfinite else { return .null }
        return glyphFrame.insetBy(dx: -closeHitSlop, dy: -closeHitSlop)
    }

    static func target(
        at point: CGPoint,
        canClose: Bool,
        closeGlyphFrame: CGRect
    ) -> TabSlotTapTarget {
        guard canClose else { return .select }
        return closeRect(for: closeGlyphFrame).contains(point) ? .close : .select
    }
}

/// Reports the close glyph's actual frame inside its tab slot. Editor tab
/// content is centered within a flexible width, so deriving this frame from
/// fixed leading padding would make the visible close affordance miss clicks.
struct TabCloseGlyphFramePreferenceKey: PreferenceKey {
    static let defaultValue = CGRect.null

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if !next.isNull {
            value = next
        }
    }
}

extension View {
    func reportsTabCloseGlyphFrame() -> some View {
        background {
            GeometryReader { geometry in
                Color.clear.preference(
                    key: TabCloseGlyphFramePreferenceKey.self,
                    value: geometry.frame(
                        in: .named(TabSlotHitTesting.coordinateSpaceName)
                    )
                )
            }
        }
    }
}
