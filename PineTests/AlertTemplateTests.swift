//
//  AlertTemplateTests.swift
//  PineTests
//
//  Tests for AlertTemplate: template-to-buttons mapping, alert style, and default-button selection.
//

import AppKit
import Testing

@testable import Pine

@MainActor
struct AlertTemplateTests {

    // MARK: - Button labels

    @Test("unsavedChangesSingle has Save / Don't Save / Cancel")
    func unsavedChangesSingleButtons() {
        let template = AlertTemplate.unsavedChangesSingle
        let alert = template.makeAlert(messageText: "Test", informativeText: "Info")
        let buttons = alert.buttons
        #expect(buttons.count == 3)
        #expect(buttons[0].title == Strings.dialogSave)
        #expect(buttons[1].title == Strings.dialogDontSave)
        #expect(buttons[2].title == Strings.dialogCancel)
    }

    @Test("unsavedChangesBulk has Save All / Don't Save / Cancel")
    func unsavedChangesBulkButtons() {
        let template = AlertTemplate.unsavedChangesBulk
        let alert = template.makeAlert(messageText: "Test", informativeText: "Info")
        let buttons = alert.buttons
        #expect(buttons.count == 3)
        #expect(buttons[0].title == Strings.dialogSaveAll)
        #expect(buttons[1].title == Strings.dialogDontSave)
        #expect(buttons[2].title == Strings.dialogCancel)
    }

    @Test("terminalTabCloseWarning has Close / Cancel")
    func terminalTabCloseWarningButtons() {
        let template = AlertTemplate.terminalTabCloseWarning
        let alert = template.makeAlert(messageText: "Test")
        let buttons = alert.buttons
        #expect(buttons.count == 2)
        #expect(buttons[0].title == Strings.terminalTabCloseWarningClose)
        #expect(buttons[1].title == Strings.dialogCancel)
    }

    @Test("terminalActiveProcessWarning has Quit / Cancel")
    func terminalActiveProcessWarningButtons() {
        let template = AlertTemplate.terminalActiveProcessWarning
        let alert = template.makeAlert(messageText: "Test")
        let buttons = alert.buttons
        #expect(buttons.count == 2)
        #expect(buttons[0].title == Strings.terminalActiveProcessWarningQuit)
        #expect(buttons[1].title == Strings.dialogCancel)
    }

    @Test("externalModifyConflict has Reload / Keep")
    func externalModifyConflictButtons() {
        let template = AlertTemplate.externalModifyConflict
        let alert = template.makeAlert(messageText: "Test")
        let buttons = alert.buttons
        #expect(buttons.count == 2)
        #expect(buttons[0].title == Strings.externalModifyReload)
        #expect(buttons[1].title == Strings.externalModifyKeep)
    }

    @Test("fileDeletedSaveAs has Save As / Don't Save / Cancel")
    func fileDeletedSaveAsButtons() {
        let template = AlertTemplate.fileDeletedSaveAs
        let alert = template.makeAlert(messageText: "Test")
        let buttons = alert.buttons
        #expect(buttons.count == 3)
        #expect(buttons[0].title == Strings.fileDeletedSaveAs)
        #expect(buttons[1].title == Strings.dialogDontSave)
        #expect(buttons[2].title == Strings.dialogCancel)
    }

    @Test("fileOperationError critical has OK button and critical style")
    func fileOperationErrorCritical() {
        let template = AlertTemplate.fileOperationErrorCritical
        let alert = template.makeAlert(messageText: "Test", informativeText: "Error details")
        let buttons = alert.buttons
        #expect(buttons.count == 1)
        #expect(buttons[0].title == Strings.dialogOK)
        #expect(alert.alertStyle == .critical)
    }

    @Test("fileOperationError warning has OK button and warning style")
    func fileOperationErrorWarning() {
        let template = AlertTemplate.fileOperationErrorWarning
        let alert = template.makeAlert(messageText: "Test", informativeText: "Error details")
        let buttons = alert.buttons
        #expect(buttons.count == 1)
        #expect(buttons[0].title == Strings.dialogOK)
        #expect(alert.alertStyle == .warning)
    }

    @Test("largeFileWarning has Without Highlighting / With Highlighting / Cancel")
    func largeFileWarningButtons() {
        let template = AlertTemplate.largeFileWarning
        let alert = template.makeAlert(messageText: "Test")
        let buttons = alert.buttons
        #expect(buttons.count == 3)
        #expect(buttons[0].title == Strings.largeFileOpenWithoutHighlighting)
        #expect(buttons[1].title == Strings.largeFileOpenWithHighlighting)
        #expect(buttons[2].title == Strings.dialogCancel)
    }

    @Test("branchUncommittedChanges has Switch / Cancel")
    func branchUncommittedChangesButtons() {
        let template = AlertTemplate.branchUncommittedChanges
        let alert = template.makeAlert(messageText: "Test")
        let buttons = alert.buttons
        #expect(buttons.count == 2)
        #expect(buttons[0].title == Strings.branchUncommittedChangesSwitch)
        #expect(buttons[1].title == Strings.dialogCancel)
    }

    @Test("revertAllConfirmation has Revert All / Cancel")
    func revertAllConfirmationButtons() {
        let template = AlertTemplate.revertAllConfirmation
        let alert = template.makeAlert(messageText: "Revert?")
        let buttons = alert.buttons
        #expect(buttons.count == 2)
        #expect(buttons[0].title == Strings.revertAllButton)
        #expect(buttons[1].title == Strings.dialogCancel)
    }

    @Test("cliInstallerInfo has OK and informational style")
    func cliInstallerInfoButtons() {
        let template = AlertTemplate.cliInstallerInfo
        let alert = template.makeAlert(messageText: "Title", informativeText: "Message")
        let buttons = alert.buttons
        #expect(buttons.count == 1)
        #expect(buttons[0].title == Strings.dialogOK)
        #expect(alert.alertStyle == .informational)
    }

    // MARK: - Alert style defaults

    @Test("most templates default to warning style")
    func warningStyles() {
        let warningTemplates: [AlertTemplate] = [
            .unsavedChangesSingle,
            .unsavedChangesBulk,
            .terminalTabCloseWarning,
            .terminalActiveProcessWarning,
            .externalModifyConflict,
            .fileDeletedSaveAs,
            .largeFileWarning,
            .branchUncommittedChanges,
            .revertAllConfirmation,
            .fileOperationErrorWarning,
        ]
        for template in warningTemplates {
            let alert = template.makeAlert(messageText: "Test")
            #expect(alert.alertStyle == .warning, "Expected .warning for \(template)")
        }
    }

    // MARK: - Message text propagation

    @Test("messageText and informativeText are set correctly")
    func messageTextPropagation() {
        let template = AlertTemplate.unsavedChangesSingle
        let alert = template.makeAlert(messageText: "My Title", informativeText: "My Details")
        #expect(alert.messageText == "My Title")
        #expect(alert.informativeText == "My Details")
    }

    @Test("messageText works without informativeText")
    func messageTextOnly() {
        let template = AlertTemplate.terminalTabCloseWarning
        let alert = template.makeAlert(messageText: "Just title")
        #expect(alert.messageText == "Just title")
        #expect(alert.informativeText == "")
    }
}
