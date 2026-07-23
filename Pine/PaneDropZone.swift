//
//  PaneDropZone.swift
//  Pine
//
//  Drop zone types, overlay, preference key, and drop delegate for pane splitting.
//

import SwiftUI
import UniformTypeIdentifiers

// MARK: - Drop Zones

/// Represents where a tab can be dropped relative to a pane.
enum PaneDropZone: Equatable, Sendable {
    case left
    case right
    case top
    case bottom
    case center

    /// Fraction of pane width/height that triggers edge drop zones.
    /// The outer 25% on each edge triggers a split.
    static let edgeThreshold: CGFloat = 0.25

    /// Determines the drop zone based on cursor location within a container of the given size.
    static func zone(for location: CGPoint, in size: CGSize) -> PaneDropZone {
        let width = size.width
        let height = size.height
        guard width > 0, height > 0 else { return .center }

        let relX = location.x / width
        let relY = location.y / height

        let inLeft = relX < edgeThreshold
        let inRight = relX > (1 - edgeThreshold)
        let inTop = relY < edgeThreshold
        let inBottom = relY > (1 - edgeThreshold)

        // If in a corner, pick the axis where the cursor is closer to the edge
        let distToEdgeX = min(relX, 1 - relX)
        let distToEdgeY = min(relY, 1 - relY)

        if inLeft && (!inTop && !inBottom || distToEdgeX <= distToEdgeY) {
            return .left
        } else if inRight && (!inTop && !inBottom || distToEdgeX <= distToEdgeY) {
            return .right
        } else if inTop {
            return .top
        } else if inBottom {
            return .bottom
        } else {
            return .center
        }
    }
}

/// The payload category used to route a pane-level drop.
///
/// Kept separate from `DropInfo` so maximize routing can be covered without
/// constructing SwiftUI's opaque drop event type.
enum PaneDropPayload: Equatable, Sendable {
    case paneTab
    case sidebarFile
    case fileURL
}

/// Visual overlay that shows the drop zone indicator.
struct PaneDropOverlay: View {
    let dropZone: PaneDropZone?

    var body: some View {
        // Maximized pane-tab drags are routed to nil, while permitted file
        // drops are routed to .center and retain their visual feedback.
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
        case .left:
            return CGRect(x: 0, y: 0, width: size.width / 2, height: size.height)
        case .right:
            return CGRect(x: size.width / 2, y: 0, width: size.width / 2, height: size.height)
        case .top:
            return CGRect(x: 0, y: 0, width: size.width, height: size.height / 2)
        case .bottom:
            return CGRect(x: 0, y: size.height / 2, width: size.width, height: size.height / 2)
        case .center:
            return CGRect(x: 0, y: 0, width: size.width, height: size.height)
        }
    }
}

// MARK: - Preference Key for Pane Size

/// Captures the pane size via GeometryReader for use in drop zone calculations.
struct PaneSizePreferenceKey: PreferenceKey {
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
    /// Tab strips own this band and pane-body routing must not compete with it.
    var excludedTopInset: CGFloat = 0

    func validateDrop(info: DropInfo) -> Bool {
        guard let payload = payload(for: info) else { return false }
        if payload == .paneTab, info.location.y < excludedTopInset {
            return false
        }
        return routedDropZone(for: payload, proposedZone: .center) != nil
    }

    func dropEntered(info: DropInfo) {
        updateDropZone(info: info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        updateDropZone(info: info)
        guard let payload = payload(for: info),
              routedDropZone(for: payload, proposedZone: .center) != nil else {
            return nil
        }
        if payload == .paneTab, paneManager.dropZones[paneID] == nil {
            return nil
        }
        let operation: DropOperation = payload == .paneTab ? .move : .copy
        return DropProposal(operation: operation)
    }

    func dropExited(info: DropInfo) {
        paneManager.dropZones[paneID] = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let payload = payload(for: info) else { return false }

        // Snapshot the visual zone. Tab intents must commit before overlays
        // are cleared because the coordinator owns the preview transaction.
        let savedZone = paneManager.dropZones[paneID]

        // Pane tab drag takes priority
        if payload == .paneTab {
            return handlePaneTabDrop(zone: savedZone)
        }

        paneManager.clearAllDropZones()

        // Sidebar file drag — decode from item providers async
        if payload == .sidebarFile {
            let providers = info.itemProviders(for: [.sidebarFileDrag])
            let routedZone = routedDropZone(for: payload, proposedZone: savedZone)
            guard routedZone != nil else { return false }
            handleSidebarFileDrop(zone: routedZone, providers: providers)
            return true
        }

        // File drop from Finder — open as tab in this pane
        if payload == .fileURL {
            handleFileDrop(providers: info.itemProviders(for: [.fileURL]))
            return true
        }

        return false
    }

    private func handleSidebarFileDrop(zone: PaneDropZone?, providers: [NSItemProvider]) {
        guard let zone else { return }
        let capturedPaneID = paneID
        let capturedPaneManager = paneManager

        Task {
            guard let provider = providers.first,
                  let data = try? await provider.loadItem(
                      forTypeIdentifier: UTType.sidebarFileDrag.identifier
                  ) as? Data,
                  let dragInfo = try? JSONDecoder().decode(SidebarFileDragInfo.self, from: data) else {
                return
            }

            await MainActor.run {
                switch zone {
                case .left, .right, .top, .bottom:
                    let axis: SplitAxis = (zone == .left || zone == .right) ? .horizontal : .vertical
                    let before = (zone == .left || zone == .top)
                    capturedPaneManager.splitAndOpenFile(
                        url: dragInfo.fileURL,
                        relativeTo: capturedPaneID,
                        axis: axis,
                        insertBefore: before
                    )
                case .center:
                    capturedPaneManager.openFileInPane(url: dragInfo.fileURL, paneID: capturedPaneID)
                }
            }
        }
    }

    private func handlePaneTabDrop(zone: PaneDropZone?) -> Bool {
        guard let zone = routedDropZone(for: .paneTab, proposedZone: zone) else {
            return false
        }
        guard paneManager.previewPaneDrop(
            destinationPaneID: paneID,
            proposedZone: zone
        ) != nil else { return false }
        let didCommit = paneManager.tabDragCoordinator.commitPreview()
        if didCommit {
            paneManager.clearAllDropZones()
        }
        return didCommit
    }

    private func handleFileDrop(providers: [NSItemProvider]) {
        guard let tabManager = paneManager.tabManager(for: paneID) else { return }
        for provider in providers {
            Task {
                guard let url = try? await provider.loadItem(
                    forTypeIdentifier: UTType.fileURL.identifier
                ) as? URL else { return }
                await MainActor.run {
                    DropHandler.openFilesAsTabs([url], in: tabManager)
                }
            }
        }
    }

    private func updateDropZone(info: DropInfo) {
        guard let payload = payload(for: info) else {
            paneManager.dropZones[paneID] = nil
            return
        }
        updateDropZone(for: payload, at: info.location)
    }

    private func payload(for info: DropInfo) -> PaneDropPayload? {
        if info.hasItemsConforming(to: [.paneTabDrag]) {
            return .paneTab
        }
        if info.hasItemsConforming(to: [.sidebarFileDrag]) {
            return .sidebarFile
        }
        if info.hasItemsConforming(to: [.fileURL]) {
            return .fileURL
        }
        return nil
    }
}

// MARK: - Test Support

extension PaneSplitDropDelegate {
    /// Routes a proposed pane drop through the maximize safety invariant.
    /// Tab payloads must stay in their local tab-strip delegate while the
    /// pane is maximized. File payloads remain useful, but are forced to the
    /// non-structural center action.
    func routedDropZone(
        for payload: PaneDropPayload,
        proposedZone: PaneDropZone?
    ) -> PaneDropZone? {
        guard paneManager.isMaximized else { return proposedZone }
        switch payload {
        case .paneTab:
            return nil
        case .sidebarFile, .fileURL:
            return .center
        }
    }

    /// Testable counterpart of `dropEntered` / `dropUpdated`.
    @discardableResult
    func updateDropZone(
        for payload: PaneDropPayload,
        at location: CGPoint
    ) -> PaneDropZone? {
        if payload == .paneTab, location.y < excludedTopInset {
            paneManager.dropZones[paneID] = nil
            paneManager.tabDragCoordinator.clearPreview(destinationPaneID: paneID)
            return nil
        }
        let proposedZone = PaneDropZone.zone(for: location, in: paneSize)
        let routedZone = routedDropZone(for: payload, proposedZone: proposedZone)
        let zone: PaneDropZone?
        if payload == .paneTab, let routedZone {
            zone = paneManager.previewPaneDrop(
                destinationPaneID: paneID,
                proposedZone: routedZone
            )
        } else {
            zone = routedZone
        }
        paneManager.dropZones[paneID] = zone
        if zone != nil {
            paneManager.startStaleDropPollingIfNeeded()
        }
        return zone
    }

    /// Testable entry point for the pane-tab branch of `performDrop(info:)`.
    ///
    /// Equivalent to invoking `performDrop` when
    /// `info.hasItemsConforming(to: [.paneTabDrag])` is true, after
    /// `paneManager.dropZones[paneID]` has been populated by `dropEntered` /
    /// `dropUpdated` and `paneManager.activeDrag` has been set by the drag
    /// source. Exposed for unit tests because SwiftUI's `DropInfo` has no
    /// public initializer, so tests cannot construct one to drive
    /// `performDrop` directly. See issue #1002.
    ///
    /// Behavior is identical to `performDrop(info:)` for the pane-tab case:
    /// reads `paneManager.activeDrag`, clears it on success, and dispatches to
    /// `PaneManager` based on `zone` and `dragInfo.contentType`.
    @discardableResult
    func performPaneTabDrop(zone: PaneDropZone?) -> Bool {
        handlePaneTabDrop(zone: zone)
    }
}
