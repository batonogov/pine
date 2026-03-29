//
//  MarkdownPreviewMode.swift
//  Pine
//

/// Markdown preview display mode: source code, rendered preview, or side-by-side split.
enum MarkdownPreviewMode: String, Codable, Sendable {
    case source, preview, split

    /// Cycles through modes: source → split → preview → source.
    var next: Self {
        switch self {
        case .source: .split
        case .split: .preview
        case .preview: .source
        }
    }
}
