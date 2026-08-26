//
//  UserKeybinding.swift
//  Pine
//
//  Lightweight extensibility (issue #1009): user-defined command → key
//  mappings loaded from `keybindings.json`. These map a Pine command id to a
//  key chord string (e.g. `"cmd+shift+f"`) that the app registers as a custom
//  shortcut via the keybinding event monitor.
//

import AppKit
import Foundation
import Observation

/// A single user-defined keybinding entry.
///
/// `command` is a Pine command id recognized by the built-in command table
/// (see `UserCommand.allBuiltIn`). `key` is a normalized chord string whose
/// modifiers are lowercase and `+`-separated (e.g. `"cmd+shift+b"`); the main
/// character is lowercased (e.g. `"f"`).
nonisolated struct UserKeybinding: Codable, Sendable, Equatable {
    let command: String
    let key: String

    enum CodingKeys: String, CodingKey {
        case command
        case key
    }
}

nonisolated struct UserKeybindingsDocument: Codable, Sendable, Equatable {
    let keybindings: [UserKeybinding]
}

/// Built-in commands that user keybindings may target.
///
/// Each case is reachable through a `NotificationCenter` notification, so a
/// user keybinding simply posts the matching notification when its chord is
/// pressed. This keeps the keybinding surface fully decoupled from the rest
/// of the app — no protocol surface to maintain.
nonisolated enum UserCommand: String, Sendable, CaseIterable {
    case newFile
    case openFile
    case clearRecentProjects
    case closeTab
    case closeWindow
    case closeProject
    case save
    case saveAll
    case saveAs
    case duplicate
    case toggleAutoSave
    case toggleFormatOnSave
    case toggleSmartListContinuation
    case toggleComment
    case findInFile
    case findAndReplace
    case findNext
    case findPrevious
    case useSelectionForFind
    case findInProject
    case goToLine
    case nextChange
    case previousChange
    case acceptChange
    case revertChange
    case acceptAllChanges
    case revertAllChanges
    case foldCode
    case unfoldCode
    case foldAll
    case unfoldAll
    case symbolNavigator
    case quickOpen
    case commandPalette
    case openFolder
    case showBranchSwitcher
    case increaseFontSize
    case decreaseFontSize
    case resetFontSize
    case toggleWordWrap
    case toggleMinimap
    case toggleBlame
    case togglePreview
    case revealFileInFinder
    case revealProjectInFinder
    case showAgentActivity
    case showAgentHistory
    case showAgentInbox
    // Agent worktrees (#1525) — reachable without the toolbar
    case newAgent
    case nextProjectInWindow
    case previousProjectInWindow
    case toggleTerminal
    case newTerminalTab
    case findInTerminal
    case sendToTerminal
    case toggleTerminalZoom
    case editKeybindings
    case editTasks
    case reloadUserConfiguration
    // Problems panel (#1236) — chrome wiring
    case showProblems
    case nextDiagnostic
    case previousDiagnostic

    /// The string key for the `Notification.Name` posted when this command fires.
    /// Use `Notification.Name(rawValue:)` on the MainActor side to convert.
    var notificationKey: String {
        switch self {
        case .newFile: "newFile"
        case .openFile: "openFile"
        case .clearRecentProjects: "clearRecentProjects"
        case .closeTab: "closeTab"
        case .closeProject: "closeProject"
        case .closeWindow: "closeWindow"
        case .save: "user.save"
        case .saveAll: "user.saveAll"
        case .saveAs: "user.saveAs"
        case .duplicate: "user.duplicate"
        case .toggleAutoSave: "user.toggleAutoSave"
        case .toggleFormatOnSave: "user.toggleFormatOnSave"
        case .toggleSmartListContinuation: "user.toggleSmartListContinuation"
        case .toggleComment: "toggleComment"
        case .findInFile: "findInFile"
        case .findAndReplace: "findAndReplace"
        case .findNext: "findNext"
        case .findPrevious: "findPrevious"
        case .useSelectionForFind: "useSelectionForFind"
        case .findInProject: "showProjectSearch"
        case .goToLine: "goToLine"
        case .nextChange, .previousChange: "navigateChange"
        case .acceptChange, .revertChange,
             .acceptAllChanges, .revertAllChanges:
            "inlineDiffAction"
        case .foldCode, .unfoldCode, .foldAll, .unfoldAll: "foldCode"
        case .symbolNavigator: "showSymbolNavigator"
        case .quickOpen: "showQuickOpen"
        case .commandPalette: "showCommandPalette"
        case .openFolder: "openFolder"
        case .showBranchSwitcher: "showBranchSwitcher"
        case .increaseFontSize: "user.increaseFontSize"
        case .decreaseFontSize: "user.decreaseFontSize"
        case .resetFontSize: "user.resetFontSize"
        case .toggleWordWrap: "toggleWordWrap"
        case .toggleMinimap: "user.toggleMinimap"
        case .toggleBlame: "user.toggleBlame"
        case .togglePreview: "user.togglePreview"
        case .revealFileInFinder: "user.revealFileInFinder"
        case .revealProjectInFinder: "user.revealProjectInFinder"
        case .showAgentActivity: "showAgentActivity"
        case .showAgentHistory: "showAgentHistory"
        case .showAgentInbox: "showAgentInbox"
        case .newAgent: "newAgent"
        case .nextProjectInWindow, .previousProjectInWindow:
            "switchProjectInWindow"
        case .toggleTerminal: "user.toggleTerminal"
        case .newTerminalTab: "user.newTerminalTab"
        case .findInTerminal: "findInTerminal"
        case .sendToTerminal: "sendToTerminal"
        case .toggleTerminalZoom: "user.toggleTerminalZoom"
        case .editKeybindings: "user.editKeybindings"
        case .editTasks: "user.editTasks"
        case .reloadUserConfiguration: "user.reloadUserConfiguration"
        case .showProblems: "showProblems"
        case .nextDiagnostic: "nextDiagnostic"
        case .previousDiagnostic: "previousDiagnostic"
        }
    }

    /// Whether this command currently has a production notification observer.
    var isAvailableForUserKeybinding: Bool {
        switch self {
        default: true
        }
    }

    static func from(_ raw: String) -> UserCommand? {
        UserCommand(rawValue: raw)
    }
}

/// The function keys a chord can name, and the characters AppKit reports for
/// them.
///
/// `NSF1FunctionKey` … `NSF20FunctionKey` are contiguous private-use scalars
/// starting at `U+F704`, which no keyboard layout can type and no
/// configuration file can readably contain. So the chord grammar spells them
/// `"f1"` … `"f20"` and this table is the single place the two spellings meet
/// — used by `UserKeybindingRegistry.parse` and `keyToken` on the dispatch
/// side and by `MenuKeyboardShortcut` on the menu side, so a function-key
/// chord survives the whole round trip instead of being dropped by whichever
/// layer forgot about it (#1539).
nonisolated enum FunctionKeyToken {
    private static let firstScalar: UInt32 = 0xF704
    private static let count = 20

    private static let charactersByToken: [String: Character] = {
        var table: [String: Character] = [:]
        for index in 0..<count {
            guard let scalar = UnicodeScalar(firstScalar + UInt32(index)) else {
                continue
            }
            table["f\(index + 1)"] = Character(scalar)
        }
        return table
    }()

    private static let tokensByCharacter: [Character: String] = {
        var table: [Character: String] = [:]
        for (token, character) in charactersByToken {
            table[character] = token
        }
        return table
    }()

    /// `"f8"` → the `U+F70B` character AppKit and SwiftUI both use for F8.
    static func character(for token: String) -> Character? {
        charactersByToken[token]
    }

    /// The reverse: `U+F70B` → `"f8"`.
    static func token(for character: Character) -> String? {
        tokensByCharacter[character]
    }
}

/// Parsed key chord: modifiers + a single character or special key.
nonisolated struct ParsedKeyChord: Equatable, Hashable, Sendable {
    let modifiers: NSEvent.ModifierFlags
    /// Lowercased character (e.g. "f", "b"), or a special token ("return",
    /// "up", "down", "left", "right", "tab", "delete", "esc", "space",
    /// "f1" … "f20").
    let key: String

    static func == (lhs: ParsedKeyChord, rhs: ParsedKeyChord) -> Bool {
        lhs.modifiers.rawValue == rhs.modifiers.rawValue && lhs.key == rhs.key
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(modifiers.rawValue)
        hasher.combine(key)
    }
}

/// A validated command/chord pair ready to install in the active registry.
nonisolated struct ResolvedUserKeybinding: Equatable, Sendable {
    let command: UserCommand
    let chord: ParsedKeyChord
}

/// Loads and parses user keybindings from `keybindings.json`.
@MainActor
@Observable
final class UserKeybindingRegistry {
    /// Parsed entries in declaration order.
    private(set) var entries: [ResolvedUserKeybinding] = []

    var count: Int { entries.count }
    var isEmpty: Bool { entries.isEmpty }

    @discardableResult
    func load(from url: URL) async -> UserConfigurationLoadReport {
        let candidate = await Self.prepareLoad(from: url)
        return apply(candidate, from: url)
    }

    /// Reads, decodes, and validates a candidate without touching actor state.
    nonisolated static func prepareLoad(
        from url: URL
    ) async -> UserConfigurationCandidate<ResolvedUserKeybinding> {
        await runOnBackground(qos: .utility) {
            readCandidate(from: url)
        }
    }

    /// Commits a prepared candidate on the main actor.
    func apply(
        _ candidate: UserConfigurationCandidate<ResolvedUserKeybinding>,
        from url: URL
    ) -> UserConfigurationLoadReport {
        let outcome: UserConfigurationLoadOutcome
        let diagnostics: [UserConfigurationDiagnostic]
        switch candidate {
        case .loaded(let parsed):
            entries = parsed
            outcome = .loaded
            diagnostics = []
        case .missing:
            entries = []
            outcome = .missing
            diagnostics = []
        case .rejected(let problems):
            outcome = .rejected
            diagnostics = problems
        }

        return UserConfigurationLoadReport(
            file: .keybindings,
            fileURL: url,
            outcome: outcome,
            activeEntryCount: entries.count,
            diagnostics: diagnostics
        )
    }

    nonisolated private static func readCandidate(
        from url: URL
    ) -> UserConfigurationCandidate<ResolvedUserKeybinding> {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .missing
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return .rejected([
                diagnostic(
                    for: url,
                    entryNumber: nil,
                    reason: .unreadable(details: String(describing: error))
                )
            ])
        }

        let raw: [UserKeybinding]
        do {
            raw = try Self.decodeDocument(from: data)
        } catch {
            return .rejected([
                diagnostic(
                    for: url,
                    entryNumber: nil,
                    reason: .malformedDocument(details: String(describing: error))
                )
            ])
        }

        var parsed: [ResolvedUserKeybinding] = []
        var diagnostics: [UserConfigurationDiagnostic] = []
        var firstEntryForChord: [ParsedKeyChord: Int] = [:]
        var firstEntryForCommand: [UserCommand: Int] = [:]
        for (index, entry) in raw.enumerated() {
            let entryNumber = index + 1
            let command = UserCommand.from(entry.command)
            let chord = Self.parse(entry.key)

            if command == nil {
                diagnostics.append(UserConfigurationDiagnostic(
                    file: .keybindings,
                    fileURL: url,
                    entryNumber: entryNumber,
                    reason: .unknownCommand(id: entry.command)
                ))
            } else if command?.isAvailableForUserKeybinding == false {
                diagnostics.append(UserConfigurationDiagnostic(
                    file: .keybindings,
                    fileURL: url,
                    entryNumber: entryNumber,
                    reason: .unavailableCommand(id: entry.command)
                ))
            }
            if chord == nil {
                diagnostics.append(UserConfigurationDiagnostic(
                    file: .keybindings,
                    fileURL: url,
                    entryNumber: entryNumber,
                    reason: .invalidChord(value: entry.key)
                ))
            } else if let chord, Self.reservedChords.contains(chord) {
                diagnostics.append(UserConfigurationDiagnostic(
                    file: .keybindings,
                    fileURL: url,
                    entryNumber: entryNumber,
                    reason: .reservedSystemChord(value: entry.key)
                ))
            } else if let chord, !Self.hasDispatchModifier(chord) {
                diagnostics.append(UserConfigurationDiagnostic(
                    file: .keybindings,
                    fileURL: url,
                    entryNumber: entryNumber,
                    reason: .textInputChord(value: entry.key)
                ))
            }

            guard let command, let chord else {
                continue
            }

            if let firstEntryNumber = firstEntryForCommand[command] {
                diagnostics.append(UserConfigurationDiagnostic(
                    file: .keybindings,
                    fileURL: url,
                    entryNumber: entryNumber,
                    reason: .duplicateCommand(
                        id: command.rawValue,
                        firstEntryNumber: firstEntryNumber
                    )
                ))
            } else {
                firstEntryForCommand[command] = entryNumber
            }

            if let firstEntryNumber = firstEntryForChord[chord] {
                diagnostics.append(UserConfigurationDiagnostic(
                    file: .keybindings,
                    fileURL: url,
                    entryNumber: entryNumber,
                    reason: .duplicateChord(
                        value: entry.key,
                        firstEntryNumber: firstEntryNumber
                    )
                ))
            } else {
                firstEntryForChord[chord] = entryNumber
            }
            parsed.append(ResolvedUserKeybinding(command: command, chord: chord))
        }

        guard diagnostics.isEmpty else {
            return .rejected(diagnostics)
        }

        return .loaded(parsed)
    }

    /// Looks up the command matching a key event, if any.
    func command(for event: NSEvent) -> UserCommand? {
        guard let chord = Self.chord(for: event) else { return nil }
        for entry in entries where entry.chord == chord {
            return entry.command
        }
        return nil
    }

    /// Whether a user entry replaces `command`'s built-in shortcut.
    func hasOverride(for command: UserCommand) -> Bool {
        entries.contains { $0.command == command }
    }

    /// Returns the one shortcut that is currently effective for `command`.
    ///
    /// A user entry replaces the built-in chord instead of supplementing it.
    /// A built-in chord claimed by another user entry is suppressed so the
    /// menu label, command palette, and event dispatcher all describe the
    /// same routing decision.
    func effectiveChord(for command: UserCommand) -> ParsedKeyChord? {
        if let userEntry = entries.first(where: { $0.command == command }) {
            return userEntry.chord
        }
        guard let builtIn = command.defaultChord else { return nil }
        let claimant = entries.first(where: { $0.chord == builtIn })?.command
        return claimant == nil || claimant == command ? builtIn : nil
    }

    /// Returns `true` when `event` is the old built-in shortcut of a command
    /// that has been rebound by the user. The unified event router consumes
    /// such an event before NSMenu sees it, making a user binding a true
    /// replacement instead of an additional shortcut.
    func suppressesBuiltInShortcut(for event: NSEvent) -> Bool {
        guard let chord = Self.chord(for: event) else { return false }
        return UserCommand.allCases.contains { command in
            command.defaultChord == chord && hasOverride(for: command)
        }
    }

    init() {}

    // MARK: - Parsing

    private enum DocumentError: Error {
        case unsupportedTopLevel
    }

    nonisolated private static func decodeDocument(
        from data: Data
    ) throws -> [UserKeybinding] {
        let object = try JSONSerialization.jsonObject(with: data)
        let decoder = JSONDecoder()
        if object is [Any] {
            return try decoder.decode([UserKeybinding].self, from: data)
        }
        if object is [String: Any] {
            return try decoder.decode(UserKeybindingsDocument.self, from: data).keybindings
        }
        throw DocumentError.unsupportedTopLevel
    }

    nonisolated private static let dispatchModifierMask: NSEvent.ModifierFlags = [
        .command,
        .control,
        .option,
        .shift,
    ]

    nonisolated private static func chord(
        for event: NSEvent
    ) -> ParsedKeyChord? {
        guard let key = keyToken(
            keyCode: event.keyCode,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers
        ) else {
            return nil
        }
        return ParsedKeyChord(
            modifiers: event.modifierFlags.intersection(dispatchModifierMask),
            key: key
        )
    }

    nonisolated private static let reservedChords: Set<ParsedKeyChord> = Set(
        [
            "cmd+space",
            "cmd+tab",
            "cmd+shift+tab",
            "cmd+option+esc",
            "cmd+control+q",
            "ctrl+space",
            "ctrl+up",
            "ctrl+down",
            "ctrl+left",
            "ctrl+right",
            "cmd+a",
            "cmd+c",
            "cmd+x",
            "cmd+v",
            "cmd+z",
            "cmd+shift+z",
            "cmd+`",
            "cmd+q",
            "cmd+w",
            "cmd+h",
            "cmd+m",
            "option+left",
            "option+right",
            "option+shift+left",
            "option+shift+right"
        ].compactMap(parse)
    )

    nonisolated private static func hasDispatchModifier(_ chord: ParsedKeyChord) -> Bool {
        !chord.modifiers.isDisjoint(with: [.command, .control])
    }

    /// Resolves AppKit key codes into the canonical tokens accepted by
    /// `parse`, falling back to printable characters for ordinary keys.
    nonisolated static func keyToken(
        keyCode: UInt16,
        charactersIgnoringModifiers: String?
    ) -> String? {
        switch keyCode {
        case 36, 76: "return"
        case 48: "tab"
        case 51, 117: "delete"
        case 53: "esc"
        case 49: "space"
        case 123: "left"
        case 124: "right"
        case 125: "down"
        case 126: "up"
        default:
            charactersIgnoringModifiers?
                .lowercased()
                .first
                .map { FunctionKeyToken.token(for: $0) ?? String($0) }
        }
    }

    nonisolated private static func diagnostic(
        for url: URL,
        entryNumber: Int?,
        reason: UserConfigurationDiagnosticReason
    ) -> UserConfigurationDiagnostic {
        UserConfigurationDiagnostic(
            file: .keybindings,
            fileURL: url,
            entryNumber: entryNumber,
            reason: reason
        )
    }

    /// Parses a chord string like `"cmd+shift+f"` into modifiers + key.
    ///
    /// Recognized modifier tokens (case-insensitive): `cmd`/`command`,
    /// `shift`, `alt`/`option`/`opt`, `ctrl`/`control`. The final token is
    /// the key — a single character (lowercased), a named special key, or a
    /// function key `"f1"` … `"f20"`.
    nonisolated static func parse(_ chord: String) -> ParsedKeyChord? {
        let tokens = chord.split(separator: "+", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces).lowercased()
        }
        guard !tokens.contains(where: \.isEmpty),
              let last = tokens.last else {
            return nil
        }

        var flags: NSEvent.ModifierFlags = []
        for token in tokens.dropLast() {
            switch token {
            case "cmd", "command": flags.insert(.command)
            case "shift": flags.insert(.shift)
            case "alt", "option", "opt": flags.insert(.option)
            case "ctrl", "control": flags.insert(.control)
            default: return nil // unknown modifier
            }
        }

        // Special named keys.
        switch last {
        case "return", "enter": return ParsedKeyChord(modifiers: flags, key: "return")
        case "tab": return ParsedKeyChord(modifiers: flags, key: "tab")
        case "delete", "backspace": return ParsedKeyChord(modifiers: flags, key: "delete")
        case "esc", "escape": return ParsedKeyChord(modifiers: flags, key: "esc")
        case "space": return ParsedKeyChord(modifiers: flags, key: "space")
        case "up", "down", "left", "right":
            return ParsedKeyChord(modifiers: flags, key: last)
        default:
            // Function keys, then a single printable character.
            if FunctionKeyToken.character(for: last) != nil {
                return ParsedKeyChord(modifiers: flags, key: last)
            }
            guard last.count == 1 else { return nil }
            return ParsedKeyChord(modifiers: flags, key: last)
        }
    }
}
