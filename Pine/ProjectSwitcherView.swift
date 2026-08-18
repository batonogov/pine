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
    /// Text beside the icon, or `nil` when the window title already says the
    /// same thing and the switcher should not repeat it. Resolved by
    /// ``WindowChromePresentation``.
    let label: String?
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
                    systemImage: MenuIcons.projectSwitcherNewAgent
                )
            }
            .disabled(
                session.isLaunchingAgent
                    || session.availableAgentOptions.isEmpty
            )
            .accessibilityIdentifier(AccessibilityID.projectSwitcherNewAgent)

            Button(action: onOpenProject) {
                Label(
                    Strings.menuOpenFolder,
                    systemImage: MenuIcons.projectSwitcherOpenFolder
                )
            }
            .disabled(session.isLaunchingAgent)
        } label: {
            HStack(spacing: 6) {
                if session.isLaunchingAgent {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    // Was `folder.stack`, which is not an SF Symbol and so
                    // rendered as nothing — invisible while the label sat
                    // beside it, a bare chevron once the label could be
                    // suppressed.
                    Image(systemName: MenuIcons.projectSwitcher)
                }
                if let label {
                    Text(label)
                        .lineLimit(1)
                }
                Image(systemName: MenuIcons.projectSwitcherDisclosure)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: true, vertical: false)
        .help(Strings.projectSwitcherTooltip)
        // Spoken name stays the project even when the visible text is
        // suppressed as a duplicate — an icon-only control must not reach
        // VoiceOver as an unnamed button.
        .accessibilityLabel(Text(session.activeDisplayName))
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
                    ? MenuIcons.projectSwitcherActive
                    : MenuIcons.projectSwitcherProject)
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
