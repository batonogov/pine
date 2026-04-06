//
//  CrossTypeCenterDropTests.swift
//  PineTests
//
//  Tests for cross-type center drop (issue #714).
//  When a terminal tab is dropped in the center of an editor pane
//  (or an editor tab in the center of a terminal pane), the target
//  pane is auto-split vertically: original content stays on top,
//  the moved tab lands in a new pane below.
//

import Foundation
import Testing

@testable import Pine

@Suite("Cross-Type Center Drop Tests")
@MainActor
struct CrossTypeCenterDropTests {

    // MARK: - Terminal tab → Editor pane center

    @Test("terminal tab center-dropped on editor pane creates vertical auto-split")
    func terminalOnEditorCenter_autoSplits() throws {
        let manager = PaneManager()
        let editorPaneID = manager.activePaneID
        let editorTM = try #require(manager.tabManager(for: editorPaneID))
        editorTM.openTab(url: URL(fileURLWithPath: "/tmp/a.swift"))

        // Create a terminal pane with two tabs so source survives after move
        let termPaneID = manager.createTerminalPaneAtBottom(workingDirectory: nil)
        let termState = try #require(manager.terminalState(for: termPaneID))
        termState.addTab(workingDirectory: nil)
        let termTab = termState.terminalTabs[0]

        let drag = TabDragInfo(
            paneID: termPaneID.id,
            tabID: termTab.id,
            fileURL: nil,
            contentType: .terminal
        )

        let ok = manager.performCenterDrop(dragInfo: drag, targetPaneID: editorPaneID)

        #expect(ok)
        // Editor pane still exists with its tab
        #expect(manager.tabManager(for: editorPaneID)?.tabs.count == 1)
        // A new terminal pane was created holding the moved tab
        let terminalPanes = manager.terminalPaneIDs
        #expect(terminalPanes.count == 2)
        let newTermPane = try #require(terminalPanes.first { $0 != termPaneID })
        let newState = try #require(manager.terminalState(for: newTermPane))
        #expect(newState.terminalTabs.contains { $0.id == termTab.id })
        // Source terminal pane still has its remaining tab
        #expect(termState.terminalTabs.count == 1)
        #expect(!termState.terminalTabs.contains { $0.id == termTab.id })
        // Active pane is the new one
        #expect(manager.activePaneID == newTermPane)
    }

    @Test("terminal tab center-drop on editor: last tab removes source terminal pane")
    func terminalOnEditorCenter_lastTab_removesSource() throws {
        let manager = PaneManager()
        let editorPaneID = manager.activePaneID
        let termPaneID = manager.createTerminalPaneAtBottom(workingDirectory: nil)
        let termState = try #require(manager.terminalState(for: termPaneID))
        let tabID = termState.terminalTabs[0].id

        let drag = TabDragInfo(
            paneID: termPaneID.id,
            tabID: tabID,
            fileURL: nil,
            contentType: .terminal
        )

        let ok = manager.performCenterDrop(dragInfo: drag, targetPaneID: editorPaneID)

        #expect(ok)
        // Source terminal pane should be removed
        #expect(manager.terminalState(for: termPaneID) == nil)
        // A new terminal pane exists with the moved tab
        let terminalPanes = manager.terminalPaneIDs
        #expect(terminalPanes.count == 1)
        let newState = try #require(manager.terminalState(for: terminalPanes[0]))
        #expect(newState.terminalTabs.count == 1)
        #expect(newState.terminalTabs[0].id == tabID)
    }

    // MARK: - Editor tab → Terminal pane center

    @Test("editor tab center-dropped on terminal pane creates vertical auto-split")
    func editorOnTerminalCenter_autoSplits() throws {
        let manager = PaneManager()
        let editorPaneID = manager.activePaneID
        let editorTM = try #require(manager.tabManager(for: editorPaneID))
        let fileA = URL(fileURLWithPath: "/tmp/a.swift")
        let fileB = URL(fileURLWithPath: "/tmp/b.swift")
        editorTM.openTab(url: fileA)
        editorTM.openTab(url: fileB)

        let termPaneID = manager.createTerminalPaneAtBottom(workingDirectory: nil)

        let drag = TabDragInfo(
            paneID: editorPaneID.id,
            tabID: UUID(),
            fileURL: fileA,
            contentType: .editor
        )

        let ok = manager.performCenterDrop(dragInfo: drag, targetPaneID: termPaneID)

        #expect(ok)
        // Original editor pane still has remaining tab (fileB)
        #expect(editorTM.tabs.count == 1)
        #expect(editorTM.tabs[0].url == fileB)
        // Terminal pane still exists
        #expect(manager.terminalState(for: termPaneID) != nil)
        // A new editor pane was created with the moved file
        let editorLeaves = manager.root.leafIDs.filter { manager.root.content(for: $0) == .editor }
        #expect(editorLeaves.count == 2)
        let newEditor = try #require(editorLeaves.first { $0 != editorPaneID })
        let newTM = try #require(manager.tabManager(for: newEditor))
        #expect(newTM.tabs.count == 1)
        #expect(newTM.tabs[0].url == fileA)
    }

    @Test("editor tab center-drop on terminal: last tab keeps source editor pane (invariant)")
    func editorOnTerminalCenter_lastTab_keepsSourceEditor() throws {
        let manager = PaneManager()
        let editorPaneID = manager.activePaneID
        let editorTM = try #require(manager.tabManager(for: editorPaneID))
        let fileA = URL(fileURLWithPath: "/tmp/a.swift")
        editorTM.openTab(url: fileA)

        let termPaneID = manager.createTerminalPaneAtBottom(workingDirectory: nil)

        let drag = TabDragInfo(
            paneID: editorPaneID.id,
            tabID: UUID(),
            fileURL: fileA,
            contentType: .editor
        )

        let ok = manager.performCenterDrop(dragInfo: drag, targetPaneID: termPaneID)

        #expect(ok)
        // Invariant: there is always at least one editor pane.
        let editorLeafCount = manager.root.leafCount(ofType: .editor)
        #expect(editorLeafCount >= 1)
        // The auto-split actually happened: a new editor pane was created
        // (so we now have 2 editor leaves — the original and the new one).
        let editorLeaves = manager.root.leafIDs.filter { manager.root.content(for: $0) == .editor }
        #expect(editorLeaves.count == 2)
        // The original editor pane still exists (invariant: never destroy
        // the last editor pane, even if its last tab was moved out).
        #expect(editorLeaves.contains(editorPaneID))
        // fileA lives in the new editor pane (not the source).
        let newEditor = try #require(editorLeaves.first { $0 != editorPaneID })
        let newTM = try #require(manager.tabManager(for: newEditor))
        #expect(newTM.tabs.count == 1)
        #expect(newTM.tabs[0].url == fileA)
        // Source editor pane has been emptied (its only tab was moved).
        #expect(editorTM.tabs.isEmpty)
        // Terminal pane is still alive.
        #expect(manager.terminalState(for: termPaneID) != nil)
        #expect(manager.root.leafCount(ofType: .terminal) == 1)
    }

    // MARK: - Deeply nested pane trees

    @Test("cross-type center drop into deeply nested pane preserves tree consistency")
    func crossTypeCenter_deeplyNestedTarget_preservesTree() throws {
        // Build a 3-level deep editor tree:
        //   root split (horizontal)
        //     ├─ paneA (editor, fileA)
        //     └─ child split (vertical)
        //         ├─ paneB (editor, fileB)
        //         └─ grandchild split (horizontal)
        //             ├─ paneC (editor, fileC)
        //             └─ paneD (editor, fileD)  <-- target for cross-type drop
        let manager = PaneManager()
        let paneA = manager.activePaneID
        let tmA = try #require(manager.tabManager(for: paneA))
        let fileA = URL(fileURLWithPath: "/tmp/a.swift")
        tmA.openTab(url: fileA)

        let paneB = try #require(manager.splitPane(paneA, axis: .horizontal))
        let tmB = try #require(manager.tabManager(for: paneB))
        let fileB = URL(fileURLWithPath: "/tmp/b.swift")
        tmB.openTab(url: fileB)

        let paneC = try #require(manager.splitPane(paneB, axis: .vertical))
        let tmC = try #require(manager.tabManager(for: paneC))
        let fileC = URL(fileURLWithPath: "/tmp/c.swift")
        tmC.openTab(url: fileC)

        let paneD = try #require(manager.splitPane(paneC, axis: .horizontal))
        let tmD = try #require(manager.tabManager(for: paneD))
        let fileD = URL(fileURLWithPath: "/tmp/d.swift")
        tmD.openTab(url: fileD)

        // Create a terminal pane (wraps the whole editor tree at the bottom)
        // and add a second tab so the source survives after the move.
        let termPaneID = manager.createTerminalPaneAtBottom(workingDirectory: nil)
        let termState = try #require(manager.terminalState(for: termPaneID))
        termState.addTab(workingDirectory: nil)
        #expect(termState.terminalTabs.count == 2)
        let movedTermTabID = termState.terminalTabs[0].id

        let beforeEditorCount = manager.root.leafCount(ofType: .editor)
        let beforeTerminalCount = manager.root.leafCount(ofType: .terminal)
        #expect(beforeEditorCount == 4)
        #expect(beforeTerminalCount == 1)

        // Drop the terminal tab into the deeply nested editor pane (paneD).
        let drag = TabDragInfo(
            paneID: termPaneID.id,
            tabID: movedTermTabID,
            fileURL: nil,
            contentType: .terminal
        )
        let ok = manager.performCenterDrop(dragInfo: drag, targetPaneID: paneD)
        #expect(ok)

        // Tree consistency: editor leaf count unchanged, terminal grew by one.
        #expect(manager.root.leafCount(ofType: .editor) == beforeEditorCount)
        #expect(manager.root.leafCount(ofType: .terminal) == beforeTerminalCount + 1)

        // All original editor panes still exist with their original tabs intact.
        let allLeaves = manager.root.leafIDs
        #expect(allLeaves.contains(paneA))
        #expect(allLeaves.contains(paneB))
        #expect(allLeaves.contains(paneC))
        #expect(allLeaves.contains(paneD))
        #expect(try #require(manager.tabManager(for: paneA)).tabs.first?.url == fileA)
        #expect(try #require(manager.tabManager(for: paneB)).tabs.first?.url == fileB)
        #expect(try #require(manager.tabManager(for: paneC)).tabs.first?.url == fileC)
        #expect(try #require(manager.tabManager(for: paneD)).tabs.first?.url == fileD)

        // The new terminal pane sits adjacent to paneD (the deeply nested target)
        // and holds the moved tab. The original terminal pane still has its second tab.
        let terminalPanes = manager.terminalPaneIDs
        #expect(terminalPanes.count == 2)
        let newTermPane = try #require(terminalPanes.first { $0 != termPaneID })
        let newState = try #require(manager.terminalState(for: newTermPane))
        #expect(newState.terminalTabs.contains { $0.id == movedTermTabID })
        #expect(termState.terminalTabs.count == 1)
        #expect(!termState.terminalTabs.contains { $0.id == movedTermTabID })

        // Tree is still well-formed: every leaf is reachable via content(for:).
        for leaf in allLeaves {
            #expect(manager.root.content(for: leaf) != nil)
        }
        // And total leaf count matches the sum of editor + terminal leaves.
        #expect(manager.root.leafCount == beforeEditorCount + beforeTerminalCount + 1)
    }

    // MARK: - Same-type center drop (unchanged behaviour)

    @Test("same-type center drop still moves tab (editor→editor)")
    func sameTypeCenter_editor_stillMoves() throws {
        let manager = PaneManager()
        let paneA = manager.activePaneID
        let tmA = try #require(manager.tabManager(for: paneA))
        let fileA = URL(fileURLWithPath: "/tmp/a.swift")
        tmA.openTab(url: fileA)

        let paneB = try #require(manager.splitPane(paneA, axis: .horizontal))
        let tmB = try #require(manager.tabManager(for: paneB))
        tmB.openTab(url: URL(fileURLWithPath: "/tmp/b.swift"))

        let drag = TabDragInfo(
            paneID: paneA.id,
            tabID: UUID(),
            fileURL: fileA,
            contentType: .editor
        )

        let ok = manager.performCenterDrop(dragInfo: drag, targetPaneID: paneB)

        #expect(ok)
        #expect(tmB.tabs.contains { $0.url == fileA })
        // source pane emptied → removed
        #expect(manager.tabManager(for: paneA) == nil)
    }

    @Test("same-type center drop still moves tab (terminal→terminal)")
    func sameTypeCenter_terminal_stillMoves() throws {
        let manager = PaneManager()
        let term1 = manager.createTerminalPaneAtBottom(workingDirectory: nil)
        let state1 = try #require(manager.terminalState(for: term1))
        state1.addTab(workingDirectory: nil)
        let movedID = state1.terminalTabs[0].id

        let term2 = try #require(
            manager.createTerminalPane(relativeTo: term1, axis: .horizontal, workingDirectory: nil)
        )

        let drag = TabDragInfo(
            paneID: term1.id,
            tabID: movedID,
            fileURL: nil,
            contentType: .terminal
        )

        let ok = manager.performCenterDrop(dragInfo: drag, targetPaneID: term2)

        #expect(ok)
        let state2 = try #require(manager.terminalState(for: term2))
        #expect(state2.terminalTabs.contains { $0.id == movedID })
    }

    // MARK: - Edge cases

    @Test("same-pane center drop is a no-op")
    func samePaneCenter_noop() throws {
        let manager = PaneManager()
        let paneA = manager.activePaneID
        let tmA = try #require(manager.tabManager(for: paneA))
        let fileA = URL(fileURLWithPath: "/tmp/a.swift")
        tmA.openTab(url: fileA)

        let drag = TabDragInfo(
            paneID: paneA.id,
            tabID: UUID(),
            fileURL: fileA,
            contentType: .editor
        )

        let ok = manager.performCenterDrop(dragInfo: drag, targetPaneID: paneA)

        // No meaningful change — single pane still has its single tab
        #expect(ok == false)
        #expect(tmA.tabs.count == 1)
        #expect(manager.root.leafCount == 1)
    }

    @Test("center drop with missing source pane fails gracefully")
    func missingSourcePane_noop() throws {
        let manager = PaneManager()
        let editorPaneID = manager.activePaneID

        let drag = TabDragInfo(
            paneID: UUID(), // non-existent
            tabID: UUID(),
            fileURL: nil,
            contentType: .terminal
        )

        let ok = manager.performCenterDrop(dragInfo: drag, targetPaneID: editorPaneID)
        #expect(ok == false)
        #expect(manager.root.leafCount == 1)
    }

    @Test("cross-type center drop preserves dirty editor tab state")
    func crossTypeCenter_preservesDirtyEditorTab() throws {
        let manager = PaneManager()
        let editorPaneID = manager.activePaneID
        let editorTM = try #require(manager.tabManager(for: editorPaneID))
        let fileA = URL(fileURLWithPath: "/tmp/a.swift")
        let fileB = URL(fileURLWithPath: "/tmp/b.swift")
        editorTM.openTab(url: fileA)
        editorTM.openTab(url: fileB)
        // Mark fileA dirty by diverging content from savedContent
        if let idx = editorTM.tabs.firstIndex(where: { $0.url == fileA }) {
            editorTM.tabs[idx].content = "modified"
            editorTM.tabs[idx].savedContent = "original"
        }

        let termPaneID = manager.createTerminalPaneAtBottom(workingDirectory: nil)

        let drag = TabDragInfo(
            paneID: editorPaneID.id,
            tabID: UUID(),
            fileURL: fileA,
            contentType: .editor
        )

        let ok = manager.performCenterDrop(dragInfo: drag, targetPaneID: termPaneID)
        #expect(ok)

        // The moved tab should retain its dirty flag in the new pane
        let editorLeaves = manager.root.leafIDs.filter { manager.root.content(for: $0) == .editor }
        let newEditor = try #require(editorLeaves.first { $0 != editorPaneID })
        let newTM = try #require(manager.tabManager(for: newEditor))
        let moved = try #require(newTM.tabs.first { $0.url == fileA })
        #expect(moved.isDirty)
    }
}
