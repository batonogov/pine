//
//  UserTask.swift
//  Pine
//
//  Lightweight extensibility (issue #1009): user-defined external commands
//  ("tasks") invokable on the active file or project.
//  Generalizes the format-on-save mechanism (ExternalFileFormatter) into a
//  configurable, user-facing commands system.
//

import Foundation
import Observation

/// A single user-defined task loaded from `tasks.json`.
///
/// A task is an external CLI command (à la Sublime/Nova build systems) that
/// can run on the active file or the project root. The `command` is invoked
/// through a shell; `workingDirectoryScope` and `stdinScope` decide where it
/// runs and what it receives on stdin.
nonisolated struct UserTask: Codable, Sendable, Identifiable, Equatable {
    /// Stable identifier used to look up and report the task.
    let id: String
    /// Human-readable label shown in the Tasks menu.
    let label: String
    /// Shell command to execute (e.g. `"terraform fmt -"`).
    let command: String
    /// Where the command runs.
    var scope: Scope = .activeFile
    /// Whether active-file content is sent to the command's standard input.
    /// Command output is reported to the user; it does not currently replace
    /// the file.
    var replacesFileContent: Bool = false
    /// Whether the user must confirm before the task runs.
    ///
    /// When `nil` (the default when omitted from `tasks.json`), the runner
    /// auto-detects: commands that look destructive (contain `rm`, `chmod`,
    /// `dd`, `diskutil`, etc.) default to **requiring** confirmation; benign
    /// commands (lint, format, build) do not.  An explicit `true` / `false`
    /// in the JSON always overrides auto-detection.
    var requireConfirmation: Bool?

    enum Scope: String, Codable, Sendable {
        /// Runs in the active file's directory; the file content is piped to
        /// stdin when `replacesFileContent` is true.
        case activeFile
        /// Runs in the project root; no stdin.
        case project
    }

    enum CodingKeys: String, CodingKey {
        case id, label, command, scope
        // Kept out of the synthesized memberwise init; decoded explicitly below.
        case replacesFileContent = "replaces_file_content"
        case requireConfirmation = "require_confirmation"
    }

    init(
        id: String,
        label: String,
        command: String,
        scope: Scope = .activeFile,
        replacesFileContent: Bool = false,
        requireConfirmation: Bool? = nil
    ) {
        self.id = id
        self.label = label
        self.command = command
        self.scope = scope
        self.replacesFileContent = replacesFileContent
        self.requireConfirmation = requireConfirmation
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        command = try c.decode(String.self, forKey: .command)
        scope = try c.decodeIfPresent(Scope.self, forKey: .scope) ?? .activeFile
        replacesFileContent = try c.decodeIfPresent(Bool.self, forKey: .replacesFileContent) ?? false
        requireConfirmation = try c.decodeIfPresent(Bool.self, forKey: .requireConfirmation)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(label, forKey: .label)
        try c.encode(command, forKey: .command)
        try c.encode(scope, forKey: .scope)
        try c.encode(replacesFileContent, forKey: .replacesFileContent)
        try c.encodeIfPresent(requireConfirmation, forKey: .requireConfirmation)
    }

    /// Resolves whether this task requires user confirmation before running.
    /// An explicit `requireConfirmation` value from `tasks.json` takes
    /// precedence; otherwise the command is inspected for destructive
    /// patterns (rm, chmod, dd, diskutil, etc.).
    func effectiveRequireConfirmation(validator: UserTaskValidator = .default) -> Bool {
        if let explicit = requireConfirmation {
            return explicit
        }
        return validator.isDestructive(command)
    }
}

/// A parsed `tasks.json` document.
nonisolated struct UserTasksDocument: Codable, Sendable, Equatable {
    let tasks: [UserTask]
}

/// Loads and holds the user's task definitions.
///
/// `tasks.json` is optional — a missing file yields an empty registry. An
/// unreadable, malformed, or invalid file is rejected atomically, preserving
/// the last valid task list. Parsing happens off-main; registry swaps stay on
/// the main actor so readers never observe a partial update.
@MainActor
@Observable
final class UserTaskRegistry {
    /// Loaded tasks in declaration order.
    private(set) var tasks: [UserTask] = []

    /// Number of loaded tasks (convenience for tests/UI).
    var count: Int { tasks.count }

    /// Loads tasks from `tasks.json` at the given URL.
    /// A missing file is not an error — it applies an empty task list.
    /// Invalid files leave the active registry unchanged.
    @discardableResult
    func load(from url: URL) async -> UserConfigurationLoadReport {
        let candidate = await Self.prepareLoad(from: url)
        return apply(candidate, from: url)
    }

    /// Reads, decodes, and validates a candidate without touching actor state.
    nonisolated static func prepareLoad(
        from url: URL
    ) async -> UserConfigurationCandidate<UserTask> {
        await runOnBackground(qos: .utility) {
            readCandidate(from: url)
        }
    }

    /// Commits a prepared candidate on the main actor.
    func apply(
        _ candidate: UserConfigurationCandidate<UserTask>,
        from url: URL
    ) -> UserConfigurationLoadReport {
        let outcome: UserConfigurationLoadOutcome
        let diagnostics: [UserConfigurationDiagnostic]
        switch candidate {
        case .loaded(let decoded):
            tasks = decoded
            outcome = .loaded
            diagnostics = []
        case .missing:
            tasks = []
            outcome = .missing
            diagnostics = []
        case .rejected(let problems):
            outcome = .rejected
            diagnostics = problems
        }

        return UserConfigurationLoadReport(
            file: .tasks,
            fileURL: url,
            outcome: outcome,
            activeEntryCount: tasks.count,
            diagnostics: diagnostics
        )
    }

    /// Returns the task with the given id, if any.
    func task(forID id: String) -> UserTask? {
        tasks.first { $0.id == id }
    }

    init() {}

    private enum DocumentError: Error {
        case unsupportedTopLevel
    }

    nonisolated private static func readCandidate(
        from url: URL
    ) -> UserConfigurationCandidate<UserTask> {
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

        let decoded: [UserTask]
        do {
            decoded = try Self.decodeDocument(from: data)
        } catch {
            return .rejected([
                diagnostic(
                    for: url,
                    entryNumber: nil,
                    reason: .malformedDocument(details: String(describing: error))
                )
            ])
        }

        let diagnostics = Self.validate(decoded, from: url)
        guard diagnostics.isEmpty else {
            return .rejected(diagnostics)
        }

        return .loaded(decoded)
    }

    nonisolated private static func decodeDocument(from data: Data) throws -> [UserTask] {
        let object = try JSONSerialization.jsonObject(with: data)
        let decoder = JSONDecoder()
        if object is [Any] {
            return try decoder.decode([UserTask].self, from: data)
        }
        if object is [String: Any] {
            return try decoder.decode(UserTasksDocument.self, from: data).tasks
        }
        throw DocumentError.unsupportedTopLevel
    }

    nonisolated private static func validate(
        _ decoded: [UserTask],
        from url: URL
    ) -> [UserConfigurationDiagnostic] {
        var diagnostics: [UserConfigurationDiagnostic] = []
        var firstEntryForID: [String: Int] = [:]

        for (index, task) in decoded.enumerated() {
            let entryNumber = index + 1
            if task.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                diagnostics.append(diagnostic(
                    for: url,
                    entryNumber: entryNumber,
                    reason: .emptyTaskID
                ))
            }
            if task.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                diagnostics.append(diagnostic(
                    for: url,
                    entryNumber: entryNumber,
                    reason: .emptyTaskLabel
                ))
            }
            if task.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                diagnostics.append(diagnostic(
                    for: url,
                    entryNumber: entryNumber,
                    reason: .emptyTaskCommand
                ))
            }

            if let firstEntryNumber = firstEntryForID[task.id] {
                diagnostics.append(diagnostic(
                    for: url,
                    entryNumber: entryNumber,
                    reason: .duplicateTaskID(
                        id: task.id,
                        firstEntryNumber: firstEntryNumber
                    )
                ))
            } else {
                firstEntryForID[task.id] = entryNumber
            }
        }
        return diagnostics
    }

    nonisolated private static func diagnostic(
        for url: URL,
        entryNumber: Int?,
        reason: UserConfigurationDiagnosticReason
    ) -> UserConfigurationDiagnostic {
        UserConfigurationDiagnostic(
            file: .tasks,
            fileURL: url,
            entryNumber: entryNumber,
            reason: reason
        )
    }
}
