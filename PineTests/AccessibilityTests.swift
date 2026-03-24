//
//  AccessibilityTests.swift
//  PineTests
//

import Testing
import Foundation
@testable import Pine

struct AccessibilityTests {

    // MARK: - AccessibilityLabels constants

    @Test func sidebarLabelsExist() {
        #expect(!AccessibilityLabels.sidebar.isEmpty)
        #expect(!AccessibilityLabels.fileTree.isEmpty)
    }

    @Test func editorLabelsExist() {
        #expect(!AccessibilityLabels.editorTabBar.isEmpty)
        #expect(!AccessibilityLabels.editorArea.isEmpty)
        #expect(!AccessibilityLabels.codeEditor.isEmpty)
        #expect(!AccessibilityLabels.noFileOpen.isEmpty)
    }

    @Test func statusBarLabelsExist() {
        #expect(!AccessibilityLabels.statusBar.isEmpty)
        #expect(!AccessibilityLabels.terminalToggle.isEmpty)
        #expect(!AccessibilityLabels.cursorPosition.isEmpty)
        #expect(!AccessibilityLabels.indentation.isEmpty)
        #expect(!AccessibilityLabels.lineEnding.isEmpty)
        #expect(!AccessibilityLabels.fileSize.isEmpty)
        #expect(!AccessibilityLabels.encoding.isEmpty)
    }

    @Test func terminalLabelsExist() {
        #expect(!AccessibilityLabels.terminalArea.isEmpty)
    }

    @Test func welcomeLabelsExist() {
        #expect(!AccessibilityLabels.welcomeWindow.isEmpty)
        #expect(!AccessibilityLabels.openFolderButton.isEmpty)
        #expect(!AccessibilityLabels.recentProjects.isEmpty)
    }

    // MARK: - Dynamic label generation

    @Test func editorTabLabelIncludesFileName() {
        let label = AccessibilityLabels.editorTab(fileName: "main.swift", isActive: false, isDirty: false)
        #expect(label.contains("main.swift"))
    }

    @Test func editorTabLabelIndicatesActiveState() {
        let activeLabel = AccessibilityLabels.editorTab(fileName: "test.swift", isActive: true, isDirty: false)
        let inactiveLabel = AccessibilityLabels.editorTab(fileName: "test.swift", isActive: false, isDirty: false)
        #expect(activeLabel != inactiveLabel)
        #expect(activeLabel.lowercased().contains("selected") || activeLabel.lowercased().contains("active"))
    }

    @Test func editorTabLabelIndicatesDirtyState() {
        let cleanLabel = AccessibilityLabels.editorTab(fileName: "test.swift", isActive: false, isDirty: false)
        let dirtyLabel = AccessibilityLabels.editorTab(fileName: "test.swift", isActive: false, isDirty: true)
        #expect(cleanLabel != dirtyLabel)
        #expect(dirtyLabel.lowercased().contains("unsaved") || dirtyLabel.lowercased().contains("modified"))
    }

    @Test func editorTabCloseHintIncludesFileName() {
        let hint = AccessibilityLabels.closeTabHint(fileName: "main.swift")
        #expect(hint.contains("main.swift"))
    }

    @Test func cursorPositionValueFormat() {
        let value = AccessibilityLabels.cursorPositionValue(line: 42, column: 10)
        #expect(value.contains("42"))
        #expect(value.contains("10"))
    }

    @Test func fileNodeLabelForDirectory() {
        let label = AccessibilityLabels.fileNode(name: "Sources", isDirectory: true)
        #expect(label.contains("Sources"))
        #expect(label.lowercased().contains("folder") || label.lowercased().contains("directory"))
    }

    @Test func fileNodeLabelForFile() {
        let label = AccessibilityLabels.fileNode(name: "main.swift", isDirectory: false)
        #expect(label.contains("main.swift"))
    }

    @Test func gitStatusLabel() {
        let modifiedLabel = AccessibilityLabels.gitStatusDescription(modified: 3, added: 1, untracked: 2)
        #expect(modifiedLabel.contains("3"))
        #expect(modifiedLabel.contains("1"))
        #expect(modifiedLabel.contains("2"))
    }

    @Test func gitStatusLabelWithZeroCounts() {
        let label = AccessibilityLabels.gitStatusDescription(modified: 0, added: 0, untracked: 0)
        #expect(!label.isEmpty)
    }

    @Test func recentProjectLabel() {
        let label = AccessibilityLabels.recentProject(name: "MyProject", path: "~/Projects/MyProject")
        #expect(label.contains("MyProject"))
        #expect(label.contains("~/Projects/MyProject"))
    }

    @Test func terminalToggleHintWhenVisible() {
        let hint = AccessibilityLabels.terminalToggleHint(isVisible: true)
        #expect(hint.lowercased().contains("hide"))
    }

    @Test func terminalToggleHintWhenHidden() {
        let hint = AccessibilityLabels.terminalToggleHint(isVisible: false)
        #expect(hint.lowercased().contains("show"))
    }

    // MARK: - AccessibilityID completeness

    @Test func accessibilityIDsAreDefined() {
        // Verify key IDs are non-empty strings
        #expect(!AccessibilityID.sidebar.isEmpty)
        #expect(!AccessibilityID.editorTabBar.isEmpty)
        #expect(!AccessibilityID.statusBar.isEmpty)
        #expect(!AccessibilityID.terminalArea.isEmpty)
        #expect(!AccessibilityID.welcomeWindow.isEmpty)
        #expect(!AccessibilityID.codeEditor.isEmpty)
        #expect(!AccessibilityID.editorPlaceholder.isEmpty)
    }

    @Test func dynamicAccessibilityIDsContainName() {
        let tabID = AccessibilityID.editorTab("main.swift")
        #expect(tabID.contains("main.swift"))

        let nodeID = AccessibilityID.fileNode("Sources")
        #expect(nodeID.contains("Sources"))

        let projectID = AccessibilityID.welcomeRecentProject("Pine")
        #expect(projectID.contains("Pine"))
    }
}
