//
//  ProjectSwitcherView.swift
//  Pine
//
//  Compact project and agent-worktree navigation for one Pine window.
//

import SwiftUI

struct ProjectSwitcherView: View {
    let session: ProjectWindowSession
    let registry: ProjectRegistry
    let onOpenProject: () -> Void

    var body: some View {
        Menu {
            ForEach(Array(session.groups.enumerated()), id: \.element.id) { index, group in
                if index > 0 {
                    Divider()
                }
                projectButton(group.projectURL)
                ForEach(group.worktrees, id: \.worktreeRoot) { worktree in
                    worktreeButton(worktree)
                }
            }

            Divider()

            Menu {
                if session.availableAgentOptions.isEmpty {
                    Text(Strings.projectSwitcherNoAgents)
                } else {
                    ForEach(session.availableAgentOptions) { option in
                        Button(option.displayName) {
                            Task { @MainActor in
                                await session.launchAgent(
                                    option,
                                    registry: registry
                                )
                            }
                        }
                    }
                }
            } label: {
                Label(
                    Strings.projectSwitcherNewAgent,
                    systemImage: "sparkles"
                )
            }
            .disabled(
                session.isLaunchingAgent
                    || session.availableAgentOptions.isEmpty
            )
            .accessibilityIdentifier(AccessibilityID.projectSwitcherNewAgent)

            Button(action: onOpenProject) {
                Label(Strings.menuOpenFolder, systemImage: "folder.badge.plus")
            }
            .disabled(session.isLaunchingAgent)
        } label: {
            HStack(spacing: 6) {
                if session.isLaunchingAgent {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "folder.stack")
                }
                Text(session.activeDisplayName)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: true, vertical: false)
        .help(Strings.projectSwitcherTooltip)
        .accessibilityIdentifier(AccessibilityID.projectSwitcher)
    }

    @ViewBuilder
    private func projectButton(_ url: URL) -> some View {
        Button {
            Task { @MainActor in
                await session.activate(url, registry: registry)
            }
        } label: {
            Label {
                Text(url.lastPathComponent)
            } icon: {
                Image(systemName: session.activeProjectURL == url
                    ? "checkmark"
                    : "folder")
            }
        }
        .disabled(session.isLaunchingAgent)
        .accessibilityIdentifier(
            AccessibilityID.projectSwitcherProject(url.lastPathComponent)
        )
    }

    @ViewBuilder
    private func worktreeButton(_ worktree: AgentManagedWorktree) -> some View {
        let task = session.worktreeTask(worktree, registry: registry)
        let presentation = WorktreePresentation(
            worktree: worktree,
            task: task,
            isActive: session.activeProjectURL == worktree.worktreeRoot
        )
        Button {
            Task { @MainActor in
                await session.activate(
                    worktree.worktreeRoot,
                    registry: registry
                )
            }
        } label: {
            Label {
                Text(presentation.title)
            } icon: {
                Image(systemName: presentation.symbolName)
            }
        }
        .disabled(session.isLaunchingAgent)
        .accessibilityIdentifier(
            AccessibilityID.projectSwitcherWorktree(worktree.taskID)
        )
    }
}

private struct WorktreePresentation {
    let title: String
    let symbolName: String

    init(
        worktree: AgentManagedWorktree,
        task: AgentTask?,
        isActive: Bool
    ) {
        let taskTitle = task?.title?.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let agentName = task?.descriptor.agentType.displayName
        let branch = worktree.branchName
            .split(separator: "/")
            .suffix(2)
            .joined(separator: "/")
        let displayName: String
        if let taskTitle, !taskTitle.isEmpty {
            displayName = taskTitle
        } else {
            displayName = agentName ?? branch
        }
        title = "    \(displayName)"

        if isActive {
            symbolName = "checkmark"
        } else if task?.attention == .waitingInput {
            symbolName = "exclamationmark.circle.fill"
        } else if task?.attention == .failed {
            symbolName = "xmark.circle.fill"
        } else if task?.lifecycle == .completed
                    || task?.runs.last?.state == .done {
            symbolName = "checkmark.circle"
        } else if task?.runs.last?.liveness == .live {
            symbolName = "circle.fill"
        } else {
            symbolName = "circle"
        }
    }
}
