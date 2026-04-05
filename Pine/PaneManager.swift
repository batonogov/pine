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

    /// Per-pane terminal states, keyed by PaneID.
    private(set) var terminalStates: [PaneID: TerminalPaneState] = [:]

    /// Saved root before maximize, for restore.
    private var savedRootBeforeMaximize: PaneNode?

    /// ID of the currently maximized pane, if any.
    private(set) var maximizedPaneID: PaneID?

    /// Whether a pane is currently maximized.
    var isMaximized: Bool { maximizedPaneID != nil }

    /// The currently focused pane.
    var activePaneID: PaneID

    /// Shared drag state for synchronous tab drag between panes.
    /// Set by EditorTabBar.onDrag, read by drop delegates.
    /// Using shared state avoids unreliable async NSItemProvider loading.
    var activeDrag: TabDragInfo?

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

    /// Returns the TabManager for the active editor pane.
    /// If the active pane is a terminal, returns the first available editor pane's TabManager.
    var activeEditorTabManager: TabManager? {
        if let tm = tabManagers[activePaneID] { return tm }
        // Active pane is terminal — find nearest editor pane
        for leafID in root.leafIDs where root.content(for: leafID) == .editor {
            if let tm = tabManagers[leafID] { return tm }
        }
        return nil
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
    /// If removing this pane would leave zero editor panes, the pane is kept
    /// but its tabs are closed instead — ensuring the editor area is always available.
    func removePane(_ paneID: PaneID) {
        // If the pane being removed is the maximized pane, restore first
        // so the saved layout is available for removal.
        if maximizedPaneID == paneID {
            restoreFromMaximize()
        }

        guard root.leafCount > 1,
              let newRoot = root.removing(paneID) else { return }

        // Prevent removing the last editor pane — clear its tabs instead.
        if root.content(for: paneID) == .editor,
           root.leafCount(ofType: .editor) <= 1 {
            if let tm = tabManagers[paneID] {
                tm.closeAllTabs(force: true)
            }
            return
        }

        tabManagers[paneID] = nil
        terminalStates[paneID] = nil
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

    // MARK: - Terminal pane operations

    func terminalState(for paneID: PaneID) -> TerminalPaneState? {
        terminalStates[paneID]
    }

    var terminalPaneIDs: [PaneID] {
        root.leafIDs.filter { root.content(for: $0) == .terminal }
    }

    var allTerminalTabs: [TerminalTab] {
        terminalStates.values.flatMap(\.terminalTabs)
    }

    @discardableResult
    func createTerminalPane(
        relativeTo targetID: PaneID,
        axis: SplitAxis,
        workingDirectory: URL?
    ) -> PaneID? {
        let newID = PaneID()
        guard let newRoot = root.splitting(
            targetID, axis: axis, newPaneID: newID, newContent: .terminal
        ) else { return nil }

        root = newRoot
        let state = TerminalPaneState()
        state.addTab(workingDirectory: workingDirectory)
        terminalStates[newID] = state
        activePaneID = newID
        return newID
    }

    func moveTerminalTab(_ tabID: UUID, from sourceID: PaneID, to targetID: PaneID) {
        guard let srcState = terminalStates[sourceID],
              let dstState = terminalStates[targetID],
              let tab = srcState.terminalTabs.first(where: { $0.id == tabID }) else { return }

        dstState.terminalTabs.append(tab)
        dstState.activeTerminalID = tab.id
        srcState.terminalTabs.removeAll { $0.id == tabID }
        if srcState.activeTerminalID == tabID {
            srcState.activeTerminalID = srcState.terminalTabs.last?.id
        }
        activePaneID = targetID
        if srcState.terminalTabs.isEmpty {
            removePane(sourceID)
        }
    }

    // MARK: - Maximize

    func maximize(paneID: PaneID) {
        guard maximizedPaneID == nil else { return }
        guard let content = root.content(for: paneID) else { return }
        savedRootBeforeMaximize = root
        root = .leaf(paneID, content)
        maximizedPaneID = paneID
    }

    func restoreFromMaximize() {
        guard let saved = savedRootBeforeMaximize else { return }
        root = saved
        savedRootBeforeMaximize = nil
        maximizedPaneID = nil
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

        var newTabManagers: [PaneID: TabManager] = [:]
        var newTerminalStates: [PaneID: TerminalPaneState] = [:]
        for leafID in leafIDs {
            switch node.content(for: leafID) {
            case .editor:
                newTabManagers[leafID] = TabManager()
            case .terminal:
                newTerminalStates[leafID] = TerminalPaneState()
            case nil:
                break
            }
        }

        // Replace root and tab managers atomically
        root = node
        tabManagers = newTabManagers
        terminalStates = newTerminalStates

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
        guard let srcIdx = source.tabs.firstIndex(where: { $0.url == url }) ?? source.tabs.firstIndex(where: {
            $0.url.standardizedFileURL == url.standardizedFileURL
        }) else { return }
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
