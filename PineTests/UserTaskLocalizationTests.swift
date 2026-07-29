//
//  UserTaskLocalizationTests.swift
//  PineTests
//

import Foundation
import Testing

@Suite("User task localization")
struct UserTaskLocalizationTests {
    private static let locales = Set([
        "de", "en", "es", "fr", "ja", "ko", "pt-BR", "ru", "zh-Hans",
    ])

    private static let keys = [
        "userTask.replacementUnavailable.title",
        "userTask.replacementUnavailable.message",
        "userTask.toast.succeeded",
        "userTask.copyOutput",
        "userTask.openOutput",
        "userTask.run.status.pending",
        "userTask.run.status.running",
        "userTask.run.status.cancelling",
        "userTask.run.status.succeeded",
        "userTask.run.status.timedOut",
        "userTask.run.status.failed",
        "userTask.run.status.cancelled",
        "userTask.run.status.exitCode",
        "userTask.run.elapsed",
        "userTask.output.title",
        "userTask.output.empty",
        "userTask.output.previewTruncated",
        "userTask.output.clearFinished",
        "userTask.output.close",
        "userTask.output.show",
        "userTask.cancel",
        "userTask.diagnostic.blocked",
        "userTask.diagnostic.launchFailed",
        "userTask.diagnostic.backgroundReaper",
        "userTask.diagnostic.subprocessCleanup",
        "userTask.diagnostic.outputDeadline",
        "userTask.diagnostic.outputTruncated",
        "userTask.diagnostic.invalidUTF8",
        "userTask.diagnostic.inputIncomplete",
    ]

    @Test("Every task UI key is translated for all supported locales")
    func completeCatalogCoverage() throws {
        let catalog = try loadCatalog()

        for key in Self.keys {
            let entry = try #require(catalog[key] as? [String: Any])
            let localizations = try #require(
                entry["localizations"] as? [String: Any]
            )
            #expect(Set(localizations.keys) == Self.locales)

            let english = try localizedValue(
                in: localizations,
                locale: "en"
            )
            let englishPlaceholders = placeholders(in: english)
            for locale in Self.locales {
                let value = try localizedValue(
                    in: localizations,
                    locale: locale
                )
                #expect(!value.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty)
                #expect(
                    placeholders(in: value) == englishPlaceholders,
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

    private func localizedValue(
        in localizations: [String: Any],
        locale: String
    ) throws -> String {
        let localization = try #require(
            localizations[locale] as? [String: Any]
        )
        let unit = try #require(
            localization["stringUnit"] as? [String: Any]
        )
        #expect(unit["state"] as? String == "translated")
        return try #require(unit["value"] as? String)
    }

    private func placeholders(in value: String) -> [String] {
        let expression = try? NSRegularExpression(
            pattern: #"%([0-9]+\$)?(?:@|lld)"#
        )
        let range = NSRange(value.startIndex..., in: value)
        return expression?.matches(in: value, range: range).compactMap {
            Range($0.range, in: value).map { String(value[$0]) }
        } ?? []
    }
}
