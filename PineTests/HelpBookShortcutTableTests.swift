//
//  HelpBookShortcutTableTests.swift
//  PineTests
//
//  "The help book's shortcut table matches the code" is listed under
//  #1564's verified-correct section as something not to regress, and its
//  naming section demands the table stop disagreeing with the menu. This
//  suite states both over the checked-in help book sources:
//
//  - every command that owns a built-in chord has a row whose <kbd> equals
//    that chord, unless the command is on a maintained exclusion list — so
//    a command that arrives with a chord cannot silently miss its row;
//  - for the commands #1564 renamed or re-chorded, the row's title equals
//    that locale's menu title (minus the ellipsis the table omits).
//
//  Source-scanned rather than read from Bundle.main so a stale build
//  artifact can never make the shipped table look current.
//

import Foundation
import Testing

@testable import Pine

@Suite("The help book shortcut table matches the menu")
struct HelpBookShortcutTableTests {
    /// One row of the shortcuts table.
    private struct Row {
        let title: String
        let chord: String
    }

    /// Commands with a built-in chord that the curated "Essential shortcuts"
    /// table deliberately does not list. Every entry is a decision, not an
    /// oversight — adding a command to the chord table means adding a row
    /// here or a documented exclusion below.
    private static let commandsWithoutTheirOwnRow: Set<UserCommand> = [
        // File lifecycle: visible in the File menu itself, not table
        // material.
        .newFile, .openFile, .commandPalette, .closeTab, .closeProject,
        .closeWindow, .saveAll, .saveAs, .duplicate,
        // Find stepping and selection feed: the table lists the entry
        // points (Find, Find and Replace), not the steppers.
        .findNext, .findPrevious, .useSelectionForFind,
        // Diff navigation and folding: dense families behind the Edit menu.
        .acceptChange, .revertChange, .foldCode, .unfoldCode, .foldAll,
        .unfoldAll,
        // Font zoom, panels, reveal, and agent launch: discoverable in the
        // View and Window menus; the ⌘= / ⇧⌘- aliases are invisible by
        // design.
        .increaseFontSize, .decreaseFontSize, .resetFontSize, .toggleBlame,
        .showProblems, .revealFileInFinder, .showAgentInbox, .newAgent,
        // Terminal extras beyond the two the table carries.
        .sendToTerminal, .toggleTerminalZoom,
        // Change and diagnostic steppers share their paired rows below.
        .nextChange, .previousChange, .nextDiagnostic, .previousDiagnostic,
    ]

    /// The commands the table must carry as single rows: everything that
    /// owns a chord and is not excluded or paired above.
    private static var expectedSingleRowCommands: [UserCommand] {
        UserCommand.allCases.filter {
            $0.defaultChord != nil
                && !commandsWithoutTheirOwnRow.contains($0)
        }
    }

    /// The rows that join two steppers under one shared modifier prefix.
    private static var expectedPairs: [(first: UserCommand, second: UserCommand)] {
        [
            (.nextChange, .previousChange),
            (.nextDiagnostic, .previousDiagnostic),
        ]
    }

    /// A row with no UserCommand behind it: the Quick Terminal's Carbon
    /// hotkey. Only its glyph string is asserted.
    private static let literalChords = ["⌃⌥Space"]

    /// The commands whose row title must equal the localized menu title
    /// (minus the table's omitted ellipsis) — the renames of #1564.
    private static let titleKeysByCommand: [UserCommand: String] = [
        .findInFile: "menu.find",
        .goToLine: "menu.goToLine",
        .symbolNavigator: "menu.symbolNavigator",
        .togglePreview: "menu.togglePreview",
        .toggleMinimap: "menu.toggleMinimap",
        .toggleWordWrap: "menu.toggleWordWrap",
    ]

    // MARK: - The table

    @Test(
        "every locale's table carries one row per command with the right chord and title",
        arguments: LocalizationCatalog.locales
    )
    func tableMatchesCommands(locale: String) throws {
        let rows = try Self.rows(locale: locale)
        var matchedChords = Set<String>()

        // Single-command rows: one per non-excluded chord-owning command.
        for command in Self.expectedSingleRowCommands {
            let chord = try #require(
                command.defaultChord,
                "\(command.rawValue) owns no default chord"
            )
            let row = try #require(
                rows.first { $0.chord == chord.displayText },
                """
                \(locale) lists no row showing \(chord.displayText) for \
                \(command.rawValue). A command with a built-in chord needs \
                a table row here or a documented exclusion (#1564).
                """
            )
            matchedChords.insert(row.chord)

            if let titleKey = Self.titleKeysByCommand[command] {
                try Self.assertTitle(
                    row: row,
                    titleKey: titleKey,
                    locale: locale
                )
            }
        }

        // Paired rows: one shared-prefix row per stepper pair.
        for pair in Self.expectedPairs {
            let firstChord = try #require(pair.first.defaultChord)
            let secondChord = try #require(pair.second.defaultChord)
            // The pair rows share one modifier prefix and print only the
            // differing key glyph after the slash: "⌃⌥↓/↑".
            let expectedChord =
                firstChord.displayText
                + "/"
                + String(secondChord.displayText.suffix(1))
            let row = try #require(
                rows.first { $0.chord == expectedChord },
                """
                \(locale) lists no paired row "\(expectedChord)" for \
                \(pair.first.rawValue) / \(pair.second.rawValue) (#1564).
                """
            )
            matchedChords.insert(row.chord)
        }

        // Literal rows: present as written.
        for literal in Self.literalChords {
            #expect(
                rows.contains { $0.chord == literal },
                "\(locale) lists no row showing \(literal) (#1564)."
            )
            matchedChords.insert(literal)
        }

        // Nothing extra: every other row in the file was accounted for
        // above, so a stale row the code no longer backs cannot linger.
        let unaccounted = rows.filter { !matchedChords.contains($0.chord) }
        #expect(
            unaccounted.isEmpty,
            """
            \(locale) carries rows no UserCommand backs: \
            \(unaccounted.map(\.chord)). A renamed or removed command's row \
            must go with it (#1564).
            """
        )
    }

    /// The derivation above must never silently collapse to nothing.
    @Test("the expected table covers a meaningful set of commands")
    func expectedRowsAreNonTrivial() {
        #expect(Self.expectedSingleRowCommands.count >= 10)
        #expect(!Self.literalChords.isEmpty)
    }

    // MARK: - Reading the table

    private static func assertTitle(
        row: Row,
        titleKey: String,
        locale: String
    ) throws {
        let menuTitle = try #require(
            LocalizationCatalog.value(titleKey, locale: locale),
            "\(titleKey) has no \(locale) value in Localizable.xcstrings"
        )
        let expectedTitle = menuTitle.hasSuffix("…")
            ? String(menuTitle.dropLast())
            : menuTitle
        #expect(
            row.title == expectedTitle,
            """
            \(locale) help says "\(row.title)" for \(titleKey), but the menu \
            titles it "\(menuTitle)". Help and menu must name the same \
            command the same way (#1564).
            """
        )
    }

    private static func rows(locale: String) throws -> [Row] {
        let url = try ProductionSourceScan.repositoryRoot()
            .appendingPathComponent(
                "Pine/Pine.help/Contents/Resources/\(locale).lproj/shortcuts.html"
            )
        let html = try String(contentsOf: url, encoding: .utf8)
        let expression = try NSRegularExpression(
            pattern: #"<div class="shortcut"><span>(.*?)</span><kbd>(.*?)</kbd></div>"#
        )
        let range = NSRange(html.startIndex..., in: html)
        return expression.matches(in: html, range: range).compactMap { match in
            guard
                let title = Range(match.range(at: 1), in: html),
                let chord = Range(match.range(at: 2), in: html)
            else { return nil }
            return Row(
                title: String(html[title]),
                chord: String(html[chord])
            )
        }
    }
}
