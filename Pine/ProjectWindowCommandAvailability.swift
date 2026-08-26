//
//  ProjectWindowCommandAvailability.swift
//  Pine
//
//  Issue #1525: starting an agent in a worktree, and moving between the
//  projects a window holds, used to exist only inside the toolbar's
//  project-switcher menu — hiding the toolbar deleted both features.
//
//  Both are now ordinary registered commands, which means three surfaces
//  (menu bar, Command Palette, user keybindings) have to agree on when they
//  are offered. That agreement lives here as a plain value: the window
//  session is a `@MainActor` observable object, and threading it through the
//  invocation router would make the router's gate untestable.
//

import Foundation

/// What the focused window can currently do with its projects and agents.
nonisolated struct ProjectWindowCommandAvailability: Sendable, Equatable {
    /// Agent worktrees are cut with `git worktree add`; a plain folder has
    /// nothing to branch from.
    let isGitRepository: Bool
    /// Whether any first-party agent CLI resolved on `PATH`.
    let hasAgentOptions: Bool
    /// A launch already in flight. `ProjectWindowSession` refuses a second
    /// one, and every switcher row is disabled while it runs.
    let isLaunchingAgent: Bool
    /// Projects plus agent worktrees in this window.
    let switchableTargetCount: Int

    /// No window, or no window session — the Welcome window, a scene whose
    /// project was closed. Nothing on offer.
    static let none = ProjectWindowCommandAvailability(
        isGitRepository: false,
        hasAgentOptions: false,
        isLaunchingAgent: false,
        switchableTargetCount: 0
    )

    var canLaunchAgent: Bool {
        isGitRepository && hasAgentOptions && !isLaunchingAgent
    }

    /// One row is not a choice: wrapping would re-activate the row already on
    /// screen, so a single-project window offers no switching.
    var canSwitchProject: Bool {
        !isLaunchingAgent && switchableTargetCount > 1
    }
}

@MainActor
extension ProjectWindowCommandAvailability {
    /// Reads the live facts off the focused window.
    ///
    /// The repository question is asked of the focused project rather than the
    /// session's `activeRepositoryURL`: an agent worktree is itself a git
    /// checkout, so the answer is the same, and this way the menu never has to
    /// touch the filesystem to decide whether to dim an item.
    init(
        session: ProjectWindowSession?,
        projectManager: ProjectManager?
    ) {
        guard let session, let projectManager else {
            self = .none
            return
        }
        self.init(
            isGitRepository: projectManager.workspace.gitProvider
                .isGitRepository,
            hasAgentOptions: !session.availableAgentOptions.isEmpty,
            isLaunchingAgent: session.isLaunchingAgent,
            switchableTargetCount: session.switchTargets.count
        )
    }
}

/// Resolves which agent a New Agent request means, and carries that request
/// from a menu item to the window that owns the session.
nonisolated enum ProjectAgentLaunchSelection {
    /// `userInfo` key naming one agent. Absent means "the preferred one".
    static let identifierKey = "agentIdentifier"

    /// The agent a request names, or the preferred one when it names nothing.
    ///
    /// A named agent that is no longer in the catalog resolves to `nil` rather
    /// than falling back: the catalog can shrink between a menu opening and
    /// the click landing, and launching a different agent than the one clicked
    /// is worse than launching none.
    static func option(
        identifier: String?,
        in options: [ProjectAgentLaunchOption]
    ) -> ProjectAgentLaunchOption? {
        guard let identifier else { return options.first }
        return options.first { $0.id == identifier }
    }

    /// Posts a New Agent request at the window owning `projectManager`.
    ///
    /// Menu items name their agent; the palette and user keybindings do not,
    /// and mean the preferred one.
    @MainActor
    static func post(
        identifier: String?,
        projectManager: ProjectManager?,
        notificationCenter: NotificationCenter = .default
    ) {
        notificationCenter.post(
            name: .newAgent,
            object: projectManager,
            userInfo: identifier.map { [identifierKey: $0] }
        )
    }
}
