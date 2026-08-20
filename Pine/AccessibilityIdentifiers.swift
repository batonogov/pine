//
//  AccessibilityIdentifiers.swift
//  Pine
//
//  Shared accessibility identifiers used by both app code and UI tests.
//

import Foundation

nonisolated enum AccessibilityID {
    // MARK: - Settings
    static let agentHandoffReadOnlyContextToggle =
        "agentHandoffReadOnlyContextToggle"
    static let agentHandoffStatus = "agentHandoffStatus"
    static let agentNotificationSettings = "agentNotificationSettings"
    static let agentNotificationEnableButton = "agentNotificationEnableButton"
    static let agentNotificationMainToggle = "agentNotificationMainToggle"
    static let generalFontSizeSlider = "generalFontSizeSlider"
    static let generalSettingsPane = "generalSettingsPane"
    static let keyBindingsSettingsPane = "keyBindingsSettingsPane"
    static let settingsHelpButton = "settingsHelpButton"

    // MARK: - Terminal theme settings
    static let terminalSettingsScrollView = "terminalSettingsScrollView"
    static let terminalAppearancePicker = "terminalAppearancePicker"
    static let terminalCursorShapePicker = "terminalCursorShapePicker"
    static let terminalCursorBlinkToggle = "terminalCursorBlinkToggle"
    static let terminalThemeGrid = "terminalThemeGrid"
    static func terminalThemeRow(_ id: String) -> String {
        "terminalThemeRow_\(id)"
    }

    // MARK: - Quick Terminal settings
    static let quickTerminalSettingsSection = "quickTerminalSettingsSection"
    static let quickTerminalEnabledToggle = "quickTerminalEnabledToggle"
    static let quickTerminalHotkeyRecorder = "quickTerminalHotkeyRecorder"
    static let quickTerminalHotkeyValidation = "quickTerminalHotkeyValidation"
    static let quickTerminalScreenEdgePicker =
        "quickTerminalScreenEdgePicker"
    static let quickTerminalSizeSlider = "quickTerminalSizeSlider"
    static let quickTerminalTargetDisplayPicker =
        "quickTerminalTargetDisplayPicker"
    static let quickTerminalHideOnFocusLossToggle =
        "quickTerminalHideOnFocusLossToggle"
    static let quickTerminalResetButton = "quickTerminalResetButton"
    static let quickTerminalContent = "quickTerminalContent"
    static let quickTerminalAgentIdentity = "quickTerminalAgentIdentity"

    // MARK: - Welcome window
    static let welcomeOpenFolderButton = "welcomeOpenFolderButton"
    static let welcomeRecentProjectsList = "welcomeRecentProjectsList"
    static let welcomeRecentProjectOpen = "welcomeRecentProjectOpen"
    static let welcomeRecentProjectReveal = "welcomeRecentProjectReveal"
    static let welcomeRecentProjectRemove = "welcomeRecentProjectRemove"
    static let welcomeSearchField = "welcomeSearchField"
    static let welcomeSearchToggle = "welcomeSearchToggle"
    static let welcomeAgentInboxButton = "welcomeAgentInboxButton"
    static func welcomeRecentProject(_ name: String) -> String { "welcomeRecentProject_\(name)" }

    // MARK: - Main editor window
    static let sidebar = "sidebar"
    static let openFolderToolbarButton = "openFolderToolbarButton"
    static let projectSwitcher = "projectSwitcher"
    static let projectSwitcherNewAgent = "projectSwitcherNewAgent"
    static let projectSwitcherCloseProject = "projectSwitcherCloseProject"
    static func projectSwitcherProject(_ name: String) -> String {
        "projectSwitcherProject_\(name)"
    }
    static func projectSwitcherWorktree(_ id: UUID) -> String {
        "projectSwitcherWorktree_\(id.uuidString)"
    }
    static func fileNode(_ name: String) -> String { "fileNode_\(name)" }
    static let inlineRenameTextField = "inlineRenameTextField"

    // MARK: - Editor
    static let editorTabBar = "editorTabBar"
    static func editorTab(_ name: String) -> String { "editorTab_\(name)" }
    static func editorTabCloseButton(_ name: String) -> String { "editorTabClose_\(name)" }
    static func editorTabPinToggle(_ name: String) -> String { "editorTabPinToggle_\(name)" }
    static func editorTabCloseOthers(_ name: String) -> String { "editorTabCloseOthers_\(name)" }
    static func editorTabCloseRight(_ name: String) -> String { "editorTabCloseRight_\(name)" }
    static func editorTabCloseAll(_ name: String) -> String { "editorTabCloseAll_\(name)" }
    static func editorTabCopyPath(_ name: String) -> String { "editorTabCopyPath_\(name)" }
    static func editorTabCopyRelativePath(_ name: String) -> String {
        "editorTabCopyRelativePath_\(name)"
    }
    static func editorTabRevealInSidebar(_ name: String) -> String {
        "editorTabRevealInSidebar_\(name)"
    }
    static func editorTabRevealInFinder(_ name: String) -> String {
        "editorTabRevealInFinder_\(name)"
    }
    static let editorPlaceholder = "editorPlaceholder"
    static let codeEditor = "codeEditor"
    static let lineNumberGutter = "lineNumberGutter"
    static let minimap = "minimap"
    static let autoSaveIndicator = "autoSaveIndicator"
    static let editorTabOverflowMenu = "editorTabOverflowMenu"
    static let quickLookPreview = "quickLookPreview"

    // MARK: - Breadcrumb
    static let breadcrumbBar = "breadcrumbBar"
    static func breadcrumbSegment(_ name: String) -> String { "breadcrumbSegment_\(name)" }

    // MARK: - Terminal
    static let terminalTabBar = "terminalTabBar"
    static func terminalTab(_ name: String) -> String { "terminalTab_\(name)" }
    static let terminalSurface = "terminalSurface"
    static let newTerminalButton = "newTerminalButton"
    static let maximizeTerminalButton = "maximizeTerminalButton"
    static let hideTerminalButton = "hideTerminalButton"

    // MARK: - Terminal Search
    static let terminalSearchBar = "terminalSearchBar"
    static let terminalSearchField = "terminalSearchField"
    static let terminalSearchPrevious = "terminalSearchPrevious"
    static let terminalSearchNext = "terminalSearchNext"
    static let terminalSearchClose = "terminalSearchClose"
    static let terminalSearchCaseSensitive = "terminalSearchCaseSensitive"

    // MARK: - Markdown Preview
    static let markdownPreviewToggle = "markdownPreviewToggle"
    static let markdownPreviewView = "markdownPreviewView"

    // MARK: - Go to Line
    /// Existing view-level identifier retained for compatibility. The
    /// NSPanel container uses `goToLineOverlay`.
    static let goToLineSheet = "goToLineSheet"
    static let goToLineOverlay = "goToLineOverlay"
    static let goToLineField = "goToLineField"
    static let goToLineInvalidMessage = "goToLineInvalidMessage"

    // MARK: - Branch switcher
    static let branchSearchField = "branchSearchField"
    static func branchItem(_ name: String) -> String { "branchItem_\(name)" }

    // MARK: - Project Search
    static let projectSearchResultsList = "projectSearchResultsList"
    static let searchEmptyState = "searchEmptyState"
    static let searchInitialState = "searchInitialState"
    static let searchTruncationFooter = "searchTruncationFooter"

    // MARK: - Quick Open
    static let quickOpenOverlay = "quickOpenOverlay"
    static let quickOpenSearchField = "quickOpenSearchField"
    static let quickOpenResultsList = "quickOpenResultsList"
    static func quickOpenItem(_ name: String) -> String { "quickOpenItem_\(name)" }

    // MARK: - Command Palette
    static let commandPaletteOverlay = "commandPaletteOverlay"
    static let commandPaletteSearchField = "commandPaletteSearchField"
    static let commandPaletteResultsList = "commandPaletteResultsList"
    static func commandPaletteItem(_ id: String) -> String {
        "commandPaletteItem_\(id)"
    }

    // MARK: - Symbol Navigator
    static let symbolNavigatorOverlay = "symbolNavigatorOverlay"
    static let symbolSearchField = "symbolSearchField"
    static let symbolResultsList = "symbolResultsList"
    static func symbolItem(_ name: String) -> String { "symbolItem_\(name)" }

    // MARK: - Split Panes
    static let paneDivider = "paneDivider"
    static let paneDropOverlay = "paneDropOverlay"
    static func paneLeaf(_ id: String) -> String { "paneLeaf_\(id)" }

    // MARK: - Toast notifications
    static let toastNotification = "toastNotification"

    // MARK: - User tasks
    static let userTaskOutputPanel = "userTaskOutputPanel"
    static let userTaskClearFinishedButton = "userTaskClearFinishedButton"
    static let userTaskCloseOutputButton = "userTaskCloseOutputButton"
    static let userTaskShowOutputButton = "userTaskShowOutputButton"
    static func userTaskRun(_ id: UUID) -> String {
        "userTaskRun_\(id.uuidString)"
    }
    static func userTaskStatusLabel(_ id: UUID) -> String {
        "userTaskStatus_\(id.uuidString)"
    }
    static func userTaskElapsedLabel(_ id: UUID) -> String {
        "userTaskElapsed_\(id.uuidString)"
    }
    static func userTaskCopyOutputButton(_ id: UUID) -> String {
        "userTaskCopyOutput_\(id.uuidString)"
    }
    static func userTaskOutputText(_ id: UUID) -> String {
        "userTaskOutputText_\(id.uuidString)"
    }
    static func userTaskOutputTruncationNotice(_ id: UUID) -> String {
        "userTaskOutputTruncation_\(id.uuidString)"
    }
    static func userTaskCancelButton(_ id: UUID) -> String {
        "userTaskCancel_\(id.uuidString)"
    }
    static func userTaskProgressIndicator(_ id: UUID) -> String {
        "userTaskProgress_\(id.uuidString)"
    }

    // MARK: - Context menu
    static let contextMenuNewFile = "contextMenuNewFile"
    static let contextMenuNewFolder = "contextMenuNewFolder"

    // MARK: - Status bar
    static let statusBar = "statusBar"
    static let terminalToggleButton = "terminalToggleButton"
    static let encodingMenu = "encodingMenu"
    static let cursorPosition = "cursorPosition"
    static let indentationIndicator = "indentationIndicator"
    static let lineEndingIndicator = "lineEndingIndicator"
    static let fileSizeIndicator = "fileSizeIndicator"
    static let progressIndicator = "progressIndicator"
    static let agentStatusBar = "agentStatusBar"
    static let agentStatusBarItem = "agentStatusBarItem"
    static let agentAttentionBell = "agentAttentionBell"
    static let agentAttentionOverlay = "agentAttentionOverlay"
    static func agentAttentionRow(_ id: UUID) -> String {
        "agentAttentionRow_\(id.uuidString)"
    }

    // MARK: - Agent Inbox
    static let agentInbox = "agentInbox"
    static let agentInboxToolbarButton = "agentInboxToolbarButton"
    static let agentInboxList = "agentInboxList"
    static let agentInboxEmpty = "agentInboxEmpty"
    static let agentInboxNavigationStatus = "agentInboxNavigationStatus"
    static let agentInboxHelpButton = "agentInboxHelpButton"
    static let agentInboxRecoveryActions = "agentInboxRecoveryActions"
    static let agentInboxResumeSession = "agentInboxResumeSession"
    static let agentInboxNewSession = "agentInboxNewSession"
    static let agentInboxMarkReviewed = "agentInboxMarkReviewed"
    static let agentInboxCopyObjective = "agentInboxCopyObjective"
    static let agentInboxDismissTask = "agentInboxDismissTask"
    static func agentInboxRow(_ id: UUID) -> String {
        "agentInboxRow_\(id.uuidString)"
    }

    // MARK: - Global Tab Switcher overlay (#1239)
    static let globalTabSwitcherOverlay = "globalTabSwitcherOverlay"
    static let globalTabSwitcherList = "globalTabSwitcherList"
    static func globalTabSwitcherItem(_ identity: GlobalTabIdentity) -> String {
        [
            "globalTabSwitcherItem",
            identity.contentType.rawValue,
            identity.paneID.id.uuidString,
            identity.tabID.uuidString,
        ].joined(separator: "_")
    }

    // MARK: - LSP / Problems panel (#1010)
    static let problemsIndicator = "problemsIndicator"
    static let problemsPanel = "problemsPanel"
    static let problemsEmptyState = "problemsEmptyState"
    static let problemsHelpButton = "problemsHelpButton"
    static let problemsLanguageSettingsButton =
        "problemsLanguageSettingsButton"
    static let agentStatusBarMenu = "agentStatusBarMenu"

    // MARK: - LSP completion popup (#1012)
    static let completionPopup = "completionPopup"
    static let completionPopupList = "completionPopupList"
    static func completionItem(_ label: String) -> String { "completionItem_\(label)" }

    // MARK: - Agent Activity Panel (#1072)
    static let agentActivityPanel = "agentActivityPanel"
    static let agentActivityRow = "agentActivityRow"
    static let agentActivityEmpty = "agentActivityEmpty"
    static let agentActivityNoMatches = "agentActivityNoMatches"
    static func agentActivityRow(_ id: UUID) -> String {
        "agentActivityRow_\(id.uuidString)"
    }
    static let agentActivityResetFilters = "agentActivityResetFilters"
    static let agentActivityKindMenu = "agentActivityKindMenu"
    static let agentActivityStatusMenu = "agentActivityStatusMenu"
    static let agentActivityAttributionMenu = "agentActivityAttributionMenu"
    static let agentActivityHelpButton = "agentActivityHelpButton"
    static let agentActivityDetail = "agentActivityDetail"
    static let agentActivityDetailHelpButton =
        "agentActivityDetailHelpButton"
    static let agentActivityDetailCopy = "agentActivityDetailCopy"
    static let agentActivityDetailGoToTerminal = "agentActivityDetailGoToTerminal"
    static let agentActivityDetailOpenFile = "agentActivityDetailOpenFile"

    // MARK: - Agent History & Undo (#1073)
    static let agentHistoryPanel = "agentHistoryPanel"
    static let agentHistoryRevertButton = "agentHistoryRevertButton"
    static let agentHistoryUndoUnavailable = "agentHistoryUndoUnavailable"
    static let agentHistoryRevertedBadge = "agentHistoryRevertedBadge"
    static let agentCompletionBrief = "agentCompletionBrief"
    static let agentCompletionShowButton = "agentCompletionShowButton"
    static let agentCompletionReviewChanges =
        "agentCompletionReviewChanges"
    static let agentHistoryRecoveryNotice = "agentHistoryRecoveryNotice"
    static func agentHistoryRecoveryRecord(_ name: String) -> String {
        "agentHistoryRecoveryRecord_\(name)"
    }
    static func agentHistoryRecoveryCopyPath(_ path: String) -> String {
        "agentHistoryRecoveryCopyPath_\(path)"
    }
    static func agentHistoryRecoveryRevealPath(_ path: String) -> String {
        "agentHistoryRecoveryRevealPath_\(path)"
    }

    // MARK: - Verified undo review (#1237)
    static let agentHistoryUndoReview = "agentHistoryUndoReview"
    static let agentHistoryUndoReviewSummary =
        "agentHistoryUndoReviewSummary"
    static let agentHistoryUndoReviewStale =
        "agentHistoryUndoReviewStale"
    static let agentHistoryUndoReviewApply =
        "agentHistoryUndoReviewApply"
    static let agentHistoryUndoReviewHeaderDismiss =
        "agentHistoryUndoReviewHeaderDismiss"
    static let agentHistoryUndoReviewFooterDismiss =
        "agentHistoryUndoReviewFooterDismiss"
    static let agentHistoryUndoReviewProgress =
        "agentHistoryUndoReviewProgress"
    static func agentHistoryUndoReviewOperation(
        _ path: String
    ) -> String {
        "agentHistoryUndoReviewOperation_\(path)"
    }

    // MARK: - Prepared inverse review (#933)
    static let verifiedDiffPreview = "verifiedDiffPreview"
    static let verifiedDiffStalenessNotice =
        "verifiedDiffStalenessNotice"
    static func verifiedDiffOperation(_ index: Int) -> String {
        "verifiedDiffOperation_\(index)"
    }
}
