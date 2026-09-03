//
//  LocalizationCentralizationGuardTests.swift
//  PineTests
//
//  Guards the two structural rules #1536 established for the string catalog:
//
//  1. Raw `String(localized:)` access lives in `Strings.swift` (or in a
//     frozen allowlist of files pending migration) — anywhere else and new
//     keys scatter across the codebase, defeating translation memory.
//  2. Every count-bearing catalog key pluralizes, unless it is explicitly
//     allowlisted as an ordinal, ratio, or count-invariant phrasing.
//

import Foundation
import Testing

@testable import Pine

@Suite("Localization centralization guards")
struct LocalizationCentralizationGuardTests {
    /// Files that still call `String(localized:)` directly. Every one of them
    /// predates the centralization rule; when a file is migrated to
    /// `Strings.swift` accessors, shrink this list. `Pine/Extensibility/**`
    /// entries belong to the extensibility surface and are migrated with it.
    private static let rawCatalogAccessAllowlist: Set<String> = [
        "Pine/AboutInfo.swift",
        "Pine/Agent/AgentActivityView.swift",
        "Pine/Agent/AgentInboxView.swift",
        "Pine/Agent/AgentNotificationController.swift",
        "Pine/CommandPaletteView.swift",
        "Pine/Extensibility/CommandPaletteModel.swift",
        "Pine/Extensibility/UserCommand+Palette.swift",
        "Pine/Extensibility/UserConfigurationDiagnostic+Localized.swift",
        "Pine/Extensibility/UserConfigurationEditor.swift",
        "Pine/GoToLineView.swift",
        "Pine/NativeRecentProjectsMenu.swift",
        "Pine/PineAppMenuCommands.swift",
        "Pine/ProjectWindowSession.swift",
        "Pine/QuickOpenView.swift",
        "Pine/Strings.swift",
        "Pine/SymbolNavigatorView.swift",
        "Pine/Tabs/TabPersistence.swift",
    ]

    /// Count-bearing keys that legitimately carry no plural variations, with
    /// the reason each is exempt:
    ///
    /// - Ordinals and identifiers: the number names a line, pane, terminal,
    ///   argument, or exit code — no noun agrees with it.
    /// - Ratios: "2 of 5" style current/total or shown/total pairs.
    /// - Count-invariant phrasing: every existing translation phrases the
    ///   sentence so the same string is grammatical for any count (colon-
    ///   separated counts, bare numerals after "и ещё"/"…and N more").
    /// - `a11y.statusBar.git.*`: "Category: N" accessibility labels, which
    ///   need no plural agreement in any supported locale (#1533).
    private static let nonPluralCountKeyAllowlist: Set<String> = [
        "%@ — line %lld",
        "a11y.statusBar.cursorPosition.value %lld %lld",
        "a11y.statusBar.git.added %lld",
        "a11y.statusBar.git.modified %lld",
        "a11y.statusBar.git.untracked %lld",
        "agentWorktrees.moreChanges %lld",
        // Announced only for counts ≥ 2 (count == 1 routes to
        // commandOverlay.announcement.oneResult), so the English plural is
        // always grammatical; the Russian phrasing is count-invariant.
        "commandOverlay.announcement.manyResults",
        // Line ordinal inside a VoiceOver announcement.
        "commandOverlay.announcement.symbol",
        // Line/column ordinals.
        "diagnostic.lineColumn",
        "diagnostic.line",
        "Enter a line number from 1 to %lld",
        // "3 of 4" position ratio.
        "globalTabSwitcher.announcement",
        "Line %lld is out of range (1–%lld)",
        "pane.positionLabel",
        "quit.summary.message %lld",
        "search.truncatedTotal %lld %lld",
        // Label-shaped reload summary: neither count agrees a noun, so
        // every (tasks, keybindings) pair is grammatical through the single
        // format production reads (cf. quit.summary.message).
        "userConfig.reloadSuccess.message",
        // Line/column ordinals — the numbers name a position, no noun
        // agrees with them.
        "statusbar.cursorPosition %lld %lld",
        // The indent width (always ≥ 2 — IndentationStyle.detect clamps to
        // 2...8) naming a setting, not counting objects; every translation
        // phrases it as a count-invariant "label: N".
        "statusbar.indentation.spaces %lld",
        "settings.lsp.error.argument %lld",
        "terminal.numberedName %lld",
        "terminal.search.matchCount %lld %lld",
        // Entry ordinals ("duplicates entry 3"), not counts.
        "userConfig.diagnostic.duplicateChord",
        "userConfig.diagnostic.duplicateCommand",
        "userConfig.diagnostic.duplicateTaskID",
        "userConfig.diagnostic.entryPrefix",
        "userTask.run.status.exitCode",
    ]

    private static let supportedLocales = [
        "de", "en", "es", "fr", "ja", "ko", "pt-BR", "ru", "zh-Hans",
    ]

    // MARK: - Raw catalog access

    @Test("Raw catalog access stays inside Strings.swift or the frozen allowlist")
    func rawCatalogAccessIsCentralized() throws {
        let root = try ProductionSourceScan.repositoryRoot()
        let sourceURLs = try ProductionSourceScan.swiftFileURLs(
            under: root.appendingPathComponent("Pine")
        )
        let expression = try NSRegularExpression(
            pattern: #"(?:String\s*\(\s*localized:|NSLocalizedString\s*\()"#
        )

        var callers: Set<String> = []
        for url in sourceURLs {
            let source = try String(contentsOf: url, encoding: .utf8)
            let relativePath = url.path.replacingOccurrences(
                of: root.path + "/",
                with: ""
            )
            if expression.firstMatch(
                in: source,
                range: NSRange(source.startIndex..., in: source)
            ) != nil {
                callers.insert(relativePath)
            }
        }

        let unlisted = callers.subtracting(Self.rawCatalogAccessAllowlist)
        #expect(
            unlisted.isEmpty,
            """
            Files calling String(localized:) or NSLocalizedString outside \
            Strings.swift. Route new keys through Pine/Strings.swift, or \
            extend the allowlist only for pre-existing debt:
            \(unlisted.sorted().joined(separator: "\n"))
            """
        )

        // The allowlist must not rot: a listed file that no longer calls
        // String(localized:) has been migrated and its entry must go.
        let stale = Self.rawCatalogAccessAllowlist.subtracting(callers)
        #expect(
            stale.isEmpty,
            """
            Stale allowlist entries — these files no longer call \
            String(localized:); remove them from the allowlist:
            \(stale.sorted().joined(separator: "\n"))
            """
        )
    }

    // MARK: - Plural coverage

    @Test("Count-bearing keys pluralize unless explicitly allowlisted")
    func countKeysPluralize() throws {
        let strings = try Self.loadCatalog()
        var missing: [String] = []

        for key in strings.keys.sorted() {
            guard let entry = strings[key] as? [String: Any],
                  entry["shouldTranslate"] as? Bool != false,
                  let localizations = entry["localizations"] as? [String: Any],
                  let english = localizations["en"] as? [String: Any]
            else {
                continue
            }
            let values = Self.stringUnitValues(in: english)
            let carriesCount = values.contains { value in
                // Plain and positional integer specifiers ("%lld",
                // "%1$lld"), plus named substitutions ("%#@lld@").
                value.contains("%lld")
                    || value.contains("$lld")
                    || value.contains("%#@")
            }
            let pluralizes = Self.hasPluralStructure(english)
            if carriesCount && !pluralizes
                && !Self.nonPluralCountKeyAllowlist.contains(key) {
                missing.append(key)
            }
        }

        #expect(
            missing.isEmpty,
            """
            Count-bearing keys without plural variations. Add variations for \
            all 9 locales (see settings.keyBindings.activeCount for the \
            format), or allowlist the key here with a reason if it is an \
            ordinal, ratio, or count-invariant phrasing:
            \(missing.joined(separator: "\n"))
            """
        )
    }

    @Test("Pluralized keys pluralize in every supported locale")
    func pluralKeysCoverEveryLocale() throws {
        let strings = try Self.loadCatalog()
        var incomplete: [String] = []

        for key in strings.keys.sorted() {
            guard let entry = strings[key] as? [String: Any],
                  entry["shouldTranslate"] as? Bool != false,
                  let localizations = entry["localizations"] as? [String: Any],
                  let english = localizations["en"] as? [String: Any],
                  Self.hasPluralStructure(english)
            else {
                continue
            }
            for locale in Self.supportedLocales {
                guard let localization = localizations[locale] as? [String: Any],
                      Self.hasPluralStructure(localization),
                      !Self.stringUnitValues(in: localization).isEmpty
                else {
                    incomplete.append("\(key) [\(locale)]")
                    continue
                }
            }
        }

        #expect(
            incomplete.isEmpty,
            """
            Keys plural in English but flat in some locale — that locale \
            renders every count with the one string it has ("1 ошибок"):
            \(incomplete.joined(separator: "\n"))
            """
        )
    }

    @Test("No parenthetical plural hacks in any translation")
    func noParentheticalPluralHacks() throws {
        let strings = try Self.loadCatalog()
        let hacks = ["(s)", "(en)", "(ões)", "(ées)"]
        var offenders: [String] = []

        for key in strings.keys.sorted() {
            guard let entry = strings[key] as? [String: Any],
                  entry["shouldTranslate"] as? Bool != false,
                  let localizations = entry["localizations"] as? [String: Any]
            else {
                continue
            }
            for (locale, raw) in localizations {
                guard let localization = raw as? [String: Any] else { continue }
                for value in Self.stringUnitValues(in: localization)
                where hacks.contains(where: { value.contains($0) }) {
                    offenders.append("\(key) [\(locale)]: \(value)")
                }
            }
        }

        #expect(
            offenders.isEmpty,
            """
            Parenthetical plural hacks ("change(s)") left in translations. \
            Replace with plural variations:
            \(offenders.joined(separator: "\n"))
            """
        )
    }

    // MARK: - Helpers

    private static func loadCatalog() throws -> [String: Any] {
        let root = try ProductionSourceScan.repositoryRoot()
        let data = try Data(contentsOf: root.appendingPathComponent(
            "Pine/Localizable.xcstrings"
        ))
        guard
            let decoded = try JSONSerialization.jsonObject(with: data)
                as? [String: Any],
            let strings = decoded["strings"] as? [String: Any]
        else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return strings
    }

    private static func hasPluralStructure(_ localization: [String: Any]) -> Bool {
        let hasVariations = (localization["variations"] as? [String: Any])?["plural"]
            != nil
        let hasSubstitutions = localization["substitutions"] != nil
        return hasVariations || hasSubstitutions
    }

    private static func stringUnitValues(in value: Any) -> [String] {
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
}
