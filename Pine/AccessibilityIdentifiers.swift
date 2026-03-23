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
    static let lineNumberGutter = "lineNumberGutter"
    static let minimap = "minimap"
    static let autoSaveIndicator = "autoSaveIndicator"
    static let editorTabOverflowMenu = "editorTabOverflowMenu"
    static let quickLookPreview = "quickLookPreview"

    // MARK: - Terminal
    static let terminalArea = "terminalArea"
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

    // MARK: - Branch switcher
    static let branchSwitcherButton = "branchSwitcherButton"
    static let branchSearchField = "branchSearchField"
    static func branchItem(_ name: String) -> String { "branchItem_\(name)" }

    // MARK: - Project Search
    static let projectSearchResultsList = "projectSearchResultsList"

    // MARK: - Quick Open
    static let quickOpenOverlay = "quickOpenOverlay"
    static let quickOpenSearchField = "quickOpenSearchField"
    static let quickOpenResultsList = "quickOpenResultsList"
    static func quickOpenItem(_ name: String) -> String { "quickOpenItem_\(name)" }

    // MARK: - FPS Overlay
    static let fpsOverlay = "fpsOverlay"

    // MARK: - Status bar
    static let statusBar = "statusBar"
    static let terminalToggleButton = "terminalToggleButton"
    static let encodingMenu = "encodingMenu"
    static let cursorPosition = "cursorPosition"
    static let indentationIndicator = "indentationIndicator"
    static let lineEndingIndicator = "lineEndingIndicator"
    static let fileSizeIndicator = "fileSizeIndicator"
}
