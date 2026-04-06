//
//  PaneManagerPruneEmptyEditorTests.swift
//  PineTests
//
//  Tests for `PaneManager.pruneEmptyEditorLeaves()`, which collapses
//  editor leaves whose TabManager has no tabs whenever the tree still
//  contains another editor leaf. Fixes the UX bug where an empty
//  "No File Selected" placeholder dominated the layout next to other panes.
//

import Testing
import Foundation
@testable import Pine

@Suite("PaneManager prune empty editor leaves")
@MainActor
struct PaneManagerPruneEmptyEditorTests {

    /// Creates a real file in a unique temp directory and opens it via
    /// `TabManager.openTab(url:)` so all tab invariants (highlight cache,
    /// dirty tracking, observers) are exercised exactly like in production.
    /// Returns the file URL so callers can reference it later (e.g. DnD).
    @discardableResult
    private func openDummyTab(in tm: TabManager, name: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-prune-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try? "// \(name)".write(to: url, atomically: true, encoding: .utf8)
        tm.openTab(url: url)
        return url
    }

    // MARK: - Single pane (root) is never pruned

    @Test func singleEmptyEditorRoot_isNotPruned() {
        let manager = PaneManager()
        manager.pruneEmptyEditorLeaves()
        #expect(manager.root.leafCount == 1)
        #expect(manager.tabManagers.count == 1)
    }

    // MARK: - Two editor leaves: empty one collapses next to non-empty

    @Test func emptyEditor_collapsesNextToEditorWithTabs() {
        let manager = PaneManager()
        let original = manager.activePaneID
        // Original editor is empty. Split → new editor pane (also empty).
        guard let newID = manager.splitPane(original, axis: .horizontal) else {
            Issue.record("split failed"); return
        }
        // Give the NEW pane a tab so the original empty one is the victim.
        guard let newTM = manager.tabManager(for: newID) else {
            Issue.record("missing TM"); return
        }
        openDummyTab(in: newTM, name: "a.swift")

        manager.pruneEmptyEditorLeaves()

        #expect(manager.root.leafCount == 1)
        #expect(manager.tabManagers[original] == nil)
        #expect(manager.tabManagers[newID] != nil)
        // Active pane should now be the surviving leaf.
        #expect(manager.activePaneID == newID)
    }

    // MARK: - Empty editor next to terminal: pruned (no inhabitant invariant)

    @Test func emptyEditorNextToTerminal_isPruned() {
        let manager = PaneManager()
        let editorID = manager.activePaneID
        let terminalID = manager.createTerminalPane(
            relativeTo: editorID, axis: .horizontal, workingDirectory: nil
        )
        #expect(manager.root.leafCount == 2)

        manager.pruneEmptyEditorLeaves()

        // Editor must be removed — terminals-only layout is now valid.
        #expect(manager.root.leafCount == 1)
        #expect(manager.root.leafCount(ofType: .editor) == 0)
        #expect(manager.tabManagers[editorID] == nil)
        #expect(manager.root.firstLeafID == terminalID)
    }

    // MARK: - ensureEditorPane: re-creates editor when only terminals remain

    @Test func ensureEditorPane_createsNewEditorWhenOnlyTerminalsExist() {
        let manager = PaneManager()
        let editorID = manager.activePaneID
        _ = manager.createTerminalPane(
            relativeTo: editorID, axis: .horizontal, workingDirectory: nil
        )
        manager.pruneEmptyEditorLeaves()
        #expect(manager.root.leafCount(ofType: .editor) == 0)

        let tm = manager.ensureEditorPane()

        // A fresh editor leaf is created and active.
        #expect(manager.root.leafCount(ofType: .editor) == 1)
        #expect(manager.root.leafCount == 2)
        #expect(tm.tabs.isEmpty)
        // The newly-created editor pane is now the active pane.
        #expect(manager.tabManagers[manager.activePaneID] === tm)
    }

    @Test func ensureEditorPane_returnsExistingEditorWhenOneAlreadyExists() {
        let manager = PaneManager()
        let editorID = manager.activePaneID
        let originalTM = manager.tabManager(for: editorID)

        let tm = manager.ensureEditorPane()

        #expect(tm === originalTM)
        #expect(manager.root.leafCount(ofType: .editor) == 1)
    }

    /// Quick Open path: simulates `QuickOpenView.openFile` against a
    /// terminals-only layout — must transparently recreate an editor leaf
    /// and open the file in it. Mirrors the production code path
    /// `paneManager.ensureEditorPane().openTab(url:)`.
    @Test func quickOpen_inTerminalsOnlyLayout_recreatesEditorAndOpensFile() {
        let manager = PaneManager()
        let editorID = manager.activePaneID
        _ = manager.createTerminalPane(
            relativeTo: editorID, axis: .horizontal, workingDirectory: nil
        )
        manager.pruneEmptyEditorLeaves()
        #expect(manager.root.leafCount(ofType: .editor) == 0)

        // Simulate Quick Open's openFile flow.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-quick-open-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("opened-via-quick-open.swift")
        try? "// quick open".write(to: url, atomically: true, encoding: .utf8)
        manager.ensureEditorPane().openTab(url: url)

        #expect(manager.root.leafCount(ofType: .editor) == 1)
        let activeTM = manager.tabManagers[manager.activePaneID]
        #expect(activeTM?.tabs.count == 1)
        #expect(activeTM?.tabs.first?.url == url)
    }

    @Test func ensureEditorPane_thenOpenFile_endToEnd() {
        let manager = PaneManager()
        let editorID = manager.activePaneID
        _ = manager.createTerminalPane(
            relativeTo: editorID, axis: .horizontal, workingDirectory: nil
        )
        manager.pruneEmptyEditorLeaves()
        #expect(manager.root.leafCount(ofType: .editor) == 0)

        // Simulate opening a file from the sidebar after pruning.
        let url = URL(fileURLWithPath: "/tmp/ensure-end-to-end.swift")
        manager.ensureEditorPane().openTab(url: url)

        #expect(manager.root.leafCount(ofType: .editor) == 1)
        let activeTM = manager.tabManagers[manager.activePaneID]
        #expect(activeTM?.tabs.count == 1)
        #expect(activeTM?.tabs.first?.url == url)
    }

    // MARK: - DnD: moving last tab away collapses empty source

    @Test func moveTabBetweenPanes_collapsesEmptySourceEditor() {
        let manager = PaneManager()
        let sourceID = manager.activePaneID
        guard let sourceTM = manager.tabManager(for: sourceID) else {
            Issue.record("missing TM"); return
        }
        let movedURL = openDummyTab(in: sourceTM, name: "moved.swift")

        guard let destID = manager.splitPane(sourceID, axis: .horizontal) else {
            Issue.record("split failed"); return
        }
        // Give dest its own tab so it survives prune.
        guard let destTM = manager.tabManager(for: destID) else {
            Issue.record("missing dest TM"); return
        }
        openDummyTab(in: destTM, name: "keep.swift")

        manager.moveTabBetweenPanes(
            tabURL: movedURL,
            from: sourceID,
            to: destID
        )

        #expect(manager.root.leafCount == 1)
        #expect(manager.tabManagers[sourceID] == nil)
        #expect(manager.tabManagers[destID] != nil)
        #expect(manager.activePaneID == destID)
    }

    // MARK: - Deeply nested tree: middle empty editor pruned, parent splits collapse

    @Test func deeplyNestedEmptyEditor_isPrunedAndParentCollapses() {
        let manager = PaneManager()
        let rootID = manager.activePaneID
        // Build: split root horizontally → A | B; split B vertically → A | (B / C)
        guard let bID = manager.splitPane(rootID, axis: .horizontal) else {
            Issue.record("split B failed"); return
        }
        guard let cID = manager.splitPane(bID, axis: .vertical) else {
            Issue.record("split C failed"); return
        }
        // Give A and C tabs; B remains empty.
        if let tmA = manager.tabManager(for: rootID) {
            openDummyTab(in: tmA, name: "a.swift")
        }
        if let tmC = manager.tabManager(for: cID) {
            openDummyTab(in: tmC, name: "c.swift")
        }
        #expect(manager.root.leafCount == 3)

        manager.pruneEmptyEditorLeaves()

        #expect(manager.root.leafCount == 2)
        #expect(manager.tabManagers[bID] == nil)
        // Both surviving leaves still present.
        let ids = Set(manager.root.leafIDs)
        #expect(ids.contains(rootID))
        #expect(ids.contains(cID))
    }

    // MARK: - Multiple empty editors: all pruned except one (invariant)

    @Test func multipleEmptyEditors_keepsAtLeastOne() {
        let manager = PaneManager()
        let firstID = manager.activePaneID
        guard let secondID = manager.splitPane(firstID, axis: .horizontal) else {
            Issue.record("split failed"); return
        }
        guard let thirdID = manager.splitPane(secondID, axis: .horizontal) else {
            Issue.record("split failed"); return
        }
        _ = thirdID
        // All three editors are empty.
        manager.pruneEmptyEditorLeaves()

        // Exactly one editor must survive.
        #expect(manager.root.leafCount(ofType: .editor) == 1)
        #expect(manager.root.leafCount == 1)
    }

    // MARK: - Maximized empty editor is not pruned

    @Test func maximizedEmptyEditor_isNotPruned() {
        let manager = PaneManager()
        let firstID = manager.activePaneID
        guard let secondID = manager.splitPane(firstID, axis: .horizontal) else {
            Issue.record("split failed"); return
        }
        if let tm2 = manager.tabManager(for: secondID) {
            openDummyTab(in: tm2, name: "x.swift")
        }
        // Maximize the empty pane.
        manager.maximize(paneID: firstID)
        #expect(manager.maximizedPaneID == firstID)

        manager.pruneEmptyEditorLeaves()

        // Maximized pane must remain intact.
        #expect(manager.maximizedPaneID == firstID)
        #expect(manager.tabManagers[firstID] != nil)
    }

    // MARK: - Idempotence

    @Test func pruneIsIdempotent() {
        let manager = PaneManager()
        let firstID = manager.activePaneID
        guard let secondID = manager.splitPane(firstID, axis: .horizontal) else {
            Issue.record("split failed"); return
        }
        if let tm2 = manager.tabManager(for: secondID) {
            openDummyTab(in: tm2, name: "x.swift")
        }
        manager.pruneEmptyEditorLeaves()
        let snapshotLeaves = manager.root.leafCount
        let snapshotIDs = manager.root.leafIDs
        manager.pruneEmptyEditorLeaves()
        manager.pruneEmptyEditorLeaves()
        #expect(manager.root.leafCount == snapshotLeaves)
        #expect(manager.root.leafIDs == snapshotIDs)
    }

    // MARK: - Active pane reassignment when victim was active

    @Test func activePaneReassignedWhenVictimWasActive() {
        let manager = PaneManager()
        let firstID = manager.activePaneID
        guard let secondID = manager.splitPane(firstID, axis: .horizontal) else {
            Issue.record("split failed"); return
        }
        if let tm2 = manager.tabManager(for: secondID) {
            openDummyTab(in: tm2, name: "x.swift")
        }
        // Make the empty pane active explicitly.
        manager.activePaneID = firstID

        manager.pruneEmptyEditorLeaves()

        #expect(manager.activePaneID == secondID)
        #expect(manager.tabManagers[firstID] == nil)
    }
}
