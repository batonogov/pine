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
    @State private var tabFrames: [UUID: CGRect] = [:]

    private var coordinateSpaceName: String { "terminal-tab-strip-\(paneID.id.uuidString)" }

    private var insertionIndicatorX: CGFloat? {
        guard let intent = paneManager.tabDragCoordinator.previewIntent,
              intent.destinationPaneID == paneID,
              intent.drag.contentType == .terminal,
              let insertionIndex = intent.insertionIndex else { return nil }
        return TabStripInsertionGeometry.indicatorX(
            for: insertionIndex,
            orderedTabIDs: terminalState.terminalTabs.map(\.id),
            frames: tabFrames
        )
    }

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
                                    paneManager.selectTerminalTab(tab.id, in: paneID)
                                },
                                onClose: { closeTerminalTabWithConfirmation(tab) }
                            )
                            .opacity(isDragged ? 0.4 : 1.0)
                            .scaleEffect(isDragged ? 0.95 : 1.0)
                            .transaction { $0.animation = nil }
                            .reportTabStripFrame(
                                tabID: tab.id,
                                coordinateSpace: coordinateSpaceName
                            )
                            .onDrag {
                                let info = paneManager.beginTabDrag(
                                    paneID: paneID,
                                    tabID: tab.id,
                                    fileURL: nil,
                                    contentType: .terminal
                                )
                                return info.itemProvider()
                            }
                        }
                    }
                    .padding(.horizontal, 4)
                }

                // New terminal tab button
                Button {
                    paneManager.addTerminalTab(
                        in: paneID,
                        workingDirectory: workingDirectory
                    )
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
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .coordinateSpace(name: coordinateSpaceName)
            .onPreferenceChange(TabStripFramePreferenceKey.self) { tabFrames = $0 }
            .overlay(alignment: .topLeading) {
                if let insertionIndicatorX {
                    TabInsertionIndicator(x: insertionIndicatorX)
                }
            }
            .onDrop(of: [.paneTabDrag], delegate: TabStripDropDelegate(
                paneID: paneID,
                contentType: .terminal,
                orderedTabIDs: terminalState.terminalTabs.map(\.id),
                frames: tabFrames,
                paneManager: paneManager
            ))

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
