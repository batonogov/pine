//
//  AccessibilityStringGuardTests.swift
//  PineTests
//
//  The guard half of #1529. Wiring ten accessors and translating nineteen
//  keys fixes those; it does nothing about the next `a11y.*` key someone
//  adds English-only, or the next accessor authored and never shown to
//  VoiceOver. So the invariant is stated over the source and the catalog
//  themselves, the way `MenuHardcodedShortcutGuardTests` states its own.
//

import Foundation
import Testing

@testable import Pine

@Suite("Accessibility strings are wired and translated")
struct AccessibilityStringGuardTests {
    /// What VoiceOver reads is user-facing text: every `a11y.*` key must be
    /// translated in all nine shipped locales.
    static let shippedLocales = [
        "en", "de", "es", "fr", "ja", "ko", "pt-BR", "ru", "zh-Hans",
    ]

    @Test("Every a11y accessor in Strings.swift is referenced by a view")
    func everyAccessorReachesAView() throws {
        let root = try ProductionSourceScan.repositoryRoot()
        let stringsSource = try String(
            contentsOf: root.appendingPathComponent("Pine/Strings.swift"),
            encoding: .utf8
        )

        let declared = Set(
            stringsSource.matches(of: /static (?:let|var|func) (a11y\w+)/)
                .map { String($0.1) }
        )
        #expect(
            !declared.isEmpty,
            "The scan found no accessors — the regex no longer matches, so this guard proves nothing"
        )

        var referenced: Set<String> = []
        for url in try ProductionSourceScan.productionSwiftFileURLs() {
            guard url.lastPathComponent != "Strings.swift" else { continue }
            let source = try String(contentsOf: url, encoding: .utf8)
            referenced.formUnion(
                source.matches(of: /Strings\.(a11y\w+)/)
                    .map { String($0.1) }
            )
        }

        let dead = declared.subtracting(referenced)
        #expect(
            dead.isEmpty,
            """
            Dead a11y accessors — authored, localized, and never shown to \
            VoiceOver: \(dead.sorted()). Wire each one into the view it \
            names, or delete it from Strings.swift and the catalog (#1529).
            """
        )
    }

    @Test("Every a11y catalog key is translated in all nine locales")
    func everyCatalogKeyIsTranslated() throws {
        let root = try ProductionSourceScan.repositoryRoot()
        let data = try Data(
            contentsOf: root.appendingPathComponent("Pine/Localizable.xcstrings")
        )
        let catalog = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let strings = try #require(catalog["strings"] as? [String: Any])

        var offenders: [String] = []
        for (key, value) in strings where key.hasPrefix("a11y.") {
            let localizations = (value as? [String: Any])?["localizations"]
                as? [String: Any] ?? [:]
            for locale in Self.shippedLocales {
                let unit = (localizations[locale] as? [String: Any])?["stringUnit"]
                    as? [String: Any]
                let state = unit?["state"] as? String
                if state != "translated" {
                    offenders.append("\(key) [\(locale): \(state ?? "missing")]")
                }
            }
        }

        let residual = Set(
            offenders.map {
                $0.prefix(while: { $0 != "[" })
                    .trimmingCharacters(in: .whitespaces)
            }
        )
        #expect(
            residual.isEmpty,
            """
            a11y keys that ship untranslated: \(offenders). Accessibility \
            text is user-facing text; add the eight missing translations or \
            do not ship the key (#1529).
            """
        )
    }
}
