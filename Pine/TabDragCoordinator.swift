//
//  TabDragCoordinator.swift
//  Pine
//
//  Transactional intent model shared by editor and terminal tab drags.
//

import SwiftUI

/// The outcome of moving a tab to an insertion gap.
enum TabInsertionResult: Equatable, Sendable {
    case moved
    case noOp
    case rejected

    var accepted: Bool { self != .rejected }
}

/// Stable identity copied from the active drag into every preview intent.
/// The coordinator rejects intents left behind by an older drag gesture.
struct TabDragKey: Equatable, Sendable {
    let dragID: UUID
    let sourcePaneID: PaneID
    let tabID: UUID
    let contentType: PaneContent

    init(_ drag: TabDragInfo) {
        dragID = drag.dragID
        sourcePaneID = PaneID(id: drag.paneID)
        tabID = drag.tabID
        contentType = drag.contentType
    }
}

/// A complete, revalidatable description of the mutation that a drop would
/// perform. Hover only updates this value; model state changes in `commit`.
enum TabDropIntent: Equatable, Sendable {
    /// Move within one strip. `insertionIndex` is one of the N+1 gaps in the
    /// pre-removal tab array.
    case reorder(
        drag: TabDragKey,
        destinationPaneID: PaneID,
        insertionIndex: Int
    )
    /// Insert into another strip at one of its N+1 gaps.
    case insert(
        drag: TabDragKey,
        destinationPaneID: PaneID,
        insertionIndex: Int
    )
    /// Merge into a pane body using the destination type's default end gap.
    case merge(drag: TabDragKey, destinationPaneID: PaneID)
    /// Split one leaf and place the dragged tab in the new pane.
    case leafSplit(
        drag: TabDragKey,
        destinationPaneID: PaneID,
        zone: PaneDropZone
    )
    /// Wrap the complete pane tree at a window edge.
    case rootSplit(drag: TabDragKey, zone: RootDropZone)

    var drag: TabDragKey {
        switch self {
        case .reorder(let drag, _, _),
             .insert(let drag, _, _),
             .merge(let drag, _),
             .leafSplit(let drag, _, _),
             .rootSplit(let drag, _):
            drag
        }
    }
}

/// One coordinator owns the full drag session. Drop destinations submit
/// preview intents; only `commitPreview` may mutate pane/tab models.
@MainActor
@Observable
final class TabDragCoordinator {
    private(set) var activeDrag: TabDragInfo?
    private(set) var previewIntent: TabDropIntent?

    @ObservationIgnored
    var validateIntent: ((TabDropIntent) -> Bool)?
    @ObservationIgnored
    var commitIntent: ((TabDropIntent) -> Bool)?

    func begin(_ drag: TabDragInfo) {
        activeDrag = drag
        previewIntent = nil
    }

    @discardableResult
    func preview(_ intent: TabDropIntent) -> Bool {
        guard intentBelongsToActiveDrag(intent),
              validateIntent?(intent) == true else {
            if previewIntent?.drag.dragID == intent.drag.dragID {
                previewIntent = nil
            }
            return false
        }
        previewIntent = intent
        return true
    }

    func clearPreview() {
        previewIntent = nil
    }

    func clearPreview(destinationPaneID: PaneID) {
        guard previewIntent?.destinationPaneID == destinationPaneID else { return }
        previewIntent = nil
    }

    @discardableResult
    func commitPreview() -> Bool {
        guard let intent = previewIntent,
              intentBelongsToActiveDrag(intent),
              validateIntent?(intent) == true,
              commitIntent?(intent) == true else {
            previewIntent = nil
            return false
        }
        cancel()
        return true
    }

    func cancel() {
        activeDrag = nil
        previewIntent = nil
    }

    private func intentBelongsToActiveDrag(_ intent: TabDropIntent) -> Bool {
        guard let activeDrag else { return false }
        let key = intent.drag
        return key.dragID == activeDrag.dragID
            && key.sourcePaneID.id == activeDrag.paneID
            && key.tabID == activeDrag.tabID
            && key.contentType == activeDrag.contentType
    }
}

extension TabDropIntent {
    var destinationPaneID: PaneID? {
        switch self {
        case .reorder(_, let destinationPaneID, _),
             .insert(_, let destinationPaneID, _),
             .merge(_, let destinationPaneID),
             .leafSplit(_, let destinationPaneID, _):
            destinationPaneID
        case .rootSplit:
            nil
        }
    }

    var insertionIndex: Int? {
        switch self {
        case .reorder(_, _, let index), .insert(_, _, let index):
            index
        case .merge, .leafSplit, .rootSplit:
            nil
        }
    }
}
