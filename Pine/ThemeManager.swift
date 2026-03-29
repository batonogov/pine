//
//  ThemeManager.swift
//  Pine
//
//  Manages editor theme selection and persistence.
//

import AppKit
import os

// MARK: - ThemeManager

@MainActor
@Observable
final class ThemeManager {
    static let shared = ThemeManager()

    nonisolated static let userDefaultsKey = "editorThemeID"
    /// Default theme ID — the built-in adaptive theme.
    nonisolated static let systemThemeID = "system-default"

    private let defaults: UserDefaults

    /// All available themes, including the system default.
    private(set) var availableThemes: [EditorTheme] = []

    /// The currently selected theme ID.
    private(set) var selectedThemeID: String {
        didSet {
            defaults.set(selectedThemeID, forKey: Self.userDefaultsKey)
            applyTheme()
        }
    }

    /// The resolved EditorTheme (nil when using system default).
    private(set) var activeTheme: EditorTheme?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.selectedThemeID = defaults.string(forKey: Self.userDefaultsKey) ?? Self.systemThemeID
        loadThemes()
        applyTheme()
    }

    // MARK: - Public API

    /// Select a theme by ID.
    func selectTheme(_ id: String) {
        selectedThemeID = id
    }

    /// Whether the system default (adaptive) theme is active.
    var isSystemDefault: Bool {
        selectedThemeID == Self.systemThemeID
    }

    // MARK: - Theme loading

    private func loadThemes() {
        guard let urls = Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: nil) else {
            return
        }

        let decoder = JSONDecoder()
        var themes: [EditorTheme] = []

        for url in urls {
            do {
                let data = try Data(contentsOf: url)
                let theme = try decoder.decode(EditorTheme.self, from: data)
                themes.append(theme)
            } catch {
                // Not a theme file — skip silently (grammars, etc.)
                continue
            }
        }

        // Sort: dark themes first, then alphabetically
        themes.sort { lhs, rhs in
            if lhs.appearance != rhs.appearance {
                return lhs.appearance == .dark
            }
            return lhs.name < rhs.name
        }

        availableThemes = themes
        Logger.syntax.info("Loaded \(themes.count) editor themes")
    }

    // MARK: - Apply

    private func applyTheme() {
        if selectedThemeID == Self.systemThemeID {
            activeTheme = nil
            SyntaxHighlighter.shared.theme = .default
        } else if let theme = availableThemes.first(where: { $0.id == selectedThemeID }) {
            activeTheme = theme
            SyntaxHighlighter.shared.theme = theme.syntaxTheme()
        } else {
            // Unknown theme ID — fall back to system default
            activeTheme = nil
            SyntaxHighlighter.shared.theme = .default
        }

        // Notify editors to re-highlight
        NotificationCenter.default.post(name: .themeChanged, object: nil)
    }
}
