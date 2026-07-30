//
//  GlobalTabSwitcherLocalizationTests.swift
//  PineTests
//

import Foundation
import Testing

@testable import Pine

@Suite("Global Tab Switcher Localization")
struct GlobalTabSwitcherLocalizationTests {
    private static let languages = [
        "de", "en", "es", "fr", "ja", "ko", "pt-BR", "ru", "zh-Hans"
    ]

    private static let keys = [
        "globalTabSwitcher.announcement",
        "globalTabSwitcher.hint",
        "globalTabSwitcher.title",
        "pane.genericLabel",
        "pane.positionLabel",
        "tab.switchNext",
        "tab.switchPrevious"
    ]

    private static func catalog(filePath: String = #filePath) throws -> [String: Any] {
        let testURL = URL(fileURLWithPath: filePath)
        let projectRoot = testURL
            .deletingLastPathComponent()
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

    @Test("Every switcher key has exactly all nine supported locales")
    func catalogIsComplete() throws {
        let strings = try Self.catalog()
        for key in Self.keys {
            let entry = try #require(strings[key] as? [String: Any])
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
                let value = try #require(unit["value"] as? String)
                #expect(!value.trimmingCharacters(in: .whitespaces).isEmpty)
                #expect(unit["state"] as? String == "translated")
            }
        }
    }

    @Test("Formatted pane labels and announcements resolve by locale")
    func formattedStringsResolve() {
        #expect(
            Strings.globalTabSwitcherTitle(locale: Locale(identifier: "en"))
                == "Switch Tab"
        )
        #expect(
            Strings.globalTabSwitcherTitle(locale: Locale(identifier: "ru"))
                == "Переключение вкладки"
        )
        #expect(
            Strings.globalTabSwitcherHint(locale: Locale(identifier: "en"))
                == "Tab cycles · Release Control to switch · Esc cancels"
        )
        #expect(
            Strings.paneGenericLabel(locale: Locale(identifier: "ja"))
                == "ペイン"
        )
        #expect(
            Strings.panePositionLabel(2, locale: Locale(identifier: "en"))
                == "Pane 2"
        )
        #expect(
            Strings.panePositionLabel(2, locale: Locale(identifier: "ru"))
                == "Область 2"
        )
        #expect(
            Strings.globalTabSwitcherAnnouncement(
                title: "main.swift",
                paneContext: "Pane 2",
                position: 2,
                total: 5,
                locale: Locale(identifier: "en")
            ) == "main.swift, Pane 2, 2 of 5"
        )
        #expect(
            Strings.globalTabSwitcherAnnouncement(
                title: "main.swift",
                paneContext: "ペイン2",
                position: 2,
                total: 5,
                locale: Locale(identifier: "ja")
            ) == "main.swift、ペイン2、5件中2件目"
        )
    }
}
