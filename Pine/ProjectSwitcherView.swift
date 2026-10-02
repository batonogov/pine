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
    /// Takes the active project out of this window. Owned by the view that
    /// has the dialog context, since closing may have to ask about unsaved
    /// files first.
    let onCloseProject: () -> Void

    @Environment(\.controlActiveState) private var controlActiveState
    @State private var isHovered = false

    var body: some View {
        Menu {
            ProjectSwitcherMenuContent(
                session: session,
                registry: registry,
                onOpenProject: onOpenProject,
                onCloseProject: onCloseProject
            )
        } label: {
            HStack(spacing: 5) {
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
                        .fontWeight(.semibold)
                        .lineLimit(1)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background {
                Capsule(style: .continuous)
                    .fill(
                        Color.primary.opacity(isHovered ? 0.14 : 0.08)
                    )
            }
            .contentShape(Capsule(style: .continuous))
            .onHover { isHovered = $0 }
            // `.borderlessButton` escapes the toolbar's inactive-window
            // dimming — the label used to stay full-strength white while
            // every neighbour faded — so the pill fades by hand.
            .opacity(controlActiveState == .key ? 1 : 0.5)
        }
        // Styled after Safari's tab-group picker (macOS 27): a filled tinted
        // capsule — icon, semibold project name, chevron — that reads as the
        // navigation zone's primary control rather than one more round
        // toolbar button. `.borderlessButton` opts out of the toolbar's own
        // item chrome so the capsule the label draws is the only chrome;
        // its two known failure modes are patched above — the capsule is
        // sized by hand with generous padding, and inactive-window dimming
        // is applied manually. The tint is a whisper of the label colour,
        // not the accent: the control should read as chrome, not as a call
        // to action.
        .menuStyle(.borderlessButton)
        // The label draws its own chevron; the system indicator would stamp
        // a second one on top.
        .menuIndicator(.hidden)
        .help(Strings.projectSwitcherTooltip)
        // Spoken name stays the project even when the visible text is
        // suppressed as a duplicate — an icon-only control must not reach
        // VoiceOver as an unnamed button.
        .accessibilityLabel(Text(session.activeDisplayName))
        .accessibilityIdentifier(AccessibilityID.projectSwitcher)
    }
}

/// Everything the switcher's menu offers below the label: the project and
/// worktree rows, Close Project, New Agent, Manage Worktrees, Open Folder.
///
/// Extracted from `ProjectSwitcherView.body` so the menu's content is defined
/// exactly once and the view's own code can stay about the pill chrome drawn
/// around it.
struct ProjectSwitcherMenuContent: View {
    let session: ProjectWindowSession
    let registry: ProjectRegistry
    let onOpenProject: () -> Void
    let onCloseProject: () -> Void

    var body: some View {
        ProjectSwitcherRows(
            session: session,
            registry: registry,
            carriesIdentifiers: true,
            onSelect: { url in
                Task { @MainActor in
                    await session.activate(url, registry: registry)
                }
            }
        )

        Divider()

        Button {
            onCloseProject()
        } label: {
            Label {
                // The repository, not `activeDisplayName`: with an agent
                // worktree active the display name carries its branch,
                // while closing takes out the whole project — worktrees
                // included. Naming the branch here would promise less
                // than the item does.
                Text(verbatim: Strings.projectSwitcherCloseProjectTitle(
                    session.displayName(for: session.activeRepositoryURL)
                ))
            } icon: {
                Image(systemName: MenuIcons.closeProject)
            }
        }
        .disabled(session.isLaunchingAgent)
        .accessibilityIdentifier(
            AccessibilityID.projectSwitcherCloseProject
        )

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

        // Mirrors Agent ▸ Manage Agent Worktrees. The menu bar is the
        // canonical home (#1524 lists that as a requirement, and #1525
        // tracks the switcher being hard to reach at all); this is the
        // second door, next to the New Agent item that opens the first.
        Button {
            NotificationCenter.default.post(
                name: .showAgentWorktrees,
                object: nil
            )
        } label: {
            Label(
                Strings.menuAgentWorktrees,
                systemImage: MenuIcons.agentWorktrees
            )
        }
        .disabled(session.isLaunchingAgent)
        .accessibilityIdentifier(
            AccessibilityID.projectSwitcherManageWorktrees
        )

        Button(action: onOpenProject) {
            Label(
                Strings.menuOpenFolder,
                systemImage: MenuIcons.projectSwitcherOpenFolder
            )
        }
        .disabled(session.isLaunchingAgent)
    }
}

/// The switcher's rows: every project this window holds, the agent worktrees
/// hanging off each, and the dividers that group them.
///
/// Shared by the window's switcher control and the menu bar's Switch Project
/// submenu (#1525). The switcher is a convenience layer over commands that
/// exist in the menu bar, never their only home — and one row renderer is
/// what keeps the two from disagreeing about what this window is showing.
struct ProjectSwitcherRows: View {
    let session: ProjectWindowSession
    let registry: ProjectRegistry
    /// Whether these rows carry the switcher's accessibility identifiers.
    ///
    /// The toolbar control owns them. The menu bar draws the same rows and
    /// must not stamp a second copy with the same identifiers: every XCUITest
    /// and VoiceOver lookup would then match two elements and reach whichever
    /// came first. Menu-bar rows are found by title, as every other menu-bar
    /// item is.
    let carriesIdentifiers: Bool
    let onSelect: (URL) -> Void

    var body: some View {
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
    }

    @ViewBuilder
    private func projectButton(_ url: URL) -> some View {
        let button = Button {
            onSelect(url)
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

        if carriesIdentifiers {
            // Identified by the disambiguated name, not the folder name: two
            // roots called `infra` would otherwise answer to the same
            // identifier, and both VoiceOver and XCUITest would only ever
            // reach the first one. With no collision the two strings are
            // identical, so this is stable.
            button.accessibilityIdentifier(
                AccessibilityID.projectSwitcherProject(
                    session.displayName(for: url)
                )
            )
        } else {
            button
        }
    }

    @ViewBuilder
    private func worktreeButton(_ worktree: AgentManagedWorktree) -> some View {
        let task = session.worktreeTask(worktree, registry: registry)
        let presentation = WorktreePresentation(
            worktree: worktree,
            task: task,
            isActive: session.activeProjectURL == worktree.worktreeRoot
        )
        let button = Button {
            onSelect(worktree.worktreeRoot)
        } label: {
            Label {
                Text(presentation.title)
            } icon: {
                Image(systemName: presentation.symbolName)
            }
        }
        .disabled(session.isLaunchingAgent)

        if carriesIdentifiers {
            button.accessibilityIdentifier(
                AccessibilityID.projectSwitcherWorktree(worktree.taskID)
            )
        } else {
            button
        }
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
