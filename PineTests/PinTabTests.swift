//
//  PinTabTests.swift
//  PineTests
//
//  Created by Claude on 25.03.2026.
//

import Foundation
import Testing

@testable import Pine

@Suite("Pin Tab Tests")
@MainActor
struct PinTabTests {

    /// Creates a temporary file URL for testing.
    private func tempFileURL(name: String = "test.swift", content: String = "hello") -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try? content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Returns the ID of a tab with the given URL, or records a test failure.
    private func tabID(in manager: TabManager, for url: URL) -> UUID? {
        guard let tab = manager.tabs.first(where: { $0.url == url }) else {
            Issue.record("Tab not found for \(url.lastPathComponent)")
            return nil
        }
        return tab.id
    }

    // MARK: - Toggle pin

    @Test("Toggle pin sets isPinned to true")
    func togglePinOn() throws {
        let manager = TabManager()
        let url = tempFileURL()
        manager.openTab(url: url)
        guard let tabID = manager.activeTabID else {
            Issue.record("activeTabID should not be nil")
            return
        }

        manager.togglePin(id: tabID)

        #expect(manager.tabs[0].isPinned == true)
    }

    @Test("Toggle pin twice restores isPinned to false")
    func togglePinOff() throws {
        let manager = TabManager()
        let url = tempFileURL()
        manager.openTab(url: url)
        guard let tabID = manager.activeTabID else {
            Issue.record("activeTabID should not be nil")
            return
        }

        manager.togglePin(id: tabID)
        manager.togglePin(id: tabID)

        #expect(manager.tabs[0].isPinned == false)
    }

    // MARK: - Pinned tabs sort to the left

    @Test("Pinning a tab moves it to the left of unpinned tabs")
    func pinnedTabMovesToLeft() throws {
        let manager = TabManager()
        let url1 = tempFileURL(name: "a.swift")
        let url2 = tempFileURL(name: "b.swift")
        let url3 = tempFileURL(name: "c.swift")

        manager.openTab(url: url1)
        manager.openTab(url: url2)
        manager.openTab(url: url3)

        // Pin the third tab (c.swift)
        let tabCID = manager.tabs[2].id
        manager.togglePin(id: tabCID)

        // c.swift should now be at index 0 (first pinned)
        #expect(manager.tabs[0].url == url3)
        #expect(manager.tabs[0].isPinned == true)
        #expect(manager.tabs[1].url == url1)
        #expect(manager.tabs[2].url == url2)
    }

    @Test("Unpinning a tab moves it to start of unpinned group")
    func unpinnedTabMovesRight() throws {
        let manager = TabManager()
        let url1 = tempFileURL(name: "a.swift")
        let url2 = tempFileURL(name: "b.swift")
        let url3 = tempFileURL(name: "c.swift")

        manager.openTab(url: url1)
        manager.openTab(url: url2)
        manager.openTab(url: url3)

        // Pin a and b
        guard let idA = tabID(in: manager, for: url1),
              let idB = tabID(in: manager, for: url2) else { return }
        manager.togglePin(id: idA)
        manager.togglePin(id: idB)

        // Now unpin a
        guard let idAAfter = tabID(in: manager, for: url1) else { return }
        manager.togglePin(id: idAAfter)

        // b should be pinned at 0, a should be at 1 (start of unpinned), c at 2
        #expect(manager.tabs[0].url == url2)
        #expect(manager.tabs[0].isPinned == true)
        #expect(manager.tabs[1].url == url1)
        #expect(manager.tabs[1].isPinned == false)
        #expect(manager.tabs[2].url == url3)
    }

    // MARK: - Close protection

    @Test("Closing a pinned tab is a no-op without force")
    func closePinnedTabNoOp() throws {
        let manager = TabManager()
        let url = tempFileURL()
        manager.openTab(url: url)
        guard let tabID = manager.activeTabID else {
            Issue.record("activeTabID should not be nil")
            return
        }

        manager.togglePin(id: tabID)
        manager.closeTab(id: tabID)

        // Tab should still be there
        #expect(manager.tabs.count == 1)
        #expect(manager.tabs[0].isPinned == true)
    }

    @Test("Closing a pinned tab with force removes it")
    func closePinnedTabForce() throws {
        let manager = TabManager()
        let url = tempFileURL()
        manager.openTab(url: url)
        guard let tabID = manager.activeTabID else {
            Issue.record("activeTabID should not be nil")
            return
        }

        manager.togglePin(id: tabID)
        manager.closeTab(id: tabID, force: true)

        #expect(manager.tabs.isEmpty)
    }

    // MARK: - Reorder constraints

    @Test("Reorder between pinned and unpinned groups is blocked")
    func reorderBetweenGroupsBlocked() throws {
        let manager = TabManager()
        let url1 = tempFileURL(name: "a.swift")
        let url2 = tempFileURL(name: "b.swift")

        manager.openTab(url: url1)
        manager.openTab(url: url2)

        // Pin a
        guard let idA = tabID(in: manager, for: url1) else { return }
        manager.togglePin(id: idA)

        let pinnedID = manager.tabs[0].id
        let unpinnedID = manager.tabs[1].id

        // Try to reorder pinned onto unpinned
        manager.reorderTab(draggedID: pinnedID, targetID: unpinnedID)

        // Order should not change
        #expect(manager.tabs[0].url == url1)
        #expect(manager.tabs[1].url == url2)
    }

    @Test("Reorder within pinned group works")
    func reorderWithinPinnedGroup() throws {
        let manager = TabManager()
        let url1 = tempFileURL(name: "a.swift")
        let url2 = tempFileURL(name: "b.swift")
        let url3 = tempFileURL(name: "c.swift")

        manager.openTab(url: url1)
        manager.openTab(url: url2)
        manager.openTab(url: url3)

        // Pin a and b
        guard let idA = tabID(in: manager, for: url1),
              let idB = tabID(in: manager, for: url2) else { return }
        manager.togglePin(id: idA)
        manager.togglePin(id: idB)

        guard let idAAfter = tabID(in: manager, for: url1),
              let idBAfter = tabID(in: manager, for: url2) else { return }

        // Reorder a after b
        manager.reorderTab(draggedID: idAAfter, targetID: idBAfter)

        #expect(manager.tabs[0].url == url2)
        #expect(manager.tabs[1].url == url1)
    }

    // MARK: - Pin all / unpin all

    @Test("Pin all tabs")
    func pinAllTabs() throws {
        let manager = TabManager()
        let url1 = tempFileURL(name: "a.swift")
        let url2 = tempFileURL(name: "b.swift")

        manager.openTab(url: url1)
        manager.openTab(url: url2)

        for tab in manager.tabs {
            manager.togglePin(id: tab.id)
        }

        let allPinned = manager.tabs.allSatisfy { $0.isPinned }
        #expect(allPinned)
        #expect(manager.pinnedTabCount == 2)
    }

    @Test("Unpin all tabs")
    func unpinAllTabs() throws {
        let manager = TabManager()
        let url1 = tempFileURL(name: "a.swift")
        let url2 = tempFileURL(name: "b.swift")

        manager.openTab(url: url1)
        manager.openTab(url: url2)

        // Pin all
        for tab in manager.tabs {
            manager.togglePin(id: tab.id)
        }

        // Unpin all
        for tab in manager.tabs {
            manager.togglePin(id: tab.id)
        }

        let allUnpinned = manager.tabs.allSatisfy { !$0.isPinned }
        #expect(allUnpinned)
        #expect(manager.pinnedTabCount == 0)
    }

    // MARK: - Pin state survives file rename

    @Test("Pin state is preserved after file rename")
    func pinStateSurvivesRename() throws {
        let manager = TabManager()
        let url = tempFileURL(name: "old.swift")
        manager.openTab(url: url)
        guard let tabID = manager.activeTabID else {
            Issue.record("activeTabID should not be nil")
            return
        }

        manager.togglePin(id: tabID)

        let newURL = url.deletingLastPathComponent().appendingPathComponent("new.swift")
        try? FileManager.default.moveItem(at: url, to: newURL)
        manager.handleFileRenamed(oldURL: url, newURL: newURL)

        #expect(manager.tabs[0].isPinned == true)
        #expect(manager.tabs[0].url == newURL)
    }

    // MARK: - Pinned count

    @Test("pinnedTabCount returns correct value")
    func pinnedTabCount() throws {
        let manager = TabManager()
        let url1 = tempFileURL(name: "a.swift")
        let url2 = tempFileURL(name: "b.swift")
        let url3 = tempFileURL(name: "c.swift")

        manager.openTab(url: url1)
        manager.openTab(url: url2)
        manager.openTab(url: url3)

        #expect(manager.pinnedTabCount == 0)

        manager.togglePin(id: manager.tabs[0].id)
        #expect(manager.pinnedTabCount == 1)

        manager.togglePin(id: manager.tabs[1].id)
        #expect(manager.pinnedTabCount == 2)
    }

    // MARK: - Session restore

    @Test("restorePinnedState sets isPinned and sorts correctly")
    func restorePinnedState() throws {
        let manager = TabManager()
        let url1 = tempFileURL(name: "a.swift")
        let url2 = tempFileURL(name: "b.swift")
        let url3 = tempFileURL(name: "c.swift")

        manager.openTab(url: url1)
        manager.openTab(url: url2)
        manager.openTab(url: url3)

        // Restore: b.swift was pinned
        manager.restorePinnedState(pinnedPaths: [url2.path])

        #expect(manager.tabs[0].url == url2)
        #expect(manager.tabs[0].isPinned == true)
        #expect(manager.tabs[1].url == url1)
        #expect(manager.tabs[1].isPinned == false)
        #expect(manager.tabs[2].url == url3)
        #expect(manager.tabs[2].isPinned == false)
    }

    // MARK: - Toggle pin on nonexistent tab

    @Test("Toggle pin on nonexistent tab ID is a no-op")
    func togglePinNonexistent() throws {
        let manager = TabManager()
        let url = tempFileURL()
        manager.openTab(url: url)

        manager.togglePin(id: UUID())

        #expect(manager.tabs[0].isPinned == false)
    }

    // MARK: - EditorTab isPinned default

    @Test("EditorTab isPinned defaults to false")
    func editorTabIsPinnedDefault() throws {
        let tab = EditorTab(url: URL(fileURLWithPath: "/tmp/test.swift"))
        #expect(tab.isPinned == false)
    }

    // MARK: - Multiple pins preserve order

    @Test("Pinning multiple tabs preserves their relative order within pinned group")
    func multiplesPinsPreserveOrder() throws {
        let manager = TabManager()
        let url1 = tempFileURL(name: "a.swift")
        let url2 = tempFileURL(name: "b.swift")
        let url3 = tempFileURL(name: "c.swift")
        let url4 = tempFileURL(name: "d.swift")

        manager.openTab(url: url1)
        manager.openTab(url: url2)
        manager.openTab(url: url3)
        manager.openTab(url: url4)

        // Pin c, then a (in that order)
        guard let idC = tabID(in: manager, for: url3),
              let idA = tabID(in: manager, for: url1) else { return }
        manager.togglePin(id: idC)
        manager.togglePin(id: idA)

        // Expected: [c(pinned), a(pinned), b, d]
        #expect(manager.tabs[0].url == url3)
        #expect(manager.tabs[1].url == url1)
        #expect(manager.tabs[2].url == url2)
        #expect(manager.tabs[3].url == url4)
    }
}
