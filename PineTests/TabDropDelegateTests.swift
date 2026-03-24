//
//  TabDropDelegateTests.swift
//  PineTests
//
//  Created by Claude on 24.03.2026.
//

import Foundation
import Testing

@testable import Pine

@Suite("Tab Drag Reorder Tests")
struct TabDragReorderTests {

    /// Creates a temporary file URL for testing.
    private func tempFileURL(name: String = "test.swift") -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try? "test".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func makeManager(fileNames: [String]) -> TabManager {
        let manager = TabManager()
        for name in fileNames {
            manager.openTab(url: tempFileURL(name: name))
        }
        return manager
    }

    // MARK: - reorderTab(draggedID:targetID:)

    @Test("Reorder tab forward: first to last")
    func reorderForward() {
        let manager = makeManager(fileNames: ["a.swift", "b.swift", "c.swift"])
        let dragID = manager.tabs[0].id
        let targetID = manager.tabs[2].id

        manager.reorderTab(draggedID: dragID, targetID: targetID)

        #expect(manager.tabs.map(\.fileName) == ["b.swift", "c.swift", "a.swift"])
    }

    @Test("Reorder tab backward: last to first")
    func reorderBackward() {
        let manager = makeManager(fileNames: ["a.swift", "b.swift", "c.swift"])
        let dragID = manager.tabs[2].id
        let targetID = manager.tabs[0].id

        manager.reorderTab(draggedID: dragID, targetID: targetID)

        #expect(manager.tabs.map(\.fileName) == ["c.swift", "a.swift", "b.swift"])
    }

    @Test("Reorder adjacent tabs forward")
    func reorderAdjacentForward() {
        let manager = makeManager(fileNames: ["a.swift", "b.swift"])
        let dragID = manager.tabs[0].id
        let targetID = manager.tabs[1].id

        manager.reorderTab(draggedID: dragID, targetID: targetID)

        #expect(manager.tabs.map(\.fileName) == ["b.swift", "a.swift"])
    }

    @Test("Reorder adjacent tabs backward")
    func reorderAdjacentBackward() {
        let manager = makeManager(fileNames: ["a.swift", "b.swift"])
        let dragID = manager.tabs[1].id
        let targetID = manager.tabs[0].id

        manager.reorderTab(draggedID: dragID, targetID: targetID)

        #expect(manager.tabs.map(\.fileName) == ["b.swift", "a.swift"])
    }

    @Test("Reorder same tab as target does nothing")
    func reorderSameTab() {
        let manager = makeManager(fileNames: ["a.swift", "b.swift", "c.swift"])
        let tabID = manager.tabs[1].id

        manager.reorderTab(draggedID: tabID, targetID: tabID)

        #expect(manager.tabs.map(\.fileName) == ["a.swift", "b.swift", "c.swift"])
    }

    @Test("Reorder with non-existent dragged ID does nothing")
    func reorderNonExistentDragged() {
        let manager = makeManager(fileNames: ["a.swift", "b.swift"])
        let targetID = manager.tabs[0].id

        manager.reorderTab(draggedID: UUID(), targetID: targetID)

        #expect(manager.tabs.map(\.fileName) == ["a.swift", "b.swift"])
    }

    @Test("Reorder with non-existent target ID does nothing")
    func reorderNonExistentTarget() {
        let manager = makeManager(fileNames: ["a.swift", "b.swift"])
        let dragID = manager.tabs[0].id

        manager.reorderTab(draggedID: dragID, targetID: UUID())

        #expect(manager.tabs.map(\.fileName) == ["a.swift", "b.swift"])
    }

    @Test("Reorder middle tab to first position")
    func reorderMiddleToFirst() {
        let manager = makeManager(fileNames: ["a.swift", "b.swift", "c.swift", "d.swift"])
        let dragID = manager.tabs[2].id
        let targetID = manager.tabs[0].id

        manager.reorderTab(draggedID: dragID, targetID: targetID)

        #expect(manager.tabs.map(\.fileName) == ["c.swift", "a.swift", "b.swift", "d.swift"])
    }

    @Test("Reorder middle tab to last position")
    func reorderMiddleToLast() {
        let manager = makeManager(fileNames: ["a.swift", "b.swift", "c.swift", "d.swift"])
        let dragID = manager.tabs[1].id
        let targetID = manager.tabs[3].id

        manager.reorderTab(draggedID: dragID, targetID: targetID)

        #expect(manager.tabs.map(\.fileName) == ["a.swift", "c.swift", "d.swift", "b.swift"])
    }

    @Test("Reorder preserves active tab ID")
    func reorderPreservesActiveTab() {
        let manager = makeManager(fileNames: ["a.swift", "b.swift", "c.swift"])
        let activeID = manager.tabs[1].id
        manager.activeTabID = activeID

        manager.reorderTab(draggedID: manager.tabs[0].id, targetID: manager.tabs[2].id)

        #expect(manager.activeTabID == activeID)
    }

    @Test("Reorder single tab does nothing")
    func reorderSingleTab() {
        let manager = makeManager(fileNames: ["a.swift"])
        let tabID = manager.tabs[0].id

        manager.reorderTab(draggedID: tabID, targetID: tabID)

        #expect(manager.tabs.count == 1)
        #expect(manager.tabs[0].fileName == "a.swift")
    }

    @Test("Multiple sequential reorders produce correct final order")
    func multipleReorders() {
        let manager = makeManager(fileNames: ["a.swift", "b.swift", "c.swift", "d.swift"])

        // Move a.swift to after c.swift -> [b, c, a, d]
        let aID = manager.tabs[0].id
        let cID = manager.tabs[2].id
        manager.reorderTab(draggedID: aID, targetID: cID)
        #expect(manager.tabs.map(\.fileName) == ["b.swift", "c.swift", "a.swift", "d.swift"])

        // Move d.swift to first position -> [d, b, c, a]
        let dID = manager.tabs[3].id
        let bID = manager.tabs[0].id
        manager.reorderTab(draggedID: dID, targetID: bID)
        #expect(manager.tabs.map(\.fileName) == ["d.swift", "b.swift", "c.swift", "a.swift"])
    }
}
