//
//  RecoveryDialogView.swift
//  Pine
//

import Foundation
import SwiftUI

/// One answer from the recovery list: what was chosen, and for which row.
struct RecoveryDialogAnswer: Equatable {
    let choice: RecoveryDialogChoice
    /// The row the choice was made for.
    let recoveryID: UUID?
}

/// One choice offered by the recovery list, paired with the keyboard
/// equivalents it is allowed to answer to and the snapshots it is allowed to
/// unlink.
///
/// The shortcut policy *and* the deletion policy live on this type instead of
/// being spelled out at each `Button` and at the call site that applies the
/// answer, because this sheet is the one SwiftUI surface in Pine where a
/// single keystroke can unlink unsaved work. Escape used to be bound to
/// ``discard``, so dismissing the sheet the way macOS teaches you to deleted
/// every recovered buffer — no confirmation, no undo (#1503). Keeping "which
/// key runs which choice" and "what that choice deletes" on the same value
/// makes both checked invariants instead of layout details, and it puts them
/// where a test can enumerate them: the resolver in `ContentView+Helpers`
/// lives in a file the coverage gate excludes and no unit test loads.
///
/// This is the SwiftUI half of a policy `AlertTemplate` already implements for
/// every `NSAlert` in the app: exactly one default button, at most one
/// cancellation target, cancellation reachable by both Escape and ⌘-., and
/// the destructive button reachable by neither. Change one of the two and check
/// the other — `AlertTemplate.buttonRoles` carries the matching note.
enum RecoveryDialogChoice: String, CaseIterable, Sendable {
    /// Deletes one row's snapshot. Irreversible, so the sheet asks again
    /// before it reports this (#1760).
    case discard
    /// Closes the sheet and leaves every snapshot on disk. Later is the only
    /// way a snapshot outlives the user's attention now that nothing collects
    /// it by age: File ▸ Recover Unsaved Work… brings the list back.
    case later
    /// Reopens one row's snapshot as an unsaved tab.
    case restore
    /// Asks where to write a copy of one row. Never touches the original.
    case saveCopy

    /// Whether choosing this destroys recovered content.
    var isDestructive: Bool { self == .discard }

    /// Every keyboard equivalent bound to this choice, in installation order:
    /// the first rides the visible button, any further one rides an invisible
    /// proxy, because SwiftUI allows a control only one key equivalent.
    ///
    /// A destructive choice must carry none. Escape and Return are reflexes,
    /// and a reflex must not be able to delete unsaved work, so both — and
    /// ⌘-., macOS's other cancellation gesture, which every Pine alert
    /// honours via `AlertTemplate` — resolve to ``later``, which leaves the
    /// snapshots on disk.
    ///
    /// The guard is what carries the invariant: a case added to this enum
    /// inherits "destructive implies unreachable by keyboard" from the type
    /// rather than from whoever remembers to write `[]` in the right branch.
    /// The `discard` arm below is unreachable while `discard` is the only
    /// destructive case, and is kept solely so the switch stays exhaustive —
    /// a `default:` here would silently hand a *new* case no shortcuts at all.
    /// The two therefore agree by construction and no test can tell them
    /// apart; do not read a green suite as evidence that either one alone is
    /// doing the work.
    var keyboardShortcuts: [KeyboardShortcut] {
        guard !isDestructive else { return [] }
        switch self {
        case .discard:
            return []
        // The row actions are reached by choosing a row, not by a reflex.
        case .restore, .saveCopy:
            return []
        case .later:
            return [
                .defaultAction,
                .cancelAction,
                KeyboardShortcut(".", modifiers: .command),
            ]
        }
    }

    /// Whether this is the sheet's default action — the one Return runs, and
    /// by macOS convention the one that sits last in the button row.
    var isDefaultAction: Bool {
        keyboardShortcuts.contains(.defaultAction)
    }

    /// The snapshot IDs this choice is allowed to unlink, out of the ones the
    /// sheet is showing: its own row's, for Discard, and nothing else.
    ///
    /// The deletion decision belongs here, on the same value that already
    /// carries ``isDestructive``, the button's role and its (empty) shortcut
    /// list, so the resolver can call it unconditionally. An `if` at the call
    /// site is a place where a plausible "the function already handled the
    /// other case" simplification silently restores #1503, and the call site
    /// is in `ContentView+Helpers.swift` — excluded from the coverage gate and
    /// not loaded by any unit test. Here it is enumerable: every case's answer
    /// is asserted in `RecoveryDialogEscapeSafetyTests`.
    ///
    /// Generic in the payload so a test can drive it with the same tuple shape
    /// the sheet uses without constructing `RecoveryEntry` values.
    func snapshotsToDelete<Payload>(
        row: UUID?,
        from entries: [(UUID, Payload)]
    ) -> [UUID] {
        guard isDestructive, let row else { return [] }
        return entries.filter { $0.0 == row }.map(\.0)
    }

    /// Localized button title.
    var title: LocalizedStringKey {
        switch self {
        case .discard: Strings.recoveryDiscard
        case .later: Strings.recoveryLater
        case .restore: Strings.recoveryRestore
        case .saveCopy: Strings.recoverySaveCopy
        }
    }

    /// Stable identifier so UI tests can address the button.
    var accessibilityIdentifier: String {
        switch self {
        case .discard: AccessibilityID.recoveryDiscardButton
        case .later: AccessibilityID.recoveryLaterButton
        case .restore: AccessibilityID.recoveryRestoreButton
        case .saveCopy: AccessibilityID.recoverySaveCopyButton
        }
    }

    /// VoiceOver hint, `nil` for the choices that need none.
    ///
    /// SwiftUI's `ButtonRole.destructive` only recolors the button; it does not
    /// set AppKit's `hasDestructiveAction`, which is the trait `AlertTemplate`
    /// sets by hand so a screen reader announces intent. Until SwiftUI exposes
    /// that trait, this hint is what tells a VoiceOver user that Discard is
    /// not an ordinary button.
    ///
    /// Optional rather than an empty key: `LocalizedStringKey("")` is a real
    /// lookup for a key the catalog does not contain, and the hint it would
    /// attach is an empty announcement rather than no announcement.
    var accessibilityHint: LocalizedStringKey? {
        isDestructive ? Strings.recoveryDiscardHint : nil
    }
}

/// The recovery list's action bar.
///
/// Laid out like the standard macOS "Don't Save / Cancel / Save" alert: the
/// irreversible choice sits apart on the leading edge, the safe choices on
/// the trailing edge with the default action last.
///
/// Split out of ``RecoveryDialogView`` so the row can be measured on its own —
/// four buttons is the widest thing in the sheet in the longer locales.
struct RecoveryDialogFooter: View {
    /// The row the row-scoped choices act on. `nil` leaves only Later
    /// enabled, so a list with nothing selected still has a way out.
    var selection: UUID? = nil
    /// Reports the choice the user made. One callback keyed by the choice, not
    /// four interchangeable `() -> Void` parameters: every button gets its
    /// role, its keystrokes, its title *and* its outcome from the same enum
    /// value, so no edit can leave Escape pointing at a button that reports
    /// something else (#1503).
    let onChoose: (RecoveryDialogAnswer) -> Void

    /// Every choice, placed by what it is rather than by name, so a case added
    /// to ``RecoveryDialogChoice`` appears on screen instead of existing only
    /// in the type. Destructive choices lead, the default action goes last.
    private static let leading = RecoveryDialogChoice.allCases
        .filter(\.isDestructive)
    private static let trailing = RecoveryDialogChoice.allCases
        .filter { !$0.isDestructive && !$0.isDefaultAction }
        + RecoveryDialogChoice.allCases
        .filter { !$0.isDestructive && $0.isDefaultAction }

    /// The buttons in the order they are laid out, derived from the two lists
    /// the body iterates so it cannot describe a row that is not drawn.
    /// Exposed for `RecoveryDialogEscapeSafetyTests`, which is what turns
    /// "every case reaches the screen" into something a compiler-silent
    /// addition to the enum cannot break quietly.
    static let displayOrder = leading + trailing

    /// Whether `choice` answers right now. Restore, Save a Copy… and Discard
    /// act on the selected row and do nothing without one; Later needs no row
    /// and must never be the thing that traps the user in the sheet.
    static func isEnabled(
        _ choice: RecoveryDialogChoice,
        hasSelection: Bool
    ) -> Bool {
        choice.isDefaultAction || hasSelection
    }

    var body: some View {
        HStack(spacing: 12) {
            ForEach(Self.leading, id: \.self) { button(for: $0) }
            Spacer(minLength: 12)
            ForEach(Self.trailing, id: \.self) { button(for: $0) }
        }
    }

    @ViewBuilder
    private func button(for choice: RecoveryDialogChoice) -> some View {
        let control = Button(role: choice.isDestructive ? .destructive : nil) {
            onChoose(RecoveryDialogAnswer(choice: choice, recoveryID: selection))
        } label: {
            Text(choice.title)
        }
        .keyboardShortcut(choice.keyboardShortcuts.first)
        .disabled(!Self.isEnabled(choice, hasSelection: selection != nil))
        .accessibilityIdentifier(choice.accessibilityIdentifier)
        .background {
            shortcutProxies(for: choice)
        }

        if let hint = choice.accessibilityHint {
            control.accessibilityHint(hint)
        } else {
            control
        }
    }

    /// Invisible controls carrying the choice's second and further key
    /// equivalents — the SwiftUI form of `AlertTemplate.installShortcutProxy`,
    /// which does the same for ⌘-. on every `NSAlert` in Pine. They are hidden
    /// from accessibility so VoiceOver and XCUITest still see four buttons,
    /// and they report the same choice as the visible button.
    ///
    /// `.focusable(false)` as well as `.accessibilityHidden(true)`: hiding a
    /// control from the accessibility tree is not documented to take it out of
    /// SwiftUI's focus ring, and with Full Keyboard Access on, a Tab stop at a
    /// 0×0 control draws its focus ring nowhere and strands the traversal.
    private func shortcutProxies(
        for choice: RecoveryDialogChoice
    ) -> some View {
        ForEach(
            Array(choice.keyboardShortcuts.dropFirst().enumerated()),
            id: \.offset
        ) { _, shortcut in
            Button { onChoose(RecoveryDialogAnswer(choice: choice, recoveryID: selection)) } label: { Color.clear }
                .buttonStyle(.plain)
                .keyboardShortcut(shortcut)
        }
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
        .focusable(false)
    }
}

/// One recovered buffer in the list.
///
/// Its own view so the width it asks for can be measured on its own. Inside
/// the `List` it cannot be: a list is a scroll view and absorbs whatever its
/// rows want, so a row that asks for a thousand points is clipped silently
/// rather than showing up in the sheet's fitting size. That is the failure
/// this row is shaped to avoid, and a test measuring the sheet would never see
/// it happen.
struct RecoveryEntryRow: View {
    let entry: RecoveryEntry
    /// The snapshot's recovery ID, which keys the row's accessibility
    /// identifier: two snapshots of one file must not collide.
    var recoveryID: UUID = UUID()
    /// The project an untitled buffer was open in, once its snapshot
    /// directory has been matched against the recent projects. `nil` when
    /// the project cannot be traced.
    var projectPath: String? = nil

    var body: some View {
        HStack {
            Image(systemName: "doc.text")
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                // Generated bundles, downloads and dated exports routinely
                // produce names well past a hundred characters, and a `Text`
                // has no natural width to stop at. Middle truncation keeps
                // both ends — the extension is what identifies the file, and
                // the beginning is what distinguishes two exports of the same
                // thing.
                Text(Self.fileName(from: entry))
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(Self.location(from: entry, projectPath: projectPath))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Self.details(entry)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: RecoveryDialogView.contentWidth, alignment: .leading)
        .accessibilityIdentifier(
            AccessibilityID.recoveryEntry(recoveryID)
        )
        // One element per buffer: the three lines are one fact to VoiceOver,
        // and the list's own selection — not each line — is what it navigates.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            Self.accessibilityLabel(entry, projectPath: projectPath)
        )
    }

    static func fileName(from entry: RecoveryEntry) -> String {
        if entry.originalPath.isEmpty {
            return entry.untitledName ?? Strings.recoveryUntitled
        }
        return (entry.originalPath as NSString).lastPathComponent
    }

    /// The second line: where the file lives. An untitled buffer has no
    /// path, so it names the project it was open in instead — or says it
    /// cannot (#1760).
    static func location(
        from entry: RecoveryEntry,
        projectPath: String?
    ) -> String {
        if entry.originalPath.isEmpty {
            return projectPath ?? Strings.recoveryUntitled
        }
        return (entry.originalPath as NSString).abbreviatingWithTildeInPath
    }

    /// Size, date and time: what tells two snapshots of one file apart.
    private static func details(_ entry: RecoveryEntry) -> some View {
        HStack(spacing: 6) {
            Text(
                ByteCountFormatter.string(
                    fromByteCount: Int64(entry.byteCount),
                    countStyle: .file
                )
            )
            Text(verbatim: "·")
            Text(entry.timestamp, style: .date)
                + Text(verbatim: ", ")
                + Text(entry.timestamp, style: .time)
        }
    }

    static func accessibilityLabel(
        _ entry: RecoveryEntry,
        projectPath: String?
    ) -> String {
        [
            fileName(from: entry),
            location(from: entry, projectPath: projectPath),
            ByteCountFormatter.string(
                fromByteCount: Int64(entry.byteCount),
                countStyle: .file
            ),
            entry.timestamp.formatted(date: .abbreviated, time: .shortened),
        ]
        .formatted(.list(type: .and))
    }
}

/// Lists recovered unsaved buffers and what may become of each.
///
/// Nothing here shows a buffer's content: a snapshot can hold anything that
/// was on someone's screen, and the decision — restore it, keep a copy,
/// discard it, or leave it for later — needs only its name, where it came
/// from, when it was taken and how large it is (#1760).
struct RecoveryDialogView: View {
    let entries: [(UUID, RecoveryEntry)]
    /// Whether these entries are what a restore attempt handed back rather
    /// than what was found at launch.
    ///
    /// The restorer keeps every snapshot it could not install and the sheet
    /// simply comes back holding them. Read without this flag, the second
    /// appearance says "Pine found unsaved changes" — describing a launch
    /// that already happened and saying nothing about the attempt that just
    /// failed on these exact files (#1541).
    var didFailToRestore: Bool = false
    /// Why the last Save a Copy… wrote nothing. Replaces the footnote until
    /// the host clears it, so a refusal is never mistaken for a silent save.
    var notice: String? = nil
    /// Projects an untitled buffer can be traced through its snapshot
    /// directory: this one first, then the recent ones.
    var projects: [URL] = []
    /// This project's snapshot directory name. `nil` leaves every untitled
    /// buffer untraced.
    var recoveryDirectoryName: String? = nil
    /// Reports which choice the user made, and for which row. See
    /// ``RecoveryDialogFooter/onChoose`` for why this is one callback.
    let onChoose: (RecoveryDialogAnswer) -> Void

    @State private var selection: UUID?
    @State private var discardConfirmation: UUID?
    @State private var untitledProjectPath: String?

    /// Width of the text column, and the sheet's resting width once the 24pt
    /// padding on each edge is added back. Shared with ``RecoveryEntryRow``,
    /// which caps itself to the same column.
    static let contentWidth: CGFloat = 448

    /// What the sheet says about why it is on screen.
    ///
    /// Static so the one edge that distinguishes a first offer from a failed
    /// restore can be asserted without hosting the sheet: inlining it as an
    /// `if` in the body would put it in the one place a unit test cannot see.
    static func explanation(didFailToRestore: Bool) -> LocalizedStringKey {
        didFailToRestore
            ? Strings.recoveryPartialFailureMessage
            : Strings.recoveryMessage
    }

    /// The sentence the list shows when Save a Copy… wrote nothing.
    static func saveCopyFailure(_ error: Error, fileName: String) -> String {
        switch error as? RecoveryCopyFailure {
        case .originalFile:
            return Strings.recoverySaveCopyOriginalRefused(fileName)
        case .cannotEncode:
            return Strings.recoverySaveCopyEncodingFailure(fileName)
        case nil:
            return Strings.recoverySaveCopyWriteFailure(
                fileName,
                error.localizedDescription
            )
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.yellow)
                .accessibilityHidden(true)

            Text(Strings.recoveryTitle)
                .font(.headline)
                .multilineTextAlignment(.center)
                .frame(maxWidth: Self.contentWidth)

            Text(Self.explanation(didFailToRestore: didFailToRestore))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: Self.contentWidth)

            List(selection: $selection) {
                ForEach(entries, id: \.0) { id, entry in
                    RecoveryEntryRow(
                        entry: entry,
                        recoveryID: id,
                        projectPath: untitledProjectPath
                    )
                    .tag(id)
                }
            }
            .frame(minHeight: 100, maxHeight: 220)
            .accessibilityIdentifier(AccessibilityID.recoveryEntryList)

            footnote

            RecoveryDialogFooter(selection: selection, onChoose: choose)
        }
        .padding(24)
        // `minWidth`, not `width`: the footer is the widest row here, and in
        // the longer locales it needs most of the text column. A fixed width
        // turns any future growth — a longer translation, a change in AppKit's
        // button metrics — into a truncated button label. Growing the sheet
        // instead is the recoverable failure.
        // The text rows and the list rows are capped above so they cannot
        // drive that growth themselves; without the cap a long message alone
        // would stretch the sheet rather than wrapping.
        .frame(minWidth: 2 * 24 + Self.contentWidth)
        // `children: .contain` so the identifier names this container and does
        // not flatten the buttons inside it into one element.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.recoverySheet)
        .alert(
            Strings.recoveryDiscardConfirmTitle(
                discardTarget.map(RecoveryEntryRow.fileName(from:)) ?? ""
            ),
            isPresented: confirmDiscard,
            presenting: discardConfirmation
        ) { row in
            // Cancel leads so it owns Escape; the destructive button is given
            // no key equivalent, so neither Escape nor Return reaches it —
            // the same roles `AlertTemplate` assigns to Don't Save.
            Button(Strings.dialogCancel, role: .cancel) {}
            Button(Strings.recoveryDiscard, role: .destructive) {
                onChoose(RecoveryDialogAnswer(choice: .discard, recoveryID: row))
            }
            .accessibilityIdentifier(AccessibilityID.recoveryConfirmDiscardButton)
        } message: { _ in
            Text(Strings.recoveryDiscardConfirmMessage)
        }
        .onAppear {
            if selection == nil { selection = entries.first?.0 }
        }
        // The entries themselves are not `Equatable` — a snapshot carries a
        // whole buffer — so the observation rides the IDs, which is also the
        // only part the selection logic reads: when the host hands back a
        // shorter list (a confirmed Discard removed its row, a restore kept
        // only what failed), a selection pointing at a row that is gone
        // would leave every row-scoped button acting on a phantom.
        .onChange(of: entryIDs) { _, newIDs in
            if let selection, newIDs.contains(selection) { return }
            selection = newIDs.first
        }
        .task(id: recoveryDirectoryName) {
            guard let recoveryDirectoryName else { return }
            let candidates = projects
            // Hashing resolves symlinks on disk, so it stays off the main actor.
            untitledProjectPath = await runOnBackground {
                RecoveryManager.project(
                    matchingRecoveryDirectoryName: recoveryDirectoryName,
                    among: candidates
                )?.path
            }
        }
    }

    @ViewBuilder
    private var footnote: some View {
        if let notice {
            Text(notice)
                .font(.caption)
                .multilineTextAlignment(.center)
                .frame(maxWidth: Self.contentWidth)
        } else {
            // Later is safe without a deadline (#1760): nothing is collected
            // while the user is away, and the menu brings the list back.
            Text(Strings.recoveryKeepNotice)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: Self.contentWidth)
        }
    }

    private var discardTarget: RecoveryEntry? {
        guard let discardConfirmation else { return nil }
        return entries.first { $0.0 == discardConfirmation }?.1
    }

    /// The list's row IDs, the `Equatable` shape `.onChange` needs.
    private var entryIDs: [UUID] { entries.map(\.0) }

    private var confirmDiscard: Binding<Bool> {
        Binding(
            get: { discardConfirmation != nil },
            set: { if !$0 { discardConfirmation = nil } }
        )
    }

    /// Reports `answer` — except for the one choice that destroys work. That
    /// one is asked again first, and leaves this view only when the user
    /// repeats it.
    private func choose(_ answer: RecoveryDialogAnswer) {
        switch answer.choice {
        case .discard:
            discardConfirmation = answer.recoveryID
        case .restore, .saveCopy, .later:
            onChoose(answer)
        }
    }
}
