//
//  CommandPaletteModelTests.swift
//  PineTests
//

import AppKit
import Foundation
import Testing

@testable import Pine

@Suite("Command palette catalog and search")
@MainActor
struct CommandPaletteModelTests {
    private let fullContext = CommandPaletteContext(
        hasProject: true,
        hasActiveFile: true,
        isGitRepository: true,
        hasTerminal: true
    )

    @Test("Catalog contains every registered command and every user task")
    func catalogCompleteness() {
        let registry = UserKeybindingRegistry()
        let tasks = [
            UserTask(
                id: "lint",
                label: "Lint Project",
                command: "swiftlint",
                scope: .project
            ),
            UserTask(
                id: "format",
                label: "Format File",
                command: "swiftformat -",
                replacesFileContent: true
            ),
        ]

        let items = CommandPaletteCatalog.makeItems(
            tasks: tasks,
            keybindings: registry,
            context: fullContext
        )
        let commandIDs = Set(items.compactMap { item -> UserCommand? in
            guard case .builtIn(let command) = item.id else { return nil }
            return command
        })
        let taskIDs = Set(items.compactMap { item -> String? in
            guard case .task(let id) = item.id else { return nil }
            return id
        })

        #expect(commandIDs == Set(UserCommand.allCases))
        #expect(taskIDs == ["lint", "format"])
        #expect(items.count == UserCommand.allCases.count + tasks.count)
        #expect(items.allSatisfy { !$0.title.isEmpty && !$0.iconName.isEmpty })
    }

    @Test("Catalog exposes effective override and shadowed shortcut states")
    func shortcutPrecedencePresentation() throws {
        let registry = UserKeybindingRegistry()
        _ = registry.apply(
            .loaded([
                ResolvedUserKeybinding(
                    command: .quickOpen,
                    chord: try #require(UserKeybindingRegistry.parse("cmd+k"))
                ),
                ResolvedUserKeybinding(
                    command: .toggleComment,
                    chord: try #require(UserKeybindingRegistry.parse("cmd+f"))
                ),
            ]),
            from: URL(fileURLWithPath: "/tmp/keybindings.json")
        )

        let items = CommandPaletteCatalog.makeItems(
            tasks: [],
            keybindings: registry,
            context: fullContext
        )
        let quickOpen = try #require(item(for: .quickOpen, in: items))
        let find = try #require(item(for: .findInFile, in: items))
        let toggleComment = try #require(item(for: .toggleComment, in: items))

        #expect(quickOpen.shortcut.state == .userOverride)
        #expect(quickOpen.shortcut.displayText == "⌘K")
        #expect(toggleComment.shortcut.state == .userOverride)
        #expect(toggleComment.shortcut.displayText == "⌘F")
        #expect(find.shortcut.state == .shadowed)
        #expect(find.shortcut.displayText == "⌘F")
    }

    @Test("Context disables commands and tasks without hiding them")
    func contextualAvailability() throws {
        let registry = UserKeybindingRegistry()
        let tasks = [
            UserTask(
                id: "file-task",
                label: "File Task",
                command: "cat",
                scope: .activeFile
            ),
            UserTask(
                id: "project-task",
                label: "Project Task",
                command: "true",
                scope: .project
            ),
        ]
        let context = CommandPaletteContext(
            hasProject: true,
            hasActiveFile: false,
            isGitRepository: false,
            hasTerminal: false
        )

        let items = CommandPaletteCatalog.makeItems(
            tasks: tasks,
            keybindings: registry,
            context: context
        )

        #expect(try #require(item(for: .save, in: items)).isEnabled == false)
        #expect(try #require(item(for: .saveAs, in: items)).isEnabled == false)
        #expect(
            try #require(item(for: .save, in: items)).unavailabilityReason
                == Strings.commandPaletteRequiresActiveFile
        )
        #expect(try #require(item(for: .quickOpen, in: items)).isEnabled)
        #expect(
            try #require(item(for: .quickOpen, in: items))
                .unavailabilityReason == nil
        )
        #expect(
            try #require(item(forTask: "file-task", in: items)).isEnabled
                == false
        )
        #expect(
            try #require(item(forTask: "file-task", in: items))
                .unavailabilityReason
                == Strings.commandPaletteRequiresActiveFile
        )
        #expect(try #require(item(forTask: "project-task", in: items)).isEnabled)
    }

    @Test("Every unavailable context has a localized explanation")
    func contextualAvailabilityReasons() throws {
        let items = CommandPaletteCatalog.makeItems(
            tasks: [],
            keybindings: UserKeybindingRegistry(),
            context: .unavailable
        )

        #expect(
            try #require(item(for: .quickOpen, in: items))
                .unavailabilityReason
                == Strings.commandPaletteRequiresProject
        )
        #expect(
            try #require(item(for: .save, in: items)).unavailabilityReason
                == Strings.commandPaletteRequiresActiveFile
        )
        #expect(
            try #require(item(for: .showBranchSwitcher, in: items))
                .unavailabilityReason
                == Strings.commandPaletteRequiresGitRepository
        )
        #expect(
            try #require(item(for: .findInTerminal, in: items))
                .unavailabilityReason
                == Strings.commandPaletteRequiresTerminal
        )
        #expect(
            try #require(item(for: .sendToTerminal, in: items))
                .unavailabilityReason
                == Strings.commandPaletteNeedsFileAndTerminal
        )
    }

    @Test("Fuzzy search matches titles, command ids, and task ids")
    func fuzzySearch() {
        let registry = UserKeybindingRegistry()
        let task = UserTask(
            id: "terraform-validate",
            label: "Validate Infrastructure",
            command: "terraform validate",
            scope: .project
        )
        let items = CommandPaletteCatalog.makeItems(
            tasks: [task],
            keybindings: registry,
            context: fullContext
        )

        let byCommandID = CommandPaletteSearch.filter(
            items,
            query: "qopen"
        )
        let byTaskID = CommandPaletteSearch.filter(
            items,
            query: "terra val"
        )
        let noMatch = CommandPaletteSearch.filter(
            items,
            query: "definitely-not-present"
        )

        #expect(byCommandID.first?.id == .builtIn(.quickOpen))
        #expect(byTaskID.first?.id == .task("terraform-validate"))
        #expect(noMatch.isEmpty)
    }

    @Test("Keyboard navigation wraps and handles empty results")
    func keyboardNavigation() {
        #expect(
            CommandPaletteNavigation.movedIndex(
                from: 0,
                by: -1,
                itemCount: 3
            ) == 2
        )
        #expect(
            CommandPaletteNavigation.movedIndex(
                from: 2,
                by: 1,
                itemCount: 3
            ) == 0
        )
        #expect(
            CommandPaletteNavigation.movedIndex(
                from: 9,
                by: 1,
                itemCount: 3
            ) == 0
        )
        #expect(
            CommandPaletteNavigation.movedIndex(
                from: 0,
                by: 1,
                itemCount: 0
            ) == 0
        )
    }

    @Test("Keyboard navigation skips disabled results and wraps")
    func keyboardNavigationSkipsDisabled() {
        let items = [
            navigationItem(id: "first", isEnabled: true),
            navigationItem(id: "disabled", isEnabled: false),
            navigationItem(id: "third", isEnabled: true),
        ]

        #expect(
            CommandPaletteNavigation.movedIndex(
                from: 0,
                by: 1,
                items: items
            ) == 2
        )
        #expect(
            CommandPaletteNavigation.movedIndex(
                from: 2,
                by: 1,
                items: items
            ) == 0
        )
        #expect(
            CommandPaletteNavigation.movedIndex(
                from: 0,
                by: -1,
                items: items
            ) == 2
        )
        #expect(CommandPaletteNavigation.preferredIndex(in: items) == 0)
    }

    @Test("All-disabled results keep an explained row discoverable")
    func allDisabledResultsRemainDiscoverable() {
        let items = [
            navigationItem(id: "first", isEnabled: false),
            navigationItem(id: "second", isEnabled: false),
        ]

        #expect(CommandPaletteNavigation.preferredIndex(in: items) == 0)
        #expect(
            CommandPaletteNavigation.movedIndex(
                from: 0,
                by: 1,
                items: items
            ) == 0
        )
        #expect(items.allSatisfy { $0.unavailabilityReason != nil })
    }

    @Test("Shortcut formatter covers named keys and modifiers")
    func shortcutFormatting() throws {
        #expect(
            try #require(
                UserKeybindingRegistry.parse("ctrl+option+shift+cmd+return")
            ).displayText == "⌃⌥⇧⌘↩"
        )
        #expect(
            try #require(
                UserKeybindingRegistry.parse("cmd+left")
            ).displayText == "⌘←"
        )
    }

    private func item(
        for command: UserCommand,
        in items: [CommandPaletteItem]
    ) -> CommandPaletteItem? {
        items.first { $0.id == .builtIn(command) }
    }

    private func navigationItem(
        id: String,
        isEnabled: Bool
    ) -> CommandPaletteItem {
        CommandPaletteItem(
            id: .task(id),
            title: id,
            subtitle: "Test",
            searchTerms: [id],
            iconName: "command",
            shortcut: CommandShortcutPresentation(chord: nil, state: .none),
            isEnabled: isEnabled,
            unavailabilityReason: isEnabled
                ? nil
                : Strings.commandPaletteRequiresProject
        )
    }

    private func item(
        forTask id: String,
        in items: [CommandPaletteItem]
    ) -> CommandPaletteItem? {
        items.first { $0.id == .task(id) }
    }
}
