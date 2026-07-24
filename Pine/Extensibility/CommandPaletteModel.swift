//
//  CommandPaletteModel.swift
//  Pine
//
//  Unified searchable catalog for Pine's built-in commands and user tasks
//  (issue #1117). The model is independent from SwiftUI so fuzzy ranking,
//  shortcut precedence, availability, and keyboard navigation remain
//  deterministic and directly testable.
//

import AppKit
import Foundation

nonisolated enum CommandPaletteCategory: String, Sendable, CaseIterable {
    case file
    case edit
    case view
    case git
    case terminal
    case tasks

    var localizedTitle: String {
        switch self {
        case .file:
            String(localized: "commandPalette.category.file")
        case .edit:
            String(localized: "commandPalette.category.edit")
        case .view:
            String(localized: "menu.view")
        case .git:
            String(localized: "menu.git")
        case .terminal:
            String(localized: "menu.terminal")
        case .tasks:
            String(localized: "menu.tasks")
        }
    }
}

nonisolated enum CommandAvailabilityRequirement: Sendable {
    case always
    case project
    case activeFile
    case activeFileAndTerminal
    case gitRepository
    case terminal
}

nonisolated struct CommandPaletteContext: Sendable, Equatable {
    let hasProject: Bool
    let hasActiveFile: Bool
    let isGitRepository: Bool
    let hasTerminal: Bool

    static let unavailable = CommandPaletteContext(
        hasProject: false,
        hasActiveFile: false,
        isGitRepository: false,
        hasTerminal: false
    )

    func satisfies(_ requirement: CommandAvailabilityRequirement) -> Bool {
        switch requirement {
        case .always:
            true
        case .project:
            hasProject
        case .activeFile:
            hasActiveFile
        case .activeFileAndTerminal:
            hasActiveFile && hasTerminal
        case .gitRepository:
            isGitRepository
        case .terminal:
            hasTerminal
        }
    }
}

nonisolated enum CommandPaletteItemID: Hashable, Sendable {
    case builtIn(UserCommand)
    case task(String)
}

nonisolated enum CommandShortcutState: Sendable, Equatable {
    /// The built-in key equivalent is effective.
    case builtIn
    /// A user binding replaces the command's built-in key equivalent.
    case userOverride
    /// Another user binding claims this command's built-in key equivalent.
    case shadowed
    /// The command or task has no shortcut.
    case none
}

nonisolated struct CommandShortcutPresentation: Sendable, Equatable {
    let chord: ParsedKeyChord?
    let state: CommandShortcutState

    var displayText: String? {
        chord?.displayText
    }
}

nonisolated struct CommandPaletteItem: Identifiable, Sendable, Equatable {
    let id: CommandPaletteItemID
    let title: String
    let subtitle: String
    let searchTerms: [String]
    let iconName: String
    let shortcut: CommandShortcutPresentation
    let isEnabled: Bool

    var isTask: Bool {
        if case .task = id {
            return true
        }
        return false
    }

    var searchableText: String {
        ([title, subtitle] + searchTerms).joined(separator: " ").lowercased()
    }
}

@MainActor
enum CommandPaletteCatalog {
    static func makeItems(
        tasks: [UserTask],
        keybindings: UserKeybindingRegistry,
        context: CommandPaletteContext
    ) -> [CommandPaletteItem] {
        let userEntries = keybindings.entries
        var entryByCommand: [UserCommand: ParsedKeyChord] = [:]
        var commandByClaimedChord: [ParsedKeyChord: UserCommand] = [:]
        for entry in userEntries {
            if entryByCommand[entry.command] == nil {
                entryByCommand[entry.command] = entry.chord
            }
            if commandByClaimedChord[entry.chord] == nil {
                commandByClaimedChord[entry.chord] = entry.command
            }
        }

        let builtIns = UserCommand.allCases.map { command in
            let shortcut = shortcutPresentation(
                for: command,
                entryByCommand: entryByCommand,
                commandByClaimedChord: commandByClaimedChord
            )
            return CommandPaletteItem(
                id: .builtIn(command),
                title: command.localizedTitle,
                subtitle: command.category.localizedTitle,
                searchTerms: [command.rawValue],
                iconName: command.iconName,
                shortcut: shortcut,
                isEnabled: context.satisfies(command.availabilityRequirement)
            )
        }

        let taskItems = tasks.map { task in
            let isEnabled: Bool
            switch task.scope {
            case .activeFile:
                isEnabled = context.hasActiveFile
            case .project:
                isEnabled = context.hasProject
            }
            return CommandPaletteItem(
                id: .task(task.id),
                title: task.label,
                subtitle: CommandPaletteCategory.tasks.localizedTitle,
                searchTerms: [task.id, task.command],
                iconName: MenuIcons.tasks,
                shortcut: CommandShortcutPresentation(chord: nil, state: .none),
                isEnabled: isEnabled
            )
        }

        return builtIns + taskItems
    }

    private static func shortcutPresentation(
        for command: UserCommand,
        entryByCommand: [UserCommand: ParsedKeyChord],
        commandByClaimedChord: [ParsedKeyChord: UserCommand]
    ) -> CommandShortcutPresentation {
        if let userChord = entryByCommand[command] {
            return CommandShortcutPresentation(
                chord: userChord,
                state: .userOverride
            )
        }
        guard let builtInChord = command.defaultChord else {
            return CommandShortcutPresentation(chord: nil, state: .none)
        }
        if let claimant = commandByClaimedChord[builtInChord],
           claimant != command {
            return CommandShortcutPresentation(
                chord: builtInChord,
                state: .shadowed
            )
        }
        return CommandShortcutPresentation(
            chord: builtInChord,
            state: .builtIn
        )
    }
}

nonisolated enum CommandPaletteSearch {
    static func filter(
        _ items: [CommandPaletteItem],
        query: String
    ) -> [CommandPaletteItem] {
        let tokens = query
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard !tokens.isEmpty else { return items }

        return items.enumerated()
            .compactMap { index, item -> (CommandPaletteItem, Int, Int)? in
                var totalScore = 0
                for token in tokens {
                    guard let score = score(token: token, item: item) else {
                        return nil
                    }
                    totalScore += score
                }
                return (item, totalScore, index)
            }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 {
                    return lhs.1 > rhs.1
                }
                return lhs.2 < rhs.2
            }
            .map(\.0)
    }

    private static func score(
        token: String,
        item: CommandPaletteItem
    ) -> Int? {
        let title = item.title.lowercased()
        let terms = item.searchTerms.map { $0.lowercased() }

        if title == token {
            return 1_000
        }
        if title.hasPrefix(token) {
            return 800 - title.count
        }
        if title.contains(token) {
            return 600 - title.count
        }
        if terms.contains(token) {
            return 550
        }
        if let term = terms.first(where: { $0.hasPrefix(token) }) {
            return 500 - term.count
        }
        if isSubsequence(token, of: title) {
            return 300 - title.count
        }
        if isSubsequence(token, of: item.searchableText) {
            return 100 - item.searchableText.count
        }
        return nil
    }

    private static func isSubsequence(_ query: String, of target: String) -> Bool {
        var queryIndex = query.startIndex
        var targetIndex = target.startIndex
        while queryIndex < query.endIndex, targetIndex < target.endIndex {
            if query[queryIndex] == target[targetIndex] {
                query.formIndex(after: &queryIndex)
            }
            target.formIndex(after: &targetIndex)
        }
        return queryIndex == query.endIndex
    }
}

nonisolated enum CommandPaletteNavigation {
    static func movedIndex(
        from currentIndex: Int,
        by delta: Int,
        itemCount: Int
    ) -> Int {
        guard itemCount > 0 else { return 0 }
        let normalized = min(max(currentIndex, 0), itemCount - 1)
        let remainder = (normalized + delta) % itemCount
        return remainder >= 0 ? remainder : remainder + itemCount
    }
}

nonisolated extension ParsedKeyChord {
    var displayText: String {
        var result = ""
        if modifiers.contains(.control) {
            result += "⌃"
        }
        if modifiers.contains(.option) {
            result += "⌥"
        }
        if modifiers.contains(.shift) {
            result += "⇧"
        }
        if modifiers.contains(.command) {
            result += "⌘"
        }
        result += Self.displayKey(key)
        return result
    }

    private static func displayKey(_ key: String) -> String {
        switch key {
        case "return": "↩"
        case "tab": "⇥"
        case "delete": "⌫"
        case "esc": "⎋"
        case "space": "Space"
        case "up": "↑"
        case "down": "↓"
        case "left": "←"
        case "right": "→"
        default: key.uppercased()
        }
    }
}
