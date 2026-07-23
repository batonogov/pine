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
    case toggleComment
    case findInFile
    case findAndReplace
    case findNext
    case findPrevious
    case findInProject
    case goToLine
    case symbolNavigator
    case quickOpen
    case openFolder
    case showBranchSwitcher
    case toggleWordWrap
    case toggleMinimap
    case toggleBlame
    case togglePreview
    case toggleTerminal
    case newTerminalTab

    /// The string key for the `Notification.Name` posted when this command fires.
    /// Use `Notification.Name(rawValue:)` on the MainActor side to convert.
    var notificationKey: String {
        switch self {
        case .toggleComment: "toggleComment"
        case .findInFile: "findInFile"
        case .findAndReplace: "findAndReplace"
        case .findNext: "findNext"
        case .findPrevious: "findPrevious"
        case .findInProject: "showProjectSearch"
        case .goToLine: "goToLine"
        case .symbolNavigator: "showSymbolNavigator"
        case .quickOpen: "showQuickOpen"
        case .openFolder: "openFolder"
        case .showBranchSwitcher: "showBranchSwitcher"
        case .toggleWordWrap: "toggleWordWrap"
        case .toggleMinimap: "user.toggleMinimap"
        case .toggleBlame: "user.toggleBlame"
        case .togglePreview: "user.togglePreview"
        case .toggleTerminal: "user.toggleTerminal"
        case .newTerminalTab: "user.newTerminalTab"
        }
    }

    /// Whether this command currently has a production notification observer.
    var isAvailableForUserKeybinding: Bool {
        switch self {
        case .toggleMinimap, .toggleBlame, .togglePreview,
             .toggleTerminal, .newTerminalTab:
            false
        default:
            true
        }
    }

    static func from(_ raw: String) -> UserCommand? {
        UserCommand(rawValue: raw)
    }
}

/// Parsed key chord: modifiers + a single character or special key.
nonisolated struct ParsedKeyChord: Equatable, Hashable, Sendable {
    let modifiers: NSEvent.ModifierFlags
    /// Lowercased character (e.g. "f", "b"), or a special token ("return",
    /// "up", "down", "left", "right", "tab", "delete", "esc", "space").
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
        let mods = event.modifierFlags.intersection(Self.dispatchModifierMask)
        guard let key = Self.keyToken(
            keyCode: event.keyCode,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers
        ) else {
            return nil
        }
        for entry in entries where entry.chord.modifiers == mods && entry.chord.key == key {
            return entry.command
        }
        return nil
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
                .map(String.init)
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
    /// the key — a single character (lowercased) or a named special key.
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
            // Single printable character.
            guard last.count == 1 else { return nil }
            return ParsedKeyChord(modifiers: flags, key: last)
        }
    }
}
