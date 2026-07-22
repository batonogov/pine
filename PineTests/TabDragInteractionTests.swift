//
//  TabDragInteractionTests.swift
//  PineTests
//
//  Deterministic coverage for tab hit geometry and nested drop routing.
//

import CoreGraphics
import Foundation
import SwiftUI
import Testing

@testable import Pine

@Suite("Tab Slot Hit Testing")
struct TabSlotHitTestingTests {
    private let slotHeight: CGFloat = 30
    private let epsilon: CGFloat = 0.001
    private let glyphFrame = CGRect(x: 58, y: 8, width: 14, height: 14)

    @Test("Close target expands the visible glyph by the configured hit slop")
    func closeTargetUsesConfiguredGeometry() {
        let rect = TabSlotHitTesting.closeRect(for: glyphFrame)
        let expectedHitSize = TabSlotHitTesting.closeGlyphSize
            + (TabSlotHitTesting.closeHitSlop * 2)

        #expect(TabSlotHitTesting.closeGlyphSize == 14)
        #expect(TabSlotHitTesting.closeHitSlop == 4)
        #expect(rect.minX == glyphFrame.minX - TabSlotHitTesting.closeHitSlop)
        #expect(rect.midX == glyphFrame.midX)
        #expect(rect.midY == glyphFrame.midY)
        #expect(rect.width == expectedHitSize)
        #expect(rect.height == expectedHitSize)
    }

    @Test("Close target follows the measured glyph anywhere in a flexible tab")
    func closeTargetFollowsMeasuredGlyph() {
        let frames = [
            CGRect(x: 10, y: 8, width: 14, height: 14),
            CGRect(x: 58, y: 8, width: 14, height: 14),
            CGRect(x: 132, y: 8, width: 14, height: 14)
        ]

        for frame in frames {
            let rect = TabSlotHitTesting.closeRect(for: frame)
            #expect(rect.midX == frame.midX)
            #expect(rect.midY == frame.midY)
        }
    }

    @Test("Points immediately inside every close-target boundary close the tab")
    func insideCloseTargetBoundariesClose() {
        let rect = TabSlotHitTesting.closeRect(for: glyphFrame)
        let points = [
            CGPoint(x: rect.minX, y: rect.midY),
            CGPoint(x: rect.maxX - epsilon, y: rect.midY),
            CGPoint(x: rect.midX, y: rect.minY),
            CGPoint(x: rect.midX, y: rect.maxY - epsilon),
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX - epsilon, y: rect.maxY - epsilon)
        ]

        for point in points {
            #expect(TabSlotHitTesting.target(
                at: point,
                canClose: true,
                closeGlyphFrame: glyphFrame
            ) == .close)
        }
    }

    @Test("Points immediately outside every close-target boundary select the tab")
    func outsideCloseTargetBoundariesSelect() {
        let rect = TabSlotHitTesting.closeRect(for: glyphFrame)
        let points = [
            CGPoint(x: rect.minX - epsilon, y: rect.midY),
            CGPoint(x: rect.maxX, y: rect.midY),
            CGPoint(x: rect.midX, y: rect.minY - epsilon),
            CGPoint(x: rect.midX, y: rect.maxY)
        ]

        for point in points {
            #expect(TabSlotHitTesting.target(
                at: point,
                canClose: true,
                closeGlyphFrame: glyphFrame
            ) == .select)
        }
    }

    @Test("Upper, lower, and trailing slot padding select the tab")
    func slotPaddingSelects() {
        let closeRect = TabSlotHitTesting.closeRect(for: glyphFrame)
        let points = [
            CGPoint(x: closeRect.midX, y: epsilon),
            CGPoint(x: closeRect.midX, y: slotHeight - epsilon),
            CGPoint(x: closeRect.maxX + 20, y: slotHeight / 2)
        ]

        for point in points {
            #expect(TabSlotHitTesting.target(
                at: point,
                canClose: true,
                closeGlyphFrame: glyphFrame
            ) == .select)
        }
    }

    @Test("Tabs that cannot close always select, including over the close target")
    func cannotCloseAlwaysSelects() {
        let rect = TabSlotHitTesting.closeRect(for: glyphFrame)
        let points = [
            CGPoint(x: rect.midX, y: rect.midY),
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX - epsilon, y: rect.maxY - epsilon)
        ]

        for point in points {
            #expect(TabSlotHitTesting.target(
                at: point,
                canClose: false,
                closeGlyphFrame: glyphFrame
            ) == .select)
        }
    }

    @Test("Missing glyph measurement cannot accidentally close a tab")
    func missingGlyphMeasurementSelects() {
        #expect(TabSlotHitTesting.target(
            at: CGPoint(x: 10, y: slotHeight / 2),
            canClose: true,
            closeGlyphFrame: .null
        ) == .select)
    }
}

@Suite("Tab Item Drop Routing")
struct TabItemDropRouterTests {
    @Test("Missing shared drag state is rejected")
    func missingDragIsRejected() {
        let decision = TabItemDropRouter.decide(
            drag: nil,
            targetPaneID: PaneID(),
            targetContent: .editor
        )

        #expect(decision == .reject)
    }

    @Test("Editor drag in its source editor pane reorders locally")
    func localEditorDragReorders() {
        let paneID = PaneID()
        let tabID = UUID()
        let drag = makeDrag(paneID: paneID, tabID: tabID, content: .editor)

        let decision = TabItemDropRouter.decide(
            drag: drag,
            targetPaneID: paneID,
            targetContent: .editor
        )

        #expect(decision == .localReorder(draggedTabID: tabID))
    }

    @Test("Terminal drag in its source terminal pane reorders locally")
    func localTerminalDragReorders() {
        let paneID = PaneID()
        let tabID = UUID()
        let drag = makeDrag(paneID: paneID, tabID: tabID, content: .terminal)

        let decision = TabItemDropRouter.decide(
            drag: drag,
            targetPaneID: paneID,
            targetContent: .terminal
        )

        #expect(decision == .localReorder(draggedTabID: tabID))
    }

    @Test("Editor drag targeting another editor pane defers to the pane delegate")
    func crossPaneEditorDragDefers() {
        let drag = makeDrag(paneID: PaneID(), content: .editor)

        let decision = TabItemDropRouter.decide(
            drag: drag,
            targetPaneID: PaneID(),
            targetContent: .editor
        )

        #expect(decision == .deferToPane)
    }

    @Test("Terminal drag targeting another terminal pane defers to the pane delegate")
    func crossPaneTerminalDragDefers() {
        let drag = makeDrag(paneID: PaneID(), content: .terminal)

        let decision = TabItemDropRouter.decide(
            drag: drag,
            targetPaneID: PaneID(),
            targetContent: .terminal
        )

        #expect(decision == .deferToPane)
    }

    @Test("Editor drag targeting a terminal pane defers to cross-type pane handling")
    func crossPaneEditorToTerminalDefers() {
        let drag = makeDrag(paneID: PaneID(), content: .editor)

        let decision = TabItemDropRouter.decide(
            drag: drag,
            targetPaneID: PaneID(),
            targetContent: .terminal
        )

        #expect(decision == .deferToPane)
    }

    @Test("Terminal drag targeting an editor pane defers to cross-type pane handling")
    func crossPaneTerminalToEditorDefers() {
        let drag = makeDrag(paneID: PaneID(), content: .terminal)

        let decision = TabItemDropRouter.decide(
            drag: drag,
            targetPaneID: PaneID(),
            targetContent: .editor
        )

        #expect(decision == .deferToPane)
    }

    @Test("Editor payload claiming its source is a terminal pane is rejected")
    func samePaneEditorToTerminalIsRejected() {
        let paneID = PaneID()
        let drag = makeDrag(paneID: paneID, content: .editor)

        let decision = TabItemDropRouter.decide(
            drag: drag,
            targetPaneID: paneID,
            targetContent: .terminal
        )

        #expect(decision == .reject)
    }

    @Test("Terminal payload claiming its source is an editor pane is rejected")
    func samePaneTerminalToEditorIsRejected() {
        let paneID = PaneID()
        let drag = makeDrag(paneID: paneID, content: .terminal)

        let decision = TabItemDropRouter.decide(
            drag: drag,
            targetPaneID: paneID,
            targetContent: .editor
        )

        #expect(decision == .reject)
    }

    private func makeDrag(
        paneID: PaneID,
        tabID: UUID = UUID(),
        content: PaneContent
    ) -> TabDragInfo {
        TabDragInfo(
            paneID: paneID.id,
            tabID: tabID,
            fileURL: content == .editor ? URL(fileURLWithPath: "/tmp/test.swift") : nil,
            contentType: content
        )
    }
}

@Suite("Editor Tab Drop Delegate Routing")
@MainActor
struct EditorTabDropDelegateRoutingTests {
    @Test("Local editor drop reorders, consumes payload, and reports completion")
    func localDropCompletes() {
        let paneManager = PaneManager()
        let paneID = paneManager.activePaneID
        guard let tabManager = paneManager.tabManager(for: paneID) else {
            Issue.record("Missing initial editor tab manager")
            return
        }
        let first = EditorTab(
            url: URL(fileURLWithPath: "/tmp/first.swift"),
            content: "",
            savedContent: ""
        )
        let second = EditorTab(
            url: URL(fileURLWithPath: "/tmp/second.swift"),
            content: "",
            savedContent: ""
        )
        tabManager.tabs = [first, second]
        paneManager.activeDrag = TabDragInfo(
            paneID: paneID.id,
            tabID: first.id,
            fileURL: first.url
        )
        var completionCount = 0
        let delegate = TabDropDelegate(
            tabManager: tabManager,
            paneManager: paneManager,
            targetPaneID: paneID,
            targetTabID: second.id,
            hoverTargetTabID: .constant(nil),
            onReorder: { completionCount += 1 }
        )

        let decision = delegate.routingDecision()
        #expect(decision == .localReorder(draggedTabID: first.id))
        #expect(delegate.handleDropEntered(decision: decision))
        #expect(tabManager.tabs.map(\.id) == [second.id, first.id])
        #expect(delegate.finishDrop(decision: decision))
        #expect(paneManager.activeDrag == nil)
        #expect(completionCount == 1)
    }

    @Test("Cross-pane editor drop leaves payload and order for the pane delegate")
    func crossPaneDropDefers() {
        let paneManager = PaneManager()
        let targetPaneID = paneManager.activePaneID
        guard let tabManager = paneManager.tabManager(for: targetPaneID) else {
            Issue.record("Missing initial editor tab manager")
            return
        }
        let tab = EditorTab(
            url: URL(fileURLWithPath: "/tmp/target.swift"),
            content: "",
            savedContent: ""
        )
        tabManager.tabs = [tab]
        let drag = TabDragInfo(
            paneID: PaneID().id,
            tabID: UUID(),
            fileURL: URL(fileURLWithPath: "/tmp/source.swift")
        )
        paneManager.activeDrag = drag
        let delegate = TabDropDelegate(
            tabManager: tabManager,
            paneManager: paneManager,
            targetPaneID: targetPaneID,
            targetTabID: tab.id,
            hoverTargetTabID: .constant(nil)
        )

        let decision = delegate.routingDecision()
        #expect(decision == .deferToPane)
        #expect(!delegate.handleDropEntered(decision: decision))
        #expect(!delegate.finishDrop(decision: decision))
        #expect(tabManager.tabs.map(\.id) == [tab.id])
        #expect(paneManager.activeDrag?.tabID == drag.tabID)
    }
}

@Suite("Terminal Tab Drop Delegate Routing")
@MainActor
struct TerminalTabDropDelegateRoutingTests {
    @Test("Local terminal drop reorders and consumes the shared payload")
    func localDropCompletes() {
        let paneManager = PaneManager()
        let paneID = PaneID()
        let state = TerminalPaneState()
        let first = TerminalTab(name: "Terminal 1")
        let second = TerminalTab(name: "Terminal 2")
        state.terminalTabs = [first, second]
        paneManager.activeDrag = TabDragInfo(
            paneID: paneID.id,
            tabID: first.id,
            contentType: .terminal
        )
        let delegate = TerminalTabDropDelegate(
            terminalState: state,
            targetTabID: second.id,
            targetPaneID: paneID,
            paneManager: paneManager
        )

        let decision = delegate.routingDecision()
        #expect(decision == .localReorder(draggedTabID: first.id))
        #expect(delegate.handleDropEntered(decision: decision))
        #expect(state.terminalTabs.map(\.id) == [second.id, first.id])
        #expect(delegate.finishDrop(decision: decision))
        #expect(paneManager.activeDrag == nil)
    }

    @Test("Cross-pane terminal drop leaves payload and order for the pane delegate")
    func crossPaneDropDefers() {
        let paneManager = PaneManager()
        let targetPaneID = PaneID()
        let state = TerminalPaneState()
        let tab = TerminalTab(name: "Terminal 1")
        state.terminalTabs = [tab]
        let drag = TabDragInfo(
            paneID: PaneID().id,
            tabID: UUID(),
            contentType: .terminal
        )
        paneManager.activeDrag = drag
        let delegate = TerminalTabDropDelegate(
            terminalState: state,
            targetTabID: tab.id,
            targetPaneID: targetPaneID,
            paneManager: paneManager
        )

        let decision = delegate.routingDecision()
        #expect(decision == .deferToPane)
        #expect(!delegate.handleDropEntered(decision: decision))
        #expect(!delegate.finishDrop(decision: decision))
        #expect(state.terminalTabs.map(\.id) == [tab.id])
        #expect(paneManager.activeDrag?.tabID == drag.tabID)
    }
}

@Suite("Nested Tab-to-Pane Drop Integration")
@MainActor
struct NestedTabToPaneDropIntegrationTests {
    @Test("Deferred editor item drop is completed by the target pane")
    func deferredEditorDropMovesThroughPaneDelegate() throws {
        let paneManager = PaneManager()
        let sourcePaneID = paneManager.activePaneID
        let sourceTabManager = try #require(paneManager.tabManager(for: sourcePaneID))
        let sourceTab = EditorTab(
            url: URL(fileURLWithPath: "/tmp/source.swift"),
            content: "source",
            savedContent: "source"
        )
        sourceTabManager.tabs = [sourceTab]
        sourceTabManager.activeTabID = sourceTab.id

        let targetPaneID = try #require(
            paneManager.splitPane(sourcePaneID, axis: .horizontal)
        )
        let targetTabManager = try #require(paneManager.tabManager(for: targetPaneID))
        let targetTab = EditorTab(
            url: URL(fileURLWithPath: "/tmp/target.swift"),
            content: "target",
            savedContent: "target"
        )
        targetTabManager.tabs = [targetTab]
        targetTabManager.activeTabID = targetTab.id

        let drag = TabDragInfo(
            paneID: sourcePaneID.id,
            tabID: sourceTab.id,
            fileURL: sourceTab.url,
            contentType: .editor
        )
        paneManager.activeDrag = drag
        let itemDelegate = TabDropDelegate(
            tabManager: targetTabManager,
            paneManager: paneManager,
            targetPaneID: targetPaneID,
            targetTabID: targetTab.id,
            hoverTargetTabID: .constant(nil)
        )

        let decision = itemDelegate.routingDecision()
        #expect(decision == .deferToPane)
        #expect(!itemDelegate.handleDropEntered(decision: decision))
        #expect(!itemDelegate.finishDrop(decision: decision))
        #expect(paneManager.activeDrag?.paneID == drag.paneID)
        #expect(paneManager.activeDrag?.tabID == drag.tabID)
        #expect(paneManager.activeDrag?.fileURL == drag.fileURL)
        #expect(paneManager.activeDrag?.contentType == drag.contentType)
        #expect(targetTabManager.tabs.map(\.id) == [targetTab.id])
        #expect(sourceTabManager.tabs.map(\.id) == [sourceTab.id])

        let paneDelegate = PaneSplitDropDelegate(
            paneID: targetPaneID,
            paneManager: paneManager,
            paneSize: CGSize(width: 400, height: 300)
        )

        #expect(paneDelegate.performPaneTabDrop(zone: .center))
        #expect(paneManager.activeDrag == nil)
        #expect(targetTabManager.tabs.contains { $0.id == targetTab.id })
        #expect(targetTabManager.tabs.contains { $0.url == sourceTab.url })
        #expect(targetTabManager.tabs.count == 2)
        #expect(paneManager.tabManager(for: sourcePaneID) == nil)
        #expect(paneManager.root.content(for: sourcePaneID) == nil)
        #expect(paneManager.root.content(for: targetPaneID) == .editor)
    }

    @Test("Deferred terminal item drop is completed by the target pane")
    func deferredTerminalDropMovesThroughPaneDelegate() throws {
        let paneManager = PaneManager()
        let sourcePaneID = paneManager.createTerminalPaneAtBottom(workingDirectory: nil)
        let sourceState = try #require(paneManager.terminalState(for: sourcePaneID))
        let sourceTab = try #require(sourceState.terminalTabs.first)

        let targetPaneID = try #require(paneManager.createTerminalPane(
            relativeTo: sourcePaneID,
            axis: .horizontal,
            workingDirectory: nil
        ))
        let targetState = try #require(paneManager.terminalState(for: targetPaneID))
        let targetTab = try #require(targetState.terminalTabs.first)

        let drag = TabDragInfo(
            paneID: sourcePaneID.id,
            tabID: sourceTab.id,
            contentType: .terminal
        )
        paneManager.activeDrag = drag
        let itemDelegate = TerminalTabDropDelegate(
            terminalState: targetState,
            targetTabID: targetTab.id,
            targetPaneID: targetPaneID,
            paneManager: paneManager
        )

        let decision = itemDelegate.routingDecision()
        #expect(decision == .deferToPane)
        #expect(!itemDelegate.handleDropEntered(decision: decision))
        #expect(!itemDelegate.finishDrop(decision: decision))
        #expect(paneManager.activeDrag?.paneID == drag.paneID)
        #expect(paneManager.activeDrag?.tabID == drag.tabID)
        #expect(paneManager.activeDrag?.fileURL == drag.fileURL)
        #expect(paneManager.activeDrag?.contentType == drag.contentType)
        #expect(targetState.terminalTabs.map(\.id) == [targetTab.id])
        #expect(sourceState.terminalTabs.map(\.id) == [sourceTab.id])

        let paneDelegate = PaneSplitDropDelegate(
            paneID: targetPaneID,
            paneManager: paneManager,
            paneSize: CGSize(width: 400, height: 300)
        )

        #expect(paneDelegate.performPaneTabDrop(zone: .center))
        #expect(paneManager.activeDrag == nil)
        #expect(targetState.terminalTabs.map(\.id).contains(targetTab.id))
        #expect(targetState.terminalTabs.map(\.id).contains(sourceTab.id))
        #expect(targetState.terminalTabs.count == 2)
        #expect(paneManager.terminalState(for: sourcePaneID) == nil)
        #expect(paneManager.root.content(for: sourcePaneID) == nil)
        #expect(paneManager.root.content(for: targetPaneID) == .terminal)
    }
}
