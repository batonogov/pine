//
//  UserConfigurationDiagnosticLocalizedTests.swift
//  PineTests
//
//  Issue #1117: verifies every user-configuration diagnostic reason has a
//  non-empty localized description for UI alerts, and that the composed
//  message includes the file and entry provenance.
//

import Foundation
import Testing

@testable import Pine

@Suite("User configuration diagnostics localization")
struct UserConfigDiagnosticLocalizedTests {

    @Test("Every reason has a non-empty localized description")
    func everyReasonLocalizes() {
        let reasons: [UserConfigurationDiagnosticReason] = [
            .unreadable(details: "permission denied"),
            .malformedDocument(details: "unexpected token"),
            .unknownCommand(id: "nope"),
            .unavailableCommand(id: "toggleMinimap"),
            .invalidChord(value: "cmd+hyper+f"),
            .textInputChord(value: "f"),
            .reservedSystemChord(value: "cmd+c"),
            .duplicateChord(value: "cmd+p", firstEntryNumber: 2),
            .duplicateTaskID(id: "lint", firstEntryNumber: 1),
            .emptyTaskID,
            .emptyTaskLabel,
            .emptyTaskCommand,
        ]
        for reason in reasons {
            let text = reason.localizedDescription
            #expect(!text.isEmpty, "localizedDescription empty for \(reason.logDescription)")
            // A localized UI string must never leak the raw log token.
            #expect(!text.contains("could not read file"))
        }
    }

    @Test("Localized message carries entry provenance for entry-level failures")
    func messageCarriesEntryProvenance() {
        let url = URL(fileURLWithPath: "/tmp/keybindings.json")
        let entry = UserConfigurationDiagnostic(
            file: .keybindings,
            fileURL: url,
            entryNumber: 3,
            reason: .duplicateChord(value: "cmd+p", firstEntryNumber: 1)
        )
        let message = entry.localizedMessage
        #expect(message.contains("3"))
        #expect(!message.isEmpty)
    }

    @Test("Localized message omits entry prefix for document-level failures")
    func messageOmitsEntryForDocumentLevel() {
        let url = URL(fileURLWithPath: "/tmp/tasks.json")
        let document = UserConfigurationDiagnostic(
            file: .tasks,
            fileURL: url,
            entryNumber: nil,
            reason: .malformedDocument(details: "unexpected eof")
        )
        let message = document.localizedMessage
        #expect(!message.isEmpty)
        // Document-level failures have no entry number, so the localized
        // message must not fabricate one.
        #expect(!message.lowercased().hasPrefix("entry"))
    }

    @Test("Both configuration files are addressable")
    func filesCovered() {
        #expect(UserConfigurationFile.tasks.rawValue == "tasks")
        #expect(UserConfigurationFile.keybindings.rawValue == "keybindings")
    }
}
