//
//  AgentActivityFilterLocalizationTests.swift
//  PineTests
//
//  Catalog coverage for Activity attribution-evidence filter copy.
//

import Foundation
import Testing

@Suite("Agent Activity Filter Localization")
struct AgentActivityFilterLocalizationTests {
    private static let languages = [
        "en", "de", "es", "fr", "ja", "ko", "pt-BR", "ru", "zh-Hans"
    ]
    private static let keys = [
        "agentActivity.noMatches",
        "agentActivity.attribution.filterLabel",
        "agentActivity.attribution.sessionLinked",
        "agentActivity.attribution.sessionLinkedHint",
        "agentActivity.attribution.inferred",
        "agentActivity.attribution.inferredHint",
        "agentActivity.attribution.ambiguous",
        "agentActivity.attribution.ambiguousHint"
    ]

    private func stringsCatalog() throws -> [String: Any] {
        let testURL = URL(fileURLWithPath: #filePath)
        let projectRoot = testURL.deletingLastPathComponent()
            .deletingLastPathComponent()
        let catalogURL = projectRoot.appendingPathComponent(
            "Pine/Localizable.xcstrings"
        )
        let data = try Data(contentsOf: catalogURL)
        let root = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        return try #require(root["strings"] as? [String: Any])
    }

    @Test("Every filter string is translated in all supported languages")
    func allLanguagesPresent() throws {
        let catalog = try stringsCatalog()

        for key in Self.keys {
            let entry = try #require(catalog[key] as? [String: Any])
            let localizations = try #require(
                entry["localizations"] as? [String: Any]
            )
            #expect(Set(localizations.keys) == Set(Self.languages))

            for language in Self.languages {
                let localization = try #require(
                    localizations[language] as? [String: Any]
                )
                let unit = try #require(
                    localization["stringUnit"] as? [String: Any]
                )
                #expect(unit["state"] as? String == "translated")
                let value = try #require(unit["value"] as? String)
                #expect(!value.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    @Test("English copy names evidence without claiming verification")
    func englishCopyIsTruthful() throws {
        let catalog = try stringsCatalog()
        let entry = try #require(
            catalog["agentActivity.attribution.sessionLinked"]
                as? [String: Any]
        )
        let localizations = try #require(
            entry["localizations"] as? [String: Any]
        )
        let english = try #require(localizations["en"] as? [String: Any])
        let unit = try #require(english["stringUnit"] as? [String: Any])

        #expect(unit["value"] as? String == "Session-linked")
        #expect(catalog["agentActivity.attribution.direct"] == nil)
    }
}
