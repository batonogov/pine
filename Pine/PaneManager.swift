//
//  PaneManager.swift
//  Pine
//
//  Created by Pine Team on 27.03.2026.
//

import Foundation

/// Manages the pane layout tree and per-pane TabManagers.
///
/// Each leaf pane owns a `TabManager` instance (stored in a flat dictionary
/// keyed by `PaneID` for O(1) lookup). The manager provides split, close,
/// focus-cycle, and resize operations while preserving backward compatibility
/// through `activeTabManager` (the single-pane equivalent of `tabManager`).
@Observable
final class PaneManager {
    /// The root of the pane layout tree.
    var rootNode: PaneNode

    /// The ID of the currently focused pane.
    var activePaneID: PaneID

    /// Per-pane TabManager instances. Keys are leaf PaneIDs.
    private(set) var tabManagers: [PaneID: TabManager] = [:]

    // MARK: - Initialization

    /// Creates a manager with a single editor pane (backward compatible).
    init() {
        let initialID = PaneID()
        self.rootNode = .leaf(initialID, .editor)
        self.activePaneID = initialID
        self.tabManagers[initialID] = TabManager()
    }

    /// Creates a manager with a single editor pane using the given TabManager.
    /// Convenience initializer for backward compatibility.
    init(rootTabManager: TabManager) {
        let initialID = PaneID()
        self.rootNode = .leaf(initialID, .editor)
        self.activePaneID = initialID
        self.tabManagers[initialID] = rootTabManager
    }

    /// Restores a manager from persisted state.
    init(rootNode: PaneNode, activePaneID: PaneID, tabManagers: [PaneID: TabManager]) {
        self.rootNode = rootNode
        self.activePaneID = activePaneID
        self.tabManagers = tabManagers
    }

    // MARK: - Computed properties

    /// The TabManager for the currently active pane.
    var activeTabManager: TabManager? {
        tabManagers[activePaneID]
    }

    /// Total number of leaf panes.
    var paneCount: Int {
        rootNode.leafCount
    }

    /// All leaf PaneIDs in the tree.
    var allPaneIDs: Set<PaneID> {
        rootNode.allIDs
    }

    // MARK: - Pane operations

    /// Splits the given pane along `axis`, creating a new sibling pane with the given content.
    /// No-op if the pane is not found or max depth would be exceeded.
    func splitPane(_ paneID: PaneID, axis: SplitAxis, content: PaneContent = .editor) {
        let newID = PaneID()
        guard let newRoot = rootNode.splitting(
            paneID,
            axis: axis,
            newPaneID: newID,
            newContent: content
        ) else { return }

        rootNode = newRoot
        tabManagers[newID] = TabManager()
        activePaneID = newID
    }

    /// Closes a pane and removes its TabManager. No-op if only one pane remains.
    /// If the closed pane was active, focus moves to the first remaining leaf.
    func closePane(_ paneID: PaneID) {
        guard paneCount > 1 else { return }
        guard let newRoot = rootNode.removing(paneID) else { return }

        rootNode = newRoot
        tabManagers[paneID] = nil

        if activePaneID == paneID {
            guard let nextFocus = rootNode.firstLeafID else {
                preconditionFailure("PaneNode tree has no leaves after removing pane")
            }
            activePaneID = nextFocus
        }
    }

    /// Sets the active pane. No-op if the ID is not in the tree.
    func focusPane(_ paneID: PaneID) {
        guard rootNode.contains(paneID) else { return }
        activePaneID = paneID
    }

    /// Moves focus to the next leaf pane (wraps around).
    func focusNextPane() {
        let ids = rootNode.leafIDs
        guard ids.count > 1,
              let currentIndex = ids.firstIndex(of: activePaneID) else { return }
        let nextIndex = (currentIndex + 1) % ids.count
        activePaneID = ids[nextIndex]
    }

    /// Moves focus to the previous leaf pane (wraps around).
    func focusPreviousPane() {
        let ids = rootNode.leafIDs
        guard ids.count > 1,
              let currentIndex = ids.firstIndex(of: activePaneID) else { return }
        let prevIndex = (currentIndex - 1 + ids.count) % ids.count
        activePaneID = ids[prevIndex]
    }

    /// Resizes the split containing the given pane. Ratio is clamped to 0.1...0.9.
    func resizePane(_ paneID: PaneID, ratio: CGFloat) {
        guard let newRoot = rootNode.updatingRatio(for: paneID, ratio: ratio) else { return }
        rootNode = newRoot
    }

    /// Returns the TabManager for a specific pane, if it exists.
    func tabManager(for paneID: PaneID) -> TabManager? {
        tabManagers[paneID]
    }

    /// Opens a file in the specified pane, or the active pane if nil.
    func openFile(_ url: URL, in paneID: PaneID? = nil) {
        let targetID = paneID ?? activePaneID
        guard let manager = tabManagers[targetID] else { return }
        manager.openTab(url: url)
    }
}
