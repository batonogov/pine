//
//  AccessibilityLocalizationMatrixTests.swift
//  PineTests
//

import Foundation
import Testing

@Suite("Accessibility localization matrix")
struct AccessibilityLocalizationMatrixTests {
    private static let supportedLocales: Set<String> = [
        "de",
        "en",
        "es",
        "fr",
        "ja",
        "ko",
        "pt-BR",
        "ru",
        "zh-Hans",
    ]

    /// One or more stable labels from every release-critical surface in the
    /// focused UI smoke. Keeping the list here makes missing translations fail
    /// in the fast unit lane before XCUITest needs to launch the app.
    private static let criticalKeys = [
        // Welcome and project entry.
        "welcome.title",
        "welcome.subtitle",
        "welcome.recentProjects",
        "openPanel.prompt",
        "welcome.revealInFinder",
        "welcome.removeFromRecent",
        "sidebar.openFolderButton",
        // Settings.
        "settings.tab.general",
        "settings.tab.terminal",
        "settings.tab.languageServers",
        "settings.tab.agentHandoff",
        "settings.tab.keyBindings",
        "settings.general.autoSave",
        "settings.terminal.cursor.shape",
        "terminal.cursor.shape.verticalBar",
        // Terminal and command surfaces.
        "terminal.label",
        "terminal.new",
        "terminal.hide",
        "terminal.maximize",
        "terminal.restore",
        "menu.quickOpen",
        "quickOpen.placeholder",
        "menu.commandPalette",
        "commandPalette.placeholder",
        "menu.symbolNavigator",
        "symbolNavigator.placeholder",
        // Agent Inbox, save/Quit decisions, and updates.
        "menu.agentInbox",
        "agentInbox.empty",
        "menu.save",
        "dialog.unsavedChanges.question %@",
        "dialog.unsavedChanges.consequence",
        "dialog.unsavedChanges.cancel",
        "dialog.unsavedChanges.dontSave",
        "dialog.unsavedChanges.save",
        "quit.summary.title",
        "quit.summary.quitAnyway",
        "quit.summary.review",
        "menu.checkForUpdates",
    ]

    @Test("Critical surfaces have explicit translations in every locale")
    func criticalSurfaceTranslations() throws {
        let catalog = try Self.loadCatalog()
        #expect(catalog.sourceLanguage == "en")

        for key in Self.criticalKeys {
            let entry = try #require(
                catalog.strings[key],
                "Missing localization key: \(key)"
            )
            let localizations = try #require(
                entry.localizations,
                "Missing localizations for: \(key)"
            )
            #expect(
                Set(localizations.keys) == Self.supportedLocales,
                "\(key) must cover the complete supported-locale matrix"
            )

            for locale in Self.supportedLocales {
                let unit = try #require(
                    localizations[locale]?.stringUnit,
                    "\(key) has no static string for \(locale)"
                )
                #expect(
                    unit.state == "translated",
                    "\(key) is not translated for \(locale)"
                )
                #expect(
                    !unit.value.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).isEmpty,
                    "\(key) is empty for \(locale)"
                )
                #expect(
                    unit.value != key,
                    "\(key) exposes its raw key for \(locale)"
                )
            }
        }
    }

    @Test("Project and catalog declare the same supported locales")
    func projectLocaleContract() throws {
        let catalog = try Self.loadCatalog()
        let declared = catalog.strings.values.reduce(into: Set<String>()) { locales, entry in
            if let localizations = entry.localizations {
                locales.formUnion(localizations.keys)
            }
        }
        #expect(declared == Self.supportedLocales)

        let project = try String(
            contentsOf: Self.repositoryRoot
                .appending(path: "Pine.xcodeproj/project.pbxproj"),
            encoding: .utf8
        )
        for locale in Self.supportedLocales {
            let quoted = locale.contains("-") ? "\"\(locale)\"" : locale
            #expect(
                project.contains("\n\t\t\t\t\(quoted),"),
                "Xcode knownRegions omits \(locale)"
            )
        }
    }

    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func loadCatalog() throws -> Catalog {
        let data = try Data(
            contentsOf: repositoryRoot
                .appending(path: "Pine/Localizable.xcstrings")
        )
        return try JSONDecoder().decode(Catalog.self, from: data)
    }
}

private struct Catalog: Decodable {
    let sourceLanguage: String
    let strings: [String: CatalogEntry]
}

private struct CatalogEntry: Decodable {
    let localizations: [String: CatalogLocalization]?
}

private struct CatalogLocalization: Decodable {
    let stringUnit: CatalogStringUnit?
}

private struct CatalogStringUnit: Decodable {
    let state: String
    let value: String
}
