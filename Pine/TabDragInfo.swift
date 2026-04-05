//
//  TabDragInfo.swift
//  Pine
//
//  Drag data for moving tabs between split panes.
//

import Foundation
import UniformTypeIdentifiers

/// Custom UTType for pane tab drag operations.
/// Uses reverse-DNS naming to avoid collisions with system types like .text.
extension UTType {
    static let paneTabDrag = UTType(exportedAs: "com.pine.pane-tab-drag")
}

/// Information about a tab being dragged between panes.
/// JSON-encoded for NSItemProvider transport via custom UTType.
struct TabDragInfo: Codable, Sendable {
    let paneID: UUID
    let tabID: UUID
    let fileURL: URL
    /// The pane content type. Defaults to `.editor` for backwards compatibility.
    var contentType: PaneContent = .editor

    /// JSON-encodes to a string for drag transfer.
    var encoded: String {
        guard let data = try? JSONEncoder().encode(self),
              let string = String(data: data, encoding: .utf8) else {
            return ""
        }
        return string
    }

    /// Decodes from a JSON string. Returns nil if format is invalid.
    static func decode(from string: String) -> TabDragInfo? {
        guard let data = string.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(TabDragInfo.self, from: data)
    }

    init(paneID: UUID, tabID: UUID, fileURL: URL, contentType: PaneContent = .editor) {
        self.paneID = paneID
        self.tabID = tabID
        self.fileURL = fileURL
        self.contentType = contentType
    }

    enum CodingKeys: String, CodingKey {
        case paneID
        case tabID
        case fileURL
        case contentType
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        paneID = try container.decode(UUID.self, forKey: .paneID)
        tabID = try container.decode(UUID.self, forKey: .tabID)
        fileURL = try container.decode(URL.self, forKey: .fileURL)
        contentType = try container.decodeIfPresent(PaneContent.self, forKey: .contentType) ?? .editor
    }
}
