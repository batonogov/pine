//
//  MenuItemNamingConventionTests.swift
//  PineTests
//
//  The naming half of #1564, stated over Localizable.xcstrings the way a
//  Mac user meets the names: in the menu. Two conventions are guarded:
//
//  - a command that needs further input is titled with an ellipsis, like its
//    siblings "Quick Open…", "Find…", and "Save As…";
//  - a `Toggle(isOn:)` item renders a checkmark, so its title names the
//    state ("Minimap"), not the verb ("Toggle Minimap").
//
//  The values live in the xcstrings catalog keyed by Strings.swift, so the
//  catalog is the single place both conventions can be verified for all
//  nine locales at once.
//

import Foundation
import Testing

@testable import Pine

/// The localization catalog read from the repository.
///
/// Shared by the guards that need to compare a localized menu title with a
/// localized help-book row (reading is safe; only writing through a JSON
/// serializer is forbidden by the localization rules).
enum LocalizationCatalog {
    /// Isolated away from the suite's default MainActor isolation so the
    /// `@Test(arguments:)` macro — which evaluates outside the actor — can
    /// read it.
    nonisolated static let locales = [
        "en", "de", "es", "fr", "ja", "ko", "pt-BR", "ru", "zh-Hans",
    ]

    static func value(_ key: String, locale: String) -> String? {
        table[key]?[locale]
    }

    /// Resolves the catalog key behind a Swift identifier like
    /// `menuToggleMinimap` → `menu.toggleMinimap`, matching case- and
    /// dot-insensitively so the mapping holds however the identifier is
    /// cased in source.
    static func key(forIdentifier identifier: String) -> String? {
        keysByNormalizedIdentifier[Self.normalized(identifier)]
    }

    private static func normalized(_ string: String) -> String {
        string.lowercased().filter { $0 != "." && $0 != "_" }
    }

    private static let keysByNormalizedIdentifier: [String: String] =
        table.reduce(into: [:]) { result, entry in
            result[Self.normalized(entry.key)] = entry.key
        }

    /// Loaded once; `static let` initialization is atomic, so parallel tests
    /// share one immutable snapshot of the catalog.
    private static let table: [String: [String: String]] = load() ?? [:]

    private static func load() -> [String: [String: String]]? {
        guard
            let url = try? ProductionSourceScan.repositoryRoot()
                .appendingPathComponent("Pine/Localizable.xcstrings"),
            let data = try? Data(contentsOf: url),
            let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any]
        else { return nil }
        var result: [String: [String: String]] = [:]
        for (key, entry) in object["strings"] as? [String: Any] ?? [:] {
            let localizations =
                (entry as? [String: Any])?["localizations"] as? [String: Any]
                ?? [:]
            var values: [String: String] = [:]
            for (locale, localization) in localizations {
                guard
                    let unit = (localization as? [String: Any])?["stringUnit"]
                        as? [String: Any],
                    let value = unit["value"] as? String
                else { continue }
                values[locale] = value
            }
            result[key] = values
        }
        return result
    }
}

@Suite("Menu item titles follow the ellipsis and checkmark conventions")
struct MenuItemNamingConventionTests {
    private static func value(_ key: String, _ locale: String) throws -> String {
        try #require(
            LocalizationCatalog.value(key, locale: locale),
            "\(key) has no \(locale) value in Localizable.xcstrings"
        )
    }

    // MARK: - Ellipsis

    /// Commands that open a prompt, a panel with a search field, or a find
    /// bar take further input, so every locale titles them with an ellipsis.
    @Test("commands that need further input end with an ellipsis")
    func inputCommandsCarryAnEllipsis() throws {
        let keys = [
            "menu.goToLine",
            "menu.symbolNavigator",
            "menu.findInProject",
            "menu.findInTerminal",
        ]
        for key in keys {
            for locale in LocalizationCatalog.locales {
                let title = try Self.value(key, locale)
                #expect(
                    title.hasSuffix("…"),
                    """
                    \(key) is titled "\(title)" in \(locale): a command that \
                    needs further input carries an ellipsis (#1564).
                    """
                )
            }
        }
    }

    /// The renamed Symbol Navigator also aligns with the help book, which
    /// has always called the command "Go to Symbol".
    @Test("the symbol command is named Go to Symbol in English")
    func symbolCommandMatchesHelpBookNaming() throws {
        #expect(
            try Self.value("menu.symbolNavigator", "en") == "Go to Symbol…",
            """
            The help book lists "Go to Symbol"; the menu must agree (#1564).
            """
        )
    }

    // MARK: - Checkmark items

    /// Every `Toggle(isOn:)` item the menu defines, by the `Strings.<key>`
    /// label that follows it. Derived from the menu source — not listed —
    /// so a "Toggle Foo" someone adds six months from now is checked the
    /// moment it compiles.
    private static func checkmarkItemKeys() throws -> [String] {
        let source = try MenuCommandSource.source()
        var results: [String] = []
        var searchStart = source.startIndex
        while let toggle = source.range(
            of: "Toggle(isOn:",
            range: searchStart..<source.endIndex
        ) {
            // The label follows the Toggle: find the nearest `Strings.` in
            // the item's own closure, before its closing brace, and resolve
            // the catalog key behind the identifier it names.
            let scopeEnd = source[toggle.upperBound...].firstIndex(of: "}")
                ?? source.endIndex
            if let label = source[toggle.upperBound..<scopeEnd]
                .range(of: "Strings.") {
                let identifier = source[label.upperBound...].prefix {
                    $0.isLetter || $0.isNumber || $0 == "_"
                }
                guard let key = LocalizationCatalog.key(
                    forIdentifier: String(identifier)
                ) else {
                    Issue.record(
                        """
                        A Toggle(isOn:) in the menu source labels itself with \
                        "Strings.\(identifier)", which resolves to no catalog \
                        key; this guard cannot verify its naming (#1564).
                        """
                    )
                    searchStart = scopeEnd
                    continue
                }
                results.append(key)
            } else {
                Issue.record(
                    """
                    A Toggle(isOn:) in the menu source carries no \
                    Strings.* label; this guard cannot verify its \
                    naming (#1564).
                    """
                )
            }
            searchStart = scopeEnd
        }
        #expect(
            !results.isEmpty,
            """
            The menu source scan found no Toggle(isOn:) items at all — this \
            guard cannot pass on a menu it failed to read.
            """
        )
        return results
    }

    /// `Toggle(isOn:)` renders a checkmark; the title must name the state so
    /// the checked row reads "Minimap ✓" rather than "Toggle Minimap ✓".
    @Test("checkmark items are named for the state, not the verb")
    func checkmarkItemsNameTheState() throws {
        let keys = try Self.checkmarkItemKeys()

        for key in keys {
            let englishTitle = try Self.value(key, "en")
            #expect(
                !englishTitle.lowercased().hasPrefix("toggle"),
                """
                \(key) is titled "\(englishTitle)": a checkmarked item names \
                the state, not the verb (#1564).
                """
            )
            #expect(!englishTitle.isEmpty)
            for locale in LocalizationCatalog.locales {
                let title = try Self.value(key, locale)
                #expect(
                    !title.isEmpty,
                    "\(key) has an empty \(locale) title."
                )
            }
        }
    }

    /// The preview mode cycler is a plain Button (no checkmark), so it keeps
    /// an action verb — but it must say what it toggles, matching the help
    /// book's "Markdown Preview" wording instead of a bare "Toggle Preview".
    @Test("the preview cycler names its subject")
    func previewToggleNamesMarkdown() throws {
        #expect(
            try Self.value("menu.togglePreview", "en")
                == "Toggle Markdown Preview",
            """
            The help book calls the command "Markdown Preview"; the menu must \
            name the same subject (#1564).
            """
        )
    }
}
