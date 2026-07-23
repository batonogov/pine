//
//  TabDragCoordinatorTests.swift
//  PineTests
//
//  Transaction, boundary, routing, and focus coverage for issue #1171.
//

import CoreGraphics
import Foundation
import Testing

@testable import Pine

@Suite("Tab Drag Coordinator")
@MainActor
struct TabDragCoordinatorTests {
    @Test("Editor strip hover is preview-only and commit moves to the last gap")
    func editorPreviewThenCommit() throws {
        let manager = PaneManager()
        let paneID = manager.activePaneID
        let tabs = [makeEditorTab("a.swift"), makeEditorTab("b.swift"), makeEditorTab("c.swift")]
        let tabManager = try #require(manager.tabManager(for: paneID))
        tabManager.tabs = tabs
        tabManager.activeTabID = tabs[0].id
        _ = manager.beginTabDrag(
            paneID: paneID,
            tabID: tabs[0].id,
            fileURL: tabs[0].url,
            contentType: .editor
        )

        let intent = try #require(manager.tabStripIntent(
            destinationPaneID: paneID,
            contentType: .editor,
            insertionIndex: 3
        ))
        #expect(manager.tabDragCoordinator.preview(intent))
        #expect(tabManager.tabs.map(\.id) == tabs.map(\.id))

        #expect(manager.tabDragCoordinator.commitPreview())
        #expect(tabManager.tabs.map(\.id) == [tabs[1].id, tabs[2].id, tabs[0].id])
        #expect(tabManager.activeTabID == tabs[0].id)
        #expect(tabManager.pendingFocusTabID == tabs[0].id)
        #expect(manager.activeDrag == nil)
        #expect(manager.tabDragCoordinator.previewIntent == nil)
    }

    @Test("Both adjacent gaps are accepted no-ops")
    func adjacentGapsAreNoOps() throws {
        for gap in [1, 2] {
            let manager = PaneManager()
            let paneID = manager.activePaneID
            let tabs = [makeEditorTab("a.swift"), makeEditorTab("b.swift"), makeEditorTab("c.swift")]
            let tabManager = try #require(manager.tabManager(for: paneID))
            tabManager.tabs = tabs
            _ = manager.beginTabDrag(
                paneID: paneID,
                tabID: tabs[1].id,
                fileURL: tabs[1].url,
                contentType: .editor
            )
            let intent = try #require(manager.tabStripIntent(
                destinationPaneID: paneID,
                contentType: .editor,
                insertionIndex: gap
            ))

            #expect(manager.tabDragCoordinator.preview(intent))
            #expect(manager.tabDragCoordinator.commitPreview())
            #expect(tabManager.tabs.map(\.id) == tabs.map(\.id))
            #expect(tabManager.pendingFocusTabID == tabs[1].id)
        }
    }

    @Test("Cross-pane editor inserts at first, middle, and last gaps")
    func editorCrossPaneExactGaps() throws {
        for insertionIndex in 0...2 {
            let setup = try makeEditorPanePair()
            let dragged = setup.source.tabs[0]
            let kept = setup.source.tabs[1]
            let originalTarget = setup.target.tabs
            _ = setup.manager.beginTabDrag(
                paneID: setup.sourcePaneID,
                tabID: dragged.id,
                fileURL: dragged.url,
                contentType: .editor
            )
            let intent = try #require(setup.manager.tabStripIntent(
                destinationPaneID: setup.targetPaneID,
                contentType: .editor,
                insertionIndex: insertionIndex
            ))

            #expect(setup.manager.tabDragCoordinator.preview(intent))
            #expect(setup.source.tabs.map(\.id) == [dragged.id, kept.id])
            #expect(setup.target.tabs.map(\.id) == originalTarget.map(\.id))
            #expect(setup.manager.tabDragCoordinator.commitPreview())

            var expected = originalTarget.map(\.id)
            expected.insert(dragged.id, at: insertionIndex)
            #expect(setup.target.tabs.map(\.id) == expected)
            #expect(setup.source.tabs.map(\.id) == [kept.id])
            #expect(setup.target.activeTabID == dragged.id)
            #expect(setup.target.pendingFocusTabID == dragged.id)
            #expect(setup.manager.activePaneID == setup.targetPaneID)
        }
    }

    @Test("Pinned and regular tabs cannot cross their boundary")
    func pinnedBoundaryRejectsInvalidGaps() throws {
        let manager = PaneManager()
        let paneID = manager.activePaneID
        let pinnedA = makeEditorTab("pinned-a.swift", pinned: true)
        let pinnedB = makeEditorTab("pinned-b.swift", pinned: true)
        let regularA = makeEditorTab("regular-a.swift")
        let regularB = makeEditorTab("regular-b.swift")
        let tabManager = try #require(manager.tabManager(for: paneID))
        tabManager.tabs = [pinnedA, pinnedB, regularA, regularB]

        _ = manager.beginTabDrag(
            paneID: paneID,
            tabID: pinnedA.id,
            fileURL: pinnedA.url,
            contentType: .editor
        )
        let pinnedIntent = try #require(manager.tabStripIntent(
            destinationPaneID: paneID,
            contentType: .editor,
            insertionIndex: 3
        ))
        #expect(!manager.tabDragCoordinator.preview(pinnedIntent))

        _ = manager.beginTabDrag(
            paneID: paneID,
            tabID: regularB.id,
            fileURL: regularB.url,
            contentType: .editor
        )
        let regularIntent = try #require(manager.tabStripIntent(
            destinationPaneID: paneID,
            contentType: .editor,
            insertionIndex: 1
        ))
        #expect(!manager.tabDragCoordinator.preview(regularIntent))
        #expect(tabManager.tabs.map(\.id) == [pinnedA.id, pinnedB.id, regularA.id, regularB.id])
    }

    @Test("Shared pinned boundary accepts either tab class")
    func pinnedBoundaryAcceptsBothClasses() throws {
        do {
            let setup = try makeEditorPanePair(
                sourceTabs: [
                    makeEditorTab("dragged-pinned.swift", pinned: true),
                    makeEditorTab("kept.swift")
                ],
                targetTabs: [
                    makeEditorTab("target-pinned.swift", pinned: true),
                    makeEditorTab("target.swift")
                ]
            )
            let dragged = setup.source.tabs[0]
            let targetPinned = setup.target.tabs[0]
            let targetRegular = setup.target.tabs[1]
            try previewAndCommitEditorInsert(setup: setup, dragged: dragged, insertionIndex: 1)
            #expect(setup.target.tabs.map(\.id) == [
                targetPinned.id, dragged.id, targetRegular.id
            ])
        }

        do {
            let setup = try makeEditorPanePair(
                sourceTabs: [
                    makeEditorTab("kept-pinned.swift", pinned: true),
                    makeEditorTab("dragged.swift")
                ],
                targetTabs: [
                    makeEditorTab("target-pinned.swift", pinned: true),
                    makeEditorTab("target.swift")
                ]
            )
            let dragged = setup.source.tabs[1]
            let targetPinned = setup.target.tabs[0]
            let targetRegular = setup.target.tabs[1]
            try previewAndCommitEditorInsert(setup: setup, dragged: dragged, insertionIndex: 1)
            #expect(setup.target.tabs.map(\.id) == [
                targetPinned.id, dragged.id, targetRegular.id
            ])
        }
    }

    @Test("A new drag invalidates an old intent with the same tab identity")
    func staleDragIDIsRejected() throws {
        let manager = PaneManager()
        let paneID = manager.activePaneID
        let tabs = [makeEditorTab("a.swift"), makeEditorTab("b.swift")]
        let tabManager = try #require(manager.tabManager(for: paneID))
        tabManager.tabs = tabs
        _ = manager.beginTabDrag(
            paneID: paneID,
            tabID: tabs[0].id,
            fileURL: tabs[0].url,
            contentType: .editor
        )
        let staleIntent = try #require(manager.tabStripIntent(
            destinationPaneID: paneID,
            contentType: .editor,
            insertionIndex: 2
        ))
        #expect(manager.tabDragCoordinator.preview(staleIntent))

        let newDrag = manager.beginTabDrag(
            paneID: paneID,
            tabID: tabs[0].id,
            fileURL: tabs[0].url,
            contentType: .editor
        )
        #expect(!manager.tabDragCoordinator.preview(staleIntent))
        #expect(!manager.tabDragCoordinator.commitPreview())
        #expect(manager.activeDrag?.dragID == newDrag.dragID)
        #expect(tabManager.tabs.map(\.id) == tabs.map(\.id))
    }

    @Test("Commit revalidates destination and never extracts on failure")
    func atomicCommitRevalidation() throws {
        let setup = try makeEditorPanePair()
        let dragged = setup.source.tabs[0]
        _ = setup.manager.beginTabDrag(
            paneID: setup.sourcePaneID,
            tabID: dragged.id,
            fileURL: dragged.url,
            contentType: .editor
        )
        let intent = try #require(setup.manager.tabStripIntent(
            destinationPaneID: setup.targetPaneID,
            contentType: .editor,
            insertionIndex: 0
        ))
        #expect(setup.manager.tabDragCoordinator.preview(intent))

        setup.target.tabs.insert(
            EditorTab(url: dragged.url, content: "duplicate", savedContent: "duplicate"),
            at: 0
        )
        let sourceBeforeCommit = setup.source.tabs.map(\.id)
        let targetBeforeCommit = setup.target.tabs.map(\.id)
        #expect(!setup.manager.tabDragCoordinator.commitPreview())
        #expect(setup.source.tabs.map(\.id) == sourceBeforeCommit)
        #expect(setup.target.tabs.map(\.id) == targetBeforeCommit)
        #expect(setup.manager.activeDrag?.tabID == dragged.id)
    }

    @Test("Terminal strips use the same preview and indexed commit path")
    func terminalPreviewAndIndexedCommit() throws {
        let manager = PaneManager()
        let sourcePaneID = manager.createTerminalPaneAtBottom(workingDirectory: nil)
        let source = try #require(manager.terminalState(for: sourcePaneID))
        let dragged = try #require(source.terminalTabs.first)
        let kept = source.addTab(workingDirectory: nil)
        let targetPaneID = try #require(manager.createTerminalPane(
            relativeTo: sourcePaneID,
            axis: .horizontal,
            workingDirectory: nil
        ))
        let target = try #require(manager.terminalState(for: targetPaneID))
        let originalTarget = try #require(target.terminalTabs.first)

        _ = manager.beginTabDrag(
            paneID: sourcePaneID,
            tabID: dragged.id,
            fileURL: nil,
            contentType: .terminal
        )
        let intent = try #require(manager.tabStripIntent(
            destinationPaneID: targetPaneID,
            contentType: .terminal,
            insertionIndex: 0
        ))
        #expect(manager.tabDragCoordinator.preview(intent))
        #expect(source.terminalTabs.map(\.id) == [dragged.id, kept.id])
        #expect(target.terminalTabs.map(\.id) == [originalTarget.id])

        #expect(manager.tabDragCoordinator.commitPreview())
        #expect(source.terminalTabs.map(\.id) == [kept.id])
        #expect(target.terminalTabs.map(\.id) == [dragged.id, originalTarget.id])
        #expect(target.activeTerminalID == dragged.id)
        #expect(target.pendingFocusTabID == dragged.id)
    }

    @Test("Cross-type center preview shows and commits the actual bottom split")
    func crossTypeCenterMatchesPreview() throws {
        let manager = PaneManager()
        let sourcePaneID = manager.activePaneID
        let source = try #require(manager.tabManager(for: sourcePaneID))
        let dragged = makeEditorTab("dragged.swift")
        let kept = makeEditorTab("kept.swift")
        source.tabs = [dragged, kept]
        let terminalPaneID = manager.createTerminalPaneAtBottom(workingDirectory: nil)
        let leafCountBefore = manager.root.leafCount

        _ = manager.beginTabDrag(
            paneID: sourcePaneID,
            tabID: dragged.id,
            fileURL: dragged.url,
            contentType: .editor
        )
        #expect(manager.previewPaneDrop(
            destinationPaneID: terminalPaneID,
            proposedZone: .center
        ) == .bottom)
        guard case .leafSplit(_, let previewTarget, let previewZone)? =
            manager.tabDragCoordinator.previewIntent else {
            Issue.record("Expected leaf split preview")
            return
        }
        #expect(previewTarget == terminalPaneID)
        #expect(previewZone == .bottom)
        #expect(manager.root.leafCount == leafCountBefore)
        #expect(source.tabs.map(\.id) == [dragged.id, kept.id])

        #expect(manager.tabDragCoordinator.commitPreview())
        #expect(manager.root.leafCount == leafCountBefore + 1)
        let destinationPaneID = manager.activePaneID
        let destination = try #require(manager.tabManager(for: destinationPaneID))
        #expect(destination.tabs.map(\.id) == [dragged.id])
        #expect(destination.pendingFocusTabID == dragged.id)
        #expect(source.tabs.map(\.id) == [kept.id])
    }

    @Test("Pane body excludes the tab strip routing band")
    func stripAndBodyRoutingDoNotOverlap() throws {
        let setup = try makeEditorPanePair()
        let dragged = setup.source.tabs[0]
        _ = setup.manager.beginTabDrag(
            paneID: setup.sourcePaneID,
            tabID: dragged.id,
            fileURL: dragged.url,
            contentType: .editor
        )
        let delegate = PaneSplitDropDelegate(
            paneID: setup.targetPaneID,
            paneManager: setup.manager,
            paneSize: CGSize(width: 400, height: 300),
            excludedTopInset: 30
        )

        #expect(delegate.updateDropZone(
            for: .paneTab,
            at: CGPoint(x: 200, y: 10)
        ) == nil)
        #expect(setup.manager.tabDragCoordinator.previewIntent == nil)
        #expect(delegate.updateDropZone(
            for: .paneTab,
            at: CGPoint(x: 200, y: 150)
        ) == .center)
        #expect(setup.source.tabs.count == 2)
        #expect(setup.target.tabs.count == 2)
    }

    @Test("Empty editor pane exposes and commits its single strip gap")
    func emptyEditorPaneInsertionGap() throws {
        let manager = PaneManager()
        let sourcePaneID = manager.activePaneID
        let source = try #require(manager.tabManager(for: sourcePaneID))
        let dragged = makeEditorTab("dragged.swift")
        let kept = makeEditorTab("kept.swift")
        source.tabs = [dragged, kept]
        source.activeTabID = dragged.id

        let targetPaneID = try #require(manager.splitPane(sourcePaneID, axis: .horizontal))
        let target = try #require(manager.tabManager(for: targetPaneID))
        #expect(target.tabs.isEmpty)
        #expect(PaneLeafTabStripComposition.rendersStrip(
            content: .editor,
            editorTabCount: target.tabs.count,
            terminalTabCount: nil
        ))
        #expect(PaneLeafTabStripComposition.excludedTopInset(
            content: .editor,
            editorTabCount: target.tabs.count,
            terminalTabCount: nil,
            tabBarHeight: 30
        ) == 30)

        let insertionIndex = try #require(TabStripInsertionGeometry.insertionIndex(
            atX: 200,
            orderedTabIDs: [],
            frames: [:]
        ))
        #expect(insertionIndex == 0)
        _ = manager.beginTabDrag(
            paneID: sourcePaneID,
            tabID: dragged.id,
            fileURL: dragged.url,
            contentType: .editor
        )
        let bodyDelegate = PaneSplitDropDelegate(
            paneID: targetPaneID,
            paneManager: manager,
            paneSize: CGSize(width: 400, height: 300),
            excludedTopInset: 30
        )
        #expect(bodyDelegate.updateDropZone(
            for: .paneTab,
            at: CGPoint(x: 200, y: 10)
        ) == nil)
        let stripDelegate = TabStripDropDelegate(
            paneID: targetPaneID,
            contentType: .editor,
            orderedTabIDs: [],
            frames: [:],
            paneManager: manager
        )

        #expect(stripDelegate.preview(atX: 200))
        #expect(manager.tabDragCoordinator.previewIntent?.insertionIndex == insertionIndex)
        #expect(target.tabs.isEmpty)
        #expect(manager.tabDragCoordinator.commitPreview())
        #expect(target.tabs.map(\.id) == [dragged.id])
        #expect(source.tabs.map(\.id) == [kept.id])
    }

    @Test("Empty terminal pane exposes and commits its single strip gap")
    func emptyTerminalPaneInsertionGap() throws {
        let manager = PaneManager()
        let sourcePaneID = manager.createTerminalPaneAtBottom(workingDirectory: nil)
        let source = try #require(manager.terminalState(for: sourcePaneID))
        let dragged = try #require(source.terminalTabs.first)
        let kept = source.addTab(workingDirectory: nil)
        let targetPaneID = try #require(manager.createTerminalPane(
            relativeTo: sourcePaneID,
            axis: .horizontal,
            workingDirectory: nil
        ))
        let target = try #require(manager.terminalState(for: targetPaneID))
        target.terminalTabs.removeAll()
        target.activeTerminalID = nil

        #expect(PaneLeafTabStripComposition.rendersStrip(
            content: .terminal,
            editorTabCount: nil,
            terminalTabCount: target.terminalTabs.count
        ))
        #expect(PaneLeafTabStripComposition.excludedTopInset(
            content: .terminal,
            editorTabCount: nil,
            terminalTabCount: target.terminalTabs.count,
            tabBarHeight: 30
        ) == 30)

        _ = manager.beginTabDrag(
            paneID: sourcePaneID,
            tabID: dragged.id,
            fileURL: nil,
            contentType: .terminal
        )
        let bodyDelegate = PaneSplitDropDelegate(
            paneID: targetPaneID,
            paneManager: manager,
            paneSize: CGSize(width: 400, height: 300),
            excludedTopInset: 30
        )
        #expect(bodyDelegate.updateDropZone(
            for: .paneTab,
            at: CGPoint(x: 200, y: 10)
        ) == nil)
        let stripDelegate = TabStripDropDelegate(
            paneID: targetPaneID,
            contentType: .terminal,
            orderedTabIDs: [],
            frames: [:],
            paneManager: manager
        )

        #expect(stripDelegate.preview(atX: 200))
        #expect(manager.tabDragCoordinator.previewIntent?.insertionIndex == 0)
        #expect(target.terminalTabs.isEmpty)
        #expect(manager.tabDragCoordinator.commitPreview())
        #expect(target.terminalTabs.map(\.id) == [dragged.id])
        #expect(source.terminalTabs.map(\.id) == [kept.id])
    }

    @Test("Missing backing state does not reserve a dead strip band")
    func missingBackingStateHasNoExcludedInset() {
        #expect(!PaneLeafTabStripComposition.rendersStrip(
            content: .editor,
            editorTabCount: nil,
            terminalTabCount: nil
        ))
        #expect(PaneLeafTabStripComposition.excludedTopInset(
            content: .editor,
            editorTabCount: nil,
            terminalTabCount: nil,
            tabBarHeight: 30
        ) == 0)
    }

    private struct EditorPanePair {
        let manager: PaneManager
        let sourcePaneID: PaneID
        let targetPaneID: PaneID
        let source: TabManager
        let target: TabManager
    }

    private func makeEditorPanePair(
        sourceTabs: [EditorTab]? = nil,
        targetTabs: [EditorTab]? = nil
    ) throws -> EditorPanePair {
        let resolvedSourceTabs = sourceTabs ?? [
            makeEditorTab("source.swift"),
            makeEditorTab("kept.swift")
        ]
        let resolvedTargetTabs = targetTabs ?? [
            makeEditorTab("target-a.swift"),
            makeEditorTab("target-b.swift")
        ]
        let manager = PaneManager()
        let sourcePaneID = manager.activePaneID
        let source = try #require(manager.tabManager(for: sourcePaneID))
        source.tabs = resolvedSourceTabs
        source.activeTabID = resolvedSourceTabs.first?.id
        let targetPaneID = try #require(manager.splitPane(sourcePaneID, axis: .horizontal))
        let target = try #require(manager.tabManager(for: targetPaneID))
        target.tabs = resolvedTargetTabs
        target.activeTabID = resolvedTargetTabs.first?.id
        return EditorPanePair(
            manager: manager,
            sourcePaneID: sourcePaneID,
            targetPaneID: targetPaneID,
            source: source,
            target: target
        )
    }

    private func previewAndCommitEditorInsert(
        setup: EditorPanePair,
        dragged: EditorTab,
        insertionIndex: Int
    ) throws {
        _ = setup.manager.beginTabDrag(
            paneID: setup.sourcePaneID,
            tabID: dragged.id,
            fileURL: dragged.url,
            contentType: .editor
        )
        let intent = try #require(setup.manager.tabStripIntent(
            destinationPaneID: setup.targetPaneID,
            contentType: .editor,
            insertionIndex: insertionIndex
        ))
        #expect(setup.manager.tabDragCoordinator.preview(intent))
        #expect(setup.manager.tabDragCoordinator.commitPreview())
    }

    private func makeEditorTab(_ name: String, pinned: Bool = false) -> EditorTab {
        var tab = EditorTab(
            url: URL(fileURLWithPath: "/tmp/\(UUID().uuidString)-\(name)"),
            content: name,
            savedContent: name
        )
        tab.isPinned = pinned
        return tab
    }
}
