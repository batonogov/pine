//
//  LocalizationCatalogCompletenessTests.swift
//  PineTests
//

import Foundation
import Testing

@Suite("Localization catalog completeness")
struct LocalizationCatalogCompletenessTests {
    private static let supportedLocales = Set([
        "de", "en", "es", "fr", "ja", "ko", "pt-BR", "ru", "zh-Hans",
    ])

    private static let formatOnlyKeys = Set([
        "",
        " ●",
        "…",
        "%@%@%@",
        "%lld",
        "1–%lld",
    ])

    @Test("Every user-facing entry covers all supported locales")
    func everyTranslatableEntryIsComplete() throws {
        let strings = try loadCatalog()

        for key in strings.keys.sorted() {
            let entry = try #require(strings[key] as? [String: Any])
            if entry["shouldTranslate"] as? Bool == false {
                continue
            }

            let localizations = try #require(
                entry["localizations"] as? [String: Any],
                "Missing localizations for \(key.debugDescription)"
            )
            #expect(
                Set(localizations.keys) == Self.supportedLocales,
                "Incomplete locales for \(key.debugDescription)"
            )

            for locale in Self.supportedLocales {
                let localization = try #require(
                    localizations[locale] as? [String: Any]
                )
                let units = stringUnitValues(in: localization)
                #expect(
                    !units.isEmpty,
                    "Missing string unit for \(key) [\(locale)]"
                )
                for value in units {
                    #expect(
                        !value.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        ).isEmpty,
                        "Empty translation for \(key) [\(locale)]"
                    )
                }
            }
        }
    }

    @Test("Format-only entries are explicitly opted out")
    func formatOnlyEntriesAreExplicit() throws {
        let strings = try loadCatalog()
        let optedOut: Set<String> = Set(strings.compactMap { key, rawEntry in
            guard
                let entry = rawEntry as? [String: Any],
                entry["shouldTranslate"] as? Bool == false
            else {
                return nil
            }
            return key
        })

        #expect(optedOut == Self.formatOnlyKeys)
    }

    @Test("Format placeholders match across locales")
    func placeholdersMatchEnglish() throws {
        let strings = try loadCatalog()

        for key in strings.keys.sorted() {
            let entry = try #require(strings[key] as? [String: Any])
            guard entry["shouldTranslate"] as? Bool != false else {
                continue
            }
            let localizations = try #require(
                entry["localizations"] as? [String: Any]
            )
            let english = try #require(
                localizations["en"] as? [String: Any]
            )
            let expected = placeholderSignatures(in: english)

            for locale in Self.supportedLocales {
                let localization = try #require(
                    localizations[locale] as? [String: Any]
                )
                #expect(
                    placeholderSignatures(in: localization) == expected,
                    "Placeholder mismatch for \(key) [\(locale)]"
                )
            }
        }
    }

    private func loadCatalog() throws -> [String: Any] {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: projectRoot.appendingPathComponent(
            "Pine/Localizable.xcstrings"
        ))
        let root = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        return try #require(root["strings"] as? [String: Any])
    }

    private func stringUnitValues(in value: Any) -> [String] {
        if let dictionary = value as? [String: Any] {
            var values: [String] = []
            if let unit = dictionary["stringUnit"] as? [String: Any],
               let text = unit["value"] as? String {
                values.append(text)
            }
            for (key, child) in dictionary where key != "stringUnit" {
                values.append(contentsOf: stringUnitValues(in: child))
            }
            return values
        }
        if let array = value as? [Any] {
            return array.flatMap { stringUnitValues(in: $0) }
        }
        return []
    }

    private func placeholderSignatures(
        in localization: [String: Any]
    ) -> Set<[String]> {
        Set(stringUnitValues(in: localization).map(placeholderSignature))
    }

    private func placeholderSignature(in value: String) -> [String] {
        let expression = try? NSRegularExpression(
            pattern: #"%#@[A-Za-z0-9_.-]+@|%([0-9]+\$)?(?:@|lld)"#
        )
        let range = NSRange(value.startIndex..., in: value)
        var implicitPosition = 1
        let tokens = expression?.matches(
            in: value,
            range: range
        ).compactMap { match -> String? in
            guard let matchRange = Range(match.range, in: value) else {
                return nil
            }
            let token = String(value[matchRange])
            if token.hasPrefix("%#@") {
                return token
            }

            let conversion = token.hasSuffix("lld") ? "lld" : "@"
            if match.numberOfRanges > 1,
               let positionRange = Range(match.range(at: 1), in: value) {
                let position = String(
                    value[positionRange].dropLast()
                )
                return "\(position)$\(conversion)"
            }

            defer { implicitPosition += 1 }
            return "\(implicitPosition)$\(conversion)"
        } ?? []
        return tokens.sorted()
    }
}
