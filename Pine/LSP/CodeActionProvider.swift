//
//  CodeActionProvider.swift
//  Pine
//
//  Phase 4 of LSP support (issue #1013, parent #994).
//
//  Value types for `textDocument/codeAction`:
//    • `LSPCodeAction` — a single code action (quick fix, refactoring,
//      source action) with optional `WorkspaceEdit` and/or `Command`.
//    • `LSPCommand` — a command the server suggests executing.
//    • `LSPCodeActionKind` — the LSP kind enum (quickfix, refactor, etc.).
//    • `LSPCodeActionResponse` — the server response (an array of
//      `CodeAction` and/or `Command` objects).
//
//  All types are `nonisolated` + `Sendable` so they can cross the background
//  JSON-RPC queue → main-actor boundary without Swift 6 strict-concurrency
//  errors. This mirrors the Phase 1/2/3 value types (`LSPPosition`,
//  `LSPRange`, `LSPDiagnostic`, `LSPHover`, `LSPDefinitionResponse`,
//  `LSPCompletionItem`) in `DiagnosticsProvider.swift`,
//  `HoverAndDefinitionProvider.swift`, and `CompletionProvider.swift`.
//

import Foundation

// MARK: - Code action kind

/// The LSP `CodeActionKind` enum, represented as a string per spec.
///
/// `nonisolated` because this is pure data with no actor surface. Without
/// `nonisolated`, the project-wide `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`
/// would make the enum implicitly `@MainActor` and the value-type decoder
/// would not compile when called from a background JSON-RPC callback.
nonisolated enum LSPCodeActionKind: String, Sendable, Equatable {
    case quickFix = "quickfix"
    case refactor = "refactor"
    case refactorExtract = "refactor.extract"
    case refactorInline = "refactor.inline"
    case refactorRewrite = "refactor.rewrite"
    case source = "source"
    case sourceOrganizeImports = "source.organizeImports"
    case sourceFixAll = "source.fixAll"

    /// Initialises from the raw JSON string value. Returns `nil` when the
    /// value is absent or an unrecognised kind — servers may use custom kinds.
    init?(raw: Any?) {
        guard let value = raw as? String else { return nil }
        self.init(rawValue: value)
    }

    /// An SF Symbol name for this kind, used by the menu. Reuses the icon
    /// vocabulary from elsewhere in Pine for visual consistency.
    var symbolName: String {
        switch self {
        case .quickFix:               return "wrench.and.screwdriver"
        case .refactor:               return "arrow.triangle.swap"
        case .refactorExtract:        return "scissors"
        case .refactorInline:         return "arrow.merge"
        case .refactorRewrite:        return "pencil.and.outline"
        case .source:                 return "doc.text"
        case .sourceOrganizeImports:  return "list.bullet.indent"
        case .sourceFixAll:           return "checkmark.circle"
        }
    }
}

// MARK: - Command

/// An LSP `Command` — a title + command identifier + optional arguments.
///
/// The server may return a `Command` instead of a `CodeAction` (or a
/// `CodeAction` with a `command` but no `edit`). Pine presents the title in
/// the menu and, on selection, sends `workspace/executeCommand` if the
/// command has no pre-attached `edit`.
nonisolated struct LSPCommand: @unchecked Sendable, Identifiable {
    /// Stable identifier for menu identity (derived from `command` + `title`).
    let id: String
    /// Human-readable title shown in the menu.
    let title: String
    /// The command identifier (server-defined).
    let command: String
    /// Optional arguments passed to `workspace/executeCommand`.
    /// Stored as raw JSON string to satisfy Sendable.
    let arguments: String?

    /// Initialises from the raw JSON dictionary of a `Command`.
    /// Returns `nil` when `title` or `command` is missing.
    init?(json: Any) {
        guard let dict = json as? [String: Any] else { return nil }
        guard let title = dict["title"] as? String, !title.isEmpty else { return nil }
        guard let command = dict["command"] as? String, !command.isEmpty else { return nil }
        self.title = title
        self.command = command
        if let args = dict["arguments"] {
            self.arguments = (try? JSONSerialization.data(withJSONObject: args))
                .flatMap { String(data: $0, encoding: .utf8) }
        } else {
            self.arguments = nil
        }
        self.id = "\(command)\u{0}\(title)"
    }

    /// Test/fixture convenience constructor.
    init(title: String, command: String, arguments: String? = nil) {
        self.title = title
        self.command = command
        self.arguments = arguments
        self.id = "\(command)\u{0}\(title)"
    }
}

// MARK: - Code action

/// A single `CodeAction` from `textDocument/codeAction`.
///
/// Per the LSP spec, a `CodeAction` has a `title`, an optional `kind`, an
/// optional `edit` (`WorkspaceEdit`), and/or an optional `command`. When the
/// user selects the action, Pine first applies `edit` (if present) and then
/// sends `workspace/executeCommand` for `command` (if present).
///
/// The `edit` is stored as the raw `LSPWorkspaceEdit` value type (defined in
/// `RenameProvider.swift`) so it can be applied by the same trusted path that
/// rename uses.
nonisolated struct LSPCodeAction: @unchecked Sendable, Identifiable {
    /// Stable identifier for menu identity (derived from `title` + `kind`).
    let id: String
    /// Human-readable title shown in the menu.
    let title: String
    /// The kind of code action. `nil` when the server omits it.
    let kind: LSPCodeActionKind?
    /// Whether this action is the preferred fix for its diagnostics.
    let isPreferred: Bool
    /// The workspace edit to apply when the action is selected. `nil` when
    /// the action has only a `command` or is disabled.
    let edit: LSPWorkspaceEdit?
    /// The command to execute when the action is selected. `nil` when the
    /// action has only an `edit`.
    let command: LSPCommand?
    /// The diagnostic messages this action addresses (informational only).
    let diagnostics: [LSPDiagnostic]

    /// Initialises from the raw JSON dictionary of a `CodeAction`.
    /// Returns `nil` when `title` is missing or the entry is a bare `Command`
    /// (which should be handled by `LSPCommand(json:)` instead).
    init?(json: Any) {
        guard let dict = json as? [String: Any] else { return nil }
        guard let title = dict["title"] as? String, !title.isEmpty else { return nil }
        self.title = title
        self.kind = LSPCodeActionKind(raw: dict["kind"])
        self.isPreferred = (dict["isPreferred"] as? Bool) ?? false

        if let editJSON = dict["edit"] {
            self.edit = LSPWorkspaceEdit(json: editJSON)
        } else {
            self.edit = nil
        }

        if let cmdJSON = dict["command"] {
            self.command = LSPCommand(json: cmdJSON)
        } else {
            self.command = nil
        }

        let rawDiag = (dict["diagnostics"] as? [Any]) ?? []
        self.diagnostics = rawDiag.compactMap { LSPDiagnostic(json: $0) }

        let kindStr = (dict["kind"] as? String) ?? ""
        self.id = "\(kindStr)\u{0}\(title)"
    }

    /// Test/fixture convenience constructor.
    init(
        title: String,
        kind: LSPCodeActionKind? = nil,
        isPreferred: Bool = false,
        edit: LSPWorkspaceEdit? = nil,
        command: LSPCommand? = nil,
        diagnostics: [LSPDiagnostic] = []
    ) {
        self.title = title
        self.kind = kind
        self.isPreferred = isPreferred
        self.edit = edit
        self.command = command
        self.diagnostics = diagnostics
        let kindStr = kind?.rawValue ?? ""
        self.id = "\(kindStr)\u{0}\(title)"
    }

    /// `true` when the action carries an `edit` or a `command` — i.e. the
    /// user can actually apply it. Actions with neither are typically
    /// disabled markers.
    var isExecutable: Bool { edit != nil || command != nil }
}

// MARK: - Code action response

/// The result of a `textDocument/codeAction` request.
///
/// The LSP spec allows the server to answer with an array of `CodeAction`
/// and/or `Command` objects, or `null` (no actions available). This type
/// normalises all forms into a single value.
nonisolated struct LSPCodeActionResponse: @unchecked Sendable {
    /// All code actions, in server order.
    let actions: [LSPCodeAction]
    /// All bare commands (when the server returns `Command` objects without
    /// wrapping them in `CodeAction`).
    let commands: [LSPCommand]

    /// `true` when the server returned nothing actionable.
    var isEmpty: Bool { actions.isEmpty && commands.isEmpty }

    /// The total number of menu items.
    var count: Int { actions.count + commands.count }

    /// Initialises from the raw `result` of a code action request.
    init(result: Any?) {
        guard let result else {
            self.actions = []
            self.commands = []
            return
        }

        guard let array = result as? [Any] else {
            self.actions = []
            self.commands = []
            return
        }

        var actions: [LSPCodeAction] = []
        var commands: [LSPCommand] = []
        for element in array {
            // Prefer `CodeAction` (has `title` + `edit`/`command`/`kind`).
            if let action = LSPCodeAction(json: element) {
                actions.append(action)
            } else if let cmd = LSPCommand(json: element) {
                commands.append(cmd)
            }
        }
        self.actions = actions
        self.commands = commands
    }

    init(actions: [LSPCodeAction], commands: [LSPCommand] = []) {
        self.actions = actions
        self.commands = commands
    }
}
