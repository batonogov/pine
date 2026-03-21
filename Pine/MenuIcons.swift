//
//  MenuIcons.swift
//  Pine
//
//  SF Symbol names for menu items. Used by both app code and tests.
//

enum MenuIcons {
    // MARK: - File menu
    static let openFolder = "folder"
    static let save = "square.and.arrow.down"
    static let saveAll = "square.and.arrow.down.on.square"
    static let saveAs = "doc.on.doc"
    static let duplicate = "plus.square.on.square"
    static let autoSave = "arrow.triangle.2.circlepath"

    // MARK: - Edit menu
    static let toggleComment = "slash.circle"
    static let find = "magnifyingglass"
    static let findAndReplace = "arrow.left.arrow.right"
    static let findInProject = "magnifyingglass"
    static let nextChange = "chevron.down"
    static let previousChange = "chevron.up"
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
    static let revealFileInFinder = "doc.viewfinder"
    static let revealProjectInFinder = "arrow.right.circle"

    // MARK: - Git menu
    static let showChanges = "arrow.left.arrow.right.square"
    static let switchBranch = "arrow.triangle.branch"

    // MARK: - Terminal menu
    static let newTerminalTab = "plus"

    // MARK: - Context menu
    static let newFile = "doc.badge.plus"
    static let newFolder = "folder.badge.plus"
    static let revealInFinder = "arrow.right.circle"
    static let rename = "pencil"
    static let delete = "trash"
}
