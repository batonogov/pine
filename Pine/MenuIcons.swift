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

    // MARK: - Edit menu
    static let toggleComment = "slash.circle"
    static let findInProject = "magnifyingglass"
    static let nextChange = "chevron.down"
    static let previousChange = "chevron.up"

    // MARK: - View menu
    static let increaseFontSize = "plus.magnifyingglass"
    static let decreaseFontSize = "minus.magnifyingglass"
    static let resetFontSize = "textformat.size"
    static let toggleTerminal = "terminal"
    static let togglePreview = "doc.richtext"
    static let toggleMinimap = "sidebar.right"
    static let revealFileInFinder = "doc.viewfinder"
    static let revealProjectInFinder = "arrow.right.circle"

    // MARK: - Terminal menu
    static let newTerminalTab = "plus"

    // MARK: - Context menu
    static let newFile = "doc.badge.plus"
    static let newFolder = "folder.badge.plus"
    static let revealInFinder = "arrow.right.circle"
    static let rename = "pencil"
    static let delete = "trash"
}
