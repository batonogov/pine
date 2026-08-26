//
//  AlertWordingAndRecoveryTruthTests.swift
//  PineTests
//
//  The HIG structure of the close confirmations, and the two recovery
//  surfaces that used to answer every distinct failure with one sentence
//  (#1541).
//

import Foundation
import SwiftUI
import Testing

@testable import Pine

@Suite("Alert wording and truthful recovery failures")
@MainActor
struct AlertWordingAndRecoveryTruthTests {
    private static let locales = [
        "de", "en", "es", "fr", "ja", "ko", "pt-BR", "ru", "zh-Hans",
    ]

    // MARK: - Close confirmation structure

    /// The message text is the question and the informative text is the
    /// consequence. Reversed — a noun-phrase title with the question in the
    /// body — is what Pine shipped, and it reads as a label rather than as
    /// something being asked.
    @Test("the single-file close question names the file being closed")
    func singleCloseQuestionNamesTheFile() {
        let prompt = TabCloseHelper.unsavedChangesPrompt(
            fileName: "Untitled Report.md"
        )

        #expect(
            prompt.messageText.contains("Untitled Report.md"),
            """
            The close confirmation does not name the file. The tab is known \
            at the call site, and "unsaved changes" alone does not tell the \
            user what they are about to lose (#1541)
            """
        )
        #expect(
            prompt.messageText.hasSuffix("?"),
            "the message text must be the question: \(prompt.messageText)"
        )
        #expect(
            !prompt.informativeText.hasSuffix("?"),
            "the informative text carries the consequence, not the question"
        )
        #expect(prompt.informativeText == Strings.unsavedChangesConsequence)
    }

    /// Every localization has to keep the structure, not only English: a
    /// translation that drops `%@` silently returns to the anonymous alert.
    @Test("every locale's close question interpolates the file name")
    func everyLocaleNamesTheFile() throws {
        let catalog = try Catalog.load()

        for locale in Self.locales {
            let format = try #require(
                catalog.value(
                    for: "dialog.unsavedChanges.question %@",
                    locale: locale
                ),
                "no close question for \(locale)"
            )
            #expect(
                format.contains("%@"),
                "\(locale) drops the file name from the close question"
            )
            let rendered = Strings.unsavedChangesQuestion(
                "notes.swift",
                locale: Locale(identifier: locale)
            )
            #expect(
                rendered.contains("notes.swift"),
                "\(locale) renders \(rendered) without the file name"
            )
        }
    }

    /// A window close, a project close and a Quit review all reach the bulk
    /// prompt with any count, so "these files" over a one-line list would be
    /// both ungrammatical and less informative than the name Pine has.
    @Test("a bulk close of one file still names that file")
    func bulkCloseOfOneFileNamesIt() {
        let one = TabCloseHelper.unsavedChangesPrompt(
            fileNames: ["a.swift"]
        )
        let many = TabCloseHelper.unsavedChangesPrompt(
            fileNames: ["a.swift", "b.swift", "c.swift"]
        )

        #expect(
            one == TabCloseHelper.unsavedChangesPrompt(fileName: "a.swift"),
            "one dirty file must ask the named single-file question"
        )
        #expect(one.messageText.contains("a.swift"))
        #expect(
            one.messageText != many.messageText,
            "one dirty file and three must not read identically"
        )
        #expect(many.messageText == Strings.unsavedChangesBulkQuestion)
        #expect(many.messageText.hasSuffix("?"))
        #expect(
            !many.messageText.contains("a.swift"),
            "the group question names no single file; the list under it does"
        )
    }

    @Test("the bulk informative text lists every file, one per line")
    func bulkInformativeTextListsTheFiles() {
        let prompt = TabCloseHelper.unsavedChangesPrompt(
            fileNames: ["a.swift", "b.swift"]
        )

        for name in ["a.swift", "b.swift"] {
            #expect(
                prompt.informativeText.contains(name),
                "\(name) is missing from the file list"
            )
        }
        #expect(
            prompt.informativeText.contains(Strings.unsavedChangesConsequence),
            "the bulk alert must state the consequence too"
        )
    }

    // MARK: - Agent History recovery notices

    /// Seven corruption reasons used to render as one "Corrupt or untrusted
    /// recovery data", which cannot tell a folder that moved from one whose
    /// manifest this build does not understand (#1541).
    @MainActor
    @Test("every corruption reason has its own notice text")
    func corruptionReasonsAreDistinct() {
        let reasons = AgentHistoryRecoveryCorruption.allCases
        let english = Locale(identifier: "en_US")
        let texts = reasons.map {
            Strings.agentHistoryRecoveryCorruptionText($0, locale: english)
        }

        #expect(
            Set(texts).count == reasons.count,
            "two corruption reasons share one sentence: \(texts)"
        )
        for (reason, text) in zip(reasons, texts) {
            #expect(!text.isEmpty, "\(reason) has no notice text")
            #expect(
                !text.hasPrefix("agentHistory."),
                "\(reason) exposes its catalog key: \(text)"
            )
        }
    }

    @MainActor
    @Test("the notice row renders the reason, not a shared corrupt label")
    func noticeRowRendersTheReason() {
        let states: [AgentHistoryRecoveryDiscoveryState] = [
            .prepared,
            .authorityConsumed,
            .finalized,
            .corrupt(.invalidManifest),
            .corrupt(.untrustedDirectory),
        ]
        // `LocalizedStringKey` is `Equatable` but not `Hashable`.
        let rendered = states.map(
            AgentHistoryRecoveryNoticeList.statusText(for:)
        )
        for left in rendered.indices {
            for right in rendered.indices where right > left {
                #expect(
                    rendered[left] != rendered[right],
                    "\(states[left]) and \(states[right]) share a status line"
                )
            }
        }
        #expect(
            rendered[3] == Strings.agentHistoryRecoveryCorruption(
                .invalidManifest
            )
        )
        #expect(
            rendered[4] == Strings.agentHistoryRecoveryCorruption(
                .untrustedDirectory
            )
        )
    }

    // MARK: - Crash recovery sheet

    /// The restorer keeps everything it could not install and the sheet
    /// simply returns holding it. Without this edge the second appearance
    /// repeats "Pine found unsaved changes from a previous session" and says
    /// nothing about the attempt that just failed on these exact files.
    @MainActor
    @Test("a returning recovery sheet says the restore failed")
    func recoverySheetExplainsAFailedRestore() {
        #expect(
            RecoveryDialogView.explanation(didFailToRestore: false)
                == Strings.recoveryMessage
        )
        #expect(
            RecoveryDialogView.explanation(didFailToRestore: true)
                == Strings.recoveryPartialFailureMessage
        )
        #expect(
            Strings.recoveryMessage != Strings.recoveryPartialFailureMessage
        )
    }

    // MARK: - Catalog coverage for every new string

    /// The failure texts are the entire deliverable of #1541: a cause that
    /// falls back to English in eight of the nine shipped locales is the same
    /// dead end in a different font.
    @Test("every recovery string is translated in every locale")
    func recoveryStringsCoverTheLocaleMatrix() throws {
        let catalog = try Catalog.load()
        var keys: [String] = [
            "agentInbox.routeUnavailable.nextStep",
            "recovery.partialFailureMessage",
            "agentHistory.undoReview.applyHint",
            "dialog.unsavedChanges.consequence",
            "dialog.unsavedChanges.question %@",
            "dialog.unsavedChanges.bulkQuestion",
        ]
        keys += AgentRecoveryFailure.allCases.map(\.causeKey)
        keys += Set(AgentRecoveryFailure.allCases.map(\.nextStepKey)).sorted()
        keys += AgentHistoryRecoveryCorruption.allCases.map(\.noticeKey)

        for key in keys {
            for locale in Self.locales {
                let value = try #require(
                    catalog.value(for: key, locale: locale),
                    "\(key) is missing \(locale)"
                )
                #expect(
                    !value.trimmingCharacters(in: .whitespacesAndNewlines)
                        .isEmpty,
                    "\(key) is empty in \(locale)"
                )
                #expect(value != key, "\(key) exposes its key in \(locale)")
            }
        }
    }

    /// The generic sentence itself. Leaving it in the catalog is how it comes
    /// back: a later edit only has to point one switch arm at it again.
    @Test("the collapsed failure strings are gone from the catalog")
    func collapsedStringsAreRetired() throws {
        let catalog = try Catalog.load()

        for key in [
            "agentInbox.recoveryUnavailable",
            "agentHistory.recoveryNoticeCorrupt",
            "dialog.unsavedChanges.title",
            "dialog.unsavedChanges.message",
        ] {
            #expect(
                catalog.strings[key] == nil,
                "\(key) is still in the catalog"
            )
        }
    }

    // MARK: - Catalog reader

    private struct Catalog: Decodable {
        let strings: [String: Entry]

        struct Entry: Decodable {
            let localizations: [String: Localization]?
        }

        struct Localization: Decodable {
            let stringUnit: StringUnit?
        }

        struct StringUnit: Decodable {
            let value: String
        }

        static func load() throws -> Self {
            let root = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let data = try Data(
                contentsOf: root.appending(path: "Pine/Localizable.xcstrings")
            )
            return try JSONDecoder().decode(Self.self, from: data)
        }

        func value(for key: String, locale: String) -> String? {
            strings[key]?.localizations?[locale]?.stringUnit?.value
        }
    }
}
