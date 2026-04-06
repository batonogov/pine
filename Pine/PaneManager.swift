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
    private(set) var savedRootBeforeMaximize: PaneNode?

    /// ID of the currently maximized pane, if any.
    private(set) var maximizedPaneID: PaneID?

    /// Whether a pane is currently maximized.
    var isMaximized: Bool { maximizedPaneID != nil }

    /// The root to use when persisting session state.
    /// Returns the full layout even when a single pane is maximized.
    var persistableRoot: PaneNode { savedRootBeforeMaximize ?? root }

    /// The currently focused pane.
    var activePaneID: PaneID

    /// Shared drag state for synchronous tab drag between panes.
    /// Set by EditorTabBar.onDrag, read by drop delegates.
    /// Using shared state avoids unreliable async NSItemProvider loading.
    var activeDrag: TabDragInfo?

    /// Active drop zone per pane — centralized to avoid stale @State/@Binding issues.
    var dropZones: [PaneID: PaneDropZone] = [:]

    /// Active root-level drop zone — set by RootPaneSplitDropDelegate.
    var rootDropZone: RootDropZone?

    // The four properties below are marked `nonisolated(unsafe)` solely so
    // they can be touched from `deinit`, which is nonisolated even on a
    // @MainActor class. All real reads/writes happen on the main thread.

    /// NSEvent monitor for mouse-up cleanup of drop overlays (in-app).
    nonisolated(unsafe) private var mouseUpMonitor: Any?

    /// NSEvent monitor for mouse-up cleanup that fires even when the cursor
    /// is released outside the app window.
    nonisolated(unsafe) private var globalMouseUpMonitor: Any?

    /// Notification observers for window/app deactivation cleanup.
    nonisolated(unsafe) private var deactivationObservers: [NSObjectProtocol] = []

    /// Provider that returns `true` when the user is currently holding any
    /// mouse button down (i.e. a drag is potentially in progress).
    /// Defaults to `NSEvent.pressedMouseButtons`. Injectable for tests.
    var isMouseButtonPressed: () -> Bool = {
        NSEvent.pressedMouseButtons != 0
    }

    /// Clears all drop zone overlays across all panes.
    func clearAllDropZones() {
        dropZones.removeAll()
        rootDropZone = nil
    }

    /// Clears leaf-level drop zone overlays without touching rootDropZone.
    func clearLeafDropZones() {
        dropZones.removeAll()
    }

    /// Returns true if any drop zone overlay is currently visible.
    var hasActiveDropZones: Bool {
        !dropZones.isEmpty || rootDropZone != nil
    }

    /// Clears any visible drop zone overlays if the system reports that no
    /// mouse button is pressed (i.e. there cannot be an active drag session).
    /// This is a defensive cleanup hook used by polling and notification
    /// observers in case SwiftUI's `DropDelegate` fails to call `dropExited`
    /// or `performDrop` (issue #710).
    func clearStaleDropZonesIfNoDragActive() {
        guard hasActiveDropZones else { return }
        if !isMouseButtonPressed() {
            clearAllDropZones()
        }
    }

    /// Polling timer that periodically checks whether stale overlays should
    /// be cleared. Started lazily when an overlay first appears, stopped when
    /// none remain. ~120ms cadence keeps overhead negligible.
    nonisolated(unsafe) private var staleDropPollTimer: Timer?

    /// Starts the stale-overlay polling timer if not already running.
    /// Called by drop delegates whenever they set a drop zone.
    func startStaleDropPollingIfNeeded() {
        guard staleDropPollTimer == nil else { return }
        // Timer scheduled on the main run loop fires on the main thread, and
        // PaneManager is @MainActor, so no extra DispatchQueue.main.async hop
        // is needed inside the callback.
        let timer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            if !self.hasActiveDropZones {
                t.invalidate()
                self.staleDropPollTimer = nil
                return
            }
            self.clearStaleDropZonesIfNoDragActive()
        }
        staleDropPollTimer = timer
    }

    /// Creates a PaneManager with a single editor pane.
    init() {
        let initialID = PaneID()
        self.root = .leaf(initialID, .editor)
        self.activePaneID = initialID
        let tm = TabManager()
        self.tabManagers[initialID] = tm
        installMouseUpMonitor()
    }

    /// Creates a PaneManager with an existing TabManager (for migration from single-pane).
    init(existingTabManager: TabManager) {
        let initialID = PaneID()
        self.root = .leaf(initialID, .editor)
        self.activePaneID = initialID
        self.tabManagers[initialID] = existingTabManager
        installMouseUpMonitor()
    }

    deinit {
        if let monitor = mouseUpMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = globalMouseUpMonitor {
            NSEvent.removeMonitor(monitor)
        }
        for observer in deactivationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        staleDropPollTimer?.invalidate()
    }

    /// Installs an NSEvent monitor (local + global) and notification observers
    /// that clear drop overlays whenever a drag could possibly have ended.
    ///
    /// SwiftUI's `DropDelegate` does not reliably call `dropExited` or
    /// `performDrop` in all scenarios — e.g. when the drag is cancelled while
    /// the cursor is inside a pane, when the cursor moves between panes very
    /// quickly, or after the pane tree is mutated by `performDrop`.
    /// See issue #710.
    ///
    /// We defend against stale overlays by combining several signals:
    ///   1. Local mouse-up — drag released while the app is foreground
    ///   2. Global mouse-up — drag released while another app is foreground
    ///   3. Window/app deactivation — focus moved away mid-drag
    private func installMouseUpMonitor() {
        // Local closure invoked only from main-thread NSEvent monitor
        // callbacks, so it does not need to be @Sendable.
        let cleanup: () -> Void = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                if self.hasActiveDropZones {
                    self.clearAllDropZones()
                }
            }
        }

        mouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { event in
            cleanup()
            return event
        }

        globalMouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { _ in
            cleanup()
        }

        // Note: `didResignKeyNotification` is intentionally aggressive — it
        // fires whenever the window loses key status. This is acceptable
        // because during an active drag session AppKit cannot present a sheet
        // or popover that would steal key, so we will not clear an overlay
        // out from under a real in-progress drag.
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            NSWindow.didResignKeyNotification,
            NSApplication.didResignActiveNotification,
            NSApplication.didHideNotification
        ]
        for name in names {
            let observer = center.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.clearAllDropZones()
            }
            deactivationObservers.append(observer)
        }
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
    /// If `insertBefore` is true, the new pane is placed before (left/top of) the target.
    @discardableResult
    func splitPane(
        _ targetID: PaneID,
        axis: SplitAxis,
        tabURL: URL? = nil,
        sourcePane: PaneID? = nil,
        insertBefore: Bool = false
    ) -> PaneID? {
        let newID = PaneID()
        guard let newRoot = root.splitting(
            targetID,
            axis: axis,
            newPaneID: newID,
            newContent: .editor,
            insertBefore: insertBefore
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

    /// Creates a terminal pane spanning the full width at the bottom of the editor area.
    /// Wraps the entire current root in a vertical split with the terminal below.
    @discardableResult
    func createTerminalPaneAtBottom(workingDirectory: URL?) -> PaneID {
        let newID = PaneID()
        let terminalLeaf = PaneNode.leaf(newID, .terminal)
        root = .split(.vertical, first: root, second: terminalLeaf, ratio: 0.6)

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

    /// Splits a pane, creates a new terminal pane, and moves an existing terminal tab into it.
    @discardableResult
    func splitAndMoveTerminalTab(
        tabID: UUID,
        from sourceID: PaneID,
        relativeTo targetID: PaneID,
        axis: SplitAxis,
        insertBefore: Bool = false
    ) -> PaneID? {
        guard let srcState = terminalStates[sourceID],
              let tab = srcState.terminalTabs.first(where: { $0.id == tabID }) else { return nil }

        let newID = PaneID()
        guard let newRoot = root.splitting(
            targetID, axis: axis, newPaneID: newID, newContent: .terminal, insertBefore: insertBefore
        ) else { return nil }

        root = newRoot
        let newState = TerminalPaneState()
        terminalStates[newID] = newState

        newState.terminalTabs.append(tab)
        newState.activeTerminalID = tab.id
        srcState.terminalTabs.removeAll { $0.id == tabID }
        if srcState.activeTerminalID == tabID {
            srcState.activeTerminalID = srcState.terminalTabs.last?.id
        }

        activePaneID = newID

        if srcState.terminalTabs.isEmpty {
            removePane(sourceID)
        }

        return newID
    }

    /// Wraps the entire root in a new split, creating a full-width/height terminal pane.
    /// Moves the specified terminal tab from the source pane to the new pane.
    /// Removes the source pane if it becomes empty.
    func wrapRootWithTerminal(at zone: RootDropZone, from sourcePaneID: PaneID, tabID: UUID) {
        guard let srcState = terminalStates[sourcePaneID],
              let tab = srcState.terminalTabs.first(where: { $0.id == tabID }) else { return }

        // Remove tab from source BEFORE modifying the tree
        srcState.terminalTabs.removeAll { $0.id == tabID }
        if srcState.activeTerminalID == tabID {
            srcState.activeTerminalID = srcState.terminalTabs.last?.id
        }

        // Remove source pane if empty (this modifies root)
        if srcState.terminalTabs.isEmpty {
            removePane(sourcePaneID)
        }

        // Create new terminal pane and wrap root
        let newID = PaneID()
        let terminalLeaf = PaneNode.leaf(newID, .terminal)

        switch zone {
        case .bottom:
            root = .split(.vertical, first: root, second: terminalLeaf, ratio: 0.7)
        case .top:
            root = .split(.vertical, first: terminalLeaf, second: root, ratio: 0.3)
        case .right:
            root = .split(.horizontal, first: root, second: terminalLeaf, ratio: 0.7)
        case .left:
            root = .split(.horizontal, first: terminalLeaf, second: root, ratio: 0.3)
        }

        let newState = TerminalPaneState()
        newState.terminalTabs.append(tab)
        newState.activeTerminalID = tab.id
        terminalStates[newID] = newState
        activePaneID = newID
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

    // MARK: - Sidebar file drop operations

    /// Opens a file as a new tab in the specified editor pane.
    /// Does nothing if the pane has no TabManager (e.g., terminal pane)
    /// or if the URL is a directory.
    func openFileInPane(url: URL, paneID: PaneID) {
        guard let tabManager = tabManagers[paneID] else { return }
        // Skip directories — they should not open as editor tabs
        var isDir: ObjCBool = false
        let filePath = url.path(percentEncoded: false)
        if FileManager.default.fileExists(atPath: filePath, isDirectory: &isDir), isDir.boolValue {
            return
        }
        tabManager.openTab(url: url)
        activePaneID = paneID
    }

    /// Splits a pane and opens a file in the new pane.
    /// Returns the new pane's ID, or nil if the split failed.
    @discardableResult
    func splitAndOpenFile(
        url: URL,
        relativeTo targetID: PaneID,
        axis: SplitAxis,
        insertBefore: Bool = false
    ) -> PaneID? {
        guard let newPaneID = splitPane(targetID, axis: axis, insertBefore: insertBefore) else { return nil }
        guard let newTabManager = tabManagers[newPaneID] else { return nil }
        newTabManager.openTab(url: url)
        return newPaneID
    }

    // MARK: - Center drop

    /// Handles a center-zone tab drop on `targetPaneID`.
    ///
    /// - Same-type drop: moves the tab into the target pane (existing behaviour).
    /// - Cross-type drop: auto-splits the target pane vertically and places the
    ///   moved tab in a new pane of matching type below the target. This is
    ///   issue #714 — previously cross-type center drops were silently rejected.
    ///
    /// Returns `true` if the drop caused a state change.
    @discardableResult
    func performCenterDrop(dragInfo: TabDragInfo, targetPaneID: PaneID) -> Bool {
        let sourcePaneID = PaneID(id: dragInfo.paneID)
        guard let targetContent = root.content(for: targetPaneID) else { return false }
        // Same-pane center drop is a no-op.
        guard sourcePaneID != targetPaneID else { return false }

        if dragInfo.contentType == targetContent {
            // Same-type: plain move.
            if dragInfo.contentType == .terminal {
                guard terminalStates[sourcePaneID]?.terminalTabs
                    .contains(where: { $0.id == dragInfo.tabID }) == true else { return false }
                moveTerminalTab(dragInfo.tabID, from: sourcePaneID, to: targetPaneID)
                return true
            } else if let fileURL = dragInfo.fileURL {
                guard tabManagers[sourcePaneID]?.tabs
                    .contains(where: { $0.url == fileURL }) == true else { return false }
                moveTabBetweenPanes(tabURL: fileURL, from: sourcePaneID, to: targetPaneID)
                return true
            }
            return false
        }

        // Cross-type: auto-split target vertically, new pane below holds the moved tab.
        if dragInfo.contentType == .terminal {
            // Moving a terminal tab into an editor pane.
            guard terminalStates[sourcePaneID]?.terminalTabs
                .contains(where: { $0.id == dragInfo.tabID }) == true else { return false }
            let newID = splitAndMoveTerminalTab(
                tabID: dragInfo.tabID,
                from: sourcePaneID,
                relativeTo: targetPaneID,
                axis: .vertical,
                insertBefore: false
            )
            return newID != nil
        } else if let fileURL = dragInfo.fileURL {
            // Moving an editor tab into a terminal pane.
            guard tabManagers[sourcePaneID]?.tabs
                .contains(where: { $0.url == fileURL }) == true else { return false }
            let newID = splitPane(
                targetPaneID,
                axis: .vertical,
                tabURL: fileURL,
                sourcePane: sourcePaneID,
                insertBefore: false
            )
            return newID != nil
        }
        return false
    }

    /// Clears stale drag state for both tab drags and sidebar file drags.
    /// Called when a drag exits all valid drop targets (e.g., user cancels drag).
    func clearStaleDragState() {
        activeDrag = nil
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
