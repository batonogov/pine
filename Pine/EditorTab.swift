//
//  EditorTab.swift
//  Pine
//
//  Created by Claude on 12.03.2026.
//

import Foundation

/// Represents a single open editor tab with its file URL and content state.
struct EditorTab: Identifiable, Hashable {
    let id: UUID
    let url: URL
    var content: String
    var savedContent: String

    var isDirty: Bool { content != savedContent }

    var fileName: String { url.lastPathComponent }

    var language: String {
        (url.lastPathComponent as NSString).pathExtension.lowercased()
    }

    init(url: URL, content: String = "", savedContent: String = "") {
        self.id = UUID()
        self.url = url
        self.content = content
        self.savedContent = savedContent
    }

    // Hashable by id only — content changes shouldn't affect identity.
    static func == (lhs: EditorTab, rhs: EditorTab) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
