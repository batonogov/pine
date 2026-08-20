//
//  AgentInboxView.swift
//  Pine
//
//  Application-level cross-project task inbox (#1305).
//

import AppKit
import SwiftUI

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
    @State private var navigationMessage: LocalizedStringKey?
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

            if let navigationMessage {
                HStack {
                    Spacer()
                    Label(navigationMessage, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
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
        .onChange(of: snapshot.rows.map(\.id)) { _, _ in
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
        if !snapshot.rows.contains(where: {
            $0.id == recoveryActionsTaskID && $0.canRecover
        }) {
            recoveryActionsTaskID = nil
        }
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
        onAccessibilityAnnouncement(actionTitle(primaryAction))
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
        navigationMessage = nil
        Task { @MainActor in
            let result = await registry.recoverAgentTaskFromInbox(
                taskID,
                action: action,
                openProjectWindow: openProject
            )
            switch result {
            case .openedNewSession:
                onDismiss()
            case .resumed:
                onDismiss()
            case .taskMissing, .projectUnavailable, .unavailable,
                    .changedWhilePreparing, .launchRejected:
                navigationMessage = Strings.agentInboxRecoveryUnavailable
            }
        }
    }

    private func navigate(to taskID: UUID) {
        navigationMessage = nil
        Task { @MainActor in
            let result = await registry.navigateToAgentTaskFromInbox(
                taskID,
                openProjectWindow: openProject
            )
            switch result {
            case .focused:
                onDismiss()
            case .taskMissing, .projectUnavailable, .routeStale:
                navigationMessage = Strings.agentInboxRouteUnavailable
            }
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
