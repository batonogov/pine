//
//  PaneManager.swift
//  Pine
//
//  Manages the pane layout tree and per-pane TabManagers.
//  Each leaf pane owns its own TabManager; splitting creates new ones.
//

import SwiftUI

/// Exact work counters for the global-switcher inventory projection. These
/// counters make the hot-path complexity test deterministic without relying
/// on wall-clock timing from a loaded CI host.
struct GlobalTabInventoryMetrics: Equatable {
    var paneVisits = 0
    var tabVisits = 0
    var orderLookups = 0
    var entryLookups = 0

    var totalOperations: Int {
        paneVisits + tabVisits + orderLookups + entryLookups
    }
}

/// Manages the split pane layout for the editor area.
/// Each leaf node in the PaneNode tree has its own `TabManager`.
@MainActor
@Observable
final class PaneManager {
    private enum GlobalTabInventoryItem {
        case editor(fileName: String, url: URL?)
        case terminal(
            name: String,
            stableLabel: String,
            workingDirectory: URL?
        )
    }

    private struct GlobalTabInventory {
        var items: [GlobalTabIdentity: GlobalTabInventoryItem] = [:]
        var deterministicOrder: [GlobalTabIdentity] = []
        var metrics = GlobalTabInventoryMetrics()

        var validIdentities: Set<GlobalTabIdentity> {
            Set(items.keys)
        }
    }

    /// The root of the pane layout tree.
    private(set) var root: PaneNode

    /// Per-pane tab managers, keyed by PaneID.
    private(set) var tabManagers: [PaneID: TabManager] = [:]

    /// Per-pane terminal states, keyed by PaneID.
    private(set) var terminalStates: [PaneID: TerminalPaneState] = [:]

    /// Applies project-scoped services (recovery, editor-context callbacks,
    /// and similar wiring) to every editor TabManager owned by this pane tree.
    /// Setting the configurator also updates managers that already exist.
    var configureEditorTabManager: ((TabManager) -> Void)? {
        didSet {
            guard let configureEditorTabManager else { return }
            tabManagers.values.forEach(configureEditorTabManager)
        }
    }

    /// Applies project-scoped lifecycle wiring to every terminal tab without
    /// making the durable registry retain pane, tab, view, or process objects.
    var configureTerminalTab: ((TerminalTab) -> Void)? {
        didSet {
            guard let configureTerminalTab else { return }
            allTerminalTabs.forEach(configureTerminalTab)
            terminalStates.values.forEach {
                $0.onTabCreated = configureTerminalTab
            }
        }
    }

    /// Reports value-only terminal route changes after a completed tab move.
    var terminalTabDidMove: ((TerminalTab, PaneID) -> Void)?

    /// Saved root before maximize, for restore.
    private(set) var savedRootBeforeMaximize: PaneNode?

    /// ID of the currently maximized pane, if any.
    private(set) var maximizedPaneID: PaneID?

    /// Whether a pane is currently maximized.
    var isMaximized: Bool { maximizedPaneID != nil }

    /// The root to use when persisting session state.
    /// Returns the full layout even when a single pane is maximized.
    var persistableRoot: PaneNode { savedRootBeforeMaximize ?? root }

    /// Last exact inventory work count, excluded from observation so rendering
    /// the overlay cannot cause a feedback loop. Kept internal for deterministic
    /// linear-complexity regression tests and diagnostics.
    @ObservationIgnored
    private(set) var lastGlobalTabInventoryMetrics =
        GlobalTabInventoryMetrics()

    /// The currently focused pane.
    var activePaneID: PaneID

    /// Global most-recently-used tab switch order across ALL panes. This is
    /// independent of each pane's local active-tab selection
    /// (`TabManager.activeTabID` / `TerminalPaneState.activeTerminalID`). It
    /// powers the all-pane tab switcher (Ctrl+Tab / Ctrl+Shift+Tab).
    ///
    /// The most recently activated tab is at index 0. Closed or stale
    /// identities are filtered out lazily at switch time via
    /// ``validGlobalTabSwitchOrder()``.
    private(set) var globalTabSwitchOrder: [GlobalTabIdentity] = []

    /// Prevents the activation callbacks owned by pane-local managers from
    /// reordering the MRU list while a keyboard cycle is in progress.
    private var isPerformingGlobalTabSwitch = false

    /// The live visual MRU switcher session (`nil` unless Control-Tab overlay
    /// is up). Created by `beginGlobalTabSwitcherSession()`, torn down on commit
    /// (Control release) or cancellation (Escape). Observed by the overlay view.
    /// The MRU order itself (`globalTabSwitchOrder`) remains the source of
    /// truth; the session only captures a frozen snapshot for deterministic
    /// cycling while the overlay is shown (#1239).
    private(set) var globalTabSwitcherSession: GlobalTabSwitcherSession?

    /// `true` while the visual Control-Tab overlay is being driven. The
    /// keyboard handler uses this to distinguish the *first* Control-Tab press
    /// (open the overlay) from subsequent presses (cycle it).
    var isGlobalTabSwitcherActive: Bool { globalTabSwitcherSession != nil }

    /// Records a tab activation in the global MRU switch order. Called by
    /// every path that activates an editor or terminal tab: selection, open,
    /// transfer, and split. Move-to-front with dedup so each identity appears
    /// at most once and the newest activation is always first.
    func recordTabActivation(
        paneID: PaneID,
        tabID: UUID,
        contentType: PaneContent
    ) {
        let identity = GlobalTabIdentity(paneID: paneID, tabID: tabID, contentType: contentType)
        globalTabSwitchOrder.removeAll { $0 == identity }
        globalTabSwitchOrder.insert(identity, at: 0)
    }

    /// Returns the global switch order with closed/stale identities removed.
    /// A stale identity is one whose pane no longer exists in the tree or
    /// whose tab no longer exists in the pane's manager. This lazy filter
    /// makes restoration deterministic without requiring explicit cleanup
    /// on every structural mutation.
    func validGlobalTabSwitchOrder() -> [GlobalTabIdentity] {
        var inventory = makeGlobalTabInventory()
        let order = validGlobalTabSwitchOrder(in: &inventory)
        lastGlobalTabInventoryMetrics = inventory.metrics
        return order
    }

    /// Builds one O(n) pane/tab projection for validation and presentation.
    /// Keeping metadata in an identity dictionary avoids repeatedly scanning
    /// every pane's tab array for each MRU identity.
    private func makeGlobalTabInventory() -> GlobalTabInventory {
        var inventory = GlobalTabInventory()

        func collect(_ node: PaneNode) {
            inventory.metrics.paneVisits += 1
            switch node {
            case .leaf(let paneID, let content):
                switch content {
                case .editor:
                    for tab in tabManagers[paneID]?.tabs ?? [] {
                        inventory.metrics.tabVisits += 1
                        let identity = GlobalTabIdentity(
                            paneID: paneID,
                            tabID: tab.id,
                            contentType: .editor
                        )
                        inventory.items[identity] = .editor(
                            fileName: tab.fileName,
                            url: tab.fileURL
                        )
                        inventory.deterministicOrder.append(identity)
                    }
                case .terminal:
                    for tab in terminalStates[paneID]?.terminalTabs ?? [] {
                        inventory.metrics.tabVisits += 1
                        let identity = GlobalTabIdentity(
                            paneID: paneID,
                            tabID: tab.id,
                            contentType: .terminal
                        )
                        inventory.items[identity] = .terminal(
                            name: tab.name,
                            stableLabel: tab.stableLabel,
                            workingDirectory: tab.workingDirectoryURL
                        )
                        inventory.deterministicOrder.append(identity)
                    }
                }
            case .split(_, let first, let second, _):
                collect(first)
                collect(second)
            }
        }

        // A maximized pane is only a presentation projection. Hidden siblings
        // remain eligible for the all-pane switcher.
        collect(persistableRoot)
        return inventory
    }

    private func validGlobalTabSwitchOrder(
        in inventory: inout GlobalTabInventory
    ) -> [GlobalTabIdentity] {
        let validIdentities = inventory.validIdentities
        return globalTabSwitchOrder.filter { identity in
            inventory.metrics.orderLookups += 1
            return validIdentities.contains(identity)
        }
    }

    /// Reconciles a frozen switcher snapshot through the same identity set
    /// used by both presentation and commit. Counting the set probes keeps
    /// the deterministic complexity diagnostics representative of this path.
    private func reconciledGlobalTabSwitcherSession(
        _ session: GlobalTabSwitcherSession,
        in inventory: inout GlobalTabInventory
    ) -> GlobalTabSwitcherSession? {
        inventory.metrics.orderLookups += session.identities.count
        return session.reconciled(
            keeping: inventory.validIdentities
        )
    }

    /// The identity of the currently active tab in the active pane, if any.
    /// Used as the anchor for forward/backward MRU cycling.
    private func currentGlobalTabIdentity() -> GlobalTabIdentity? {
        let paneID = activePaneID
        guard let content = persistableRoot.content(for: paneID) else {
            return nil
        }
        let tabID: UUID?
        if content == .editor {
            tabID = tabManagers[paneID]?.activeTabID
        } else {
            tabID = terminalStates[paneID]?.activeTerminalID
        }
        guard let tabID else { return nil }
        return GlobalTabIdentity(paneID: paneID, tabID: tabID, contentType: content)
    }

    /// Cycles to the next tab in global MRU order (Ctrl+Tab). Wraps around.
    /// Returns `true` if a switch occurred.
    @discardableResult
    func switchToNextTabGlobally() -> Bool {
        switchGlobalTab(offset: 1)
    }

    /// Cycles to the previous tab in global MRU order (Ctrl+Shift+Tab).
    /// Wraps around. Returns `true` if a switch occurred.
    @discardableResult
    func switchToPreviousTabGlobally() -> Bool {
        switchGlobalTab(offset: -1)
    }

    /// Core MRU cycling logic. The current tab is found in the valid order;
    /// `offset` (+1 forward, −1 backward) selects the neighbour with wraparound.
    /// If the current tab is not in the order (e.g. freshly opened), cycling
    /// starts from the head.
    @discardableResult
    private func switchGlobalTab(offset: Int) -> Bool {
        let order = validGlobalTabSwitchOrder()
        guard order.count >= 2 else { return false }

        let currentIndex = currentGlobalTabIdentity().flatMap { current in
            order.firstIndex(of: current)
        }

        let startIndex: Int
        if let currentIndex {
            startIndex = (currentIndex + offset + order.count) % order.count
        } else {
            startIndex = offset > 0 ? 0 : order.count - 1
        }

        let target = order[startIndex]
        // Activate WITHOUT recording: the switcher must not re-order the MRU
        // list, otherwise each press chases the tab it just promoted and the
        // cycle never reaches older entries. Only organic interactions
        // (click, open, edit) re-order the list.
        isPerformingGlobalTabSwitch = true
        defer { isPerformingGlobalTabSwitch = false }
        return activateGlobalTab(target)
    }

    /// Sets the active pane and tab for a global-switch target WITHOUT
    /// recording it in the MRU order. Used by the switcher so cycling does
    /// not pollute the switch order.
    @discardableResult
    private func activateGlobalTab(_ identity: GlobalTabIdentity) -> Bool {
        if identity.contentType == .editor {
            guard let tabManager = tabManagers[identity.paneID],
                  tabManager.tabs.contains(where: { $0.id == identity.tabID }) else {
                return false
            }
            surfaceMaximizedPaneIfNeeded(identity)
            activePaneID = identity.paneID
            tabManager.activeTabID = identity.tabID
            tabManager.pendingFocusTabID = identity.tabID
            return true
        }
        guard let terminalState = terminalStates[identity.paneID],
              terminalState.terminalTabs.contains(where: { $0.id == identity.tabID }) else {
            return false
        }
        surfaceMaximizedPaneIfNeeded(identity)
        activePaneID = identity.paneID
        terminalState.activeTerminalID = identity.tabID
        terminalState.pendingFocusTabID = identity.tabID
        return true
    }

    /// Switching from one hidden sibling to another while zoomed keeps zoom
    /// active but swaps the projected leaf, so the committed target is visible.
    private func surfaceMaximizedPaneIfNeeded(
        _ identity: GlobalTabIdentity
    ) {
        guard savedRootBeforeMaximize != nil,
              maximizedPaneID != identity.paneID else { return }
        root = .leaf(identity.paneID, identity.contentType)
        maximizedPaneID = identity.paneID
    }

    // MARK: - Visual MRU switcher session (#1239)

    /// Begins a visual Control-Tab switching session: freezes the current
    /// valid MRU order, records the starting tab so Escape can restore it, and
    /// arms the overlay. The overlay view observes `globalTabSwitcherSession`
    /// and renders while it is non-`nil`.
    ///
    /// `initialOffset` applies the first forward/reverse gesture atomically.
    /// When there is no current tab in the MRU snapshot, a forward gesture
    /// starts at the head and a reverse gesture starts at the tail.
    ///
    /// Safe to call repeatedly: if a session is already active, this is a
    /// no-op (the existing session keeps its frozen order). Returns `true` if a
    /// session is now active (newly or already).
    @discardableResult
    func beginGlobalTabSwitcherSession(initialOffset: Int = 0) -> Bool {
        if globalTabSwitcherSession != nil { return true }
        let order = validGlobalTabSwitchOrder()
        guard order.count >= 2 else { return false }
        let original = currentGlobalTabIdentity()
        let startIndex: Int
        if let currentIndex = original.flatMap({ order.firstIndex(of: $0) }) {
            startIndex = (
                currentIndex + initialOffset % order.count + order.count
            ) % order.count
        } else {
            startIndex = initialOffset < 0 ? order.count - 1 : 0
        }
        globalTabSwitcherSession = GlobalTabSwitcherSession(
            identities: order,
            originalIdentity: original,
            selectedIndex: startIndex
        )
        return true
    }

    /// Advances the overlay cursor by `offset` (+1 forward via Control-Tab,
    /// −1 backward via Shift-Control-Tab), wrapping around the frozen order.
    /// No-op (and does not create a session) if no session is active or the
    /// frozen order is empty.
    ///
    /// Does NOT record the activation in the MRU list: cycling must not pollute
    /// the switch order (same invariant as `switchGlobalTab`). The selected tab
    /// is only surfaced visually; the real activation happens on `commit`.
    func advanceGlobalTabSwitcher(offset: Int) {
        guard reconcileGlobalTabSwitcherSession(),
              let session = globalTabSwitcherSession else { return }
        let count = session.identities.count
        let newIndex = (session.selectedIndex + offset % count + count) % count
        globalTabSwitcherSession?.selectedIndex = newIndex
    }

    /// Commits the current switcher selection: activates the highlighted tab
    /// and tears down the session. This is the ONLY step during the cycle that
    /// moves real focus. The selected tab is recorded as the most-recently-used
    /// only through the normal activation path, so the MRU list updates once,
    /// at the moment the user committed.
    func commitGlobalTabSwitcher() {
        guard reconcileGlobalTabSwitcherSession(),
              let session = globalTabSwitcherSession else { return }
        defer { globalTabSwitcherSession = nil }
        guard let target = session.selectedIdentity else { return }
        // Activate through the same path used by organic selection so the
        // committed tab is promoted to the MRU head exactly once.
        _ = activateAndRecordGlobalTab(target)
    }

    /// Cancels the switcher session, restoring the tab that was active when it
    /// began only if an organic action changed the real active tab while the
    /// overlay was open. Preview cycling never moves focus, so re-activating an
    /// unchanged original would manufacture a duplicate pending-focus request.
    /// If no original tab was recorded (or it has since become invalid), the
    /// active pane/tab state is left untouched.
    func cancelGlobalTabSwitcher() {
        guard let session = globalTabSwitcherSession else { return }
        globalTabSwitcherSession = nil
        guard let original = session.originalIdentity,
              currentGlobalTabIdentity() != original else { return }
        // Best-effort restore: if the original tab is still valid, surface it;
        // otherwise leave whatever is currently active (the user's last view).
        _ = activateGlobalTab(original)
    }

    /// Tears down a gesture without changing pane, tab, or first-responder
    /// state. Window/app lifecycle loss and owner migration use this path:
    /// restoring focus into an outgoing or closing window is unsafe.
    func discardGlobalTabSwitcherSession() {
        globalTabSwitcherSession = nil
    }

    /// Reconciles a live switcher session against the current pane/tab
    /// inventory. Returns `false` after ending a session that no longer has at
    /// least two eligible tabs.
    @discardableResult
    func reconcileGlobalTabSwitcherSession() -> Bool {
        guard let session = globalTabSwitcherSession else { return false }
        var inventory = makeGlobalTabInventory()
        defer {
            lastGlobalTabInventoryMetrics = inventory.metrics
        }
        guard let reconciled = reconciledGlobalTabSwitcherSession(
            session,
            in: &inventory
        ) else {
            globalTabSwitcherSession = nil
            return false
        }
        if reconciled != session {
            globalTabSwitcherSession = reconciled
        }
        return true
    }

    /// Child tab owners call this only after completing an identity-set
    /// mutation, so reconciliation never re-enters a live array `inout`
    /// access. The early guard keeps ordinary tab operations O(1) when the
    /// visual switcher is not open.
    private func reconcileGlobalTabSwitcherAfterInventoryChange() {
        guard globalTabSwitcherSession != nil else { return }
        _ = reconcileGlobalTabSwitcherSession()
    }

    /// Activate a global tab AND record it in the MRU list. Mirrors
    /// `activateGlobalTab` but promotes the target to the MRU head, used by the
    /// commit path so the committed tab is treated like an organic activation.
    @discardableResult
    private func activateAndRecordGlobalTab(_ identity: GlobalTabIdentity) -> Bool {
        // Suppress the pane-local activation callback while focus changes,
        // then perform the single explicit MRU promotion below.
        let wasPerformingGlobalTabSwitch = isPerformingGlobalTabSwitch
        isPerformingGlobalTabSwitch = true
        let activated = activateGlobalTab(identity)
        isPerformingGlobalTabSwitch = wasPerformingGlobalTabSwitch
        guard activated else { return false }
        recordTabActivation(
            paneID: identity.paneID,
            tabID: identity.tabID,
            contentType: identity.contentType
        )
        return true
    }

    /// Builds the presentation rows for the active switcher session, in the
    /// frozen session order. Titles are read live so they stay current (e.g. a
    /// shell-reported terminal title), while the *order* follows the snapshot
    /// captured at session start. Stale identities (closed/stale since the
    /// snapshot) are dropped defensively.
    ///
    /// `projectRoot` is used to derive project-relative paths for editor tabs;
    /// pass `nil` when no project is open.
    func globalTabSwitcherEntries(
        projectRoot: URL?,
        locale: Locale = .current
    ) -> [GlobalTabSwitcherEntry] {
        globalTabSwitcherPresentation(
            projectRoot: projectRoot,
            locale: locale
        ).entries
    }

    /// Builds rows and cursor from one reconciled snapshot so a stale identity
    /// cannot make the overlay highlight one tab and commit another.
    func globalTabSwitcherPresentation(
        projectRoot: URL?,
        locale: Locale = .current
    ) -> GlobalTabSwitcherPresentation {
        guard let session = globalTabSwitcherSession else {
            return .empty
        }
        var inventory = makeGlobalTabInventory()
        defer {
            lastGlobalTabInventoryMetrics = inventory.metrics
        }
        guard let reconciled = reconciledGlobalTabSwitcherSession(
            session,
            in: &inventory
        ) else {
            return .empty
        }
        // Pane position labels are stable for the session (derived from the
        // visible tree). Use persistableRoot so hidden-maximized siblings are
        // still counted in their true positions, not the collapsed single leaf.
        let panePositions = paneContextLabels(locale: locale)
        let entries: [GlobalTabSwitcherEntry] =
            reconciled.identities.compactMap { identity -> GlobalTabSwitcherEntry? in
                inventory.metrics.entryLookups += 1
                guard let item = inventory.items[identity] else { return nil }
                return entry(
                    for: identity,
                    item: item,
                    panePositions: panePositions,
                    projectRoot: projectRoot,
                    locale: locale
                )
            }
        guard entries.count == reconciled.identities.count else {
            return .empty
        }
        return GlobalTabSwitcherPresentation(
            entries: entries,
            selectedIndex: reconciled.selectedIndex
        )
    }

    /// Resolves inventory metadata to one presentation entry. Callers perform
    /// the O(1) validity lookup before invoking this formatter.
    private func entry(
        for identity: GlobalTabIdentity,
        item: GlobalTabInventoryItem,
        panePositions: [PaneID: String],
        projectRoot: URL?,
        locale: Locale
    ) -> GlobalTabSwitcherEntry {
        let paneContext = panePositions[identity.paneID]
            ?? Strings.paneGenericLabel(locale: locale)
        switch item {
        case .editor(let fileName, let url):
            return GlobalTabSwitcherEntry(
                id: identity,
                title: fileName,
                symbolName: FileIconMapper.iconForFile(fileName),
                symbolColor: FileIconMapper.colorForFile(fileName),
                paneContext: paneContext,
                detail: Self.editorDetail(
                    from: url,
                    root: projectRoot
                )
            )
        case .terminal(let name, let stableLabel, let workingDirectory):
            return GlobalTabSwitcherEntry(
                id: identity,
                title: name,
                symbolName: "terminal",
                symbolColor: .secondary,
                paneContext: paneContext,
                detail: Self.terminalDetail(
                    stableLabel: stableLabel,
                    workingDirectory: workingDirectory,
                    projectRoot: projectRoot
                )
            )
        }
    }

    /// Maps each leaf pane to a 1-based position label (left-to-right,
    /// top-to-bottom). Uses `persistableRoot` so hidden-maximized siblings keep
    /// their true positions rather than collapsing to "Pane 1".
    private func paneContextLabels(locale: Locale) -> [PaneID: String] {
        var labels: [PaneID: String] = [:]
        for (index, paneID) in persistableRoot.leafIDs.enumerated() {
            labels[paneID] = Strings.panePositionLabel(
                index + 1,
                locale: locale
            )
        }
        return labels
    }

    /// Project-relative path for `url` under `root`, or `nil` when `url` is not
    /// under `root` (or when either is absent). Normalization is purely lexical:
    /// the Control-Tab main-thread path must never perform filesystem I/O.
    static func relativePath(from url: URL?, root: URL?) -> String? {
        guard let url, let root else { return nil }
        let rootPath = lexicallyNormalizedPath(root.path)
        let urlPath = lexicallyNormalizedPath(url.path)
        guard !rootPath.isEmpty, !urlPath.isEmpty else { return nil }
        if rootPath == "/" {
            return urlPath == "/" ? "" : String(urlPath.dropFirst())
        }
        guard urlPath == rootPath || urlPath.hasPrefix(rootPath + "/") else {
            return nil
        }
        if urlPath == rootPath { return "" }
        return String(urlPath.dropFirst(rootPath.count + 1))
    }

    /// Secondary editor label: project-relative path when possible, otherwise
    /// the external parent directory so equal file names remain distinguishable.
    private static func editorDetail(from url: URL?, root: URL?) -> String? {
        guard let url else { return nil }
        if let relativePath = relativePath(from: url, root: root),
           !relativePath.isEmpty {
            return relativePath
        }
        let path = lexicallyNormalizedPath(url.path)
        guard !path.isEmpty else { return nil }
        let parent = lexicallyNormalizedPath(
            (path as NSString).deletingLastPathComponent
        )
        return parent.isEmpty ? "/" : abbreviatedDisplayPath(parent)
    }

    /// Secondary terminal label keeps duplicate dynamic shell titles distinct
    /// through the tab's stable creation label and current working directory.
    private static func terminalDetail(
        stableLabel: String,
        workingDirectory: URL?,
        projectRoot: URL?
    ) -> String {
        guard let workingDirectory else { return stableLabel }
        let directory: String
        if let relative = relativePath(
            from: workingDirectory,
            root: projectRoot
        ) {
            directory = relative.isEmpty
                ? (projectRoot?.lastPathComponent ?? workingDirectory.path)
                : relative
        } else {
            directory = abbreviatedDisplayPath(
                lexicallyNormalizedPath(workingDirectory.path)
            )
        }
        guard !directory.isEmpty, directory != stableLabel else {
            return stableLabel
        }
        return "\(stableLabel) · \(directory)"
    }

    /// Uses `~` for the current home directory without resolving symlinks or
    /// touching disk, keeping external-path details concise and less revealing.
    private static func abbreviatedDisplayPath(_ path: String) -> String {
        let home = lexicallyNormalizedPath(NSHomeDirectory())
        guard home != "/", !home.isEmpty else { return path }
        if path == home { return "~" }
        guard path.hasPrefix(home + "/") else { return path }
        return "~/" + String(path.dropFirst(home.count + 1))
    }

    /// Removes `.` and `..` components without consulting the filesystem.
    /// File URLs are absolute in Pine, but preserving relative input makes the
    /// helper total and straightforward to exercise in unit tests.
    private static func lexicallyNormalizedPath(_ path: String) -> String {
        let isAbsolute = path.hasPrefix("/")
        var components: [Substring] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".":
                continue
            case "..":
                if let last = components.last, last != ".." {
                    components.removeLast()
                } else if !isAbsolute {
                    components.append(component)
                }
            default:
                components.append(component)
            }
        }
        let joined = components.joined(separator: "/")
        if isAbsolute {
            return joined.isEmpty ? "/" : "/\(joined)"
        }
        return joined
    }

    /// The single owner of tab-drag session, preview, validation, and commit.
    let tabDragCoordinator: TabDragCoordinator

    /// Compatibility facade for existing cleanup and diagnostics. New drop
    /// destinations submit intents through `tabDragCoordinator`.
    var activeDrag: TabDragInfo? {
        get { tabDragCoordinator.activeDrag }
        set {
            if let newValue {
                tabDragCoordinator.begin(newValue)
            } else {
                tabDragCoordinator.cancel()
            }
        }
    }

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
        tabDragCoordinator.clearPreview()
    }

    /// Clears leaf-level drop zone overlays without touching rootDropZone.
    func clearLeafDropZones() {
        dropZones.removeAll()
    }

    /// Returns true if any drop zone overlay is currently visible.
    var hasActiveDropZones: Bool {
        !dropZones.isEmpty || rootDropZone != nil
    }

    /// Clears any visible drop zone overlays and the shared payload if the
    /// system reports that no mouse button is pressed (i.e. there cannot be
    /// an active drag session).
    /// This is a defensive cleanup hook used by polling and notification
    /// observers in case SwiftUI's `DropDelegate` fails to call `dropExited`
    /// or `performDrop` (issue #710).
    func clearStaleDropZonesIfNoDragActive() {
        guard hasActiveDropZones || activeDrag != nil else { return }
        if !isMouseButtonPressed() {
            clearAllDropZones()
            clearStaleDragState()
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
        let coordinator = TabDragCoordinator()
        self.tabDragCoordinator = coordinator
        self.root = .leaf(initialID, .editor)
        self.activePaneID = initialID
        let tm = TabManager()
        self.tabManagers[initialID] = tm
        trackEditorActivations(in: tm, paneID: initialID)
        bindTabDragCoordinator(coordinator)
        installMouseUpMonitor()
    }

    /// Creates a PaneManager with an existing TabManager (for migration from single-pane).
    init(existingTabManager: TabManager) {
        let initialID = PaneID()
        let coordinator = TabDragCoordinator()
        self.tabDragCoordinator = coordinator
        self.root = .leaf(initialID, .editor)
        self.activePaneID = initialID
        self.tabManagers[initialID] = existingTabManager
        trackEditorActivations(in: existingTabManager, paneID: initialID)
        bindTabDragCoordinator(coordinator)
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
                self.clearStaleDragState()
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
                DispatchQueue.main.async {
                    self?.clearAllDropZones()
                    self?.clearStaleDragState()
                }
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

    /// Selects an editor tab and makes its owning pane active.
    ///
    /// Tab-strip controls use the default focus request so the destination
    /// editor becomes first responder. Callers such as sidebar previews can
    /// opt out to keep keyboard interaction at the source.
    @discardableResult
    func selectEditorTab(
        _ tabID: UUID,
        in paneID: PaneID,
        requestFocus: Bool = true
    ) -> Bool {
        guard let tabManager = tabManagers[paneID],
              tabManager.tabs.contains(where: { $0.id == tabID }) else {
            return false
        }
        activePaneID = paneID
        tabManager.activeTabID = tabID
        // Clearing here is intentional: a previously queued AppKit retry for
        // this same tab must not steal focus after a sidebar preview click.
        tabManager.pendingFocusTabID = requestFocus ? tabID : nil
        recordTabActivation(paneID: paneID, tabID: tabID, contentType: .editor)
        return true
    }

    // MARK: - Split operations

    /// Splits a pane by placing a new pane alongside it.
    /// The tab at the given identity (or legacy URL fallback) is moved from
    /// the source pane to the new one.
    /// If `insertBefore` is true, the new pane is placed before (left/top of) the target.
    @discardableResult
    func splitPane(
        _ targetID: PaneID,
        axis: SplitAxis,
        tabID: UUID? = nil,
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

        let newTabManager = makeEditorTabManager(for: newID)

        // Resolve and detach the tab before committing the new tree. If any
        // transfer precondition fails, no pane is created and the source is
        // left untouched. Insertion is rollback-safe even if its identity
        // precondition unexpectedly changes.
        if tabID != nil || tabURL != nil {
            guard let sourcePane,
                  let source = tabManagers[sourcePane],
                  let resolvedTabID = resolvedEditorTabID(tabID: tabID, url: tabURL, in: source),
                  let tab = source.tabs.first(where: { $0.id == resolvedTabID }),
                  newTabManager.canInsertTransferredTab(tab),
                  let extraction = source.extractTab(id: resolvedTabID) else { return nil }

            guard newTabManager.insertTransferredTab(extraction) else {
                source.restoreExtractedTab(extraction)
                return nil
            }
        }

        root = newRoot
        tabManagers[newID] = newTabManager
        activePaneID = newID
        newTabManager.onEditorContextChanged?()

        // An edge/split move must obey the same empty-source invariant as a
        // center move. The newly created destination is non-empty, so it is
        // never selected as the pruning victim.
        if tabID != nil || tabURL != nil {
            pruneEmptyEditorLeaves()
            if let activeTabID = newTabManager.activeTabID {
                recordTabActivation(
                    paneID: newID,
                    tabID: activeTabID,
                    contentType: .editor
                )
            }
        }
        return newID
    }

    /// Moves a tab from one pane to another by URL.
    @discardableResult
    func moveTabBetweenPanes(tabURL: URL, from sourceID: PaneID, to targetID: PaneID) -> Bool {
        transferEditorTab(tabID: nil, url: tabURL, from: sourceID, to: targetID)
    }

    /// Moves the exact tab identity from one editor pane to another. The URL
    /// is retained only as a compatibility fallback for legacy drag payloads.
    @discardableResult
    func moveTabBetweenPanes(
        tabID: UUID,
        tabURL: URL? = nil,
        from sourceID: PaneID,
        to targetID: PaneID
    ) -> Bool {
        transferEditorTab(tabID: tabID, url: tabURL, from: sourceID, to: targetID)
    }

    /// Indexed cross-pane transfer used by an editor strip insertion intent.
    @discardableResult
    func moveTabBetweenPanes(
        tabID: UUID,
        tabURL: URL? = nil,
        from sourceID: PaneID,
        to targetID: PaneID,
        at insertionIndex: Int
    ) -> Bool {
        transferEditorTab(
            tabID: tabID,
            url: tabURL,
            from: sourceID,
            to: targetID,
            insertionIndex: insertionIndex
        )
    }

    // MARK: - Empty editor leaf pruning

    /// Removes any editor leaf whose TabManager has no tabs, collapsing the
    /// empty "No File Selected" placeholder so it never occupies layout space
    /// when the user has other panes to work with. Pruning is unconditional
    /// when other content (editor or terminal) remains in the tree; if a file
    /// is later opened from the sidebar / Quick Open / Recent, callers use
    /// ``ensureEditorPane()`` to recreate an editor leaf on demand.
    ///
    /// Invariants:
    ///   - The single root leaf is never removed (valid empty-state on a
    ///     freshly opened project).
    ///   - A maximized pane is never removed; restore first if needed.
    ///
    /// Idempotent and safe to call after any structural mutation.
    func pruneEmptyEditorLeaves() {
        while true {
            // Cannot prune the only leaf in the tree.
            guard root.leafCount > 1 else { return }

            let victim = root.leafIDs.first { id in
                guard root.content(for: id) == .editor else { return false }
                guard id != maximizedPaneID else { return false }
                guard let tm = tabManagers[id] else { return false }
                return tm.tabs.isEmpty
            }
            guard let paneID = victim else { return }
            guard let newRoot = root.removing(paneID) else { return }

            tabManagers[paneID] = nil
            terminalStates[paneID] = nil
            root = newRoot

            if activePaneID == paneID {
                activePaneID = root.firstLeafID ?? activePaneID
            }
            reconcileGlobalTabSwitcherAfterInventoryChange()
        }
    }

    /// Returns the TabManager of an editor leaf suitable for receiving a
    /// newly opened file. If an editor leaf already exists, returns its
    /// TabManager (preferring the active one). Otherwise creates a new
    /// editor leaf next to the first terminal pane, splitting it vertically
    /// so the new editor sits above the terminal — matching the behavior
    /// users expect when opening files into a terminals-only layout.
    ///
    /// Always returns non-nil; the only failure mode (entire tree gone) is
    /// guarded by re-using the existing root leaf as a last resort.
    @discardableResult
    func ensureEditorPane() -> TabManager {
        if let tm = tabManagers[activePaneID] { return tm }
        if let editorPaneID = root.leafIDs.first(where: {
            root.content(for: $0) == .editor
        }), let tm = tabManagers[editorPaneID] {
            activePaneID = editorPaneID
            return tm
        }

        // No editor leaf exists — create one by splitting the first terminal
        // pane (insertBefore = true puts the new editor above the terminal).
        if let terminalLeafID = root.leafIDs.first(where: { root.content(for: $0) == .terminal }),
           let newID = splitPane(terminalLeafID, axis: .vertical, insertBefore: true),
           let tm = tabManagers[newID] {
            activePaneID = newID
            return tm
        }

        // Theoretical fallback: tree contains neither editor nor terminal
        // leaves (impossible in practice). Fall back to whatever TabManager
        // we still have, or create a fresh one bound to the existing root.
        if let firstID = root.firstLeafID, let tm = tabManagers[firstID] {
            return tm
        }
        let newID = PaneID()
        let fresh = makeEditorTabManager(for: newID)
        tabManagers[newID] = fresh
        root = .leaf(newID, .editor)
        activePaneID = newID
        return fresh
    }

    /// Opens a file into the usable editor destination and routes pane/tab
    /// activation through the same path as a tab click. Explicit opens, Quick
    /// Open, and Activity Panel navigation request first-responder focus by
    /// default; sidebar previews opt out so their keyboard focus is preserved.
    @discardableResult
    func openFileInActiveEditor(
        url: URL,
        asTransientPreview: Bool = false,
        requestFocus: Bool = true,
        completion: TabManager.OpenCompletion? = nil
    ) -> Bool {
        let previousActivePaneID = activePaneID
        let existingEditorPaneIDs = Set(tabManagers.keys)
        let tabManager = ensureEditorPane()
        let paneID = activePaneID
        let createdDestination = !existingEditorPaneIDs.contains(paneID)
        let completion: TabManager.OpenCompletion = { [weak self, weak tabManager] result in
            if let self, let tabManager {
                self.finishFileOpen(
                    result,
                    in: tabManager,
                    paneID: paneID,
                    requestFocus: requestFocus,
                    previousActivePaneID: previousActivePaneID,
                    removeEmptyDestinationOnCancel: createdDestination
                )
            }
            completion?(result)
        }
        let result = if asTransientPreview {
            tabManager.openTabAsPreview(url: url, completion: completion)
        } else {
            tabManager.openTab(url: url, completion: completion)
        }

        // `ensureEditorPane()` must provision a destination before the
        // large-file sheet can resolve, but a pending decision must not steal
        // pane focus. The completion activates it only after acceptance.
        if result == .pending,
           root.content(for: previousActivePaneID) != nil {
            activePaneID = previousActivePaneID
        }
        return result.wasAccepted
    }

    /// Removes a pane and promotes its sibling. When the very last leaf in
    /// the tree is removed, a fresh empty editor leaf is created in its
    /// place so the window never ends up with no content at all.
    func removePane(_ paneID: PaneID) {
        // If the pane being removed is the maximized pane, restore first
        // so the saved layout is available for removal.
        if maximizedPaneID == paneID {
            restoreFromMaximize()
        }

        // Special case: removing the only leaf in the tree → replace it with
        // a fresh empty editor leaf so the user always has a destination.
        if root.leafCount == 1, root.firstLeafID == paneID {
            terminalStates[paneID]?.terminalTabs.forEach { $0.stop() }
            tabManagers[paneID] = nil
            terminalStates[paneID] = nil
            let newID = PaneID()
            tabManagers[newID] = makeEditorTabManager(for: newID)
            root = .leaf(newID, .editor)
            activePaneID = newID
            reconcileGlobalTabSwitcherAfterInventoryChange()
            return
        }

        guard root.leafCount > 1,
              let newRoot = root.removing(paneID) else { return }

        terminalStates[paneID]?.terminalTabs.forEach { $0.stop() }
        tabManagers[paneID] = nil
        terminalStates[paneID] = nil
        root = newRoot

        // If active pane was removed, switch to first available
        if activePaneID == paneID {
            activePaneID = root.firstLeafID ?? activePaneID
        }
        reconcileGlobalTabSwitcherAfterInventoryChange()
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

    /// Selects a terminal tab, activates its pane, and requests first responder
    /// for the newly selected terminal content.
    @discardableResult
    func selectTerminalTab(_ tabID: UUID, in paneID: PaneID) -> Bool {
        guard let terminalState = terminalStates[paneID],
              terminalState.terminalTabs.contains(where: { $0.id == tabID }) else {
            return false
        }
        activePaneID = paneID
        terminalState.activeTerminalID = tabID
        terminalState.pendingFocusTabID = tabID
        recordTabActivation(paneID: paneID, tabID: tabID, contentType: .terminal)
        return true
    }

    // MARK: - Pointer-free tab movement

    /// Whether the currently active editor or terminal tab can perform a
    /// keyboard/VoiceOver movement command without violating pinned
    /// boundaries, hidden-layout guards, or content-type routing.
    func canMoveActiveTab(_ action: TabMoveAction) -> Bool {
        guard let contentType = root.content(for: activePaneID) else { return false }
        let tabID: UUID?
        switch contentType {
        case .editor:
            tabID = tabManagers[activePaneID]?.activeTabID
        case .terminal:
            tabID = terminalStates[activePaneID]?.activeTerminalID
        }
        guard let tabID else { return false }
        return canMoveTab(
            tabID,
            from: activePaneID,
            contentType: contentType,
            action: action
        )
    }

    /// Moves the active tab through the same transactional primitives used by
    /// drag-and-drop. This gives keyboard and assistive-technology users the
    /// exact same pinned-boundary, focus, pruning, and rollback semantics.
    @discardableResult
    func moveActiveTab(_ action: TabMoveAction) -> Bool {
        guard let contentType = root.content(for: activePaneID) else { return false }
        let tabID: UUID?
        switch contentType {
        case .editor:
            tabID = tabManagers[activePaneID]?.activeTabID
        case .terminal:
            tabID = terminalStates[activePaneID]?.activeTerminalID
        }
        guard let tabID else { return false }
        return moveTab(
            tabID,
            from: activePaneID,
            contentType: contentType,
            action: action
        )
    }

    func canMoveTab(
        _ tabID: UUID,
        from paneID: PaneID,
        contentType: PaneContent,
        action: TabMoveAction
    ) -> Bool {
        guard root.content(for: paneID) == contentType else { return false }
        switch action {
        case .leading, .trailing:
            guard let insertionIndex = adjacentInsertionIndex(
                tabID: tabID,
                paneID: paneID,
                contentType: contentType,
                action: action
            ) else { return false }
            switch contentType {
            case .editor:
                return tabManagers[paneID]?.canMoveTab(
                    id: tabID,
                    toInsertionIndex: insertionIndex
                ) == .moved
            case .terminal:
                return terminalStates[paneID]?.canMoveTab(
                    id: tabID,
                    toInsertionIndex: insertionIndex
                ) == .moved
            }
        case .previousPane, .nextPane:
            guard !isMaximized,
                  let destinationPaneID = adjacentPane(
                    to: paneID,
                    contentType: contentType,
                    action: action
                  ) else { return false }
            switch contentType {
            case .editor:
                guard let tab = tabManagers[paneID]?.tabs.first(where: { $0.id == tabID }),
                      let destination = tabManagers[destinationPaneID] else { return false }
                let insertionIndex = tab.isPinned
                    ? destination.pinnedTabCount
                    : destination.tabs.count
                return destination.canInsertTransferredTab(tab, at: insertionIndex)
            case .terminal:
                return terminalStates[destinationPaneID]?
                    .terminalTabs.contains(where: { $0.id == tabID }) == false
            }
        }
    }

    @discardableResult
    func moveTab(
        _ tabID: UUID,
        from paneID: PaneID,
        contentType: PaneContent,
        action: TabMoveAction
    ) -> Bool {
        guard canMoveTab(
            tabID,
            from: paneID,
            contentType: contentType,
            action: action
        ) else { return false }

        switch action {
        case .leading, .trailing:
            guard let insertionIndex = adjacentInsertionIndex(
                tabID: tabID,
                paneID: paneID,
                contentType: contentType,
                action: action
            ) else { return false }
            let result: TabInsertionResult
            switch contentType {
            case .editor:
                result = tabManagers[paneID]?.moveTab(
                    id: tabID,
                    toInsertionIndex: insertionIndex
                ) ?? .rejected
            case .terminal:
                result = terminalStates[paneID]?.moveTab(
                    id: tabID,
                    toInsertionIndex: insertionIndex
                ) ?? .rejected
            }
            guard result == .moved else { return false }
            activePaneID = paneID
            recordTabActivation(paneID: paneID, tabID: tabID, contentType: contentType)
            return true
        case .previousPane, .nextPane:
            guard let destinationPaneID = adjacentPane(
                to: paneID,
                contentType: contentType,
                action: action
            ) else { return false }
            switch contentType {
            case .editor:
                guard let tab = tabManagers[paneID]?.tabs.first(where: { $0.id == tabID }),
                      let destination = tabManagers[destinationPaneID] else { return false }
                let insertionIndex = tab.isPinned
                    ? destination.pinnedTabCount
                    : destination.tabs.count
                return moveTabBetweenPanes(
                    tabID: tabID,
                    tabURL: tab.fileURL,
                    from: paneID,
                    to: destinationPaneID,
                    at: insertionIndex
                )
            case .terminal:
                guard let destination = terminalStates[destinationPaneID] else { return false }
                return moveTerminalTab(
                    tabID,
                    from: paneID,
                    to: destinationPaneID,
                    at: destination.terminalTabs.count
                )
            }
        }
    }

    private func adjacentInsertionIndex(
        tabID: UUID,
        paneID: PaneID,
        contentType: PaneContent,
        action: TabMoveAction
    ) -> Int? {
        let ids: [UUID]
        switch contentType {
        case .editor:
            ids = tabManagers[paneID]?.tabs.map(\.id) ?? []
        case .terminal:
            ids = terminalStates[paneID]?.terminalTabs.map(\.id) ?? []
        }
        guard let sourceIndex = ids.firstIndex(of: tabID) else { return nil }
        switch action {
        case .leading:
            return sourceIndex > 0 ? sourceIndex - 1 : nil
        case .trailing:
            return sourceIndex + 1 < ids.count ? sourceIndex + 2 : nil
        case .previousPane, .nextPane:
            return nil
        }
    }

    private func adjacentPane(
        to paneID: PaneID,
        contentType: PaneContent,
        action: TabMoveAction
    ) -> PaneID? {
        let matchingPaneIDs = root.leafIDs.filter {
            root.content(for: $0) == contentType
        }
        guard let index = matchingPaneIDs.firstIndex(of: paneID) else { return nil }
        switch action {
        case .previousPane:
            return index > 0 ? matchingPaneIDs[index - 1] : nil
        case .nextPane:
            return index + 1 < matchingPaneIDs.count ? matchingPaneIDs[index + 1] : nil
        case .leading, .trailing:
            return nil
        }
    }

    /// Adds a terminal tab through the pane owner so creation and focus
    /// routing cannot disagree about the active pane.
    @discardableResult
    func addTerminalTab(in paneID: PaneID, workingDirectory: URL?) -> TerminalTab? {
        guard let terminalState = terminalStates[paneID] else { return nil }
        activePaneID = paneID
        let tab = terminalState.addTab(workingDirectory: workingDirectory)
        recordTabActivation(paneID: paneID, tabID: tab.id, contentType: .terminal)
        return tab
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
        let state = makeTerminalPaneState(for: newID)
        terminalStates[newID] = state
        activePaneID = newID
        state.addTab(workingDirectory: workingDirectory)
        return newID
    }

    /// Creates a terminal pane spanning the full width at the bottom of the editor area.
    /// Wraps the entire current root in a vertical split with the terminal below.
    @discardableResult
    func createTerminalPaneAtBottom(workingDirectory: URL?) -> PaneID {
        let newID = PaneID()
        let terminalLeaf = PaneNode.leaf(newID, .terminal)
        root = .split(.vertical, first: root, second: terminalLeaf, ratio: 0.6)

        let state = makeTerminalPaneState(for: newID)
        terminalStates[newID] = state
        activePaneID = newID
        state.addTab(workingDirectory: workingDirectory)
        return newID
    }

    @discardableResult
    func moveTerminalTab(_ tabID: UUID, from sourceID: PaneID, to targetID: PaneID) -> Bool {
        guard let destination = terminalStates[targetID] else { return false }
        return moveTerminalTab(
            tabID,
            from: sourceID,
            to: targetID,
            at: destination.terminalTabs.count
        )
    }

    /// Atomically inserts a terminal tab at an exact destination gap. Every
    /// precondition is checked before either source or destination changes.
    @discardableResult
    func moveTerminalTab(
        _ tabID: UUID,
        from sourceID: PaneID,
        to targetID: PaneID,
        at insertionIndex: Int
    ) -> Bool {
        guard sourceID != targetID,
              let srcState = terminalStates[sourceID],
              let dstState = terminalStates[targetID],
              (0...dstState.terminalTabs.count).contains(insertionIndex),
              !dstState.terminalTabs.contains(where: { $0.id == tabID }),
              let tab = srcState.terminalTabs.first(where: { $0.id == tabID }) else { return false }

        dstState.terminalTabs.insert(tab, at: insertionIndex)
        dstState.activeTerminalID = tab.id
        dstState.pendingFocusTabID = tab.id
        srcState.terminalTabs.removeAll { $0.id == tabID }
        if srcState.activeTerminalID == tabID {
            srcState.activeTerminalID = srcState.terminalTabs.last?.id
        }
        activePaneID = targetID
        terminalTabDidMove?(tab, targetID)
        if srcState.terminalTabs.isEmpty {
            removePane(sourceID)
        }
        recordTabActivation(paneID: targetID, tabID: tabID, contentType: .terminal)
        reconcileGlobalTabSwitcherAfterInventoryChange()
        return true
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
        let newState = makeTerminalPaneState(for: newID)
        terminalStates[newID] = newState

        newState.terminalTabs.append(tab)
        newState.activeTerminalID = tab.id
        newState.pendingFocusTabID = tab.id
        srcState.terminalTabs.removeAll { $0.id == tabID }
        if srcState.activeTerminalID == tabID {
            srcState.activeTerminalID = srcState.terminalTabs.last?.id
        }

        activePaneID = newID
        terminalTabDidMove?(tab, newID)

        if srcState.terminalTabs.isEmpty {
            removePane(sourceID)
        }

        recordTabActivation(paneID: newID, tabID: tab.id, contentType: .terminal)
        reconcileGlobalTabSwitcherAfterInventoryChange()
        return newID
    }

    /// Wraps the entire root in a new split, creating a full-width/height terminal pane.
    /// Moves the specified terminal tab from the source pane to the new pane.
    /// Removes the source pane if it becomes empty.
    @discardableResult
    func wrapRootWithTerminal(
        at zone: RootDropZone,
        from sourcePaneID: PaneID,
        tabID: UUID
    ) -> Bool {
        guard let srcState = terminalStates[sourcePaneID],
              let tab = srcState.terminalTabs.first(where: { $0.id == tabID }) else { return false }

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

        let newState = makeTerminalPaneState(for: newID)
        terminalStates[newID] = newState
        newState.terminalTabs.append(tab)
        newState.activeTerminalID = tab.id
        newState.pendingFocusTabID = tab.id
        activePaneID = newID
        terminalTabDidMove?(tab, newID)
        recordTabActivation(paneID: newID, tabID: tab.id, contentType: .terminal)
        reconcileGlobalTabSwitcherAfterInventoryChange()
        return true
    }

    // MARK: - Maximize

    func maximize(paneID: PaneID) {
        guard maximizedPaneID == nil else { return }
        guard let content = root.content(for: paneID) else { return }
        savedRootBeforeMaximize = root
        root = .leaf(paneID, content)
        maximizedPaneID = paneID
        // The projected leaf is now the only visible pane. Keep the focus
        // model aligned even when the maximize button consumed the click
        // before PaneFocusDetector could mark this pane active.
        activePaneID = paneID
    }

    func restoreFromMaximize() {
        guard let saved = savedRootBeforeMaximize else { return }
        root = saved
        savedRootBeforeMaximize = nil
        maximizedPaneID = nil
    }

    /// Toggles zoom on the focused terminal pane (#1115): maximizes the
    /// active pane if it is a terminal and nothing is zoomed; restores the
    /// full layout if a pane is currently zoomed. No-op when the focus is
    /// not on a terminal pane and nothing is zoomed (so the user can always
    /// escape zoom with the same shortcut regardless of focus).
    func toggleMaximizeOnActiveTerminalPane() {
        if isMaximized {
            restoreFromMaximize()
            return
        }
        guard terminalPaneIDs.contains(activePaneID) else { return }
        maximize(paneID: activePaneID)
    }

    // MARK: - Session restore

    /// Restores a previously saved pane layout.
    /// Creates TabManagers for each leaf and returns the paneID-to-TabManager mapping
    /// so the caller can populate tabs.
    @discardableResult
    func restoreLayout(
        from node: PaneNode,
        activePaneUUID: UUID?
    ) -> Bool {
        // Collect all leaf IDs from the restored tree
        let leafIDs = node.leafIDs
        guard !leafIDs.isEmpty,
              node.depth <= paneMaxDepth,
              Set(leafIDs).count == leafIDs.count else {
            return false
        }

        // A wholesale layout restore replaces the pane/tab identity space and
        // resets MRU below. A live gesture cannot be meaningfully reconciled
        // across that transaction, so tear it down without moving focus.
        discardGlobalTabSwitcherSession()

        var newTabManagers: [PaneID: TabManager] = [:]
        var newTerminalStates: [PaneID: TerminalPaneState] = [:]
        let reusableSingleEditorManager: TabManager? = {
            guard leafIDs.count == 1,
                  node.content(for: leafIDs[0]) == .editor,
                  root.leafCount == 1,
                  let currentID = root.firstLeafID,
                  root.content(for: currentID) == .editor else { return nil }
            return tabManagers[currentID]
        }()
        for leafID in leafIDs {
            switch node.content(for: leafID) {
            case .editor:
                if let reusableSingleEditorManager {
                    configureEditorTabManager?(reusableSingleEditorManager)
                    trackEditorActivations(in: reusableSingleEditorManager, paneID: leafID)
                    newTabManagers[leafID] = reusableSingleEditorManager
                } else {
                    newTabManagers[leafID] = makeEditorTabManager(for: leafID)
                }
            case .terminal:
                newTerminalStates[leafID] = makeTerminalPaneState(for: leafID)
            case nil:
                break
            }
        }

        // A restored layout replaces runtime terminal identity. Report every
        // discarded terminal exactly once before publishing the new tree.
        terminalStates.values
            .flatMap(\.terminalTabs)
            .forEach { $0.stop() }

        // Replace root and tab managers atomically
        root = node
        tabManagers = newTabManagers
        terminalStates = newTerminalStates
        globalTabSwitchOrder = []

        // Restore active pane
        if let uuid = activePaneUUID,
           let paneID = leafIDs.first(where: { $0.id == uuid }) {
            activePaneID = paneID
        } else if let firstLeaf = root.firstLeafID {
            activePaneID = firstLeaf
        }
        return true
    }

    /// Re-applies a persisted active pane after empty-leaf pruning and terminal
    /// recreation. Invalid or stale UUIDs fail closed to the first surviving
    /// leaf in deterministic tree order.
    func restoreActivePane(uuid: UUID?) {
        if let uuid,
           let paneID = root.leafIDs.first(where: { $0.id == uuid }) {
            activePaneID = paneID
        } else if !root.leafIDs.contains(activePaneID),
                  let firstLeaf = root.firstLeafID {
            activePaneID = firstLeaf
        }
    }

    /// Restores the global switch order after runtime tab UUIDs have been
    /// recreated. Stale/duplicate identities are discarded. Any tabs omitted
    /// by an older or partially stale session are appended in stable
    /// pane-order/tab-order so the switcher always has a complete,
    /// deterministic cycle.
    func restoreGlobalTabSwitchOrder(_ restored: [GlobalTabIdentity]) {
        let inventory = makeGlobalTabInventory()
        var result: [GlobalTabIdentity] = []
        var seen = Set<GlobalTabIdentity>()

        func appendIfValid(_ identity: GlobalTabIdentity) {
            guard seen.insert(identity).inserted,
                  inventory.items[identity] != nil else { return }
            result.append(identity)
        }

        restored.forEach(appendIfValid)

        if result.isEmpty, let current = currentGlobalTabIdentity() {
            appendIfValid(current)
        }
        inventory.deterministicOrder.forEach(appendIfValid)
        globalTabSwitchOrder = result
        lastGlobalTabInventoryMetrics = inventory.metrics
    }

    /// Invalidates a destination-focus request that predates a source control
    /// such as the sidebar taking first responder.
    ///
    /// Only the active pane can currently pass the AppKit coordinators'
    /// `canAttempt` guards. Keeping the cancellation scoped to that pane avoids
    /// discarding unrelated restore or drag requests in background panes.
    func cancelPendingFocusForActivePane() {
        switch root.content(for: activePaneID) {
        case .editor:
            guard let manager = tabManagers[activePaneID],
                  manager.pendingFocusTabID != nil else { return }
            manager.pendingFocusTabID = nil
        case .terminal:
            guard let state = terminalStates[activePaneID],
                  state.pendingFocusTabID != nil else { return }
            state.pendingFocusTabID = nil
        case nil:
            break
        }
    }

    /// Requests usable content focus for the restored active pane. The normal
    /// bounded AppKit retry coordinator consumes this request once the
    /// destination view has entered a window.
    func requestFocusForActivePane() {
        switch root.content(for: activePaneID) {
        case .editor:
            guard let manager = tabManagers[activePaneID],
                  let tabID = manager.activeTabID else { return }
            manager.pendingFocusTabID = tabID
        case .terminal:
            guard let state = terminalStates[activePaneID],
                  let tabID = state.activeTerminalID else { return }
            state.pendingFocusTabID = tabID
        case nil:
            break
        }
    }

    // MARK: - Sidebar file drop operations

    /// Opens a file as a new tab in the specified editor pane.
    /// Does nothing if the pane has no TabManager (e.g., terminal pane)
    /// or if the URL is a directory.
    @discardableResult
    func openFileInPane(
        url: URL,
        paneID: PaneID,
        completion: TabManager.OpenCompletion? = nil
    ) -> Bool {
        guard let tabManager = tabManagers[paneID] else {
            completion?(.cancelled)
            return false
        }
        // Skip directories — they should not open as editor tabs
        var isDir: ObjCBool = false
        let filePath = url.path(percentEncoded: false)
        if FileManager.default.fileExists(atPath: filePath, isDirectory: &isDir), isDir.boolValue {
            completion?(.cancelled)
            return false
        }
        let result = tabManager.openTab(url: url) { [weak self, weak tabManager] result in
            if let self, let tabManager {
                self.finishFileOpen(
                    result,
                    in: tabManager,
                    paneID: paneID,
                    requestFocus: true
                )
            }
            completion?(result)
        }
        return result.wasAccepted
    }

    /// Splits a pane and opens a file in the new pane.
    /// Returns the new pane's ID, or nil if the split failed.
    @discardableResult
    func splitAndOpenFile(
        url: URL,
        relativeTo targetID: PaneID,
        axis: SplitAxis,
        insertBefore: Bool = false,
        completion: TabManager.OpenCompletion? = nil
    ) -> PaneID? {
        let previousActivePaneID = activePaneID
        guard let newPaneID = splitPane(
            targetID,
            axis: axis,
            insertBefore: insertBefore
        ) else {
            completion?(.cancelled)
            return nil
        }
        guard let newTabManager = tabManagers[newPaneID] else {
            completion?(.cancelled)
            return nil
        }
        let result = newTabManager.openTab(url: url) { [weak self, weak newTabManager] result in
            if let self, let newTabManager {
                self.finishFileOpen(
                    result,
                    in: newTabManager,
                    paneID: newPaneID,
                    requestFocus: true,
                    previousActivePaneID: previousActivePaneID,
                    removeEmptyDestinationOnCancel: true
                )
            }
            completion?(result)
        }

        // Creating the split is synchronous, while a large-file decision is
        // not. Keep the source pane active until acceptance.
        if result == .pending,
           root.content(for: previousActivePaneID) != nil {
            activePaneID = previousActivePaneID
        }
        return result.wasAccepted ? newPaneID : nil
    }

    // MARK: - Transactional tab drag

    /// Starts a drag and returns the payload stored in the item provider.
    @discardableResult
    func beginTabDrag(
        paneID: PaneID,
        tabID: UUID,
        fileURL: URL?,
        contentType: PaneContent
    ) -> TabDragInfo {
        let drag = TabDragInfo(
            paneID: paneID.id,
            tabID: tabID,
            fileURL: fileURL,
            contentType: contentType
        )
        tabDragCoordinator.begin(drag)
        return drag
    }

    /// Builds the typed intent for a same-type strip. Cross-type payloads are
    /// deliberately rejected here so the strip and pane body never compete.
    func tabStripIntent(
        destinationPaneID: PaneID,
        contentType: PaneContent,
        insertionIndex: Int
    ) -> TabDropIntent? {
        guard let drag = activeDrag,
              drag.contentType == contentType,
              root.content(for: destinationPaneID) == contentType else { return nil }
        let key = TabDragKey(drag)
        if key.sourcePaneID == destinationPaneID {
            return .reorder(
                drag: key,
                destinationPaneID: destinationPaneID,
                insertionIndex: insertionIndex
            )
        }
        return .insert(
            drag: key,
            destinationPaneID: destinationPaneID,
            insertionIndex: insertionIndex
        )
    }

    /// Previews a pane-body destination and returns the zone that should be
    /// drawn. A cross-type center drop is represented as the bottom split it
    /// will actually commit, keeping feedback and mutation identical.
    @discardableResult
    func previewPaneDrop(
        destinationPaneID: PaneID,
        proposedZone: PaneDropZone
    ) -> PaneDropZone? {
        guard let drag = activeDrag,
              let targetContent = root.content(for: destinationPaneID) else {
            tabDragCoordinator.clearPreview(destinationPaneID: destinationPaneID)
            return nil
        }

        let key = TabDragKey(drag)
        let intent: TabDropIntent
        let visualZone: PaneDropZone
        if proposedZone == .center {
            if drag.contentType == targetContent {
                intent = .merge(drag: key, destinationPaneID: destinationPaneID)
                visualZone = .center
            } else {
                intent = .leafSplit(
                    drag: key,
                    destinationPaneID: destinationPaneID,
                    zone: .bottom
                )
                visualZone = .bottom
            }
        } else {
            intent = .leafSplit(
                drag: key,
                destinationPaneID: destinationPaneID,
                zone: proposedZone
            )
            visualZone = proposedZone
        }

        return tabDragCoordinator.preview(intent) ? visualZone : nil
    }

    @discardableResult
    func previewRootDrop(zone: RootDropZone) -> Bool {
        guard let drag = activeDrag else { return false }
        return tabDragCoordinator.preview(.rootSplit(drag: TabDragKey(drag), zone: zone))
    }

    private func bindTabDragCoordinator(_ coordinator: TabDragCoordinator) {
        coordinator.validateIntent = { [weak self] intent in
            self?.canCommitTabDrop(intent) == true
        }
        coordinator.commitIntent = { [weak self] intent in
            self?.commitTabDrop(intent) == true
        }
    }

    private func canCommitTabDrop(_ intent: TabDropIntent) -> Bool {
        let key = intent.drag
        guard root.content(for: key.sourcePaneID) == key.contentType,
              sourceContainsDraggedTab(key) else { return false }

        switch intent {
        case .reorder(_, let destinationPaneID, let insertionIndex):
            guard destinationPaneID == key.sourcePaneID,
                  root.content(for: destinationPaneID) == key.contentType else { return false }
            if key.contentType == .editor {
                return tabManagers[destinationPaneID]?
                    .canMoveTab(id: key.tabID, toInsertionIndex: insertionIndex)
                    .accepted == true
            }
            return terminalStates[destinationPaneID]?
                .canMoveTab(id: key.tabID, toInsertionIndex: insertionIndex)
                .accepted == true

        case .insert(_, let destinationPaneID, let insertionIndex):
            guard !isMaximized,
                  destinationPaneID != key.sourcePaneID,
                  root.content(for: destinationPaneID) == key.contentType else { return false }
            if key.contentType == .editor {
                guard let tab = tabManagers[key.sourcePaneID]?.tabs
                    .first(where: { $0.id == key.tabID }) else { return false }
                return tabManagers[destinationPaneID]?
                    .canInsertTransferredTab(tab, at: insertionIndex) == true
            }
            guard let destination = terminalStates[destinationPaneID] else { return false }
            return (0...destination.terminalTabs.count).contains(insertionIndex)
                && !destination.terminalTabs.contains(where: { $0.id == key.tabID })

        case .merge(_, let destinationPaneID):
            guard !isMaximized,
                  destinationPaneID != key.sourcePaneID,
                  root.content(for: destinationPaneID) == key.contentType else { return false }
            if key.contentType == .editor {
                guard let tab = tabManagers[key.sourcePaneID]?.tabs
                    .first(where: { $0.id == key.tabID }) else { return false }
                let destination = tabManagers[destinationPaneID]
                let index = tab.isPinned
                    ? destination?.pinnedTabCount
                    : destination?.tabs.count
                guard let destination, let index else { return false }
                return destination.canInsertTransferredTab(tab, at: index)
            }
            return terminalStates[destinationPaneID]?
                .terminalTabs.contains(where: { $0.id == key.tabID }) == false

        case .leafSplit(_, let destinationPaneID, let zone):
            return !isMaximized
                && zone != .center
                && root.content(for: destinationPaneID) != nil

        case .rootSplit:
            return !isMaximized
                && root.leafCount > 1
                && key.contentType == .terminal
        }
    }

    private func sourceContainsDraggedTab(_ key: TabDragKey) -> Bool {
        if key.contentType == .editor {
            return tabManagers[key.sourcePaneID]?.tabs
                .contains(where: { $0.id == key.tabID }) == true
        }
        return terminalStates[key.sourcePaneID]?.terminalTabs
            .contains(where: { $0.id == key.tabID }) == true
    }

    private func commitTabDrop(_ intent: TabDropIntent) -> Bool {
        guard canCommitTabDrop(intent) else { return false }
        let key = intent.drag

        switch intent {
        case .reorder(_, let destinationPaneID, let insertionIndex):
            let result: TabInsertionResult
            if key.contentType == .editor {
                result = tabManagers[destinationPaneID]?.moveTab(
                    id: key.tabID,
                    toInsertionIndex: insertionIndex
                ) ?? .rejected
            } else {
                result = terminalStates[destinationPaneID]?.moveTab(
                    id: key.tabID,
                    toInsertionIndex: insertionIndex
                ) ?? .rejected
            }
            if result.accepted {
                activePaneID = destinationPaneID
            }
            return result.accepted

        case .insert(_, let destinationPaneID, let insertionIndex):
            if key.contentType == .editor {
                return moveTabBetweenPanes(
                    tabID: key.tabID,
                    from: key.sourcePaneID,
                    to: destinationPaneID,
                    at: insertionIndex
                )
            }
            return moveTerminalTab(
                key.tabID,
                from: key.sourcePaneID,
                to: destinationPaneID,
                at: insertionIndex
            )

        case .merge(_, let destinationPaneID):
            if key.contentType == .editor {
                return moveTabBetweenPanes(
                    tabID: key.tabID,
                    from: key.sourcePaneID,
                    to: destinationPaneID
                )
            }
            return moveTerminalTab(key.tabID, from: key.sourcePaneID, to: destinationPaneID)

        case .leafSplit(_, let destinationPaneID, let zone):
            let axis: SplitAxis = (zone == .left || zone == .right)
                ? .horizontal
                : .vertical
            let insertBefore = zone == .left || zone == .top
            if key.contentType == .editor {
                guard let tab = tabManagers[key.sourcePaneID]?.tabs
                    .first(where: { $0.id == key.tabID }) else { return false }
                return splitPane(
                    destinationPaneID,
                    axis: axis,
                    tabID: key.tabID,
                    tabURL: tab.fileURL,
                    sourcePane: key.sourcePaneID,
                    insertBefore: insertBefore
                ) != nil
            }
            return splitAndMoveTerminalTab(
                tabID: key.tabID,
                from: key.sourcePaneID,
                relativeTo: destinationPaneID,
                axis: axis,
                insertBefore: insertBefore
            ) != nil

        case .rootSplit(_, let zone):
            return wrapRootWithTerminal(
                at: zone,
                from: key.sourcePaneID,
                tabID: key.tabID
            )
        }
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
                return moveTerminalTab(dragInfo.tabID, from: sourcePaneID, to: targetPaneID)
            } else if let fileURL = dragInfo.fileURL {
                return moveTabBetweenPanes(
                    tabID: dragInfo.tabID,
                    tabURL: fileURL,
                    from: sourcePaneID,
                    to: targetPaneID
                )
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
            let newID = splitPane(
                targetPaneID,
                axis: .vertical,
                tabID: dragInfo.tabID,
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

    /// Applies the terminal result of a file open to pane-level state. This is
    /// the only place async large-file opens acquire pane focus and MRU
    /// position, matching the synchronous open path.
    private func finishFileOpen(
        _ result: TabManager.OpenRequestResult,
        in tabManager: TabManager,
        paneID: PaneID,
        requestFocus: Bool,
        previousActivePaneID: PaneID? = nil,
        removeEmptyDestinationOnCancel: Bool = false
    ) {
        switch result {
        case .opened(let tabID):
            guard tabManagers[paneID] === tabManager else { return }
            selectEditorTab(tabID, in: paneID, requestFocus: requestFocus)
        case .cancelled:
            if removeEmptyDestinationOnCancel,
               tabManagers[paneID] === tabManager,
               tabManager.tabs.isEmpty,
               root.leafCount > 1 {
                removePane(paneID)
            }
            if let previousActivePaneID,
               root.content(for: previousActivePaneID) != nil {
                activePaneID = previousActivePaneID
            }
        case .pending:
            // Completions are terminal; retaining this case makes the shared
            // result type exhaustive if a future presenter changes behavior.
            break
        }
    }

    private func makeEditorTabManager(for paneID: PaneID) -> TabManager {
        let tabManager = TabManager()
        configureEditorTabManager?(tabManager)
        trackEditorActivations(in: tabManager, paneID: paneID)
        return tabManager
    }

    private func makeTerminalPaneState(for paneID: PaneID) -> TerminalPaneState {
        let terminalState = TerminalPaneState()
        terminalState.onTabCreated = configureTerminalTab
        trackTerminalActivations(in: terminalState, paneID: paneID)
        return terminalState
    }

    private func trackEditorActivations(in tabManager: TabManager, paneID: PaneID) {
        tabManager.onActiveTabChanged = { [weak self, weak tabManager] tabID in
            guard let self,
                  let tabManager,
                  self.tabManagers[paneID] === tabManager,
                  !self.isPerformingGlobalTabSwitch,
                  let tabID else { return }
            self.recordTabActivation(
                paneID: paneID,
                tabID: tabID,
                contentType: .editor
            )
        }
        tabManager.onTabInventoryChanged = { [weak self, weak tabManager] in
            guard let self,
                  let tabManager,
                  self.tabManagers[paneID] === tabManager else { return }
            self.reconcileGlobalTabSwitcherAfterInventoryChange()
        }
    }

    private func trackTerminalActivations(
        in terminalState: TerminalPaneState,
        paneID: PaneID
    ) {
        terminalState.onActiveTabChanged = { [weak self, weak terminalState] tabID in
            guard let self,
                  let terminalState,
                  self.terminalStates[paneID] === terminalState,
                  !self.isPerformingGlobalTabSwitch,
                  let tabID else { return }
            self.recordTabActivation(
                paneID: paneID,
                tabID: tabID,
                contentType: .terminal
            )
        }
        terminalState.onTabInventoryChanged = { [weak self, weak terminalState] in
            guard let self,
                  let terminalState,
                  self.terminalStates[paneID] === terminalState else { return }
            self.reconcileGlobalTabSwitcherAfterInventoryChange()
        }
    }

    private func resolvedEditorTabID(tabID: UUID?, url: URL?, in source: TabManager) -> UUID? {
        if let tabID {
            return source.tabs.contains(where: { $0.id == tabID }) ? tabID : nil
        }
        guard let url else { return nil }
        return source.tabs.first(where: { $0.fileURL == url })?.id
            ?? source.tabs.first(where: {
                $0.fileURL?.standardizedFileURL
                    == url.standardizedFileURL
            })?.id
    }

    private func transferEditorTab(
        tabID: UUID?,
        url: URL?,
        from sourceID: PaneID,
        to targetID: PaneID,
        insertionIndex: Int? = nil
    ) -> Bool {
        guard sourceID != targetID,
              let source = tabManagers[sourceID],
              let destination = tabManagers[targetID],
              let resolvedTabID = resolvedEditorTabID(tabID: tabID, url: url, in: source),
              let tab = source.tabs.first(where: { $0.id == resolvedTabID }) else { return false }

        let resolvedInsertionIndex = insertionIndex
            ?? (tab.isPinned ? destination.pinnedTabCount : destination.tabs.count)
        guard destination.canInsertTransferredTab(tab, at: resolvedInsertionIndex),
              let extraction = source.extractTab(id: resolvedTabID) else { return false }

        guard destination.insertTransferredTab(extraction, at: resolvedInsertionIndex) else {
            source.restoreExtractedTab(extraction)
            return false
        }

        activePaneID = targetID
        destination.onEditorContextChanged?()
        pruneEmptyEditorLeaves()
        recordTabActivation(paneID: targetID, tabID: resolvedTabID, contentType: .editor)
        return true
    }
}
