//
//  TerminalPaneTabBar.swift
//  Pine
//
//  Tab bar for a terminal pane with drag-and-drop support,
//  maximize/restore, and close-with-process confirmation.
//

import SwiftUI

struct TerminalPaneTabBar: View {
    let paneID: PaneID
    let terminalState: TerminalPaneState
    var workingDirectory: URL?
    @Environment(PaneManager.self) private var paneManager

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
                        TerminalNativeTabItem(
                            tab: tab,
                            isActive: tab.id == terminalState.activeTerminalID,
                            canClose: true,
                            onSelect: {
                                terminalState.activeTerminalID = tab.id
                                terminalState.pendingFocusTabID = tab.id
                            },
                            onClose: { closeTerminalTabWithConfirmation(tab) }
                        )
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
    }
}
