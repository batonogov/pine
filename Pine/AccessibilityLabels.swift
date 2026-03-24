//
//  AccessibilityLabels.swift
//  Pine
//
//  VoiceOver accessibility labels, hints, and values for UI elements.
//  Centralized here to keep views clean and to make testing straightforward.
//

import Foundation

enum AccessibilityLabels {

    // MARK: - Static labels

    static let sidebar = "File navigator"
    static let fileTree = "Project files"
    static let editorTabBar = "Open files"
    static let editorArea = "Editor"
    static let codeEditor = "Code editor"
    static let noFileOpen = "No file open"
    static let statusBar = "Status bar"
    static let terminalToggle = "Terminal"
    static let terminalArea = "Terminal"
    static let welcomeWindow = "Welcome to Pine"
    static let openFolderButton = "Open folder"
    static let recentProjects = "Recent projects"
    static let cursorPosition = "Cursor position"
    static let indentation = "Indentation"
    static let lineEnding = "Line ending"
    static let fileSize = "File size"
    static let encoding = "File encoding"

    // MARK: - Dynamic labels

    /// Label for an editor tab.
    static func editorTab(fileName: String, isActive: Bool, isDirty: Bool) -> String {
        var parts = [fileName]
        if isActive {
            parts.append("selected")
        }
        if isDirty {
            parts.append("unsaved changes")
        }
        return parts.joined(separator: ", ")
    }

    /// Hint for a tab close button.
    static func closeTabHint(fileName: String) -> String {
        "Close \(fileName)"
    }

    /// Value for cursor position indicator.
    static func cursorPositionValue(line: Int, column: Int) -> String {
        "Line \(line), Column \(column)"
    }

    /// Label for a file node in the sidebar.
    static func fileNode(name: String, isDirectory: Bool) -> String {
        isDirectory ? "\(name) folder" : name
    }

    /// Label describing git status counts.
    static func gitStatusDescription(modified: Int, added: Int, untracked: Int) -> String {
        var parts: [String] = []
        if modified > 0 {
            parts.append("\(modified) modified")
        }
        if added > 0 {
            parts.append("\(added) added")
        }
        if untracked > 0 {
            parts.append("\(untracked) untracked")
        }
        if parts.isEmpty {
            return "No changes"
        }
        return parts.joined(separator: ", ")
    }

    /// Label for a recent project row.
    static func recentProject(name: String, path: String) -> String {
        "\(name), \(path)"
    }

    /// Hint for terminal toggle button.
    static func terminalToggleHint(isVisible: Bool) -> String {
        isVisible ? "Hide terminal" : "Show terminal"
    }
}
