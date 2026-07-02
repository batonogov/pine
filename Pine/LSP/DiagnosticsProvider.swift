//
//  DiagnosticsProvider.swift
//  Pine
//
//  Phase 1 of LSP support (issue #1010).
//
//  Maps LSP `Diagnostic` values into Pine's existing `ValidationDiagnostic`
//  model so they flow through the same gutter-icon + popover machinery that
//  config validators already use (#679 / #781). Also aggregates diagnostics
//  across all open documents for the Problems panel.
//

import Foundation

// MARK: - LSP position / range

/// An LSP `Position` (0-based line and character).
nonisolated struct LSPPosition: Equatable, Sendable {
    let line: Int
    let character: Int

    /// Initialises from the raw JSON dictionary of an LSP `Position`.
    init?(json: Any) {
        guard let dict = json as? [String: Any] else { return nil }
        guard let line = dict["line"] as? Int,
              let character = dict["character"] as? Int else { return nil }
        self.line = line
        self.character = character
    }

    init(line: Int, character: Int) {
        self.line = line
        self.character = character
    }
}

/// An LSP `Range` (start and end positions, 0-based).
nonisolated struct LSPRange: Equatable, Sendable {
    let start: LSPPosition
    let end: LSPPosition

    init?(json: Any) {
        guard let dict = json as? [String: Any] else { return nil }
        guard let start = LSPPosition(json: dict["start"] ?? [:]),
              let end = LSPPosition(json: dict["end"] ?? [:]) else { return nil }
        self.start = start
        self.end = end
    }

    init(start: LSPPosition, end: LSPPosition) {
        self.start = start
        self.end = end
    }
}

// MARK: - LSP severity

/// The LSP `DiagnosticSeverity` enum (1-based per spec).
nonisolated enum LSPDiagnosticSeverity: Int, Sendable, Equatable {
    case error = 1
    case warning = 2
    case information = 3
    case hint = 4

    /// Maps to Pine's existing validation severity, falling back to `.info`.
    var validationSeverity: ValidationSeverity {
        switch self {
        case .error: return .error
        case .warning: return .warning
        case .information, .hint: return .info
        }
    }

    /// Initialises from the raw JSON number value. `nil` if the value is
    /// absent or out of range — servers may omit severity.
    init?(raw: Any?) {
        guard let value = raw as? Int,
              let severity = LSPDiagnosticSeverity(rawValue: value) else { return nil }
        self = severity
    }
}

// MARK: - LSP Diagnostic

/// A single LSP `Diagnostic`.
nonisolated struct LSPDiagnostic: Equatable, Sendable {
    let range: LSPRange
    let severity: LSPDiagnosticSeverity?
    let code: String?
    let source: String?
    let message: String

    /// Initialises from the raw JSON dictionary of an LSP `Diagnostic`.
    /// Returns `nil` if required fields (`range`, `message`) are missing.
    init?(json: Any) {
        guard let dict = json as? [String: Any] else { return nil }
        guard let range = LSPRange(json: dict["range"] ?? [:]) else { return nil }
        guard let message = dict["message"] as? String else { return nil }
        self.range = range
        self.severity = LSPDiagnosticSeverity(raw: dict["severity"])
        // `code` may be a string or a number.
        if let codeStr = dict["code"] as? String {
            self.code = codeStr
        } else if let codeNum = dict["code"] as? Int {
            self.code = String(codeNum)
        } else {
            self.code = nil
        }
        self.source = dict["source"] as? String
        self.message = message
    }
}

// MARK: - publishDiagnostics notification

/// The `textDocument/publishDiagnostics` notification payload.
nonisolated struct LSPDiagnosticsNotification: Equatable, Sendable {
    let uri: String
    let diagnostics: [LSPDiagnostic]

    /// Initialises from the raw `params` dictionary. Returns `nil` if the URI
    /// is missing (diagnostics may be an empty array — that's valid and means
    /// "no problems for this file").
    init?(params: [String: Any]) {
        guard let uri = params["uri"] as? String else { return nil }
        self.uri = uri
        let rawArray = (params["diagnostics"] as? [Any]) ?? []
        self.diagnostics = rawArray.compactMap { LSPDiagnostic(json: $0) }
    }

    /// Convenience constructor for tests / fixtures.
    init(uri: String, diagnostics: [LSPDiagnostic]) {
        self.uri = uri
        self.diagnostics = diagnostics
    }
}

// MARK: - Diagnostic mapping

/// Pure mapping from LSP diagnostics to Pine's `ValidationDiagnostic` model.
///
/// LSP positions are 0-based; Pine's gutter/validator model is 1-based for
/// lines. Columns are preserved as-is (1-based from the user's perspective)
/// since the existing `ValidationDiagnostic.column` is `Int?`.
///
/// `nonisolated` because the mapping is pure data work — no actor isolation
/// needed, and it is invoked from background diagnostic callbacks.
nonisolated enum DiagnosticMapper {

    /// Converts a single LSP diagnostic into a Pine validation diagnostic.
    /// The `source` falls back to `"lsp"` when the server omits it.
    static func map(_ lsp: LSPDiagnostic, fallbackSource: String = "lsp") -> ValidationDiagnostic {
        // LSP line is 0-based; Pine lines are 1-based.
        let pineLine = lsp.range.start.line + 1
        // LSP character is 0-based; Pine columns are 1-based. Clamp negatives defensively.
        let pineColumn = max(0, lsp.range.start.character) + 1
        return ValidationDiagnostic(
            line: pineLine,
            column: pineColumn,
            message: lsp.message,
            severity: (lsp.severity ?? .information).validationSeverity,
            source: lsp.source ?? fallbackSource
        )
    }

    /// Converts a whole `publishDiagnostics` notification into an array of
    /// Pine validation diagnostics for that document.
    static func map(_ notification: LSPDiagnosticsNotification) -> [ValidationDiagnostic] {
        notification.diagnostics.map { map($0) }
    }
}
