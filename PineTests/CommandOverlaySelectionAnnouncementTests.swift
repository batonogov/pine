//
//  CommandOverlaySelectionAnnouncementTests.swift
//  PineTests
//

import AppKit
import Foundation
import Testing

@testable import Pine

@Suite("Command overlay selection announcements")
@MainActor
struct CommandOverlaySelectionAnnouncementTests {
    private static let languages = [
        "de", "en", "es", "fr", "ja", "ko", "pt-BR", "ru", "zh-Hans",
    ]

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
        let delivered = await waitUntil {
            recorder.messages == ["Current results"]
        }

        #expect(delivered)
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

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else { return false }
            await Task.yield()
        }
        return true
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
