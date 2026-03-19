//
//  SearchLocalizationTests.swift
//  PineTests
//
//  Verifies that all search-related localization keys have translations
//  in every supported language.
//

import Foundation
import Testing

@Suite("Search Localization Tests")
struct SearchLocalizationTests {

    /// All languages the app supports.
    private static let supportedLanguages = ["en", "de", "es", "fr", "ja", "ko", "pt-BR", "ru", "zh-Hans"]

    /// Search-related localization keys added in the .searchable migration.
    private static let searchKeys = [
        "search.placeholder",
        "search.noResults",
        "search.caseSensitive",
        "search.close",
        "sidebar.search"
    ]

    /// Parses Localizable.xcstrings and returns [key: [lang: value]].
    private static func loadLocalizations(filePath: String = #filePath) throws -> [String: [String: String]] {
        // #filePath points to PineTests/SearchLocalizationTests.swift
        // Go up two levels to project root, then into Pine/
        let testFile = URL(fileURLWithPath: filePath)
        let projectRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
        let url = projectRoot.appendingPathComponent("Pine/Localizable.xcstrings")
        let data = try Data(contentsOf: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let strings = json["strings"] as? [String: Any] else {
            return [:]
        }

        var result: [String: [String: String]] = [:]
        for (key, value) in strings {
            guard let entry = value as? [String: Any],
                  let localizations = entry["localizations"] as? [String: Any] else { continue }

            var langMap: [String: String] = [:]
            for (lang, locValue) in localizations {
                if let locDict = locValue as? [String: Any],
                   let stringUnit = locDict["stringUnit"] as? [String: Any],
                   let text = stringUnit["value"] as? String {
                    langMap[lang] = text
                }
            }
            result[key] = langMap
        }
        return result
    }

    @Test("All search keys have translations in all supported languages",
          arguments: searchKeys)
    func searchKeyHasAllTranslations(key: String) throws {
        let localizations = try Self.loadLocalizations()

        guard let translations = localizations[key] else {
            Issue.record("Key '\(key)' not found in Localizable.xcstrings")
            return
        }

        for lang in Self.supportedLanguages {
            let value = translations[lang]
            #expect(
                value != nil && !value!.isEmpty,
                "Key '\(key)' missing translation for '\(lang)'"
            )
        }
    }

    @Test("Search translations are non-empty strings",
          arguments: searchKeys)
    func searchTranslationsNonEmpty(key: String) throws {
        let localizations = try Self.loadLocalizations()
        guard let translations = localizations[key] else { return }

        for (lang, value) in translations {
            #expect(
                !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "Key '\(key)' has empty translation for '\(lang)'"
            )
        }
    }

    @Test("All supported languages have at least one search translation")
    func allLanguagesHaveSearchStrings() throws {
        let localizations = try Self.loadLocalizations()

        for lang in Self.supportedLanguages {
            let count = Self.searchKeys.filter { key in
                localizations[key]?[lang] != nil
            }.count
            #expect(
                count == Self.searchKeys.count,
                "Language '\(lang)' has \(count)/\(Self.searchKeys.count) search translations"
            )
        }
    }
}
