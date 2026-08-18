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
            let groups = session.groups
            ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                if ProjectSwitcherMenuLayout.needsDivider(
                    before: index,
                    in: groups
                ) {
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
            }
        }
        // No `menuStyle` and no hand-drawn chevron: the toolbar's own style
        // is what sizes the item chrome and draws the disclosure indicator.
        // `.borderlessButton` opted out of both and pinned the control to a
        // chrome narrower than the round items beside it while holding two
        // glyphs instead of one, so the icon and the chevron sat flush
        // against the capsule with no breathing room. It also kept the label
        // full-strength white while every neighbour, and the window title,
        // dimmed with an inactive window. Measured on macOS 27 beta at 2×:
        // 33pt beside 35pt neighbours before, 41.5pt after. The exact metric
        // moves with the OS and the display scale; the relationship — a
        // busier control is never the narrowest one on the strip — does not,
        // which is what `EditorWindowTests` asserts.
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
                Text(session.displayName(for: url))
            } icon: {
                Image(systemName: session.activeProjectURL == url
                    ? MenuIcons.projectSwitcherActive
                    : MenuIcons.projectSwitcherProject)
            }
        }
        .disabled(session.isLaunchingAgent)
        // Identified by the disambiguated name, not the folder name: two roots
        // called `infra` would otherwise answer to the same identifier, and
        // both VoiceOver and XCUITest would only ever reach the first one.
        // With no collision the two strings are identical, so this is stable.
        .accessibilityIdentifier(
            AccessibilityID.projectSwitcherProject(session.displayName(for: url))
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

/// Where the switcher menu draws separators.
///
/// A divider earns its place by grouping something: a project and the agent
/// worktrees hanging off it read as one block, and the rule separates that
/// block from what surrounds it. Between two plain projects it groups nothing
/// and only spreads four rows across four sections, which is why a window with
/// no agent worktrees — the common case — now shows an unbroken list.
nonisolated enum ProjectSwitcherMenuLayout {
    static func needsDivider(
        before index: Int,
        in groups: [ProjectWindowGroup]
    ) -> Bool {
        guard index > 0, index < groups.count else { return false }
        return !groups[index].worktrees.isEmpty
            || !groups[index - 1].worktrees.isEmpty
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
