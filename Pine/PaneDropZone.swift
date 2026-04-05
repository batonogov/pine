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

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.paneTabDrag])
            || info.hasItemsConforming(to: [.sidebarFileDrag])
            || info.hasItemsConforming(to: [.fileURL])
    }

    func dropEntered(info: DropInfo) {
        updateDropZone(info: info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        updateDropZone(info: info)
        let operation: DropOperation = info.hasItemsConforming(to: [.paneTabDrag])
            ? .move : .copy
        return DropProposal(operation: operation)
    }

    func dropExited(info: DropInfo) {
        paneManager.dropZones[paneID] = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        // Snapshot zone and clear ALL overlays before tree mutations.
        let savedZone = paneManager.dropZones[paneID]
        paneManager.clearAllDropZones()

        // Pane tab drag takes priority
        if info.hasItemsConforming(to: [.paneTabDrag]) {
            return handlePaneTabDrop(zone: savedZone)
        }

        // Sidebar file drag — uses synchronous shared state
        if info.hasItemsConforming(to: [.sidebarFileDrag]) {
            return handleSidebarFileDrop(zone: savedZone)
        }

        // File drop from Finder — open as tab in this pane
        if info.hasItemsConforming(to: [.fileURL]) {
            handleFileDrop(providers: info.itemProviders(for: [.fileURL]))
            return true
        }

        return false
    }

    private func handleSidebarFileDrop(zone: PaneDropZone?) -> Bool {
        guard let zone else { return false }
        guard let dragInfo = paneManager.activeSidebarDrag else { return false }
        paneManager.activeSidebarDrag = nil

        switch zone {
        case .left, .right, .top, .bottom:
            let axis: SplitAxis = (zone == .left || zone == .right) ? .horizontal : .vertical
            let before = (zone == .left || zone == .top)
            paneManager.splitAndOpenFile(
                url: dragInfo.fileURL,
                relativeTo: paneID,
                axis: axis,
                insertBefore: before
            )
        case .center:
            paneManager.openFileInPane(url: dragInfo.fileURL, paneID: paneID)
        }
        return true
    }

    private func handlePaneTabDrop(zone: PaneDropZone?) -> Bool {
        guard let zone else { return false }

        // Use synchronous shared drag state instead of async NSItemProvider
        guard let dragInfo = paneManager.activeDrag else { return false }
        paneManager.activeDrag = nil

        let sourcePaneID = PaneID(id: dragInfo.paneID)
        let targetContent = paneManager.root.content(for: paneID)

        switch zone {
        case .left, .right, .top, .bottom:
            // Edge drop always creates a new pane of matching type
            let axis: SplitAxis = (zone == .left || zone == .right) ? .horizontal : .vertical
            let before = (zone == .left || zone == .top)
            if dragInfo.contentType == .terminal {
                paneManager.createTerminalPane(
                    relativeTo: paneID, axis: axis, workingDirectory: nil
                )
            } else {
                paneManager.splitPane(
                    paneID,
                    axis: axis,
                    tabURL: dragInfo.fileURL,
                    sourcePane: sourcePaneID,
                    insertBefore: before
                )
            }
        case .center:
            // Center drop: only allow same-type moves
            guard sourcePaneID != paneID,
                  dragInfo.contentType == targetContent else { break }
            if dragInfo.contentType == .terminal {
                paneManager.moveTerminalTab(
                    dragInfo.tabID, from: sourcePaneID, to: paneID
                )
            } else {
                paneManager.moveTabBetweenPanes(
                    tabURL: dragInfo.fileURL,
                    from: sourcePaneID,
                    to: paneID
                )
            }
        }
        return true
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
        paneManager.dropZones[paneID] = PaneDropZone.zone(for: info.location, in: paneSize)
    }
}
