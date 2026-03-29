//
//  EditorTheme.swift
//  Pine
//
//  Theme model for editor syntax highlighting colors.
//

import AppKit

// MARK: - JSON-Codable theme model

/// A color represented as RGB components (0.0–1.0).
struct ThemeColor: Codable, Sendable, Equatable {
    let r: CGFloat
    let g: CGFloat
    let b: CGFloat

    var nsColor: NSColor {
        NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }
}

/// Editor chrome colors (background, gutter, etc.).
struct EditorColors: Codable, Sendable, Equatable {
    let background: ThemeColor
    let text: ThemeColor
    let gutter: ThemeColor
    let gutterText: ThemeColor
    let currentLine: ThemeColor
    let selection: ThemeColor
}

/// A complete editor theme loaded from JSON.
struct EditorTheme: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let name: String
    let appearance: ThemeAppearance
    let editor: EditorColors
    let scopes: [String: ThemeColor]

    /// Converts scope colors to the Theme struct used by SyntaxHighlighter.
    func syntaxTheme() -> Theme {
        let colors = scopes.mapValues { $0.nsColor }
        return Theme(colors: colors)
    }
}

/// Whether a theme is designed for dark or light mode.
enum ThemeAppearance: String, Codable, Sendable {
    case dark
    case light
}
