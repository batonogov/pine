//
//  SidebarFileDragInfo.swift
//  Pine
//
//  Drag data for dragging files from the sidebar to editor panes.
//  Separate from TabDragInfo to distinguish sidebar file drags from tab drags.
//

import Foundation
import UniformTypeIdentifiers

/// Custom UTType for sidebar file drag operations.
/// Distinct from `.paneTabDrag` so drop delegates can distinguish sidebar drags from tab reorders.
extension UTType {
    static let sidebarFileDrag = UTType(exportedAs: "com.pine.sidebar-file-drag")
}

/// Information about a file being dragged from the sidebar.
/// JSON-encoded for NSItemProvider transport via custom UTType.
struct SidebarFileDragInfo: Codable, Sendable {
    let fileURL: URL

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
