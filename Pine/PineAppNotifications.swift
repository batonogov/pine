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
    /// Creates a new untitled editable buffer (File → New File).
    static let newFile = Notification.Name("newFile")
    /// Opens a single file via the open panel (File → Open…).
    static let openFile = Notification.Name("openFile")
    static let openFolder = Notification.Name("openFolder")
    /// Opens a recent project (File → Open Recent submenu).
    /// userInfo: ["url": URL]
    static let openRecentProject = Notification.Name("openRecentProject")
    /// Clears the recent-projects menu (File → Open Recent → Clear Menu).
    static let clearRecentProjects = Notification.Name("clearRecentProjects")
    static let closeTab = Notification.Name("closeTab")
    /// Closes the active project window (File → Close Window).
    static let closeWindow = Notification.Name("closeWindow")
    /// Takes the active project out of its window, leaving the window open on
    /// the projects beside it (File → Close Project).
    static let closeProject = Notification.Name("closeProject")
    static let showQuickOpen = Notification.Name("showQuickOpen")
    static let showCommandPalette = Notification.Name("showCommandPalette")
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

    /// Opens a file at a specific line and optional column.
    /// Posted when the user clicks a `file:line` reference in terminal
    /// output (issue #949).
    /// userInfo: ["url": URL, "line": Int, "column": Int?]
    static let openFileAtLine = Notification.Name("openFileAtLine")

    // MARK: - Terminal
    /// Find in Terminal (issue #308)
    static let findInTerminal = Notification.Name("findInTerminal")
    /// Send to Terminal (issue #311)
    static let sendToTerminal = Notification.Name("sendToTerminal")
    /// userInfo: ["text": String]
    static let sendTextToTerminal = Notification.Name("sendTextToTerminal")

    // MARK: - Agent Activity Panel (vision #933, Phase 2 — #1072)
    static let showAgentActivity = Notification.Name("showAgentActivity")

    /// Opens the application-level cross-project Agent Inbox (#1305).
    static let showAgentInbox = Notification.Name("showAgentInbox")

    // MARK: - Agent history (#1073)
    /// Shows the persistent agent-history timeline sheet.
    static let showAgentHistory = Notification.Name("showAgentHistory")

    // MARK: - Agent worktrees (#1524, #1525)
    /// Starts an agent in a fresh worktree off the target window's active
    /// repository.
    /// userInfo: ["agentIdentifier": String] — absent means the preferred
    /// (last-used) agent.
    static let newAgent = Notification.Name("newAgent")

    /// Changes which project or agent worktree the target window shows.
    /// userInfo: ["url": URL] for a named row, or ["direction": "next" |
    /// "previous"] to step through the switcher order.
    static let switchProjectInWindow = Notification.Name(
        "switchProjectInWindow"
    )

    /// Shows the sheet that lists, merges, and removes the git worktrees Pine
    /// created for agent tasks.
    static let showAgentWorktrees = Notification.Name("showAgentWorktrees")

    // MARK: - Agent handoff (#933)
    /// Posted after the user changes the read-only editor-context permission.
    static let agentHandoffSettingsChanged = Notification.Name(
        "agentHandoffSettingsChanged"
    )

    // MARK: - Git
    static let showBranchSwitcher = Notification.Name("showBranchSwitcher")
    static let refreshLineDiffs = Notification.Name("refreshLineDiffs")

    // MARK: - Problems panel (#1236)
    /// Toggles (shows) the bottom Problems panel.
    static let showProblems = Notification.Name("showProblems")
    /// Navigates to the next diagnostic in the Problems panel (wrap-around).
    static let nextDiagnostic = Notification.Name("nextDiagnostic")
    /// Navigates to the previous diagnostic (wrap-around).
    static let previousDiagnostic = Notification.Name("previousDiagnostic")
}
