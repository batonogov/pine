//
//  AgentTaskSelectionHosting.swift
//  Pine
//
//  The seam attention routing uses to show one exact task (#1760).
//

import Foundation

/// A surface that lists one project's tasks and can show one of them.
///
/// `ProjectRegistry.selectAgentTask` routes attention here. Selecting is
/// view-only: it never launches, resumes, accepts, or executes anything.
@MainActor
protocol AgentTaskSelectionHosting: AnyObject {
    /// The root of the project whose tasks this surface lists.
    var hostedProjectURL: URL { get }
    func selectTask(_ taskID: UUID)
}

/// How a request to show one exact task ended.
nonisolated enum AgentTaskSelectionOutcome: Equatable, Sendable {
    /// The owning window is focused and shows the task.
    case selected
    /// The owning window is up; the task is selected once its task list mounts.
    case queued
    /// No listed task has this ID.
    case refused
    /// The task does not live in a project window (Quick Terminal).
    case unsupportedSurface
    /// The owning project window could not be presented.
    case projectUnavailable
}
