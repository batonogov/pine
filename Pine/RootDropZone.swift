//
//  RootDropZone.swift
//  Pine
//
//  Root-level drop zone types for full-width/height pane splits.
//

import SwiftUI
import UniformTypeIdentifiers

// MARK: - Root Drop Zone

/// Represents a drop zone at the window edge for creating full-width/height splits.
enum RootDropZone: Equatable, Sendable {
    case top
    case bottom
    case left
    case right

    /// Fraction of container size that triggers root edge drop zones.
    /// Narrower than leaf zones (10% vs 25%) to avoid conflicts.
    static let edgeThreshold: CGFloat = 0.10

    /// Determines the root drop zone based on cursor location.
    /// Returns nil if the cursor is not within the edge threshold.
    static func detect(location: CGPoint, in size: CGSize) -> RootDropZone? {
        let width = size.width
        let height = size.height
        guard width > 0, height > 0 else { return nil }

        let relX = location.x / width
        let relY = location.y / height

        let inLeft = relX < edgeThreshold
        let inRight = relX > (1 - edgeThreshold)
        let inTop = relY < edgeThreshold
        let inBottom = relY > (1 - edgeThreshold)

        guard inLeft || inRight || inTop || inBottom else { return nil }

        // Corner conflict: pick the axis where cursor is closer to the edge
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
        }

        return nil
    }
}

// MARK: - Root Drop Overlay

/// Visual overlay showing the full-width/height drop zone indicator at window edges.
struct RootDropOverlay: View {
    let dropZone: RootDropZone?

    var body: some View {
        if let zone = dropZone {
            GeometryReader { geometry in
                let rect = dropRect(zone: zone, size: geometry.size)
                Rectangle()
                    .fill(Color.accentColor.opacity(0.15))
                    .border(Color.accentColor.opacity(0.4), width: 2)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
            }
            .allowsHitTesting(false)
        }
    }

    private func dropRect(zone: RootDropZone, size: CGSize) -> CGRect {
        let fraction: CGFloat = 0.3
        switch zone {
        case .top:
            let height = size.height * fraction
            return CGRect(x: size.width / 2, y: height / 2, width: size.width, height: height)
        case .bottom:
            let height = size.height * fraction
            return CGRect(x: size.width / 2, y: size.height - height / 2, width: size.width, height: height)
        case .left:
            let width = size.width * fraction
            return CGRect(x: width / 2, y: size.height / 2, width: width, height: size.height)
        case .right:
            let width = size.width * fraction
            return CGRect(x: size.width - width / 2, y: size.height / 2, width: width, height: size.height)
        }
    }
}

// MARK: - Root Drop Delegate

/// Handles drop events at window edges for root-level pane splits.
/// Only accepts terminal tab drags.
struct RootPaneSplitDropDelegate: DropDelegate {
    let paneManager: PaneManager
    let containerSize: CGSize

    func validateDrop(info: DropInfo) -> Bool {
        guard info.hasItemsConforming(to: [.paneTabDrag]) else { return false }
        guard let drag = paneManager.activeDrag,
              drag.contentType == .terminal else { return false }
        return paneManager.root.leafCount > 1
    }

    func dropEntered(info: DropInfo) {
        updateZone(info: info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        updateZone(info: info)
        let zone = RootDropZone.detect(location: info.location, in: containerSize)
        if zone != nil {
            paneManager.clearLeafDropZones()
            return DropProposal(operation: .move)
        }
        paneManager.rootDropZone = nil
        return nil
    }

    func dropExited(info: DropInfo) {
        paneManager.rootDropZone = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let zone = paneManager.rootDropZone else { return false }
        paneManager.rootDropZone = nil
        paneManager.clearAllDropZones()

        guard let dragInfo = paneManager.activeDrag,
              dragInfo.contentType == .terminal else { return false }
        paneManager.activeDrag = nil

        let sourcePaneID = PaneID(id: dragInfo.paneID)
        paneManager.wrapRootWithTerminal(at: zone, from: sourcePaneID, tabID: dragInfo.tabID)
        return true
    }

    private func updateZone(info: DropInfo) {
        paneManager.rootDropZone = RootDropZone.detect(location: info.location, in: containerSize)
        paneManager.startStaleDropPollingIfNeeded()
    }
}

// MARK: - Preference Key

/// Captures the root container size for root drop zone calculations.
struct RootContainerSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}
