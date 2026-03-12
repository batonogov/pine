//
//  TabManagerTests.swift
//  PineTests
//
//  Created by Claude on 12.03.2026.
//

import Foundation
import Testing

@testable import Pine

@Suite("TabManager Tests")
struct TabManagerTests {

    /// Creates a temporary file URL for testing.
    private func tempFileURL(name: String = "test.swift", content: String = "hello") -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try? content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test("Open tab loads content and activates it")
    func openTab() {
        let manager = TabManager()
        let url = tempFileURL(content: "let x = 1")

        manager.openTab(url: url)

        #expect(manager.tabs.count == 1)
        #expect(manager.activeTab?.url == url)
        #expect(manager.activeTab?.content == "let x = 1")
        #expect(manager.activeTab?.isDirty == false)
    }

    @Test("Open duplicate tab activates existing tab")
    func openDuplicateTab() {
        let manager = TabManager()
        let url = tempFileURL()

        manager.openTab(url: url)
        let firstID = manager.activeTabID

        manager.openTab(url: url)

        #expect(manager.tabs.count == 1)
        #expect(manager.activeTabID == firstID)
    }

    @Test("Close tab selects adjacent tab")
    func closeTabSelectsAdjacent() {
        let manager = TabManager()
        let url1 = tempFileURL(name: "a.swift")
        let url2 = tempFileURL(name: "b.swift")
        let url3 = tempFileURL(name: "c.swift")

        manager.openTab(url: url1)
        manager.openTab(url: url2)
        manager.openTab(url: url3)

        // Active is url3 (last opened). Close it.
        guard let closedID = manager.activeTabID else {
            Issue.record("activeTabID should not be nil")
            return
        }
        manager.closeTab(id: closedID)

        #expect(manager.tabs.count == 2)
        // Should select the tab at the same index (clamped), which is url2
        #expect(manager.activeTab?.url == url2)
    }

    @Test("Close last remaining tab clears activeTabID")
    func closeLastTab() {
        let manager = TabManager()
        let url = tempFileURL()

        manager.openTab(url: url)
        guard let tabID = manager.activeTabID else {
            Issue.record("activeTabID should not be nil")
            return
        }
        manager.closeTab(id: tabID)

        #expect(manager.tabs.isEmpty)
        #expect(manager.activeTabID == nil)
    }

    @Test("Update content marks tab as dirty")
    func updateContentMarksDirty() {
        let manager = TabManager()
        let url = tempFileURL(content: "original")

        manager.openTab(url: url)
        #expect(manager.activeTab?.isDirty == false)

        manager.updateContent("modified")
        #expect(manager.activeTab?.isDirty == true)
        #expect(manager.activeTab?.content == "modified")
    }

    @Test("Save tab writes to disk and clears dirty state")
    func saveTab() {
        let manager = TabManager()
        let url = tempFileURL(content: "original")

        manager.openTab(url: url)
        manager.updateContent("modified")
        #expect(manager.activeTab?.isDirty == true)

        manager.saveActiveTab()
        #expect(manager.activeTab?.isDirty == false)

        // Verify file on disk
        let onDisk = try? String(contentsOf: url, encoding: .utf8)
        #expect(onDisk == "modified")
    }

    @Test("Handle file renamed updates tab URL")
    func handleFileRenamed() {
        let manager = TabManager()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let oldURL = dir.appendingPathComponent("old.swift")
        let newURL = dir.appendingPathComponent("new.swift")
        try? "content".write(to: oldURL, atomically: true, encoding: .utf8)

        manager.openTab(url: oldURL)
        manager.handleFileRenamed(oldURL: oldURL, newURL: newURL)

        #expect(manager.tabs.count == 1)
        #expect(manager.activeTab?.url == newURL)
    }

    @Test("Tabs affected by deletion")
    func tabsAffectedByDeletion() {
        let manager = TabManager()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let subdir = dir.appendingPathComponent("sub")
        try? FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)

        let file1 = dir.appendingPathComponent("a.swift")
        let file2 = subdir.appendingPathComponent("b.swift")
        let file3 = dir.appendingPathComponent("c.swift")
        for f in [file1, file2, file3] {
            try? "x".write(to: f, atomically: true, encoding: .utf8)
        }

        manager.openTab(url: file1)
        manager.openTab(url: file2)
        manager.openTab(url: file3)

        // Deleting the subdir should affect file2
        let affected = manager.tabsAffectedByDeletion(url: subdir)
        #expect(affected.count == 1)
        #expect(affected.first?.url == file2)
    }

    @Test("Move tab reorders correctly")
    func moveTab() {
        let manager = TabManager()
        let url1 = tempFileURL(name: "a.swift")
        let url2 = tempFileURL(name: "b.swift")
        let url3 = tempFileURL(name: "c.swift")

        manager.openTab(url: url1)
        manager.openTab(url: url2)
        manager.openTab(url: url3)

        // Move first tab to end
        manager.moveTab(fromOffsets: IndexSet(integer: 0), toOffset: 3)

        #expect(manager.tabs[0].url == url2)
        #expect(manager.tabs[1].url == url3)
        #expect(manager.tabs[2].url == url1)
    }
}
