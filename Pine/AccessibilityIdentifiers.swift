//
//  AccessibilityIdentifiers.swift
//  Pine
//
//  Shared accessibility identifiers used by both app code and UI tests.
//

nonisolated enum AccessibilityID {
    // MARK: - Settings
    static let agentHandoffReadOnlyContextToggle =
        "agentHandoffReadOnlyContextToggle"
    static let agentHandoffStatus = "agentHandoffStatus"

    // MARK: - Welcome window
    static let welcomeOpenFolderButton = "welcomeOpenFolderButton"
    static let welcomeRecentProjectsList = "welcomeRecentProjectsList"
    static let welcomeSearchField = "welcomeSearchField"
    static let welcomeSearchToggle = "welcomeSearchToggle"
    static func welcomeRecentProject(_ name: String) -> String { "welcomeRecentProject_\(name)" }

    // MARK: - Main editor window
    static let sidebar = "sidebar"
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
    static let goToLineSheet = "goToLineSheet"
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

    // MARK: - LSP / Problems panel (#1010)
    static let problemsIndicator = "problemsIndicator"
    static let problemsPanel = "problemsPanel"
    static let problemsEmptyState = "problemsEmptyState"
    static let agentStatusBarMenu = "agentStatusBarMenu"

    // MARK: - LSP completion popup (#1012)
    static let completionPopup = "completionPopup"
    static let completionPopupList = "completionPopupList"
    static func completionItem(_ label: String) -> String { "completionItem_\(label)" }

    // MARK: - Agent Activity Panel (#1072)
    static let agentActivityPanel = "agentActivityPanel"
    static let agentActivityRow = "agentActivityRow"

    // MARK: - Agent History & Undo (#1073)
    static let agentHistoryPanel = "agentHistoryPanel"
    static let agentHistoryRevertButton = "agentHistoryRevertButton"
    static let agentHistoryUndoUnavailable = "agentHistoryUndoUnavailable"
    static let agentHistoryRevertedBadge = "agentHistoryRevertedBadge"
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
}
