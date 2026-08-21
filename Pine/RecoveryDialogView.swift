//
//  RecoveryDialogView.swift
//  Pine
//

import SwiftUI

/// One choice offered by the crash-recovery sheet, paired with the keyboard
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
/// cancellation target, cancellation reachable by both Escape and ⌘-., and the
/// destructive button reachable by neither. Change one of the two and check
/// the other — `AlertTemplate.buttonRoles` carries the matching note.
enum RecoveryDialogChoice: String, CaseIterable, Sendable {
    /// Deletes the recovery snapshots. Irreversible.
    case discard
    /// Closes the sheet and leaves the snapshots on disk for the next launch.
    case later
    /// Restores every snapshot into the active editor pane.
    case recoverAll

    /// Whether choosing this destroys recovered content.
    var isDestructive: Bool { self == .discard }

    /// Every keyboard equivalent bound to this choice, in installation order:
    /// the first rides the visible button, any further one rides an invisible
    /// proxy, because SwiftUI allows a control only one key equivalent.
    ///
    /// A destructive choice must carry none. Escape and Return are reflexes,
    /// and a reflex must not be able to delete unsaved work, so Escape (and
    /// ⌘-., macOS's other cancellation gesture, which every Pine alert honours
    /// via `AlertTemplate`) resolves to ``later`` — which leaves the snapshots
    /// on disk and brings the offer back on the next launch.
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
        case .later:
            return [.cancelAction, KeyboardShortcut(".", modifiers: .command)]
        case .recoverAll:
            return [.defaultAction]
        }
    }

    /// Whether this is the sheet's default action — the one Return runs, and
    /// by macOS convention the one that sits last in the button row.
    var isDefaultAction: Bool {
        keyboardShortcuts.contains(.defaultAction)
    }

    /// The snapshot IDs this choice is allowed to unlink, out of the ones the
    /// sheet is showing.
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
        from entries: [(UUID, Payload)]
    ) -> [UUID] {
        isDestructive ? entries.map { $0.0 } : []
    }

    /// Localized button title.
    var title: LocalizedStringKey {
        switch self {
        case .discard: Strings.recoveryDiscard
        case .later: Strings.recoveryLater
        case .recoverAll: Strings.recoveryRecoverAll
        }
    }

    /// Stable identifier so UI tests can address the button.
    var accessibilityIdentifier: String {
        switch self {
        case .discard: AccessibilityID.recoveryDiscardButton
        case .later: AccessibilityID.recoveryLaterButton
        case .recoverAll: AccessibilityID.recoveryRecoverAllButton
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

/// The recovery sheet's footer.
///
/// Laid out like the standard macOS "Don't Save / Cancel / Save" alert: the
/// irreversible choice sits apart on the leading edge, the two safe choices on
/// the trailing edge with the default action last.
///
/// Split out of ``RecoveryDialogView`` so the row can be measured on its own —
/// three buttons is the widest thing in the sheet in the longer locales.
struct RecoveryDialogFooter: View {
    /// Reports the choice the user made. One callback keyed by the choice, not
    /// three interchangeable `() -> Void` parameters: every button gets its
    /// role, its keystrokes, its title *and* its outcome from the same enum
    /// value, so no edit can leave Escape pointing at a button that reports
    /// something else (#1503).
    let onChoose: (RecoveryDialogChoice) -> Void

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
            onChoose(choice)
        } label: {
            Text(choice.title)
        }
        .keyboardShortcut(choice.keyboardShortcuts.first)
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
    /// from accessibility so VoiceOver and XCUITest still see three buttons,
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
            Button { onChoose(choice) } label: { Color.clear }
                .buttonStyle(.plain)
                .keyboardShortcut(shortcut)
        }
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
        .focusable(false)
    }
}

/// One recovered buffer in the sheet's list.
///
/// Its own view so the width it asks for can be measured on its own. Inside
/// the `List` it cannot be: a list is a scroll view and absorbs whatever its
/// rows want, so a row that asks for a thousand points is clipped silently
/// rather than showing up in the sheet's fitting size. That is the failure
/// this row is shaped to avoid, and a test measuring the sheet would never see
/// it happen.
struct RecoveryEntryRow: View {
    let entry: RecoveryEntry

    var body: some View {
        HStack {
            Image(systemName: "doc.text")
            VStack(alignment: .leading) {
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
                Text(entry.timestamp, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: RecoveryDialogView.contentWidth, alignment: .leading)
    }

    static func fileName(from entry: RecoveryEntry) -> String {
        if entry.originalPath.isEmpty {
            return entry.untitledName ?? Strings.recoveryUntitled
        }
        return (entry.originalPath as NSString).lastPathComponent
    }
}

/// Shows a dialog listing recovered unsaved files after a crash.
struct RecoveryDialogView: View {
    let entries: [(UUID, RecoveryEntry)]
    /// Reports which of the three choices the user made. See
    /// ``RecoveryDialogFooter/onChoose`` for why this is one callback.
    let onChoose: (RecoveryDialogChoice) -> Void

    /// Width of the text column, and the sheet's resting width once the 24pt
    /// padding on each edge is added back. Shared with ``RecoveryEntryRow``,
    /// which caps itself to the same column.
    static let contentWidth: CGFloat = 352

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.yellow)

            Text(Strings.recoveryTitle)
                .font(.headline)
                .multilineTextAlignment(.center)
                .frame(maxWidth: Self.contentWidth)

            Text(Strings.recoveryMessage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: Self.contentWidth)

            List {
                ForEach(entries, id: \.0) { _, entry in
                    RecoveryEntryRow(entry: entry)
                }
            }
            .frame(minHeight: 100, maxHeight: 200)

            // Closing this sheet without choosing is safe but not unlimited:
            // the launch-time sweep collects undecided snapshots eventually.
            // Saying so is the honest half of making Escape mean "later"
            // instead of "delete" (#1503). The wording names the choice it
            // describes and the moment the clock starts, because it sits
            // directly above a row whose leading button is Discard: read as a
            // bare "nothing here is final for a week" it would make the one
            // irreversible click on this sheet feel cheap, and Discard does
            // not honour the window at all.
            Text(Strings.recoveryRetentionNotice(
                days: RecoveryManager.staleEntryRetentionDays
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: Self.contentWidth)

            RecoveryDialogFooter(onChoose: onChoose)
        }
        .padding(24)
        // `minWidth`, not `width`: the footer is the widest row here, and in
        // German it already asks for 349 of the 352pt a fixed 400pt sheet can
        // give it. A fixed width turns any future growth — a longer
        // translation, a change in AppKit's button metrics — into a truncated
        // button label. Growing the sheet instead is the recoverable failure.
        // The two text rows and the list rows are capped above so they cannot
        // drive that growth themselves; without the cap the German message
        // alone would stretch the sheet to 634pt rather than wrapping.
        .frame(minWidth: 2 * 24 + Self.contentWidth)
        // `children: .contain` so the identifier names this container and does
        // not flatten the buttons inside it into one element.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.recoverySheet)
    }
}
