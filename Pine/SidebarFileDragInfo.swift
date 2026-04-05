//
//  SidebarFileDragInfo.swift
//  Pine
//
//  Drag data for dragging files from the sidebar to editor panes.
//  Separate from TabDragInfo to distinguish sidebar file drags from tab drags.
//

import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// Custom UTType for sidebar file drag operations.
/// Distinct from `.paneTabDrag` so drop delegates can distinguish sidebar drags from tab reorders.
extension UTType {
    nonisolated(unsafe) static let sidebarFileDrag = UTType(exportedAs: "com.pine.sidebar-file-drag")
}

/// Information about a file being dragged from the sidebar.
/// JSON-encoded for NSItemProvider transport via custom UTType.
/// Conforms to Transferable so `.draggable()` can be used instead of `.onDrag`,
/// which avoids tap gesture conflicts in List rows.
struct SidebarFileDragInfo: Codable, Sendable, Transferable {
    let fileURL: URL

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .sidebarFileDrag)
    }

    /// JSON-encodes to a string for drag transfer.
    var encoded: String {
        guard let data = try? JSONEncoder().encode(self),
              let string = String(data: data, encoding: .utf8) else {
            return ""
        }
        return string
    }

    /// Decodes from a JSON string. Returns nil if format is invalid.
    static func decode(from string: String) -> SidebarFileDragInfo? {
        guard let data = string.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(SidebarFileDragInfo.self, from: data)
    }
}
