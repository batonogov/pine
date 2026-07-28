//
//  UserConfigurationPaths.swift
//  Pine
//
//  Lightweight extensibility (issue #1009): centralizes the filesystem
//  locations where Pine reads user-supplied configuration — custom grammars,
//  tasks, and keybindings. Keeping the paths in one place makes them testable
//  and discoverable.
//

import Foundation

/// Filesystem locations for user-supplied configuration.
///
/// Everything lives under `~/Library/Application Support/Pine/`, matching how
/// the rest of the app stores persistent data (contexts, recovery snapshots).
/// All accessors are `nonisolated` and safe to call from any thread.
nonisolated enum UserConfigurationPaths {
    /// `~/Library/Application Support/Pine/`
    static var applicationSupportDirectory: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pine", isDirectory: true)
    }

    /// `…/Pine/Grammars/` — drop-in JSON grammar files, merged with the
    /// bundled grammars at startup. User grammars override bundled ones for
    /// overlapping extensions / file names.
    static var userGrammarsDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("Grammars", isDirectory: true)
    }

    /// `…/Pine/tasks.json` — user-defined external commands/tasks.
    static var userTasksFile: URL {
        // A narrowly gated UI-test hook keeps task execution scenarios
        // deterministic without reading or overwriting a developer's real
        // configuration. `--reset-state` is already Pine's UI-test launch
        // mode; the environment override is ignored for normal launches.
        if CommandLine.arguments.contains("--reset-state"),
           let path = ProcessInfo.processInfo.environment[
               "PINE_USER_TASKS_FILE"
           ],
           !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: false)
        }
        return applicationSupportDirectory.appendingPathComponent(
            "tasks.json",
            isDirectory: false
        )
    }

    /// `…/Pine/keybindings.json` — user-defined command → key mappings.
    static var userKeybindingsFile: URL {
        applicationSupportDirectory.appendingPathComponent("keybindings.json", isDirectory: false)
    }
}
