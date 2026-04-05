//
//  RootDropZone.swift
//  Pine
//
//  Root-level drop zone types for full-width/height pane splits.
//

import SwiftUI

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
