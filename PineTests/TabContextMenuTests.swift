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

    @Test("closeOtherTabs keeps only the specified tab")
    func closeOtherTabsKeepsOne() {
        let (manager, urls) = managerWithTabs(4)
        let keepID = manager.tabs[1].id

        manager.closeOtherTabs(keeping: keepID)

        #expect(manager.tabs.count == 1)
        #expect(manager.tabs[0].url == urls[1])
        #expect(manager.activeTabID == keepID)
    }

    @Test("closeOtherTabs preserves pinned tabs")
    func closeOtherTabsPreservesPinned() {
        let (manager, urls) = managerWithTabs(4)
        let keepID = manager.tabs[2].id
        manager.togglePin(id: manager.tabs[0].id)

        manager.closeOtherTabs(keeping: keepID)

        #expect(manager.tabs.count == 2)
        #expect(manager.tabs.contains { $0.url == urls[0] })
        #expect(manager.tabs.contains { $0.url == urls[2] })
    }

    @Test("closeOtherTabs with single tab is a no-op")
    func closeOtherTabsSingleTab() {
        let (manager, _) = managerWithTabs(1)
        let keepID = manager.tabs[0].id

        manager.closeOtherTabs(keeping: keepID)

        #expect(manager.tabs.count == 1)
    }

    // MARK: - Close Tabs to the Right

    @Test("closeTabsToTheRight closes only right-side tabs")
    func closeTabsToTheRight() {
        let (manager, urls) = managerWithTabs(5)
        let pivotID = manager.tabs[2].id

        manager.closeTabsToTheRight(of: pivotID)

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

        manager.closeTabsToTheRight(of: pivotID)

        // Pinned tab stays, pivot stays, right unpinned tabs closed
        #expect(manager.tabs.count == 2)
        #expect(manager.tabs[0].isPinned == true)
    }

    @Test("closeTabsToTheRight on last tab is a no-op")
    func closeTabsToTheRightLastTab() {
        let (manager, _) = managerWithTabs(3)
        let lastID = manager.tabs[2].id

        manager.closeTabsToTheRight(of: lastID)

        #expect(manager.tabs.count == 3)
    }

    // MARK: - Close All Tabs

    @Test("closeAllTabs removes all tabs including pinned")
    func closeAllTabs() {
        let (manager, _) = managerWithTabs(4)
        manager.togglePin(id: manager.tabs[0].id)

        manager.closeAllTabs()

        #expect(manager.tabs.isEmpty)
        #expect(manager.activeTabID == nil)
    }

    @Test("closeAllTabs on empty manager is a no-op")
    func closeAllTabsEmpty() {
        let manager = TabManager()

        manager.closeAllTabs()

        #expect(manager.tabs.isEmpty)
    }

    // MARK: - Close Other Tabs with active tab selection

    @Test("closeOtherTabs sets active tab to the kept tab")
    func closeOtherTabsSetsActive() {
        let (manager, _) = managerWithTabs(3)
        let keepID = manager.tabs[0].id
        // Active tab is the last opened (tabs[2])
        #expect(manager.activeTabID == manager.tabs[2].id)

        manager.closeOtherTabs(keeping: keepID)

        #expect(manager.activeTabID == keepID)
    }

    // MARK: - Close Tabs to the Right with invalid ID

    @Test("closeTabsToTheRight with unknown ID is a no-op")
    func closeTabsToTheRightUnknownID() {
        let (manager, _) = managerWithTabs(3)
        let unknownID = UUID()

        manager.closeTabsToTheRight(of: unknownID)

        #expect(manager.tabs.count == 3)
    }

    // MARK: - Combined scenarios

    @Test("closeOtherTabs then closeAllTabs leaves empty state")
    func closeOtherThenCloseAll() {
        let (manager, _) = managerWithTabs(5)
        let keepID = manager.tabs[2].id

        manager.closeOtherTabs(keeping: keepID)
        #expect(manager.tabs.count == 1)

        manager.closeAllTabs()
        #expect(manager.tabs.isEmpty)
    }
}
