//
//  UserConfigurationEditor.swift
//  Pine
//
//  Issue #1117: surfaces Pine's user-editable JSON configuration
//  (`keybindings.json`, `tasks.json`) through menu actions. Creates a
//  commented starter file when none exists yet — without ever overwriting
//  a file the user already wrote — and reveals it in the system's default
//  editor.
//
//  The starter content is valid JSON: guidance lives in a `_comment` field
//  that JSONDecoder silently ignores, so reloading a freshly-created starter
//  produces no diagnostics instead of a "malformed document" error.
//

import AppKit
import Foundation
import os

/// Opens (and lazily bootstraps) Pine's user configuration files.
///
/// All members are safe to call from the main actor (menu actions). File I/O
/// is tiny and one-shot, so it stays inline rather than dispatching to a
/// background queue.
@MainActor
enum UserConfigurationEditor {
    /// Creates the starter file for `file` at its canonical path if it does
    /// not already exist, then never touches it again.
    ///
    /// - Returns: `true` if a new starter file was created, `false` if the
    ///   file already existed (caller may want to distinguish "opened my
    ///   existing config" from "opened a brand-new template").
    @discardableResult
    static func ensureStarterFileExists(_ file: UserConfigurationFile) throws -> Bool {
        let url = url(for: file)
        let directory = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        guard !FileManager.default.fileExists(atPath: url.path) else {
            return false
        }
        try Data(starterContent(for: file).utf8).write(to: url, options: .atomic)
        return true
    }

    /// Reveals the configuration file in the user's default editor.
    /// Creates the starter first so the action always opens something
    /// editable instead of a "file not found" dead end.
    static func open(_ file: UserConfigurationFile) {
        do {
            try ensureStarterFileExists(file)
        } catch {
            Logger.extensibility.error(
                "Could not create starter \(file.rawValue) configuration: \(String(describing: error))"
            )
            presentCreationFailure(file, error: error)
            return
        }
        NSWorkspace.shared.open(url(for: file))
    }

    /// Shortcut for the keybindings config file.
    static func openKeybindings() {
        open(.keybindings)
    }

    /// Shortcut for the tasks config file.
    static func openTasks() {
        open(.tasks)
    }

    // MARK: - Paths & templates

    /// The canonical URL for a configuration file.
    static func url(for file: UserConfigurationFile) -> URL {
        switch file {
        case .keybindings:
            UserConfigurationPaths.userKeybindingsFile
        case .tasks:
            UserConfigurationPaths.userTasksFile
        }
    }

    /// Documented, valid-JSON starter content for a configuration file.
    ///
    /// Pure function so it is directly unit-testable without touching disk.
    /// The `_comment` guidance is JSON-encoded so embedded quotes survive
    /// safely; the emitted document always parses.
    nonisolated static func starterContent(
        for file: UserConfigurationFile
    ) -> String {
        switch file {
        case .keybindings:
            starterDocument(
                comment: keybindingsComment,
                arrayKey: "keybindings"
            )
        case .tasks:
            starterDocument(
                comment: tasksComment,
                arrayKey: "tasks"
            )
        }
    }

    nonisolated private static var keybindingsComment: String {
        [
            "Pine keybindings. Add entries to the \"keybindings\" array below.",
            " Each entry maps a command id to a key chord.",
            " Command ids: quickOpen, findInFile, findAndReplace, findNext,",
            " findPrevious, findInProject, goToLine, symbolNavigator,",
            " toggleComment, toggleWordWrap, openFolder, showBranchSwitcher.",
            " Chords use lowercase modifiers joined by '+':",
            " cmd (or command), shift, alt (or option/opt),",
            " ctrl (or control), plus a single key (e.g. 'f', 'return', 'up').",
            " A dispatch modifier (cmd or ctrl) is required.",
            " Reserved system chords (cmd+a/c/v/z, cmd+w, cmd+tab, ...)",
            " and plain text input are rejected."
        ].joined()
    }

    nonisolated private static var tasksComment: String {
        [
            "Pine tasks. Add entries to the \"tasks\" array below.",
            " Each task runs a shell command.",
            " Fields: id (unique, used by keybindings), label (menu text),",
            " command (shell string), scope (activeFile or project,",
            " default activeFile), replaces_file_content (default false:",
            " stdout replaces the active file), require_confirmation",
            " (default auto: destructive commands like rm/chmod/dd/diskutil",
            " prompt)."
        ].joined()
    }

    /// Emits a starter document with a JSON-encoded `_comment` and an empty
    /// `arrayKey` array. Always valid JSON.
    nonisolated private static func starterDocument(
        comment: String,
        arrayKey: String
    ) -> String {
        let encoded = Self.encodeJSONString(comment)
        return """
        {
          "_comment": "\(encoded)",
          "\(arrayKey)": [
          ]
        }
        """
    }

    /// Returns the escaped inner content of a JSON string literal (no
    /// surrounding quotes), so it can be interpolated into a `"...\(encoded)"`
    /// template. Uses JSONEncoder for RFC 8259-compliant escaping.
    nonisolated private static func encodeJSONString(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let quoted = String(data: data, encoding: .utf8) else {
            // Fallback: escape only quotes and backslashes.
            return value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
        }
        // `quoted` is `"…"` — strip the surrounding quotes, keep escapes.
        return String(quoted.dropFirst().dropLast())
    }

    // MARK: - Failure presentation

    private static func presentCreationFailure(
        _ file: UserConfigurationFile,
        error: Error
    ) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            localized: "userConfig.starterCreateFailed.title",
            defaultValue: "Couldn’t create configuration file"
        )
        alert.informativeText = String(
            localized: "userConfig.starterCreateFailed.message",
            defaultValue: "Pine could not create the \(file.rawValue) configuration file: \(error.localizedDescription)"
        )
        alert.addButton(withTitle: NSLocalizedString(
            "userConfig.ok",
            value: "OK",
            comment: "Dismiss button"
        ))
        alert.runModal()
    }
}
