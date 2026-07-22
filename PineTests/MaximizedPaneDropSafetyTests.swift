//
//  MaximizedPaneDropSafetyTests.swift
//  PineTests
//
//  Regression coverage for structural drop routing against the temporary
//  maximized pane tree (issue #1169).
//

import CoreGraphics
import Foundation
import SwiftUI
import Testing

@testable import Pine

@Suite("Maximized Pane Drop Safety")
@MainActor
struct MaximizedPaneDropSafetyTests {
    private let paneSize = CGSize(width: 800, height: 600)

    @Test("Pane tab edge drop is hidden and rejected while maximized")
    func paneTabEdgeDropIsRejected() throws {
        let manager = PaneManager()
        let paneID = manager.activePaneID
        let tabManager = try #require(manager.tabManager(for: paneID))
        let tab = EditorTab(
            url: URL(fileURLWithPath: "/tmp/maximized.swift"),
            content: "let value = 1",
            savedContent: "let value = 1"
        )
        tabManager.tabs = [tab]
        tabManager.activeTabID = tab.id
        _ = try #require(manager.splitPane(paneID, axis: .horizontal))
        let savedLeafIDs = manager.persistableRoot.leafIDs

        manager.maximize(paneID: paneID)
        manager.activeDrag = TabDragInfo(
            paneID: paneID.id,
            tabID: tab.id,
            fileURL: tab.url,
            contentType: .editor
        )
        let delegate = paneDelegate(for: paneID, manager: manager)

        let hoverZone = delegate.updateDropZone(
            for: .paneTab,
            at: CGPoint(x: paneSize.width - 1, y: paneSize.height / 2)
        )

        #expect(hoverZone == nil)
        #expect(manager.dropZones[paneID] == nil)
        #expect(!delegate.performPaneTabDrop(zone: .right))
        #expect(manager.isMaximized)
        #expect(manager.root.leafIDs == [paneID])
        #expect(manager.persistableRoot.leafIDs == savedLeafIDs)
        #expect(manager.activeDrag?.tabID == tab.id)
        #expect(tabManager.tabs.map(\.id) == [tab.id])
    }

    @Test("All pane tab zones defer to the local tab strip while maximized")
    func paneTabCenterDropIsRejected() throws {
        let manager = PaneManager()
        let paneID = manager.activePaneID
        _ = try #require(manager.splitPane(paneID, axis: .vertical))
        manager.maximize(paneID: paneID)

        let delegate = paneDelegate(for: paneID, manager: manager)

        #expect(delegate.routedDropZone(for: .paneTab, proposedZone: .center) == nil)
        #expect(delegate.routedDropZone(for: .paneTab, proposedZone: .left) == nil)
    }

    @Test("Sidebar and Finder files are forced to non-structural center drop")
    func fileDropsAreForcedToCenter() throws {
        let manager = PaneManager()
        let paneID = manager.activePaneID
        _ = try #require(manager.splitPane(paneID, axis: .horizontal))
        manager.maximize(paneID: paneID)
        let delegate = paneDelegate(for: paneID, manager: manager)

        #expect(delegate.routedDropZone(for: .sidebarFile, proposedZone: .right) == .center)
        #expect(delegate.routedDropZone(for: .fileURL, proposedZone: .bottom) == .center)
        #expect(delegate.updateDropZone(
            for: .sidebarFile,
            at: CGPoint(x: paneSize.width - 1, y: paneSize.height / 2)
        ) == .center)
        #expect(manager.dropZones[paneID] == .center)
        #expect(manager.root.leafIDs == [paneID])
    }

    @Test("Root drop is hidden and rejected while maximized")
    func rootDropIsRejected() throws {
        let manager = PaneManager()
        let terminalPaneID = manager.createTerminalPaneAtBottom(workingDirectory: nil)
        let terminalState = try #require(manager.terminalState(for: terminalPaneID))
        let tabID = try #require(terminalState.terminalTabs.first?.id)
        let savedLeafIDs = manager.persistableRoot.leafIDs

        manager.maximize(paneID: terminalPaneID)
        manager.activeDrag = TabDragInfo(
            paneID: terminalPaneID.id,
            tabID: tabID,
            contentType: .terminal
        )
        let delegate = RootPaneSplitDropDelegate(
            paneManager: manager,
            containerSize: paneSize
        )

        #expect(!delegate.canRouteStructuralDrop)
        #expect(delegate.updateRootDropZone(at: CGPoint(x: 1, y: 300)) == nil)
        #expect(manager.rootDropZone == nil)

        // A stale zone must not bypass the perform-time guard.
        manager.rootDropZone = .left
        #expect(!delegate.performRootPaneTabDrop(zone: manager.rootDropZone))
        #expect(manager.rootDropZone == nil)
        #expect(manager.isMaximized)
        #expect(manager.root.leafIDs == [terminalPaneID])
        #expect(manager.persistableRoot.leafIDs == savedLeafIDs)
        #expect(manager.activeDrag?.tabID == tabID)
        #expect(terminalState.terminalTabs.map(\.id) == [tabID])
    }

    @Test("Editor tabs still reorder locally while their pane is maximized")
    func editorTabsStillReorderLocally() throws {
        let manager = PaneManager()
        let paneID = manager.activePaneID
        let tabManager = try #require(manager.tabManager(for: paneID))
        let first = EditorTab(
            url: URL(fileURLWithPath: "/tmp/first.swift"),
            content: "first",
            savedContent: "first"
        )
        let second = EditorTab(
            url: URL(fileURLWithPath: "/tmp/second.swift"),
            content: "second",
            savedContent: "second"
        )
        tabManager.tabs = [first, second]
        tabManager.activeTabID = first.id
        _ = try #require(manager.splitPane(paneID, axis: .horizontal))
        manager.maximize(paneID: paneID)
        manager.activeDrag = TabDragInfo(
            paneID: paneID.id,
            tabID: first.id,
            fileURL: first.url,
            contentType: .editor
        )
        let delegate = TabDropDelegate(
            tabManager: tabManager,
            paneManager: manager,
            targetPaneID: paneID,
            targetTabID: second.id,
            hoverTargetTabID: .constant(nil)
        )

        let decision = delegate.routingDecision()
        #expect(decision == .localReorder(draggedTabID: first.id))
        #expect(delegate.handleDropEntered(decision: decision))
        #expect(delegate.finishDrop(decision: decision))
        #expect(tabManager.tabs.map(\.id) == [second.id, first.id])
        #expect(manager.activeDrag == nil)
        #expect(manager.isMaximized)
    }

    @Test("Terminal tabs still reorder locally while their pane is maximized")
    func terminalTabsStillReorderLocally() throws {
        let manager = PaneManager()
        let terminalPaneID = manager.createTerminalPaneAtBottom(workingDirectory: nil)
        let terminalState = try #require(manager.terminalState(for: terminalPaneID))
        terminalState.addTab(workingDirectory: nil)
        let firstID = terminalState.terminalTabs[0].id
        let secondID = terminalState.terminalTabs[1].id
        manager.maximize(paneID: terminalPaneID)
        manager.activeDrag = TabDragInfo(
            paneID: terminalPaneID.id,
            tabID: firstID,
            contentType: .terminal
        )
        let delegate = TerminalTabDropDelegate(
            terminalState: terminalState,
            targetTabID: secondID,
            targetPaneID: terminalPaneID,
            paneManager: manager
        )

        let decision = delegate.routingDecision()
        #expect(decision == .localReorder(draggedTabID: firstID))
        #expect(delegate.handleDropEntered(decision: decision))
        #expect(delegate.finishDrop(decision: decision))
        #expect(terminalState.terminalTabs.map(\.id) == [secondID, firstID])
        #expect(manager.activeDrag == nil)
        #expect(manager.isMaximized)
    }

    private func paneDelegate(
        for paneID: PaneID,
        manager: PaneManager
    ) -> PaneSplitDropDelegate {
        PaneSplitDropDelegate(
            paneID: paneID,
            paneManager: manager,
            paneSize: paneSize
        )
    }
}
