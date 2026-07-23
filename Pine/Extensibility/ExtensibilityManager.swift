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

typealias UserTaskConfigurationLoader = @Sendable (
    URL
) async -> UserConfigurationCandidate<UserTask>

typealias UserKeybindingConfigurationLoader = @Sendable (
    URL
) async -> UserConfigurationCandidate<ResolvedUserKeybinding>

/// Owns the shared `UserTaskRegistry` and `UserKeybindingRegistry`,
/// loading both from disk at startup.
///
/// Parsing and file I/O run off-main. Validated candidates are committed to
/// both registries on the main actor, with a generation guard so an older
/// reload cannot overwrite a newer request.
@MainActor
final class ExtensibilityManager {
    static let shared = ExtensibilityManager(
        tasksFileURL: UserConfigurationPaths.userTasksFile,
        keybindingsFileURL: UserConfigurationPaths.userKeybindingsFile
    )

    let tasks = UserTaskRegistry()
    let keybindings = UserKeybindingRegistry()
    private let tasksFileURL: URL
    private let keybindingsFileURL: URL
    private let taskLoader: UserTaskConfigurationLoader
    private let keybindingLoader: UserKeybindingConfigurationLoader
    private var reloadGeneration = 0
    private(set) var lastReloadReport: ExtensibilityReloadReport?

    init(
        tasksFileURL: URL,
        keybindingsFileURL: URL,
        taskLoader: @escaping UserTaskConfigurationLoader = {
            await UserTaskRegistry.prepareLoad(from: $0)
        },
        keybindingLoader: @escaping UserKeybindingConfigurationLoader = {
            await UserKeybindingRegistry.prepareLoad(from: $0)
        }
    ) {
        self.tasksFileURL = tasksFileURL
        self.keybindingsFileURL = keybindingsFileURL
        self.taskLoader = taskLoader
        self.keybindingLoader = keybindingLoader
    }

    /// (Re)loads tasks and keybindings from their config files.
    /// Missing files are silently treated as "no config" — not an error.
    /// Returns `nil` when a newer reload supersedes this request.
    @discardableResult
    func reload() async -> ExtensibilityReloadReport? {
        reloadGeneration &+= 1
        let generation = reloadGeneration
        let taskLoader = taskLoader
        let keybindingLoader = keybindingLoader
        let tasksFileURL = tasksFileURL
        let keybindingsFileURL = keybindingsFileURL

        async let taskCandidate = taskLoader(tasksFileURL)
        async let keybindingCandidate = keybindingLoader(keybindingsFileURL)
        let candidates = await (taskCandidate, keybindingCandidate)

        guard reloadGeneration == generation, !Task.isCancelled else {
            return nil
        }

        let taskReport = tasks.apply(candidates.0, from: tasksFileURL)
        let keybindingReport = keybindings.apply(
            candidates.1,
            from: keybindingsFileURL
        )
        let report = ExtensibilityReloadReport(
            tasks: taskReport,
            keybindings: keybindingReport
        )
        lastReloadReport = report
        Self.log(report)
        return report
    }

    private static func log(_ report: ExtensibilityReloadReport) {
        Logger.extensibility.info(
            """
            Extensibility: \(report.tasks.activeEntryCount) tasks, \
            \(report.keybindings.activeEntryCount) keybindings
            """
        )
        for diagnostic in report.diagnostics {
            Logger.extensibility.error(
                "Extensibility configuration rejected: \(diagnostic.logDescription)"
            )
        }
    }
}
