//
//  RecoveryDialogEscapeSafetyTests.swift
//  PineTests
//
//  #1503: the crash-recovery sheet bound `.keyboardShortcut(.cancelAction)` —
//  Escape, the universal macOS "not now" — to a `Button(role: .destructive)`
//  that unlinked every recovered buffer. Dismissing the sheet the way macOS
//  teaches you to destroyed exactly the unsaved work the sheet exists to
//  protect, with no confirmation and no undo.
//
//  The tests that matter here host the real sheet in a real `NSWindow` and
//  press real keys through `performKeyEquivalent(with:)`, then look at which
//  choice came back. Asserting the shortcut table as data cannot see a button
//  wired to the wrong action, which is the shape the original bug had.
//

import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Pine

@Suite("Recovery dialog keyboard safety", .serialized)
@MainActor
struct RecoveryDialogEscapeSafetyTests {

    // MARK: - Hosted key events

    @Test("Escape dismisses the hosted sheet without choosing destruction")
    func escapeResolvesToTheSafeDismissal() {
        let hosted = Self.hostSheet()
        defer { hosted.window.close() }

        Self.sendEscape(to: hosted.window)

        #expect(hosted.recorder.choices == [.later])
        #expect(hosted.recorder.choices.allSatisfy { !$0.isDestructive })
    }

    @Test("Return in the hosted sheet closes it safely: Later is the default")
    func returnResolvesToLater() {
        let hosted = Self.hostSheet()
        defer { hosted.window.close() }

        // Since #1760 the row actions are chosen per row, not by a reflex,
        // and Later — which deletes nothing and keeps every snapshot — is
        // what Return and Escape both land on.
        Self.sendReturn(to: hosted.window)

        #expect(hosted.recorder.choices == [.later])
        #expect(hosted.recorder.choices.allSatisfy { !$0.isDestructive })
    }

    @Test("⌘-. dismisses the hosted sheet exactly like Escape")
    func commandPeriodMatchesEscape() {
        // Every NSAlert in Pine answers to both Escape and ⌘-.
        // (`AlertTemplate.makeAlert`). This sheet is the one dialog built in
        // SwiftUI, and it must not be the one place where the second
        // cancellation gesture does nothing — or worse, falls through to a
        // different responder.
        let hosted = Self.hostSheet()
        defer { hosted.window.close() }

        Self.sendCommandPeriod(to: hosted.window)

        #expect(hosted.recorder.choices == [.later])
    }

    @Test("The keypad Enter key is also the default action, never a delete")
    func keypadEnterResolvesToLater() {
        let hosted = Self.hostSheet()
        defer { hosted.window.close() }

        Self.sendKey(
            to: hosted.window,
            characters: "\u{3}",
            keyCode: 76
        )

        #expect(hosted.recorder.choices == [.later])
    }

    @Test("No sequence of reflex keys ever reaches the destructive choice")
    func reflexKeysNeverReachDiscard() {
        let hosted = Self.hostSheet()
        defer { hosted.window.close() }

        // Hammering the keys a panicking user reaches for, in an order nobody
        // designed for: the sheet stays open in production because the real
        // callbacks dismiss it, but the view under test does not, so every
        // keystroke is delivered to the same live hierarchy.
        for _ in 0..<3 {
            Self.sendEscape(to: hosted.window)
            Self.sendCommandPeriod(to: hosted.window)
            Self.sendReturn(to: hosted.window)
        }

        #expect(hosted.recorder.choices.count == 9)
        #expect(!hosted.recorder.choices.contains { $0.isDestructive })
        #expect(
            Set(hosted.recorder.choices) == [.later],
            """
            A reflex key resolved to something other than the one safe \
            dismissal: \(hosted.recorder.choices)
            """
        )
    }

    @Test("An empty entry list is still dismissible by Escape")
    func emptySheetStillAnswersEscape() {
        // A degenerate list must not remove the safe way out and leave the
        // user with nothing but the destructive button.
        let hosted = Self.hostSheet(entries: [])
        defer { hosted.window.close() }

        Self.sendEscape(to: hosted.window)

        #expect(hosted.recorder.choices == [.later])
    }

    @Test("A hundred entries do not change what Escape means")
    func aLongListStillAnswersEscape() {
        let entries = (0..<100).map { index in
            (
                UUID(),
                RecoveryEntry(
                    originalPath: "/tmp/project/file-\(index).swift",
                    content: "unsaved \(index)"
                )
            )
        }
        let hosted = Self.hostSheet(entries: entries)
        defer { hosted.window.close() }

        Self.sendEscape(to: hosted.window)

        #expect(hosted.recorder.choices == [.later])
    }

    @Test("Hosting and laying out the sheet chooses nothing on its own")
    func hostingTheSheetChoosesNothing() {
        let hosted = Self.hostSheet()
        defer { hosted.window.close() }

        hosted.window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        hosted.window.contentView?.layoutSubtreeIfNeeded()

        #expect(hosted.recorder.choices.isEmpty)
    }

    @Test("Escape means the same thing in every supported locale")
    func escapeIsSafeInEveryLocale() {
        for identifier in Self.supportedLocales {
            let hosted = Self.hostSheet(locale: identifier)
            defer { hosted.window.close() }

            Self.sendEscape(to: hosted.window)

            #expect(
                hosted.recorder.choices == [.later],
                "Escape resolved to \(hosted.recorder.choices) in \(identifier)"
            )
        }
    }

    // MARK: - From the keystroke to the filesystem

    // Everything above stops at the choice the sheet emits. That is one layer
    // short of the bug: #1503 was a keystroke reaching `removeItem`, and a
    // suite that only checks which enum case came back cannot tell a resolver
    // that deletes on `.later` from one that does not. These drive a real
    // `RecoveryManager` over a real directory through the seam production
    // uses — `choice.snapshotsToDelete(row:from:)` into
    // `deleteSnapshots(withRecoveryIDs:)`, exactly as
    // `ContentView.resolveRecoveryOffer` spells it — and then look at the
    // files.

    @Test("Escape leaves every snapshot file where it was")
    func escapeLeavesTheSnapshotsOnDisk() throws {
        try Self.withSnapshotFixture { fixture in
            let hosted = Self.hostResolvingSheet(fixture)
            defer { hosted.window.close() }
            let before = fixture.files

            Self.sendEscape(to: hosted.window)

            #expect(hosted.recorder.choices == [.later])
            #expect(
                fixture.files == before,
                "Escape unlinked a recovered buffer (#1503)"
            )
            #expect(fixture.manager.pendingRecoveryEntries().count == 2)
        }
    }

    @Test("⌘-. leaves every snapshot file where it was")
    func commandPeriodLeavesTheSnapshotsOnDisk() throws {
        try Self.withSnapshotFixture { fixture in
            let hosted = Self.hostResolvingSheet(fixture)
            defer { hosted.window.close() }
            let before = fixture.files

            Self.sendCommandPeriod(to: hosted.window)

            // The choice, not only the filesystem: a sheet that answered ⌘-.
            // with nothing at all would leave the files alone too, and pass.
            #expect(hosted.recorder.choices == [.later])
            #expect(fixture.files == before)
        }
    }

    @Test("Hammering the reflex keys leaves every snapshot file where it was")
    func reflexKeysLeaveTheSnapshotsOnDisk() throws {
        try Self.withSnapshotFixture { fixture in
            let hosted = Self.hostResolvingSheet(fixture)
            defer { hosted.window.close() }
            let before = fixture.files

            // Return resolves to `.later`, which in production closes the
            // sheet and keeps every snapshot; what matters here is that no
            // reflex key can reach the deletion path from the sheet.
            for _ in 0..<3 {
                Self.sendEscape(to: hosted.window)
                Self.sendReturn(to: hosted.window)
                Self.sendCommandPeriod(to: hosted.window)
            }

            #expect(hosted.recorder.choices.count == 9)
            #expect(fixture.files == before)
        }
    }

    @Test("Discard deletes nothing until the alert confirms it, then one row")
    func discardRequiresTheSecondConfirmation() throws {
        // Without this, every test above could be passing because the seam is
        // dead — a resolver that never deletes anything would satisfy them all
        // and ship a Discard button that does nothing. And since #1760 the
        // first Discard click must not reach the resolver at all: the sheet
        // asks again, and only the confirmed answer names one row.
        try Self.withSnapshotFixture { fixture in
            let hosted = Self.hostResolvingSheet(fixture)
            defer { hosted.window.close() }
            #expect(fixture.files.count == 2)
            // The sheet selects its first row when it appears, so the
            // confirmed answer names that row and only that row's snapshot
            // may go. `entries.last` is the row that must survive.
            let selectedRow = try #require(fixture.entries.first?.0)
            let survivingRow = try #require(fixture.entries.last?.0)

            // Discard carries no key equivalent by design, so it is reached
            // the only way it can be: the way a click arrives — the
            // accessibility action VoiceOver's activate gesture sends.
            #expect(
                Self.pressButton(
                    AccessibilityID.recoveryDiscardButton,
                    under: hosted.window.contentView
                ),
                "The Discard button did not answer an accessibility press"
            )
            #expect(
                Self.wait(forConfirmationAlertOn: hosted.window) != nil,
                "Discard did not raise the confirmation alert"
            )

            // The first click was intercepted: nothing deleted, nothing
            // reported.
            #expect(fixture.files.count == 2)
            #expect(
                fixture.manager.pendingRecoveryEntries().count == 2
            )
            #expect(hosted.recorder.choices.isEmpty)

            // The alert's destructive button reports exactly this answer —
            // `RecoveryDialogAnswer(choice: .discard, recoveryID:)` for the
            // row the user confirmed — and it is the only thing in the app
            // that produces one. Its `NSButton` is not materialised inside an
            // offscreen test window (macOS 26 builds the alert's buttons only
            // for an on-screen window), so the click itself is UI-test
            // territory; what a unit test can pin is that nothing deletes
            // before this answer exists, and what this answer deletes through
            // the production seam.
            hosted.onChoose(
                RecoveryDialogAnswer(choice: .discard, recoveryID: selectedRow)
            )

            #expect(hosted.recorder.choices == [.discard])
            #expect(hosted.recorder.chosen.first?.recoveryID == selectedRow)
            // Exactly one snapshot — the confirmed row's — is gone.
            #expect(fixture.files.count == 1)
            #expect(
                fixture.manager.pendingRecoveryEntries().map(\.0)
                    == [survivingRow]
            )
        }
    }

    @Test("Cancelling the discard confirmation keeps both snapshots")
    func cancellingTheConfirmationDeletesNothing() throws {
        try Self.withSnapshotFixture { fixture in
            let hosted = Self.hostResolvingSheet(fixture)
            defer { hosted.window.close() }
            let before = fixture.files

            #expect(
                Self.pressButton(
                    AccessibilityID.recoveryDiscardButton,
                    under: hosted.window.contentView
                )
            )
            let alert = Self.wait(forConfirmationAlertOn: hosted.window)
            #expect(alert != nil, "Discard did not raise the confirmation")

            // Escape belongs to the alert's Cancel there, not to the sheet
            // behind it — the reflex way out of the confirmation deletes
            // nothing and leaves the list exactly as it was.
            Self.sendEscape(to: try #require(alert))
            Self.wait(forConfirmationAlertOn: hosted.window)

            #expect(hosted.recorder.choices.isEmpty)
            #expect(fixture.files == before)
            #expect(fixture.manager.pendingRecoveryEntries().count == 2)
        }
    }

    @Test("Discard takes only the row it was confirmed for")
    func discardLeavesSnapshotsThatWereNotConfirmed() throws {
        let dir = try Self.makeTempDir()
        defer { Self.removeTempDir(dir) }
        let manager = RecoveryManager(recoveryDirectory: dir)
        manager.snapshotDirtyTabs([Self.dirtyTab(path: "/tmp/offered.swift")])
        let offered = manager.pendingRecoveryEntries()
        // A snapshot written after the sheet was built — the periodic timer
        // does this while the sheet is open.
        let later = Self.dirtyTab(path: "/tmp/written-later.swift")
        manager.snapshotDirtyTabs([later])

        let undeleted = manager.deleteSnapshots(
            withRecoveryIDs: RecoveryDialogChoice.discard.snapshotsToDelete(
                row: offered.first?.0,
                from: offered
            )
        )
        // The manager reports which unlinks it refused, so the resolver can
        // keep a row whose Discard the filesystem did not perform (#1760).
        #expect(undeleted.isEmpty)

        #expect(manager.pendingRecoveryEntries().map(\.0) == [later.id])
    }

    // MARK: - What each choice is allowed to unlink

    @Test("No safe choice may unlink anything the sheet is showing")
    func safeChoicesDeleteNothing() {
        let entries = Self.makeEntries()

        for choice in RecoveryDialogChoice.allCases where !choice.isDestructive {
            // Hoisted out of the macro: a generic call with an optional
            // argument inside `#expect` expands into something the type
            // checker refuses.
            let deleted = choice.snapshotsToDelete(
                row: entries.first?.0,
                from: entries
            )
            #expect(
                deleted.isEmpty,
                """
                \(choice.rawValue) is not destructive, so it must unlink \
                nothing — even for the row it is answering. Escape, Return \
                and ⌘-. resolve to `.later`, which unlinks nothing (#1503), \
                and nothing collects a snapshot by age any more (#1760)
                """
            )
        }
    }

    @Test("Discard unlinks exactly the row it was given")
    func discardDeletesExactlyItsRow() {
        let entries = Self.makeEntries()
        let first = entries[0].0
        let second = entries[1].0

        let firstDeleted = RecoveryDialogChoice.discard.snapshotsToDelete(
            row: first, from: entries
        )
        let secondDeleted = RecoveryDialogChoice.discard.snapshotsToDelete(
            row: second, from: entries
        )
        #expect(firstDeleted == [first])
        #expect(secondDeleted == [second])
    }

    @Test("Discard without a confirmed row unlinks nothing")
    func discardWithoutARowDeletesNothing() {
        let entries = Self.makeEntries()

        let unconfirmed = RecoveryDialogChoice.discard.snapshotsToDelete(
            row: nil, from: entries
        )
        #expect(
            unconfirmed.isEmpty,
            """
            An unconfirmed Discard must not fall back to deleting everything \
            the sheet is showing (#1760)
            """
        )
    }

    @Test("An empty sheet gives every choice nothing to unlink")
    func anEmptySheetDeletesNothingWhateverIsChosen() {
        let empty: [(UUID, RecoveryEntry)] = []

        for choice in RecoveryDialogChoice.allCases {
            let withRow = choice.snapshotsToDelete(row: UUID(), from: empty)
            let withoutRow = choice.snapshotsToDelete(row: nil, from: empty)
            #expect(withRow.isEmpty)
            #expect(withoutRow.isEmpty)
        }
    }

    @Test("Exactly one choice is allowed to unlink anything")
    func onlyOneChoiceCanDelete() {
        let entries = Self.makeEntries()
        let row = entries[0].0
        let deleters = RecoveryDialogChoice.allCases.filter {
            !$0.snapshotsToDelete(row: row, from: entries).isEmpty
        }

        #expect(deleters == [.discard])
    }

    // MARK: - Shortcut policy

    @Test("No destructive recovery choice carries a keyboard equivalent")
    func destructiveChoicesCarryNoKeyboardShortcut() {
        let destructive = RecoveryDialogChoice.allCases.filter(\.isDestructive)

        #expect(
            !destructive.isEmpty,
            "The sheet must still offer an irreversible discard"
        )
        for choice in destructive {
            #expect(
                choice.keyboardShortcuts.isEmpty,
                """
                \(choice.rawValue) destroys recovered work, so it must be \
                reachable only by a deliberate click (#1503)
                """
            )
        }
    }

    @Test("Discard is the only destructive choice")
    func discardIsTheOnlyDestructiveChoice() {
        #expect(
            RecoveryDialogChoice.allCases.filter(\.isDestructive) == [.discard]
        )
    }

    @Test("Escape and Return belong to exactly one safe choice each")
    func reflexShortcutsBelongToSafeChoices() {
        let owners: (KeyboardShortcut) -> [RecoveryDialogChoice] = { shortcut in
            RecoveryDialogChoice.allCases.filter {
                $0.keyboardShortcuts.contains(shortcut)
            }
        }

        // Every reflex — Escape, Return, keypad Enter, ⌘-. — lands on Later,
        // which unlinks nothing. The row actions are reached by selecting a
        // row, never by a keystroke (#1760).
        #expect(owners(.cancelAction) == [.later])
        #expect(owners(.defaultAction) == [.later])
        #expect(
            owners(KeyboardShortcut(".", modifiers: .command)) == [.later]
        )
        for choice in [RecoveryDialogChoice.restore, .saveCopy] {
            #expect(
                choice.keyboardShortcuts.isEmpty,
                """
                \(choice.rawValue) acts on the selected row; giving it a key \
                equivalent would let a reflex act on whatever selection the \
                list happens to hold (#1760)
                """
            )
        }
    }

    @Test("No two choices answer to the same keystroke")
    func shortcutsAreUnique() {
        let shortcuts = RecoveryDialogChoice.allCases
            .flatMap(\.keyboardShortcuts)

        #expect(Set(shortcuts).count == shortcuts.count)
    }

    @Test("The sheet keeps every choice it is supposed to offer")
    func everyChoiceIsPresent() {
        #expect(
            Set(RecoveryDialogChoice.allCases)
                == [.discard, .later, .restore, .saveCopy]
        )
    }

    @Test("Only the destructive choice carries a VoiceOver hint")
    func onlyTheDestructiveChoiceHasAHint() {
        for choice in RecoveryDialogChoice.allCases {
            #expect(
                (choice.accessibilityHint != nil) == choice.isDestructive,
                """
                \(choice.rawValue) disagrees with itself: the hint exists to \
                announce irreversibility, and `nil` rather than "" is what \
                keeps a safe button from carrying an empty announcement and \
                a lookup for a key the catalog does not have
                """
            )
        }

        // Presence is not the claim. `isDestructive ? Strings.recoveryLater :
        // nil` satisfies every assertion above and announces "Later" as the
        // warning on the one irreversible control in this sheet.
        #expect(
            RecoveryDialogChoice.discard.accessibilityHint
                == Strings.recoveryDiscardHint,
            """
            The Discard hint is pointed at another catalog string. SwiftUI's \
            `ButtonRole.destructive` does not set AppKit's \
            `hasDestructiveAction`, so this hint is the only warning a \
            VoiceOver user gets before an unrecoverable click (#1503)
            """
        )
    }

    @Test("The shortcut proxies stay out of the accessibility tree")
    func theHostedSheetExposesExactlyFourButtons() throws {
        // ⌘-. rides an invisible 0×0 `Button` in the visible button's
        // `.background`, because SwiftUI gives a control only one key
        // equivalent. Nothing but `.accessibilityHidden(true)` keeps it out of
        // the accessibility tree, and removing that modifier is a one-line
        // edit no other test in this file can see: every behavioural
        // assertion here goes through `performKeyEquivalent`, which the proxy
        // answers either way. What it costs is a VoiceOver user hearing five
        // buttons on a four-button sheet, two of them announced "Later" — on
        // the one sheet in Pine where picking the wrong button is
        // unrecoverable.
        let hosted = Self.hostSheet()
        defer { hosted.window.close() }

        let identifiers = try Self.accessibilityButtonIdentifiers(
            under: hosted.window.contentView
        )

        #expect(
            Set(identifiers)
                == Set(RecoveryDialogChoice.allCases.map(\.accessibilityIdentifier)),
            """
            The recovery sheet exposes \(identifiers.count) accessibility \
            buttons instead of \(RecoveryDialogChoice.allCases.count): \
            \(identifiers). An unidentified extra one is a shortcut proxy \
            that lost `.accessibilityHidden(true)` — VoiceOver would then \
            announce two buttons called "Later" on the sheet where the \
            neighbouring button is unrecoverable (#1503)
            """
        )
        #expect(
            identifiers.count == RecoveryDialogChoice.allCases.count,
            "Duplicate accessibility identifiers: \(identifiers)"
        )
    }

    @Test("The footer lays out every choice, destructive first, default last")
    func theFooterDrawsEveryChoice() {
        // The row used to name its buttons one by one, so a new
        // choice would have existed in the type, been reachable by nothing,
        // and shown up nowhere. It is built by walking `allCases` now, and
        // this is the assertion that keeps it that way.
        let order = RecoveryDialogFooter.displayOrder

        #expect(Set(order) == Set(RecoveryDialogChoice.allCases))
        #expect(order.count == RecoveryDialogChoice.allCases.count)
        #expect(
            order.first?.isDestructive == true,
            "The irreversible choice must stand apart on the leading edge"
        )
        #expect(
            order.last?.isDefaultAction == true,
            "macOS puts the default action last; Return must land on it"
        )
        #expect(
            order.dropFirst().allSatisfy { !$0.isDestructive },
            "A destructive choice ended up in the trailing group: \(order)"
        )
    }

    @Test("Every choice has its own accessibility identifier")
    func accessibilityIdentifiersAreDistinct() {
        let identifiers = RecoveryDialogChoice.allCases
            .map(\.accessibilityIdentifier)

        #expect(Set(identifiers).count == identifiers.count)
        #expect(identifiers.allSatisfy { !$0.isEmpty })
    }

    // MARK: - Localization

    @Test("Every locale gives the four choices four different titles")
    func choiceTitlesAreDistinctInEveryLocale() throws {
        let catalog = try Self.loadCatalog()
        let keys = [
            "recovery.discard",
            "recovery.later",
            "recovery.restore",
            "recovery.saveCopy",
        ]

        for locale in Self.supportedLocales {
            let titles = try keys.map { key -> String in
                try #require(
                    Self.value(for: key, locale: locale, in: catalog),
                    "Missing \(key) [\(locale)]"
                )
            }
            #expect(
                Set(titles).count == keys.count,
                """
                \(locale) gives two recovery choices the same title, so the \
                row has two buttons a user cannot tell apart: \(titles)
                """
            )
            #expect(titles.allSatisfy { !$0.isEmpty })
        }
    }

    @Test("The destructive button's title is pinned in every locale")
    func discardTitleIsPinnedPerLocale() throws {
        // What this enforces is a review gate, not a linguistic property:
        // changing the word on the one irreversible control in this sheet has
        // to cost a conversation with someone who speaks the language. There
        // is no way to ask a string whether a native speaker hears deletion
        // in it, and the pinned set below is not internally consistent about
        // it either — German `Verwerfen`, Spanish and Brazilian Portuguese
        // `Descartar` and Chinese `放弃` are all "discard/abandon" words, the
        // same class as the Russian «Отклонить» and French « Ignorer » this
        // branch replaced. They stay: `Verwerfen` is the platform-standard
        // wording macOS itself uses for Don't Save, and matching the platform
        // beats matching a rule invented here. The ones that were changed
        // were changed because they read as *dismissing the dialog*, which is
        // now a different button sitting right next to them (#1503).
        let expected = [
            "de": "Verwerfen",
            "en": "Discard",
            "es": "Descartar",
            "fr": "Supprimer",
            "ja": "破棄",
            "ko": "삭제",
            "pt-BR": "Descartar",
            "ru": "Удалить",
            "zh-Hans": "放弃",
        ]
        let catalog = try Self.loadCatalog()

        #expect(Set(expected.keys) == Set(Self.supportedLocales))
        for (locale, title) in expected {
            #expect(
                Self.value(for: "recovery.discard", locale: locale, in: catalog)
                    == title,
                """
                The Discard title changed in \(locale). It is the only \
                irreversible control on this sheet and it sits next to \
                Later — confirm with a native speaker that the new word \
                cannot be read as "just close this", then update this \
                pin (#1503)
                """
            )
        }
    }

    @Test("Each choice's button title is its own catalog string")
    func choiceTitlesComeFromTheirOwnKeys() throws {
        // Nothing else in this suite reads `\.title`. Swapping two of them —
        //
        //     case .discard: Strings.recoveryLater
        //     case .later: Strings.recoveryDiscard
        //
        // compiles, keeps every other assertion in this file green, and puts
        // "Later" on the irreversible button and "Discard" on the safe one.
        // That is #1503's harm reached with the mouse instead of the keyboard,
        // and it is worse than the original: the shortcut policy is intact, so
        // the user who presses Escape is fine and the one who reads the row is
        // the one who loses their work.
        #expect(RecoveryDialogChoice.discard.title == Strings.recoveryDiscard)
        #expect(RecoveryDialogChoice.later.title == Strings.recoveryLater)
        #expect(RecoveryDialogChoice.restore.title == Strings.recoveryRestore)
        #expect(RecoveryDialogChoice.saveCopy.title == Strings.recoverySaveCopy)

        // The identity check above is blind to the other half of the same
        // swap — done inside `Strings`, where `recoveryDiscard` is pointed at
        // "recovery.later" — and so is `discardTitleIsPinnedPerLocale`, which
        // reads the catalog by literal key rather than through `Strings`.
        // Rendering closes the loop: `Text(choice.title)` and a
        // `Text(verbatim:)` of the value the catalog holds under the expected
        // key lay out to the same width, and to different widths otherwise.
        // Same technique, and same tolerance, as
        // `localeSubstitutionChangesWhatIsMeasured`.
        //
        // It is a width comparison, so it can only see a substitution that
        // changes the width. Two titles that happen to typeset alike in one
        // locale (Japanese 破棄 against 後で) would hide a swap *there* — but
        // the swap is one edit affecting every locale at once, and «Удалить»
        // against «Позже» is not a close call.
        let catalog = try Self.loadCatalog()
        let keys: [RecoveryDialogChoice: String] = [
            .discard: "recovery.discard",
            .later: "recovery.later",
            .restore: "recovery.restore",
            .saveCopy: "recovery.saveCopy",
        ]
        #expect(
            Set(keys.keys) == Set(RecoveryDialogChoice.allCases),
            "A choice was added to the enum and has no expected title here"
        )

        for locale in Self.supportedLocales {
            for choice in RecoveryDialogChoice.allCases {
                let key = try #require(keys[choice])
                let expected = try #require(
                    Self.value(for: key, locale: locale, in: catalog),
                    "Missing \(key) [\(locale)]"
                )
                // Measured with the typesetting language pinned on both
                // sides, like `measuredNoticeWidth`: the row actions' titles
                // end in "…", and in `ja` and `zh-Hans` the typesetter
                // squeezes that punctuation only when it knows the language.
                let rendered = Self.measuredNoticeWidth(
                    Text(choice.title),
                    locale: locale
                )
                let fromCatalog = Self.measuredNoticeWidth(
                    Text(verbatim: expected),
                    locale: locale
                )
                #expect(
                    abs(rendered - fromCatalog) <= Self.typesettingTolerance,
                    """
                    The \(choice.rawValue) button in \(locale) does not render \
                    \(key)'s value "\(expected)" — \(rendered)pt against \
                    \(fromCatalog)pt. Its title has been pointed at another \
                    string, and on this sheet that means a button whose label \
                    is not what pressing it does (#1503)
                    """
                )
            }
        }
    }

    @Test("The destructive button carries a warning hint in every locale")
    func discardHintIsLocalizedEverywhere() throws {
        // SwiftUI's `ButtonRole.destructive` does not set AppKit's
        // `hasDestructiveAction`, so this hint is the only thing telling a
        // VoiceOver user that Discard is not an ordinary button.
        let catalog = try Self.loadCatalog()

        for locale in Self.supportedLocales {
            let hint = Self.value(
                for: "recovery.discardHint",
                locale: locale,
                in: catalog
            )
            #expect(hint?.isEmpty == false, "Missing discard hint [\(locale)]")
        }
    }

    @Test("The discard hint says the saved files are safe")
    func discardHintDoesNotThreatenTheUsersFiles() throws {
        // This is the one string whose job is to warn a blind user before an
        // irreversible action, and it used to say Discard "permanently deletes
        // the recovered files" — which reads as the sources in the project.
        // Discard deletes snapshots of unsaved changes and touches nothing on
        // disk that the user saved; `recovery.message` in the same sheet says
        // so correctly, and the two must not disagree about what is at stake.
        let catalog = try Self.loadCatalog()
        // Second clause, in each language's own words for "saved" and "not".
        let reassurance = [
            "de": "gespeicherten",
            "en": "saved files are not affected",
            "es": "guardados",
            "fr": "enregistrés",
            "ja": "保存済み",
            "ko": "저장된 파일",
            "pt-BR": "salvos",
            "ru": "Сохранённые файлы",
            "zh-Hans": "已保存的文件",
        ]

        for locale in Self.supportedLocales {
            let hint = try #require(
                Self.value(
                    for: "recovery.discardHint",
                    locale: locale,
                    in: catalog
                )
            )
            let needle = try #require(reassurance[locale])
            #expect(
                hint.contains(needle),
                """
                The discard hint in \(locale) no longer tells the user their \
                saved files survive: \(hint)
                """
            )
        }
    }

    @Test("The keep notice is localized for every supported locale")
    func keepNoticeIsLocalizedEverywhere() throws {
        // "Later" is safe without a deadline now (#1760): nothing collects a
        // snapshot by age, and the menu reopens the list. That promise has to
        // exist wherever the sheet can be shown, or the footnote regresses to
        // a raw key.
        let catalog = try Self.loadCatalog()

        for locale in Self.supportedLocales {
            #expect(
                Self.value(
                    for: "recovery.keepNotice",
                    locale: locale,
                    in: catalog
                )?.isEmpty == false,
                "Missing keep notice [\(locale)]"
            )
        }
    }

    @Test("The keep notice the sheet renders is the catalog's")
    func theRenderedKeepNoticeResolves() throws {
        // Everything above reads the catalog and never asks whether the sheet
        // can reach it. Same technique and tolerance as
        // `localeSubstitutionChangesWhatIsMeasured`: a resolved
        // `Text(LocalizedStringKey)` and a `Text(verbatim:)` of the same
        // characters lay out to the same width, an unresolved key does not.
        let catalog = try Self.loadCatalog()

        for locale in Self.supportedLocales {
            let expected = try #require(
                Self.value(for: "recovery.keepNotice", locale: locale, in: catalog),
                "Missing keep notice [\(locale)]"
            )
            let rendered = Self.measuredNoticeWidth(
                Text(Strings.recoveryKeepNotice),
                locale: locale
            )
            let fromCatalog = Self.measuredNoticeWidth(
                Text(verbatim: expected),
                locale: locale
            )

            #expect(
                abs(rendered - fromCatalog) <= Self.typesettingTolerance,
                """
                The keep-notice footnote in \(locale) does not render the \
                catalog's "\(expected)" — \(rendered)pt against \
                \(fromCatalog)pt. The lookup did not resolve, so the sheet is \
                printing a raw key where it promises the user that nothing \
                collects their work (#1760)
                """
            )
        }
    }

    @Test("A wrong keep-notice key is something the render check can see")
    func theRenderedKeepNoticeCheckHasTeeth() throws {
        // The positive control for the test above: an unresolved key is not
        // within a couple of points of the sentence it should have produced.
        // Without this, a measurement that silently returned the same number
        // for everything would make that test pass forever.
        let catalog = try Self.loadCatalog()
        let expected = try #require(
            Self.value(for: "recovery.keepNotice", locale: "en", in: catalog)
        )
        // What SwiftUI draws for a key the catalog does not contain: the key
        // itself. This is exactly what a renamed entry produces.
        let unresolved = Self.measuredNoticeWidth(
            Text(LocalizedStringKey("recovery.keepNoticeTypo")),
            locale: "en"
        )
        let fromCatalog = Self.measuredNoticeWidth(
            Text(verbatim: expected),
            locale: "en"
        )

        #expect(
            abs(unresolved - fromCatalog) > Self.typesettingTolerance,
            """
            A key that resolves to nothing measured the same as the resolved \
            footnote (\(unresolved)pt against \(fromCatalog)pt), so \
            `theRenderedKeepNoticeResolves` cannot tell them apart either
            """
        )
    }

    @Test("The discard confirmation and save-copy notices are localized everywhere")
    func discardConfirmAndSaveCopyNoticesAreLocalizedEverywhere() throws {
        let catalog = try Self.loadCatalog()
        let formatKeys = [
            "recovery.discardConfirmTitle %@",
            "recovery.discardRefused %@",
            "recovery.saveCopyOriginalRefused %@",
            "recovery.saveCopyEncodingFailure %@",
            "recovery.saveCopyPanelUnavailable %@",
            "recovery.saveCopyWriteFailure %@ %@",
        ]
        let plainKeys = [
            "recovery.discardConfirmMessage",
            "menu.recoverUnsavedWork",
        ]

        for locale in Self.supportedLocales {
            for key in formatKeys {
                let text = try #require(
                    Self.value(for: key, locale: locale, in: catalog),
                    "Missing \(key) [\(locale)]"
                )
                #expect(text.contains("%@"), "\(key) [\(locale)] lost its substitution")
            }
            for key in plainKeys {
                #expect(
                    Self.value(for: key, locale: locale, in: catalog)?
                        .isEmpty == false,
                    "Missing \(key) [\(locale)]"
                )
            }
        }
    }

    // MARK: - Layout

    @Test("The footer fits inside the width the sheet actually takes")
    func footerFitsTheSheetItGets() {
        // Measured against the sheet's own fitting width, not a hardcoded
        // number: the point is that the two agree, whatever they are.
        for identifier in Self.supportedLocales {
            let footer = Self.measuredFooterWidth(locale: identifier)
            let sheet = Self.measuredSheetWidth(locale: identifier)

            #expect(
                footer > 100,
                "Footer measured \(footer)pt in \(identifier) — it did not lay out"
            )
            #expect(
                sheet >= footer + Self.sheetPadding,
                """
                The four buttons need \(footer)pt plus \
                \(Self.sheetPadding)pt of padding in \(identifier), but the \
                sheet only takes \(sheet)pt — the row is being squeezed
                """
            )
        }
    }

    @Test("The sheet grows for a footer that outgrows its resting width")
    func theSheetGrowsRatherThanSqueezingTheFooter() {
        // German already asks for 349 of the 352pt a 400pt sheet can give the
        // button row, so the headroom is three points. `.controlSize` stands
        // in here for the thing that will actually consume it: a change in
        // AppKit's button metrics on a newer macOS. A fixed-width sheet
        // answers that by truncating a button label; this one widens.
        var grew = false

        for identifier in Self.supportedLocales {
            let footer = Self.measuredFooterWidth(
                locale: identifier,
                controlSize: .extraLarge
            )
            let sheet = Self.measuredSheetWidth(
                locale: identifier,
                controlSize: .extraLarge
            )

            #expect(
                sheet >= footer + Self.sheetPadding,
                """
                With larger controls the footer needs \(footer)pt in \
                \(identifier) and the sheet stopped at \(sheet)pt — a fixed \
                width would clip the button labels here (#1503)
                """
            )
            if sheet > Self.restingSheetWidth { grew = true }
        }

        #expect(
            grew,
            """
            No locale pushed the sheet past its resting width even with \
            oversized controls, so this test can no longer tell a growing \
            sheet from a fixed one
            """
        )
    }

    @Test("The sheet keeps its resting width at the normal control size")
    func theSheetRestsAtItsDesignedWidth() {
        // A band, not an equality. `minWidth` was chosen over `width`
        // precisely so a locale that needs a few more points can have them,
        // and pinning the exact number would turn that flexibility into a
        // failing test the first time it is used. The ceiling is what the
        // test is really for: it separates "a translation grew" from "a width
        // cap was removed and some row is now driving the sheet to a thousand
        // points", which is the failure mode the caps in `body` exist to stop.
        for identifier in Self.supportedLocales {
            let width = Self.measuredSheetWidth(locale: identifier)

            #expect(
                width >= Self.restingSheetWidth,
                "The sheet shrank below its `minWidth` in \(identifier): \(width)pt"
            )
            #expect(
                width <= Self.restingSheetWidth + Self.widthHeadroom,
                """
                The sheet wants \(width)pt in \(identifier), more than \
                \(Self.restingSheetWidth + Self.widthHeadroom)pt — something \
                inside it is no longer capped to the content width
                """
            )
        }
    }

    @Test("A pathological file name is truncated, not laid out in full")
    func aVeryLongFileNameIsTruncatedRatherThanWidening() {
        // Generated bundles, downloads and dated exports routinely produce
        // names well past a hundred characters, and a `Text` has no natural
        // width to stop at.
        //
        // Measured on the row and not on the sheet, deliberately: a `List` is
        // a scroll view, so it absorbs a row that asks for a thousand points
        // and the sheet's fitting size never changes. A test that watched the
        // sheet would pass whether the row was capped or not — it would look
        // like a regression test and assert nothing. What actually goes wrong
        // without the cap is inside the list: a name clipped mid-word with no
        // ellipsis, and the relative timestamp pushed out of view.
        //
        // Width alone does not say "truncated": `.frame(maxWidth:)` on its own
        // satisfies it, and a row that lost `.lineLimit(1)` still reports
        // 352pt — an unconstrained `fittingSize` proposes nothing, so the
        // `Text` lays out on one ideal-width line and the frame merely clamps
        // the number that comes back. The height has to be measured under a
        // proposal the row cannot ignore, so it is taken again inside a
        // container fixed at the text column: there the name either fits on
        // one line or reflows onto a dozen, and only the line limit decides
        // which. What neither measurement can see is the truncation *mode* —
        // a `.tail` ellipsis lays out exactly like a `.middle` one — so
        // keeping the file extension visible stays a reviewed choice rather
        // than a checked one.
        let long = String(repeating: "extremely-long-generated-name-", count: 8)
        let ceiling = RecoveryDialogView.contentWidth + Self.typesettingTolerance
        let entries = [
            RecoveryEntry(
                originalPath: "/tmp/project/\(long).swift",
                content: "unsaved"
            ),
            RecoveryEntry(
                originalPath: "",
                untitledName: long,
                content: "draft"
            ),
        ]
        let short = RecoveryEntry(originalPath: "/tmp/a.swift", content: "x")

        for identifier in Self.supportedLocales {
            let singleLine = Self.heightInTextColumn(
                of: short,
                locale: identifier
            )

            for entry in entries {
                let width = Self.measuredWidth(
                    of: RecoveryEntryRow(entry: entry),
                    locale: identifier
                )
                let height = Self.heightInTextColumn(
                    of: entry,
                    locale: identifier
                )

                #expect(
                    width <= ceiling,
                    """
                    A \(long.count)-character name made the row ask for \
                    \(width)pt in \(identifier), past the \(ceiling)pt \
                    text column — the row lost its width cap
                    """
                )
                #expect(
                    abs(height - singleLine) <= Self.typesettingTolerance,
                    """
                    Given the \(RecoveryDialogView.contentWidth)pt text \
                    column, a \(long.count)-character name made the row \
                    \(height)pt tall in \(identifier) against \
                    \(singleLine)pt for a short name — the name is reflowing \
                    onto more lines instead of being truncated on one, so the \
                    row lost its line limit
                    """
                )
            }
        }

        // …and the sheet itself still rests where it should with them in it.
        let sheetEntries = entries.map { (UUID(), $0) }
        #expect(
            Self.measuredSheetWidth(locale: "en", entries: sheetEntries)
                <= Self.restingSheetWidth + Self.widthHeadroom
        )
    }

    @Test("Locale substitution actually reaches the rendered footer")
    func localeSubstitutionChangesWhatIsMeasured() throws {
        // Without a positive control, every measurement above could silently
        // be the English one and the locale tests would pass for the wrong
        // reason. Distinct widths is too weak on its own: eight locales could
        // fall back to English and one could differ, and the set would still
        // have two members.
        //
        // So each locale is checked against the value in the catalog. A
        // rendered `Text(LocalizedStringKey)` and a `Text(verbatim:)` of the
        // same characters lay out to the same width, and to a different one
        // otherwise — which is exactly the question "did the lookup resolve
        // to this locale's string, or did it fall back?".
        let catalog = try Self.loadCatalog()
        let widths = Self.supportedLocales.map {
            Self.measuredFooterWidth(locale: $0)
        }

        #expect(
            Set(widths).count > 1,
            """
            All nine locales measured the same footer width \(widths) — \
            `.environment(\\.locale, …)` is not reaching the button titles, \
            so the localized layout is not being tested at all
            """
        )

        for locale in Self.supportedLocales {
            let expected = try #require(
                Self.value(for: "recovery.later", locale: locale, in: catalog)
            )
            let rendered = Self.measuredWidth(
                of: Text(Strings.recoveryLater),
                locale: locale
            )
            let fromCatalog = Self.measuredWidth(
                of: Text(verbatim: expected),
                locale: locale
            )
            // Within a point or two, not exactly: a localized `Text` carries
            // the locale's typesetting language and a `Text(verbatim:)` does
            // not, which moves Japanese by 1pt. The tolerance is far below the
            // gap any fallback would open — "後で" against "Later" is tens of
            // points — so it costs the test nothing it was there to catch.
            #expect(
                abs(rendered - fromCatalog) <= Self.typesettingTolerance,
                """
                The Later button in \(locale) does not render the catalog's \
                "\(expected)" — \(rendered)pt rendered against \(fromCatalog)pt \
                for the catalog value. The lookup fell back to another locale, \
                so every measurement taken for \(locale) is measuring the \
                wrong string
                """
            )
        }
    }

    @Test("An empty entry list still lays the sheet out")
    func hostedSheetSurvivesAnEmptyEntryList() {
        let recorder = ChoiceRecorder()
        let hosted = NSHostingView(
            rootView: RecoveryDialogView(entries: []) { recorder.record($0) }
        )
        hosted.frame = NSRect(x: 0, y: 0, width: 560, height: 520)
        hosted.layoutSubtreeIfNeeded()

        #expect(recorder.choices.isEmpty)
        // A band, like `theSheetRestsAtItsDesignedWidth`: the sheet's own
        // `minWidth` is the floor, and a locale that needs a few more points
        // may have them.
        #expect(hosted.fittingSize.width >= Self.restingSheetWidth)
        // The list has a 100pt floor, so an empty sheet is still a real sheet
        // and not a collapsed strip with four buttons in it.
        #expect(hosted.fittingSize.height > 200)
    }

    // MARK: - Helpers

    private static let supportedLocales = [
        "de", "en", "es", "fr", "ja", "ko", "pt-BR", "ru", "zh-Hans",
    ]

    /// 24pt of padding on each edge, from `RecoveryDialogView.body`.
    private static let sheetPadding: CGFloat = 48
    private static let restingSheetWidth: CGFloat = 496
    /// How much a shipped translation may add to the resting width before the
    /// growth stops being a translation and starts being a missing cap.
    private static let widthHeadroom: CGFloat = 40
    /// Slack between a localized `Text` and a verbatim one holding the same
    /// characters. See `localeSubstitutionChangesWhatIsMeasured`.
    private static let typesettingTolerance: CGFloat = 2

    private final class HostedTestWindow: NSWindow {
        override var canBecomeKey: Bool { true }
    }

    private struct HostedSheet {
        let window: NSWindow
        let recorder: ChoiceRecorder
        let onChoose: (RecoveryDialogAnswer) -> Void
    }

    /// A real recovery directory with two snapshots in it.
    private struct SnapshotFixture {
        let directory: URL
        let manager: RecoveryManager
        let entries: [(UUID, RecoveryEntry)]

        /// The snapshot files actually on disk right now.
        var files: Set<String> {
            let names = (try? FileManager.default.contentsOfDirectory(
                atPath: directory.path
            )) ?? []
            return Set(names.filter { $0.hasSuffix(".json") })
        }
    }

    private static func withSnapshotFixture(
        _ body: (SnapshotFixture) throws -> Void
    ) throws {
        let dir = try makeTempDir()
        defer { removeTempDir(dir) }
        let manager = RecoveryManager(recoveryDirectory: dir)
        manager.snapshotDirtyTabs([
            dirtyTab(path: "/tmp/project/README.md"),
            dirtyTab(path: "/tmp/project/notes.swift"),
        ])
        let entries = manager.pendingRecoveryEntries()
        #expect(entries.count == 2, "The fixture did not write its snapshots")
        try body(
            SnapshotFixture(
                directory: dir,
                manager: manager,
                entries: entries
            )
        )
    }

    /// Hosts the sheet wired to the fixture's manager through the production
    /// seam: the answer's choice and confirmed row decide what may be
    /// unlinked, and the call is made whatever the answer is.
    private static func hostResolvingSheet(
        _ fixture: SnapshotFixture
    ) -> HostedSheet {
        hostSheet(entries: fixture.entries) { answer in
            fixture.manager.deleteSnapshots(
                withRecoveryIDs: answer.choice.snapshotsToDelete(
                    row: answer.recoveryID,
                    from: fixture.entries
                )
            )
        }
    }

    private static func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PineRecoveryEscapeTests-\(UUID().uuidString)"
            )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }

    private static func removeTempDir(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private static func dirtyTab(path: String) -> EditorTab {
        EditorTab(
            url: URL(fileURLWithPath: path),
            content: "unsaved",
            savedContent: "saved"
        )
    }

    private static func hostSheet(
        entries: [(UUID, RecoveryEntry)]? = nil,
        locale: String = "en",
        onChoose: @escaping (RecoveryDialogAnswer) -> Void = { _ in }
    ) -> HostedSheet {
        let recorder = ChoiceRecorder()
        let hosted = NSHostingView(
            rootView: RecoveryDialogView(
                entries: entries ?? makeEntries()
            ) {
                recorder.record($0)
                onChoose($0)
            }
                .environment(\.locale, Locale(identifier: locale))
        )
        hosted.frame = NSRect(x: 0, y: 0, width: 420, height: 520)
        // Mirrors `AgentHistoryUndoReviewHostedTests`: borderless and parked
        // off screen so the window never flashes in front of whoever is
        // running the suite, and `isReleasedWhenClosed = false` because the
        // AppKit default would free it under the strong reference this test
        // still holds.
        let window = HostedTestWindow(
            contentRect: hosted.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosted
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(hosted)
        hosted.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        hosted.layoutSubtreeIfNeeded()
        return HostedSheet(
            window: window,
            recorder: recorder,
            // The combined closure — record, then hand to the seam — so a
            // direct call goes through exactly what the sheet reports
            // through.
            onChoose: { answer in
                recorder.record(answer)
                onChoose(answer)
            }
        )
    }

    private static func measuredWidth(
        of view: some View,
        locale: String
    ) -> CGFloat {
        measuredSize(of: view, locale: locale).width
    }

    /// The row's height when it is handed exactly the text column it is
    /// designed for.
    ///
    /// An unconstrained `fittingSize` proposes nothing, so a `Text` reports
    /// one ideal-width line however long its content is and `maxWidth` only
    /// clamps the number that comes back — a row that lost `.lineLimit(1)`
    /// measures identically. Wrapping the row in a fixed-width container is
    /// what forces the question the list will ask it in production.
    private static func heightInTextColumn(
        of entry: RecoveryEntry,
        locale: String
    ) -> CGFloat {
        measuredSize(
            of: RecoveryEntryRow(entry: entry)
                .frame(width: RecoveryDialogView.contentWidth),
            locale: locale
        ).height
    }

    private static func measuredSize(
        of view: some View,
        locale: String
    ) -> NSSize {
        let hosted = NSHostingView(
            rootView: view
                .environment(\.locale, Locale(identifier: locale))
        )
        hosted.layoutSubtreeIfNeeded()
        return hosted.fittingSize
    }

    private static func measuredFooterWidth(
        locale: String,
        controlSize: ControlSize = .regular
    ) -> CGFloat {
        let hosted = NSHostingView(
            rootView: RecoveryDialogFooter(onChoose: { _ in })
                .controlSize(controlSize)
                .environment(\.locale, Locale(identifier: locale))
        )
        hosted.layoutSubtreeIfNeeded()
        return hosted.fittingSize.width
    }

    private static func measuredSheetWidth(
        locale: String,
        controlSize: ControlSize = .regular,
        entries: [(UUID, RecoveryEntry)]? = nil
    ) -> CGFloat {
        let hosted = NSHostingView(
            rootView: RecoveryDialogView(entries: entries ?? makeEntries()) { _ in }
                .controlSize(controlSize)
                .environment(\.locale, Locale(identifier: locale))
        )
        hosted.frame = NSRect(x: 0, y: 0, width: 420, height: 520)
        hosted.layoutSubtreeIfNeeded()
        return hosted.fittingSize.width
    }

    private static func sendReturn(to window: NSWindow) {
        sendKey(to: window, characters: "\r", keyCode: 36)
    }

    private static func sendEscape(to window: NSWindow) {
        sendKey(to: window, characters: "\u{1B}", keyCode: 53)
    }

    private static func sendCommandPeriod(to window: NSWindow) {
        sendKey(
            to: window,
            characters: ".",
            keyCode: 47,
            modifierFlags: .command
        )
    }

    private static func sendKey(
        to window: NSWindow,
        characters: String,
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags = []
    ) {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifierFlags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ) else {
            Issue.record("Could not construct a hosted key event")
            return
        }
        if !window.performKeyEquivalent(with: event) {
            window.sendEvent(event)
        }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    private static func makeEntries() -> [(UUID, RecoveryEntry)] {
        [
            (
                UUID(),
                RecoveryEntry(
                    originalPath: "/tmp/project/README.md",
                    content: "unsaved"
                )
            ),
            (
                UUID(),
                RecoveryEntry(
                    originalPath: "",
                    untitledName: "Untitled 2",
                    content: "draft"
                )
            ),
        ]
    }

    private static func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func loadCatalog() throws -> [String: Any] {
        let data = try Data(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Pine/Localizable.xcstrings")
        )
        let root = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        return try #require(root["strings"] as? [String: Any])
    }

    /// Width of one retention footnote, with the typesetting language pinned.
    ///
    /// The footnote is a whole sentence, and in `ja` and `zh-Hans` a sentence
    /// carries punctuation that the typesetter squeezes — 「」、。 and ，。 —
    /// which a `Text(verbatim:)` does not get, because only a localized
    /// `Text` picks up the locale's typesetting language. Left alone that is a
    /// 33pt gap in Japanese between two strings that are character-for-
    /// character identical, which has nothing to do with the question being
    /// asked. Setting the language explicitly on both sides puts them in the
    /// same typesetting regime, and the two-point tolerance then measures only
    /// what it is meant to: did the catalog lookup resolve.
    private static func measuredNoticeWidth(
        _ text: Text,
        locale: String
    ) -> CGFloat {
        measuredWidth(
            of: text.typesettingLanguage(
                .explicit(Locale.Language(identifier: locale))
            ),
            locale: locale
        )
    }

    // MARK: - Reading the accessibility tree
    //
    // SwiftUI does not put its accessibility elements in the view hierarchy:
    // under an `NSHostingView` they are instances of SwiftUI's own
    // `AccessibilityNode`, reachable only through `accessibilityChildren()`,
    // and they are built lazily — before any accessibility client has asked,
    // the hosting view reports none at all. `AccessibilityNode` is an
    // `NSObject` that answers the usual accessibility selectors but does not
    // declare `NSAccessibilityProtocol` conformance, so Swift cannot call
    // them directly; KVC can, guarded by `responds(to:)`.
    //
    // Neither is a hack for its own sake: this is the tree VoiceOver reads,
    // and reading it any other way (subviews, focus order) would be asserting
    // about something else.

    /// Makes AppKit materialise the accessibility tree for this process.
    ///
    /// Querying our *own* pid needs no TCC grant — the trust check gates
    /// inspecting other processes — and it is the query itself that switches
    /// accessibility on, after which the hosting view's children exist.
    private static func awakenAccessibility() {
        let application = AXUIElementCreateApplication(getpid())
        var children: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(
            application,
            kAXChildrenAttribute as CFString,
            &children
        )
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    }

    private static func accessibilityValue(
        _ name: String,
        of element: NSObject
    ) -> Any? {
        guard element.responds(to: Selector((name))) else { return nil }
        return element.value(forKey: name)
    }

    /// The accessibility identifiers of every element the tree under the
    /// recovery sheet's own container calls a button.
    ///
    /// Scoped to the container rather than to the window so the count cannot
    /// be padded by anything AppKit puts beside the sheet, and returning
    /// identifiers rather than a number so a failure names what appeared.
    private static func accessibilityButtonIdentifiers(
        under root: NSView?
    ) throws -> [String] {
        guard let root else { return [] }
        awakenAccessibility()
        root.layoutSubtreeIfNeeded()

        let sheet = try #require(
            descendant(of: root) {
                accessibilityValue("accessibilityIdentifier", of: $0) as? String
                    == AccessibilityID.recoverySheet
            },
            """
            The sheet's container element is not in the accessibility tree \
            under \(AccessibilityID.recoverySheet), so nothing below can be \
            counted
            """
        )

        var identifiers: [String] = []
        forEachDescendant(of: sheet) { element in
            guard accessibilityValue("accessibilityRole", of: element)
                as? String == NSAccessibility.Role.button.rawValue else {
                return
            }
            identifiers.append(
                accessibilityValue("accessibilityIdentifier", of: element)
                    as? String ?? "«unidentified»"
            )
        }
        return identifiers
    }

    private static func descendant(
        of root: NSObject,
        where matches: (NSObject) -> Bool
    ) -> NSObject? {
        var result: NSObject?
        forEachDescendant(of: root) { element in
            if result == nil, matches(element) { result = element }
        }
        return result
    }

    // MARK: - Pressing the sheet's real buttons
    //
    // The Discard button carries no keyboard equivalent (#1503), so the only
    // way a test can reach it is the way a click does: the accessibility
    // action VoiceOver's activate gesture sends — the same mechanics
    // `AccessibilityTreeProbe` uses for sidebar rows. The confirmation alert
    // is AppKit behind SwiftUI's `.alert`, so its buttons live under the
    // window's attached sheet.

    /// Presses the element named `identifier` the way an assistive client's
    /// activate gesture does. `false` means no such element answered a press,
    /// which is a failure mode of its own: a button VoiceOver cannot use is
    /// a button the recovery sheet does not really offer.
    @discardableResult
    private static func pressButton(
        _ identifier: String,
        under root: NSView?
    ) -> Bool {
        guard let root else { return false }
        awakenAccessibility()
        root.layoutSubtreeIfNeeded()

        guard let button = descendant(of: root, where: {
            accessibilityValue("accessibilityIdentifier", of: $0) as? String
                == identifier
        }) else { return false }
        return AccessibilityTreeProbe.performPress(button) == true
    }

    @discardableResult
    private static func wait(
        forConfirmationAlertOn window: NSWindow
    ) -> NSWindow? {
        for _ in 0..<50 {
            if let sheet = window.attachedSheet { return sheet }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        }
        return window.attachedSheet
    }

    private static func forEachDescendant(
        of root: NSObject,
        _ body: (NSObject) -> Void
    ) {
        var stack: [NSObject] = [root]
        var visited = 0

        while let current = stack.popLast(), visited < 10_000 {
            visited += 1
            body(current)
            let children = accessibilityValue(
                "accessibilityChildren",
                of: current
            ) as? [Any] ?? []
            for child in children {
                guard let child = child as? NSObject else { continue }
                stack.append(child)
            }
        }
    }

    private static func value(
        for key: String,
        locale: String,
        in catalog: [String: Any]
    ) -> String? {
        guard let entry = catalog[key] as? [String: Any],
              let localizations = entry["localizations"] as? [String: Any],
              let localization = localizations[locale] as? [String: Any],
              let unit = localization["stringUnit"] as? [String: Any],
              let value = unit["value"] as? String else {
            return nil
        }
        return value
    }

    @MainActor
    private final class ChoiceRecorder {
        private(set) var chosen: [RecoveryDialogAnswer] = []

        /// The choices in report order, so tests written against the old
        /// choice-only shape keep reading the same way.
        var choices: [RecoveryDialogChoice] { chosen.map(\.choice) }

        func record(_ answer: RecoveryDialogAnswer) {
            chosen.append(answer)
        }
    }
}
