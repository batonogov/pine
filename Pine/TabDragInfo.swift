//
//  TabDragInfo.swift
//  Pine
//
//  Drag data for moving tabs between split panes.
//

import Foundation

/// Information about a tab being dragged between panes.
/// Encoded as a string "paneUUID|tabUUID|fileURL" for NSItemProvider transport.
struct TabDragInfo: Sendable {
    let paneID: UUID
    let tabID: UUID
    let fileURL: URL

    /// Encodes to string for drag transfer.
    var encoded: String {
        "\(paneID.uuidString)|\(tabID.uuidString)|\(fileURL.absoluteString)"
    }

    /// Decodes from string. Returns nil if format is invalid.
    static func decode(from string: String) -> TabDragInfo? {
        let parts = string.split(separator: "|", maxSplits: 2)
        guard parts.count == 3,
              let paneUUID = UUID(uuidString: String(parts[0])),
              let tabUUID = UUID(uuidString: String(parts[1])),
              let url = URL(string: String(parts[2])) else {
            return nil
        }
        return TabDragInfo(paneID: paneUUID, tabID: tabUUID, fileURL: url)
    }
}

/// UTType identifier for pane tab drag operations.
/// Uses a reverse-DNS custom type to avoid collisions with system types.
let paneTabDragUTType = "com.pine.pane-tab-drag"
