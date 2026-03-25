//
//  AccessibilityTests.swift
//  PineTests
//

import Testing
import Foundation
@testable import Pine

struct AccessibilityTests {

    // MARK: - Static labels — verify non-empty and distinct

    @Test func sidebarLabelIsNonEmpty() {
        #expect(!AccessibilityLabels.sidebar.isEmpty)
    }

    @Test func fileTreeLabelIsNonEmpty() {
        #expect(!AccessibilityLabels.fileTree.isEmpty)
    }

    @Test func editorTabBarLabelIsNonEmpty() {
        #expect(!AccessibilityLabels.editorTabBar.isEmpty)
    }

    @Test func editorAreaLabelIsNonEmpty() {
        #expect(!AccessibilityLabels.editorArea.isEmpty)
    }

    @Test func codeEditorLabelIsNonEmpty() {
        #expect(!AccessibilityLabels.codeEditor.isEmpty)
    }

    @Test func noFileOpenLabelIsNonEmpty() {
        #expect(!AccessibilityLabels.noFileOpen.isEmpty)
    }

    @Test func statusBarLabelIsNonEmpty() {
        #expect(!AccessibilityLabels.statusBar.isEmpty)
    }

    @Test func welcomeWindowLabelIsNonEmpty() {
        #expect(!AccessibilityLabels.welcomeWindow.isEmpty)
    }

    @Test func openFolderButtonLabelIsNonEmpty() {
        #expect(!AccessibilityLabels.openFolderButton.isEmpty)
    }

    @Test func openFolderHintIsNonEmpty() {
        #expect(!AccessibilityLabels.openFolderHint.isEmpty)
    }

    @Test func recentProjectsLabelIsNonEmpty() {
        #expect(!AccessibilityLabels.recentProjects.isEmpty)
    }

    @Test func cursorPositionLabelIsNonEmpty() {
        #expect(!AccessibilityLabels.cursorPosition.isEmpty)
    }

    @Test func indentationLabelIsNonEmpty() {
        #expect(!AccessibilityLabels.indentation.isEmpty)
    }

    @Test func lineEndingLabelIsNonEmpty() {
        #expect(!AccessibilityLabels.lineEnding.isEmpty)
    }

    @Test func fileSizeLabelIsNonEmpty() {
        #expect(!AccessibilityLabels.fileSize.isEmpty)
    }

    @Test func encodingLabelIsNonEmpty() {
        #expect(!AccessibilityLabels.encoding.isEmpty)
    }

    @Test func closeButtonLabelIsNonEmpty() {
        // К3: localized close button text — must be non-empty
        #expect(!AccessibilityLabels.closeButton.isEmpty)
    }

    @Test func tabPinnedLabelIsNonEmpty() {
        // К2: localized "pinned" text — must be non-empty
        #expect(!AccessibilityLabels.tabPinned.isEmpty)
    }

    // MARK: - С5: terminalToggle and terminalArea must differ

    @Test func terminalToggleDiffersFromTerminalArea() {
        #expect(AccessibilityLabels.terminalToggle != AccessibilityLabels.terminalArea)
    }

    @Test func terminalToggleIsNonEmpty() {
        #expect(!AccessibilityLabels.terminalToggle.isEmpty)
    }

    @Test func terminalAreaIsNonEmpty() {
        #expect(!AccessibilityLabels.terminalArea.isEmpty)
    }

    // MARK: - С2: static let consistency (same value on repeated access)

    @Test func staticLetReturnsSameValue() {
        let first = AccessibilityLabels.sidebar
        let second = AccessibilityLabels.sidebar
        #expect(first == second)
    }

    // MARK: - Editor tab labels — all combinations

    @Test func editorTabPlainLabelIsJustFileName() {
        let label = AccessibilityLabels.editorTab(
            fileName: "main.swift", isActive: false, isDirty: false
        )
        #expect(label == "main.swift")
    }

    @Test func editorTabActiveLabelContainsMore() {
        let plain = AccessibilityLabels.editorTab(fileName: "main.swift", isActive: false, isDirty: false)
        let active = AccessibilityLabels.editorTab(fileName: "main.swift", isActive: true, isDirty: false)
        #expect(active != plain)
        #expect(active.hasPrefix("main.swift"))
        #expect(active.count > plain.count)
    }

    @Test func editorTabDirtyLabelContainsMore() {
        let clean = AccessibilityLabels.editorTab(fileName: "test.swift", isActive: false, isDirty: false)
        let dirty = AccessibilityLabels.editorTab(fileName: "test.swift", isActive: false, isDirty: true)
        #expect(dirty != clean)
        #expect(dirty.hasPrefix("test.swift"))
        #expect(dirty.count > clean.count)
    }

    @Test func editorTabActiveAndDirtyLabelHasBothParts() {
        let plain = AccessibilityLabels.editorTab(fileName: "app.swift", isActive: false, isDirty: false)
        let activeOnly = AccessibilityLabels.editorTab(fileName: "app.swift", isActive: true, isDirty: false)
        let dirtyOnly = AccessibilityLabels.editorTab(fileName: "app.swift", isActive: false, isDirty: true)
        let both = AccessibilityLabels.editorTab(fileName: "app.swift", isActive: true, isDirty: true)

        // The full label should be longer than either single-trait version
        #expect(both.count > activeOnly.count)
        #expect(both.count > dirtyOnly.count)
        #expect(both.count > plain.count)
        #expect(both.hasPrefix("app.swift"))
    }

    @Test func editorTabPinnedLabelIncludesPinnedTrait() {
        // К2: pinned tab must include pinned trait
        let plain = AccessibilityLabels.editorTab(
            fileName: "config.json", isActive: false, isDirty: false, isPinned: false
        )
        let pinned = AccessibilityLabels.editorTab(
            fileName: "config.json", isActive: false, isDirty: false, isPinned: true
        )
        #expect(pinned != plain)
        #expect(pinned.contains(AccessibilityLabels.tabPinned))
        #expect(pinned.hasPrefix("config.json"))
    }

    @Test func editorTabPinnedAndActiveLabel() {
        let label = AccessibilityLabels.editorTab(
            fileName: "config.json", isActive: true, isDirty: false, isPinned: true
        )
        #expect(label.hasPrefix("config.json"))
        #expect(label.contains(AccessibilityLabels.tabPinned))
        // Should have 3 comma-separated parts: name, pinned, selected
        let commaCount = label.filter { $0 == "," }.count
        #expect(commaCount == 2)
    }

    @Test func editorTabPinnedAndDirtyLabel() {
        let label = AccessibilityLabels.editorTab(
            fileName: "config.json", isActive: false, isDirty: true, isPinned: true
        )
        #expect(label.hasPrefix("config.json"))
        #expect(label.contains(AccessibilityLabels.tabPinned))
        let commaCount = label.filter { $0 == "," }.count
        #expect(commaCount == 2)
    }

    @Test func editorTabPinnedActiveDirtyLabel() {
        let label = AccessibilityLabels.editorTab(
            fileName: "config.json", isActive: true, isDirty: true, isPinned: true
        )
        #expect(label.hasPrefix("config.json"))
        // Should have 4 comma-separated parts: name, pinned, selected, dirty
        let commaCount = label.filter { $0 == "," }.count
        #expect(commaCount == 3)
    }

    // MARK: - Edge cases: file names

    @Test func editorTabEmptyFileName() {
        let label = AccessibilityLabels.editorTab(
            fileName: "", isActive: false, isDirty: false
        )
        #expect(label == "")
    }

    @Test func editorTabVeryLongFileName() {
        let longName = String(repeating: "a", count: 500) + ".swift"
        let label = AccessibilityLabels.editorTab(
            fileName: longName, isActive: true, isDirty: false
        )
        #expect(label.hasPrefix(String(repeating: "a", count: 500)))
        #expect(label.count > longName.count) // includes ", selected"
    }

    @Test func editorTabSpecialCharactersInFileName() {
        let specialName = "файл (copy) [2].swift"
        let label = AccessibilityLabels.editorTab(
            fileName: specialName, isActive: false, isDirty: true
        )
        #expect(label.hasPrefix(specialName))
        #expect(label.count > specialName.count) // includes dirty trait
    }

    @Test func editorTabUnicodeFileName() {
        let unicodeName = "日本語ファイル.txt"
        let label = AccessibilityLabels.editorTab(
            fileName: unicodeName, isActive: true, isDirty: true
        )
        #expect(label.hasPrefix(unicodeName))
    }

    @Test func editorTabFileNameWithComma() {
        // Edge case: comma in file name shouldn't break the label structure
        let label = AccessibilityLabels.editorTab(
            fileName: "file,name.txt", isActive: true, isDirty: false
        )
        #expect(label.hasPrefix("file,name.txt"))
    }

    // MARK: - Close tab hint

    @Test func closeTabHintContainsFileName() {
        let hint = AccessibilityLabels.closeTabHint(fileName: "main.swift")
        #expect(hint.contains("main.swift"))
        #expect(!hint.isEmpty)
    }

    @Test func closeTabHintEmptyName() {
        // Should not crash and should be non-empty (still has "Close" prefix)
        let hint = AccessibilityLabels.closeTabHint(fileName: "")
        #expect(!hint.isEmpty)
    }

    // MARK: - Cursor position value

    @Test func cursorPositionContainsNumbers() {
        let value = AccessibilityLabels.cursorPositionValue(line: 42, column: 10)
        #expect(value.contains("42"))
        #expect(value.contains("10"))
    }

    @Test func cursorPositionFirstLineFirstColumn() {
        let value = AccessibilityLabels.cursorPositionValue(line: 1, column: 1)
        #expect(value.contains("1"))
    }

    @Test func cursorPositionLargeValues() {
        let value = AccessibilityLabels.cursorPositionValue(line: 99999, column: 500)
        // Number formatting may include locale-specific grouping (e.g. "99 999" or "99,999")
        // so check for the raw digits being present somewhere
        let digitsOnly = value.filter { $0.isNumber }
        #expect(digitsOnly.contains("99999"))
        #expect(digitsOnly.contains("500"))
    }

    // MARK: - File node labels

    @Test func fileNodeDirectoryLabelLongerThanName() {
        let label = AccessibilityLabels.fileNode(name: "Sources", isDirectory: true)
        #expect(label.contains("Sources"))
        // Directory label includes localized descriptor
        #expect(label.count > "Sources".count)
    }

    @Test func fileNodeFileLabelIsJustName() {
        let label = AccessibilityLabels.fileNode(name: "main.swift", isDirectory: false)
        #expect(label == "main.swift")
    }

    @Test func fileNodeEmptyNameDirectory() {
        let label = AccessibilityLabels.fileNode(name: "", isDirectory: true)
        // Should still contain the localized folder descriptor
        #expect(!label.isEmpty)
    }

    @Test func fileNodeEmptyNameFile() {
        let label = AccessibilityLabels.fileNode(name: "", isDirectory: false)
        #expect(label == "")
    }

    // MARK: - Git status labels

    @Test func gitStatusAllZerosReturnsNonEmpty() {
        let label = AccessibilityLabels.gitStatusDescription(
            modified: 0, added: 0, untracked: 0
        )
        #expect(!label.isEmpty) // Returns "No changes" or localized equivalent
    }

    @Test func gitStatusModifiedOnly() {
        let label = AccessibilityLabels.gitStatusDescription(
            modified: 3, added: 0, untracked: 0
        )
        #expect(label.contains("3"))
        // Only one part, no commas
        #expect(!label.contains(","))
    }

    @Test func gitStatusAddedOnly() {
        let label = AccessibilityLabels.gitStatusDescription(
            modified: 0, added: 1, untracked: 0
        )
        #expect(label.contains("1"))
        #expect(!label.contains(","))
    }

    @Test func gitStatusUntrackedOnly() {
        let label = AccessibilityLabels.gitStatusDescription(
            modified: 0, added: 0, untracked: 5
        )
        #expect(label.contains("5"))
        #expect(!label.contains(","))
    }

    @Test func gitStatusAllCounts() {
        let label = AccessibilityLabels.gitStatusDescription(
            modified: 3, added: 1, untracked: 2
        )
        #expect(label.contains("3"))
        #expect(label.contains("1"))
        #expect(label.contains("2"))
        // Three parts joined by comma
        let commaCount = label.filter { $0 == "," }.count
        #expect(commaCount == 2)
    }

    @Test func gitStatusTwoCounts() {
        let label = AccessibilityLabels.gitStatusDescription(
            modified: 7, added: 0, untracked: 4
        )
        #expect(label.contains("7"))
        #expect(label.contains("4"))
        let commaCount = label.filter { $0 == "," }.count
        #expect(commaCount == 1)
    }

    @Test func gitStatusLargeNumbers() {
        let label = AccessibilityLabels.gitStatusDescription(
            modified: 100, added: 200, untracked: 300
        )
        #expect(label.contains("100"))
        #expect(label.contains("200"))
        #expect(label.contains("300"))
    }

    @Test func gitStatusSingleFile() {
        let label = AccessibilityLabels.gitStatusDescription(
            modified: 1, added: 0, untracked: 0
        )
        #expect(label.contains("1"))
    }

    // MARK: - Recent project labels (С1: localized)

    @Test func recentProjectContainsBothParts() {
        let label = AccessibilityLabels.recentProject(
            name: "MyProject", path: "~/Projects/MyProject"
        )
        #expect(label.contains("MyProject"))
        #expect(label.contains("~/Projects/MyProject"))
    }

    @Test func recentProjectWithSpaces() {
        let label = AccessibilityLabels.recentProject(
            name: "My Project", path: "~/My Projects/My Project"
        )
        #expect(label.contains("My Project"))
        #expect(label.contains("~/My Projects/My Project"))
    }

    @Test func recentProjectWithUnicode() {
        let label = AccessibilityLabels.recentProject(
            name: "Проект", path: "~/Документы/Проект"
        )
        #expect(label.contains("Проект"))
        #expect(label.contains("~/Документы/Проект"))
    }

    @Test func recentProjectEmptyName() {
        let label = AccessibilityLabels.recentProject(name: "", path: "/some/path")
        #expect(label.contains("/some/path"))
    }

    @Test func recentProjectEmptyPath() {
        let label = AccessibilityLabels.recentProject(name: "Proj", path: "")
        #expect(label.contains("Proj"))
    }

    // MARK: - Terminal toggle hint

    @Test func terminalToggleHintsAreDifferent() {
        let visible = AccessibilityLabels.terminalToggleHint(isVisible: true)
        let hidden = AccessibilityLabels.terminalToggleHint(isVisible: false)
        #expect(visible != hidden)
        #expect(!visible.isEmpty)
        #expect(!hidden.isEmpty)
    }

    // MARK: - All static labels are distinct from each other

    @Test func staticLabelsAreDistinct() {
        let labels = [
            AccessibilityLabels.sidebar,
            AccessibilityLabels.fileTree,
            AccessibilityLabels.editorTabBar,
            AccessibilityLabels.editorArea,
            AccessibilityLabels.codeEditor,
            AccessibilityLabels.noFileOpen,
            AccessibilityLabels.statusBar,
            AccessibilityLabels.terminalToggle,
            AccessibilityLabels.terminalArea,
            AccessibilityLabels.welcomeWindow,
            AccessibilityLabels.openFolderButton,
            AccessibilityLabels.recentProjects,
            AccessibilityLabels.cursorPosition,
            AccessibilityLabels.indentation,
            AccessibilityLabels.lineEnding,
            AccessibilityLabels.fileSize,
            AccessibilityLabels.encoding,
            AccessibilityLabels.closeButton,
            AccessibilityLabels.tabPinned
        ]
        let unique = Set(labels)
        // All labels must be unique — no two labels should resolve to the same string
        #expect(unique.count == labels.count)
    }

    // MARK: - AccessibilityID completeness

    @Test func accessibilityIDsAreDefined() {
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
