//
//  TerminalPaneTabBar.swift
//  Pine
//
//  Tab bar for a terminal pane with drag-and-drop support,
//  maximize/restore, and close-with-process confirmation.
//

import SwiftUI
import UniformTypeIdentifiers

struct TerminalPaneTabBar: View {
    let paneID: PaneID
    let terminalState: TerminalPaneState
    var workingDirectory: URL?
    @Environment(PaneManager.self) private var paneManager

    private func closeTerminalTabWithConfirmation(_ tab: TerminalTab) {
        guard TabCloseHelper.confirmTerminalProcessStop(tabs: [tab]) else { return }
        terminalState.removeTab(id: tab.id)
        // Remove the pane if no tabs remain
        if terminalState.terminalTabs.isEmpty {
            paneManager.removePane(paneID)
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(terminalState.terminalTabs) { tab in
                        let isActive = tab.id == terminalState.activeTerminalID
                        let isDragged = paneManager.activeDrag.map { drag in
                            drag.paneID == paneID.id
                                && drag.tabID == tab.id
                                && drag.contentType == .terminal
                        } ?? false
                        TerminalNativeTabItem(
                            tab: tab,
                            isActive: isActive,
                            canClose: true,
                            onSelect: {
                                terminalState.activeTerminalID = tab.id
                                terminalState.pendingFocusTabID = tab.id
                            },
                            onClose: { closeTerminalTabWithConfirmation(tab) }
                        )
                        .opacity(isDragged ? 0.4 : 1.0)
                        .scaleEffect(isDragged ? 0.95 : 1.0)
                        .transaction { $0.animation = nil }
                        .onDrag {
                            let info = TabDragInfo(
                                paneID: paneID.id,
                                tabID: tab.id,
                                fileURL: nil,
                                contentType: .terminal
                            )
                            paneManager.activeDrag = info
                            return info.itemProvider()
                        }
                        .onDrop(of: [.paneTabDrag], delegate: TerminalTabDropDelegate(
                            terminalState: terminalState,
                            targetTabID: tab.id,
                            targetPaneID: paneID,
                            paneManager: paneManager
                        ))
                    }
                }
                .padding(.horizontal, 4)
            }

            // New terminal tab button
            Button {
                terminalState.addTab(workingDirectory: workingDirectory)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help(Strings.newTerminal)
            .accessibilityIdentifier(AccessibilityID.newTerminalButton)
            .accessibilityAddTraits(.isButton)

            Spacer()

            // Maximize / restore terminal pane
            Button {
                withAnimation(PineAnimation.quick) {
                    if paneManager.isMaximized {
                        paneManager.restoreFromMaximize()
                    } else {
                        paneManager.maximize(paneID: paneID)
                    }
                }
            } label: {
                Image(systemName: paneManager.maximizedPaneID == paneID
                      ? "arrow.down.right.and.arrow.up.left"
                      : "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help(paneManager.maximizedPaneID == paneID
                  ? Strings.restoreTerminal : Strings.maximizeTerminal)
            .accessibilityIdentifier(AccessibilityID.maximizeTerminalButton)

            // Close terminal pane
            Button {
                // Warn if any tab has a foreground process
                guard TabCloseHelper.confirmTerminalProcessStop(
                    tabs: terminalState.terminalTabs
                ) else { return }
                // Stop all tabs and remove pane
                for tab in terminalState.terminalTabs {
                    tab.stop()
                }
                paneManager.removePane(paneID)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 4)
            .help(Strings.hideTerminal)
            .accessibilityIdentifier(AccessibilityID.hideTerminalButton)
        }
        .frame(height: LayoutMetrics.tabBarHeight)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.terminalTabBar)
    }
}

/// Handles drag-to-reorder for terminal tabs within a pane.
struct TerminalTabDropDelegate: DropDelegate {
    let terminalState: TerminalPaneState
    let targetTabID: UUID
    let targetPaneID: PaneID
    let paneManager: PaneManager

    private static let reorderAnimation: Animation = .spring(response: 0.3, dampingFraction: 0.8)

    func validateDrop(info: DropInfo) -> Bool {
        guard info.hasItemsConforming(to: [.paneTabDrag]) else { return false }
        guard case .localReorder = routingDecision() else { return false }
        return true
    }

    func performDrop(info: DropInfo) -> Bool {
        finishDrop(decision: routingDecision())
    }

    func dropEntered(info: DropInfo) {
        _ = handleDropEntered(decision: routingDecision())
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard case .localReorder = routingDecision() else { return nil }
        return DropProposal(operation: .move)
    }

    /// Returns whether this tab-local destination should reorder, defer to the
    /// surrounding pane, or reject the drag entirely.
    func routingDecision() -> TabItemDropDecision {
        TabItemDropRouter.decide(
            drag: paneManager.activeDrag,
            targetPaneID: targetPaneID,
            targetContent: .terminal
        )
    }

    /// Testable mutation seam for `dropEntered(info:)`.
    @discardableResult
    func handleDropEntered(decision: TabItemDropDecision) -> Bool {
        guard case .localReorder(let draggedTabID) = decision else { return false }
        guard draggedTabID != targetTabID else { return true }
        withAnimation(Self.reorderAnimation) {
            terminalState.reorderTab(draggedID: draggedTabID, targetID: targetTabID)
        }
        return true
    }

    /// Testable completion seam for `performDrop(info:)`.
    /// Deferred and rejected drops must leave the shared payload untouched so
    /// an ancestor pane destination can finish the operation.
    @discardableResult
    func finishDrop(decision: TabItemDropDecision) -> Bool {
        guard case .localReorder = decision else { return false }
        paneManager.activeDrag = nil
        return true
    }
}
