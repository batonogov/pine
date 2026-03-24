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

enum AccessibilityLabels {

    // MARK: - Static labels

    static var sidebar: String {
        String(localized: "a11y.sidebar")
    }

    static var fileTree: String {
        String(localized: "a11y.fileTree")
    }

    static var editorTabBar: String {
        String(localized: "a11y.editorTabBar")
    }

    static var editorArea: String {
        String(localized: "a11y.editorArea")
    }

    static var codeEditor: String {
        String(localized: "a11y.codeEditor")
    }

    static var noFileOpen: String {
        String(localized: "a11y.noFileOpen")
    }

    static var statusBar: String {
        String(localized: "a11y.statusBar")
    }

    static var terminalToggle: String {
        String(localized: "a11y.terminalToggle")
    }

    static var terminalArea: String {
        String(localized: "a11y.terminalArea")
    }

    static var welcomeWindow: String {
        String(localized: "a11y.welcomeWindow")
    }

    static var openFolderButton: String {
        String(localized: "a11y.openFolderButton")
    }

    static var recentProjects: String {
        String(localized: "a11y.recentProjects")
    }

    static var cursorPosition: String {
        String(localized: "a11y.cursorPosition")
    }

    static var indentation: String {
        String(localized: "a11y.indentation")
    }

    static var lineEnding: String {
        String(localized: "a11y.lineEnding")
    }

    static var fileSize: String {
        String(localized: "a11y.fileSize")
    }

    static var encoding: String {
        String(localized: "a11y.encoding")
    }

    // MARK: - Dynamic labels

    /// Label for an editor tab.
    static func editorTab(fileName: String, isActive: Bool, isDirty: Bool) -> String {
        var parts = [fileName]
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

    /// Label for a recent project row.
    static func recentProject(name: String, path: String) -> String {
        "\(name), \(path)"
    }

    /// Hint for terminal toggle button.
    static func terminalToggleHint(isVisible: Bool) -> String {
        isVisible
            ? String(localized: "a11y.terminal.hide")
            : String(localized: "a11y.terminal.show")
    }
}
