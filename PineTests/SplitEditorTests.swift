//
//  SplitEditorTests.swift
//  PineTests
//
//  Tests for split editor functionality.
//

import Foundation
import Testing

@testable import Pine

@Suite("Split Editor Tests")
struct SplitEditorTests {

    /// Creates a temporary file URL for testing.
    private func tempFileURL(name: String = "test.swift", content: String = "hello") -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try? content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - SplitPane basic operations

    @Test("SplitPane opens tab and activates it")
    func splitPaneOpenTab() {
        let pane = SplitPane()
        let url = tempFileURL(content: "let x = 1")

        pane.openTab(url: url)

        #expect(pane.tabs.count == 1)
        #expect(pane.activeTab?.url == url)
        #expect(pane.activeTab?.content == "let x = 1")
    }

    @Test("SplitPane deduplicates tabs")
    func splitPaneDedup() {
        let pane = SplitPane()
        let url = tempFileURL()

        pane.openTab(url: url)
        let firstID = pane.activeTabID
        pane.openTab(url: url)

        #expect(pane.tabs.count == 1)
        #expect(pane.activeTabID == firstID)
    }

    @Test("SplitPane closes tab and selects adjacent")
    func splitPaneCloseTab() {
        let pane = SplitPane()
        let url1 = tempFileURL(name: "a.swift")
        let url2 = tempFileURL(name: "b.swift")

        pane.openTab(url: url1)
        pane.openTab(url: url2)

        guard let id = pane.activeTabID else {
            Issue.record("activeTabID should not be nil")
            return
        }
        pane.closeTab(id: id)

        #expect(pane.tabs.count == 1)
        #expect(pane.activeTab?.url == url1)
    }

    @Test("SplitPane update content marks dirty")
    func splitPaneUpdateContent() {
        let pane = SplitPane()
        let url = tempFileURL(content: "original")

        pane.openTab(url: url)
        pane.updateContent("modified")

        #expect(pane.activeTab?.isDirty == true)
        #expect(pane.activeTab?.content == "modified")
    }

    @Test("SplitPane update editor state")
    func splitPaneUpdateEditorState() {
        let pane = SplitPane()
        let url = tempFileURL()

        pane.openTab(url: url)
        pane.updateEditorState(cursorPosition: 42, scrollOffset: 100)

        #expect(pane.activeTab?.cursorPosition == 42)
        #expect(pane.activeTab?.scrollOffset == 100)
    }

    @Test("SplitPane save active tab")
    func splitPaneSaveActiveTab() {
        let pane = SplitPane()
        let url = tempFileURL(content: "original")

        pane.openTab(url: url)
        pane.updateContent("modified")
        #expect(pane.activeTab?.isDirty == true)

        let success = pane.saveActiveTab()
        #expect(success == true)
        #expect(pane.activeTab?.isDirty == false)

        let onDisk = try? String(contentsOf: url, encoding: .utf8)
        #expect(onDisk == "modified")
    }

    @Test("SplitPane hasUnsavedChanges")
    func splitPaneHasUnsavedChanges() {
        let pane = SplitPane()
        let url = tempFileURL(content: "clean")

        pane.openTab(url: url)
        #expect(pane.hasUnsavedChanges == false)

        pane.updateContent("dirty")
        #expect(pane.hasUnsavedChanges == true)
    }

    @Test("SplitPane handleFileRenamed")
    func splitPaneHandleFileRenamed() {
        let pane = SplitPane()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let oldURL = dir.appendingPathComponent("old.swift")
        let newURL = dir.appendingPathComponent("new.swift")
        try? "content".write(to: oldURL, atomically: true, encoding: .utf8)

        pane.openTab(url: oldURL)
        let originalID = pane.activeTabID

        pane.handleFileRenamed(oldURL: oldURL, newURL: newURL)

        #expect(pane.activeTab?.url == newURL)
        #expect(pane.activeTabID == originalID)
    }

    @Test("SplitPane closeTabsForDeletedFile")
    func splitPaneCloseTabsForDeletedFile() {
        let pane = SplitPane()
        let url1 = tempFileURL(name: "a.swift")
        let url2 = tempFileURL(name: "b.swift")

        pane.openTab(url: url1)
        pane.openTab(url: url2)

        pane.closeTabsForDeletedFile(url: url1)

        #expect(pane.tabs.count == 1)
        #expect(pane.tabs[0].url == url2)
    }

    // MARK: - TabManager split operations

    @Test("splitRight creates split pane")
    func splitRightCreatesSplitPane() {
        let manager = TabManager()
        let url = tempFileURL()
        manager.openTab(url: url)

        manager.splitRight()

        #expect(manager.isSplitActive == true)
        #expect(manager.splitPane != nil)
        #expect(manager.splitPane?.tabs.isEmpty == true)
    }

    @Test("splitRight with moveActiveTab moves tab to trailing pane")
    func splitRightMoveActiveTab() {
        let manager = TabManager()
        let url = tempFileURL(content: "let x = 1")
        manager.openTab(url: url)

        manager.splitRight(moveActiveTab: true)

        #expect(manager.isSplitActive == true)
        #expect(manager.tabs.isEmpty)
        #expect(manager.splitPane?.tabs.count == 1)
        #expect(manager.splitPane?.activeTab?.url == url)
        #expect(manager.focusedSide == .trailing)
    }

    @Test("splitRight does nothing if already split")
    func splitRightIdempotent() {
        let manager = TabManager()
        manager.splitRight()
        let pane = manager.splitPane

        manager.splitRight()

        #expect(manager.splitPane === pane)
    }

    @Test("closeSplit merges tabs back to primary")
    func closeSplitMergesTabs() {
        let manager = TabManager()
        let url1 = tempFileURL(name: "a.swift")
        let url2 = tempFileURL(name: "b.swift")

        manager.openTab(url: url1)
        manager.splitRight()
        manager.splitPane?.openTab(url: url2)

        manager.closeSplit()

        #expect(manager.isSplitActive == false)
        #expect(manager.tabs.count == 2)
        #expect(manager.tabs.contains(where: { $0.url == url1 }))
        #expect(manager.tabs.contains(where: { $0.url == url2 }))
        #expect(manager.focusedSide == .leading)
    }

    @Test("closeSplit does not duplicate tabs already in primary")
    func closeSplitNoDuplicates() {
        let manager = TabManager()
        let url = tempFileURL()

        manager.openTab(url: url)
        manager.splitRight()
        // Open same file in split pane
        manager.splitPane?.openTab(url: url)

        manager.closeSplit()

        #expect(manager.tabs.count == 1)
    }

    @Test("moveTabToOtherPane moves from leading to trailing")
    func moveTabLeadingToTrailing() {
        let manager = TabManager()
        let url1 = tempFileURL(name: "a.swift")
        let url2 = tempFileURL(name: "b.swift")

        manager.openTab(url: url1)
        manager.openTab(url: url2)
        manager.splitRight()

        manager.focusedSide = .leading
        manager.moveTabToOtherPane()

        #expect(manager.tabs.count == 1)
        #expect(manager.tabs[0].url == url1) // url2 moved, url1 became active then b was moved
        #expect(manager.splitPane?.tabs.count == 1)
        #expect(manager.splitPane?.activeTab?.url == url2)
        #expect(manager.focusedSide == .trailing)
    }

    @Test("moveTabToOtherPane moves from trailing to leading")
    func moveTabTrailingToLeading() {
        let manager = TabManager()
        let url1 = tempFileURL(name: "a.swift")
        let url2 = tempFileURL(name: "b.swift")

        manager.openTab(url: url1)
        manager.splitRight()
        manager.splitPane?.openTab(url: url2)

        manager.focusedSide = .trailing
        manager.moveTabToOtherPane()

        #expect(manager.tabs.count == 2)
        #expect(manager.tabs.contains(where: { $0.url == url2 }))
        // Split pane had only one tab which was moved → auto-closed
        #expect(manager.isSplitActive == false)
        #expect(manager.focusedSide == .leading)
    }

    @Test("moveTabToOtherPane does nothing without split")
    func moveTabNoSplit() {
        let manager = TabManager()
        let url = tempFileURL()
        manager.openTab(url: url)

        manager.moveTabToOtherPane()

        #expect(manager.tabs.count == 1)
    }

    @Test("openInSplit creates split and opens file in trailing pane")
    func openInSplit() {
        let manager = TabManager()
        let url1 = tempFileURL(name: "a.swift")
        let url2 = tempFileURL(name: "b.swift")

        manager.openTab(url: url1)
        manager.openInSplit(url: url2)

        #expect(manager.isSplitActive == true)
        #expect(manager.splitPane?.activeTab?.url == url2)
        #expect(manager.focusedSide == .trailing)
    }

    @Test("Closing last tab in split auto-closes split")
    func closingLastTabAutoClosesSplit() {
        let manager = TabManager()
        let url1 = tempFileURL(name: "a.swift")
        let url2 = tempFileURL(name: "b.swift")

        manager.openTab(url: url1)
        manager.splitRight()
        manager.splitPane?.openTab(url: url2)

        // Close the only tab in split pane
        if let tabID = manager.splitPane?.activeTabID {
            manager.splitPane?.closeTab(id: tabID)
        }
        manager.autoCloseSplitIfEmpty()

        #expect(manager.isSplitActive == false)
        #expect(manager.focusedSide == .leading)
    }

    // MARK: - Aggregate properties

    @Test("hasAnyUnsavedChanges includes split pane")
    func hasAnyUnsavedChangesIncludesSplit() {
        let manager = TabManager()
        let url1 = tempFileURL(name: "a.swift", content: "clean")
        let url2 = tempFileURL(name: "b.swift", content: "clean")

        manager.openTab(url: url1)
        manager.splitRight()
        manager.splitPane?.openTab(url: url2)

        #expect(manager.hasAnyUnsavedChanges == false)

        manager.splitPane?.updateContent("dirty")

        #expect(manager.hasAnyUnsavedChanges == true)
        #expect(manager.hasUnsavedChanges == false) // primary is clean
    }

    @Test("allDirtyTabs includes split pane tabs")
    func allDirtyTabsIncludesSplit() {
        let manager = TabManager()
        let url1 = tempFileURL(name: "a.swift", content: "clean")
        let url2 = tempFileURL(name: "b.swift", content: "clean")

        manager.openTab(url: url1)
        manager.updateContent("dirty1")
        manager.splitRight()
        manager.splitPane?.openTab(url: url2)
        manager.splitPane?.updateContent("dirty2")

        let dirty = manager.allDirtyTabs
        #expect(dirty.count == 2)
    }

    @Test("handleFileRenamedIncludingSplit updates both panes")
    func handleFileRenamedIncludingSplit() {
        let manager = TabManager()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let oldURL = dir.appendingPathComponent("old.swift")
        let newURL = dir.appendingPathComponent("new.swift")
        try? "content".write(to: oldURL, atomically: true, encoding: .utf8)

        manager.openTab(url: oldURL)
        manager.splitRight()

        let oldURL2 = dir.appendingPathComponent("old2.swift")
        let newURL2 = dir.appendingPathComponent("new2.swift")
        try? "content2".write(to: oldURL2, atomically: true, encoding: .utf8)
        manager.splitPane?.openTab(url: oldURL2)

        manager.handleFileRenamedIncludingSplit(oldURL: oldURL, newURL: newURL)
        manager.handleFileRenamedIncludingSplit(oldURL: oldURL2, newURL: newURL2)

        #expect(manager.tabs[0].url == newURL)
        #expect(manager.splitPane?.tabs[0].url == newURL2)
    }

    @Test("closeTabsForDeletedFileIncludingSplit handles both panes")
    func closeTabsForDeletedFileIncludingSplit() {
        let manager = TabManager()
        let url1 = tempFileURL(name: "a.swift")
        let url2 = tempFileURL(name: "b.swift")
        let url3 = tempFileURL(name: "c.swift")

        manager.openTab(url: url1)
        manager.openTab(url: url3)
        manager.splitRight()
        manager.splitPane?.openTab(url: url2)

        manager.closeTabsForDeletedFileIncludingSplit(url: url2)

        #expect(manager.tabs.count == 2)
        // Split pane had only one tab which was deleted → auto-close
        #expect(manager.isSplitActive == false)
    }

    // MARK: - Focused pane routing

    @Test("focusedActiveTab returns correct tab based on side")
    func focusedActiveTab() {
        let manager = TabManager()
        let url1 = tempFileURL(name: "a.swift")
        let url2 = tempFileURL(name: "b.swift")

        manager.openTab(url: url1)
        manager.splitRight()
        manager.splitPane?.openTab(url: url2)

        manager.focusedSide = .leading
        #expect(manager.focusedActiveTab?.url == url1)

        manager.focusedSide = .trailing
        #expect(manager.focusedActiveTab?.url == url2)
    }

    @Test("updateFocusedContent routes to correct pane")
    func updateFocusedContentRouting() {
        let manager = TabManager()
        let url1 = tempFileURL(name: "a.swift", content: "original1")
        let url2 = tempFileURL(name: "b.swift", content: "original2")

        manager.openTab(url: url1)
        manager.splitRight()
        manager.splitPane?.openTab(url: url2)

        manager.focusedSide = .trailing
        manager.updateFocusedContent("modified2")

        #expect(manager.activeTab?.content == "original1") // primary unchanged
        #expect(manager.splitPane?.activeTab?.content == "modified2")

        manager.focusedSide = .leading
        manager.updateFocusedContent("modified1")

        #expect(manager.activeTab?.content == "modified1")
    }

    @Test("saveFocusedActiveTab routes to correct pane")
    func saveFocusedActiveTabRouting() {
        let manager = TabManager()
        let url1 = tempFileURL(name: "a.swift", content: "original1")
        let url2 = tempFileURL(name: "b.swift", content: "original2")

        manager.openTab(url: url1)
        manager.splitRight()
        manager.splitPane?.openTab(url: url2)
        manager.splitPane?.updateContent("modified2")

        manager.focusedSide = .trailing
        let success = manager.saveFocusedActiveTab()

        #expect(success == true)
        #expect(manager.splitPane?.activeTab?.isDirty == false)

        let onDisk = try? String(contentsOf: url2, encoding: .utf8)
        #expect(onDisk == "modified2")
    }

    @Test("closeFocusedActiveTab closes tab in focused pane")
    func closeFocusedActiveTabTest() {
        let manager = TabManager()
        let url1 = tempFileURL(name: "a.swift")
        let url2 = tempFileURL(name: "b.swift")

        manager.openTab(url: url1)
        manager.splitRight()
        manager.splitPane?.openTab(url: url2)

        manager.focusedSide = .trailing
        let closed = manager.closeFocusedActiveTab()

        #expect(closed?.url == url2)
        // Split had only one tab → auto-closed
        #expect(manager.isSplitActive == false)
    }

    @Test("trySaveAllTabsIncludingSplit saves both panes")
    func trySaveAllTabsIncludingSplit() throws {
        let manager = TabManager()
        let url1 = tempFileURL(name: "a.swift", content: "original1")
        let url2 = tempFileURL(name: "b.swift", content: "original2")

        manager.openTab(url: url1)
        manager.updateContent("modified1")
        manager.splitRight()
        manager.splitPane?.openTab(url: url2)
        manager.splitPane?.updateContent("modified2")

        try manager.trySaveAllTabsIncludingSplit()

        #expect(manager.hasAnyUnsavedChanges == false)
        let disk1 = try? String(contentsOf: url1, encoding: .utf8)
        let disk2 = try? String(contentsOf: url2, encoding: .utf8)
        #expect(disk1 == "modified1")
        #expect(disk2 == "modified2")
    }

    // MARK: - Session state with split

    @Test("SessionState encodes and decodes split state")
    func sessionStateSplitRoundTrip() {
        let state = SessionState(
            projectPath: "/tmp/project",
            openFilePaths: ["/tmp/project/a.swift"],
            activeFilePath: "/tmp/project/a.swift",
            splitOpenFilePaths: ["/tmp/project/b.swift"],
            splitActiveFilePath: "/tmp/project/b.swift"
        )

        let data = try? JSONEncoder().encode(state)
        #expect(data != nil)

        if let data {
            let decoded = try? JSONDecoder().decode(SessionState.self, from: data)
            #expect(decoded?.splitOpenFilePaths == ["/tmp/project/b.swift"])
            #expect(decoded?.splitActiveFilePath == "/tmp/project/b.swift")
        }
    }

    @Test("SessionState without split fields decodes correctly (backward compat)")
    func sessionStateBackwardCompat() {
        let json = """
        {"projectPath":"/tmp/project","openFilePaths":["/tmp/a.swift"]}
        """
        guard let data = json.data(using: .utf8) else {
            Issue.record("Failed to encode JSON")
            return
        }
        let decoded = try? JSONDecoder().decode(SessionState.self, from: data)

        #expect(decoded != nil)
        #expect(decoded?.splitOpenFilePaths == nil)
        #expect(decoded?.splitActiveFilePath == nil)
    }

    // MARK: - Edge cases

    @Test("moveTabToOtherPane skips if tab already open in other pane")
    func moveTabSkipsDuplicate() {
        let manager = TabManager()
        let url = tempFileURL()

        manager.openTab(url: url)
        manager.splitRight()
        manager.splitPane?.openTab(url: url) // same file in both panes

        manager.focusedSide = .leading
        manager.moveTabToOtherPane()

        // Should not move since url is already in trailing
        #expect(manager.tabs.count == 1)
        #expect(manager.splitPane?.tabs.count == 1)
    }

    @Test("SplitPane togglePreviewMode works for markdown")
    func splitPaneTogglePreviewMode() {
        let pane = SplitPane()
        let url = tempFileURL(name: "readme.md", content: "# Hello")

        pane.openTab(url: url)
        #expect(pane.activeTab?.previewMode == .source)

        pane.togglePreviewMode()
        #expect(pane.activeTab?.previewMode == .split)
    }
}
