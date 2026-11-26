import Testing
import Foundation
@testable import Pine

@Suite("PaneManager empty editor presentation")
@MainActor
struct PaneManagerPruneEmptyEditorTests {
    @Test func singleEmptyEditorRootIsNotPruned() {
        let manager = PaneManager()
        manager.pruneEmptyEditorLeaves()
        #expect(manager.root.leafCount == 1)
        #expect(manager.root.leafCount(ofType: .editor) == 1)
        #expect(manager.tabManagers.count == 1)
    }

    @Test func emptyEditorNextToTerminalIsHiddenAndRestoredOnDemand() {
        let manager = PaneManager()
        let terminalID = manager.createTerminalPaneAtBottom(workingDirectory: nil)
        let editorManager = manager.activeEditorTabManager

        manager.pruneEmptyEditorLeaves()
        #expect(manager.root.leafCount == 1)
        #expect(manager.root.firstLeafID == terminalID)
        #expect(manager.root.leafCount(ofType: .editor) == 0)
        #expect(manager.tabManagers.count == 1)

        let restored = manager.ensureEditorPane()
        #expect(restored === editorManager)
        #expect(manager.root.leafCount == 2)
        #expect(manager.root.leafCount(ofType: .editor) == 1)
        #expect(manager.activeTabManager === restored)
    }

    @Test func nonEmptyEditorRemainsVisibleAndPruneIsIdempotent() {
        let manager = PaneManager()
        let editorID = manager.activePaneID
        manager.tabManager(for: editorID)?.tabs = [
            EditorTab(url: URL(fileURLWithPath: "/project/a.swift")),
        ]
        _ = manager.createTerminalPaneAtBottom(workingDirectory: nil)

        manager.pruneEmptyEditorLeaves()
        let root = manager.root
        manager.pruneEmptyEditorLeaves()
        #expect(manager.root == root)
        #expect(manager.root.leafCount(ofType: .editor) == 1)
    }
}
