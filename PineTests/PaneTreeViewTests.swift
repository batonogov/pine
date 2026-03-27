//
//  PaneTreeViewTests.swift
//  PineTests
//
//  Created by Pine Team on 27.03.2026.
//

import Foundation
import Testing
@testable import Pine

// MARK: - PaneSplitView Size Calculation Tests

@Suite("PaneSplitView size calculations")
struct PaneSplitViewSizeTests {
    /// Computes the first and second child sizes the same way PaneSplitView does.
    private func childSizes(totalSize: CGFloat, ratio: CGFloat) -> (first: CGFloat, second: CGFloat) {
        let divider = PaneSplitView.dividerThickness
        let firstSize = max(0, totalSize * ratio - divider / 2)
        let secondSize = max(0, totalSize * (1 - ratio) - divider / 2)
        return (firstSize, secondSize)
    }

    @Test("50/50 split divides space equally")
    func equalSplit() {
        let (first, second) = childSizes(totalSize: 1000, ratio: 0.5)
        #expect(abs(first - second) < 1)
        #expect(first + second + PaneSplitView.dividerThickness <= 1000)
    }

    @Test("70/30 split gives first child 70% of space")
    func unequalSplit70_30() {
        let (first, second) = childSizes(totalSize: 1000, ratio: 0.7)
        #expect(first > second)
        // first should be approximately 70% minus half divider
        let expectedFirst = 1000 * 0.7 - PaneSplitView.dividerThickness / 2
        #expect(abs(first - expectedFirst) < 0.01)
    }

    @Test("Extreme ratio 0.1 still produces positive sizes")
    func minimumRatio() {
        let (first, second) = childSizes(totalSize: 500, ratio: 0.1)
        #expect(first >= 0)
        #expect(second >= 0)
        #expect(second > first)
    }

    @Test("Extreme ratio 0.9 still produces positive sizes")
    func maximumRatio() {
        let (first, second) = childSizes(totalSize: 500, ratio: 0.9)
        #expect(first >= 0)
        #expect(second >= 0)
        #expect(first > second)
    }

    @Test("Very small total size doesn't produce negative child sizes")
    func tinyTotalSize() {
        let (first, second) = childSizes(totalSize: 2, ratio: 0.5)
        #expect(first >= 0)
        #expect(second >= 0)
    }

    @Test("Zero total size produces zero child sizes")
    func zeroTotalSize() {
        let (first, second) = childSizes(totalSize: 0, ratio: 0.5)
        #expect(first == 0)
        #expect(second == 0)
    }

    @Test("First + second + divider does not exceed total for various ratios")
    func totalDoesNotExceed() {
        let total: CGFloat = 800
        for ratioInt in stride(from: 10, through: 90, by: 5) {
            let ratio = CGFloat(ratioInt) / 100
            let (first, second) = childSizes(totalSize: total, ratio: ratio)
            let sum = first + second + PaneSplitView.dividerThickness
            #expect(sum <= total + 0.01, "Ratio \(ratio): sum \(sum) exceeds total \(total)")
        }
    }

    @Test("Divider thickness constants are reasonable")
    func dividerConstants() {
        #expect(PaneSplitView.dividerThickness == 1)
        #expect(PaneSplitView.dividerHitArea == 4)
        #expect(PaneSplitView.dividerHitArea > PaneSplitView.dividerThickness)
    }
}

// MARK: - PaneManager convenience init Tests

@Suite("PaneManager convenience init")
struct PaneManagerConvenienceInitTests {
    @Test("Single pane init creates correct state")
    func singlePaneInit() {
        let tm = TabManager()
        let manager = PaneManager(rootTabManager: tm)

        #expect(manager.paneCount == 1)
        #expect(manager.rootNode.leafCount == 1)
        #expect(manager.tabManager(for: manager.activePaneID) === tm)
    }

    @Test("focusPane changes active pane")
    func focusPaneChanges() {
        let id1 = PaneID()
        let id2 = PaneID()
        let tm1 = TabManager()
        let tm2 = TabManager()
        let root = PaneNode.split(.horizontal,
                                  first: .leaf(id1, .editor),
                                  second: .leaf(id2, .editor),
                                  ratio: 0.5)
        let manager = PaneManager(rootNode: root, activePaneID: id1, tabManagers: [id1: tm1, id2: tm2])

        #expect(manager.activePaneID == id1)
        manager.focusPane(id2)
        #expect(manager.activePaneID == id2)
    }

    @Test("focusPane ignores unknown pane ID")
    func focusPaneIgnoresUnknown() {
        let tm = TabManager()
        let manager = PaneManager(rootTabManager: tm)
        let original = manager.activePaneID

        manager.focusPane(PaneID())
        #expect(manager.activePaneID == original)
    }

    @Test("resizePane updates ratio with clamping")
    func resizePaneClamped() {
        let id1 = PaneID()
        let id2 = PaneID()
        let tm1 = TabManager()
        let tm2 = TabManager()
        let root = PaneNode.split(.horizontal,
                                  first: .leaf(id1, .editor),
                                  second: .leaf(id2, .editor),
                                  ratio: 0.5)
        let manager = PaneManager(rootNode: root, activePaneID: id1, tabManagers: [id1: tm1, id2: tm2])

        manager.resizePane(id1, ratio: 0.7)
        if case .split(_, _, _, let ratio) = manager.rootNode {
            #expect(abs(ratio - 0.7) < 1e-6)
        } else {
            Issue.record("Expected split node")
        }
    }

    @Test("resizePane clamps to minimum 0.1")
    func resizePaneClampsMin() {
        let id1 = PaneID()
        let id2 = PaneID()
        let root = PaneNode.split(.horizontal,
                                  first: .leaf(id1, .editor),
                                  second: .leaf(id2, .editor),
                                  ratio: 0.5)
        let manager = PaneManager(rootNode: root, activePaneID: id1, tabManagers: [id1: TabManager(), id2: TabManager()])

        manager.resizePane(id1, ratio: 0.01)
        if case .split(_, _, _, let ratio) = manager.rootNode {
            #expect(abs(ratio - 0.1) < 1e-6)
        } else {
            Issue.record("Expected split node")
        }
    }

    @Test("resizePane clamps to maximum 0.9")
    func resizePaneClampsMax() {
        let id1 = PaneID()
        let id2 = PaneID()
        let root = PaneNode.split(.horizontal,
                                  first: .leaf(id1, .editor),
                                  second: .leaf(id2, .editor),
                                  ratio: 0.5)
        let manager = PaneManager(rootNode: root, activePaneID: id1, tabManagers: [id1: TabManager(), id2: TabManager()])

        manager.resizePane(id1, ratio: 0.99)
        if case .split(_, _, _, let ratio) = manager.rootNode {
            #expect(abs(ratio - 0.9) < 1e-6)
        } else {
            Issue.record("Expected split node")
        }
    }

    @Test("tabManager returns correct instance for each pane")
    func tabManagerLookup() {
        let id1 = PaneID()
        let id2 = PaneID()
        let tm1 = TabManager()
        let tm2 = TabManager()
        let root = PaneNode.split(.vertical,
                                  first: .leaf(id1, .editor),
                                  second: .leaf(id2, .editor),
                                  ratio: 0.5)
        let manager = PaneManager(rootNode: root, activePaneID: id1, tabManagers: [id1: tm1, id2: tm2])

        #expect(manager.tabManager(for: id1) === tm1)
        #expect(manager.tabManager(for: id2) === tm2)
        #expect(manager.tabManager(for: PaneID()) == nil)
    }

    @Test("paneCount reflects tree structure")
    func paneCountReflectsTree() {
        let id1 = PaneID()
        let id2 = PaneID()
        let id3 = PaneID()
        let root = PaneNode.split(.horizontal,
                                  first: .leaf(id1, .editor),
                                  second: .split(.vertical,
                                                 first: .leaf(id2, .editor),
                                                 second: .leaf(id3, .editor),
                                                 ratio: 0.5),
                                  ratio: 0.5)
        let manager = PaneManager(
            rootNode: root,
            activePaneID: id1,
            tabManagers: [id1: TabManager(), id2: TabManager(), id3: TabManager()]
        )

        #expect(manager.paneCount == 3)
    }
}

// MARK: - Single Leaf Pane Tests

@Suite("Single leaf pane behavior")
struct SingleLeafPaneTests {
    @Test("Single leaf pane has no divider data")
    func singleLeafNoDivider() {
        let node = PaneNode.leaf(PaneID(), .editor)
        // A leaf node should not be a split
        if case .split = node {
            Issue.record("Single leaf should not be a split")
        }
        #expect(node.leafCount == 1)
    }

    @Test("Single pane manager has paneCount 1")
    func singlePaneCount() {
        let manager = PaneManager(rootTabManager: TabManager())
        #expect(manager.paneCount == 1)
    }

    @Test("Active border should not show for single pane")
    func noBorderForSinglePane() {
        let manager = PaneManager(rootTabManager: TabManager())
        // showBorder logic: isActive && paneCount > 1
        let isActive = manager.activePaneID == manager.rootNode.firstLeafID
        let showBorder = isActive && manager.paneCount > 1
        #expect(!showBorder, "Single pane should not show active border")
    }

    @Test("Active border shows when multiple panes exist")
    func borderShowsForMultiplePane() {
        let id1 = PaneID()
        let id2 = PaneID()
        let root = PaneNode.split(.horizontal,
                                  first: .leaf(id1, .editor),
                                  second: .leaf(id2, .editor),
                                  ratio: 0.5)
        let manager = PaneManager(rootNode: root, activePaneID: id1, tabManagers: [id1: TabManager(), id2: TabManager()])

        let showBorder = manager.activePaneID == id1 && manager.paneCount > 1
        #expect(showBorder, "Active pane in multi-pane layout should show border")
    }

    @Test("Inactive pane does not show border in multi-pane layout")
    func noBorderForInactivePane() {
        let id1 = PaneID()
        let id2 = PaneID()
        let root = PaneNode.split(.horizontal,
                                  first: .leaf(id1, .editor),
                                  second: .leaf(id2, .editor),
                                  ratio: 0.5)
        let manager = PaneManager(rootNode: root, activePaneID: id1, tabManagers: [id1: TabManager(), id2: TabManager()])

        let showBorderForId2 = manager.activePaneID == id2 && manager.paneCount > 1
        #expect(!showBorderForId2, "Inactive pane should not show border")
    }
}

// MARK: - Divider Ratio Clamping Tests

@Suite("Divider ratio clamping")
struct DividerRatioClampingTests {
    @Test("Ratio clamped to valid range during resize")
    func clampDuringResize() {
        // Simulating what PaneDividerView does: clamp newRatio to 0.1...0.9
        let tooLow: CGFloat = -0.5
        let tooHigh: CGFloat = 1.5
        let normal: CGFloat = 0.3

        let clampedLow = min(max(tooLow, 0.1), 0.9)
        let clampedHigh = min(max(tooHigh, 0.1), 0.9)
        let clampedNormal = min(max(normal, 0.1), 0.9)

        #expect(clampedLow == 0.1)
        #expect(clampedHigh == 0.9)
        #expect(abs(clampedNormal - 0.3) < 1e-6)
    }

    @Test("Boundary values clamp correctly")
    func boundaryValues() {
        #expect(min(max(CGFloat(0.1), 0.1), 0.9) == 0.1)
        #expect(min(max(CGFloat(0.9), 0.1), 0.9) == 0.9)
        #expect(min(max(CGFloat(0.0), 0.1), 0.9) == 0.1)
        #expect(min(max(CGFloat(1.0), 0.1), 0.9) == 0.9)
    }
}

// MARK: - AccessibilityID Pane Tests

@Suite("AccessibilityID pane identifiers")
struct AccessibilityIDPaneTests {
    @Test("Pane accessibility ID uses UUID string")
    func paneAccessibilityID() {
        let id = PaneID()
        let accessibilityID = AccessibilityID.pane(id)
        #expect(accessibilityID == "pane_\(id.id.uuidString)")
        #expect(accessibilityID.hasPrefix("pane_"))
    }

    @Test("PaneDivider accessibility ID is constant")
    func paneDividerAccessibilityID() {
        #expect(AccessibilityID.paneDivider == "paneDivider")
    }

    @Test("Different pane IDs produce different accessibility IDs")
    func uniqueAccessibilityIDs() {
        let id1 = PaneID()
        let id2 = PaneID()
        #expect(AccessibilityID.pane(id1) != AccessibilityID.pane(id2))
    }
}
