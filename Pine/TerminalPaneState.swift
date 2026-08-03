//
//  TerminalPaneState.swift
//  Pine
//
//  Per-pane terminal state. Each terminal leaf in the PaneNode tree
//  owns one TerminalPaneState managing its terminal tabs.
//

import SwiftUI

@MainActor
@Observable
final class TerminalPaneState {
    var terminalTabs: [TerminalTab] = []
    /// Theme source inherited by every tab created in this pane. Production
    /// uses the shared settings; injection keeps project and Quick Terminal
    /// repaint integration testable without touching global defaults.
    private let themeSettings: TerminalThemeSettings
    /// The AppKit host currently presenting this pane's active terminal.
    ///
    /// SwiftUI may temporarily keep outgoing and incoming representables
    /// alive during structural pane updates. A pane-wide lease prevents the
    /// stale host from reclaiming a newly selected tab after the incoming host
    /// has taken over. This is presentation plumbing, not observable state.
    @ObservationIgnored
    weak var presentationOwner: TerminalContainerView?
    var activeTerminalID: UUID? {
        didSet {
            guard activeTerminalID != oldValue else { return }
            if pendingFocusTabID != activeTerminalID {
                pendingFocusTabID = nil
            }
            onActiveTabChanged?(activeTerminalID)
        }
    }
    var pendingFocusTabID: UUID? {
        didSet {
            pendingFocusRequestID = pendingFocusTabID.map { _ in UUID() }
        }
    }
    /// Unique generation for the active request, preventing a stale AppKit
    /// completion from consuming a later request for the same terminal tab.
    private(set) var pendingFocusRequestID: UUID?
    var onActiveTabChanged: ((UUID?) -> Void)?
    /// Called after terminal identities are inserted or removed so a live
    /// global switcher can reconcile independently of SwiftUI rendering.
    var onTabInventoryChanged: (() -> Void)?
    /// Applies project-scoped lifecycle wiring to every newly created tab.
    var onTabCreated: ((TerminalTab) -> Void)?

    /// Monotonically increasing counter for unique terminal tab names.
    private var nextTabNumber = 1

    var isSearchVisible = false
    var terminalSearchQuery = ""
    var isSearchCaseSensitive = false

    var activeTab: TerminalTab? {
        guard let id = activeTerminalID else { return nil }
        return terminalTabs.first { $0.id == id }
    }

    var tabCount: Int { terminalTabs.count }

    init(themeSettings: TerminalThemeSettings = .shared) {
        self.themeSettings = themeSettings
    }

    /// Consumes the terminal result of a bounded AppKit focus request.
    ///
    /// Retryable lifecycle states stay inside `AppKitFocusRequestCoordinator`;
    /// `false` means the request was cancelled or exhausted.
    @discardableResult
    func acknowledgeFocusRequest(
        requestID: UUID,
        for tabID: UUID,
        succeeded: Bool
    ) -> Bool {
        guard pendingFocusTabID == tabID else { return false }
        guard pendingFocusRequestID == requestID else { return false }
        guard activeTerminalID == tabID else {
            pendingFocusTabID = nil
            return false
        }
        pendingFocusTabID = nil
        return succeeded
    }

    @discardableResult
    func addTab(workingDirectory: URL?) -> TerminalTab {
        let number = nextTabNumber
        nextTabNumber += 1
        let tab = TerminalTab(
            name: Strings.terminalNumberedName(number),
            themeSettings: themeSettings
        )
        tab.configure(workingDirectory: workingDirectory)
        onTabCreated?(tab)
        terminalTabs.append(tab)
        activeTerminalID = tab.id
        pendingFocusTabID = tab.id
        onTabInventoryChanged?()
        return tab
    }

    func removeTab(id: UUID) {
        guard let tab = terminalTabs.first(where: { $0.id == id }) else { return }
        tab.stop()
        terminalTabs.removeAll { $0.id == id }
        if activeTerminalID == id {
            activeTerminalID = terminalTabs.last?.id
        }
        onTabInventoryChanged?()
    }

    func reorderTab(draggedID: UUID, targetID: UUID) {
        guard draggedID != targetID,
              let fromIndex = terminalTabs.firstIndex(where: { $0.id == draggedID }),
              let toIndex = terminalTabs.firstIndex(where: { $0.id == targetID }) else { return }
        terminalTabs.move(
            fromOffsets: IndexSet(integer: fromIndex),
            toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex
        )
    }

    /// Moves a terminal tab to one of the strip's N+1 pre-removal gaps.
    func canMoveTab(id: UUID, toInsertionIndex insertionIndex: Int) -> TabInsertionResult {
        guard (0...terminalTabs.count).contains(insertionIndex),
              let sourceIndex = terminalTabs.firstIndex(where: { $0.id == id }) else {
            return .rejected
        }
        let destinationIndex = insertionIndex > sourceIndex
            ? insertionIndex - 1
            : insertionIndex
        return destinationIndex == sourceIndex ? .noOp : .moved
    }

    @discardableResult
    func moveTab(id: UUID, toInsertionIndex insertionIndex: Int) -> TabInsertionResult {
        let validation = canMoveTab(id: id, toInsertionIndex: insertionIndex)
        guard validation != .rejected,
              let sourceIndex = terminalTabs.firstIndex(where: { $0.id == id }) else {
            return .rejected
        }

        let destinationIndex = insertionIndex > sourceIndex
            ? insertionIndex - 1
            : insertionIndex
        guard validation == .moved else {
            activeTerminalID = id
            pendingFocusTabID = id
            return .noOp
        }

        let tab = terminalTabs.remove(at: sourceIndex)
        terminalTabs.insert(tab, at: destinationIndex)
        activeTerminalID = id
        pendingFocusTabID = id
        return .moved
    }

    func startTabs(workingDirectory: URL?) {
        for tab in terminalTabs {
            tab.configure(workingDirectory: workingDirectory)
        }
        if activeTerminalID == nil {
            activeTerminalID = terminalTabs.first?.id
        }
    }

}
