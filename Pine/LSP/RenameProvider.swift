//
//  RenameProvider.swift
//  Pine
//
//  Phase 4 of LSP support (issue #1013, parent #994).
//
//  Value types and logic for `textDocument/rename` and `WorkspaceEdit`
//  application:
//    • `LSPWorkspaceEdit` — the server response (supports both
//      `documentChanges` and legacy `changes` forms).
//    • `LSPTextEdit` — a single edit within a document (range + new text).
//    • `LSPOperatedFile` — a file + its edits, normalised from
//      `TextDocumentEdit`, `CreateFile`, `RenameFile`, `DeleteFile`.
//    • `WorkspaceEditApplier` — a pure function that applies a list of
//      `LSPOperatedFile` edits to an in-memory text store, transactionally.
//
//  The actual I/O (opening tabs, writing to disk) is done by the
//  `@MainActor @Observable` `LSPManager` which calls the pure applier for
//  each affected file. The applier itself is pure data logic, testable
//  without any UI.
//
//  All types are `nonisolated` + `Sendable` so they can cross the background
//  JSON-RPC queue → main-actor boundary without Swift 6 strict-concurrency
//  errors.
//

import Foundation

// MARK: - Text edit

/// An LSP `TextEdit` — a range replacement within a single document.
///
/// `nonisolated` + `Sendable` because this is pure data produced on a
/// background JSON-RPC callback and consumed on the main actor.
nonisolated struct LSPTextEdit: Equatable, Sendable {
    /// The range to replace (LSP 0-based positions).
    let range: LSPRange
    /// The text to insert in place of the range.
    let newText: String

    /// Initialises from the raw JSON dictionary of a `TextEdit`.
    /// Returns `nil` when `range` or `newText` is missing.
    init?(json: Any) {
        guard let dict = json as? [String: Any] else { return nil }
        guard let range = LSPRange(json: dict["range"] ?? [:]) else { return nil }
        guard let newText = dict["newText"] as? String else { return nil }
        self.range = range
        self.newText = newText
    }

    init(range: LSPRange, newText: String) {
        self.range = range
        self.newText = newText
    }
}

// MARK: - Document change kind

/// The kind of `DocumentChange` a `LSPOperatedFile` represents.
///
/// `nonisolated` because this is pure data with no actor surface.
nonisolated enum LSPDocumentChangeKind: Sendable, Equatable {
    /// Edit an existing file (one or more `TextEdit`s).
    case edit
    /// Create a new file.
    case create
    /// Rename a file (old → new URL).
    case rename
    /// Delete a file.
    case delete
}

// MARK: - Operated file

/// A single file + its edits, normalised from the various
/// `documentChanges` forms (`TextDocumentEdit`, `CreateFile`, `RenameFile`,
/// `DeleteFile`) or the legacy `changes` dictionary.
///
/// `nonisolated` + `Sendable` because this is pure data crossing the
/// background → main-actor boundary.
nonisolated struct LSPOperatedFile: Equatable, Sendable {
    /// The file URI this entry operates on.
    let uri: String
    /// The kind of change.
    let kind: LSPDocumentChangeKind
    /// Text edits to apply (empty for create/rename/delete-only).
    let edits: [LSPTextEdit]
    /// For rename: the new URI. `nil` otherwise.
    let newURI: String?

    /// The file URL, decoded from the URI.
    var url: URL? { URL(string: uri) }

    /// For rename: the new file URL. `nil` otherwise.
    var newURL: URL? {
        guard let newURI else { return nil }
        return URL(string: newURI)
    }

    /// Initialises from a `TextDocumentEdit` JSON dictionary.
    /// `{ "textDocument": { "uri": ..., "version": ... }, "edits": [...] }`
    init?(textDocumentEdit json: Any) {
        guard let dict = json as? [String: Any] else { return nil }
        guard let textDoc = dict["textDocument"] as? [String: Any] else { return nil }
        guard let uri = textDoc["uri"] as? String else { return nil }
        let rawEdits = (dict["edits"] as? [Any]) ?? []
        self.uri = uri
        self.kind = .edit
        self.edits = rawEdits.compactMap { LSPTextEdit(json: $0) }
        self.newURI = nil
    }

    /// Initialises from a legacy `changes` dictionary entry.
    /// Key = URI string, Value = array of `TextEdit`.
    init?(legacyChanges uri: String, edits: Any) {
        guard let rawEdits = edits as? [Any] else { return nil }
        self.uri = uri
        self.kind = .edit
        self.edits = rawEdits.compactMap { LSPTextEdit(json: $0) }
        self.newURI = nil
    }

    /// Initialises from a `CreateFile` JSON dictionary.
    /// `{ "kind": "create", "uri": "..." }`
    init?(createFile json: Any) {
        guard let dict = json as? [String: Any] else { return nil }
        guard (dict["kind"] as? String) == "create" else { return nil }
        guard let uri = dict["uri"] as? String else { return nil }
        self.uri = uri
        self.kind = .create
        self.edits = []
        self.newURI = nil
    }

    /// Initialises from a `RenameFile` JSON dictionary.
    /// `{ "kind": "rename", "oldUri": "...", "newUri": "..." }`
    init?(renameFile json: Any) {
        guard let dict = json as? [String: Any] else { return nil }
        guard (dict["kind"] as? String) == "rename" else { return nil }
        guard let oldURI = dict["oldUri"] as? String else { return nil }
        guard let newURI = dict["newUri"] as? String else { return nil }
        self.uri = oldURI
        self.kind = .rename
        self.edits = []
        self.newURI = newURI
    }

    /// Initialises from a `DeleteFile` JSON dictionary.
    /// `{ "kind": "delete", "uri": "..." }`
    init?(deleteFile json: Any) {
        guard let dict = json as? [String: Any] else { return nil }
        guard (dict["kind"] as? String) == "delete" else { return nil }
        guard let uri = dict["uri"] as? String else { return nil }
        self.uri = uri
        self.kind = .delete
        self.edits = []
        self.newURI = nil
    }

    /// Test/fixture convenience constructor.
    init(uri: String, kind: LSPDocumentChangeKind, edits: [LSPTextEdit] = [], newURI: String? = nil) {
        self.uri = uri
        self.kind = kind
        self.edits = edits
        self.newURI = newURI
    }
}

// MARK: - Workspace edit

/// An LSP `WorkspaceEdit` — the set of changes a code action or rename
/// would apply across zero or more files.
///
/// Per the LSP spec, the server may return either:
///   • `documentChanges`: `[TextDocumentEdit | CreateFile | RenameFile | DeleteFile]`
///   • `changes`: `{ [uri: string]: TextEdit[] }` (legacy form)
///
/// Pine normalises both into a flat `[LSPOperatedFile]` plan, preferring
/// `documentChanges` when present.
nonisolated struct LSPWorkspaceEdit: Equatable, Sendable {
    /// The ordered list of file operations, normalised from whichever form
    /// the server used. Empty when the server returned an empty edit.
    let operatedFiles: [LSPOperatedFile]

    /// `true` when there are no changes to apply.
    var isEmpty: Bool { operatedFiles.isEmpty }

    /// Total number of text edits across all files.
    var totalTextEditCount: Int {
        operatedFiles.reduce(0) { $0 + $1.edits.count }
    }

    /// Initialises from the raw JSON dictionary of a `WorkspaceEdit`.
    /// Returns an empty edit when the input is `nil` or unparseable.
    init(json: Any) {
        guard let dict = json as? [String: Any] else {
            self.operatedFiles = []
            return
        }

        // Prefer `documentChanges` (3.0+) when present.
        if let docChanges = dict["documentChanges"] as? [Any], !docChanges.isEmpty {
            self.operatedFiles = LSPWorkspaceEdit.parseDocumentChanges(docChanges)
            return
        }

        // Fall back to legacy `changes` (2.0).
        if let changes = dict["changes"] as? [String: Any], !changes.isEmpty {
            var files: [LSPOperatedFile] = []
            for (uri, edits) in changes {
                if let operated = LSPOperatedFile(legacyChanges: uri, edits: edits) {
                    files.append(operated)
                }
            }
            self.operatedFiles = files
            return
        }

        self.operatedFiles = []
    }

    init(operatedFiles: [LSPOperatedFile]) {
        self.operatedFiles = operatedFiles
    }

    /// Parses a `documentChanges` array into `[LSPOperatedFile]`,
    /// dispatching each element to the correct initialiser.
    private static func parseDocumentChanges(_ changes: [Any]) -> [LSPOperatedFile] {
        var result: [LSPOperatedFile] = []
        for element in changes {
            guard let dict = element as? [String: Any] else { continue }
            let kindStr = dict["kind"] as? String

            if kindStr == "create", let f = LSPOperatedFile(createFile: element) {
                result.append(f)
            } else if kindStr == "rename", let f = LSPOperatedFile(renameFile: element) {
                result.append(f)
            } else if kindStr == "delete", let f = LSPOperatedFile(deleteFile: element) {
                result.append(f)
            } else if let f = LSPOperatedFile(textDocumentEdit: element) {
                result.append(f)
            }
        }
        return result
    }
}

// MARK: - Workspace edit applier (pure logic)

/// The result of applying a `WorkspaceEdit` to a single file's text.
///
/// `nonisolated` + `Sendable` because this is pure data produced by the
/// applier on a background context.
nonisolated struct WorkspaceEditApplyResult: Sendable, Equatable {
    /// The resulting text after applying all edits, or `nil` when the edit
    /// could not be applied (e.g. range out of bounds).
    let newText: String?
    /// `true` when the application succeeded.
    let success: Bool
    /// Optional error message when `success` is `false`.
    let errorMessage: String?

    init(newText: String) {
        self.newText = newText
        self.success = true
        self.errorMessage = nil
    }

    init(error: String) {
        self.newText = nil
        self.success = false
        self.errorMessage = error
    }
}

/// Pure logic that applies a list of `LSPTextEdit`s to a text string.
///
/// Edits are applied in **reverse order** of their start position (last
/// first) so earlier edits don't shift the offsets of later ones. This is
/// the standard approach for applying multiple non-overlapping text edits
/// to a single string.
///
/// `nonisolated` because the logic is pure data work — no actor isolation
/// needed, and it is testable in isolation.
nonisolated enum WorkspaceEditApplier {

    /// Applies `edits` to `text`, returning the resulting string.
    ///
    /// Edits are sorted by descending start position and applied one by one.
    /// If any edit's range is out of bounds or the edit fails, the function
    /// returns a failure result — the caller must not commit partial state.
    ///
    /// - Parameters:
    ///   - edits: The text edits to apply. Must be non-overlapping (the LSP
    ///     spec guarantees this for server-sent edits).
    ///   - text: The original document text.
    /// - Returns: `.success` with the new text, or `.failure` with a message.
    static func applyEdits(_ edits: [LSPTextEdit], to text: String) -> WorkspaceEditApplyResult {
        guard !edits.isEmpty else {
            return WorkspaceEditApplyResult(newText: text)
        }

        // Sort by descending start position (apply from end to start).
        let sorted = edits.sorted { lhs, rhs in
            if lhs.range.start.line != rhs.range.start.line {
                return lhs.range.start.line > rhs.range.start.line
            }
            return lhs.range.start.character > rhs.range.start.character
        }

        let ns = text as NSString
        var mutable = NSMutableString(string: text)

        for edit in sorted {
            let startOffset = LSPPositionConverter.utf16Offset(
                line: edit.range.start.line,
                character: edit.range.start.character,
                in: text
            )
            let endOffset = LSPPositionConverter.utf16Offset(
                line: edit.range.end.line,
                character: edit.range.end.character,
                in: text
            )

            // Validate bounds.
            guard startOffset >= 0, startOffset <= ns.length,
                  endOffset >= startOffset, endOffset <= ns.length else {
                let desc = "line \(edit.range.start.line):\(edit.range.start.character) – \(edit.range.end.line):\(edit.range.end.character)"
                return WorkspaceEditApplyResult(
                    error: "Edit range out of bounds: \(desc)"
                )
            }

            let range = NSRange(location: startOffset, length: endOffset - startOffset)
            mutable.replaceCharacters(in: range, with: edit.newText)
        }

        return WorkspaceEditApplyResult(newText: mutable as String)
    }

    /// Converts a `WorkspaceEdit` into a list of `(URL, [LSPTextEdit])` pairs
    /// for only the `.edit` operations, sorted by URI for deterministic order.
    ///
    /// Used by rename preview to show what will change in each file.
    static func editPlan(from workspaceEdit: LSPWorkspaceEdit) -> [(url: URL, edits: [LSPTextEdit])] {
        workspaceEdit.operatedFiles
            .filter { $0.kind == .edit && !$0.edits.isEmpty }
            .compactMap { operated in
                guard let url = operated.url else { return nil }
                return (url: url, edits: operated.edits)
            }
            .sorted { $0.url.path < $1.url.path }
    }
}
