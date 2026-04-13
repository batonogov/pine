//
//  PineAppNotifications.swift
//  Pine
//
//  Created by Федор Батоногов on 09.04.2026.
//
//  Notification names for menu commands and cross-component events.
//  Extracted from PineApp.swift as part of refactor #756.
//

import Foundation

extension Notification.Name {
    // MARK: - File operations
    static let openFolder = Notification.Name("openFolder")
    static let closeTab = Notification.Name("closeTab")
    static let showQuickOpen = Notification.Name("showQuickOpen")
    /// userInfo: ["oldURL": URL, "newURL": URL]
    static let fileRenamed = Notification.Name("fileRenamed")
    /// userInfo: ["url": URL]
    static let fileDeleted = Notification.Name("fileDeleted")
    /// userInfo: ["url": URL] — reveals a file in the sidebar tree
    static let revealInSidebar = Notification.Name("revealInSidebar")

    // MARK: - Find & Replace (issue #275)
    static let findInFile = Notification.Name("findInFile")
    static let findAndReplace = Notification.Name("findAndReplace")
    static let findNext = Notification.Name("findNext")
    static let findPrevious = Notification.Name("findPrevious")
    static let useSelectionForFind = Notification.Name("useSelectionForFind")
    static let showProjectSearch = Notification.Name("showProjectSearch")

    // MARK: - Editor navigation
    /// Go to Line (issue #418)
    static let goToLine = Notification.Name("goToLine")
    /// Symbol Navigation (issue #306)
    static let showSymbolNavigator = Notification.Name("showSymbolNavigator")
    static let symbolNavigate = Notification.Name("symbolNavigate")
    /// userInfo: ["direction": "next" | "previous"]
    static let navigateChange = Notification.Name("navigateChange")
    /// userInfo: ["action": "fold" | "unfold" | "foldAll" | "unfoldAll"]
    static let foldCode = Notification.Name("foldCode")
    static let toggleComment = Notification.Name("toggleComment")
    /// Word Wrap toggle (issue #416)
    static let toggleWordWrap = Notification.Name("toggleWordWrap")
    /// userInfo: ["action": InlineDiffAction]
    static let inlineDiffAction = Notification.Name("inlineDiffAction")
    /// Posted by `TabManager` after a tab's content was reloaded from disk
    /// (e.g., file changed externally and was clean). The CodeEditorView
    /// coordinator listens to forcibly resync NSTextView contents — this
    /// guarantees the editor reflects disk state even if SwiftUI's
    /// observation/binding chain fails to trigger `updateNSView` for the
    /// inner property mutation (issue #734).
    /// userInfo: ["url": URL, "text": String]
    static let tabReloadedFromDisk = Notification.Name("tabReloadedFromDisk")

    // MARK: - Terminal
    /// Find in Terminal (issue #308)
    static let findInTerminal = Notification.Name("findInTerminal")
    /// Send to Terminal (issue #311)
    static let sendToTerminal = Notification.Name("sendToTerminal")
    /// userInfo: ["text": String]
    static let sendTextToTerminal = Notification.Name("sendTextToTerminal")

    // MARK: - Git
    static let refreshLineDiffs = Notification.Name("refreshLineDiffs")
    static let switchBranch = Notification.Name("switchBranch")
}
