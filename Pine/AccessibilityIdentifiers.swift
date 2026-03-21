//
//  AccessibilityIdentifiers.swift
//  Pine
//
//  Shared accessibility identifiers used by both app code and UI tests.
//

enum AccessibilityID {
    // MARK: - Welcome window
    static let welcomeWindow = "welcomeWindow"
    static let welcomeOpenFolderButton = "welcomeOpenFolderButton"
    static let welcomeRecentProjectsList = "welcomeRecentProjectsList"
    static func welcomeRecentProject(_ name: String) -> String { "welcomeRecentProject_\(name)" }

    // MARK: - Main editor window
    static let sidebar = "sidebar"
    static let sidebarFileList = "sidebarFileList"
    static func fileNode(_ name: String) -> String { "fileNode_\(name)" }

    // MARK: - Editor
    static let editorArea = "editorArea"
    static let editorTabBar = "editorTabBar"
    static func editorTab(_ name: String) -> String { "editorTab_\(name)" }
    static func editorTabCloseButton(_ name: String) -> String { "editorTabClose_\(name)" }
    static let editorPlaceholder = "editorPlaceholder"
    static let codeEditor = "codeEditor"
    static let minimap = "minimap"
    static let autoSaveIndicator = "autoSaveIndicator"
    static let quickLookPreview = "quickLookPreview"

    // MARK: - Terminal
    static let terminalArea = "terminalArea"
    static let terminalTabBar = "terminalTabBar"
    static func terminalTab(_ name: String) -> String { "terminalTab_\(name)" }
    static let newTerminalButton = "newTerminalButton"
    static let maximizeTerminalButton = "maximizeTerminalButton"
    static let hideTerminalButton = "hideTerminalButton"

    // MARK: - Markdown Preview
    static let markdownPreviewToggle = "markdownPreviewToggle"
    static let markdownPreviewView = "markdownPreviewView"

    // MARK: - Branch switcher
    static let branchSwitcherButton = "branchSwitcherButton"
    static let branchSearchField = "branchSearchField"
    static func branchItem(_ name: String) -> String { "branchItem_\(name)" }

    // MARK: - Project Search
    static let projectSearchResultsList = "projectSearchResultsList"

    // MARK: - Diff Panel
    static let diffPanel = "diffPanel"
    static let diffPanelStagedSection = "diffPanelStagedSection"
    static let diffPanelUnstagedSection = "diffPanelUnstagedSection"
    static func diffPanelFile(_ name: String) -> String { "diffPanelFile_\(name)" }
    static func diffPanelHunk(_ index: Int) -> String { "diffPanelHunk_\(index)" }
    static let diffPanelStageHunkButton = "diffPanelStageHunkButton"
    static let diffPanelUnstageHunkButton = "diffPanelUnstageHunkButton"
    static let diffPanelDiscardHunkButton = "diffPanelDiscardHunkButton"

    // MARK: - Status bar
    static let statusBar = "statusBar"
    static let terminalToggleButton = "terminalToggleButton"
    static let encodingMenu = "encodingMenu"
    static let cursorPosition = "cursorPosition"
    static let indentationIndicator = "indentationIndicator"
    static let lineEndingIndicator = "lineEndingIndicator"
    static let fileSizeIndicator = "fileSizeIndicator"
}
