//
//  AgentActivityPresentationRouter.swift
//  Pine
//
//  Project-scoped presentation routing for the Agent Activity sheet.
//

import Foundation

/// Keeps Agent Activity menu requests bound to the project window that issued
/// them. A nil notification object remains supported for legacy callers, but
/// only the key window may consume that fallback request.
@MainActor
enum AgentActivityPresentationRouter {
    /// Posts a request for one exact project. Returning `false` for a missing
    /// project lets menu callers fail closed instead of broadcasting a sheet to
    /// every open project window.
    @discardableResult
    static func postRequest(
        for projectManager: ProjectManager?,
        notificationCenter: NotificationCenter = .default
    ) -> Bool {
        guard let projectManager else { return false }
        notificationCenter.post(
            name: .showAgentActivity,
            object: projectManager
        )
        return true
    }

    /// Resolves both targeted requests and the legacy nil-object fallback.
    static func shouldPresent(
        notificationObject: Any?,
        currentProject: ProjectManager,
        isKeyWindow: Bool
    ) -> Bool {
        ContentView.shouldHandleTargetedCommand(
            notificationObject: notificationObject,
            currentProject: currentProject,
            isKeyWindow: isKeyWindow
        )
    }
}
