//
//  AgentInboxView.swift
//  Pine
//
//  Application-level cross-project task inbox (#1305).
//

import SwiftUI

@MainActor
struct AgentInboxView: View {
    let registry: ProjectRegistry

    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedTaskID: UUID?
    @State private var navigationMessage: LocalizedStringKey?
    @FocusState private var hasKeyboardFocus: Bool

    private var snapshot: AgentInboxSnapshot {
        AgentInboxSnapshot(tasks: registry.agentTasks.tasks)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label(Strings.agentInboxTitle, systemImage: MenuIcons.agentInbox)
                    .font(.title2.weight(.semibold))
                Spacer()
                if let navigationMessage {
                    Label(navigationMessage, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier(
                            AccessibilityID.agentInboxNavigationStatus
                        )
                }
            }
            .padding()

            Divider()

            if snapshot.isEmpty {
                ContentUnavailableView {
                    Label(Strings.agentInboxEmpty, systemImage: MenuIcons.agentInbox)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier(AccessibilityID.agentInboxEmpty)
            } else {
                inboxContents
            }
        }
        .frame(minWidth: 420, idealWidth: 720, minHeight: 360, idealHeight: 560)
        .focusable()
        .focused($hasKeyboardFocus)
        .onAppear {
            synchronizeSelection()
            hasKeyboardFocus = true
        }
        .onChange(of: snapshot.rows.map(\.id)) { _, _ in
            synchronizeSelection()
        }
        .onKeyPress(.upArrow) {
            moveSelection(by: -1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            moveSelection(by: 1)
            return .handled
        }
        .onKeyPress(.return) {
            activateSelection()
            return .handled
        }
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
        .accessibilityIdentifier(AccessibilityID.agentInboxList)
    }

    private func inboxRow(_ row: AgentInboxRow) -> some View {
        Button {
            selectedTaskID = row.id
            if row.canNavigateToLiveRun {
                navigate(to: row.id)
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
                _ = registry.agentTasks.setReviewed(
                    row.isUnread,
                    taskID: row.id
                )
            }
            if row.lifecycle != .active, row.liveness != .live {
                if row.canRecover {
                    Divider()
                    Button(Strings.agentInboxResumeSession) {
                        recover(row.id, action: .resumeVendorSession)
                    }
                    Button(Strings.agentInboxNewSession) {
                        recover(row.id, action: .startNewSession)
                    }
                    if let objective = registry.agentTasks.task(
                        for: row.id
                    )?.objective {
                        Button(Strings.agentInboxCopyObjective) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(
                                objective,
                                forType: .string
                            )
                        }
                    }
                }
                Divider()
                Button(Strings.agentInboxDismiss, role: .destructive) {
                    _ = registry.agentTasks.dismissTask(row.id)
                }
            }
        }
        .accessibilityIdentifier(AccessibilityID.agentInboxRow(row.id))
        .accessibilityLabel(
            Text(verbatim: accessibilityLabel(for: row))
        )
        .accessibilityAddTraits(selectedTaskID == row.id ? .isSelected : [])
        .accessibilityHint(
            row.canNavigateToLiveRun ? Strings.agentInboxOpen : ""
        )
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
                Image(systemName: "folder")
                Text(verbatim: row.projectName)
                if let worktreeName = row.worktreeName {
                    Image(systemName: "arrow.triangle.branch")
                    Text(verbatim: worktreeName)
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
    }

    private func moveSelection(by delta: Int) {
        selectedTaskID = AgentKeyboardSelection.moveID(
            from: selectedTaskID,
            by: delta,
            ids: snapshot.rows.map(\.id)
        )
    }

    private func activateSelection() {
        guard let selectedTaskID else { return }
        if snapshot.rows.first(where: { $0.id == selectedTaskID })?
            .canRecover == true {
            recover(selectedTaskID, action: .startNewSession)
        } else {
            navigate(to: selectedTaskID)
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
                openProjectWindow: { url in openWindow(value: url) }
            )
            switch result {
            case .openedNewSession:
                navigationMessage = Strings.agentInboxOpenedNewSession
            case .resumed:
                navigationMessage = Strings.agentInboxResumedSession
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
                openProjectWindow: { url in openWindow(value: url) }
            )
            switch result {
            case .focused:
                navigationMessage = nil
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

    private func statusText(for row: AgentInboxRow) -> String {
        if let liveness = row.liveness, liveness != .live {
            switch liveness {
            case .live: break
            case .stale: return Strings.agentLivenessStale(locale: .current)
            case .terminated:
                return Strings.agentLivenessTerminated(locale: .current)
            }
        }
        return switch row.state {
        case .idle: Strings.agentStateIdle(locale: .current)
        case .thinking: Strings.agentStateThinking(locale: .current)
        case .executing: Strings.agentStateExecuting(locale: .current)
        case .waitingInput: Strings.agentStateWaitingInput(locale: .current)
        case .done: Strings.agentStateDone(locale: .current)
        case nil: row.agentName
        }
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

    private func accessibilityLabel(for row: AgentInboxRow) -> String {
        [
            row.title ?? row.agentName,
            row.agentName,
            statusText(for: row),
            row.projectName,
            row.worktreeName,
        ].compactMap { $0 }.joined(separator: ", ")
    }
}
