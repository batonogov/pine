import Testing
import Foundation
@testable import Pine

@Suite("Fixed workspace layout")
@MainActor
struct PaneManagerTests {
    @Test func initCreatesOneEditorWithExistingManager() {
        let existing = TabManager()
        let manager = PaneManager(existingTabManager: existing)
        #expect(manager.root.leafCount == 1)
        #expect(manager.activeTabManager === existing)
        #expect(manager.tabManagers.count == 1)
        #expect(manager.terminalPaneIDs.isEmpty)
    }

    @Test func terminalIsSingleAdjacentDestinationAndIsReused() {
        let manager = PaneManager()
        let first = manager.createTerminalPaneAtBottom(workingDirectory: nil)
        let second = manager.createTerminalPaneAtBottom(workingDirectory: nil)

        #expect(first == second)
        #expect(manager.terminalPaneIDs == [first])
        #expect(manager.root.leafCount == 2)
        #expect(manager.terminalState(for: first)?.tabCount == 2)
    }

    @Test func removingTerminalRestoresEditorOnlyLayout() {
        let manager = PaneManager()
        let terminal = manager.createTerminalPaneAtBottom(workingDirectory: nil)
        manager.removePane(terminal)
        #expect(manager.terminalPaneIDs.isEmpty)
        #expect(manager.terminalState(for: terminal) == nil)
        #expect(manager.root.leafCount == 1)
        #expect(manager.root.leafCount(ofType: .editor) == 1)
    }

    @Test func terminalZoomKeepsPersistableFixedLayout() {
        let manager = PaneManager()
        let terminal = manager.createTerminalPaneAtBottom(workingDirectory: nil)
        manager.maximize(paneID: terminal)
        #expect(manager.root.leafCount == 1)
        #expect(manager.persistableRoot.leafCount == 2)
        manager.restoreFromMaximize()
        #expect(manager.root.leafCount == 2)
        #expect(!manager.isMaximized)
    }

    @Test func dividerRatioIsClamped() {
        let manager = PaneManager()
        let terminal = manager.createTerminalPaneAtBottom(workingDirectory: nil)
        manager.updateRatio(for: terminal, ratio: 0.05)
        guard case .split(_, _, _, let ratio) = manager.root else {
            Issue.record("Expected fixed editor/terminal divider")
            return
        }
        #expect(ratio == 0.1)
    }

    @Test func legacyTreeMigrationSelectsOneEditorAndTerminal() {
        let manager = PaneManager()
        let editorA = PaneID()
        let editorB = PaneID()
        let terminalA = PaneID()
        let terminalB = PaneID()
        let legacy = PaneNode.split(
            .horizontal,
            first: .split(.vertical, first: .leaf(editorA, .editor), second: .leaf(terminalA, .terminal), ratio: 0.5),
            second: .split(.vertical, first: .leaf(editorB, .editor), second: .leaf(terminalB, .terminal), ratio: 0.6),
            ratio: 0.5
        )

        let migration = manager.restoreLayout(from: legacy, activePaneUUID: editorB.id)
        #expect(migration?.editorPaneID == editorB)
        #expect(migration?.editorSourcePaneIDs == [editorB, editorA])
        #expect(migration?.terminalPaneID == terminalA)
        #expect(migration?.terminalSourcePaneIDs == [terminalA, terminalB])
        #expect(migration?.activePaneID == editorB)
        #expect(manager.root.leafCount == 2)
        #expect(manager.tabManagers.count == 1)
        #expect(manager.terminalStates.count == 1)
    }

    @Test func terminalOnlyLegacyTreeKeepsEditorManagerOffscreen() {
        let existing = TabManager()
        let manager = PaneManager(existingTabManager: existing)
        let terminal = PaneID()
        let migration = manager.restoreLayout(
            from: .leaf(terminal, .terminal),
            activePaneUUID: terminal.id
        )
        #expect(migration?.terminalPaneID == terminal)
        #expect(migration?.editorSourcePaneIDs.isEmpty == true)
        #expect(manager.activeEditorTabManager === existing)
        #expect(manager.root.leafCount(ofType: .editor) == 0)

        _ = manager.ensureEditorPane()
        #expect(manager.root.leafCount(ofType: .editor) == 1)
        #expect(manager.activeTabManager === existing)
    }
}
