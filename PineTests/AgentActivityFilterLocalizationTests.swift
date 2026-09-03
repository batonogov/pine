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
        "agentAction.detail.evidenceLabel",
        "agentAction.detail.fileLabel",
        "agentAction.detail.kindLabel",
        "agentAction.detail.relatedTerminalLabel",
        "agentAction.detail.summaryLabel",
        "agentAction.detail.statusLabel",
        "agentAction.detail.timestampLabel",
        "agentAction.detail.workingDirectoryLabel",
        "agentAction.kind.command",
        "agentAction.kind.fileRead",
        "agentAction.kind.fileWrite",
        "agentAction.kind.toolCall",
        "agentAction.status.completed",
        "agentAction.status.failed",
        "agentAction.status.inProgress",
        "agentAction.status.pending",
        "agentActivity.noMatches",
        "agentActivity.attribution.filterLabel",
        "agentActivity.attribution.verified",
        "agentActivity.attribution.verifiedHint",
        "agentActivity.attribution.sessionLinked",
        "agentActivity.attribution.sessionLinkedHint",
        "agentActivity.attribution.inferred",
        "agentActivity.attribution.inferredHint",
        "agentActivity.attribution.ambiguous",
        "agentActivity.attribution.ambiguousHint",
        "agentActivity.attribution.stale",
        "agentActivity.attribution.staleHint",
        "agentActivity.attribution.terminated",
        "agentActivity.attribution.terminatedHint",
        "agentActivity.rowInspectHint",
        "agentActivity.resetFilters",
        "agentActivity.allAttributions",
        "agentActivity.allKinds",
        "agentActivity.allStatuses",
        "agentActivity.detail.copied",
        "agentActivity.detail.copy",
        "agentActivity.detail.goToTerminal",
        "agentActivity.detail.openFile",
        "agentState.idle",
        "agentState.thinking",
        "agentState.executing",
        "agentState.waitingInput",
        "agentState.done"
    ]
    /// Unrelated manual entries that must survive an xcstrings `ours` merge
    /// when this feature branch is brought up to date with main.
    private static let mergePreservedKeys = [
        "a11y.sidebar.collapse.action",
        "a11y.sidebar.disclosure.collapsed",
        "a11y.sidebar.disclosure.expanded",
        "a11y.sidebar.expand.action",
        "a11y.sidebar.folder.hint",
        "agent.liveness.live",
        "agent.liveness.stale",
        "agent.liveness.terminated",
        "menu.nextDiagnostic",
        "menu.previousDiagnostic",
        "menu.problems",
        "problems.close",
        "problems.filter.allSeverities",
        "problems.filter.allSources",
        "problems.filter.severity",
        "problems.filter.source",
        "problems.panelTitle",
        "problems.state.disabled",
        "problems.state.loading",
        "problems.state.unavailable",
        "problems.state.unsupported",
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

    @Test("Every Activity evidence/status string is translated in all supported languages")
    func allLanguagesPresent() throws {
        let catalog = try stringsCatalog()
        try expectCompleteTranslations(
            for: Self.activityKeys,
            in: catalog
        )
    }

    @Test("Merging Activity strings preserves main and existing feature copy")
    func unrelatedMainAndFeatureStringsRemainTranslated() throws {
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
        #expect(catalog["agentActivity.attribution.verified"] != nil)
        #expect(catalog["agentActivity.attribution.stale"] != nil)
        #expect(catalog["agentActivity.attribution.terminated"] != nil)
    }
}
