//
//  MenuIcons.swift
//  Pine
//
//  SF Symbol names for menu items. Used by both app code and tests.
//

nonisolated enum MenuIcons {
    // MARK: - File menu
    static let openFolder = "folder"
    static let save = "square.and.arrow.down"
    static let saveAll = "square.and.arrow.down.on.square"
    static let saveAs = "doc.on.doc"
    static let duplicate = "plus.square.on.square"
    static let autoSave = "arrow.triangle.2.circlepath"
    static let formatOnSave = "text.alignleft"
    static let smartListContinuation = "list.bullet"

    static let quickOpen = "doc.text.magnifyingglass"
    static let commandPalette = "command"
    static let installCLI = "terminal"

    // MARK: - Edit menu
    static let toggleComment = "slash.circle"
    static let find = "magnifyingglass"
    static let findAndReplace = "arrow.left.arrow.right"
    static let findInProject = "magnifyingglass"
    static let goToLine = "number"
    static let symbolNavigator = "list.bullet.indent"
    static let nextChange = "chevron.down"
    static let previousChange = "chevron.up"
    static let acceptChange = "checkmark.circle"
    static let revertChange = "arrow.uturn.backward.circle"
    static let acceptAllChanges = "checkmark.circle.fill"
    static let revertAllChanges = "arrow.uturn.backward.circle.fill"
    static let foldCode = "chevron.down.square"
    static let unfoldCode = "chevron.right.square"
    static let foldAll = "rectangle.compress.vertical"
    static let unfoldAll = "rectangle.expand.vertical"

    // MARK: - View menu
    static let increaseFontSize = "plus.magnifyingglass"
    static let decreaseFontSize = "minus.magnifyingglass"
    static let resetFontSize = "textformat.size"
    static let toggleTerminal = "terminal"
    static let togglePreview = "doc.richtext"
    static let toggleMinimap = "sidebar.right"
    static let toggleBlame = "person.text.rectangle"
    static let toggleWordWrap = "text.word.spacing"
    static let revealFileInFinder = "doc.viewfinder"
    static let revealProjectInFinder = "arrow.right.circle"

    // MARK: - Git menu
    static let switchBranch = "arrow.triangle.branch"

    // MARK: - Terminal menu
    static let newTerminalTab = "plus"
    static let sendToTerminal = "paperplane"
    static let maximizeTerminal = "arrow.up.left.and.arrow.down.right"

    // MARK: - Tasks menu (issue #1009)
    static let tasks = "wrench.and.screwdriver"

    // MARK: - User configuration (issue #1117)
    static let editKeybindings = "keyboard"
    static let editTasks = "doc.text"
    static let reloadUserConfiguration = "arrow.clockwise"

    // MARK: - Agent Activity Panel (#1072)
    static let agentActivity = "list.bullet.rectangle"

    // MARK: - Agent Inbox (#1305)
    static let agentInbox = "tray.full"

    // MARK: - Agent History & Undo (#1073)
    static let agentHistory = "clock.arrow.circlepath"

    // MARK: - Validation
    static let toggleValidation = "checkmark.shield"

    // MARK: - Context menu
    static let newFile = "doc.badge.plus"
    static let newFolder = "folder.badge.plus"
    static let revealInFinder = "arrow.right.circle"
    static let rename = "pencil"
    static let delete = "trash"

    // MARK: - File / Window menu (#1240)
    static let openFile = "folder"
    static let clearMenu = "eraser"
    static let closeTab = "xmark"
    static let closeWindow = "xmark.rectangle"

    // MARK: - Problems panel (#1236)
    static let problems = "exclamationmark.bubble"
    static let nextDiagnostic = "arrow.down"
    static let previousDiagnostic = "arrow.up"
    static let closeProblems = "xmark"

    // MARK: - Tab context menu
    static let closeOtherTabs = "xmark.square"
    static let closeTabsToTheRight = "xmark.rectangle"
    static let closeAllTabs = "xmark.rectangle.fill"
    static let copyPath = "doc.on.clipboard"
    static let copyRelativePath = "link"
    static let revealInSidebar = "sidebar.left"
}
