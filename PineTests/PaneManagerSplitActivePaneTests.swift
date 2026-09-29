//
//  PaneManagerSplitActivePaneTests.swift
//  PineTests
//
//  Tests for `PaneManager.splitActivePane(axis:)`, the Window menu entry
//  point for pane splitting (#1537) — previously reachable only by dragging
//  a tab onto a drop zone.
//

import Foundation
import Testing

@testable import Pine

@Suite("PaneManager split active pane (Window menu)")
@MainActor
struct PaneManagerSplitActivePaneTests {

    @discardableResult
    private func openDummyTab(in tm: TabManager, name: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-split-menu-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try? "// \(name)".write(to: url, atomically: true, encoding: .utf8)
        tm.openTab(url: url)
        return url
    }

    @Test func singleTabPane_splitsEmptyAndKeepsItsTab() throws {
        let manager = PaneManager()
        let source = manager.activePaneID
        let sourceTM = try #require(manager.tabManager(for: source))
        openDummyTab(in: sourceTM, name: "only.swift")
        let onlyTabID = try #require(sourceTM.tabs.first?.id)

        let newID = try #require(manager.splitActivePane(axis: .horizontal))

        #expect(manager.root.leafCount == 2)
        // The one tab stays in the source; the new pane starts empty, so the
        // split is never an invisible no-op.
        #expect(sourceTM.tabs.map(\.id) == [onlyTabID])
        #expect(manager.tabManager(for: newID)?.tabs.isEmpty == true)
        #expect(manager.activePaneID == newID)
    }

    @Test func multiTabPane_movesActiveTabIntoNewPane() throws {
        let manager = PaneManager()
        let source = manager.activePaneID
        let sourceTM = try #require(manager.tabManager(for: source))
        openDummyTab(in: sourceTM, name: "a.swift")
        openDummyTab(in: sourceTM, name: "b.swift")
        // openTab activates the newest tab; make the first one active.
        sourceTM.activeTabID = sourceTM.tabs[0].id
        let activeID = sourceTM.tabs[0].id

        let newID = try #require(manager.splitActivePane(axis: .vertical))

        #expect(manager.root.leafCount == 2)
        #expect(sourceTM.tabs.count == 1)
        #expect(sourceTM.tabs.first?.fileName == "b.swift")
        let newTM = try #require(manager.tabManager(for: newID))
        #expect(newTM.tabs.map(\.id) == [activeID])
        #expect(newTM.activeTabID == activeID)
        #expect(manager.activePaneID == newID)
    }

    @Test func terminalFocusedPane_splitsIntoEmptyEditor() throws {
        let manager = PaneManager()
        let editorID = manager.activePaneID
        let terminalID = try #require(manager.createTerminalPane(
            relativeTo: editorID,
            axis: .vertical,
            workingDirectory: nil
        ))
        manager.activePaneID = terminalID

        let newID = try #require(manager.splitActivePane(axis: .horizontal))

        #expect(manager.root.content(for: newID) == .editor)
        #expect(manager.tabManager(for: newID)?.tabs.isEmpty == true)
    }
}
