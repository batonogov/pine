//
//  DestructiveShortcutPolicyTests.swift
//  PineTests
//
//  Repo-wide guard for the bug class behind #1503: a `Button(role:
//  .destructive)` that also answers to a reflex key. Escape and Return are
//  pressed without looking; binding either to an irreversible action means a
//  user can destroy data by dismissing a dialog the way macOS taught them to.
//
//  These tests read production Swift as text. SwiftUI draws its own buttons,
//  so there is no `NSButton` in the hosted hierarchy whose `keyEquivalent` a
//  test could inspect; what the recovery sheet actually does with each key is
//  asserted by pressing them in `RecoveryDialogEscapeSafetyTests`. Scanning
//  the sources is what extends the invariant to code nobody has written yet.
//
//  A source scanner is only worth its runtime if it is itself tested, so the
//  scanner runs against built-in fixtures with known answers before it is
//  turned on the repository: one that must be reported, one that must not.
//
//  What it cannot see, stated plainly so nobody mistakes a green run for a
//  proof. Each of these has a fixture below asserting the blindness, so the
//  list cannot rot and closing a hole is a test that starts failing:
//
//    - a shortcut held in a variable or computed property, rather than written
//      at the call site — which is precisely how `RecoveryDialogView` now does
//      it (`.keyboardShortcut(choice.keyboardShortcuts.first)`). That file is
//      covered instead by `recoverySheetHasNoLiteralShortcut` below and by the
//      `isDestructive` guard inside `RecoveryDialogChoice.keyboardShortcuts`,
//      which makes the offending combination unrepresentable in the type;
//    - a proxy written as `Button(action:label:)` rather than with a trailing
//      closure. An invisible control in a destructive button's `.background`
//      carrying the reflex key — the other idiom this sheet introduces — *is*
//      caught when it is spelled `Button { … } label: { … }`, because the
//      window only ends at a literal `Button(`; spelled with an argument list
//      it ends the window instead and takes its own shortcut with it;
//    - `KeyboardShortcut.cancelAction` and `KeyboardShortcut(.escape)` spelled
//      in full, `.init(.escape)`, and a raw `"\u{1B}"` or `"\r"` character —
//      partially closed below, but only in the forms enumerated there;
//    - anything not written as a literal `Button(` — a wrapper view, a
//      `ForEach` over a table of actions, an AppKit `NSButton`.
//
//  In other words: this catches the bug as it was written in #1503 and the
//  obvious ways of rewriting it. It is a floor, not a ceiling.
//

import Foundation
import Testing

@Suite("Destructive buttons answer to no reflex key")
struct DestructiveShortcutPolicyTests {

    /// Ways of naming a keystroke a user produces without deciding anything.
    ///
    /// Matched against a window that also contains `.keyboardShortcut(`, so
    /// the spelling of the modifier and the spelling of the key can vary
    /// independently: `.keyboardShortcut(.cancelAction)` and
    /// `.keyboardShortcut(KeyboardShortcut.cancelAction)` are the same bug.
    private static let reflexShortcuts = [
        ".cancelAction",
        ".defaultAction",
        "(.escape",
        "(.return",
    ]

    // MARK: - The scanner, tested

    @Test("The scanner reports a destructive button bound to Escape")
    func scannerCatchesTheViolationItExistsFor() {
        let offenders = Self.offenders(in: Self.violationFixture)

        #expect(
            offenders.count == 1,
            "Expected exactly one offender, got \(offenders)"
        )
        #expect(offenders.first?.contains(".cancelAction") == true)
    }

    @Test("The scanner reports a conditionally destructive button too")
    func scannerCatchesAConditionalRole() {
        // The role does not have to be a literal. `role: isDestructive ?
        // .destructive : nil` is the form this repository's recovery sheet
        // uses, and an earlier version of this scanner was blind to it.
        let offenders = Self.offenders(in: Self.conditionalRoleFixture)

        #expect(
            offenders.count == 1,
            "A conditional destructive role slipped past the scanner: \(offenders)"
        )
    }

    @Test("The scanner reports a destructive button with a wrapped call")
    func scannerCatchesAMultiLineArgumentList() {
        let offenders = Self.offenders(in: Self.wrappedCallFixture)

        #expect(
            offenders.count == 1,
            "A wrapped `Button(` call slipped past the scanner: \(offenders)"
        )
    }

    @Test("The scanner does not blame a safe button standing before a destructive one")
    func scannerDoesNotBlameASafeNeighbour() {
        // The shape at `TerminalBarView.swift`: a plain `Button(title,
        // action:)` followed by a destructive one. Slicing the first button's
        // head up to the next `{` swallows the *second* button's role and
        // reports the safe button — with a file:line that points at innocent
        // code and a CI failure nobody can act on.
        #expect(Self.offenders(in: Self.safeNeighbourFixture).isEmpty)
        #expect(
            Self.destructiveButtonWindows(in: Self.safeNeighbourFixture).count == 1,
            "The scanner must still see the destructive button in that pair"
        )
    }

    @Test("The scanner leaves a destructive button with no shortcut alone")
    func scannerAcceptsADestructiveButtonWithoutAShortcut() {
        #expect(Self.offenders(in: Self.compliantFixture).isEmpty)
        #expect(
            Self.destructiveButtonWindows(in: Self.compliantFixture).count == 1
        )
    }

    @Test("The scanner's window reaches past the button's own closure")
    func scannerWindowCoversTheModifierChain() throws {
        // The modifier that carries the shortcut sits after the label closure
        // closes. A window that stops at the first `}` sees nothing and turns
        // the whole suite into a no-op that passes while the bug is live.
        let window = try #require(
            Self.destructiveButtonWindows(in: Self.violationFixture).first
        )
        #expect(window.contains(".keyboardShortcut"))
    }

    @Test("The scanner reports the spelled-out and constructed forms too")
    func scannerCatchesShortcutsThatAreNotDotShorthand() {
        #expect(
            Self.offenders(in: Self.spelledOutShortcutFixture).count == 1,
            "`KeyboardShortcut.cancelAction` written in full slipped past"
        )
        #expect(
            Self.offenders(in: Self.constructedShortcutFixture).count == 1,
            "`KeyboardShortcut(.escape)` slipped past"
        )
    }

    @Test("The scanner's blind spots are exactly the documented ones")
    func blindSpotsAreWhereTheyAreDocumented() {
        // A hole named in this file's header being closed is good news, and it
        // fails here so the header gets updated with it. A silent *new* hole
        // is what the header exists to prevent, and only a reader can catch
        // that — which is why the list is prose that must be maintained rather
        // than a comment nobody has to touch.
        #expect(
            Self.offenders(in: Self.indirectShortcutFixture).isEmpty,
            """
            The scanner now follows a shortcut through a property. Update the \
            header: `RecoveryDialogView` is no longer covered only by \
            `recoverySheetHasNoLiteralShortcut` and the `isDestructive` guard
            """
        )
        #expect(
            Self.offenders(in: Self.proxyShortcutFixture).count == 1,
            """
            The scanner stopped seeing a reflex key on a proxy control inside \
            a destructive button's `.background`. That is the second idiom \
            this sheet introduces, and losing it is a hole, not a cleanup
            """
        )
        // …and the destructive button is still *found* in both, so the
        // blindness is about the shortcut, not about the role.
        #expect(
            Self.destructiveButtonWindows(
                in: Self.indirectShortcutFixture
            ).count == 1
        )
    }

    // MARK: - The repository

    @Test("No destructive button in the app binds Escape or Return")
    func noDestructiveButtonBindsAReflexKey() throws {
        var offenders: [String] = []
        var scanned = 0

        for source in try Self.productionSources() {
            for window in Self.destructiveButtonWindows(in: source.text) {
                scanned += 1
                guard window.contains(".keyboardShortcut(") else { continue }
                for reflex in Self.reflexShortcuts where window.contains(reflex) {
                    offenders.append(
                        "\(source.name): \(Self.condense(window))"
                    )
                }
            }
        }

        #expect(
            scanned > 0,
            "The scanner found no destructive buttons at all — it stopped working"
        )
        #expect(
            offenders.isEmpty,
            """
            A destructive button must not answer to a reflex key: Escape and \
            Return get pressed without deciding, and there is no confirmation \
            and no undo behind them (#1503). Offenders:
            \(offenders.joined(separator: "\n"))
            """
        )
    }

    @Test("The scanner still sees the destructive buttons it is meant to guard")
    func scannerStillSeesKnownDestructiveButtons() throws {
        let files = try Self.productionSources()
            .filter { !Self.destructiveButtonWindows(in: $0.text).isEmpty }
            .map(\.name)

        // A refactor that hides every destructive button behind a helper would
        // silently turn this suite into a no-op. These files are the canaries —
        // `RecoveryDialogView.swift` above all, since it is the file the whole
        // guard was written for and it states its role conditionally.
        for expected in [
            "FileNodeRow.swift",
            "EditorTabBar.swift",
            "RecoveryDialogView.swift",
        ] {
            #expect(
                files.contains(expected),
                "\(expected) no longer exposes a destructive button to the scanner"
            )
        }
    }

    @Test("The recovery sheet spells no keystroke out at its buttons")
    func recoverySheetHasNoLiteralShortcut() throws {
        let source = try Self.source(named: "Pine/RecoveryDialogView.swift")
        let literals = [
            ".cancelAction",
            ".defaultAction",
            ".escape",
            ".return",
            "KeyboardShortcut(",
        ]
        let offenders = source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .filter { _, line in
                line.contains(".keyboardShortcut(")
                    && literals.contains { line.contains($0) }
            }
            .map {
                "RecoveryDialogView.swift:\($0.offset + 1): "
                    + $0.element.trimmingCharacters(in: .whitespaces)
            }

        #expect(
            offenders.isEmpty,
            """
            Every keystroke in the recovery sheet must come from \
            `RecoveryDialogChoice.keyboardShortcuts`, where the destructive \
            case is asserted to carry none (#1503). Offenders: \(offenders)
            """
        )
        // …and the property that owns them must still be the one being used.
        #expect(source.contains("choice.keyboardShortcuts"))
    }

    // MARK: - The seam between the sheet and the filesystem
    //
    // `ContentView+Helpers.swift` is where the sheet's answer becomes an
    // `unlink`, and it is invisible to everything else that guards this area:
    // the coverage gate excludes it by name
    // (`.github/scripts/check_coverage.py`), no unit test loads `ContentView`,
    // and the hosted sheet tests stop at the enum the view emits. So the seam
    // is asserted here, as text — the same way this file already asserts that
    // the sheet spells no keystroke out.
    //
    // **What these two scanners are.** A required-substring list and a
    // blacklist, run over one function's body with its whitespace collapsed.
    // They pin the shape the reviewed code has; they do not understand it.
    // They do catch, and there are fixtures below proving each:
    //
    //   - a branch that builds its own list of IDs instead of asking the
    //     choice (the exact shape of #1503, reintroduced at the call site);
    //   - the two branches swapped, so Recover All deletes and Discard
    //     restores — the condensed match pins `case .recoverAll:` to the call
    //     that follows it;
    //   - any of the three statements that *end* the safe branch going
    //     missing. Only the deleting call used to be pinned, which left the
    //     rest of the branch free: dropping `showRecoveryDialog = false`
    //     makes the sheet unclosable, because it has no system dismissal and
    //     Escape now lands in this very branch — leaving Discard and Force
    //     Quit as the only ways out, which is #1503 by a third road and with
    //     a green suite. Dropping `markRecoveryOfferAnswered()` turns "not
    //     now" into "again in ten seconds", since the snapshots are still on
    //     disk, own no live tab, and the scene `.task` re-runs on restoration
    //     and on close/reopen. Both are pinned as one condensed sequence, so
    //     they cannot be reordered or separated either;
    //   - the same three-statement tail after the `await` in `recoverTabs`,
    //     where the consequence is milder (migrated snapshots carry live tab
    //     IDs and are filtered out of the offer) but the shape is identical;
    //   - `checkForRecovery` going back to `pendingRecoveryEntries()`.
    //
    // What they do not catch, stated so nobody reads green as proof:
    //
    //   - a *second* deleting call added next to the required one. The
    //     required substring is still there and the blacklist does not know
    //     about the new call;
    //   - a list of IDs spelled some third way — `map { entry in entry.0 }`,
    //     a helper, a stored property — the blacklist names two spellings;
    //   - a `/* … */` comment. `strippingLineComments` only knows `//`, so a
    //     block comment's contents reach the needles as if they were code —
    //     a required substring quoted inside one satisfies its rule, and a
    //     forbidden one mentioned inside one fails it. Neither function these
    //     rules run against contains a block comment;
    //   - a function body that closes early. `functionBody` ends at the first
    //     `"\n    }\n"` — a line closing at method indentation — so a nested
    //     closure or type indented back to four spaces truncates the body
    //     there, and everything after it is invisible to every rule. The
    //     bodies scanned here indent their closures deeper than that;
    //   - anything at all in `RecoveryManager`, which is where the deletion
    //     actually happens. That side is covered by behaviour, in
    //     `RecoveryTerminationSweepTests` and `RecoveryManagerTests`.

    private struct SourceRule {
        let needle: String
        let mustBePresent: Bool
        let reason: String
    }

    /// The resolver's shape: what applying a choice must and must not say.
    private static let resolverRules: [SourceRule] = [
        SourceRule(
            needle: "withRecoveryIDs: choice.snapshotsToDelete(from: recoveryEntries)",
            mustBePresent: true,
            reason: """
                The deletion decision has to stay on `RecoveryDialogChoice`, \
                where it is enumerated by test and shares a value with the \
                button role and the empty shortcut list (#1503)
                """
        ),
        SourceRule(
            needle: "switch choice {",
            mustBePresent: true,
            reason: """
                The resolver must switch over the choice, so a fourth case is \
                a compile error rather than a silent fall-through
                """
        ),
        SourceRule(
            needle: "case .recoverAll: recoverTabs() case .discard, .later:",
            mustBePresent: true,
            reason: """
                Recover All must run the restorer and nothing else, and the \
                other two must share the deleting branch. Matched as one \
                condensed sequence so the branches cannot be swapped or \
                have anything slipped between them — `case .recoverAll: \
                showRecoveryDialog = false` is a Recover All that silently \
                does nothing, and it satisfies every separate substring
                """
        ),
        SourceRule(
            needle: """
                projectManager.markRecoveryOfferAnswered() \
                showRecoveryDialog = false recoveryEntries = []
                """,
            mustBePresent: true,
            reason: """
                The safe branch must answer the offer, close the sheet and \
                clear the list — all three, in that order. Only the deleting \
                call above was pinned, which left the rest of this branch \
                free to be edited away one statement at a time. Dropping \
                `showRecoveryDialog = false` leaves the sheet with no way \
                out at all: a SwiftUI sheet has no system dismissal here, \
                and Escape resolves to `.later`, which is this branch — so \
                the only exits become the irreversible Discard and Force \
                Quit. Dropping `markRecoveryOfferAnswered()` makes "Later" \
                mean "again in ten seconds": the snapshots are deliberately \
                still on disk, they belong to no open tab so the live filter \
                keeps them, and the scene `.task` re-runs on restoration and \
                on close/reopen. Matched condensed so the three cannot be \
                separated or reordered (#1503)
                """
        ),
        SourceRule(
            needle: "default:",
            mustBePresent: false,
            reason: """
                A `default:` turns a fourth choice into "close the sheet, \
                delete nothing, mark it answered" instead of a compile error
                """
        ),
        SourceRule(
            needle: "if choice.isDestructive",
            mustBePresent: false,
            reason: """
                The deletion is behind a condition again. Escape resolves to \
                `.later` and reaches the same call: the only thing that keeps \
                it from deleting is what the choice hands back, not what the \
                call site tests (#1503)
                """
        ),
        SourceRule(
            needle: "recoveryEntries.map(\\.0)",
            mustBePresent: false,
            reason: "The resolver builds its own list of IDs to delete (#1503)"
        ),
        SourceRule(
            needle: "recoveryEntries.map { $0.0 }",
            mustBePresent: false,
            reason: "The resolver builds its own list of IDs to delete (#1503)"
        ),
    ]

    /// What starting a Recover All must and must not say.
    private static let restoreRules: [SourceRule] = [
        SourceRule(
            needle: "projectManager.beginRecoveryRestore() Task { @MainActor in defer { projectManager.endRecoveryRestore() }",
            mustBePresent: true,
            reason: """
                The restore has to be marked in flight *before* the task is \
                started and cleared from a `defer` inside it. Restoring parks \
                on a native large-file sheet, and a scene `.task` re-running \
                in that window otherwise builds a second recovery sheet from \
                the same crash entries — which migrates them twice, leaves \
                the parked restore resuming against a detached `TabManager`, \
                and writes a snapshot under a runtime ID no window owns \
                (#1503). Matched as one condensed sequence so the call cannot \
                drift after the `Task` or lose its `defer`
                """
        ),
        SourceRule(
            needle: """
                projectManager.markRecoveryOfferAnswered() \
                recoveryEntries = retained \
                showRecoveryDialog = !retained.isEmpty
                """,
            mustBePresent: true,
            reason: """
                The same three-statement tail as the safe branch of the \
                resolver, and free for the same reason: nothing else pinned \
                it. It has to run *after* the `await`, because a restore that \
                never finishes must not silence the offer, and it has to run \
                in full — `showRecoveryDialog = !retained.isEmpty` is what \
                puts anything the restorer handed back in front of the user \
                again instead of dropping it silently. Milder than the \
                resolver's copy (a migrated snapshot carries a live tab's ID \
                and the offer filters it out) but the same shape (#1503)
                """
        ),
        SourceRule(
            needle: "Task.isCancelled",
            mustBePresent: false,
            reason: """
                An unstructured `Task` inherits no cancellation and this one's \
                handle is discarded, so nothing in the app can cancel it and \
                the guard can never fire. It reads like ⌘W is handled here; \
                ⌘W does not even reach `closeActiveTab()` while the sheet is \
                up, because `documentWindow(for: NSApp.keyWindow)` resolves to \
                the sheet, whose delegate is not a `CloseDelegate`
                """
        ),
    ]

    /// What deciding whether to show the sheet must and must not say.
    private static let offerRules: [SourceRule] = [
        SourceRule(
            needle: "projectManager.pendingRecoveryOffer()",
            mustBePresent: true,
            reason: """
                The offer has to come from the project, which outlives the \
                window and remembers being answered, and which filters out \
                snapshots belonging to tabs that are open right now (#1503)
                """
        ),
        SourceRule(
            needle: "pendingRecoveryEntries",
            mustBePresent: false,
            reason: """
                `pendingRecoveryEntries()` is every JSON file in the \
                directory. Going back to it re-offers on every scene `.task` \
                — SwiftUI re-runs those on restoration and on close/reopen — \
                and puts live dirty tabs into `recoveryEntries`, where \
                Discard deletes the crash protection of buffers the user is \
                looking at (#1503)
                """
        ),
    ]

    /// Drops `//` comments so a body can explain, in prose, the mistake its
    /// blacklist forbids — `checkForRecovery` names `pendingRecoveryEntries()`
    /// in a comment saying why it does not call it.
    ///
    /// Naive about `//` inside a string literal. Neither function these rules
    /// run against contains one, and a scanner that silently matched a comment
    /// would be worse than one that occasionally has to be taught about a URL.
    ///
    /// Naive about `/* … */` as well, and that one fails the other way: a
    /// block comment's contents survive into the condensed text and are
    /// matched as if they were code. Listed in this file's header among the
    /// blind spots; neither scanned function contains one.
    private static func strippingLineComments(_ body: String) -> String {
        body
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let comment = line.range(of: "//") else { return line }
                return line[line.startIndex..<comment.lowerBound]
            }
            .joined(separator: "\n")
    }

    private static func violations(
        of rules: [SourceRule],
        in body: String
    ) -> [String] {
        let condensed = condense(strippingLineComments(body))
        return rules.compactMap { rule in
            guard condensed.contains(rule.needle) != rule.mustBePresent else {
                return nil
            }
            let verb = rule.mustBePresent ? "missing" : "present"
            return "\(verb) `\(rule.needle)`: \(rule.reason)"
        }
    }

    @Test("The resolver asks the choice what it may delete, and asks always")
    func theResolverRoutesDeletionThroughTheChoice() throws {
        let body = try Self.functionBody(
            startingAt: "func resolveRecoveryOffer(",
            in: try Self.source(named: "Pine/ContentView+Helpers.swift")
        )

        #expect(
            Self.violations(of: Self.resolverRules, in: body).isEmpty,
            """
            `resolveRecoveryOffer` no longer has the shape #1503 was fixed \
            into: \(Self.violations(of: Self.resolverRules, in: body))
            """
        )
    }

    @Test("The offer comes from the project, not from the directory listing")
    func checkForRecoveryAsksTheProjectForTheOffer() throws {
        let body = try Self.functionBody(
            startingAt: "func checkForRecovery(",
            in: try Self.source(named: "Pine/ContentView+Helpers.swift")
        )

        #expect(
            Self.violations(of: Self.offerRules, in: body).isEmpty,
            """
            `checkForRecovery` no longer asks the project what is worth \
            offering: \(Self.violations(of: Self.offerRules, in: body))
            """
        )
    }

    @Test("A Recover All marks itself in flight for as long as it runs")
    func recoverTabsMarksTheRestoreInFlight() throws {
        let body = try Self.functionBody(
            startingAt: "func recoverTabs(",
            in: try Self.source(named: "Pine/ContentView+Helpers.swift")
        )

        #expect(
            Self.violations(of: Self.restoreRules, in: body).isEmpty,
            """
            `recoverTabs` no longer fences its in-flight window: \
            \(Self.violations(of: Self.restoreRules, in: body))
            """
        )
    }

    @Test("The resolver scanner fails on a resolver that deletes on Later")
    func resolverScannerCatchesAMutatedResolver() {
        // Without these, both scans above are assertions nobody has ever seen
        // fail — the shape of guard that passes because its needle happens to
        // be somewhere in the file. The shortcut scanner in this file is
        // tested against fixtures; so are these.
        #expect(
            Self.violations(
                of: Self.resolverRules,
                in: Self.compliantResolverFixture
            ).isEmpty,
            "The scanner reports the shape the repository actually ships"
        )
        #expect(
            !Self.violations(
                of: Self.resolverRules,
                in: Self.laterDeletesResolverFixture
            ).isEmpty,
            """
            A resolver whose `.later` branch builds its own list of IDs — \
            #1503 rewritten at the call site — passed the scan
            """
        )
        #expect(
            !Self.violations(
                of: Self.resolverRules,
                in: Self.swappedBranchesResolverFixture
            ).isEmpty,
            """
            A resolver with Recover All and Discard transposed passed the \
            scan: every required substring is present, only the pairing is \
            wrong, and that is what the condensed sequence exists to pin
            """
        )
        #expect(
            !Self.violations(
                of: Self.resolverRules,
                in: Self.silentRecoverAllResolverFixture
            ).isEmpty,
            "A Recover All that closes the sheet and restores nothing passed"
        )
        #expect(
            !Self.violations(
                of: Self.resolverRules,
                in: Self.unclosableSheetResolverFixture
            ).isEmpty,
            """
            A resolver whose safe branch never closes the sheet passed the \
            scan. There is no system dismissal behind this sheet and Escape \
            lands in that branch, so the only remaining ways out are the \
            irreversible Discard and Force Quit — #1503 by a third road
            """
        )
        #expect(
            !Self.violations(
                of: Self.resolverRules,
                in: Self.unansweredOfferResolverFixture
            ).isEmpty,
            """
            A resolver whose safe branch never marks the offer answered \
            passed the scan: "Later" becomes "again on the next scene task"
            """
        )
    }

    @Test("The offer scanner fails on a checkForRecovery that lists the directory")
    func offerScannerCatchesADirectoryListing() {
        #expect(
            Self.violations(
                of: Self.offerRules,
                in: Self.compliantOfferFixture
            ).isEmpty
        )
        #expect(
            !Self.violations(
                of: Self.offerRules,
                in: Self.directoryListingOfferFixture
            ).isEmpty,
            """
            `checkForRecovery` reading `pendingRecoveryEntries()` directly \
            passed the scan
            """
        )
    }

    @Test("The restore scanner fails on a restore that drops its tail")
    func restoreScannerCatchesAMutatedRestore() {
        #expect(
            Self.violations(
                of: Self.restoreRules,
                in: Self.compliantRestoreFixture
            ).isEmpty,
            "The scanner reports the shape the repository actually ships"
        )
        #expect(
            !Self.violations(
                of: Self.restoreRules,
                in: Self.unansweredRestoreFixture
            ).isEmpty,
            """
            A Recover All that finishes without answering the offer passed \
            the scan: the restored buffers' snapshots now carry live tab IDs \
            and are filtered out, but anything the restorer handed back is \
            offered again on the next scene task
            """
        )
        #expect(
            !Self.violations(
                of: Self.restoreRules,
                in: Self.droppedRetainedRestoreFixture
            ).isEmpty,
            """
            A Recover All that swallows the entries the restorer could not \
            restore passed the scan: the user cancelled a large-file prompt \
            and is never told the buffer is still waiting
            """
        )
    }

    @Test("Recovery discovery is awaited before a terminal can be seeded")
    func theTaskAwaitsRecoveryDiscoveryBeforeSeeding() throws {
        // `checkForRecovery()` suspends now — it reads the snapshot directory
        // off the main actor (#1503) — and the very next call,
        // `seedInitialTerminalIfNeeded(disposition:)`, guards on
        // `showRecoveryDialog` and `recoveryEntries`, the two properties
        // `checkForRecovery` sets. Dropping the `await` (or moving the call
        // into a detached `Task`) compiles with a warning at most, and turns
        // a pending offer into a race: the seeding guard reads the flags
        // before they are set, replaces the empty editor leaf with a
        // terminal, and the sheet then offers to recover into a pane that is
        // no longer there.
        //
        // Whole-file rather than scoped: this pair lives in a `.task`
        // closure, not in a `func`, so `functionBody` cannot reach it. The
        // condensed form tolerates the comment block between the two calls —
        // see `condense`.
        let source = try Self.condense(
            Self.strippingLineComments(
                Self.source(named: "Pine/ContentView.swift")
            )
        )

        #expect(
            source.contains(
                "await checkForRecovery() seedInitialTerminalIfNeeded(disposition: disposition)"
            ),
            """
            The project scene's `.task` no longer awaits recovery discovery \
            immediately before seeding an initial terminal (#1503, #1251)
            """
        )
    }

    @Test("The recovery sheet's button role comes from the choice")
    func recoverySheetDerivesTheButtonRoleFromTheChoice() throws {
        // Inverting the ternary paints the two safe buttons red and the
        // irreversible one neutral. Nothing else sees it: SwiftUI's
        // `ButtonRole` is not readable from the hosted hierarchy, the shortcut
        // scanner only asks whether `.destructive` appears in the argument
        // list — it still does — and every behavioural test in
        // `RecoveryDialogEscapeSafetyTests` stops at which choice came back.
        let source = try Self.source(named: "Pine/RecoveryDialogView.swift")

        #expect(
            source.contains(
                "Button(role: choice.isDestructive ? .destructive : nil)"
            ),
            """
            The recovery sheet no longer derives each button's role from \
            `RecoveryDialogChoice.isDestructive` in the reviewed form. The \
            colour of the only irreversible control on this sheet is the one \
            warning a sighted user gets before clicking it (#1503)
            """
        )
    }

    @Test("The recovery sheet still offers an irreversible discard")
    func recoverySheetStillOffersDiscard() throws {
        let source = try Self.source(named: "Pine/RecoveryDialogView.swift")

        // Removing Escape must not have been achieved by removing the choice:
        // a deliberate discard is still a supported, wanted action.
        #expect(source.contains(".destructive"))
        #expect(source.contains("case discard"))
    }

    // MARK: - Fixtures

    private static let violationFixture = """
        var body: some View {
            Button(role: .destructive) {
                deleteEverything()
            } label: {
                Text("Discard")
            }
            .keyboardShortcut(.cancelAction)
        }
        """

    private static let conditionalRoleFixture = """
        var body: some View {
            Button(role: isDangerous ? .destructive : nil) {
                deleteEverything()
            } label: {
                Text("Discard")
            }
            .keyboardShortcut(.defaultAction)
        }
        """

    private static let wrappedCallFixture = """
        var body: some View {
            Button(
                role: .destructive,
                action: deleteEverything
            ) {
                Text("Discard")
            }
            .keyboardShortcut(.escape)
        }
        """

    private static let safeNeighbourFixture = """
        var body: some View {
            HStack {
                Button(resume.title, action: resume.action)
                    .keyboardShortcut(.cancelAction)
                Button(role: .destructive) {
                    onClose()
                } label: {
                    Label("Close", systemImage: "xmark")
                }
                .disabled(!canClose)
            }
        }
        """

    private static let spelledOutShortcutFixture = """
        var body: some View {
            Button(role: .destructive) {
                deleteEverything()
            } label: {
                Text("Discard")
            }
            .keyboardShortcut(KeyboardShortcut.cancelAction)
        }
        """

    private static let constructedShortcutFixture = """
        var body: some View {
            Button(role: .destructive) {
                deleteEverything()
            } label: {
                Text("Discard")
            }
            .keyboardShortcut(KeyboardShortcut(.escape))
        }
        """

    /// A destructive button whose keystroke arrives through a property. The
    /// scanner cannot follow it, and `blindSpotsAreWhereTheyAreDocumented`
    /// asserts exactly that so the limitation is checked rather than claimed.
    private static let indirectShortcutFixture = """
        var body: some View {
            Button(role: .destructive) {
                deleteEverything()
            } label: {
                Text("Discard")
            }
            .keyboardShortcut(choice.shortcut)
        }
        """

    /// A destructive button carrying Escape on an invisible proxy in its
    /// `.background` — the idiom the recovery sheet uses for its second
    /// cancellation gesture, and one the scanner does catch: a trailing-closure
    /// `Button {` is not the literal `Button(` that ends a window, so the proxy
    /// and its shortcut stay inside the destructive button's slice.
    private static let proxyShortcutFixture = """
        var body: some View {
            Button(role: .destructive) {
                deleteEverything()
            } label: {
                Text("Discard")
            }
            .background {
                Button { deleteEverything() } label: { Color.clear }
                    .keyboardShortcut(.cancelAction)
            }
        }
        """

    /// The resolver as this branch ships it, so the rules are known to pass
    /// something other than the file they were written against.
    private static let compliantResolverFixture = """
        func resolveRecoveryOffer(_ choice: RecoveryDialogChoice) {
            switch choice {
            case .recoverAll:
                recoverTabs()
            case .discard, .later:
                projectManager.recoveryManager?.deleteSnapshots(
                    withRecoveryIDs: choice.snapshotsToDelete(from: recoveryEntries)
                )
                projectManager.markRecoveryOfferAnswered()
                showRecoveryDialog = false
                recoveryEntries = []
            }
        }
        """

    /// #1503 rewritten one layer down: the choice is still switched on, but
    /// the branch Escape lands in deletes everything the sheet was showing.
    private static let laterDeletesResolverFixture = """
        func resolveRecoveryOffer(_ choice: RecoveryDialogChoice) {
            switch choice {
            case .recoverAll:
                recoverTabs()
            case .discard, .later:
                projectManager.recoveryManager?.deleteSnapshots(
                    withRecoveryIDs: recoveryEntries.map(\\.0)
                )
                projectManager.markRecoveryOfferAnswered()
                showRecoveryDialog = false
                recoveryEntries = []
            }
        }
        """

    /// Every required substring present, both branches intact — and wired to
    /// each other the wrong way round.
    private static let swappedBranchesResolverFixture = """
        func resolveRecoveryOffer(_ choice: RecoveryDialogChoice) {
            switch choice {
            case .discard, .later:
                recoverTabs()
            case .recoverAll:
                projectManager.recoveryManager?.deleteSnapshots(
                    withRecoveryIDs: choice.snapshotsToDelete(from: recoveryEntries)
                )
                projectManager.markRecoveryOfferAnswered()
                showRecoveryDialog = false
                recoveryEntries = []
            }
        }
        """

    /// Recover All that closes the sheet and restores nothing: the user's
    /// work stays on disk and they are told it was recovered.
    private static let silentRecoverAllResolverFixture = """
        func resolveRecoveryOffer(_ choice: RecoveryDialogChoice) {
            switch choice {
            case .recoverAll:
                showRecoveryDialog = false
            case .discard, .later:
                projectManager.recoveryManager?.deleteSnapshots(
                    withRecoveryIDs: choice.snapshotsToDelete(from: recoveryEntries)
                )
                projectManager.markRecoveryOfferAnswered()
                showRecoveryDialog = false
                recoveryEntries = []
            }
        }
        """

    /// The in-flight fence and the post-`await` tail as this branch ships
    /// them, comment block included — which is also what proves `condense`
    /// does not let a comment split a pinned sequence.
    private static let compliantRestoreFixture = """
        func recoverTabs() {
            projectManager.beginRecoveryRestore()
            Task { @MainActor in
                defer { projectManager.endRecoveryRestore() }
                let retained = await recoveryManager.restorePendingEntries(
                    entries,
                    in: target,
                    context: context
                )
                // Answered once the restore has actually finished, not
                // before the `await`.
                projectManager.markRecoveryOfferAnswered()
                recoveryEntries = retained
                showRecoveryDialog = !retained.isEmpty
            }
        }
        """

    /// A restore that finishes without recording that the offer was answered.
    private static let unansweredRestoreFixture = """
        func recoverTabs() {
            projectManager.beginRecoveryRestore()
            Task { @MainActor in
                defer { projectManager.endRecoveryRestore() }
                let retained = await recoveryManager.restorePendingEntries(
                    entries,
                    in: target,
                    context: context
                )
                recoveryEntries = retained
                showRecoveryDialog = !retained.isEmpty
            }
        }
        """

    /// A restore that throws away whatever the restorer could not restore.
    private static let droppedRetainedRestoreFixture = """
        func recoverTabs() {
            projectManager.beginRecoveryRestore()
            Task { @MainActor in
                defer { projectManager.endRecoveryRestore() }
                _ = await recoveryManager.restorePendingEntries(
                    entries,
                    in: target,
                    context: context
                )
                projectManager.markRecoveryOfferAnswered()
                recoveryEntries = []
                showRecoveryDialog = false
            }
        }
        """

    /// The safe branch with `showRecoveryDialog = false` taken out. Every
    /// previously pinned substring is still present — the deleting call, the
    /// switch, the branch pairing — and the sheet can no longer be closed at
    /// all: Escape resolves to `.later`, which is this branch.
    private static let unclosableSheetResolverFixture = """
        func resolveRecoveryOffer(_ choice: RecoveryDialogChoice) {
            switch choice {
            case .recoverAll:
                recoverTabs()
            case .discard, .later:
                projectManager.recoveryManager?.deleteSnapshots(
                    withRecoveryIDs: choice.snapshotsToDelete(from: recoveryEntries)
                )
                projectManager.markRecoveryOfferAnswered()
                recoveryEntries = []
            }
        }
        """

    /// The safe branch that never records the answer: the sheet closes, the
    /// snapshots stay on disk owned by no live tab, and the next scene `.task`
    /// — scene restoration, or the window closed and reopened — offers them
    /// straight back.
    private static let unansweredOfferResolverFixture = """
        func resolveRecoveryOffer(_ choice: RecoveryDialogChoice) {
            switch choice {
            case .recoverAll:
                recoverTabs()
            case .discard, .later:
                projectManager.recoveryManager?.deleteSnapshots(
                    withRecoveryIDs: choice.snapshotsToDelete(from: recoveryEntries)
                )
                showRecoveryDialog = false
                recoveryEntries = []
            }
        }
        """

    private static let compliantOfferFixture = """
        func checkForRecovery() async {
            let entries = await projectManager.pendingRecoveryOffer()
            guard !entries.isEmpty else { return }
            recoveryEntries = entries
            showRecoveryDialog = true
        }
        """

    private static let directoryListingOfferFixture = """
        func checkForRecovery() async {
            guard let entries = projectManager.recoveryManager?.pendingRecoveryEntries(),
                  !entries.isEmpty else { return }
            recoveryEntries = entries
            showRecoveryDialog = true
        }
        """

    private static let compliantFixture = """
        var body: some View {
            Button(role: .destructive) {
                deleteEverything()
            } label: {
                Text("Discard")
            }
            .disabled(!canDelete)
        }
        """

    // MARK: - Helpers

    private struct Source {
        let name: String
        let text: String
    }

    private static func offenders(in text: String) -> [String] {
        destructiveButtonWindows(in: text).filter { window in
            window.contains(".keyboardShortcut(")
                && reflexShortcuts.contains { window.contains($0) }
        }
        .map(condense)
    }

    /// Source slices that begin at a destructive `Button(` and end where its
    /// modifier chain plausibly ends: the next `Button(`, the next
    /// `Divider()`, or the next blank line — whichever comes first. Modifier
    /// chains are written without blank lines in this codebase, so a window
    /// covers the whole chain, including the modifiers that follow the label
    /// closure, without spilling into a sibling declaration.
    private static func destructiveButtonWindows(in text: String) -> [String] {
        var windows: [String] = []
        var searchStart = text.startIndex

        while let buttonStart = text.range(
            of: "Button(",
            range: searchStart..<text.endIndex
        ) {
            searchStart = buttonStart.upperBound

            // The role lives in the argument list, so the head must end at the
            // parenthesis that closes it — not at the first `{`, which belongs
            // to a *later* button whenever this one has no closure of its own.
            guard let head = argumentList(
                openedAt: buttonStart.upperBound,
                in: text
            ), text[head].contains(".destructive") else { continue }

            let terminators = ["Button(", "Divider()", "\n\n"]
            let windowEnd = terminators.compactMap {
                text.range(
                    of: $0,
                    range: head.upperBound..<text.endIndex
                )?.lowerBound
            }.min() ?? text.endIndex
            windows.append(String(text[buttonStart.lowerBound..<windowEnd]))
        }

        return windows
    }

    /// The span between `Button(` and the parenthesis that closes it.
    ///
    /// Tracks nesting and string literals so an inline closure argument
    /// (`Button(role: .destructive, action: { … })`) or a nested call does not
    /// end the scan early, and returns `nil` for anything it cannot resolve
    /// rather than guessing at a boundary.
    private static func argumentList(
        openedAt open: String.Index,
        in text: String
    ) -> Range<String.Index>? {
        var parenDepth = 1
        var braceDepth = 0
        var index = open
        var inString = false
        var escaped = false
        var scanned = 0

        while index < text.endIndex, scanned < 1_000 {
            let character = text[index]
            scanned += 1

            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
            } else {
                switch character {
                case "\"": inString = true
                case "(": parenDepth += 1
                case "{": braceDepth += 1
                case "}":
                    braceDepth -= 1
                    if braceDepth < 0 { return nil }
                case ")":
                    guard braceDepth == 0 else { break }
                    parenDepth -= 1
                    if parenDepth == 0 { return open..<index }
                default: break
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    private static func productionSources() throws -> [Source] {
        // The enumeration this suite introduced now lives in
        // `ProductionSourceScan`, so the hidden-ancestor trap and the
        // non-empty guard are written once rather than per suite (#1508).
        let urls = try ProductionSourceScan.swiftFileURLs(
            under: repositoryRoot().appendingPathComponent("Pine")
        )

        return try urls.map {
            Source(
                name: $0.lastPathComponent,
                text: try String(contentsOf: $0, encoding: .utf8)
            )
        }
    }

    /// The text of one function, from its `func` keyword to the line that
    /// closes it at method indentation.
    ///
    /// Scoped rather than whole-file, because a whole-file `contains` is a
    /// guard that reports whatever some unrelated declaration happens to say —
    /// `ContentView+Helpers.swift` has a `default:` two hundred lines below
    /// the resolver, and matching it would make the exhaustiveness check pass
    /// or fail for reasons nobody intended.
    ///
    /// "Closes it" means the first line that is exactly `    }` — four spaces,
    /// method indentation. A nested closure or nested type whose own closing
    /// brace lands at that column ends the body early and hides everything
    /// after it from every rule, silently. The two bodies scanned here indent
    /// their closures deeper; the limitation is in this file's header.
    private static func functionBody(
        startingAt signature: String,
        in source: String
    ) throws -> String {
        let start = try #require(
            source.range(of: signature),
            "\(signature) is gone from the file this guard reads"
        )
        let end = try #require(
            source.range(
                of: "\n    }\n",
                range: start.upperBound..<source.endIndex
            ),
            "\(signature) is never closed at method indentation"
        )
        return String(source[start.lowerBound..<end.upperBound])
    }

    private static func source(named relativePath: String) throws -> String {
        try String(
            contentsOf: repositoryRoot().appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private static func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// Collapses a source slice onto one line, one space between statements.
    ///
    /// Blank lines are dropped *after* trimming, not only before it: a line
    /// that held nothing but a `//` comment comes out of
    /// ``strippingLineComments(_:)`` as whitespace, which `split` still counts
    /// as a line and which would otherwise join as an empty string and put two
    /// spaces into the middle of a condensed sequence. Every multi-statement
    /// needle in this file would then depend on whether anyone had written a
    /// comment inside the run it pins — a failure with nothing wrong behind
    /// it. `recoverTabs` has eight such lines between its `await` and the tail
    /// that follows it.
    private static func condense(_ window: String) -> String {
        window
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
