//
//  PaneLeafCloseTests.swift
//  PineTests
//
//  Tests for pane leaf tab close operations including dirty tab handling,
//  context menu actions (close other, close right, close all), and
//  pane removal when all tabs are closed.
//

import Testing
import Foundation
@testable import Pine

// swiftlint:disable type_body_length

@Suite("PaneLeaf Close Logic Tests")
@MainActor
struct PaneLeafCloseTests {

    // MARK: - Helpers

    /// Finds a tab ID by URL, recording a test issue if not found.
    private func tabID(for url: URL, in tabManager: TabManager) -> UUID? {
        guard let id = tabManager.tabs.first(where: { $0.url == url })?.id else {
            Issue.record("Tab not found for \(url.lastPathComponent)")
            return nil
        }
        return id
    }

    // MARK: - Close tab removes pane when empty

    @Test func closingLastTab_removesPane() {
        let manager = PaneManager()
        let firstPane = manager.activePaneID
        let url = URL(fileURLWithPath: "/tmp/test.swift")
        manager.tabManager(for: firstPane)?.openTab(url: url)

        guard let secondPane = manager.splitPane(firstPane, axis: .horizontal) else {
            Issue.record("Split failed")
            return
        }
        let url2 = URL(fileURLWithPath: "/tmp/test2.swift")
        manager.tabManager(for: secondPane)?.openTab(url: url2)

        // Close the only tab in second pane
        if let tm = manager.tabManager(for: secondPane), let tab = tm.tabs.first {
            tm.closeTab(id: tab.id)
        }

        // After closing, manually remove empty pane (mirrors PaneLeafView behavior)
        if manager.tabManager(for: secondPane)?.tabs.isEmpty == true {
            manager.removePane(secondPane)
        }

        #expect(manager.root.leafCount == 1)
        #expect(manager.tabManagers[secondPane] == nil)
    }

    // MARK: - Close other tabs

    @Test func closeOtherTabs_keepingOne_closesRest() {
        let manager = PaneManager()
        let pane = manager.activePaneID
        guard let tm = manager.tabManager(for: pane) else {
            Issue.record("No tab manager")
            return
        }

        let url1 = URL(fileURLWithPath: "/tmp/a.swift")
        let url2 = URL(fileURLWithPath: "/tmp/b.swift")
        let url3 = URL(fileURLWithPath: "/tmp/c.swift")
        tm.openTab(url: url1)
        tm.openTab(url: url2)
        tm.openTab(url: url3)

        guard let keepID = tabID(for: url2, in: tm) else { return }
        tm.closeOtherTabs(keeping: keepID, force: true)

        #expect(tm.tabs.count == 1)
        #expect(tm.tabs.first?.url == url2)
    }

    @Test func closeOtherTabs_skipsDirtyWhenNotForced() {
        let manager = PaneManager()
        let pane = manager.activePaneID
        guard let tm = manager.tabManager(for: pane) else {
            Issue.record("No tab manager")
            return
        }

        let url1 = URL(fileURLWithPath: "/tmp/a.swift")
        let url2 = URL(fileURLWithPath: "/tmp/b.swift")
        tm.openTab(url: url1)
        tm.openTab(url: url2)

        // Make url1 dirty
        tm.activeTabID = tm.tabs.first(where: { $0.url == url1 })?.id
        tm.updateContent("modified content")

        guard let keepID = tabID(for: url2, in: tm) else { return }
        tm.closeOtherTabs(keeping: keepID, force: false)

        // Dirty tab should remain
        #expect(tm.tabs.count == 2)
    }

    // MARK: - Close tabs to the right

    @Test func closeTabsToTheRight_closesOnlyRight() {
        let manager = PaneManager()
        let pane = manager.activePaneID
        guard let tm = manager.tabManager(for: pane) else {
            Issue.record("No tab manager")
            return
        }

        let url1 = URL(fileURLWithPath: "/tmp/a.swift")
        let url2 = URL(fileURLWithPath: "/tmp/b.swift")
        let url3 = URL(fileURLWithPath: "/tmp/c.swift")
        tm.openTab(url: url1)
        tm.openTab(url: url2)
        tm.openTab(url: url3)

        guard let pivotID = tabID(for: url1, in: tm) else { return }
        tm.closeTabsToTheRight(of: pivotID, force: true)

        #expect(tm.tabs.count == 1)
        #expect(tm.tabs.first?.url == url1)
    }

    @Test func closeTabsToTheRight_skipsDirtyWhenNotForced() {
        let manager = PaneManager()
        let pane = manager.activePaneID
        guard let tm = manager.tabManager(for: pane) else {
            Issue.record("No tab manager")
            return
        }

        let url1 = URL(fileURLWithPath: "/tmp/a.swift")
        let url2 = URL(fileURLWithPath: "/tmp/b.swift")
        let url3 = URL(fileURLWithPath: "/tmp/c.swift")
        tm.openTab(url: url1)
        tm.openTab(url: url2)
        tm.openTab(url: url3)

        // Make url3 dirty
        tm.activeTabID = tm.tabs.first(where: { $0.url == url3 })?.id
        tm.updateContent("modified content")

        guard let pivotID = tabID(for: url1, in: tm) else { return }
        tm.closeTabsToTheRight(of: pivotID, force: false)

        // url2 closed (clean), url3 kept (dirty)
        #expect(tm.tabs.count == 2)
        #expect(tm.tabs.contains(where: { $0.url == url1 }))
        #expect(tm.tabs.contains(where: { $0.url == url3 }))
    }

    // MARK: - Close all tabs

    @Test func closeAllTabs_forced_closesEverything() {
        let manager = PaneManager()
        let pane = manager.activePaneID
        guard let tm = manager.tabManager(for: pane) else {
            Issue.record("No tab manager")
            return
        }

        let url1 = URL(fileURLWithPath: "/tmp/a.swift")
        let url2 = URL(fileURLWithPath: "/tmp/b.swift")
        tm.openTab(url: url1)
        tm.openTab(url: url2)

        tm.closeAllTabs(force: true)
        #expect(tm.tabs.isEmpty)
    }

    @Test func closeAllTabs_notForced_skipsDirty() {
        let manager = PaneManager()
        let pane = manager.activePaneID
        guard let tm = manager.tabManager(for: pane) else {
            Issue.record("No tab manager")
            return
        }

        let url1 = URL(fileURLWithPath: "/tmp/a.swift")
        let url2 = URL(fileURLWithPath: "/tmp/b.swift")
        tm.openTab(url: url1)
        tm.openTab(url: url2)

        // Make url1 dirty
        tm.activeTabID = tm.tabs.first(where: { $0.url == url1 })?.id
        tm.updateContent("modified")

        tm.closeAllTabs(force: false)

        // Only the dirty tab remains
        #expect(tm.tabs.count == 1)
        #expect(tm.tabs.first?.url == url1)
    }

    // MARK: - Dirty tab tracking for bulk close

    @Test func dirtyTabsForCloseOthers_returnsDirtyOnly() {
        let manager = PaneManager()
        let pane = manager.activePaneID
        guard let tm = manager.tabManager(for: pane) else {
            Issue.record("No tab manager")
            return
        }

        let url1 = URL(fileURLWithPath: "/tmp/a.swift")
        let url2 = URL(fileURLWithPath: "/tmp/b.swift")
        let url3 = URL(fileURLWithPath: "/tmp/c.swift")
        tm.openTab(url: url1)
        tm.openTab(url: url2)
        tm.openTab(url: url3)

        // Make url2 dirty
        tm.activeTabID = tm.tabs.first(where: { $0.url == url2 })?.id
        tm.updateContent("dirty content")

        guard let keepID = tabID(for: url1, in: tm) else { return }
        let dirty = tm.dirtyTabsForCloseOthers(keeping: keepID)

        #expect(dirty.count == 1)
        #expect(dirty.first?.url == url2)
    }

    @Test func dirtyTabsForCloseRight_returnsDirtyToTheRight() {
        let manager = PaneManager()
        let pane = manager.activePaneID
        guard let tm = manager.tabManager(for: pane) else {
            Issue.record("No tab manager")
            return
        }

        let url1 = URL(fileURLWithPath: "/tmp/a.swift")
        let url2 = URL(fileURLWithPath: "/tmp/b.swift")
        let url3 = URL(fileURLWithPath: "/tmp/c.swift")
        tm.openTab(url: url1)
        tm.openTab(url: url2)
        tm.openTab(url: url3)

        // Make url3 dirty
        tm.activeTabID = tm.tabs.first(where: { $0.url == url3 })?.id
        tm.updateContent("dirty content")

        guard let pivotID = tabID(for: url1, in: tm) else { return }
        let dirty = tm.dirtyTabsForCloseRight(of: pivotID)

        #expect(dirty.count == 1)
        #expect(dirty.first?.url == url3)
    }

    @Test func dirtyTabsForCloseAll_returnsAllDirty() {
        let manager = PaneManager()
        let pane = manager.activePaneID
        guard let tm = manager.tabManager(for: pane) else {
            Issue.record("No tab manager")
            return
        }

        let url1 = URL(fileURLWithPath: "/tmp/a.swift")
        let url2 = URL(fileURLWithPath: "/tmp/b.swift")
        tm.openTab(url: url1)
        tm.openTab(url: url2)

        // Make both dirty
        tm.activeTabID = tm.tabs.first(where: { $0.url == url1 })?.id
        tm.updateContent("dirty1")
        tm.activeTabID = tm.tabs.first(where: { $0.url == url2 })?.id
        tm.updateContent("dirty2")

        let dirty = tm.dirtyTabsForCloseAll()
        #expect(dirty.count == 2)
    }

    // MARK: - PaneContent has only editor

    @Test func paneContent_onlyHasEditorCase() {
        let content = PaneContent.editor
        #expect(content.rawValue == "editor")

        // Verify encoding/decoding
        let data = try? JSONEncoder().encode(content)
        #expect(data != nil)
        if let data {
            let decoded = try? JSONDecoder().decode(PaneContent.self, from: data)
            #expect(decoded == .editor)
        }
    }

    // MARK: - Close all then remove pane

    @Test func closeAllTabs_thenRemovePane_works() {
        let manager = PaneManager()
        let firstPane = manager.activePaneID
        let url = URL(fileURLWithPath: "/tmp/test.swift")
        manager.tabManager(for: firstPane)?.openTab(url: url)

        guard let secondPane = manager.splitPane(firstPane, axis: .horizontal) else {
            Issue.record("Split failed")
            return
        }
        let url2 = URL(fileURLWithPath: "/tmp/test2.swift")
        manager.tabManager(for: secondPane)?.openTab(url: url2)

        // Close all tabs in second pane and remove it
        manager.tabManager(for: secondPane)?.closeAllTabs(force: true)
        manager.removePane(secondPane)

        #expect(manager.root.leafCount == 1)
        #expect(manager.tabManagers[secondPane] == nil)
        #expect(manager.activePaneID == firstPane)
    }
}

// swiftlint:enable type_body_length
