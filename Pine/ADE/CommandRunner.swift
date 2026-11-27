//
//  CommandRunner.swift
//  Pine
//
//  The single place a Command-mode submission reaches execution (#1754, #1757).
//

import Foundation

/// Where a Command runs and the task it belongs to.
nonisolated struct ADECommandEnvironment: Sendable, Equatable {
    let project: AgentTaskProjectIdentity
    /// The task the command continues; `nil` when it starts new work.
    let taskID: UUID?
}

/// What a Command produced: an exit status and bounded output, never a transcript.
nonisolated struct ADECommandResult: Sendable, Equatable {
    /// `nil` when no direct-child exit was observed.
    let exitCode: Int32?
    let output: UserTaskOutputPreview
}

/// Executes one literal Command in a task's environment.
///
/// Nothing conforms in production yet. The workspace renders Command mode
/// truthfully until the execution lane supplies a runner, and it never runs
/// anything on its own.
@MainActor
protocol CommandRunner: AnyObject {
    /// Called only from an explicit Send. Never called while restoring.
    func run(
        _ command: String, in environment: ADECommandEnvironment
    ) async throws -> ADECommandResult
}
