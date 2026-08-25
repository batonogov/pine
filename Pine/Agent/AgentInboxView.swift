//
//  AgentInboxView.swift
//  Pine
//
//  Application-level cross-project task inbox (#1305).
//

import AppKit
import SwiftUI

/// The caption the Inbox shows after a failed action, held in a reference the
/// view's `@State` owns.
///
/// A box rather than a plain `@State` value because the last step of an action
/// — which of the view's own hooks each effect actually reaches — is otherwise
/// unobservable: SwiftUI discards a `@State` write on a view that is not
/// installed, so nothing could tell `{ actionStatus.message = $0 }` from
/// `{ _ in }`. Writing through the box keeps that wiring assertable while
/// `@Observable` still drives the redraw.
@MainActor
@Observable
final class AgentInboxActionStatusStore {
    var message: LocalizedStringKey?
    /// The next step that goes with ``message``. Held beside it rather than
    /// folded into one string so the caption can render the cause and the
    /// remedy with different emphasis, and so a test can see that a failure
    /// really produced both (#1541).
    var detail: LocalizedStringKey?

    init(
        message: LocalizedStringKey? = nil,
        detail: LocalizedStringKey? = nil
    ) {
        self.message = message
        self.detail = detail
    }
}

@MainActor
struct AgentInboxView: View {
    let registry: ProjectRegistry
    let onAccessibilityAnnouncement: (String) -> Void
    let onDismiss: () -> Void
    let explicitOpenProjectWindow: ((URL) -> Void)?

    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.locale) private var locale
    @State private var selectedTaskID: UUID?
    @State private var recoveryActionsTaskID: UUID?
    /// Not `private`: this is the Inbox's own status storage, and the only
    /// way a test can see that a failed action really captioned the popover.
    @State var actionStatus = AgentInboxActionStatusStore()
    @FocusState private var hasKeyboardFocus: Bool

    private var snapshot: AgentInboxSnapshot {
        AgentInboxSnapshot(tasks: registry.agentTasks.tasks)
    }

    init(
        registry: ProjectRegistry,
        onDismiss: @escaping () -> Void = {},
        openProjectWindow: ((URL) -> Void)? = nil,
        onAccessibilityAnnouncement: @escaping (String) -> Void = { message in
            NSAccessibility.post(
                element: NSApp.keyWindow
                    ?? NSApp.mainWindow
                    ?? NSApplication.shared,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: message,
                    .priority: NSAccessibilityPriorityLevel.medium.rawValue,
                ]
            )
        }
    ) {
        self.registry = registry
        self.onDismiss = onDismiss
        self.explicitOpenProjectWindow = openProjectWindow
        self.onAccessibilityAnnouncement = onAccessibilityAnnouncement
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Label(
                    Strings.agentInboxTitle,
                    systemImage: MenuIcons.agentInbox
                )
                .font(.headline)

                Spacer()

                PineHelpButton(
                    anchor: PineHelp.Anchor.agentInbox,
                    book: PineHelp.bookName,
                    accessibilityIdentifier:
                        AccessibilityID.agentInboxHelpButton
                )
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            if let statusMessage = actionStatus.message {
                HStack(alignment: .firstTextBaseline) {
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: 2) {
                        Label(
                            statusMessage,
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                        // The next step is the half that tells the user what
                        // to do; without it the caption is the dead end
                        // #1541 was filed about.
                        if let detail = actionStatus.detail {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.trailing)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier(
                        AccessibilityID.agentInboxNavigationStatus
                    )
                }
                .padding()

                Divider()
            }

            if snapshot.isEmpty {
                ContentUnavailableView {
                    Label(Strings.agentInboxEmpty, systemImage: MenuIcons.agentInbox)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(AccessibilityID.agentInboxEmpty)
            } else {
                VStack(spacing: 0) {
                    inboxContents
                    if let row = presentedRecoveryRow {
                        Divider()
                        recoveryActions(for: row)
                    }
                }
            }
        }
        .frame(width: 520, height: 540)
        .focusable()
        .focused($hasKeyboardFocus)
        .focusEffectDisabled()
        .onAppear {
            synchronizeSelection()
            hasKeyboardFocus = true
        }
        .onChange(
            of: snapshot.rows.map(AgentInboxRecoveryState.init(row:))
        ) { _, _ in
            synchronizeSelection()
        }
        .onKeyPress(.upArrow) {
            guard hasKeyboardFocus else { return .ignored }
            moveSelection(by: -1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            guard hasKeyboardFocus else { return .ignored }
            moveSelection(by: 1)
            return .handled
        }
        .onKeyPress(.return) {
            // Let a focused action button own Return. The root-level
            // two-step activation policy applies only while the Inbox list
            // itself is the keyboard focus target.
            guard hasKeyboardFocus else { return .ignored }
            activateSelection()
            return .handled
        }
        .onKeyPress(.escape) {
            guard recoveryActionsTaskID != nil else { return .ignored }
            recoveryActionsTaskID = nil
            hasKeyboardFocus = true
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.agentInbox)
    }

    private var inboxContents: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(snapshot.sections) { section in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(sectionTitle(section.id))
                                .font(.headline)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 12)

                            ForEach(section.rows) { row in
                                inboxRow(row)
                                    .id(row.id)
                            }
                        }
                    }
                }
                .padding(.vertical, 12)
            }
            .onChange(of: selectedTaskID) { _, taskID in
                guard let taskID else { return }
                if reduceMotion {
                    proxy.scrollTo(taskID)
                } else {
                    withAnimation(PineAnimation.quick) {
                        proxy.scrollTo(taskID)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.agentInboxList)
    }

    private func inboxRow(_ row: AgentInboxRow) -> some View {
        Button {
            selectedTaskID = row.id
            if row.canNavigateToLiveRun {
                recoveryActionsTaskID = nil
                navigate(to: row.id)
            } else if row.canRecover {
                presentRecoveryActions(for: row)
            } else {
                recoveryActionsTaskID = nil
            }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: glyph(for: row))
                        .foregroundStyle(color(for: row))
                        .frame(width: 20, height: 20)
                    if row.isUnread {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 7, height: 7)
                            .offset(x: 3, y: -2)
                    }
                }

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        primaryDetails(row)
                        Spacer(minLength: 8)
                        timingDetails(row)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        primaryDetails(row)
                        timingDetails(row)
                    }
                }
            }
            .contentShape(Rectangle())
            .padding(10)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        selectedTaskID == row.id
                            ? Color.accentColor.opacity(0.16)
                            : Color.secondary.opacity(0.06)
                    )
            }
            .padding(.horizontal, 8)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .contextMenu {
            Button(row.isUnread
                   ? Strings.agentInboxMarkRead
                   : Strings.agentInboxMarkUnread) {
                toggleReviewed(row)
            }
            if row.lifecycle != .active, row.liveness != .live {
                if row.canRecover {
                    Divider()
                    if registry.canOfferAgentTaskVendorResume(row.id) {
                        Button(Strings.agentInboxResumeSession) {
                            recover(row.id, action: .resumeVendorSession)
                        }
                    }
                    Button(Strings.agentInboxNewSession) {
                        recover(row.id, action: .startNewSession)
                    }
                    if let objective = registry.agentTasks.task(
                        for: row.id
                    )?.objective {
                        Button(Strings.agentInboxCopyObjective) {
                            copyObjective(objective)
                        }
                    }
                }
                Divider()
                Button(Strings.agentInboxDismiss, role: .destructive) {
                    dismiss(row.id)
                }
            }
        }
        .accessibilityIdentifier(AccessibilityID.agentInboxRow(row.id))
        .accessibilityLabel(
            Text(verbatim: Self.accessibilityLabel(for: row, locale: locale))
        )
        .accessibilityAddTraits(selectedTaskID == row.id ? .isSelected : [])
        .accessibilityHint(
            accessibilityHint(for: row)
        )
    }

    private var presentedRecoveryRow: AgentInboxRow? {
        guard let recoveryActionsTaskID else { return nil }
        return snapshot.rows.first {
            $0.id == recoveryActionsTaskID && $0.canRecover
        }
    }

    private func recoveryActions(for row: AgentInboxRow) -> some View {
        let canResume = registry.canOfferAgentTaskVendorResume(row.id)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label(
                    Strings.agentInboxRecoveryActions,
                    systemImage: "arrow.clockwise"
                )
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

                Spacer()

                Button {
                    toggleReviewed(row)
                } label: {
                    Image(systemName: row.isUnread
                          ? "envelope.open"
                          : "envelope.badge")
                }
                .help(Text(row.isUnread
                           ? Strings.agentInboxMarkRead
                           : Strings.agentInboxMarkUnread))
                .accessibilityLabel(row.isUnread
                                    ? Strings.agentInboxMarkRead
                                    : Strings.agentInboxMarkUnread)
                .accessibilityIdentifier(
                    AccessibilityID.agentInboxMarkReviewed
                )

                if let objective = registry.agentTasks.task(
                    for: row.id
                )?.objective {
                    Button {
                        copyObjective(objective)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .help(Text(Strings.agentInboxCopyObjective))
                    .accessibilityLabel(Strings.agentInboxCopyObjective)
                    .accessibilityIdentifier(
                        AccessibilityID.agentInboxCopyObjective
                    )
                }

                Button(role: .destructive) {
                    dismiss(row.id)
                } label: {
                    Image(systemName: "trash")
                }
                .help(Text(Strings.agentInboxDismiss))
                .accessibilityLabel(Strings.agentInboxDismiss)
                .accessibilityIdentifier(
                    AccessibilityID.agentInboxDismissTask
                )
            }
            .buttonStyle(.bordered)

            HStack(spacing: 8) {
                Spacer()

                if canResume {
                    newSessionButton(for: row)
                        .buttonStyle(.bordered)
                } else {
                    newSessionButton(for: row)
                        .buttonStyle(.borderedProminent)
                }

                if canResume {
                    Button(Strings.agentInboxResumeSession) {
                        recover(row.id, action: .resumeVendorSession)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier(
                        AccessibilityID.agentInboxResumeSession
                    )
                }
            }
        }
        .padding(10)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Strings.agentInboxRecoveryActions)
        .accessibilityIdentifier(AccessibilityID.agentInboxRecoveryActions)
    }

    private func newSessionButton(for row: AgentInboxRow) -> some View {
        Button(Strings.agentInboxNewSession) {
            recover(row.id, action: .startNewSession)
        }
        .accessibilityIdentifier(AccessibilityID.agentInboxNewSession)
    }

    private func primaryDetails(_ row: AgentInboxRow) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: row.title ?? row.agentName)
                .font(.body.weight(row.isUnread ? .semibold : .regular))
                .lineLimit(1)
            HStack(spacing: 5) {
                Text(verbatim: row.agentName)
                Text(verbatim: "•")
                Text(verbatim: statusText(for: row))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            HStack(spacing: 5) {
                Image(systemName: "terminal")
                Text(verbatim: row.terminalLabel)
                if row.surface.isProjectBacked {
                    Image(systemName: "folder")
                    Text(verbatim: row.projectName)
                    if let worktreeName = row.worktreeName {
                        Image(systemName: "arrow.triangle.branch")
                        Text(verbatim: worktreeName)
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }

    private func timingDetails(_ row: AgentInboxRow) -> some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text(row.startedAt, style: .timer)
                .monospacedDigit()
            HStack(spacing: 4) {
                Text(Strings.agentInboxLastVerified)
                Text(row.lastVerifiedActivityAt, style: .relative)
            }
            .foregroundStyle(.secondary)
        }
        .font(.caption)
    }

    private func synchronizeSelection() {
        selectedTaskID = AgentKeyboardSelection.normalizeID(
            selectedTaskID,
            ids: snapshot.rows.map(\.id)
        )
        recoveryActionsTaskID = AgentInboxActivation
            .normalizedPresentedTaskID(
                recoveryActionsTaskID,
                states: snapshot.rows.map(
                    AgentInboxRecoveryState.init(row:)
                )
            )
    }

    private func moveSelection(by delta: Int) {
        let previousID = selectedTaskID
        let nextID = AgentKeyboardSelection.moveID(
            from: selectedTaskID,
            by: delta,
            ids: snapshot.rows.map(\.id)
        )
        guard nextID != previousID else { return }
        selectedTaskID = nextID
        recoveryActionsTaskID = nil
        announceSelectionChange(from: previousID, to: nextID)
    }

    private func announceSelectionChange(
        from previousID: UUID?,
        to nextID: UUID?
    ) {
        guard let announcement = Self.accessibilityAnnouncement(
            from: previousID,
            to: nextID,
            rows: snapshot.rows,
            locale: locale
        ) else { return }
        onAccessibilityAnnouncement(announcement)
    }

    private func activateSelection() {
        guard let selectedTaskID,
              let row = snapshot.rows.first(where: { $0.id == selectedTaskID })
        else { return }
        let canResume = registry.canOfferAgentTaskVendorResume(selectedTaskID)
        switch AgentInboxActivation.resolve(
            row: row,
            recoveryActionsArePresented:
                recoveryActionsTaskID == selectedTaskID,
            canResumeVendorSession: canResume
        ) {
        case .navigate:
            navigate(to: selectedTaskID)
        case .presentRecoveryActions:
            presentRecoveryActions(for: row)
        case .recover(let action):
            recover(selectedTaskID, action: action)
        }
    }

    private func presentRecoveryActions(for row: AgentInboxRow) {
        guard row.canRecover else { return }
        recoveryActionsTaskID = row.id
        let primaryAction = AgentInboxActivation.primaryRecoveryAction(
            canResumeVendorSession:
                registry.canOfferAgentTaskVendorResume(row.id)
        )
        onAccessibilityAnnouncement(
            Strings.agentInboxRecoveryActionsShown(
                defaultAction: actionTitle(primaryAction),
                locale: locale
            )
        )
    }

    private func toggleReviewed(_ row: AgentInboxRow) {
        _ = registry.agentTasks.setReviewed(row.isUnread, taskID: row.id)
    }

    private func copyObjective(_ objective: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(objective, forType: .string)
    }

    private func dismiss(_ taskID: UUID) {
        recoveryActionsTaskID = nil
        _ = registry.agentTasks.dismissTask(taskID)
    }

    private func accessibilityHint(
        for row: AgentInboxRow
    ) -> LocalizedStringKey {
        if row.canNavigateToLiveRun {
            return Strings.agentInboxOpen
        }
        if row.canRecover {
            guard recoveryActionsTaskID == row.id else {
                return Strings.agentInboxShowRecoveryActions
            }
            return actionTitleKey(
                AgentInboxActivation.primaryRecoveryAction(
                    canResumeVendorSession:
                        registry.canOfferAgentTaskVendorResume(row.id)
                )
            )
        }
        return ""
    }

    private func actionTitleKey(
        _ action: AgentTaskRecoveryAction
    ) -> LocalizedStringKey {
        switch action {
        case .resumeVendorSession: Strings.agentInboxResumeSession
        case .startNewSession: Strings.agentInboxNewSession
        }
    }

    private func actionTitle(_ action: AgentTaskRecoveryAction) -> String {
        switch action {
        case .resumeVendorSession:
            String(
                localized: "agentInbox.resumeSession",
                bundle: .main,
                locale: locale
            )
        case .startNewSession:
            String(
                localized: "agentInbox.newSession",
                bundle: .main,
                locale: locale
            )
        }
    }

    private func recover(
        _ taskID: UUID,
        action: AgentTaskRecoveryAction
    ) {
        actionStatus.message = nil
        actionStatus.detail = nil
        Task { @MainActor in
            let result = await registry.recoverAgentTaskFromInbox(
                taskID,
                action: action,
                openProjectWindow: openProject
            )
            apply(AgentInboxActionOutcome.forRecovery(result))
        }
    }

    /// Everything one action verdict changes, as data: whether the popover
    /// closes, the caption it shows, and what VoiceOver says.
    ///
    /// Split out because every part of it is silently droppable. Swapping the
    /// two branches, closing on a failure, or deleting the announcement all
    /// compile and render a popover that looks correct in a screenshot.
    struct ActionEffects: Equatable {
        let dismisses: Bool
        let statusMessage: LocalizedStringKey?
        /// The next step shown under ``statusMessage``. Separate from it so
        /// dropping the remedy — the thing #1541 is about — changes this
        /// value rather than hiding inside one concatenated string.
        let statusDetail: LocalizedStringKey?
        let announcement: String?
    }

    /// Maps one action's verdict onto what the popover does about it.
    ///
    /// A failure has to be spoken, not just shown: focus stays inside the
    /// popover and the only visible change is a caption at its bottom edge, so
    /// a VoiceOver user who hit a dead route would otherwise get no feedback
    /// at all.
    static func effects(
        of outcome: AgentInboxActionOutcome,
        locale: Locale = .current
    ) -> ActionEffects {
        switch outcome {
        case .dismiss:
            ActionEffects(
                dismisses: true,
                statusMessage: nil,
                statusDetail: nil,
                announcement: nil
            )
        case .keepVisible(let status):
            ActionEffects(
                dismisses: false,
                statusMessage: statusMessage(status),
                statusDetail: statusDetail(status),
                announcement: statusAnnouncement(status, locale: locale)
            )
        }
    }

    /// Runs one verdict's effects against the hooks that own them. Static and
    /// closure-driven so the order and the conditions — not only the mapping
    /// they read — can be exercised without a window server.
    static func applyEffects(
        _ effects: ActionEffects,
        setStatusMessage: (LocalizedStringKey, LocalizedStringKey?) -> Void,
        announce: (String) -> Void,
        dismiss: () -> Void
    ) {
        if let message = effects.statusMessage {
            setStatusMessage(message, effects.statusDetail)
        }
        if let announcement = effects.announcement {
            announce(announcement)
        }
        if effects.dismisses {
            dismiss()
        }
    }

    /// Not `private`: this is the last step nothing else observes — which of
    /// this view's own hooks each effect reaches. Wiring the announcement to
    /// a no-op, or the caption to nothing, keeps every mapping above green
    /// while removing the feedback the user actually gets.
    func apply(_ outcome: AgentInboxActionOutcome) {
        Self.applyEffects(
            Self.effects(of: outcome, locale: locale),
            setStatusMessage: { message, detail in
                actionStatus.message = message
                actionStatus.detail = detail
            },
            announce: onAccessibilityAnnouncement,
            dismiss: onDismiss
        )
    }

    /// Not `private`: the enum-to-string edge is the whole user-visible
    /// difference between the failures, and swapping two keys compiles.
    /// Tests assert every mapping directly.
    static func statusMessage(
        _ status: AgentInboxActionStatus
    ) -> LocalizedStringKey {
        switch status {
        case .routeUnavailable:
            Strings.agentInboxRouteUnavailable
        case .recoveryUnavailable(let failure):
            Strings.agentRecoveryCause(failure)
        }
    }

    /// What to do about ``statusMessage(_:)``. A failure with no way forward
    /// is a dead end, so every status has one (#1541).
    static func statusDetail(
        _ status: AgentInboxActionStatus
    ) -> LocalizedStringKey {
        switch status {
        case .routeUnavailable:
            Strings.agentInboxRouteUnavailableNextStep
        case .recoveryUnavailable(let failure):
            Strings.agentRecoveryNextStep(failure)
        }
    }

    /// The spoken form of ``statusMessage(_:)`` and ``statusDetail(_:)``.
    /// Kept beside them so the three can only drift together, and carrying
    /// both halves because focus never leaves the popover: what VoiceOver
    /// says here is the entire feedback a screen-reader user gets.
    static func statusAnnouncement(
        _ status: AgentInboxActionStatus,
        locale: Locale = .current
    ) -> String {
        switch status {
        case .routeUnavailable:
            "\(Strings.agentInboxRouteUnavailableText(locale: locale)). "
                + Strings.agentInboxRouteUnavailableNextStepText(
                    locale: locale
                )
        case .recoveryUnavailable(let failure):
            "\(Strings.agentRecoveryCauseText(failure, locale: locale)). "
                + Strings.agentRecoveryNextStepText(failure, locale: locale)
        }
    }

    private func navigate(to taskID: UUID) {
        actionStatus.message = nil
        actionStatus.detail = nil
        Task { @MainActor in
            let result = await registry.navigateToAgentTaskFromInbox(
                taskID,
                openProjectWindow: openProject
            )
            apply(AgentInboxActionOutcome.forNavigation(result))
        }
    }

    private func sectionTitle(_ id: AgentInboxSectionID) -> LocalizedStringKey {
        switch id {
        case .needsAttention: Strings.agentInboxNeedsAttention
        case .failed: Strings.agentInboxFailed
        case .completedUnread: Strings.agentInboxCompletedUnread
        case .working: Strings.agentInboxWorking
        case .history: Strings.agentInboxHistory
        }
    }

    private func openProject(_ url: URL) {
        if let explicitOpenProjectWindow {
            explicitOpenProjectWindow(url)
        } else {
            openWindow(value: url)
        }
    }

    private func statusText(for row: AgentInboxRow) -> String {
        Self.statusText(for: row, locale: locale)
    }

    private func glyph(for row: AgentInboxRow) -> String {
        switch row.section {
        case .needsAttention: "exclamationmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .completedUnread: "checkmark.circle.fill"
        case .working: "ellipsis.circle.fill"
        case .history: "clock"
        }
    }

    private func color(for row: AgentInboxRow) -> Color {
        switch row.section {
        case .needsAttention: .orange
        case .failed: .red
        case .completedUnread: .green
        case .working: .accentColor
        case .history: .secondary
        }
    }

    static func accessibilityLabel(
        for row: AgentInboxRow,
        locale: Locale = .current
    ) -> String {
        var fields: [String] = []
        if let title = row.title {
            fields.append(title)
        }
        if row.isUnread {
            fields.append(Strings.agentInboxUnread(locale: locale))
        }
        fields.append(row.agentName)
        fields.append(statusText(for: row, locale: locale))
        fields.append(row.terminalLabel)
        if row.surface.isProjectBacked {
            fields.append(row.projectName)
            if let worktreeName = row.worktreeName {
                fields.append(worktreeName)
            }
        }
        return fields.joined(separator: ", ")
    }

    /// Returns the spoken row for one explicit selection transition. The
    /// custom list keeps keyboard focus on its container, so changing the
    /// visual highlight does not move VoiceOver focus by itself (#1371).
    static func accessibilityAnnouncement(
        from previousID: UUID?,
        to nextID: UUID?,
        rows: [AgentInboxRow],
        locale: Locale = .current
    ) -> String? {
        guard previousID != nextID,
              let nextID,
              let row = rows.first(where: { $0.id == nextID }) else {
            return nil
        }
        return accessibilityLabel(for: row, locale: locale)
    }

    private static func statusText(
        for row: AgentInboxRow,
        locale: Locale
    ) -> String {
        if let liveness = row.liveness, liveness != .live {
            switch liveness {
            case .live: break
            case .stale: return Strings.agentLivenessStale(locale: locale)
            case .terminated:
                return Strings.agentLivenessTerminated(locale: locale)
            }
        }
        return switch row.state {
        case .idle: Strings.agentStateIdle(locale: locale)
        case .thinking: Strings.agentStateThinking(locale: locale)
        case .executing: Strings.agentStateExecuting(locale: locale)
        case .waitingInput: Strings.agentStateWaitingInput(locale: locale)
        case .done: Strings.agentStateDone(locale: locale)
        case nil: row.agentName
        }
    }
}
