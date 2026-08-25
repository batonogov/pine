//
//  AgentLaunchCommandTests.swift
//  PineTests
//
//  Issue #1525: launching an agent in a worktree, and switching the window's
//  active project, existed only inside the toolbar's project-switcher menu.
//  Hiding the toolbar removed both. These tests pin the headless halves of
//  the menu-bar / Command Palette / keybinding route that replaces it.
//

import Foundation
import Testing

@testable import Pine

@Suite("Agent launch and project switching commands")
@MainActor
struct AgentLaunchCommandTests {

    // MARK: - Availability

    private func availability(
        git: Bool = true,
        agents: Bool = true,
        launching: Bool = false,
        targets: Int = 2
    ) -> ProjectWindowCommandAvailability {
        ProjectWindowCommandAvailability(
            isGitRepository: git,
            hasAgentOptions: agents,
            isLaunchingAgent: launching,
            switchableTargetCount: targets
        )
    }

    /// Every clause has to hold. A worktree cannot be cut from a non-repository,
    /// there is nothing to run without an installed agent CLI, and a second
    /// launch while one is in flight is what `ProjectWindowSession.launchAgent`
    /// already refuses — the menu must not offer what the session will drop.
    @Test("agent launch needs a repository, an agent, and an idle session")
    func agentLaunchAvailabilityIsConjunctive() {
        #expect(availability().canLaunchAgent)
        #expect(!availability(git: false).canLaunchAgent)
        #expect(!availability(agents: false).canLaunchAgent)
        #expect(!availability(launching: true).canLaunchAgent)
    }

    @Test("switching needs a second row and an idle session")
    func projectSwitchAvailability() {
        #expect(availability(targets: 2).canSwitchProject)
        #expect(!availability(targets: 1).canSwitchProject)
        #expect(!availability(targets: 0).canSwitchProject)
        #expect(!availability(launching: true, targets: 2).canSwitchProject)
    }

    @Test("an absent window session offers neither command")
    func absentSessionOffersNothing() {
        #expect(!ProjectWindowCommandAvailability.none.canLaunchAgent)
        #expect(!ProjectWindowCommandAvailability.none.canSwitchProject)
    }

    // MARK: - Agent selection

    private func option(_ id: String) -> ProjectAgentLaunchOption {
        ProjectAgentLaunchOption(
            id: id,
            displayName: id.capitalized,
            command: id
        )
    }

    /// `availableAgentOptions` sorts the last-used agent first, so an
    /// unqualified request — a keybinding, the palette — means "the one I
    /// used last".
    @Test("an unqualified request launches the preferred agent")
    func unqualifiedRequestUsesPreferredOption() {
        let options = [option("codex"), option("claudeCode")]

        #expect(
            ProjectAgentLaunchSelection.option(
                identifier: nil,
                in: options
            )?.id == "codex"
        )
    }

    @Test("a named request launches exactly that agent")
    func namedRequestSelectsThatOption() {
        let options = [option("codex"), option("claudeCode")]

        #expect(
            ProjectAgentLaunchSelection.option(
                identifier: "claudeCode",
                in: options
            )?.id == "claudeCode"
        )
    }

    /// The catalog can shrink between a menu opening and the click landing —
    /// a CLI uninstalled, PATH changed. Falling back to "whatever is first"
    /// would silently start a different agent than the one clicked.
    @Test("a named request for a vanished agent launches nothing")
    func unknownIdentifierSelectsNothing() {
        #expect(
            ProjectAgentLaunchSelection.option(
                identifier: "claudeCode",
                in: [option("codex")]
            ) == nil
        )
    }

    @Test("an empty catalog launches nothing")
    func emptyCatalogSelectsNothing() {
        #expect(
            ProjectAgentLaunchSelection.option(identifier: nil, in: []) == nil
        )
    }

    // MARK: - Switch request payloads

    @Test("a named row wins over any direction in the same payload")
    func namedRowIsPreferred() {
        let url = URL(fileURLWithPath: "/a", isDirectory: true)

        #expect(
            ProjectWindowSwitchRequest.parse([
                "url": url,
                "direction": "next",
            ]) == .row(url)
        )
    }

    @Test("a direction payload becomes a step")
    func directionBecomesStep() {
        #expect(
            ProjectWindowSwitchRequest.parse(["direction": "previous"])
                == .step(.previous)
        )
    }

    /// A payload Pine does not understand is not a request. Defaulting to a
    /// direction would move the window on a malformed notification.
    @Test("an unusable payload is not a request")
    func unusablePayloadIsIgnored() {
        #expect(ProjectWindowSwitchRequest.parse(nil) == nil)
        #expect(ProjectWindowSwitchRequest.parse([:]) == nil)
        #expect(ProjectWindowSwitchRequest.parse(["direction": "up"]) == nil)
        #expect(ProjectWindowSwitchRequest.parse(["url": "/a"]) == nil)
    }

    // MARK: - Command metadata

    @Test("the new commands are registered for the palette and keybindings")
    func newCommandsAreRegistered() {
        let all = Set(UserCommand.allCases)

        #expect(all.contains(.newAgent))
        #expect(all.contains(.nextProjectInWindow))
        #expect(all.contains(.previousProjectInWindow))
    }

    @Test("the new commands carry palette metadata")
    func newCommandsHaveMetadata() {
        for command in [
            UserCommand.newAgent,
            .nextProjectInWindow,
            .previousProjectInWindow,
        ] {
            #expect(!command.localizedTitle.isEmpty)
            #expect(!command.iconName.isEmpty)
            #expect(!command.notificationKey.isEmpty)
        }
        #expect(UserCommand.newAgent.availabilityRequirement == .agentWorktree)
        #expect(
            UserCommand.nextProjectInWindow.availabilityRequirement
                == .projectSwitching
        )
        #expect(
            UserCommand.previousProjectInWindow.availabilityRequirement
                == .projectSwitching
        )
    }

    /// A rebindable command whose built-in chord collides with another
    /// command's is a shadowed command: `effectiveChord(for:)` hands the chord
    /// to whichever entry claims it and the loser silently loses its shortcut.
    @Test("no two built-in commands claim the same default chord")
    func defaultChordsAreUnique() {
        var owners: [ParsedKeyChord: UserCommand] = [:]

        for command in UserCommand.allCases {
            guard let chord = command.defaultChord else { continue }
            #expect(
                owners[chord] == nil,
                """
                \(command) claims the chord already held by \
                \(String(describing: owners[chord]))
                """
            )
            owners[chord] = command
        }
    }

    @Test("New Agent takes the free Shift-Command-A chord")
    func newAgentChord() throws {
        let chord = try #require(UserCommand.newAgent.defaultChord)

        #expect(chord == UserKeybindingRegistry.parse("cmd+shift+a"))
    }

    /// Which project a chord should switch *to* is not expressible as a key
    /// equivalent, and every free chord left is meaningful to someone. The
    /// menu-bar submenu and the palette are the discovery surface; a user who
    /// wants a chord binds one in `keybindings.json`.
    @Test("project switching ships without a built-in chord")
    func projectSwitchingHasNoDefaultChord() {
        #expect(UserCommand.nextProjectInWindow.defaultChord == nil)
        #expect(UserCommand.previousProjectInWindow.defaultChord == nil)
    }

    @Test("the New Agent chord is documented in the README")
    func newAgentChordIsDocumented() throws {
        let readme = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("README.md")
        let content = try String(contentsOf: readme, encoding: .utf8)

        #expect(
            content.contains("| `Cmd+Shift+A` | New agent in a worktree |")
        )
    }

    // MARK: - Palette surfacing

    @Test("the palette lists the new commands and explains their absence")
    func paletteListsNewCommands() throws {
        let items = CommandPaletteCatalog.makeItems(
            tasks: [],
            keybindings: UserKeybindingRegistry(),
            context: .unavailable
        )

        for command in [
            UserCommand.newAgent,
            .nextProjectInWindow,
            .previousProjectInWindow,
        ] {
            let item = try #require(
                items.first { $0.id == .builtIn(command) },
                "\(command) must be reachable from the Command Palette"
            )
            #expect(!item.isEnabled)
            #expect(item.unavailabilityReason?.isEmpty == false)
        }
    }

    @Test("a qualifying window enables the new palette entries")
    func paletteEnablesNewCommandsInAQualifyingWindow() throws {
        let context = CommandPaletteContext(
            hasProject: true,
            hasActiveFile: false,
            isGitRepository: true,
            hasTerminal: false,
            canLaunchAgent: true,
            canSwitchProjectInWindow: true
        )
        let items = CommandPaletteCatalog.makeItems(
            tasks: [],
            keybindings: UserKeybindingRegistry(),
            context: context
        )

        for command in [
            UserCommand.newAgent,
            .nextProjectInWindow,
            .previousProjectInWindow,
        ] {
            let item = try #require(items.first { $0.id == .builtIn(command) })
            #expect(item.isEnabled)
        }
    }

    // MARK: - Dispatch

    @Test("New Agent dispatch targets its own window")
    func newAgentDispatchTargetsProject() {
        let projectManager = ProjectManager()
        let identifier = ObjectIdentifier(projectManager)
        let center = NotificationCenter()
        let probe = CommandProbe()
        let token = center.addObserver(
            forName: .newAgent,
            object: nil,
            queue: nil
        ) { notification in
            let target = (notification.object as AnyObject?).map(
                ObjectIdentifier.init
            )
            probe.record("newAgent:\(target == identifier)")
        }
        defer { center.removeObserver(token) }

        UserCommandInvocationRouter.dispatch(
            .newAgent,
            projectManager: projectManager,
            windowAvailability: availability(),
            notificationCenter: center
        )

        #expect(probe.values == ["newAgent:true"])
    }

    /// The router is the single gate every surface passes through (#1117).
    /// A palette row or a user chord fired against a window that cannot host
    /// an agent has to stop here, not at the menu item's `disabled` modifier.
    @Test("New Agent dispatch stops when the window cannot host an agent")
    func newAgentDispatchRespectsAvailability() {
        let projectManager = ProjectManager()
        let center = NotificationCenter()
        let probe = CommandProbe()
        let token = center.addObserver(
            forName: .newAgent,
            object: nil,
            queue: nil
        ) { _ in
            probe.record("newAgent")
        }
        defer { center.removeObserver(token) }

        for blocked in [
            availability(git: false),
            availability(agents: false),
            availability(launching: true),
            ProjectWindowCommandAvailability.none,
        ] {
            UserCommandInvocationRouter.dispatch(
                .newAgent,
                projectManager: projectManager,
                windowAvailability: blocked,
                notificationCenter: center
            )
        }

        #expect(probe.values.isEmpty)
    }

    @Test("project switching dispatch carries its direction")
    func projectSwitchDispatchCarriesDirection() {
        let projectManager = ProjectManager()
        let center = NotificationCenter()
        let probe = CommandProbe()
        let token = center.addObserver(
            forName: .switchProjectInWindow,
            object: nil,
            queue: nil
        ) { notification in
            probe.record(
                notification.userInfo?["direction"] as? String ?? "missing"
            )
        }
        defer { center.removeObserver(token) }

        UserCommandInvocationRouter.dispatch(
            .nextProjectInWindow,
            projectManager: projectManager,
            windowAvailability: availability(),
            notificationCenter: center
        )
        UserCommandInvocationRouter.dispatch(
            .previousProjectInWindow,
            projectManager: projectManager,
            windowAvailability: availability(),
            notificationCenter: center
        )

        #expect(probe.values == ["next", "previous"])
    }

    @Test("project switching dispatch stops in a single-project window")
    func projectSwitchDispatchRespectsAvailability() {
        let projectManager = ProjectManager()
        let center = NotificationCenter()
        let probe = CommandProbe()
        let token = center.addObserver(
            forName: .switchProjectInWindow,
            object: nil,
            queue: nil
        ) { _ in
            probe.record("switch")
        }
        defer { center.removeObserver(token) }

        UserCommandInvocationRouter.dispatch(
            .nextProjectInWindow,
            projectManager: projectManager,
            windowAvailability: availability(targets: 1),
            notificationCenter: center
        )

        #expect(probe.values.isEmpty)
    }

    /// Menu items name one agent each, and that name has to survive the trip
    /// through the notification — otherwise every submenu row would launch
    /// the preferred agent.
    @Test("a menu-chosen agent identifier survives dispatch")
    func newAgentRequestCarriesChosenIdentifier() {
        let projectManager = ProjectManager()
        let center = NotificationCenter()
        let probe = CommandProbe()
        let token = center.addObserver(
            forName: .newAgent,
            object: nil,
            queue: nil
        ) { notification in
            probe.record(
                notification.userInfo?[
                    ProjectAgentLaunchSelection.identifierKey
                ] as? String ?? "preferred"
            )
        }
        defer { center.removeObserver(token) }

        ProjectAgentLaunchSelection.post(
            identifier: "claudeCode",
            projectManager: projectManager,
            notificationCenter: center
        )
        ProjectAgentLaunchSelection.post(
            identifier: nil,
            projectManager: projectManager,
            notificationCenter: center
        )

        #expect(probe.values == ["claudeCode", "preferred"])
    }
}

nonisolated private final class CommandProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.withLock { storage }
    }

    func record(_ value: String) {
        lock.withLock {
            storage.append(value)
        }
    }
}
