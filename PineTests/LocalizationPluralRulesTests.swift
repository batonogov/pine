//
//  LocalizationPluralRulesTests.swift
//  PineTests
//
//  Runtime plural coverage for the count-bearing catalog keys that used to
//  render "1 ошибок" in Russian (#1536). Russian is the canary — it needs
//  one/few/many — and every locale with noun agreement is checked on 1 vs 2.
//

import Foundation
import Testing

@testable import Pine

@Suite("Localization plural rules")
struct LocalizationPluralRulesTests {
    /// Counts that exercise the Russian one (1), few (2), many (5), and
    /// other/zero (0) categories, plus English one vs other.
    private static let counts = [0, 1, 2, 5]

    private static let english = Locale(identifier: "en")
    private static let russian = Locale(identifier: "ru")

    // MARK: - Validation / Problems counts

    @Test("Error counts follow Russian one/few/many and English one/other")
    func errorCountPlurals() {
        #expect(Self.counts.map {
            Strings.validationErrorCount($0, locale: Self.english)
        } == [
            "0 errors", "1 error", "2 errors", "5 errors",
        ])
        #expect(Self.counts.map {
            Strings.validationErrorCount($0, locale: Self.russian)
        } == [
            "0 ошибок", "1 ошибка", "2 ошибки", "5 ошибок",
        ])
    }

    @Test("Warning counts follow Russian one/few/many and English one/other")
    func warningCountPlurals() {
        #expect(Self.counts.map {
            Strings.validationWarningCount($0, locale: Self.english)
        } == [
            "0 warnings", "1 warning", "2 warnings", "5 warnings",
        ])
        #expect(Self.counts.map {
            Strings.validationWarningCount($0, locale: Self.russian)
        } == [
            "0 предупреждений", "1 предупреждение", "2 предупреждения",
            "5 предупреждений",
        ])
    }

    @Test("Problems summary has no singular special case left to regress")
    func problemsCountsDelegateToPluralRules() {
        #expect(
            Strings.problemsErrorCount(1, locale: Self.english)
                == "1 error"
        )
        #expect(
            Strings.problemsWarningCount(1, locale: Self.russian)
                == "1 предупреждение"
        )
        #expect(
            Strings.problemsErrorCount(5, locale: Self.russian)
                == "5 ошибок"
        )
    }

    // MARK: - Agent activity / completion counts

    @Test("Possible-session subtitles pluralize in agreeing locales")
    func possibleSessionsPlurals() {
        #expect(
            Strings.agentActivityPossibleSessions(2, locale: Self.english)
                == "2 possible sessions"
        )
        #expect(
            Strings.agentActivityPossibleSessions(1, locale: Self.english)
                == "1 possible session"
        )
        // Russian phrasing is count-invariant, but must still resolve.
        #expect(
            Strings.agentActivityPossibleSessions(1, locale: Self.russian)
                == "Возможных сеансов: 1"
        )
        #expect(
            Strings.agentActivityPossibleSessions(2, locale: Self.russian)
                == "Возможных сеансов: 2"
        )
        // French and Portuguese agree the noun.
        #expect(
            Strings.agentActivityPossibleSessions(1, locale: Locale(identifier: "fr"))
                == "1 session possible"
        )
        #expect(
            Strings.agentActivityPossibleSessions(2, locale: Locale(identifier: "fr"))
                == "2 sessions possibles"
        )
        #expect(
            Strings.agentActivityPossibleSessions(1, locale: Locale(identifier: "pt-BR"))
                == "1 sessão possível"
        )
        #expect(
            Strings.agentActivityPossibleSessions(2, locale: Locale(identifier: "pt-BR"))
                == "2 sessões possíveis"
        )
    }

    @Test("Verified test-run counts pluralize")
    func verifiedTestsPlurals() {
        #expect(
            Strings.agentCompletionVerifiedTests(1, locale: Self.english)
                == "1 verified test run"
        )
        #expect(
            Strings.agentCompletionVerifiedTests(2, locale: Self.english)
                == "2 verified test runs"
        )
        #expect(
            Strings.agentCompletionVerifiedTests(1, locale: Self.russian)
                == "Подтверждённых запусков тестов: 1"
        )
    }

    @Test("Gap briefs pluralize the file count")
    func gapBriefPlurals() {
        #expect(
            Strings.agentCompletionGapOverlaps(1, locale: Self.english)
                == "1 file has overlapping or ambiguous edits."
        )
        #expect(
            Strings.agentCompletionGapOverlaps(2, locale: Self.english)
                == "2 files have overlapping or ambiguous edits."
        )
        #expect(
            Strings.agentCompletionGapOverlaps(1, locale: Self.russian)
                == "В 1 файле есть пересекающиеся или неоднозначные правки."
        )
        #expect(
            Strings.agentCompletionGapOverlaps(2, locale: Self.russian)
                == "В 2 файлах есть пересекающиеся или неоднозначные правки."
        )
        #expect(
            Strings.agentCompletionGapStatistics(1, locale: Self.english)
                == "Exact diff statistics are unavailable for 1 file."
        )
        #expect(
            Strings.agentCompletionGapStatistics(2, locale: Self.english)
                == "Exact diff statistics are unavailable for 2 files."
        )
        #expect(
            Strings.agentCompletionGapStatistics(1, locale: Self.russian)
                == "Для 1 файла точная статистика diff недоступна."
        )
        #expect(
            Strings.agentCompletionGapStatistics(5, locale: Self.russian)
                == "Для 5 файлов точная статистика diff недоступна."
        )
    }

    // MARK: - Search truncation

    @Test("Per-file truncation footers pluralize the match cap")
    func truncatedPerFilePlurals() {
        #expect(
            Strings.searchTruncatedPerFile(1, locale: Self.english)
                == "Per-file results limited to 1 match — refine your query"
        )
        #expect(
            Strings.searchTruncatedPerFile(2, locale: Self.english)
                == "Per-file results limited to 2 matches — refine your query"
        )
        // Russian phrasing keeps the numeral bare, so every category
        // resolves to the same sentence — still through the plural path.
        #expect(
            Strings.searchTruncatedPerFile(5, locale: Self.russian)
                == "Результатов на файл: не более 5 — уточните запрос"
        )
    }

    // MARK: - Reload toasts

    @Test("Reload toasts pluralize the file count and keep the name list")
    func filesReloadedToastPlurals() {
        #expect(
            Strings.toastFilesReloaded(
                count: 1,
                names: "a.swift",
                locale: Self.english
            ) == "1 file reloaded: a.swift"
        )
        #expect(
            Strings.toastFilesReloaded(
                count: 2,
                names: "a.swift, b.swift",
                locale: Self.english
            ) == "2 files reloaded: a.swift, b.swift"
        )
        #expect(
            Strings.toastFilesReloaded(
                count: 1,
                names: "a.swift",
                locale: Self.russian
            ) == "1 файл перезагружен: a.swift"
        )
        #expect(
            Strings.toastFilesReloaded(
                count: 2,
                names: "a.swift",
                locale: Self.russian
            ) == "2 файла перезагружено: a.swift"
        )
        #expect(
            Strings.toastFilesReloaded(
                count: 5,
                names: "a.swift",
                locale: Self.russian
            ) == "5 файлов перезагружено: a.swift"
        )
    }

    @Test("Overflow reload toasts pluralize while keeping both counts")
    func filesReloadedMoreToastPlurals() {
        #expect(
            Strings.toastFilesReloadedMore(
                count: 1,
                names: "a.swift",
                remaining: 2,
                locale: Self.english
            ) == "1 file reloaded: a.swift and 2 more"
        )
        #expect(
            Strings.toastFilesReloadedMore(
                count: 5,
                names: "a.swift",
                remaining: 2,
                locale: Self.english
            ) == "5 files reloaded: a.swift and 2 more"
        )
        #expect(
            Strings.toastFilesReloadedMore(
                count: 5,
                names: "a.swift",
                remaining: 2,
                locale: Self.russian
            ) == "5 файлов перезагружено: a.swift и ещё 2"
        )
        #expect(
            Strings.toastFilesReloadedMore(
                count: 1,
                names: "a.swift",
                remaining: 2,
                locale: Self.russian
            ) == "1 файл перезагружен: a.swift и ещё 2"
        )
        // The `.more` branch fires with more than three names, so
        // `remaining == 1` is reachable (four files). The French trailing
        // phrase must not agree its noun: "et 1 autres" is the bug class
        // this issue exists for.
        #expect(
            Strings.toastFilesReloadedMore(
                count: 4,
                names: "a.swift",
                remaining: 1,
                locale: Locale(identifier: "fr")
            ) == "4 fichiers rechargés : a.swift et 1 de plus"
        )
    }

    @Test("Reload-success counts stay grammatical for every count pair")
    func reloadSuccessMessageAllCountPairs() throws {
        // Production reads this key through
        // String(localized:defaultValue:) with both counts interpolated in
        // the default value (PineAppMenuCommands.reloadAlert). Every
        // agreeing locale phrases the counts as category-then-number
        // labels, so (1, 1) must not produce "1 task and 1 keybindings"
        // or "Active: 1 tasks".
        #expect(
            try Self.prodPathReloadSuccess(tasks: 1, keybindings: 1, lproj: "en")
                == "Active — tasks: 1, keybindings: 1."
        )
        #expect(
            try Self.prodPathReloadSuccess(tasks: 3, keybindings: 7, lproj: "en")
                == "Active — tasks: 3, keybindings: 7."
        )
        #expect(
            try Self.prodPathReloadSuccess(tasks: 1, keybindings: 1, lproj: "ru")
                == "Активно задач: 1, сочетаний клавиш: 1."
        )
        #expect(
            try Self.prodPathReloadSuccess(tasks: 5, keybindings: 2, lproj: "ru")
                == "Активно задач: 5, сочетаний клавиш: 2."
        )
    }

    /// Resolves the key exactly the way production does —
    /// `String(localized:defaultValue:)` with the counts interpolated into
    /// the default value — pinned to a language through its `.lproj`
    /// sub-bundle.
    private static func prodPathReloadSuccess(
        tasks: Int,
        keybindings: Int,
        lproj: String
    ) throws -> String {
        let bundlePath = try #require(
            Bundle.main.path(forResource: lproj, ofType: "lproj"),
            "\(lproj).lproj is not in the test host bundle"
        )
        let bundle = try #require(
            Bundle(path: bundlePath),
            "\(lproj).lproj exists but does not load"
        )
        return String(
            localized: "userConfig.reloadSuccess.message",
            defaultValue: "\(tasks) tasks and \(keybindings) keybindings active.",
            bundle: bundle
        )
    }

    // MARK: - Worktree counts (the "(s)" hacks)

    @Test("Integration banners drop the parenthetical plural hack")
    func integratedCountPlurals() {
        #expect(
            Strings.agentWorktreesIntegratedText(
                "main",
                1,
                locale: Self.english
            ) == "Staged 1 change on “main”. Nothing was committed."
        )
        #expect(
            Strings.agentWorktreesIntegratedText(
                "main",
                2,
                locale: Self.english
            ) == "Staged 2 changes on “main”. Nothing was committed."
        )
        #expect(
            Strings.agentWorktreesIntegratedText(
                "main",
                1,
                locale: Locale(identifier: "fr")
            ) == "1 modification indexée sur « main ». Rien n’a été validé."
        )
        #expect(
            Strings.agentWorktreesIntegratedText(
                "main",
                2,
                locale: Locale(identifier: "fr")
            ) == "2 modifications indexées sur « main ». Rien n’a été validé."
        )
        #expect(
            Strings.agentWorktreesIntegratedText(
                "main",
                1,
                locale: Self.russian
            ) == "Подготовлено изменений: 1 на «main». Коммит не сделан."
        )
    }

    @Test("Dirty-path counts drop the parenthetical plural hack")
    func dirtyCountPlurals() {
        #expect(
            Strings.agentWorktreesDirtyCountText(1, locale: Locale(identifier: "fr"))
                == "1 non validée"
        )
        #expect(
            Strings.agentWorktreesDirtyCountText(2, locale: Locale(identifier: "fr"))
                == "2 non validées"
        )
        #expect(
            Strings.agentWorktreesDirtyCountText(1, locale: Locale(identifier: "pt-BR"))
                == "1 não confirmada"
        )
        #expect(
            Strings.agentWorktreesDirtyCountText(2, locale: Locale(identifier: "pt-BR"))
                == "2 não confirmadas"
        )
        #expect(
            Strings.agentWorktreesDirtyCountText(5, locale: Self.russian)
                == "5 без коммита"
        )
    }

    // MARK: - Status bar position / indentation labels

    @Test("Cursor position abbreviations resolve per locale")
    func cursorPositionLabels() {
        #expect(
            Strings.statusbarCursorPosition(line: 5, column: 10, locale: Self.english)
                == "Ln 5, Col 10"
        )
        #expect(
            Strings.statusbarCursorPosition(line: 5, column: 10, locale: Self.russian)
                == "Стр 5, Стлб 10"
        )
        #expect(
            Strings.statusbarCursorPosition(line: 1, column: 1, locale: Locale(identifier: "de"))
                == "Zl 1, Sp 1"
        )
    }

    @Test("Indentation labels resolve per locale")
    func indentationLabels() {
        #expect(
            Strings.statusbarIndentationSpaces(4, locale: Self.english)
                == "Spaces: 4"
        )
        #expect(
            Strings.statusbarIndentationTabs(locale: Self.english)
                == "Tabs"
        )
        #expect(
            Strings.statusbarIndentationSpaces(2, locale: Self.russian)
                == "Пробелы: 2"
        )
        #expect(
            Strings.statusbarIndentationTabs(locale: Self.russian)
                == "Табуляция"
        )
        // The enum routes through the same accessors.
        #expect(
            IndentationStyle.spaces(4).displayName
                == Strings.statusbarIndentationSpaces(4)
        )
        #expect(
            IndentationStyle.tabs.displayName
                == Strings.statusbarIndentationTabs()
        )
    }

    // MARK: - Rename popover

    @Test("Rename popover copy resolves per locale")
    func renamePopoverCopy() {
        #expect(
            Strings.lspRenameLabel(locale: Self.english)
                == "Rename symbol to:"
        )
        #expect(
            Strings.lspRenamePlaceholder(locale: Self.english)
                == "New name"
        )
        #expect(
            Strings.lspRenameLabel(locale: Self.russian) != "Rename symbol to:"
        )
        #expect(
            Strings.lspRenamePlaceholder(locale: Self.russian) != "New name"
        )
    }

    // MARK: - Built-in validator diagnostics

    @Test("Built-in validator diagnostics resolve per locale")
    func validatorDiagnostics() {
        #expect(
            Strings.validationYamlTabIndentation(locale: Self.english)
                == "YAML does not allow tab characters for indentation, use spaces"
        )
        #expect(
            Strings.validationYamlTrailingWhitespace(locale: Self.english)
                == "Trailing whitespace"
        )
        #expect(
            Strings.validationYamlUnusualIndentation(3, locale: Self.english)
                == "Unusual indentation (3 spaces) — YAML typically uses 2 or 4 spaces"
        )
        #expect(
            Strings.validationYamlAmbiguousMapping(locale: Self.english)
                == "Ambiguous mapping entry — value contains unquoted ': '"
        )
        #expect(
            Strings.validationShellUnquotedVariable(locale: Self.english)
                == "Unquoted variable in test — use \"$var\" to prevent word splitting"
        )
        #expect(
            Strings.validationShellBackticks(locale: Self.english)
                == "Use $(...) instead of backticks for command substitution"
        )
        #expect(
            Strings.validationDockerfileInvalidInstruction("run", locale: Self.english)
                == "Invalid Dockerfile instruction 'run'"
        )
        #expect(
            Strings.validationDockerfileMaintainerDeprecated(locale: Self.english)
                == "MAINTAINER is deprecated, use LABEL maintainer=\"...\" instead"
        )
        #expect(
            Strings.validationDockerfileInstructionCase(
                "from",
                "FROM",
                locale: Self.english
            ) == "Instruction 'from' should be uppercase 'FROM'"
        )
        #expect(
            Strings.validationDockerfileMissingFrom(locale: Self.english)
                == "Dockerfile must start with a FROM instruction"
        )
        // Non-English locales must not fall back to the English literals
        // for at least the two most visible diagnostics.
        #expect(
            Strings.validationYamlTrailingWhitespace(locale: Self.russian)
                != "Trailing whitespace"
        )
        #expect(
            Strings.validationDockerfileMissingFrom(locale: Self.russian)
                != "Dockerfile must start with a FROM instruction"
        )
    }
}
