//
//  ProjectWindowCommandObserver.swift
//  Pine
//
//  Issue #1525: New Agent and project switching are now ordinary registered
//  commands, posted from the menu bar, the Command Palette and user
//  keybindings. They act on the window session, which only a project scene
//  owns — so the scene is where the requests land.
//

import SwiftUI

/// Applies window-scoped agent and project-switching commands to this scene.
struct ProjectWindowCommandObserver: ViewModifier {
    @Environment(\.controlActiveState) private var controlActiveState
    let projectManager: ProjectManager
    let session: ProjectWindowSession
    let registry: ProjectRegistry

    func body(content: Content) -> some View {
        content
            .onReceive(
                NotificationCenter.default.publisher(for: .newAgent)
            ) { notification in
                guard isForThisWindow(notification) else { return }
                let identifier = notification.userInfo?[
                    ProjectAgentLaunchSelection.identifierKey
                ] as? String
                // A menu click arrives while AppKit is still tracking the
                // menu, and launching mutates the session (active project,
                // a new terminal) synchronously inside its first hop. Let
                // menu tracking unwind first, exactly as Open Folder and
                // Close Project do.
                NativeCommandDelivery.deferToNextMainRunLoop {
                    launchAgent(identifier: identifier)
                }
            }
            .onReceive(
                NotificationCenter.default
                    .publisher(for: .switchProjectInWindow)
            ) { notification in
                guard isForThisWindow(notification) else { return }
                guard let target = target(of: notification) else { return }
                NativeCommandDelivery.deferToNextMainRunLoop {
                    Task { @MainActor in
                        await session.activate(target, registry: registry)
                    }
                }
            }
    }

    private func isForThisWindow(_ notification: Notification) -> Bool {
        ContentView.shouldHandleTargetedCommand(
            notificationObject: notification.object,
            currentProject: projectManager,
            isKeyWindow: controlActiveState == .key
        )
    }

    private func launchAgent(identifier: String?) {
        // Resolved against the live catalog rather than the one the menu was
        // built from: an agent uninstalled in between must not silently
        // launch a different one in its place.
        guard let option = ProjectAgentLaunchSelection.option(
            identifier: identifier,
            in: session.availableAgentOptions
        ) else {
            return
        }
        Task { @MainActor in
            await session.launchAgent(option, registry: registry)
        }
    }

    /// A named row, or the row one step away in the switcher's order.
    private func target(of notification: Notification) -> URL? {
        switch ProjectWindowSwitchRequest.parse(notification.userInfo) {
        case .row(let url):
            url
        case .step(let direction):
            session.neighbourTarget(direction)
        case nil:
            nil
        }
    }
}

/// What a `switchProjectInWindow` notification is asking for.
///
/// Menu rows name a URL; Next/Previous Project name a direction. Anything
/// else — a missing payload, a direction Pine does not define — is not a
/// request at all: acting on a half-understood payload would move the window
/// somewhere the user never pointed at.
nonisolated enum ProjectWindowSwitchRequest: Equatable {
    case row(URL)
    case step(ProjectWindowSwitchOrder.Direction)

    static func parse(_ userInfo: [AnyHashable: Any]?) -> Self? {
        if let url = userInfo?["url"] as? URL {
            return .row(url)
        }
        guard let raw = userInfo?["direction"] as? String,
              let direction = ProjectWindowSwitchOrder.Direction(
                  rawValue: raw
              ) else {
            return nil
        }
        return .step(direction)
    }
}
