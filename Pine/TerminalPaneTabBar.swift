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
    @State private var draggingTabID: UUID?
    @State private var hoverTargetTabID: UUID?

    private func closeTerminalTabWithConfirmation(_ tab: TerminalTab) {
        if tab.hasForegroundProcess {
            let alert = NSAlert()
            alert.messageText = Strings.terminalTabCloseWarningTitle
            alert.informativeText = Strings.terminalTabCloseWarningMessage
            alert.addButton(withTitle: Strings.terminalTabCloseWarningClose)
            alert.addButton(withTitle: Strings.dialogCancel)
            alert.alertStyle = .warning

            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
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
                        let isDragged = tab.id == draggingTabID
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
                            draggingTabID = tab.id
                            let info = TabDragInfo(
                                paneID: paneID.id,
                                tabID: tab.id,
                                fileURL: URL(filePath: "/terminal-placeholder"),
                                contentType: .terminal
                            )
                            paneManager.activeDrag = info
                            let provider = NSItemProvider()
                            provider.registerDataRepresentation(
                                forTypeIdentifier: UTType.paneTabDrag.identifier,
                                visibility: .ownProcess
                            ) { completion in
                                let data = info.encoded.data(using: .utf8) ?? Data()
                                completion(data, nil)
                                return nil
                            }
                            return provider
                        }
                        .onDrop(of: [.paneTabDrag], delegate: TerminalTabDropDelegate(
                            terminalState: terminalState,
                            targetTabID: tab.id,
                            draggingTabID: $draggingTabID,
                            hoverTargetTabID: $hoverTargetTabID
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
                if terminalState.terminalTabs.contains(where: { $0.hasForegroundProcess }) {
                    let alert = NSAlert()
                    alert.messageText = Strings.terminalTabCloseWarningTitle
                    alert.informativeText = Strings.terminalTabCloseWarningMessage
                    alert.addButton(withTitle: Strings.terminalTabCloseWarningClose)
                    alert.addButton(withTitle: Strings.dialogCancel)
                    alert.alertStyle = .warning
                    guard alert.runModal() == .alertFirstButtonReturn else { return }
                }
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
        .frame(height: 30)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.terminalTabBar)
    }
}

/// Handles drag-to-reorder for terminal tabs within a pane.
struct TerminalTabDropDelegate: DropDelegate {
    let terminalState: TerminalPaneState
    let targetTabID: UUID
    @Binding var draggingTabID: UUID?
    @Binding var hoverTargetTabID: UUID?

    private static let reorderAnimation: Animation = .spring(response: 0.3, dampingFraction: 0.8)

    func performDrop(info: DropInfo) -> Bool {
        withAnimation(Self.reorderAnimation) {
            hoverTargetTabID = nil
            draggingTabID = nil
        }
        return true
    }

    func dropEntered(info: DropInfo) {
        guard let dragging = draggingTabID, dragging != targetTabID else { return }
        hoverTargetTabID = targetTabID
        withAnimation(Self.reorderAnimation) {
            terminalState.reorderTab(draggedID: dragging, targetID: targetTabID)
        }
    }

    func dropExited(info: DropInfo) {
        hoverTargetTabID = nil
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}
