//
//  SettingsLocalizationTests.swift
//  PineTests
//

import Foundation
import Testing

@testable import Pine

@Suite("Settings localization")
struct SettingsLocalizationTests {
    @Test("Key bindings use native macOS shortcut glyphs")
    func keyBindingGlyphs() throws {
        let letterChord = try #require(
            UserKeybindingRegistry.parse("ctrl+option+shift+cmd+f")
        )
        let namedKeyChord = try #require(
            UserKeybindingRegistry.parse("cmd+return")
        )

        #expect(
            KeyBindingsTasksSettingsView.chordDescription(letterChord)
                == "⌃⌥⇧⌘F"
        )
        #expect(
            KeyBindingsTasksSettingsView.chordDescription(namedKeyChord)
                == "⌘↩"
        )
    }

    @Test("Active-entry counts follow English and Russian plural rules")
    func activeEntryCountPlurals() {
        let counts = [0, 1, 2, 5, 21, 22, 25]

        #expect(counts.map {
            Strings.settingsKeyBindingsActiveCount(
                $0,
                locale: Locale(identifier: "en")
            )
        } == [
            "0 active entries",
            "1 active entry",
            "2 active entries",
            "5 active entries",
            "21 active entries",
            "22 active entries",
            "25 active entries",
        ])

        #expect(counts.map {
            Strings.settingsKeyBindingsActiveCount(
                $0,
                locale: Locale(identifier: "ru")
            )
        } == [
            "0 активных записей",
            "1 активная запись",
            "2 активные записи",
            "5 активных записей",
            "21 активная запись",
            "22 активные записи",
            "25 активных записей",
        ])
    }

    @Test("Successful reload summaries pluralize both counts")
    func successfulReloadSummaryPlurals() {
        let english = Locale(identifier: "en")
        let russian = Locale(identifier: "ru")

        #expect(
            Strings.settingsKeyBindingsReloadSummary(
                tasks: 1,
                keybindings: 2,
                locale: english
            ) == "Reloaded: 1 task, 2 key bindings."
        )
        #expect(
            Strings.settingsKeyBindingsReloadSummary(
                tasks: 2,
                keybindings: 5,
                locale: russian
            ) == "Перезагружено: 2 задачи, 5 сочетаний клавиш."
        )
    }

    @Test("Reload diagnostics use locale-specific plural categories")
    func reloadProblemPlurals() {
        let english = Locale(identifier: "en")
        let russian = Locale(identifier: "ru")

        #expect(
            Strings.settingsKeyBindingsReloadProblems(1, locale: english)
                == "Reloaded with 1 problem."
        )
        #expect(
            Strings.settingsKeyBindingsReloadProblems(2, locale: english)
                == "Reloaded with 2 problems."
        )
        #expect(
            Strings.settingsKeyBindingsReloadProblems(1, locale: russian)
                == "Перезагружено с 1 проблемой."
        )
        #expect(
            Strings.settingsKeyBindingsReloadProblems(2, locale: russian)
                == "Перезагружено с 2 проблемами."
        )
        #expect(
            Strings.settingsKeyBindingsReloadProblems(5, locale: russian)
                == "Перезагружено с 5 проблемами."
        )
    }

    @Test("System-facing Settings controls resolve through the catalog")
    func systemControlLabels() {
        #expect(
            Strings.lspChooseExecutablePrompt(
                locale: Locale(identifier: "en")
            ) == "Choose"
        )
        #expect(
            Strings.lspChooseExecutablePrompt(
                locale: Locale(identifier: "ru")
            ) == "Выбрать"
        )
        #expect(
            Strings.dialogClose(locale: Locale(identifier: "ru"))
                == "Закрыть"
        )
    }
}
