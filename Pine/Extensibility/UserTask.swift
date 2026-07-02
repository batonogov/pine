//
//  UserTask.swift
//  Pine
//
//  Lightweight extensibility (issue #1009): user-defined external commands
//  ("tasks") invokable on the active file or project, bindable to shortcuts.
//  Generalizes the format-on-save mechanism (ExternalFileFormatter) into a
//  configurable, user-facing commands system.
//

import Foundation

/// A single user-defined task loaded from `tasks.json`.
///
/// A task is an external CLI command (à la Sublime/Nova build systems) that
/// can run on the active file or the project root. The `command` is invoked
/// through a shell; `workingDirectoryScope` and `stdinScope` decide where it
/// runs and what it receives on stdin.
nonisolated struct UserTask: Codable, Sendable, Identifiable, Equatable {
    /// Stable identifier used by keybindings (e.g. `"format-terraform"`).
    let id: String
    /// Human-readable label shown in the Tasks menu.
    let label: String
    /// Shell command to execute (e.g. `"terraform fmt -"`).
    let command: String
    /// Where the command runs.
    var scope: Scope = .activeFile
    /// Whether the command's stdout replaces the active file's content.
    /// When `false` (default), the command output is shown in a toast but the
    /// file is left untouched.
    var replacesFileContent: Bool = false

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
    }

    init(
        id: String,
        label: String,
        command: String,
        scope: Scope = .activeFile,
        replacesFileContent: Bool = false
    ) {
        self.id = id
        self.label = label
        self.command = command
        self.scope = scope
        self.replacesFileContent = replacesFileContent
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        command = try c.decode(String.self, forKey: .command)
        scope = try c.decodeIfPresent(Scope.self, forKey: .scope) ?? .activeFile
        replacesFileContent = try c.decodeIfPresent(Bool.self, forKey: .replacesFileContent) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(label, forKey: .label)
        try c.encode(command, forKey: .command)
        try c.encode(scope, forKey: .scope)
        try c.encode(replacesFileContent, forKey: .replacesFileContent)
    }
}

/// A parsed `tasks.json` document.
nonisolated struct UserTasksDocument: Codable, Sendable, Equatable {
    let tasks: [UserTask]
}

/// Loads and holds the user's task definitions.
///
/// `tasks.json` is optional — a missing or unreadable file yields an empty
/// registry (no tasks in the menu). The loader is `nonisolated` and can be
/// queried from any thread; the parsed array is immutable and `Sendable`.
nonisolated final class UserTaskRegistry: @unchecked Sendable {
    /// Loaded tasks in declaration order.
    private(set) var tasks: [UserTask] = []

    /// Number of loaded tasks (convenience for tests/UI).
    var count: Int { tasks.count }

    /// Loads tasks from `tasks.json` at the given URL.
    /// A missing file is not an error — it simply means no user tasks.
    @discardableResult
    func load(from url: URL) -> [UserTask] {
        guard let data = try? Data(contentsOf: url) else {
            tasks = []
            return []
        }

        // Try the documented `{"tasks": [...]}` envelope first, then fall back
        // to a bare top-level array for ergonomics.
        if let doc = try? JSONDecoder().decode(UserTasksDocument.self, from: data) {
            tasks = doc.tasks
            return doc.tasks
        }
        if let array = try? JSONDecoder().decode([UserTask].self, from: data) {
            tasks = array
            return array
        }

        tasks = []
        return []
    }

    /// Returns the task with the given id, if any.
    func task(forID id: String) -> UserTask? {
        tasks.first { $0.id == id }
    }

    init() {}
}
