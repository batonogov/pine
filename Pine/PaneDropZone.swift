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
    case right
    case bottom
    case center

    /// Fraction of pane width/height that triggers edge drop zones (right/bottom).
    static let edgeThreshold: CGFloat = 0.7

    /// Determines the drop zone based on cursor location within a container of the given size.
    /// Uses percentage-based thresholds: right 30% = split right, bottom 30% = split down,
    /// center = move to pane.
    static func zone(for location: CGPoint, in size: CGSize) -> PaneDropZone {
        let width = size.width
        let height = size.height

        let inRightZone = width > 0 && location.x > width * edgeThreshold
        let inBottomZone = height > 0 && location.y > height * edgeThreshold

        if inRightZone && (!inBottomZone || location.x / width > location.y / height) {
            return .right
        } else if inBottomZone {
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
        case .right:
            return CGRect(x: size.width / 2, y: 0, width: size.width / 2, height: size.height)
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
    @Binding var dropZone: PaneDropZone?

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.paneTabDrag])
    }

    func dropEntered(info: DropInfo) {
        updateDropZone(info: info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        updateDropZone(info: info)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        dropZone = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let zone = dropZone else { return false }
        dropZone = nil

        // Extract the drag data
        let providers = info.itemProviders(for: [.paneTabDrag])
        guard let provider = providers.first else { return false }

        provider.loadItem(forTypeIdentifier: UTType.paneTabDrag.identifier, options: nil) { data, _ in
            guard let data = data as? Data,
                  let string = String(data: data, encoding: .utf8),
                  let dragInfo = TabDragInfo.decode(from: string) else { return }

            DispatchQueue.main.async {
                let sourcePaneID = PaneID(id: dragInfo.paneID)

                switch zone {
                case .right:
                    paneManager.splitPane(
                        paneID,
                        axis: .horizontal,
                        tabURL: dragInfo.fileURL,
                        sourcePane: sourcePaneID
                    )
                case .bottom:
                    paneManager.splitPane(
                        paneID,
                        axis: .vertical,
                        tabURL: dragInfo.fileURL,
                        sourcePane: sourcePaneID
                    )
                case .center:
                    // Move tab to this existing pane
                    if sourcePaneID != paneID {
                        paneManager.moveTabBetweenPanes(
                            tabURL: dragInfo.fileURL,
                            from: sourcePaneID,
                            to: paneID
                        )
                    }
                }
            }
        }
        return true
    }

    private func updateDropZone(info: DropInfo) {
        dropZone = PaneDropZone.zone(for: info.location, in: paneSize)
    }
}
