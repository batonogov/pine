//
//  CommandOverlaySelectionAnnouncementTests.swift
//  PineTests
//

import AppKit
import Foundation
import Testing

@testable import Pine

/// Unit coverage for `CommandOverlaySelectionAnnouncer` and the localization
/// catalog behind the overlay announcements (#1497).
///
/// Time-limited deliberately: `settle` is budgeted in polls, not wall-clock
/// time, so a broken announcer does not fail fast — it spends its whole budget
/// waiting. Without a ceiling that reads as a hung run rather than a red test,
/// which is exactly the unreadable failure mode #1506 was filed about. The
/// limit is per test, not per suite, and it tightens rather than loosens the
/// status quo — the bundle runs with `-test-timeouts-enabled YES` and no
/// `-default-test-execution-time-allowance`, so the alternative is Xcode's
/// 600-second default.
///
/// Three minutes, not one — see the same note on
/// `CommandOverlayHostedAnnouncementTests`. The headroom is sized from a
/// *local* measurement: on macOS 27.0 (26A5416b) / Xcode 27.0 (27A5237l) /
/// macosx SDK 27.0 (26A5406c), a full parallel `PineTests` run records
/// 59.7–61.8 seconds of elapsed time for tests that do no I/O whatsoever, so
/// a one-minute ceiling fires there on runs that are otherwise healthy. CI
/// does not show this: the macos-26 runner completes 6744 tests in 396.658 s
/// with zero retries.
@Suite("Command overlay selection announcements", .timeLimit(.minutes(3)))
@MainActor
struct CommandOverlaySelectionAnnouncementTests {
    private static let languages = [
        "de", "en", "es", "fr", "ja", "ko", "pt-BR", "ru", "zh-Hans",
    ]

    /// Settle budget in polls — see `settle(pollBudget:condition:)`.
    private static let settlePollBudget = 200

    /// Wait between polls so the announcer's debounced task can run. Sleeping
    /// leaves the main actor free; spinning on `Task.yield()` did not.
    private static let settlePollInterval = Duration.milliseconds(5)

    private static let localizationKeys = [
        "commandOverlay.announcement.noResults",
        "commandOverlay.announcement.oneResult",
        "commandOverlay.announcement.manyResults",
        "commandOverlay.announcement.shortcut",
        "commandOverlay.announcement.unavailable",
        "commandOverlay.announcement.symbol",
    ]

    @Test("Rapid result changes coalesce to the newest summary")
    func resultChangesCoalesce() async {
        let recorder = AnnouncementRecorder()
        let announcer = CommandOverlaySelectionAnnouncer(
            delay: .milliseconds(10)
        )

        announcer.schedule("Old results", using: recorder.record)
        announcer.schedule("Current results", using: recorder.record)
        let delivered = await settle {
            recorder.messages == ["Current results"]
        }

        #expect(
            delivered,
            "Announcer never delivered; recorded \(recorder.messages)."
        )
        #expect(recorder.messages == ["Current results"])
    }

    @Test("Keyboard selection is immediate and cancels a pending summary")
    func keyboardSelectionIsImmediate() async {
        let recorder = AnnouncementRecorder()
        let announcer = CommandOverlaySelectionAnnouncer(
            delay: .milliseconds(20)
        )

        announcer.schedule("Pending results", using: recorder.record)
        announcer.announceImmediately("Selected file", using: recorder.record)
        #expect(recorder.messages == ["Selected file"])

        try? await Task.sleep(for: .milliseconds(40))
        #expect(recorder.messages == ["Selected file"])
    }

    @Test("Duplicate messages and rejected stale owners are not spoken")
    func duplicateAndStaleDeliveryAreSuppressed() {
        let recorder = AnnouncementRecorder()
        let announcer = CommandOverlaySelectionAnnouncer(delay: .zero)

        announcer.announceImmediately("Same row", using: recorder.record)
        announcer.announceImmediately("Same row", using: recorder.record)
        announcer.announceImmediately("Stale row") { _ in false }

        #expect(recorder.messages == ["Same row"])

        // The rejected delivery must not have moved the duplicate-suppression
        // boundary. `deliverIfNeeded` only advances `lastDeliveredMessage`
        // once the sink accepts; drop that guard (`_ = sink(message)`) and
        // every assertion above still passes, while "Stale row" is recorded
        // as spoken and this line goes permanently silent for VoiceOver.
        announcer.announceImmediately("Stale row", using: recorder.record)
        #expect(recorder.messages == ["Same row", "Stale row"])
    }

    @Test("Quick Open includes useful path context without duplication")
    func quickOpenProjection() {
        #expect(
            CommandOverlaySelectionAnnouncement.quickOpenRow(
                fileName: "main.swift",
                relativePath: "Sources/App/main.swift"
            ) == "main.swift, Sources/App/main.swift"
        )
        #expect(
            CommandOverlaySelectionAnnouncement.quickOpenRow(
                fileName: "README.md",
                relativePath: "README.md"
            ) == "README.md"
        )
    }

    @Test("Command Palette includes shortcut and disabled reason")
    func commandPaletteProjection() {
        let item = CommandPaletteItem(
            id: .builtIn(.quickOpen),
            title: "Quick Open",
            subtitle: "File",
            searchTerms: [],
            iconName: "doc.text.magnifyingglass",
            shortcut: CommandShortcutPresentation(
                chord: ParsedKeyChord(modifiers: .command, key: "p"),
                state: .builtIn
            ),
            isEnabled: false,
            unavailabilityReason: "Open a project first"
        )

        let message = CommandOverlaySelectionAnnouncement.commandPaletteRow(
            item: item,
            locale: Locale(identifier: "en")
        )
        #expect(message.contains("Quick Open"))
        #expect(message.contains("Shortcut: ⌘P"))
        #expect(message.contains("Unavailable: Open a project first"))
    }

    @Test("Symbol projection localizes kind, name, and line")
    func symbolProjection() {
        #expect(
            CommandOverlaySelectionAnnouncement.symbolRow(
                kind: "Function",
                name: "render()",
                line: 42,
                locale: Locale(identifier: "en")
            ) == "Function, render(), line 42"
        )
        #expect(
            CommandOverlaySelectionAnnouncement.symbolRow(
                kind: "Функция",
                name: "render()",
                line: 42,
                locale: Locale(identifier: "ru")
            ) == "Функция, render(), строка 42"
        )
    }

    @Test("Result summaries distinguish empty, singular, and multiple")
    func resultSummaryProjection() {
        let locale = Locale(identifier: "en")
        #expect(
            CommandOverlaySelectionAnnouncement.resultSummary(
                count: 0,
                selectedRow: nil,
                locale: locale
            ) == "No results"
        )
        #expect(
            CommandOverlaySelectionAnnouncement.resultSummary(
                count: 1,
                selectedRow: "main.swift",
                locale: locale
            ) == "1 result. Selected: main.swift"
        )
        #expect(
            CommandOverlaySelectionAnnouncement.resultSummary(
                count: 3,
                selectedRow: "main.swift",
                locale: locale
            ) == "3 results. Selected: main.swift"
        )
    }

    @Test("Every announcement key contains all supported locales")
    func localizationCatalogIsComplete() throws {
        let catalog = try Self.catalog()
        for key in Self.localizationKeys {
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
                #expect(!value.isEmpty)
            }
        }
    }

    private static func catalog(
        filePath: String = #filePath
    ) throws -> [String: Any] {
        let testURL = URL(fileURLWithPath: filePath)
        let projectRoot = testURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(
            contentsOf: projectRoot.appendingPathComponent(
                "Pine/Localizable.xcstrings"
            )
        )
        let root = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        return try #require(root["strings"] as? [String: Any])
    }

    /// Polls `condition`, budgeted in scheduling opportunities rather than
    /// wall-clock time.
    ///
    /// The previous shape — a one-second deadline spun with `Task.yield()` —
    /// failed for reasons that had nothing to do with the announcer. In a
    /// local Xcode run `PineTests` executes its suites in parallel inside one
    /// process (the default there; CI passes `-parallel-testing-enabled NO`
    /// at `.github/workflows/ci.yml:324` and `:396`, so on CI the suites are
    /// sequential and this budget degrades to an ordinary 1-second deadline),
    /// and unrelated `@MainActor` suites block the main thread for seconds at
    /// a time: `GitStatusProviderTests` runs `/bin/sh` through
    /// `process.waitUntilExit()`, and `AgentHistoryCheckedUndoEngineTests`
    /// blocks on `DispatchSemaphore.wait(timeout:)` for up to two seconds. The
    /// deadline expired while the announcer's debounced delivery never got a
    /// turn, and the busy `Task.yield()` loop burned the main actor it was
    /// waiting on.
    ///
    /// Counting polls instead makes starvation delay the gate rather than fail
    /// it, and sleeping between polls leaves the main actor free. It is not
    /// determinism, though: it is still a budget, just one denominated in
    /// something the test controls. A real announcer regression that needs
    /// between roughly 30 and roughly 200 scheduling opportunities now passes
    /// here where it used to fail; the suite-level `.timeLimit` is what keeps
    /// an unsatisfiable budget from reading as a hung run (#1506).
    ///
    /// A cancelled sleep ends the wait after one more check rather than being
    /// swallowed. When the suite `.timeLimit` fires, `Task.sleep` throws; a
    /// `try?` here would let the loop grind through its remaining budget and
    /// return `false`, stacking a second issue on top of `timeLimitExceeded`
    /// — two failures for one cause.
    private func settle(
        pollBudget: Int = CommandOverlaySelectionAnnouncementTests
            .settlePollBudget,
        condition: @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0..<pollBudget {
            if condition() { return true }
            do {
                try await Task.sleep(for: Self.settlePollInterval)
            } catch {
                return condition()
            }
        }
        return condition()
    }
}

@MainActor
private final class AnnouncementRecorder {
    private(set) var messages: [String] = []

    func record(_ message: String) -> Bool {
        messages.append(message)
        return true
    }
}
