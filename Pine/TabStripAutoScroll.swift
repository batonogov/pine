//
//  TabStripAutoScroll.swift
//  Pine
//
//  Shared, mutation-free edge auto-scroll state for editor and terminal tabs.
//

import CoreGraphics
import Foundation
import Observation

nonisolated enum TabStripAutoScrollDirection: Hashable, Sendable {
    case leading
    case trailing
}

nonisolated struct TabStripAutoScrollOwner: Hashable, Sendable {
    let dragID: UUID
    let destinationPaneID: UUID

    @MainActor
    static func current(
        activeDrag: TabDragInfo?,
        previewIntent: TabDropIntent?
    ) -> Self? {
        guard let activeDrag,
              let previewIntent,
              previewIntent.drag == TabDragKey(activeDrag),
              previewIntent.insertionIndex != nil,
              let destinationPaneID = previewIntent.destinationPaneID else {
            return nil
        }
        return Self(
            dragID: activeDrag.dragID,
            destinationPaneID: destinationPaneID.id
        )
    }
}

nonisolated struct TabStripAutoScrollRequest: Hashable, Sendable {
    let owner: TabStripAutoScrollOwner
    let direction: TabStripAutoScrollDirection
}

/// Pure edge and visibility math shared by both tab strips.
nonisolated enum TabStripAutoScrollGeometry {
    static let edgeInset: CGFloat = 36
    static let stepDelay = Duration.milliseconds(120)
    private static let visibilityTolerance: CGFloat = 0.5

    static func direction(
        atX locationX: CGFloat,
        viewportWidth: CGFloat,
        edgeInset: CGFloat = edgeInset
    ) -> TabStripAutoScrollDirection? {
        guard locationX.isFinite,
              viewportWidth.isFinite,
              edgeInset.isFinite,
              viewportWidth > 0,
              edgeInset > 0,
              (0...viewportWidth).contains(locationX) else {
            return nil
        }

        let effectiveInset = min(edgeInset, viewportWidth / 2)
        if locationX < effectiveInset {
            return .leading
        }
        if locationX > viewportWidth - effectiveInset {
            return .trailing
        }
        return nil
    }

    static func nextTarget(
        direction: TabStripAutoScrollDirection,
        orderedTabIDs: [UUID],
        frames: [UUID: CGRect],
        viewportWidth: CGFloat
    ) -> UUID? {
        guard viewportWidth.isFinite, viewportWidth > 0, !orderedTabIDs.isEmpty else {
            return nil
        }

        for tabID in orderedTabIDs {
            guard let frame = frames[tabID],
                  frame.minX.isFinite,
                  frame.maxX.isFinite,
                  frame.width > 0 else {
                return nil
            }
        }

        switch direction {
        case .leading:
            return orderedTabIDs.last { tabID in
                guard let frame = frames[tabID] else { return false }
                return frame.minX < -visibilityTolerance
            }
        case .trailing:
            return orderedTabIDs.first { tabID in
                guard let frame = frames[tabID] else { return false }
                return frame.maxX > viewportWidth + visibilityTolerance
            }
        }
    }
}

/// Owns one strip hover generation. Geometry updates may advance the next
/// target, but a replacement drag cannot inherit the previous request.
@MainActor
@Observable
final class TabStripAutoScrollSession {
    private(set) var request: TabStripAutoScrollRequest?
    private(set) var targetID: UUID?
    private(set) var hoverLocationX: CGFloat?
    private(set) var hoveredOwner: TabStripAutoScrollOwner?

    var hoveredDragID: UUID? { hoveredOwner?.dragID }

    @ObservationIgnored private var viewportWidth: CGFloat = 0
    @ObservationIgnored private var orderedTabIDs: [UUID] = []
    @ObservationIgnored private var frames: [UUID: CGRect] = [:]

    func updateHover(
        owner: TabStripAutoScrollOwner,
        locationX: CGFloat,
        viewportWidth: CGFloat,
        orderedTabIDs: [UUID],
        frames: [UUID: CGRect]
    ) {
        hoveredOwner = owner
        hoverLocationX = locationX
        updateStoredGeometry(
            viewportWidth: viewportWidth,
            orderedTabIDs: orderedTabIDs,
            frames: frames
        )
        refreshRequest()
    }

    func updateGeometry(
        viewportWidth: CGFloat,
        orderedTabIDs: [UUID],
        frames: [UUID: CGRect]
    ) {
        updateStoredGeometry(
            viewportWidth: viewportWidth,
            orderedTabIDs: orderedTabIDs,
            frames: frames
        )
        refreshRequest()
    }

    func activeOwnerDidChange(to owner: TabStripAutoScrollOwner?) {
        guard owner == hoveredOwner else {
            end()
            return
        }
    }

    func end() {
        request = nil
        targetID = nil
        hoverLocationX = nil
        hoveredOwner = nil
        viewportWidth = 0
        orderedTabIDs = []
        frames = [:]
    }

    private func updateStoredGeometry(
        viewportWidth: CGFloat,
        orderedTabIDs: [UUID],
        frames: [UUID: CGRect]
    ) {
        self.viewportWidth = viewportWidth
        self.orderedTabIDs = orderedTabIDs
        self.frames = frames
    }

    private func refreshRequest() {
        guard let owner = hoveredOwner,
              let locationX = hoverLocationX,
              let direction = TabStripAutoScrollGeometry.direction(
                  atX: locationX,
                  viewportWidth: viewportWidth
              ),
              let targetID = TabStripAutoScrollGeometry.nextTarget(
                  direction: direction,
                  orderedTabIDs: orderedTabIDs,
                  frames: frames,
                  viewportWidth: viewportWidth
              ) else {
            request = nil
            targetID = nil
            return
        }

        request = TabStripAutoScrollRequest(owner: owner, direction: direction)
        self.targetID = targetID
    }
}
