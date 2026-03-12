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
    var url: URL
    var content: String
    var savedContent: String

    // Per-tab editor state — preserved across tab switches.
    var cursorPosition: Int = 0
    var scrollOffset: CGFloat = 0

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

    // Hashable by id only — content/state changes shouldn't affect identity.
    static func == (lhs: EditorTab, rhs: EditorTab) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
