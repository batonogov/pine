//
//  CommandOverlayContainer.swift
//  Pine
//
//  Single SwiftUI overlay modifier that renders whichever command overlay the
//  router reports as active (#975). Installed once per project window — this
//  is the shared container all command flows route through.
//
//  Only one overlay is ever mounted at a time because the router holds a single
//  `activePresentation` value; switching to a different case replaces the
//  mounted view (and its @State) deterministically.
//

import SwiftUI

/// View modifier that observes a `CommandOverlayRouter` and presents its active
/// flow inside a `CommandOverlayWindow` panel.
struct CommandOverlayContainer: ViewModifier {

    let router: CommandOverlayRouter
    let projectManager: ProjectManager
    /// The window session behind this project scene. Optional because the
    /// modifier is also reachable from hosted tests and previews, where no
    /// session is installed; a missing one simply reports that this window can
    /// neither start an agent nor switch project (#1525).
    @Environment(ProjectWindowSession.self) private var windowSession:
        ProjectWindowSession?

    func body(content: Content) -> some View {
        content
            .background {
                overlayWindow
                    .frame(width: 0, height: 0)
                    .opacity(0)
            }
    }

    /// The window-backed overlay. Hidden as a background so it never affects
    /// the document layout — the actual panel floats above the window.
    @ViewBuilder
    private var overlayWindow: some View {
        if let presentation = router.activePresentation {
            CommandOverlayWindow(
                isPresented: Binding(
                    get: { router.activePresentation != nil },
                    set: { newValue in
                        if !newValue {
                            router.dismiss(ifMatching: presentation)
                        }
                    }
                ),
                containerIdentifier: presentation.containerIdentifier,
                onDocumentOwnerResolved: { ownerWindow in
                    router.preparePresentation(in: ownerWindow)
                },
                onExternalFocusChange: {
                    router.dismissForExternalFocusChange(
                        ifMatching: presentation
                    )
                },
                content: {
                    overlayContent(for: presentation)
                        .environment(projectManager)
                }
            )
            .id(presentation) // remount on flow switch → fresh @State
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private func overlayContent(
        for presentation: CommandOverlayPresentation
    ) -> some View {
        switch presentation {
        case .quickOpen:
            QuickOpenView(
                isPresented: Binding(
                    get: {
                        router.activePresentation == .quickOpen
                    },
                    set: { newValue in
                        if !newValue { router.dismiss(ifMatching: .quickOpen) }
                    }
                ),
                onAnnounce: router.announcementSink(for: .quickOpen)
            )
        case .symbolNavigator:
            SymbolNavigatorView(
                isPresented: Binding(
                    get: {
                        router.activePresentation == .symbolNavigator
                    },
                    set: { newValue in
                        if !newValue {
                            router.dismiss(ifMatching: .symbolNavigator)
                        }
                    }
                ),
                onAnnounce: router.announcementSink(
                    for: .symbolNavigator
                )
            )
        case .goToLine:
            GoToLineView(
                totalLines: GoToLineLineCountProvider.lineCount(
                    in: projectManager
                ),
                isPresented: Binding(
                    get: {
                        router.activePresentation == .goToLine
                    },
                    set: { newValue in
                        if !newValue {
                            router.dismiss(ifMatching: .goToLine)
                        }
                    }
                ),
                onAccessibilityAnnouncement: { message in
                    router.announce(message)
                },
                onGoTo: { line, column in
                    GoToLineLineCountProvider.navigate(
                        line: line,
                        column: column,
                        in: projectManager
                    )
                    router.dismiss(ifMatching: .goToLine)
                }
            )
        case .commandPalette:
            CommandPaletteView(
                isPresented: Binding(
                    get: {
                        router.activePresentation == .commandPalette
                    },
                    set: { newValue in
                        if !newValue {
                            router.dismiss(ifMatching: .commandPalette)
                        }
                    }
                ),
                items: CommandPaletteCatalog.makeItems(
                    tasks: ExtensibilityManager.shared.tasks.tasks,
                    keybindings: ExtensibilityManager.shared.keybindings,
                    context: UserCommandInvocationRouter.context(
                        for: projectManager,
                        windowAvailability: ProjectWindowCommandAvailability(
                            session: windowSession,
                            projectManager: projectManager
                        )
                    )
                ),
                onAnnounce: router.announcementSink(for: .commandPalette),
                onInvoke: { item in
                    CommandPaletteInvocationRouter.invoke(
                        item,
                        projectManager: projectManager,
                        overlayRouter: router,
                        windowAvailability: ProjectWindowCommandAvailability(
                            session: windowSession,
                            projectManager: projectManager
                        )
                    )
                }
            )
        case .agentAttention:
            AgentAttentionOverlay(
                summaries: AgentStatusSummary.activeSummaries(
                    in: projectManager.paneManager
                ),
                onAnnounce: { announcement in
                    router.announce(announcement)
                },
                onNavigate: { paneID, tabID in
                    navigateFromAgentAttention(
                        paneID: paneID,
                        tabID: tabID
                    )
                },
                onDismiss: {
                    router.dismiss(ifMatching: .agentAttention)
                }
            )
        }
    }

    /// A valid terminal selection becomes the new focus destination, so the
    /// router consumes the old responder without restoring it. If the
    /// destination vanished while the overlay was open, cancel normally and
    /// restore the original responder.
    private func navigateFromAgentAttention(
        paneID: PaneID,
        tabID: UUID
    ) {
        guard AgentTerminalNavigationRouter.route(
            paneID: paneID,
            tabID: tabID,
            paneManager: projectManager.paneManager,
            terminalManager: projectManager.terminal
        ) else {
            router.dismiss(ifMatching: .agentAttention)
            return
        }
        router.complete(ifMatching: .agentAttention)
    }
}

/// Owns the four overlay notification subscriptions outside `ContentView`.
///
/// Keeping these publishers in a dedicated modifier gives Xcode 27's SwiftUI
/// type-checker a substantially smaller generic expression to solve. Targeted
/// notification objects also keep independent project windows from presenting
/// or navigating each other's overlays.
struct CommandOverlayNotificationObserver: ViewModifier {
    let router: CommandOverlayRouter
    let projectManager: ProjectManager
    let isKeyWindow: Bool

    func body(content: Content) -> some View {
        content
            .onReceive(
                NotificationCenter.default.publisher(for: .showQuickOpen)
            ) { notification in
                present(
                    .quickOpen,
                    for: notification,
                    requiresActiveTab: false
                )
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: .showCommandPalette
                )
            ) { notification in
                present(
                    .commandPalette,
                    for: notification,
                    requiresActiveTab: false
                )
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: .showSymbolNavigator
                )
            ) { notification in
                present(
                    .symbolNavigator,
                    for: notification,
                    requiresActiveTab: true
                )
            }
            .onReceive(
                NotificationCenter.default.publisher(for: .symbolNavigate)
            ) { notification in
                navigate(to: notification)
            }
    }

    private func present(
        _ presentation: CommandOverlayPresentation,
        for notification: Notification,
        requiresActiveTab: Bool
    ) {
        guard ContentView.shouldHandleTargetedCommand(
            notificationObject: notification.object,
            currentProject: projectManager,
            isKeyWindow: isKeyWindow
        ) else { return }
        guard !requiresActiveTab
                || projectManager.activeTabManager.activeTab != nil else {
            return
        }
        // NotificationCenter delivers menu notifications synchronously.
        // Defer observable mutation until the command action has unwound to
        // avoid the exclusivity conflict documented in #1051.
        DispatchQueue.main.async {
            router.present(presentation)
        }
    }

    private func navigate(to notification: Notification) {
        guard ContentView.shouldHandleTargetedCommand(
            notificationObject: notification.object,
            currentProject: projectManager,
            isKeyWindow: isKeyWindow
        ),
        let offset = notification.userInfo?["offset"] as? Int,
        let tab = projectManager.activeTabManager.activeTab else {
            return
        }
        let tabManager = projectManager.activeTabManager
        let line = ContentView.lineNumber(
            forOffset: offset,
            in: tab.content
        )
        DispatchQueue.main.async {
            tabManager.pendingGoToLine = line
        }
    }
}

/// Indirection layer so `CommandOverlayContainer` does not need to reach into
/// `ContentView`'s private helpers (`totalLineCount`, `activeTabManager`) —
/// keeping the container testable in isolation.
nonisolated enum GoToLineLineCountProvider {
    /// The line count of the active tab in the given project.
    @MainActor static func lineCount(in projectManager: ProjectManager) -> Int {
        guard let content = projectManager.activeTabManager.activeTab?.content
        else { return 1 }
        let ns = content as NSString
        var count = 1
        var pos = 0
        while pos < ns.length {
            pos = NSMaxRange(
                ns.lineRange(for: NSRange(location: pos, length: 0))
            )
            count += 1
        }
        return max(1, count - 1)
    }

    /// Routes a Go-to-Line result to the active pane's TabManager via
    /// `pendingGoToLine`.
    @MainActor static func navigate(
        line: Int,
        column: Int?,
        in projectManager: ProjectManager
    ) {
        guard projectManager.activeTabManager.activeTab != nil else { return }
        _ = column
        projectManager.activeTabManager.pendingGoToLine = line
    }
}

/// Thin router that delegates command-palette invocation to the existing
/// invocation paths. Extracted so `CommandOverlayContainer` stays free of
/// `ContentView` coupling.
@MainActor
enum CommandPaletteInvocationRouter {
    static func invoke(
        _ item: CommandPaletteItem,
        projectManager: ProjectManager,
        overlayRouter: CommandOverlayRouter,
        windowAvailability: ProjectWindowCommandAvailability = .none,
        notificationCenter: NotificationCenter = .default
    ) {
        switch item.id {
        case .builtIn(let command):
            if replaceOverlayIfNeeded(
                for: command,
                overlayRouter: overlayRouter
            ) {
                return
            }
            dismissThenDispatch(overlayRouter: overlayRouter) {
                UserCommandInvocationRouter.dispatch(
                    command,
                    projectManager: projectManager,
                    windowAvailability: windowAvailability,
                    notificationCenter: notificationCenter
                )
            }
        case .task(let id):
            guard let task = ExtensibilityManager.shared.tasks.task(forID: id)
            else { return }
            dismissThenDispatch(overlayRouter: overlayRouter) {
                UserTaskInvocationController.invoke(
                    task,
                    projectManager: projectManager
                )
            }
        }
    }

    /// Replaces Command Palette with another overlay without touching project
    /// state. Kept as a small seam so routing can be verified without creating
    /// a heavyweight `ProjectManager` or starting unrelated app services.
    @discardableResult
    static func replaceOverlayIfNeeded(
        for command: UserCommand,
        overlayRouter: CommandOverlayRouter
    ) -> Bool {
        guard let replacement = overlayPresentation(for: command) else {
            return false
        }
        // `present` preserves the responder captured before Command Palette
        // opened, so the replacement remains in the same overlay session.
        overlayRouter.present(replacement)
        return true
    }

    private static func dismissThenDispatch(
        overlayRouter: CommandOverlayRouter,
        action: @escaping @MainActor () -> Void
    ) {
        overlayRouter.dismiss(
            ifMatching: .commandPalette,
            then: action
        )
    }

    private static func overlayPresentation(
        for command: UserCommand
    ) -> CommandOverlayPresentation? {
        switch command {
        case .quickOpen:
            .quickOpen
        case .symbolNavigator:
            .symbolNavigator
        case .goToLine:
            .goToLine
        case .commandPalette:
            .commandPalette
        default:
            nil
        }
    }
}
