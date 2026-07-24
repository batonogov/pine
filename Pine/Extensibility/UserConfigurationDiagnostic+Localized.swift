//
//  UserConfigurationDiagnostic+Localized.swift
//  Pine
//
//  Issue #1117: localized presentation of user-configuration diagnostics.
//  The base `logDescription` stays non-localized for logs and tests; this
//  extension renders the same reasons in the user's language for alerts.
//

import Foundation

extension UserConfigurationDiagnosticReason {
    /// Localized, human-readable explanation suitable for UI alerts.
    var localizedDescription: String {
        switch self {
        case .unreadable(let details):
            String(
                localized: "userConfig.diagnostic.unreadable",
                defaultValue: "The file could not be read (\(details))."
            )
        case .malformedDocument(let details):
            String(
                localized: "userConfig.diagnostic.malformed",
                defaultValue: "The JSON document is invalid (\(details))."
            )
        case .unknownCommand(let id):
            String(
                localized: "userConfig.diagnostic.unknownCommand",
                defaultValue: "“\(id)” is not a known Pine command id."
            )
        case .unavailableCommand(let id):
            String(
                localized: "userConfig.diagnostic.unavailableCommand",
                defaultValue: "“\(id)” has no safe dispatcher and cannot be bound."
            )
        case .invalidChord(let value):
            String(
                localized: "userConfig.diagnostic.invalidChord",
                defaultValue: "“\(value)” is not a valid key chord."
            )
        case .textInputChord(let value):
            String(
                localized: "userConfig.diagnostic.textInputChord",
                defaultValue: "“\(value)” would capture normal text input; a cmd or ctrl modifier is required."
            )
        case .reservedSystemChord(let value):
            String(
                localized: "userConfig.diagnostic.reservedSystemChord",
                defaultValue: "“\(value)” is reserved by macOS or text editing and cannot be captured."
            )
        case .duplicateChord(let value, let firstEntryNumber):
            String(
                localized: "userConfig.diagnostic.duplicateChord",
                defaultValue: "“\(value)” duplicates entry \(firstEntryNumber)."
            )
        case .duplicateCommand(let id, let firstEntryNumber):
            String(
                localized: "userConfig.diagnostic.duplicateCommand",
                defaultValue: "Command id “\(id)” duplicates entry \(firstEntryNumber)."
            )
        case .duplicateTaskID(let id, let firstEntryNumber):
            String(
                localized: "userConfig.diagnostic.duplicateTaskID",
                defaultValue: "Task id “\(id)” duplicates entry \(firstEntryNumber)."
            )
        case .emptyTaskID:
            String(
                localized: "userConfig.diagnostic.emptyTaskID",
                defaultValue: "Task id is empty."
            )
        case .emptyTaskLabel:
            String(
                localized: "userConfig.diagnostic.emptyTaskLabel",
                defaultValue: "Task label is empty."
            )
        case .emptyTaskCommand:
            String(
                localized: "userConfig.diagnostic.emptyTaskCommand",
                defaultValue: "Task command is empty."
            )
        }
    }
}

extension UserConfigurationDiagnostic {
    /// Localized single-line message: `file: entry N — reason` (entry omitted
    /// for document-level failures). Used by the reload alert.
    var localizedMessage: String {
        let entry = entryNumber.map {
            String(
                localized: "userConfig.diagnostic.entryPrefix",
                defaultValue: "entry \($0) — "
            )
        } ?? ""
        return entry + reason.localizedDescription
    }
}
