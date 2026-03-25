//
//  AccessibilityLabels.swift
//  Pine
//
//  VoiceOver accessibility labels, hints, and values for UI elements.
//  Centralized here to keep views clean and to make testing straightforward.
//
//  ## AccessibilityLabels vs AccessibilityIdentifiers (AccessibilityID)
//
//  - **AccessibilityIdentifiers** (`AccessibilityID`): Stable, non-localized programmatic IDs
//    used by UI tests to find elements (e.g. `"editorTab_main.swift"`). These are set via
//    `.accessibilityIdentifier()` and are invisible to the user.
//
//  - **AccessibilityLabels** (this enum): Human-readable, localized text spoken by VoiceOver
//    to describe UI elements (e.g. "Code editor" / "Редактор кода"). These are set via
//    `.accessibilityLabel()` and must be translated into all supported languages.
//

import Foundation

// TODO: [М2] Accessibility labels not yet covered: MinimapView, QuickOpenView,
// GoToLineView, BranchSwitcherView, MarkdownPreviewView. Add in follow-up.

enum AccessibilityLabels {

    // MARK: - Static labels (С2: static let для однократной инициализации)

    static let sidebar = String(localized: "a11y.sidebar")
    static let fileTree = String(localized: "a11y.fileTree")
    static let editorTabBar = String(localized: "a11y.editorTabBar")
    static let editorArea = String(localized: "a11y.editorArea")
    static let codeEditor = String(localized: "a11y.codeEditor")
    static let noFileOpen = String(localized: "a11y.noFileOpen")
    static let statusBar = String(localized: "a11y.statusBar")
    static let terminalToggle = String(localized: "a11y.terminalToggle")
    static let terminalArea = String(localized: "a11y.terminalArea")
    static let welcomeWindow = String(localized: "a11y.welcomeWindow")
    static let openFolderButton = String(localized: "a11y.openFolderButton")
    static let openFolderHint = String(localized: "a11y.openFolderHint")
    static let recentProjects = String(localized: "a11y.recentProjects")
    static let cursorPosition = String(localized: "a11y.cursorPosition")
    static let indentation = String(localized: "a11y.indentation")
    static let lineEnding = String(localized: "a11y.lineEnding")
    static let fileSize = String(localized: "a11y.fileSize")
    static let encoding = String(localized: "a11y.encoding")
    /// Localized "Close" for tab close buttons (К3: не hardcoded).
    static let closeButton = String(localized: "a11y.tab.close")
    /// Localized "pinned" trait for pinned tabs (К2).
    static let tabPinned = String(localized: "a11y.tab.pinned")

    // MARK: - Dynamic labels

    /// Label for an editor tab (supports pinned state).
    static func editorTab(fileName: String, isActive: Bool, isDirty: Bool, isPinned: Bool = false) -> String {
        var parts = [fileName]
        if isPinned {
            parts.append(String(localized: "a11y.tab.pinned"))
        }
        if isActive {
            parts.append(String(localized: "a11y.tab.selected"))
        }
        if isDirty {
            parts.append(String(localized: "a11y.tab.unsavedChanges"))
        }
        return parts.joined(separator: ", ")
    }

    /// Hint for a tab close button.
    static func closeTabHint(fileName: String) -> String {
        String(localized: "a11y.tab.closeHint \(fileName)")
    }

    /// Value for cursor position indicator.
    static func cursorPositionValue(line: Int, column: Int) -> String {
        String(localized: "a11y.cursorPositionValue \(line) \(column)")
    }

    /// Label for a file node in the sidebar.
    static func fileNode(name: String, isDirectory: Bool) -> String {
        isDirectory ? String(localized: "a11y.fileNode.folder \(name)") : name
    }

    // TODO: [М1] git status counts use simple %lld interpolation without plural forms (.stringsdict).
    // Follow-up: add proper pluralization for added/modified/untracked counts.

    /// Label describing git status counts.
    static func gitStatusDescription(modified: Int, added: Int, untracked: Int) -> String {
        var parts: [String] = []
        if modified > 0 {
            parts.append(String(localized: "a11y.git.modified \(modified)"))
        }
        if added > 0 {
            parts.append(String(localized: "a11y.git.added \(added)"))
        }
        if untracked > 0 {
            parts.append(String(localized: "a11y.git.untracked \(untracked)"))
        }
        if parts.isEmpty {
            return String(localized: "a11y.git.noChanges")
        }
        return parts.joined(separator: ", ")
    }

    /// Label for a recent project row (С1: локализован через xcstrings).
    static func recentProject(name: String, path: String) -> String {
        String(localized: "a11y.recentProject \(name) \(path)")
    }

    /// Hint for terminal toggle button.
    static func terminalToggleHint(isVisible: Bool) -> String {
        isVisible
            ? String(localized: "a11y.terminal.hide")
            : String(localized: "a11y.terminal.show")
    }
}
