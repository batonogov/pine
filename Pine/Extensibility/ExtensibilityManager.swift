//
//  ExtensibilityManager.swift
//  Pine
//
//  Lightweight extensibility (issue #1009): central coordinator that loads
//  user-supplied tasks and keybindings at startup and owns the shared
//  registries. User grammars are loaded separately by `SyntaxHighlighter`
//  (they need rule compilation); this manager covers the config-file side.
//

import Foundation
import os

/// Owns the shared `UserTaskRegistry` and `UserKeybindingRegistry`,
/// loading both from disk at startup.
///
/// `@MainActor` because it's created and queried from the app/UI layer.
/// The underlying registries are `nonisolated` + `Sendable`-safe.
@MainActor
final class ExtensibilityManager {
    static let shared = ExtensibilityManager()

    let tasks = UserTaskRegistry()
    let keybindings = UserKeybindingRegistry()

    private init() {
        reload()
    }

    /// (Re)loads tasks and keybindings from their config files.
    /// Missing files are silently treated as "no config" — not an error.
    func reload() {
        let loadedTasks = tasks.load(from: UserConfigurationPaths.userTasksFile)
        let loadedBindings = keybindings.load(from: UserConfigurationPaths.userKeybindingsFile)

        Logger.extensibility.info(
            "Extensibility: \(loadedTasks.count) tasks, \(loadedBindings.count) keybindings"
        )
    }
}
