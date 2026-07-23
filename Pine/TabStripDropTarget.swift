//
//  TabStripDropTarget.swift
//  Pine
//
//  Shared N+1 insertion-gap routing for editor and terminal tab strips.
//

import SwiftUI
import UniformTypeIdentifiers

struct TabStripFramePreferenceKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

/// Pure geometry used by both strips and unit tests.
nonisolated enum TabStripInsertionGeometry {
    static func insertionIndex(
        atX locationX: CGFloat,
        orderedTabIDs: [UUID],
        frames: [UUID: CGRect]
    ) -> Int? {
        guard !orderedTabIDs.isEmpty else { return 0 }
        for (index, tabID) in orderedTabIDs.enumerated() {
            guard let frame = frames[tabID] else { return nil }
            if locationX < frame.midX {
                return index
            }
        }
        return orderedTabIDs.count
    }

    static func indicatorX(
        for insertionIndex: Int,
        orderedTabIDs: [UUID],
        frames: [UUID: CGRect],
        emptyLeadingX: CGFloat = 4
    ) -> CGFloat? {
        guard (0...orderedTabIDs.count).contains(insertionIndex) else { return nil }
        guard !orderedTabIDs.isEmpty else { return emptyLeadingX }
        if insertionIndex == 0 {
            return frames[orderedTabIDs[0]]?.minX
        }
        if insertionIndex == orderedTabIDs.count {
            return frames[orderedTabIDs[insertionIndex - 1]]?.maxX
        }
        guard let previous = frames[orderedTabIDs[insertionIndex - 1]],
              let next = frames[orderedTabIDs[insertionIndex]] else { return nil }
        return (previous.maxX + next.minX) / 2
    }
}

extension View {
    func reportTabStripFrame(tabID: UUID, coordinateSpace: String) -> some View {
        background {
            GeometryReader { geometry in
                Color.clear.preference(
                    key: TabStripFramePreferenceKey.self,
                    value: [tabID: geometry.frame(in: .named(coordinateSpace))]
                )
            }
        }
    }
}

/// A single drop target spans a complete tab strip. Cursor geometry resolves
/// one of N+1 gaps; hover records only a preview intent.
struct TabStripDropDelegate: DropDelegate {
    let paneID: PaneID
    let contentType: PaneContent
    let orderedTabIDs: [UUID]
    let frames: [UUID: CGRect]
    let paneManager: PaneManager
    var onCommit: (() -> Void)?
    var onHover: ((_ dragID: UUID, _ locationX: CGFloat) -> Void)?
    var onExit: (() -> Void)?

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.paneTabDrag])
            && paneManager.activeDrag?.contentType == contentType
    }

    func dropEntered(info: DropInfo) {
        _ = preview(atX: info.location.x)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        preview(atX: info.location.x)
            ? DropProposal(operation: .move)
            : nil
    }

    func dropExited(info: DropInfo) {
        paneManager.tabDragCoordinator.clearPreview(destinationPaneID: paneID)
        onExit?()
    }

    func performDrop(info _: DropInfo) -> Bool {
        commitCurrentPreview()
    }

    /// Commits the preview last derived from current strip frames. SwiftUI may
    /// retain an older value-type delegate for `performDrop`; recomputing here
    /// from its captured frames could overwrite a newer post-scroll preview.
    @discardableResult
    func commitCurrentPreview() -> Bool {
        guard let activeDrag = paneManager.activeDrag,
              activeDrag.contentType == contentType,
              let intent = paneManager.tabDragCoordinator.previewIntent,
              intent.destinationPaneID == paneID,
              intent.insertionIndex != nil,
              intent.drag.dragID == activeDrag.dragID else {
            onExit?()
            return false
        }
        let committed = paneManager.tabDragCoordinator.commitPreview()
        onExit?()
        if committed {
            paneManager.clearAllDropZones()
            onCommit?()
        }
        return committed
    }

    /// Testable counterpart of hover callbacks.
    @discardableResult
    func preview(atX locationX: CGFloat) -> Bool {
        guard let activeDrag = paneManager.activeDrag,
              let insertionIndex = TabStripInsertionGeometry.insertionIndex(
            atX: locationX,
            orderedTabIDs: orderedTabIDs,
            frames: frames
        ), let intent = paneManager.tabStripIntent(
            destinationPaneID: paneID,
            contentType: contentType,
            insertionIndex: insertionIndex
        ), paneManager.tabDragCoordinator.preview(intent) else {
            paneManager.tabDragCoordinator.clearPreview(destinationPaneID: paneID)
            onExit?()
            return false
        }
        paneManager.clearLeafDropZones()
        paneManager.rootDropZone = nil
        onHover?(activeDrag.dragID, locationX)
        return true
    }
}

/// The only mutation feedback rendered by tab strips.
struct TabInsertionIndicator: View {
    let x: CGFloat

    var body: some View {
        Capsule()
            .fill(Color.accentColor)
            .frame(width: 3, height: LayoutMetrics.tabBarHeight - 6)
            .position(x: x, y: LayoutMetrics.tabBarHeight / 2)
            .allowsHitTesting(false)
            .accessibilityIdentifier("tabInsertionIndicator")
    }
}
