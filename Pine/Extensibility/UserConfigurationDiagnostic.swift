//
//  UserConfigurationDiagnostic.swift
//  Pine
//
//  Typed diagnostics and load reports for user-owned JSON configuration.
//  These values keep parsing independent from presentation so a later UI can
//  localize errors without scraping log strings.
//

import Foundation

/// Identifies one of Pine's user-editable JSON configuration files.
nonisolated enum UserConfigurationFile: String, Sendable, Equatable {
    case tasks
    case keybindings
}

/// A structured reason why a user configuration could not be applied.
nonisolated enum UserConfigurationDiagnosticReason: Sendable, Equatable {
    case unreadable(details: String)
    case malformedDocument(details: String)
    case unknownCommand(id: String)
    case unavailableCommand(id: String)
    case invalidChord(value: String)
    case textInputChord(value: String)
    case reservedSystemChord(value: String)
    case duplicateChord(value: String, firstEntryNumber: Int)
    case duplicateCommand(id: String, firstEntryNumber: Int)
    case duplicateTaskID(id: String, firstEntryNumber: Int)
    case emptyTaskID
    case emptyTaskLabel
    case emptyTaskCommand

    /// Stable, non-localized text for logs and diagnostics during development.
    var logDescription: String {
        switch self {
        case .unreadable(let details):
            "could not read file: \(details)"
        case .malformedDocument(let details):
            "invalid JSON document: \(details)"
        case .unknownCommand(let id):
            "unknown command id '\(id)'"
        case .unavailableCommand(let id):
            "command id '\(id)' has no safe dispatcher"
        case .invalidChord(let value):
            "invalid key chord '\(value)'"
        case .textInputChord(let value):
            "key chord '\(value)' would capture normal text input"
        case .reservedSystemChord(let value):
            "key chord '\(value)' is reserved by macOS or text editing"
        case .duplicateChord(let value, let firstEntryNumber):
            "key chord '\(value)' duplicates entry \(firstEntryNumber)"
        case .duplicateCommand(let id, let firstEntryNumber):
            "command id '\(id)' duplicates entry \(firstEntryNumber)"
        case .duplicateTaskID(let id, let firstEntryNumber):
            "task id '\(id)' duplicates entry \(firstEntryNumber)"
        case .emptyTaskID:
            "task id is empty"
        case .emptyTaskLabel:
            "task label is empty"
        case .emptyTaskCommand:
            "task command is empty"
        }
    }
}

/// One actionable configuration problem, including its source and entry.
nonisolated struct UserConfigurationDiagnostic: Sendable, Equatable {
    let file: UserConfigurationFile
    let fileURL: URL
    /// One-based entry number, or `nil` for file/document-level failures.
    let entryNumber: Int?
    let reason: UserConfigurationDiagnosticReason

    var logDescription: String {
        let entry = entryNumber.map { ", entry \($0)" } ?? ""
        return "\(fileURL.path)\(entry): \(reason.logDescription)"
    }
}

/// Whether a configuration file was applied, absent, or rejected.
nonisolated enum UserConfigurationLoadOutcome: Sendable, Equatable {
    /// The file parsed and validated successfully, then replaced the registry.
    case loaded
    /// The file does not exist; an empty configuration replaced the registry.
    case missing
    /// The file could not be read, parsed, or validated; the registry was kept.
    case rejected
}

/// Result of loading one user configuration file.
nonisolated struct UserConfigurationLoadReport: Sendable, Equatable {
    let file: UserConfigurationFile
    let fileURL: URL
    let outcome: UserConfigurationLoadOutcome
    /// Number of entries active after this load attempt.
    let activeEntryCount: Int
    let diagnostics: [UserConfigurationDiagnostic]

    var wasApplied: Bool {
        outcome != .rejected
    }
}

/// Immutable result of parsing and validating a configuration file off-main.
///
/// Registries apply candidates only after returning to the main actor, keeping
/// blocking file I/O out of the UI path while preserving all-or-nothing swaps.
nonisolated enum UserConfigurationCandidate<Entry: Sendable>: Sendable {
    case loaded([Entry])
    case missing
    case rejected([UserConfigurationDiagnostic])
}

/// Combined result of reloading both extensibility configuration files.
nonisolated struct ExtensibilityReloadReport: Sendable, Equatable {
    let tasks: UserConfigurationLoadReport
    let keybindings: UserConfigurationLoadReport

    var diagnostics: [UserConfigurationDiagnostic] {
        tasks.diagnostics + keybindings.diagnostics
    }
}
