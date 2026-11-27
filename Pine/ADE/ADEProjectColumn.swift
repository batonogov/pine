//
//  ADEProjectColumn.swift
//  Pine
//
//  The workspace's leading column: which project this is, and its tasks.
//

import SwiftUI

struct ADEProjectColumn: View {
    @Bindable var model: ADEWorkspaceModel
    let registry: ProjectRegistry
    @Environment(ProjectManager.self) private var projectManager
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var projectName: String { model.projectURL.lastPathComponent }

    private var folder: String {
        (model.projectURL.deletingLastPathComponent().path as NSString)
            .abbreviatingWithTildeInPath
    }

    private var branch: String {
        projectManager.workspace.gitProvider.currentBranch
    }

    var body: some View {
        VStack(spacing: 0) {
            identity
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 6)
            List(selection: $model.selectedTaskID) {
                Section {
                    ForEach(model.rows) { row in
                        ADETaskRowView(row: row, reduceMotion: reduceMotion)
                            .tag(row.id)
                            .accessibilityIdentifier(
                                AccessibilityID.workspaceTaskRow(row.id)
                            )
                    }
                    if model.rows.isEmpty {
                        Text(Strings.workspaceNoTasks)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier(AccessibilityID.workspaceNoTasks)
                    }
                } header: {
                    tasksHeader
                }
            }
            .listStyle(.sidebar)
            .accessibilityIdentifier(AccessibilityID.workspaceTaskList)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                persistenceStatus
            }
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: - Project

    private var identity: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Text(verbatim: String(projectName.prefix(1)).uppercased())
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: projectName)
                        .font(.headline)
                        .lineLimit(1)
                    Text(verbatim: folder)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            if !branch.isEmpty {
                Label {
                    Text(verbatim: branch)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } icon: {
                    Image(systemName: "arrow.triangle.branch")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(AccessibilityID.workspaceProjectIdentity)
    }

    private var tasksHeader: some View {
        HStack {
            Text(Strings.workspaceTasks)
            Spacer(minLength: 0)
            Button {
                model.startNewTask()
                model.newTaskFocusRequest = UUID()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .help(Text(Strings.workspaceNewTask))
            .accessibilityLabel(Strings.workspaceNewTask)
            .accessibilityIdentifier(AccessibilityID.workspaceNewTaskButton)
        }
        .font(.caption.weight(.semibold))
        .tracking(0.6)
        .textCase(.uppercase)
        .foregroundStyle(.secondary)
        .contentShape(Rectangle())
    }

    /// A truthful error state: this project's task history cannot be saved.
    @ViewBuilder
    private var persistenceStatus: some View {
        if registry.agentTasks.unavailableMetadataProjects.contains(where: {
            $0 == model.projectIdentity
        }) {
            AgentTaskPersistenceStatusView(
                registry: registry.agentTasks, project: model.projectIdentity
            )
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .adaptiveMaterialBackground(.bar)
        }
    }
}

/// One task in the leading column: its goal and one state indicator.
struct ADETaskRowView: View {
    let row: ADETaskRow
    let reduceMotion: Bool
    @Environment(\.locale) private var locale

    /// The indicator sits on the text baseline, not the row's vertical centre.
    private var stateIndicator: some View {
        ADETaskIndicatorView(indicator: row.indicator, reduceMotion: reduceMotion)
            .alignmentGuide(VerticalAlignment.firstTextBaseline) { (dimensions: ViewDimensions) in
                dimensions[VerticalAlignment.center] + 3.5
            }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            stateIndicator
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: row.goal)
                    .font(.body.weight(row.inbox.isUnread ? .semibold : .regular))
                    .lineLimit(1)
                Text(verbatim: state)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: accessibilityLabel))
    }

    private var state: String {
        row.indicator.title(neverStarted: row.neverStarted, locale: locale)
    }

    /// The spoken row: goal, unread, state, agent — the same fields the eye reads.
    private var accessibilityLabel: String {
        var fields = [row.goal]
        if row.inbox.isUnread {
            fields.append(Strings.agentInboxUnread(locale: locale))
        }
        fields.append(state)
        fields.append(row.inbox.agentName)
        return fields.joined(separator: ", ")
    }
}

/// The one indicator a task carries. Shape and color both state it, so it
/// reads without color. A running task breathes, unless that is motion the
/// user asked not to see.
struct ADETaskIndicatorView: View {
    let indicator: ADETaskIndicator
    let reduceMotion: Bool
    @State private var breathing = false

    private var isRunning: Bool { indicator == .running }

    private var color: Color {
        switch indicator {
        case .needsDecision: .orange
        case .ready: .green
        case .running: .accentColor
        case .failed: .red
        case .cancelled, .unverified: .secondary
        }
    }

    var body: some View {
        // Identity follows the state so a finished animation is torn down, not left running unseen.
        if isRunning && !reduceMotion {
            symbol
                .opacity(breathing ? 0.3 : 1)
                .animation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true), value: breathing)
                .id("breathing")
                .task {
                    breathing = true
                }
        } else {
            symbol.id("steady")
        }
    }

    private var symbol: some View {
        Image(systemName: indicator.symbol)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: 12)
            .contentTransition(
                reduceMotion ? .identity : .symbolEffect(.replace)
            )
            .accessibilityHidden(true)
    }
}
