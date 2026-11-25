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

/// Owns the overlay notification subscription outside `ContentView`.
///
/// Keeping this publisher in a dedicated modifier gives Xcode 27's SwiftUI
/// type-checker a substantially smaller generic expression to solve. Targeted
/// notification objects also keep independent project windows from presenting
/// each other's overlays.
struct CommandOverlayNotificationObserver: ViewModifier {
    let router: CommandOverlayRouter
    let projectManager: ProjectManager
    let isKeyWindow: Bool

    func body(content: Content) -> some View {
        content
            .onReceive(
                NotificationCenter.default.publisher(
                    for: .showCommandPalette
                )
            ) { notification in
                present(.commandPalette, for: notification)
            }
    }

    private func present(
        _ presentation: CommandOverlayPresentation,
        for notification: Notification
    ) {
        guard ContentView.shouldHandleTargetedCommand(
            notificationObject: notification.object,
            currentProject: projectManager,
            isKeyWindow: isKeyWindow
        ) else { return }
        // NotificationCenter delivers menu notifications synchronously.
        // Defer observable mutation until the command action has unwound to
        // avoid the exclusivity conflict documented in #1051.
        DispatchQueue.main.async {
            router.present(presentation)
        }
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

    private static func dismissThenDispatch(
        overlayRouter: CommandOverlayRouter,
        action: @escaping @MainActor () -> Void
    ) {
        overlayRouter.dismiss(
            ifMatching: .commandPalette,
            then: action
        )
    }
}
