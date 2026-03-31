//
//  PaneManager.swift
//  Pine
//
//  Manages the pane layout tree and per-pane TabManagers.
//  Each leaf pane owns its own TabManager; splitting creates new ones.
//

import SwiftUI

/// Manages the split pane layout for the editor area.
/// Each leaf node in the PaneNode tree has its own `TabManager`.
@MainActor
@Observable
final class PaneManager {

    /// The root of the pane layout tree.
    private(set) var root: PaneNode

    /// Per-pane tab managers, keyed by PaneID.
    private(set) var tabManagers: [PaneID: TabManager] = [:]

    /// The currently focused pane.
    var activePaneID: PaneID

    /// Creates a PaneManager with a single editor pane.
    init() {
        let initialID = PaneID()
        self.root = .leaf(initialID, .editor)
        self.activePaneID = initialID
        let tm = TabManager()
        self.tabManagers[initialID] = tm
    }

    /// Creates a PaneManager with an existing TabManager (for migration from single-pane).
    init(existingTabManager: TabManager) {
        let initialID = PaneID()
        self.root = .leaf(initialID, .editor)
        self.activePaneID = initialID
        self.tabManagers[initialID] = existingTabManager
    }

    /// Returns the TabManager for a given pane.
    func tabManager(for paneID: PaneID) -> TabManager? {
        tabManagers[paneID]
    }

    /// Returns the active pane's TabManager.
    var activeTabManager: TabManager? {
        tabManagers[activePaneID]
    }

    /// Returns all TabManagers across all panes.
    var allTabManagers: [TabManager] {
        Array(tabManagers.values)
    }

    // MARK: - Split operations

    /// Splits a pane by placing a new pane alongside it.
    /// The tab at the given URL is moved from the source pane to the new one.
    @discardableResult
    func splitPane(
        _ targetID: PaneID,
        axis: SplitAxis,
        tabURL: URL? = nil,
        sourcePane: PaneID? = nil
    ) -> PaneID? {
        let newID = PaneID()
        guard let newRoot = root.splitting(
            targetID,
            axis: axis,
            newPaneID: newID,
            newContent: .editor
        ) else { return nil }

        root = newRoot
        let newTabManager = TabManager()
        tabManagers[newID] = newTabManager

        // Move tab from source to new pane if specified
        if let url = tabURL, let srcID = sourcePane, let srcTM = tabManagers[srcID] {
            moveTab(url: url, from: srcTM, to: newTabManager)
        }

        activePaneID = newID
        return newID
    }

    /// Moves a tab from one pane to another by URL.
    func moveTabBetweenPanes(tabURL: URL, from sourceID: PaneID, to targetID: PaneID) {
        guard let srcTM = tabManagers[sourceID],
              let dstTM = tabManagers[targetID] else { return }
        moveTab(url: tabURL, from: srcTM, to: dstTM)
        activePaneID = targetID

        // Clean up empty panes
        if srcTM.tabs.isEmpty {
            removePane(sourceID)
        }
    }

    /// Removes a pane and promotes its sibling.
    func removePane(_ paneID: PaneID) {
        guard root.leafCount > 1,
              let newRoot = root.removing(paneID) else { return }

        tabManagers[paneID] = nil
        root = newRoot

        // If active pane was removed, switch to first available
        if activePaneID == paneID {
            activePaneID = root.firstLeafID ?? activePaneID
        }
    }

    /// Updates the split ratio for a divider adjacent to a pane.
    func updateRatio(for paneID: PaneID, ratio: CGFloat) {
        if let newRoot = root.updatingRatio(for: paneID, ratio: ratio) {
            root = newRoot
        }
    }

    /// Updates the split ratio of the split node containing a target pane.
    func updateSplitRatio(containing paneID: PaneID, ratio: CGFloat) {
        if let newRoot = root.updatingRatioOfSplit(containing: paneID, ratio: ratio) {
            root = newRoot
        }
    }

    // MARK: - Session restore

    /// Restores a previously saved pane layout.
    /// Creates TabManagers for each leaf and returns the paneID-to-TabManager mapping
    /// so the caller can populate tabs.
    func restoreLayout(
        from node: PaneNode,
        activePaneUUID: UUID?
    ) {
        // Collect all leaf IDs from the restored tree
        let leafIDs = node.leafIDs

        // Create TabManagers for each leaf
        var newTabManagers: [PaneID: TabManager] = [:]
        for leafID in leafIDs {
            newTabManagers[leafID] = TabManager()
        }

        // Replace root and tab managers atomically
        root = node
        tabManagers = newTabManagers

        // Restore active pane
        if let uuid = activePaneUUID,
           let paneID = leafIDs.first(where: { $0.id == uuid }) {
            activePaneID = paneID
        } else if let firstLeaf = root.firstLeafID {
            activePaneID = firstLeaf
        }
    }

    // MARK: - Private helpers

    private func moveTab(url: URL, from source: TabManager, to destination: TabManager) {
        guard let srcIdx = source.tabs.firstIndex(where: { $0.url == url }) else { return }
        // Take a copy of the full tab with all state
        let tab = source.tabs[srcIdx]
        // Re-mint identity so the tab is fresh in the destination
        let movedTab = EditorTab.reidentified(from: tab)
        // Add to destination FIRST — if this crashes, the tab is still in source
        destination.tabs.append(movedTab)
        destination.activeTabID = movedTab.id
        // Now safe to remove from source (force: skip dirty check — we're moving, not discarding)
        source.closeTab(id: tab.id, force: true)
    }
}
