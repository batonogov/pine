//
//  ADETaskDetailView.swift
//  Pine
//
//  The main area while a task is selected: its goal, its state, anything
//  waiting for the user, the result, and a way to continue.
//

import SwiftUI

struct ADETaskDetailView: View {
    @Bindable var model: ADEWorkspaceModel
    let registry: ProjectRegistry
    let row: ADETaskRow
    @State private var showsDetails = false
    @State private var showsOutput = false
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var task: AgentTask? { registry.agentTasks.task(for: row.id) }

    /// While the result shows its own reply field, it is the one input on screen.
    private var hasDecisionRequest: Bool {
        task.map { AgentTaskReviewOrchestrator.decisionRequest(for: $0) != nil } ?? false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.bottom, 6)
            detailsDisclosure
            session.padding(.top, 8)
            GeometryReader { proxy in
                ADEFittedResultSurface(
                    availableHeight: proxy.size.height, registry: registry, taskID: row.id
                )
            }
            .padding(.top, 12)
            if !hasDecisionRequest {
                ADEComposerView(model: model)
                    .padding(.top, 12)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.workspaceTaskDetail)
    }

    // MARK: - Goal and state

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                stateIndicator
                Text(verbatim: row.indicator.title(neverStarted: row.neverStarted, locale: locale))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(verbatim: "·")
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                Text(verbatim: row.inbox.agentName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(AccessibilityID.workspaceTaskState)
            Text(verbatim: row.goal)
                .font(.title2.weight(.semibold))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier(AccessibilityID.workspaceTaskGoal)
        }
    }

    /// The indicator sits on the text baseline, not the row's vertical centre.
    private var stateIndicator: some View {
        ADETaskIndicatorView(indicator: row.indicator, reduceMotion: reduceMotion)
            .alignmentGuide(VerticalAlignment.firstTextBaseline) { (dimensions: ViewDimensions) in
                dimensions[VerticalAlignment.center] + 3.5
            }
    }

    // MARK: - Details

    private var detailsDisclosure: some View {
        DisclosureGroup(isExpanded: $showsDetails) {
            details
                .padding(.top, 6)
                .padding(.leading, 4)
        } label: {
            Text(Strings.workspaceDetails)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier(AccessibilityID.workspaceTaskDetails)
    }

    private var details: some View {
        Grid(alignment: .leading, verticalSpacing: 6) {
            GridRow(alignment: VerticalAlignment.firstTextBaseline) {
                detailLabel(Strings.workspaceEnvironmentWorktree)
                worktreeValue
            }
            unavailableRow(Strings.workspaceEnvironmentBranch)
            unavailableRow(Strings.workspaceEnvironmentRecovery)
            unavailableRow(Strings.workspaceRunHistory)
        }
        .font(.caption)
        .padding(10)
        .background(
            Color.primary.opacity(0.04),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
    }

    private func unavailableRow(_ key: LocalizedStringKey) -> some View {
        GridRow(alignment: VerticalAlignment.firstTextBaseline) {
            detailLabel(key)
            unavailable
        }
    }

    private func detailLabel(_ key: LocalizedStringKey) -> some View {
        Text(key).foregroundStyle(.secondary)
    }

    private var unavailable: some View {
        Text(Strings.workspaceNotAvailableYet).foregroundStyle(.secondary)
    }

    /// Where the task does its work. Branch and recovery are not recorded on
    /// the task yet, so they say so rather than guess.
    @ViewBuilder
    private var worktreeValue: some View {
        if let worktree = worktreePath {
            if worktree == model.projectURL.path {
                Text(Strings.workspaceProjectFolder).textSelection(.enabled)
            } else {
                Text(verbatim: worktree)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
        } else {
            unavailable
        }
    }

    private var worktreePath: String? {
        guard let task else { return nil }
        return task.worktreeSetup?.reservation.expectedWorktree.standardizedFileURL.path
            ?? task.project.canonicalWorktreePath
    }

    // MARK: - Live session

    @ViewBuilder
    private var session: some View {
        if let runtime = model.liveRuntime {
            VStack(alignment: .leading, spacing: 8) {
                activityStrip(runtime)
                if model.sessionActionFailed {
                    Text(Strings.openCodeTaskActionFailed)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let snapshot = runtime.snapshot {
                    if snapshot.inputFenced {
                        Text(Strings.openCodeTaskInputFenced)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !snapshot.children.isEmpty {
                        Text(Strings.openCodeTaskChildrenUnverified)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(snapshot.questions, id: \.id) { question in
                        questionCard(question, runtime: runtime)
                    }
                    if !snapshot.result.isEmpty {
                        outputDisclosure(snapshot.result)
                    }
                }
            }
        }
    }

    private func activityStrip(_ runtime: OpenCodeACPTaskRuntime) -> some View {
        HStack(spacing: 8) {
            if let state = runtime.snapshot?.state {
                Label(
                    OpenCodeTaskView.sessionStateText(state),
                    systemImage: state == .working || state == .submitted
                        ? "ellipsis.circle" : "info.circle"
                )
            }
            Spacer(minLength: 0)
            elapsed
            if runtime.isActive {
                Button(Strings.openCodeTaskCancel) {
                    model.performSessionAction { try await runtime.cancel() }
                }
                .controlSize(.small)
            }        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    /// A live run keeps counting; a settled one is pinned to its last honest moment.
    private var elapsed: some View {
        Group {
            if let end = row.inbox.durationEndedAt {
                Text(
                    timerInterval: row.inbox.startedAt...end,
                    pauseTime: end,
                    countsDown: false,
                    showsHours: true
                )
            } else {
                Text(row.inbox.startedAt, style: .timer)
            }
        }
        .monospacedDigit()
    }

    private func questionCard(
        _ question: OpenCodeACPSession.Question, runtime: OpenCodeACPTaskRuntime
    ) -> some View {
        HStack(alignment: .top, spacing: 0) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(Color.orange)
                .frame(width: 3)
                .padding(.vertical, 2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(Strings.workspaceQuestionTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                OpenCodeTaskQuestionView(
                    question: question, runtime: runtime,
                    isBusy: model.isBusy,
                    perform: model.performSessionAction
                )
            }
            .padding(.leading, 8)
        }
        .accessibilityElement(children: .contain)
    }

    private func outputDisclosure(_ output: String) -> some View {
        DisclosureGroup(isExpanded: $showsOutput) {
            ScrollView {
                Text(verbatim: output)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(height: 132)
            .padding(.top, 6)
            .accessibilityIdentifier(AccessibilityID.workspaceSessionOutput)
        } label: {
            Text(Strings.workspaceSessionOutput)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }
}

/// Gives the result surface whatever height the detail has left.
///
/// `AgentTaskResultView` is no shorter than 480 pt, which a short window
/// cannot give it. The surface keeps that frame, and a bottom safe-area inset
/// equal to the hidden remainder keeps its content and scrollers inside the
/// visible part — one scroll view, never a second one around it.
private struct ADEFittedResultSurface: View {
    let availableHeight: CGFloat
    let registry: ProjectRegistry
    let taskID: UUID
    private static let minimumHeight: CGFloat = 480

    private var hidden: CGFloat { max(0, Self.minimumHeight - availableHeight) }

    var body: some View {
        AgentTaskResultHost(registry: registry, taskID: taskID)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if hidden > 0 {
                    Color.clear
                        .frame(height: hidden)
                        .accessibilityHidden(true)
                }
            }
            .frame(height: max(0, availableHeight), alignment: .top)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .clipped()
    }
}
