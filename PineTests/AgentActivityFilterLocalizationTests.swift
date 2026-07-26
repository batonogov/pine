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
    private static let activityKeys = [
        "agentActivity.noMatches",
        "agentActivity.attribution.filterLabel",
        "agentActivity.attribution.sessionLinked",
        "agentActivity.attribution.sessionLinkedHint",
        "agentActivity.attribution.inferred",
        "agentActivity.attribution.inferredHint",
        "agentActivity.attribution.ambiguous",
        "agentActivity.attribution.ambiguousHint"
    ]
    /// Unrelated manual entries that must survive an xcstrings `ours` merge
    /// when this feature branch is brought up to date with main.
    private static let mergePreservedKeys = [
        "agent.liveness.live",
        "agent.liveness.stale",
        "agent.liveness.terminated",
        "statusbar.agentSession",
        "statusbar.agentSessions",
        "verifiedDiff.detail.applyTextHunks",
        "verifiedDiff.detail.removeCreatedFile",
        "verifiedDiff.detail.restoreDeletedFile",
        "verifiedDiff.detail.restoreExactFile",
        "verifiedDiff.detail.simulateRenamedFile",
        "verifiedDiff.expectedCurrent",
        "verifiedDiff.identity %@ %@ %@ %@ %@ %@",
        "verifiedDiff.identity.absent %@ %@",
        "verifiedDiff.kind.applyTextHunks",
        "verifiedDiff.kind.removeCreatedFile",
        "verifiedDiff.kind.restoreDeletedFile",
        "verifiedDiff.kind.restoreExactFile",
        "verifiedDiff.kind.simulateRenamedFile",
        "verifiedDiff.result",
        "verifiedDiff.stalenessNotice",
        "verifiedDiff.metadataAlsoChanges",
        "verifiedDiff.metadataOnly",
        "verifiedDiff.fileKind.regularFile",
        "verifiedDiff.fileKind.symbolicLink",
        "verifiedDiff.lineEnding.crlf",
        "verifiedDiff.lineEnding.lf",
        "verifiedDiff.lineEnding.noFinalNewline",
        "verifiedDiff.title"
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
        try expectCompleteTranslations(
            for: Self.activityKeys,
            in: catalog
        )
    }

    @Test("Merging Activity strings preserves existing agent and undo copy")
    func unrelatedAgentAndUndoStringsRemainTranslated() throws {
        let catalog = try stringsCatalog()
        try expectCompleteTranslations(
            for: Self.mergePreservedKeys,
            in: catalog
        )
    }

    private func expectCompleteTranslations(
        for keys: [String],
        in catalog: [String: Any]
    ) throws {
        for key in keys {
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
                #expect(
                    !value.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).isEmpty
                )
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
