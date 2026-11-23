//
//  PaneManager.swift
//  Pine
//
//  Owns the single editor destination and its optional adjacent terminal.
//

import SwiftUI

/// Identities from a legacy free-form layout mapped into the fixed workspace.
struct PaneLayoutMigration {
    let editorPaneID: PaneID
    let editorSourcePaneIDs: [PaneID]
    let terminalPaneID: PaneID?
    let terminalSourcePaneIDs: [PaneID]
    let activePaneID: PaneID
}

@MainActor
@Observable
final class PaneManager {
    private(set) var root: PaneNode
    private(set) var tabManagers: [PaneID: TabManager]
    private(set) var terminalStates: [PaneID: TerminalPaneState] = [:]

    private var editorPaneID: PaneID
    private var terminalPaneID: PaneID?
    private var showsEditor = true
    private var editorToTerminalRatio: CGFloat = 0.6

    var activePaneID: PaneID
    private(set) var maximizedPaneID: PaneID?

    var isMaximized: Bool { maximizedPaneID != nil }

    /// The fixed layout, including content hidden only by terminal zoom.
    var persistableRoot: PaneNode { layoutRoot(ignoringMaximize: true) }

    var configureEditorTabManager: ((TabManager) -> Void)? {
        didSet {
            guard let configureEditorTabManager else { return }
            tabManagers.values.forEach(configureEditorTabManager)
        }
    }

    var configureTerminalTab: ((TerminalTab) -> Void)? {
        didSet {
            guard let configureTerminalTab else { return }
            allTerminalTabs.forEach(configureTerminalTab)
            terminalStates.values.forEach {
                $0.onTabCreated = configureTerminalTab
            }
        }
    }

    /// Retained for value-only terminal route publication by the coordinator.
    var terminalTabDidMove: ((TerminalTab, PaneID) -> Void)?
    var terminalTabDidActivate: ((PaneID, UUID) -> Void)?
    var terminalPaneInventoryDidChange: (() -> Void)?

    private var isSuppressingTerminalActivationCallback = false

    init() {
        let editorPaneID = PaneID()
        self.editorPaneID = editorPaneID
        self.activePaneID = editorPaneID
        self.root = .leaf(editorPaneID, .editor)
        self.tabManagers = [editorPaneID: TabManager()]
    }

    init(existingTabManager: TabManager) {
        let editorPaneID = PaneID()
        self.editorPaneID = editorPaneID
        self.activePaneID = editorPaneID
        self.root = .leaf(editorPaneID, .editor)
        self.tabManagers = [editorPaneID: existingTabManager]
    }

    private func layoutRoot(ignoringMaximize: Bool) -> PaneNode {
        if !ignoringMaximize, maximizedPaneID != nil, let terminalPaneID {
            return .leaf(terminalPaneID, .terminal)
        }
        let editor = PaneNode.leaf(editorPaneID, .editor)
        guard let terminalPaneID else { return editor }
        let terminal = PaneNode.leaf(terminalPaneID, .terminal)
        guard showsEditor else { return terminal }
        return .split(
            .vertical,
            first: editor,
            second: terminal,
            ratio: editorToTerminalRatio
        )
    }

    private func rebuildRoot() {
        root = layoutRoot(ignoringMaximize: false)
    }

    func tabManager(for paneID: PaneID) -> TabManager? {
        tabManagers[paneID]
    }

    var activeTabManager: TabManager? {
        tabManagers[activePaneID]
    }

    var activeEditorTabManager: TabManager? {
        activeTabManager ?? tabManagers[editorPaneID]
    }

    var allTabManagers: [TabManager] {
        Array(tabManagers.values)
    }

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
        tabManager.pendingFocusTabID = requestFocus ? tabID : nil
        return true
    }

    /// Hides an empty editor only while a terminal remains available.
    func pruneEmptyEditorLeaves() {
        guard terminalPaneID != nil,
              tabManagers[editorPaneID]?.tabs.isEmpty == true else { return }
        showsEditor = false
        if activePaneID == editorPaneID, let terminalPaneID {
            activePaneID = terminalPaneID
        }
        rebuildRoot()
    }

    @discardableResult
    func ensureEditorPane() -> TabManager {
        showsEditor = true
        activePaneID = editorPaneID
        rebuildRoot()
        guard let manager = tabManagers[editorPaneID] else {
            preconditionFailure("The fixed workspace must own its editor TabManager")
        }
        return manager
    }

    @discardableResult
    func openFileInActiveEditor(
        url: URL,
        asTransientPreview: Bool = false,
        requestFocus: Bool = true,
        completion: TabManager.OpenCompletion? = nil
    ) -> Bool {
        let previousActivePaneID = activePaneID
        let wasEditorVisible = root.content(for: editorPaneID) != nil
        let tabManager = ensureEditorPane()
        let completion: TabManager.OpenCompletion = { [weak self, weak tabManager] result in
            if let self, let tabManager {
                self.finishFileOpen(
                    result,
                    in: tabManager,
                    paneID: editorPaneID,
                    requestFocus: requestFocus,
                    previousActivePaneID: previousActivePaneID,
                    hideEditorOnCancel: !wasEditorVisible
                )
            }
            completion?(result)
        }
        let result = if asTransientPreview {
            tabManager.openTabAsPreview(url: url, completion: completion)
        } else {
            tabManager.openTab(url: url, completion: completion)
        }
        if result == .pending, root.content(for: previousActivePaneID) != nil {
            activePaneID = previousActivePaneID
        }
        return result.wasAccepted
    }

    /// Removes the terminal, or hides an empty editor while terminal content remains.
    func removePane(_ paneID: PaneID) {
        if paneID == terminalPaneID {
            terminalStates[paneID]?.terminalTabs.forEach { $0.stop() }
            terminalStates[paneID] = nil
            terminalPaneID = nil
            maximizedPaneID = nil
            showsEditor = true
            activePaneID = editorPaneID
            rebuildRoot()
            terminalPaneInventoryDidChange?()
            return
        }
        guard paneID == editorPaneID else { return }
        pruneEmptyEditorLeaves()
    }

    /// Resizes the one editor/terminal divider.
    func updateRatio(for paneID: PaneID, ratio: CGFloat) {
        guard paneID == editorPaneID || paneID == terminalPaneID else { return }
        editorToTerminalRatio = min(max(ratio, 0.1), 0.9)
        rebuildRoot()
    }

    func terminalState(for paneID: PaneID) -> TerminalPaneState? {
        terminalStates[paneID]
    }

    @discardableResult
    func selectTerminalTab(
        _ tabID: UUID,
        in paneID: PaneID,
        reportActivation: Bool = true
    ) -> Bool {
        guard let terminalState = terminalStates[paneID],
              terminalState.terminalTabs.contains(where: { $0.id == tabID }) else {
            return false
        }
        let activeTabChanged = terminalState.activeTerminalID != tabID
        activePaneID = paneID
        let previousSuppression = isSuppressingTerminalActivationCallback
        isSuppressingTerminalActivationCallback = !reportActivation
        terminalState.activeTerminalID = tabID
        isSuppressingTerminalActivationCallback = previousSuppression
        terminalState.pendingFocusTabID = tabID
        if reportActivation, !activeTabChanged {
            terminalTabDidActivate?(paneID, tabID)
        }
        return true
    }

    @discardableResult
    func activatePane(_ paneID: PaneID) -> Bool {
        switch root.content(for: paneID) {
        case .terminal:
            guard let tabID = terminalStates[paneID]?.activeTerminalID else {
                return false
            }
            return selectTerminalTab(tabID, in: paneID)
        case .editor:
            activePaneID = paneID
            return true
        case nil:
            return false
        }
    }

    // MARK: - Pointer-free local tab movement

    func canMoveActiveTab(_ action: TabMoveAction) -> Bool {
        guard let contentType = root.content(for: activePaneID) else { return false }
        let tabID = contentType == .editor
            ? tabManagers[activePaneID]?.activeTabID
            : terminalStates[activePaneID]?.activeTerminalID
        guard let tabID else { return false }
        return canMoveTab(
            tabID,
            from: activePaneID,
            contentType: contentType,
            action: action
        )
    }

    @discardableResult
    func moveActiveTab(_ action: TabMoveAction) -> Bool {
        guard let contentType = root.content(for: activePaneID) else { return false }
        let tabID = contentType == .editor
            ? tabManagers[activePaneID]?.activeTabID
            : terminalStates[activePaneID]?.activeTerminalID
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
        guard root.content(for: paneID) == contentType,
              let insertionIndex = adjacentInsertionIndex(
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
        ), let insertionIndex = adjacentInsertionIndex(
            tabID: tabID,
            paneID: paneID,
            contentType: contentType,
            action: action
        ) else { return false }

        let result: TabInsertionResult
        let terminalDidSetWillPublish: Bool
        switch contentType {
        case .editor:
            terminalDidSetWillPublish = false
            result = tabManagers[paneID]?.moveTab(
                id: tabID,
                toInsertionIndex: insertionIndex
            ) ?? .rejected
        case .terminal:
            terminalDidSetWillPublish = activePaneID == paneID
                && terminalStates[paneID]?.activeTerminalID != tabID
            result = terminalStates[paneID]?.moveTab(
                id: tabID,
                toInsertionIndex: insertionIndex
            ) ?? .rejected
        }
        guard result == .moved else { return false }
        activePaneID = paneID
        if contentType == .terminal, !terminalDidSetWillPublish {
            terminalTabDidActivate?(paneID, tabID)
        }
        return true
    }

    private func adjacentInsertionIndex(
        tabID: UUID,
        paneID: PaneID,
        contentType: PaneContent,
        action: TabMoveAction
    ) -> Int? {
        let ids = contentType == .editor
            ? tabManagers[paneID]?.tabs.map(\.id) ?? []
            : terminalStates[paneID]?.terminalTabs.map(\.id) ?? []
        guard let sourceIndex = ids.firstIndex(of: tabID) else { return nil }
        switch action {
        case .leading:
            return sourceIndex > 0 ? sourceIndex - 1 : nil
        case .trailing:
            return sourceIndex + 1 < ids.count ? sourceIndex + 2 : nil
        }
    }

    // MARK: - Adjacent terminal

    @discardableResult
    func addTerminalTab(
        in paneID: PaneID,
        workingDirectory: URL?,
        initialProcess: TerminalInitialProcess? = nil
    ) -> TerminalTab? {
        guard let terminalState = terminalStates[paneID] else { return nil }
        activePaneID = paneID
        return terminalState.addTab(
            workingDirectory: workingDirectory,
            initialProcess: initialProcess
        )
    }

    var terminalPaneIDs: [PaneID] {
        terminalPaneID.map { [$0] } ?? []
    }

    var visibleTerminalSearchPaneIDs: [PaneID] {
        terminalPaneIDs.filter {
            terminalStates[$0]?.isSearchVisible == true
        }
    }

    var allTerminalTabs: [TerminalTab] {
        terminalStates.values.flatMap(\.terminalTabs)
    }

    /// Creates the single full-width terminal below the editor, or reuses it.
    @discardableResult
    func createTerminalPaneAtBottom(
        workingDirectory: URL?,
        initialProcess: TerminalInitialProcess? = nil
    ) -> PaneID {
        if let terminalPaneID {
            activePaneID = terminalPaneID
            _ = addTerminalTab(
                in: terminalPaneID,
                workingDirectory: workingDirectory,
                initialProcess: initialProcess
            )
            return terminalPaneID
        }

        let newID = PaneID()
        terminalPaneID = newID
        let state = makeTerminalPaneState(for: newID)
        terminalStates[newID] = state
        activePaneID = newID
        state.addTab(
            workingDirectory: workingDirectory,
            initialProcess: initialProcess
        )
        rebuildRoot()
        terminalPaneInventoryDidChange?()
        return newID
    }

    // MARK: - Terminal zoom

    func maximize(paneID: PaneID) {
        guard maximizedPaneID == nil,
              paneID == terminalPaneID,
              showsEditor else { return }
        maximizedPaneID = paneID
        if let tabID = terminalStates[paneID]?.activeTerminalID {
            _ = selectTerminalTab(tabID, in: paneID)
        }
        rebuildRoot()
    }

    func restoreFromMaximize() {
        maximizedPaneID = nil
        rebuildRoot()
    }

    func toggleMaximizeOnActiveTerminalPane() {
        if isMaximized {
            restoreFromMaximize()
            return
        }
        guard terminalPaneIDs.contains(activePaneID) else { return }
        maximize(paneID: activePaneID)
    }

    // MARK: - Legacy session migration

    /// Collapses a legacy free-form tree into one editor and one terminal.
    /// Source IDs let the restorer merge every saved tab/session assignment.
    @discardableResult
    func restoreLayout(
        from node: PaneNode,
        activePaneUUID: UUID?
    ) -> PaneLayoutMigration? {
        let leafIDs = node.leafIDs
        guard !leafIDs.isEmpty,
              node.depth <= paneMaxDepth,
              Set(leafIDs).count == leafIDs.count else { return nil }

        let editorIDs = leafIDs.filter { node.content(for: $0) == .editor }
        let terminalIDs = leafIDs.filter { node.content(for: $0) == .terminal }
        let activeLegacyID = activePaneUUID.flatMap { uuid in
            leafIDs.first(where: { $0.id == uuid })
        }
        let selectedEditorID = activeLegacyID.flatMap { id in
            editorIDs.contains(id) ? id : nil
        } ?? editorIDs.first ?? PaneID()
        let selectedTerminalID = activeLegacyID.flatMap { id in
            terminalIDs.contains(id) ? id : nil
        } ?? terminalIDs.first
        let resolvedActivePaneID = activeLegacyID == selectedTerminalID
            ? selectedTerminalID
            : selectedEditorID

        guard let manager = tabManagers[editorPaneID] else { return nil }
        configureEditorTabManager?(manager)
        terminalStates.values.flatMap(\.terminalTabs).forEach { $0.stop() }

        editorPaneID = selectedEditorID
        tabManagers = [selectedEditorID: manager]
        terminalStates = [:]
        if let selectedTerminalID {
            terminalStates[selectedTerminalID] = makeTerminalPaneState(
                for: selectedTerminalID
            )
        }
        terminalPaneID = selectedTerminalID
        showsEditor = !editorIDs.isEmpty || selectedTerminalID == nil
        maximizedPaneID = nil
        activePaneID = resolvedActivePaneID ?? selectedEditorID
        rebuildRoot()
        terminalPaneInventoryDidChange?()

        let orderedEditorIDs = editorIDs.reduce(into: [PaneID]()) {
            if $1 == selectedEditorID {
                $0.insert($1, at: 0)
            } else if !$0.contains($1) {
                $0.append($1)
            }
        }
        let orderedTerminalIDs = ((selectedTerminalID.map { [$0] } ?? []) + terminalIDs)
            .reduce(into: [PaneID]()) {
                if !$0.contains($1) { $0.append($1) }
            }
        return PaneLayoutMigration(
            editorPaneID: selectedEditorID,
            editorSourcePaneIDs: orderedEditorIDs,
            terminalPaneID: selectedTerminalID,
            terminalSourcePaneIDs: orderedTerminalIDs,
            activePaneID: activePaneID
        )
    }

    func restoreActivePane(uuid: UUID?) {
        if let uuid, root.leafIDs.contains(where: { $0.id == uuid }) {
            activePaneID = PaneID(id: uuid)
        } else if !root.leafIDs.contains(activePaneID), let first = root.firstLeafID {
            activePaneID = first
        }
    }

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

    private func finishFileOpen(
        _ result: TabManager.OpenRequestResult,
        in tabManager: TabManager,
        paneID: PaneID,
        requestFocus: Bool,
        previousActivePaneID: PaneID? = nil,
        hideEditorOnCancel: Bool = false
    ) {
        switch result {
        case .opened(let tabID):
            guard tabManagers[paneID] === tabManager else { return }
            selectEditorTab(tabID, in: paneID, requestFocus: requestFocus)
        case .cancelled:
            if hideEditorOnCancel, tabManager.tabs.isEmpty, terminalPaneID != nil {
                showsEditor = false
                rebuildRoot()
            }
            if let previousActivePaneID,
               root.content(for: previousActivePaneID) != nil {
                activePaneID = previousActivePaneID
            }
        case .pending:
            break
        }
    }

    private func makeTerminalPaneState(for paneID: PaneID) -> TerminalPaneState {
        let terminalState = TerminalPaneState()
        terminalState.onTabCreated = configureTerminalTab
        trackTerminalActivations(in: terminalState, paneID: paneID)
        return terminalState
    }

    private func trackTerminalActivations(
        in terminalState: TerminalPaneState,
        paneID: PaneID
    ) {
        terminalState.onActiveTabChanged = { [weak self, weak terminalState] tabID in
            guard let self,
                  let terminalState,
                  self.terminalStates[paneID] === terminalState,
                  !self.isSuppressingTerminalActivationCallback,
                  let tabID,
                  self.activePaneID == paneID else { return }
            self.terminalTabDidActivate?(paneID, tabID)
        }
    }
}
