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
    var projectManager: ProjectManager? = nil
    @Environment(PaneManager.self) private var paneManager
    @Environment(ProjectRegistry.self) private var projectRegistry
    @State private var tabFrames: [UUID: CGRect] = [:]
    @State private var autoScrollSession = TabStripAutoScrollSession()

    private var coordinateSpaceName: String { "terminal-tab-strip-\(paneID.id.uuidString)" }

    private var activeAutoScrollOwner: TabStripAutoScrollOwner? {
        TabStripAutoScrollOwner.current(
            activeDrag: paneManager.activeDrag,
            previewIntent: paneManager.tabDragCoordinator.previewIntent
        )
    }

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
        let project = projectManager
        Task { @MainActor in
            // Resolve the owner inside the task, resilient to a transiently-
            // nil weak anchor during SwiftUI scene restoration (#1335 H3).
            let context = await TabCloseHelper.terminalCloseContext(for: project)
            guard await TabCloseHelper.confirmTerminalProcessStop(
                tabs: [tab],
                context: context
            ) else { return }
            guard let currentTab = terminalState.terminalTabs.first(where: {
                $0.id == tab.id
            }), currentTab === tab else {
                return
            }
            terminalState.removeTab(id: tab.id)
            // Remove the pane if no tabs remain
            if terminalState.terminalTabs.isEmpty {
                paneManager.removePane(paneID)
            }
        }
    }

    private func agentResumeActions(
        for tab: TerminalTab
    ) -> [TerminalAgentResumeAction] {
        guard let projectManager,
              let projectURL = projectManager.rootURL else { return [] }
        return projectRegistry.agentTasks.tasks.compactMap { task in
            guard projectRegistry.agentTasks.canResumeTask(task.id),
                  task.project.canonicalWorktreePath == projectURL.path,
                  let command = task.descriptor.launchExecutable else {
                return nil
            }
            let taskID = task.id
            let displayName = task.descriptor.agentType.displayName
            let created = task.createdAt.formatted(
                date: .abbreviated,
                time: .shortened
            )
            let context = task.title ?? task.objective ?? created
            let suffix = "\(context) · \(taskID.uuidString.prefix(8))"
            return TerminalAgentResumeAction(
                id: taskID,
                title: "\(displayName) — \(suffix)"
            ) {
                Task { @MainActor in
                    guard let route = await projectRegistry.resolveAgentTaskRoute(
                        taskID,
                        targetTerminalID: tab.id
                    ),
                    route.terminalID == tab.id else {
                        return
                    }
                    _ = await projectManager.terminal.resumeAgentTaskCommand(
                        taskID: taskID,
                        command: command,
                        in: tab
                    )
                }
            }
        }
    }

    private func dropDelegate(
        orderedTabIDs: [UUID],
        frames: [UUID: CGRect],
        viewportWidth: CGFloat
    ) -> TabStripDropDelegate {
        TabStripDropDelegate(
            paneID: paneID,
            contentType: .terminal,
            orderedTabIDs: orderedTabIDs,
            frames: frames,
            paneManager: paneManager,
            onHover: { dragID, locationX in
                autoScrollSession.updateHover(
                    owner: TabStripAutoScrollOwner(
                        dragID: dragID,
                        destinationPaneID: paneID.id
                    ),
                    locationX: locationX,
                    viewportWidth: viewportWidth,
                    orderedTabIDs: orderedTabIDs,
                    frames: frames
                )
            },
            onExit: {
                autoScrollSession.end()
            }
        )
    }

    private func refreshPreviewAfterGeometryChange(
        orderedTabIDs: [UUID],
        frames: [UUID: CGRect],
        viewportWidth: CGFloat
    ) {
        guard let locationX = autoScrollSession.hoverLocationX,
              autoScrollSession.hoveredOwner == activeAutoScrollOwner else {
            autoScrollSession.end()
            return
        }
        _ = dropDelegate(
            orderedTabIDs: orderedTabIDs,
            frames: frames,
            viewportWidth: viewportWidth
        ).preview(atX: locationX)
    }

    private func runAutoScroll(
        request: TabStripAutoScrollRequest,
        proxy: ScrollViewProxy
    ) async {
        while !Task.isCancelled {
            guard autoScrollSession.request == request,
                  activeAutoScrollOwner == request.owner,
                  let targetID = autoScrollSession.targetID else {
                return
            }
            proxy.scrollTo(
                targetID,
                anchor: request.direction == .leading ? .leading : .trailing
            )
            do {
                try await Task.sleep(for: TabStripAutoScrollGeometry.stepDelay)
            } catch {
                return
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 0) {
                GeometryReader { geometry in
                    ScrollViewReader { proxy in
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
                                            _ = projectManager?.terminal.activateTerminal(
                                                paneID: paneID,
                                                tabID: tab.id
                                            )
                                        },
                                        onClose: { closeTerminalTabWithConfirmation(tab) },
                                        onMoveLeading: paneManager.canMoveTab(
                                            tab.id,
                                            from: paneID,
                                            contentType: .terminal,
                                            action: .leading
                                        ) ? {
                                            paneManager.moveTab(
                                                tab.id,
                                                from: paneID,
                                                contentType: .terminal,
                                                action: .leading
                                            )
                                        } : nil,
                                        onMoveTrailing: paneManager.canMoveTab(
                                            tab.id,
                                            from: paneID,
                                            contentType: .terminal,
                                            action: .trailing
                                        ) ? {
                                            paneManager.moveTab(
                                                tab.id,
                                                from: paneID,
                                                contentType: .terminal,
                                                action: .trailing
                                            )
                                        } : nil,
                                        onMoveToPreviousPane: paneManager.canMoveTab(
                                            tab.id,
                                            from: paneID,
                                            contentType: .terminal,
                                            action: .previousPane
                                        ) ? {
                                            paneManager.moveTab(
                                                tab.id,
                                                from: paneID,
                                                contentType: .terminal,
                                                action: .previousPane
                                            )
                                        } : nil,
                                        onMoveToNextPane: paneManager.canMoveTab(
                                            tab.id,
                                            from: paneID,
                                            contentType: .terminal,
                                            action: .nextPane
                                        ) ? {
                                            paneManager.moveTab(
                                                tab.id,
                                                from: paneID,
                                                contentType: .terminal,
                                                action: .nextPane
                                            )
                                        } : nil,
                                        agentResumeActions: agentResumeActions(
                                            for: tab
                                        )
                                    )
                                    .opacity(isDragged ? 0.4 : 1.0)
                                    .scaleEffect(isDragged ? 0.95 : 1.0)
                                    .transaction { $0.animation = nil }
                                    .id(tab.id)
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
                        .frame(maxHeight: .infinity, alignment: .center)
                        .contentShape(Rectangle())
                        .coordinateSpace(name: coordinateSpaceName)
                        .onPreferenceChange(TabStripFramePreferenceKey.self) { frames in
                            let orderedTabIDs = terminalState.terminalTabs.map(\.id)
                            tabFrames = frames
                            autoScrollSession.updateGeometry(
                                viewportWidth: geometry.size.width,
                                orderedTabIDs: orderedTabIDs,
                                frames: frames
                            )
                            refreshPreviewAfterGeometryChange(
                                orderedTabIDs: orderedTabIDs,
                                frames: frames,
                                viewportWidth: geometry.size.width
                            )
                        }
                        .overlay(alignment: .topLeading) {
                            if let insertionIndicatorX {
                                TabInsertionIndicator(x: insertionIndicatorX)
                            }
                        }
                        .onDrop(of: [.paneTabDrag], delegate: dropDelegate(
                            orderedTabIDs: terminalState.terminalTabs.map(\.id),
                            frames: tabFrames,
                            viewportWidth: geometry.size.width
                        ))
                        .task(id: autoScrollSession.request) {
                            guard let request = autoScrollSession.request else { return }
                            await runAutoScroll(request: request, proxy: proxy)
                        }
                        .onAppear {
                            if let activeID = terminalState.activeTerminalID {
                                proxy.scrollTo(activeID, anchor: .center)
                            }
                        }
                        .onDisappear {
                            autoScrollSession.end()
                        }
                        .onChange(of: geometry.size.width) { _, width in
                            let orderedTabIDs = terminalState.terminalTabs.map(\.id)
                            autoScrollSession.updateGeometry(
                                viewportWidth: width,
                                orderedTabIDs: orderedTabIDs,
                                frames: tabFrames
                            )
                            refreshPreviewAfterGeometryChange(
                                orderedTabIDs: orderedTabIDs,
                                frames: tabFrames,
                                viewportWidth: width
                            )
                        }
                        .onChange(of: activeAutoScrollOwner) { _, owner in
                            autoScrollSession.activeOwnerDidChange(to: owner)
                        }
                        .onChange(of: terminalState.activeTerminalID) {
                            guard let activeID = terminalState.activeTerminalID else { return }
                            proxy.scrollTo(activeID, anchor: .center)
                        }
                    }
                }

                // New terminal tab button
                Button {
                    _ = projectManager?.terminal.createTerminalTab(
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
                .accessibilityLabel(Strings.newTerminal)
                .accessibilityAddTraits(.isButton)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Maximize / restore terminal pane
            Button {
                // This structurally replaces the pane tree while preserving a
                // model-owned AppKit terminal view. An animated transition
                // keeps the outgoing and incoming representables alive at
                // once, so both can contend for the single NSView. Swap
                // atomically; the native terminal surface remains continuous.
                if paneManager.isMaximized {
                    paneManager.restoreFromMaximize()
                } else {
                    paneManager.maximize(paneID: paneID)
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
            .accessibilityLabel(
                paneManager.maximizedPaneID == paneID
                    ? Strings.restoreTerminal
                    : Strings.maximizeTerminal
            )

            // Close terminal pane
            Button {
                // Warn if any tab has a foreground process (window-scoped sheet, #1241)
                let targetTabs = terminalState.terminalTabs
                let targetTabIDs = Set(targetTabs.map(\.id))
                Task { @MainActor in
                    // Resolve the owner resiliently (#1335 H3): a
                    // transiently-nil weak anchor during scene restoration
                    // must not silently abort the close.
                    let context = await TabCloseHelper.terminalCloseContext(
                        for: projectManager
                    )
                    guard await TabCloseHelper.confirmTerminalProcessStop(
                        tabs: targetTabs,
                        context: context
                    ) else { return }
                    // `confirmTerminalProcessStop` already revalidates process
                    // coverage through the stable-identity authorization.
                    // Re-checking a volatile pgid here silently discarded the
                    // user's confirmation whenever an agent spawned a child
                    // (#1348); only the tab composition still needs a guard.
                    let currentTabs = terminalState.terminalTabs
                    let currentTabIDs = Set(currentTabs.map(\.id))
                    guard currentTabIDs.isSubset(of: targetTabIDs) else {
                        return
                    }
                    // Stop all tabs and remove pane
                    for tab in currentTabs {
                        tab.stop()
                    }
                    paneManager.removePane(paneID)
                }
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
