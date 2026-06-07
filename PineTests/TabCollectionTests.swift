//
//  TabCollectionTests.swift
//  PineTests
//

import Foundation
import Testing

@testable import Pine

@Suite("TabCollection Tests")
struct TabCollectionTests {

    private func makeTabs(_ names: [String]) -> [EditorTab] {
        names.map { EditorTab(url: URL(fileURLWithPath: "/tmp/\($0)"), content: "", savedContent: "") }
    }

    // MARK: - Lookup

    @Test("tab(for: URL) returns matching tab")
    func tabForURL() {
        let tabs = makeTabs(["a.swift", "b.swift"])
        let url = URL(fileURLWithPath: "/tmp/a.swift")
        #expect(TabCollection.tab(for: url, in: tabs)?.url == url)
    }

    @Test("tab(for: URL) returns nil for missing URL")
    func tabForURLMissing() {
        let tabs = makeTabs(["a.swift"])
        #expect(TabCollection.tab(for: URL(fileURLWithPath: "/tmp/missing.swift"), in: tabs) == nil)
    }

    @Test("tab(for: UUID) returns matching tab")
    func tabForID() {
        let tabs = makeTabs(["a.swift"])
        let id = tabs[0].id
        #expect(TabCollection.tab(for: id, in: tabs)?.id == id)
    }

    @Test("tab(for: UUID) returns nil for unknown ID")
    func tabForIDMissing() {
        let tabs = makeTabs(["a.swift"])
        #expect(TabCollection.tab(for: UUID(), in: tabs) == nil)
    }

    @Test("index(of: UUID) returns correct index")
    func indexOfID() {
        let tabs = makeTabs(["a.swift", "b.swift", "c.swift"])
        #expect(TabCollection.index(of: tabs[1].id, in: tabs) == 1)
    }

    @Test("index(of: UUID) returns nil for unknown ID")
    func indexOfIDMissing() {
        let tabs = makeTabs(["a.swift"])
        #expect(TabCollection.index(of: UUID(), in: tabs) == nil)
    }

    // MARK: - Dirty tabs

    @Test("hasUnsavedChanges returns false when all clean")
    func noUnsavedChanges() {
        let tabs = makeTabs(["a.swift"])
        #expect(TabCollection.hasUnsavedChanges(in: tabs) == false)
    }

    @Test("hasUnsavedChanges returns true when one dirty")
    func hasUnsavedChanges() {
        var tabs = makeTabs(["a.swift", "b.swift"])
        tabs[0].content = "modified"
        #expect(TabCollection.hasUnsavedChanges(in: tabs) == true)
    }

    @Test("dirtyTabs returns only dirty tabs")
    func dirtyTabsFiltering() {
        var tabs = makeTabs(["a.swift", "b.swift", "c.swift"])
        tabs[0].content = "dirty"
        tabs[2].content = "also dirty"
        let dirty = TabCollection.dirtyTabs(in: tabs)
        #expect(dirty.count == 2)
        #expect(dirty[0].id == tabs[0].id)
        #expect(dirty[1].id == tabs[2].id)
    }

    @Test("dirtyTabs returns empty for all clean")
    func dirtyTabsEmpty() {
        let tabs = makeTabs(["a.swift", "b.swift"])
        #expect(TabCollection.dirtyTabs(in: tabs).isEmpty)
    }

    // MARK: - Reorder

    @Test("reorderTab moves tab to target position")
    func reorderTab() {
        var tabs = makeTabs(["a.swift", "b.swift", "c.swift"])
        TabCollection.reorderTab(draggedID: tabs[0].id, targetID: tabs[2].id, in: &tabs)
        #expect(tabs[0].url.lastPathComponent == "b.swift")
        #expect(tabs[1].url.lastPathComponent == "c.swift")
        #expect(tabs[2].url.lastPathComponent == "a.swift")
    }

    @Test("reorderTab is no-op when dragging onto itself")
    func reorderTabSameID() {
        var tabs = makeTabs(["a.swift", "b.swift"])
        let original = tabs.map(\.id)
        TabCollection.reorderTab(draggedID: tabs[0].id, targetID: tabs[0].id, in: &tabs)
        #expect(tabs.map(\.id) == original)
    }

    @Test("reorderTab is no-op between pinned and unpinned groups")
    func reorderTabCrossGroup() {
        var tabs = makeTabs(["a.swift", "b.swift"])
        tabs[0].isPinned = true
        let original = tabs.map(\.id)
        TabCollection.reorderTab(draggedID: tabs[0].id, targetID: tabs[1].id, in: &tabs)
        #expect(tabs.map(\.id) == original)
    }

    // MARK: - Close helpers

    @Test("dirtyTabsForCloseOthers excludes pinned and kept tab")
    func dirtyTabsForCloseOthers() {
        var tabs = makeTabs(["a.swift", "b.swift", "c.swift", "d.swift"])
        tabs[0].content = "dirty1"
        tabs[1].isPinned = true
        tabs[2].content = "dirty2"
        let keeping = tabs[3].id
        let dirty = TabCollection.dirtyTabsForCloseOthers(keeping: keeping, in: tabs)
        #expect(dirty.count == 2)
        #expect(dirty.allSatisfy { $0.id != keeping })
        #expect(dirty.allSatisfy { !$0.isPinned })
    }

    @Test("dirtyTabsForCloseRight returns tabs right of target")
    func dirtyTabsForCloseRight() {
        var tabs = makeTabs(["a.swift", "b.swift", "c.swift", "d.swift"])
        tabs[2].content = "dirty"
        tabs[3].content = "dirty"
        let dirty = TabCollection.dirtyTabsForCloseRight(of: tabs[1].id, in: tabs)
        #expect(dirty.count == 2)
    }

    @Test("dirtyTabsForCloseRight returns empty when no dirty to right")
    func dirtyTabsForCloseRightNone() {
        let tabs = makeTabs(["a.swift", "b.swift"])
        let dirty = TabCollection.dirtyTabsForCloseRight(of: tabs[0].id, in: tabs)
        #expect(dirty.isEmpty)
    }

    @Test("dirtyTabsForCloseAll returns all dirty tabs")
    func dirtyTabsForCloseAll() {
        var tabs = makeTabs(["a.swift", "b.swift", "c.swift"])
        tabs[0].content = "dirty"
        tabs[2].content = "dirty"
        #expect(TabCollection.dirtyTabsForCloseAll(in: tabs).count == 2)
    }

    // MARK: - File operations

    @Test("handleFileRenamed updates exact match URL")
    func handleFileRenamedExact() {
        var tabs = makeTabs(["a.swift"])
        let oldURL = URL(fileURLWithPath: "/tmp/a.swift")
        let newURL = URL(fileURLWithPath: "/tmp/b.swift")
        TabCollection.handleFileRenamed(oldURL: oldURL, newURL: newURL, in: &tabs)
        #expect(tabs[0].url == newURL)
    }

    @Test("handleFileRenamed updates child paths")
    func handleFileRenamedChild() {
        var tabs = [EditorTab(url: URL(fileURLWithPath: "/project/sub/file.swift"), content: "", savedContent: "")]
        let oldURL = URL(fileURLWithPath: "/project/sub")
        let newURL = URL(fileURLWithPath: "/project/renamed")
        TabCollection.handleFileRenamed(oldURL: oldURL, newURL: newURL, in: &tabs)
        #expect(tabs[0].url == URL(fileURLWithPath: "/project/renamed/file.swift"))
    }

    @Test("tabsAffectedByDeletion returns exact and children")
    func tabsAffectedByDeletion() {
        let dir = URL(fileURLWithPath: "/project")
        var tabs = [
            EditorTab(url: dir.appendingPathComponent("a.swift"), content: "", savedContent: ""),
            EditorTab(url: dir.appendingPathComponent("sub/b.swift"), content: "", savedContent: ""),
            EditorTab(url: URL(fileURLWithPath: "/other/c.swift"), content: "", savedContent: ""),
        ]
        let affected = TabCollection.tabsAffectedByDeletion(url: dir.appendingPathComponent("sub"), in: tabs)
        #expect(affected.count == 1)
        #expect(affected[0].url.lastPathComponent == "b.swift")
    }

    // MARK: - Selection

    @Test("activeTabAfterClosing selects adjacent tab")
    func activeTabAfterClosing() {
        let tabs = makeTabs(["a.swift", "b.swift", "c.swift"])
        // Close tab at index 1 — active was that tab, remaining = [tabs[0], tabs[2]]
        let result = TabCollection.activeTabAfterClosing(
            closedIndex: 1, closedID: tabs[1].id, currentActiveID: tabs[1].id, tabs: [tabs[0], tabs[2]]
        )
        // min(1, 2-1) = 1 → remaining[1] = tabs[2]
        #expect(result == tabs[2].id)
    }

    @Test("activeTabAfterClosing returns nil for empty tabs")
    func activeTabAfterClosingEmpty() {
        let tab = EditorTab(url: URL(fileURLWithPath: "/tmp/a.swift"), content: "", savedContent: "")
        let result = TabCollection.activeTabAfterClosing(
            closedIndex: 0, closedID: tab.id, currentActiveID: tab.id, tabs: []
        )
        #expect(result == nil)
    }

    @Test("activeTabAfterClosing keeps current if not closed")
    func activeTabAfterClosingNotActive() {
        let tabs = makeTabs(["a.swift", "b.swift"])
        let result = TabCollection.activeTabAfterClosing(
            closedIndex: 0, closedID: tabs[0].id, currentActiveID: tabs[1].id, tabs: [tabs[1]]
        )
        #expect(result == tabs[1].id)
    }

    // MARK: - Navigation

    @Test("nextTabIndex wraps around")
    func nextTabIndex() {
        #expect(TabCollection.nextTabIndex(current: 0, count: 3) == 1)
        #expect(TabCollection.nextTabIndex(current: 2, count: 3) == 0)
        #expect(TabCollection.nextTabIndex(current: nil, count: 3) == 0)
        #expect(TabCollection.nextTabIndex(current: 0, count: 0) == nil)
    }

    @Test("previousTabIndex wraps around")
    func previousTabIndex() {
        #expect(TabCollection.previousTabIndex(current: 1, count: 3) == 0)
        #expect(TabCollection.previousTabIndex(current: 0, count: 3) == 2)
        #expect(TabCollection.previousTabIndex(current: nil, count: 3) == 2)
        #expect(TabCollection.previousTabIndex(current: 0, count: 0) == nil)
    }
}
