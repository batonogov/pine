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
enum UserCommand: String, Sendable, CaseIterable {
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

    /// The `Notification.Name` posted when this command fires.
    var notificationName: Notification.Name {
        switch self {
        case .toggleComment: .toggleComment
        case .findInFile: .findInFile
        case .findAndReplace: .findAndReplace
        case .findNext: .findNext
        case .findPrevious: .findPrevious
        case .findInProject: .showProjectSearch
        case .goToLine: .goToLine
        case .symbolNavigator: .showSymbolNavigator
        case .quickOpen: .showQuickOpen
        case .openFolder: .openFolder
        case .showBranchSwitcher: .showBranchSwitcher
        case .toggleWordWrap: .toggleWordWrap
        case .toggleMinimap:
            // Minimap has no dedicated notification; it's a UserDefaults toggle.
            // Use a dedicated name so the monitor can flip the setting directly.
            Self.toggleMinimapNotification
        case .toggleBlame:
            Self.toggleBlameNotification
        case .togglePreview:
            Self.togglePreviewNotification
        case .toggleTerminal:
            Self.toggleTerminalNotification
        case .newTerminalTab:
            Self.newTerminalTabNotification
        }
    }

    // Dedicated notification names for commands that previously had no
    // NotificationCenter-based entry point. They are observed in
    // ContentView / AppDelegate.
    static let toggleMinimapNotification = Notification.Name("user.toggleMinimap")
    static let toggleBlameNotification = Notification.Name("user.toggleBlame")
    static let togglePreviewNotification = Notification.Name("user.togglePreview")
    static let toggleTerminalNotification = Notification.Name("user.toggleTerminal")
    static let newTerminalTabNotification = Notification.Name("user.newTerminalTab")

    static func from(_ raw: String) -> UserCommand? {
        UserCommand(rawValue: raw)
    }
}

/// Parsed key chord: modifiers + a single character or special key.
struct ParsedKeyChord: Equatable, Sendable {
    let modifiers: NSEvent.ModifierFlags
    /// Lowercased character (e.g. "f", "b"), or a special token ("return",
    /// "up", "down", "left", "right", "tab", "delete", "esc", "space").
    let key: String
}

/// Loads and parses user keybindings from `keybindings.json`.
nonisolated final class UserKeybindingRegistry: @unchecked Sendable {
    /// Parsed entries: (command, chord).
    private(set) var entries: [(command: UserCommand, chord: ParsedKeyChord)] = []

    var count: Int { entries.count }

    @discardableResult
    func load(from url: URL) -> [(command: UserCommand, chord: ParsedKeyChord)] {
        guard let data = try? Data(contentsOf: url) else {
            entries = []
            return []
        }

        let docs = try? JSONDecoder().decode(UserKeybindingsDocument.self, from: data)
        let array = try? JSONDecoder().decode([UserKeybinding].self, from: data)
        let raw = docs?.keybindings ?? array ?? []

        var parsed: [(UserCommand, ParsedKeyChord)] = []
        for entry in raw {
            guard let command = UserCommand.from(entry.command),
                  let chord = Self.parse(entry.key) else {
                // Unknown command or unparseable key — skip silently.
                continue
            }
            parsed.append((command, chord))
        }
        entries = parsed
        return parsed
    }

    /// Looks up the command matching a key event, if any.
    func command(for event: NSEvent) -> UserCommand? {
        let mods = KeyboardShortcutMatcher.normalizedModifiers(event.modifierFlags)
        let chars = event.charactersIgnoringModifiers ?? ""
        guard let char = chars.lowercased().first else { return nil }
        let key = String(char)
        for entry in entries where entry.chord.modifiers == mods && entry.chord.key == key {
            return entry.command
        }
        return nil
    }

    init() {}

    // MARK: - Parsing

    /// Parses a chord string like `"cmd+shift+f"` into modifiers + key.
    ///
    /// Recognized modifier tokens (case-insensitive): `cmd`/`command`,
    /// `shift`, `alt`/`option`/`opt`, `ctrl`/`control`. The final token is
    /// the key — a single character (lowercased) or a named special key.
    static func parse(_ chord: String) -> ParsedKeyChord? {
        let tokens = chord.split(separator: "+").map {
            $0.trimmingCharacters(in: .whitespaces).lowercased()
        }
        guard let last = tokens.last, !last.isEmpty else { return nil }

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
