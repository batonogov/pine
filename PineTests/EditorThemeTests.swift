//
//  EditorThemeTests.swift
//  PineTests
//

import Testing
import AppKit
@testable import Pine

@Suite(.serialized)
struct EditorThemeTests {

    // MARK: - ThemeColor

    @Test("ThemeColor converts to NSColor correctly")
    func themeColorToNSColor() throws {
        let color = ThemeColor(r: 0.5, g: 0.3, b: 0.8)
        let nsColor = try #require(color.nsColor.usingColorSpace(.sRGB))
        #expect(abs(nsColor.redComponent - 0.5) < 0.01)
        #expect(abs(nsColor.greenComponent - 0.3) < 0.01)
        #expect(abs(nsColor.blueComponent - 0.8) < 0.01)
    }

    @Test("ThemeColor equality works")
    func themeColorEquality() {
        let a = ThemeColor(r: 1.0, g: 0.0, b: 0.0)
        let b = ThemeColor(r: 1.0, g: 0.0, b: 0.0)
        let c = ThemeColor(r: 0.0, g: 1.0, b: 0.0)
        #expect(a == b)
        #expect(a != c)
    }

    // MARK: - JSON helpers

    private func decodeTheme(from json: String) throws -> EditorTheme {
        let data = try #require(json.data(using: .utf8))
        return try JSONDecoder().decode(EditorTheme.self, from: data)
    }

    // MARK: - EditorTheme JSON decoding

    @Test("EditorTheme decodes from valid JSON")
    func decodeValidTheme() throws {
        let json = """
        {
            "id" : "test-theme",
            "name" : "Test Theme",
            "appearance" : "dark",
            "editor" : {
                "background" : { "r" : 0.1, "g" : 0.1, "b" : 0.1 },
                "text" : { "r" : 0.9, "g" : 0.9, "b" : 0.9 },
                "gutter" : { "r" : 0.15, "g" : 0.15, "b" : 0.15 },
                "gutterText" : { "r" : 0.5, "g" : 0.5, "b" : 0.5 },
                "currentLine" : { "r" : 0.2, "g" : 0.2, "b" : 0.2 },
                "selection" : { "r" : 0.3, "g" : 0.3, "b" : 0.4 }
            },
            "scopes" : {
                "comment" : { "r" : 0.4, "g" : 0.5, "b" : 0.4 },
                "string" : { "r" : 0.8, "g" : 0.4, "b" : 0.3 },
                "keyword" : { "r" : 0.9, "g" : 0.2, "b" : 0.5 }
            }
        }
        """
        let theme = try decodeTheme(from: json)
        #expect(theme.id == "test-theme")
        #expect(theme.name == "Test Theme")
        #expect(theme.appearance == .dark)
        #expect(theme.scopes.count == 3)
        #expect(theme.scopes["comment"] != nil)
        #expect(theme.scopes["string"] != nil)
        #expect(theme.scopes["keyword"] != nil)
    }

    @Test("EditorTheme decodes light appearance")
    func decodeLightAppearance() throws {
        let json = """
        {
            "id" : "light-test",
            "name" : "Light Test",
            "appearance" : "light",
            "editor" : {
                "background" : { "r" : 1.0, "g" : 1.0, "b" : 1.0 },
                "text" : { "r" : 0.1, "g" : 0.1, "b" : 0.1 },
                "gutter" : { "r" : 0.95, "g" : 0.95, "b" : 0.95 },
                "gutterText" : { "r" : 0.5, "g" : 0.5, "b" : 0.5 },
                "currentLine" : { "r" : 0.97, "g" : 0.97, "b" : 0.97 },
                "selection" : { "r" : 0.7, "g" : 0.8, "b" : 1.0 }
            },
            "scopes" : {
                "keyword" : { "r" : 0.8, "g" : 0.2, "b" : 0.4 }
            }
        }
        """
        let theme = try decodeTheme(from: json)
        #expect(theme.appearance == .light)
    }

    @Test("EditorTheme fails on invalid JSON")
    func decodeInvalidTheme() throws {
        let json = """
        { "id" : "bad", "name" : "Bad" }
        """
        let data = try #require(json.data(using: .utf8))
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(EditorTheme.self, from: data)
        }
    }

    // MARK: - syntaxTheme()

    @Test("syntaxTheme produces correct Theme colors")
    func syntaxThemeConversion() throws {
        let json = """
        {
            "id" : "conv-test",
            "name" : "Conversion Test",
            "appearance" : "dark",
            "editor" : {
                "background" : { "r" : 0.1, "g" : 0.1, "b" : 0.1 },
                "text" : { "r" : 0.9, "g" : 0.9, "b" : 0.9 },
                "gutter" : { "r" : 0.15, "g" : 0.15, "b" : 0.15 },
                "gutterText" : { "r" : 0.5, "g" : 0.5, "b" : 0.5 },
                "currentLine" : { "r" : 0.2, "g" : 0.2, "b" : 0.2 },
                "selection" : { "r" : 0.3, "g" : 0.3, "b" : 0.4 }
            },
            "scopes" : {
                "comment" : { "r" : 0.4, "g" : 0.5, "b" : 0.4 },
                "keyword" : { "r" : 0.9, "g" : 0.2, "b" : 0.5 }
            }
        }
        """
        let theme = try decodeTheme(from: json)
        let syntaxTheme = theme.syntaxTheme()

        #expect(syntaxTheme.color(for: "comment") != nil)
        #expect(syntaxTheme.color(for: "keyword") != nil)
        #expect(syntaxTheme.color(for: "nonexistent") == nil)
    }

    // MARK: - EditorTheme identity

    @Test("EditorTheme ID is used for Identifiable")
    func themeIdentifiable() throws {
        let json = """
        {
            "id" : "unique-id-123",
            "name" : "Unique",
            "appearance" : "dark",
            "editor" : {
                "background" : { "r" : 0.1, "g" : 0.1, "b" : 0.1 },
                "text" : { "r" : 0.9, "g" : 0.9, "b" : 0.9 },
                "gutter" : { "r" : 0.15, "g" : 0.15, "b" : 0.15 },
                "gutterText" : { "r" : 0.5, "g" : 0.5, "b" : 0.5 },
                "currentLine" : { "r" : 0.2, "g" : 0.2, "b" : 0.2 },
                "selection" : { "r" : 0.3, "g" : 0.3, "b" : 0.4 }
            },
            "scopes" : {}
        }
        """
        let theme = try decodeTheme(from: json)
        #expect(theme.id == "unique-id-123")
    }

    // MARK: - ThemeAppearance

    @Test("ThemeAppearance raw values")
    func themeAppearanceRawValues() {
        #expect(ThemeAppearance.dark.rawValue == "dark")
        #expect(ThemeAppearance.light.rawValue == "light")
    }

    @Test("ThemeAppearance round-trip encoding")
    func themeAppearanceEncoding() throws {
        let encoded = try JSONEncoder().encode(ThemeAppearance.dark)
        let decoded = try JSONDecoder().decode(ThemeAppearance.self, from: encoded)
        #expect(decoded == .dark)
    }

    // MARK: - EditorColors

    @Test("EditorColors decodes all fields")
    func editorColorsDecoding() throws {
        let json = """
        {
            "background" : { "r" : 0.1, "g" : 0.2, "b" : 0.3 },
            "text" : { "r" : 0.9, "g" : 0.8, "b" : 0.7 },
            "gutter" : { "r" : 0.15, "g" : 0.25, "b" : 0.35 },
            "gutterText" : { "r" : 0.5, "g" : 0.5, "b" : 0.5 },
            "currentLine" : { "r" : 0.2, "g" : 0.2, "b" : 0.2 },
            "selection" : { "r" : 0.3, "g" : 0.4, "b" : 0.5 }
        }
        """
        let data = try #require(json.data(using: .utf8))
        let colors = try JSONDecoder().decode(EditorColors.self, from: data)
        #expect(abs(colors.background.r - 0.1) < 0.001)
        #expect(abs(colors.text.g - 0.8) < 0.001)
        #expect(abs(colors.gutter.b - 0.35) < 0.001)
        #expect(abs(colors.selection.r - 0.3) < 0.001)
    }

    // MARK: - Theme struct (SyntaxHighlighter)

    @Test("Default theme has all standard scopes")
    func defaultThemeScopes() {
        let theme = Theme.default
        #expect(theme.color(for: "comment") != nil)
        #expect(theme.color(for: "string") != nil)
        #expect(theme.color(for: "keyword") != nil)
        #expect(theme.color(for: "number") != nil)
        #expect(theme.color(for: "type") != nil)
        #expect(theme.color(for: "attribute") != nil)
        #expect(theme.color(for: "function") != nil)
    }

    @Test("Theme returns nil for unknown scope")
    func themeUnknownScope() {
        let theme = Theme.default
        #expect(theme.color(for: "nonexistent_scope") == nil)
    }

    // MARK: - ThemeManager

    @MainActor
    @Test("ThemeManager defaults to system theme")
    func themeManagerDefaults() {
        let suiteName = "ThemeManagerTest_defaults_\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let manager = ThemeManager(defaults: defaults)
        #expect(manager.isSystemDefault)
        #expect(manager.selectedThemeID == ThemeManager.systemThemeID)
        #expect(manager.activeTheme == nil)
    }

    @MainActor
    @Test("ThemeManager persists selection to UserDefaults")
    func themeManagerPersistence() {
        let suiteName = "ThemeManagerTest_persist_\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let manager = ThemeManager(defaults: defaults)
        manager.selectTheme("monokai")
        #expect(defaults.string(forKey: ThemeManager.userDefaultsKey) == "monokai")
    }

    @MainActor
    @Test("ThemeManager restores selection from UserDefaults")
    func themeManagerRestore() {
        let suiteName = "ThemeManagerTest_restore_\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        defaults.set("one-dark", forKey: ThemeManager.userDefaultsKey)
        let manager = ThemeManager(defaults: defaults)
        #expect(manager.selectedThemeID == "one-dark")
    }

    @MainActor
    @Test("ThemeManager falls back to system default for unknown theme ID")
    func themeManagerFallback() {
        let suiteName = "ThemeManagerTest_fallback_\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        defaults.set("nonexistent-theme", forKey: ThemeManager.userDefaultsKey)
        let manager = ThemeManager(defaults: defaults)
        #expect(manager.activeTheme == nil)
    }

    @MainActor
    @Test("ThemeManager selecting system theme clears active theme")
    func themeManagerSelectSystem() {
        let suiteName = "ThemeManagerTest_system_\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let manager = ThemeManager(defaults: defaults)
        manager.selectTheme("monokai")
        manager.selectTheme(ThemeManager.systemThemeID)
        #expect(manager.isSystemDefault)
        #expect(manager.activeTheme == nil)
    }

    // MARK: - MenuIcons and Strings

    @Test("MenuIcons has theme-related icons")
    func themeMenuIcons() {
        #expect(MenuIcons.editorTheme == "paintpalette")
        #expect(MenuIcons.themeSystem == "circle.lefthalf.filled")
    }

    // MARK: - Theme scopes required for syntax highlighting

    @Test("All standard scopes are present in Monokai theme")
    func standardScopesInThemes() throws {
        let standardScopes = ["comment", "string", "keyword", "number", "type", "attribute", "function"]
        let monokaiJSON = """
        {
            "id" : "monokai",
            "name" : "Monokai",
            "appearance" : "dark",
            "editor" : {
                "background" : { "r" : 0.157, "g" : 0.157, "b" : 0.149 },
                "text" : { "r" : 0.973, "g" : 0.973, "b" : 0.949 },
                "gutter" : { "r" : 0.200, "g" : 0.200, "b" : 0.192 },
                "gutterText" : { "r" : 0.569, "g" : 0.569, "b" : 0.525 },
                "currentLine" : { "r" : 0.227, "g" : 0.227, "b" : 0.212 },
                "selection" : { "r" : 0.282, "g" : 0.282, "b" : 0.263 }
            },
            "scopes" : {
                "comment" : { "r" : 0.459, "g" : 0.439, "b" : 0.365 },
                "string" : { "r" : 0.902, "g" : 0.859, "b" : 0.455 },
                "keyword" : { "r" : 0.976, "g" : 0.149, "b" : 0.447 },
                "number" : { "r" : 0.682, "g" : 0.506, "b" : 1.000 },
                "type" : { "r" : 0.400, "g" : 0.851, "b" : 0.937 },
                "attribute" : { "r" : 0.651, "g" : 0.886, "b" : 0.180 },
                "function" : { "r" : 0.400, "g" : 0.851, "b" : 0.937 }
            }
        }
        """
        let theme = try decodeTheme(from: monokaiJSON)
        let syntaxTheme = theme.syntaxTheme()

        for scope in standardScopes {
            #expect(syntaxTheme.color(for: scope) != nil, "Missing scope: \(scope)")
        }
    }

    // MARK: - Notification name

    @Test("themeChanged notification name exists")
    func themeChangedNotification() {
        #expect(Notification.Name.themeChanged.rawValue == "themeChanged")
    }
}
