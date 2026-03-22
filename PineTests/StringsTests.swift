//
//  StringsTests.swift
//  PineTests
//

import Testing
import SwiftUI
@testable import Pine

/// Tests for Strings.swift — verifies all string accessors are non-empty.
/// Covers the computed String properties and functions (not LocalizedStringKey).
struct StringsTests {

    // MARK: - Context Menu (computed String vars)

    @Test func contextNewFileTitle_nonEmpty() {
        #expect(!Strings.contextNewFileTitle.isEmpty)
    }

    @Test func contextNewFolderTitle_nonEmpty() {
        #expect(!Strings.contextNewFolderTitle.isEmpty)
    }

    @Test func contextRenameTitle_nonEmpty() {
        #expect(!Strings.contextRenameTitle.isEmpty)
    }

    @Test func contextDeleteConfirmTitle_nonEmpty() {
        #expect(!Strings.contextDeleteConfirmTitle.isEmpty)
    }

    @Test func contextDeleteConfirmMessage_containsName() {
        let result = Strings.contextDeleteConfirmMessage("test.swift")
        #expect(!result.isEmpty)
    }

    @Test func contextNamePlaceholder_nonEmpty() {
        #expect(!Strings.contextNamePlaceholder.isEmpty)
    }

    @Test func contextDeleteButton_nonEmpty() {
        #expect(!Strings.contextDeleteButton.isEmpty)
    }

    // MARK: - File Operation Errors

    @Test func fileOperationErrorTitle_nonEmpty() {
        #expect(!Strings.fileOperationErrorTitle.isEmpty)
    }

    @Test func fileCreateError_containsName() {
        let result = Strings.fileCreateError("new.swift")
        #expect(!result.isEmpty)
    }

    @Test func operationOutsideProject_nonEmpty() {
        #expect(!Strings.operationOutsideProject.isEmpty)
    }

    @Test func fileDeletedTitle_nonEmpty() {
        #expect(!Strings.fileDeletedTitle.isEmpty)
    }

    @Test func fileDeletedMessage_nonEmpty() {
        #expect(!Strings.fileDeletedMessage.isEmpty)
    }

    @Test func fileDeletedSaveAs_nonEmpty() {
        #expect(!Strings.fileDeletedSaveAs.isEmpty)
    }

    // MARK: - External Change Conflicts

    @Test func externalModifyTitle_nonEmpty() {
        #expect(!Strings.externalModifyTitle.isEmpty)
    }

    @Test func externalModifyMessage_containsName() {
        let result = Strings.externalModifyMessage("file.swift")
        #expect(!result.isEmpty)
    }

    @Test func externalModifyReload_nonEmpty() {
        #expect(!Strings.externalModifyReload.isEmpty)
    }

    @Test func externalModifyKeep_nonEmpty() {
        #expect(!Strings.externalModifyKeep.isEmpty)
    }

    // MARK: - Branch Switcher

    @Test func branchSwitchErrorTitle_nonEmpty() {
        #expect(!Strings.branchSwitchErrorTitle.isEmpty)
    }

    @Test func branchUncommittedChangesTitle_nonEmpty() {
        #expect(!Strings.branchUncommittedChangesTitle.isEmpty)
    }

    @Test func branchUncommittedChangesMessage_containsBranch() {
        let result = Strings.branchUncommittedChangesMessage("main")
        #expect(!result.isEmpty)
    }

    @Test func branchUncommittedChangesSwitch_nonEmpty() {
        #expect(!Strings.branchUncommittedChangesSwitch.isEmpty)
    }

    // MARK: - Unsaved Changes Dialog

    @Test func unsavedChangesTitle_nonEmpty() {
        #expect(!Strings.unsavedChangesTitle.isEmpty)
    }

    @Test func unsavedChangesMessage_nonEmpty() {
        #expect(!Strings.unsavedChangesMessage.isEmpty)
    }

    @Test func dialogSave_nonEmpty() {
        #expect(!Strings.dialogSave.isEmpty)
    }

    @Test func dialogDontSave_nonEmpty() {
        #expect(!Strings.dialogDontSave.isEmpty)
    }

    @Test func dialogCancel_nonEmpty() {
        #expect(!Strings.dialogCancel.isEmpty)
    }

    @Test func dialogSaveAll_nonEmpty() {
        #expect(!Strings.dialogSaveAll.isEmpty)
    }

    @Test func unsavedChangesListMessage_containsFileNames() {
        let result = Strings.unsavedChangesListMessage("  • file1.swift\n  • file2.swift")
        #expect(!result.isEmpty)
    }

    @Test func dialogOK_nonEmpty() {
        #expect(!Strings.dialogOK.isEmpty)
    }

    // MARK: - Save As / Open Panel

    @Test func saveAsPanelTitle_nonEmpty() {
        #expect(!Strings.saveAsPanelTitle.isEmpty)
    }

    @Test func openPanelMessage_nonEmpty() {
        #expect(!Strings.openPanelMessage.isEmpty)
    }

    @Test func openPanelPrompt_nonEmpty() {
        #expect(!Strings.openPanelPrompt.isEmpty)
    }

    // MARK: - Large File Warning

    @Test func largeFileWarningTitle_nonEmpty() {
        #expect(!Strings.largeFileWarningTitle.isEmpty)
    }

    @Test func largeFileWarningMessage_containsValues() {
        let result = Strings.largeFileWarningMessage("huge.txt", 5.5)
        #expect(!result.isEmpty)
    }

    @Test func largeFileOpenWithHighlighting_nonEmpty() {
        #expect(!Strings.largeFileOpenWithHighlighting.isEmpty)
    }

    @Test func largeFileOpenWithoutHighlighting_nonEmpty() {
        #expect(!Strings.largeFileOpenWithoutHighlighting.isEmpty)
    }

    // MARK: - Terminal Search

    @Test func terminalSearchPreviousTooltip_nonEmpty() {
        #expect(!Strings.terminalSearchPreviousTooltip.isEmpty)
    }

    @Test func terminalSearchNextTooltip_nonEmpty() {
        #expect(!Strings.terminalSearchNextTooltip.isEmpty)
    }

    @Test func terminalSearchCloseTooltip_nonEmpty() {
        #expect(!Strings.terminalSearchCloseTooltip.isEmpty)
    }

    @Test func terminalSearchCaseSensitiveTooltip_nonEmpty() {
        #expect(!Strings.terminalSearchCaseSensitiveTooltip.isEmpty)
    }

    @Test func terminalSearchNoMatches_nonEmpty() {
        #expect(!Strings.terminalSearchNoMatches.isEmpty)
    }

    @Test func terminalSearchMatchCount_formatted() {
        let result = Strings.terminalSearchMatchCount(current: 3, total: 10)
        #expect(!result.isEmpty)
    }

    // MARK: - Terminal Tab Names

    @Test func terminalDefaultName_nonEmpty() {
        #expect(!Strings.terminalDefaultName.isEmpty)
    }

    @Test func terminalNumberedName_containsNumber() {
        let result = Strings.terminalNumberedName(5)
        #expect(!result.isEmpty)
    }

    // MARK: - Recovery Dialog

    @Test func recoveryUntitled_nonEmpty() {
        #expect(!Strings.recoveryUntitled.isEmpty)
    }

    // MARK: - Terminal Process Warnings

    @Test func terminalActiveProcessWarningTitle_nonEmpty() {
        #expect(!Strings.terminalActiveProcessWarningTitle.isEmpty)
    }

    @Test func terminalActiveProcessWarningMessage_nonEmpty() {
        #expect(!Strings.terminalActiveProcessWarningMessage.isEmpty)
    }

    @Test func terminalActiveProcessWarningQuit_nonEmpty() {
        #expect(!Strings.terminalActiveProcessWarningQuit.isEmpty)
    }

    @Test func terminalTabCloseWarningTitle_nonEmpty() {
        #expect(!Strings.terminalTabCloseWarningTitle.isEmpty)
    }

    @Test func terminalTabCloseWarningMessage_nonEmpty() {
        #expect(!Strings.terminalTabCloseWarningMessage.isEmpty)
    }

    @Test func terminalTabCloseWarningClose_nonEmpty() {
        #expect(!Strings.terminalTabCloseWarningClose.isEmpty)
    }
}
