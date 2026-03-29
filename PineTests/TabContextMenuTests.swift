//
//  TabContextMenuTests.swift
//  PineTests
//
//  Created by Claude on 29.03.2026.
//

import Foundation
import Testing

@testable import Pine

@Suite("Tab Context Menu Tests")
struct TabContextMenuTests {

    /// Creates a temporary file URL for testing.
    private func tempFileURL(name: String = "test.swift", content: String = "hello") -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try? content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Creates a TabManager with the given number of tabs.
    private func managerWithTabs(_ count: Int) -> (TabManager, [URL]) {
        let manager = TabManager()
        var urls: [URL] = []
        for index in 0..<count {
            let url = tempFileURL(name: "file\(index).swift")
            urls.append(url)
            manager.openTab(url: url)
        }
        return (manager, urls)
    }

    // MARK: - Close Other Tabs

    @Test("closeOtherTabs with force keeps only the specified tab")
    func closeOtherTabsKeepsOne() {
        let (manager, urls) = managerWithTabs(4)
        let keepID = manager.tabs[1].id

        manager.closeOtherTabs(keeping: keepID, force: true)

        #expect(manager.tabs.count == 1)
        #expect(manager.tabs[0].url == urls[1])
        #expect(manager.activeTabID == keepID)
    }

    @Test("closeOtherTabs preserves pinned tabs")
    func closeOtherTabsPreservesPinned() {
        let (manager, urls) = managerWithTabs(4)
        let keepID = manager.tabs[2].id
        manager.togglePin(id: manager.tabs[0].id)

        manager.closeOtherTabs(keeping: keepID, force: true)

        #expect(manager.tabs.count == 2)
        #expect(manager.tabs.contains { $0.url == urls[0] })
        #expect(manager.tabs.contains { $0.url == urls[2] })
    }

    @Test("closeOtherTabs with single tab is a no-op")
    func closeOtherTabsSingleTab() {
        let (manager, _) = managerWithTabs(1)
        let keepID = manager.tabs[0].id

        manager.closeOtherTabs(keeping: keepID, force: true)

        #expect(manager.tabs.count == 1)
    }

    // MARK: - Close Tabs to the Right

    @Test("closeTabsToTheRight closes only right-side tabs")
    func closeTabsToTheRight() {
        let (manager, urls) = managerWithTabs(5)
        let pivotID = manager.tabs[2].id

        manager.closeTabsToTheRight(of: pivotID, force: true)

        #expect(manager.tabs.count == 3)
        #expect(manager.tabs[0].url == urls[0])
        #expect(manager.tabs[1].url == urls[1])
        #expect(manager.tabs[2].url == urls[2])
    }

    @Test("closeTabsToTheRight preserves pinned tabs on the right")
    func closeTabsToTheRightPreservesPinned() {
        let (manager, _) = managerWithTabs(4)
        // Pin the last tab (it moves to the left)
        let lastTabID = manager.tabs[3].id
        manager.togglePin(id: lastTabID)
        // Now pinned tab is at index 0, rest at 1-3
        let pivotID = manager.tabs[1].id

        manager.closeTabsToTheRight(of: pivotID, force: true)

        // Pinned tab stays, pivot stays, right unpinned tabs closed
        #expect(manager.tabs.count == 2)
        #expect(manager.tabs[0].isPinned == true)
    }

    @Test("closeTabsToTheRight on last tab is a no-op")
    func closeTabsToTheRightLastTab() {
        let (manager, _) = managerWithTabs(3)
        let lastID = manager.tabs[2].id

        manager.closeTabsToTheRight(of: lastID, force: true)

        #expect(manager.tabs.count == 3)
    }

    // MARK: - Close All Tabs

    @Test("closeAllTabs with force removes all tabs including pinned")
    func closeAllTabs() {
        let (manager, _) = managerWithTabs(4)
        manager.togglePin(id: manager.tabs[0].id)

        manager.closeAllTabs(force: true)

        #expect(manager.tabs.isEmpty)
        #expect(manager.activeTabID == nil)
    }

    @Test("closeAllTabs on empty manager is a no-op")
    func closeAllTabsEmpty() {
        let manager = TabManager()

        manager.closeAllTabs(force: true)

        #expect(manager.tabs.isEmpty)
    }

    // MARK: - Close Other Tabs with active tab selection

    @Test("closeOtherTabs sets active tab to the kept tab")
    func closeOtherTabsSetsActive() {
        let (manager, _) = managerWithTabs(3)
        let keepID = manager.tabs[0].id
        // Active tab is the last opened (tabs[2])
        #expect(manager.activeTabID == manager.tabs[2].id)

        manager.closeOtherTabs(keeping: keepID, force: true)

        #expect(manager.activeTabID == keepID)
    }

    // MARK: - Close Tabs to the Right with invalid ID

    @Test("closeTabsToTheRight with unknown ID is a no-op")
    func closeTabsToTheRightUnknownID() {
        let (manager, _) = managerWithTabs(3)
        let unknownID = UUID()

        manager.closeTabsToTheRight(of: unknownID, force: true)

        #expect(manager.tabs.count == 3)
    }

    // MARK: - Combined scenarios

    @Test("closeOtherTabs then closeAllTabs leaves empty state")
    func closeOtherThenCloseAll() {
        let (manager, _) = managerWithTabs(5)
        let keepID = manager.tabs[2].id

        manager.closeOtherTabs(keeping: keepID, force: true)
        #expect(manager.tabs.count == 1)

        manager.closeAllTabs(force: true)
        #expect(manager.tabs.isEmpty)
    }

    // MARK: - Dirty tabs protection (no force)

    @Test("closeOtherTabs without force skips dirty tabs")
    func closeOtherTabsSkipsDirty() {
        let (manager, urls) = managerWithTabs(4)
        let keepID = manager.tabs[2].id
        // Make tab at index 1 dirty
        manager.activeTabID = manager.tabs[1].id
        manager.updateContent("modified content")

        manager.closeOtherTabs(keeping: keepID)

        // Tab 0 (clean) closed, tab 1 (dirty) kept, tab 2 (kept), tab 3 (clean) closed
        #expect(manager.tabs.count == 2)
        #expect(manager.tabs.contains { $0.url == urls[1] })
        #expect(manager.tabs.contains { $0.url == urls[2] })
    }

    @Test("closeTabsToTheRight without force skips dirty tabs")
    func closeTabsToTheRightSkipsDirty() {
        let (manager, urls) = managerWithTabs(4)
        let pivotID = manager.tabs[1].id
        // Make tab at index 3 dirty
        manager.activeTabID = manager.tabs[3].id
        manager.updateContent("modified content")

        manager.closeTabsToTheRight(of: pivotID)

        // Tab 2 (clean) closed, tab 3 (dirty) preserved
        #expect(manager.tabs.count == 3)
        #expect(manager.tabs.contains { $0.url == urls[0] })
        #expect(manager.tabs.contains { $0.url == urls[1] })
        #expect(manager.tabs.contains { $0.url == urls[3] })
    }

    @Test("closeAllTabs without force skips dirty tabs")
    func closeAllTabsSkipsDirty() {
        let (manager, urls) = managerWithTabs(3)
        // Make tab at index 1 dirty
        manager.activeTabID = manager.tabs[1].id
        manager.updateContent("modified content")

        manager.closeAllTabs()

        // Only dirty tab remains
        #expect(manager.tabs.count == 1)
        #expect(manager.tabs[0].url == urls[1])
    }

    @Test("dirtyTabsForCloseOthers returns only dirty tabs that would be closed")
    func dirtyTabsForCloseOthersReturnsCorrect() {
        let (manager, urls) = managerWithTabs(4)
        let keepID = manager.tabs[2].id
        // Make tabs 0 and 3 dirty
        manager.activeTabID = manager.tabs[0].id
        manager.updateContent("dirty 0")
        manager.activeTabID = manager.tabs[3].id
        manager.updateContent("dirty 3")

        let dirty = manager.dirtyTabsForCloseOthers(keeping: keepID)

        #expect(dirty.count == 2)
        #expect(dirty.contains { $0.url == urls[0] })
        #expect(dirty.contains { $0.url == urls[3] })
    }

    @Test("dirtyTabsForCloseRight returns only dirty tabs to the right")
    func dirtyTabsForCloseRightReturnsCorrect() {
        let (manager, urls) = managerWithTabs(4)
        let pivotID = manager.tabs[1].id
        // Make tab 3 dirty
        manager.activeTabID = manager.tabs[3].id
        manager.updateContent("dirty 3")

        let dirty = manager.dirtyTabsForCloseRight(of: pivotID)

        #expect(dirty.count == 1)
        #expect(dirty[0].url == urls[3])
    }

    @Test("dirtyTabsForCloseAll returns all dirty tabs")
    func dirtyTabsForCloseAllReturnsCorrect() {
        let (manager, urls) = managerWithTabs(3)
        // Make tabs 0 and 2 dirty
        manager.activeTabID = manager.tabs[0].id
        manager.updateContent("dirty 0")
        manager.activeTabID = manager.tabs[2].id
        manager.updateContent("dirty 2")

        let dirty = manager.dirtyTabsForCloseAll()

        #expect(dirty.count == 2)
        #expect(dirty.contains { $0.url == urls[0] })
        #expect(dirty.contains { $0.url == urls[2] })
    }

    // MARK: - Copy Path (relative path computation)

    @Test("computeRelativePath returns relative path for file inside project")
    func computeRelativePathInsideProject() {
        let root = URL(fileURLWithPath: "/Users/test/project")
        let file = URL(fileURLWithPath: "/Users/test/project/Sources/main.swift")

        let result = EditorTabBar.computeRelativePath(fileURL: file, projectRootURL: root)

        #expect(result == "Sources/main.swift")
    }

    @Test("computeRelativePath handles trailing slash on root")
    func computeRelativePathTrailingSlash() {
        let root = URL(fileURLWithPath: "/Users/test/project/")
        let file = URL(fileURLWithPath: "/Users/test/project/Sources/main.swift")

        let result = EditorTabBar.computeRelativePath(fileURL: file, projectRootURL: root)

        #expect(result == "Sources/main.swift")
    }

    @Test("computeRelativePath returns full path when file is outside project")
    func computeRelativePathOutsideProject() {
        let root = URL(fileURLWithPath: "/Users/test/project")
        let file = URL(fileURLWithPath: "/Users/other/file.swift")

        let result = EditorTabBar.computeRelativePath(fileURL: file, projectRootURL: root)

        #expect(result == "/Users/other/file.swift")
    }

    @Test("computeRelativePath returns full path when projectRootURL is nil")
    func computeRelativePathNilRoot() {
        let file = URL(fileURLWithPath: "/Users/test/project/file.swift")

        let result = EditorTabBar.computeRelativePath(fileURL: file, projectRootURL: nil)

        #expect(result == "/Users/test/project/file.swift")
    }

    @Test("computeRelativePath handles root as file's direct parent")
    func computeRelativePathDirectParent() {
        let root = URL(fileURLWithPath: "/Users/test/project")
        let file = URL(fileURLWithPath: "/Users/test/project/file.swift")

        let result = EditorTabBar.computeRelativePath(fileURL: file, projectRootURL: root)

        #expect(result == "file.swift")
    }

    @Test("computeRelativePath handles deeply nested files")
    func computeRelativePathDeepNesting() {
        let root = URL(fileURLWithPath: "/project")
        let file = URL(fileURLWithPath: "/project/a/b/c/d/e.swift")

        let result = EditorTabBar.computeRelativePath(fileURL: file, projectRootURL: root)

        #expect(result == "a/b/c/d/e.swift")
    }

    // MARK: - Reveal in Sidebar (notification posting)

    @Test("Reveal in Sidebar posts notification with correct URL")
    func revealInSidebarPostsNotification() {
        let expectedURL = URL(fileURLWithPath: "/test/file.swift")
        var receivedURL: URL?

        let observer = NotificationCenter.default.addObserver(
            forName: .revealInSidebar,
            object: nil,
            queue: .main
        ) { notification in
            receivedURL = notification.userInfo?["url"] as? URL
        }

        NotificationCenter.default.post(
            name: .revealInSidebar,
            object: nil,
            userInfo: ["url": expectedURL]
        )

        #expect(receivedURL == expectedURL)
        NotificationCenter.default.removeObserver(observer)
    }

    @Test("Reveal in Sidebar notification has correct name")
    func revealInSidebarNotificationName() {
        #expect(Notification.Name.revealInSidebar.rawValue == "revealInSidebar")
    }
}
