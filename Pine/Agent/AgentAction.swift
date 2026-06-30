//
//  AgentAction.swift
//  Pine
//
//  Value-type action model for the Agent Activity Panel (vision #933,
//  Phase 2 — Visibility, issue #1072). Pure value types: no detection
//  logic, no UI. Consumed by `AgentActivityStore` and projected into
//  `AgentActivityRow` for rendering by `AgentActivityView`.
//

import Foundation

/// The kind of operation a detected agent performed.
///
/// Used by `AgentAction` and surfaced as filter chips in the Activity Panel.
enum AgentActionKind: Sendable, Equatable, CaseIterable {
    /// Agent wrote/modified a file on disk.
    case fileWrite
    /// Agent read a file.
    case fileRead
    /// Agent ran a shell command.
    case command
    /// Agent invoked a tool (e.g. an MCP/tool-call).
    case toolCall

    /// SF Symbol name for the row icon.
    var systemImage: String {
        switch self {
        case .fileWrite: "pencil.and.outline"
        case .fileRead: "eye"
        case .command: "terminal"
        case .toolCall: "wrench.and.screwdriver"
        }
    }
}

/// Lifecycle status of a single agent action.
enum AgentActionStatus: Sendable, Equatable, CaseIterable {
    /// Not yet started.
    case pending
    /// Currently running.
    case inProgress
    /// Finished successfully.
    case completed
    /// Failed.
    case failed

    /// Short label for the status badge in the Activity Panel.
    var displayName: String {
        switch self {
        case .pending: "Pending"
        case .inProgress: "In progress"
        case .completed: "Completed"
        case .failed: "Failed"
        }
    }
}

/// A single structured action attributed to an AI agent session.
///
/// Links to `AgentSession` via `sessionID` (the stable session UUID). Being a
/// value type keeps the store and views free of live-terminal coupling —
/// matching the `AgentStatusSummary` projection pattern used by the status-bar
/// item (#952).
struct AgentAction: Identifiable, Equatable, Sendable {
    /// Stable identifier for this action.
    let id: UUID
    /// The agent session this action belongs to (`AgentSession.id`).
    let sessionID: UUID
    /// Which agent type performed the action (snapshot for display even after
    /// the session ends, so the panel can color-code finished runs).
    let agentType: AgentType
    /// Kind of operation.
    let kind: AgentActionKind
    /// Lifecycle status.
    var status: AgentActionStatus
    /// When the action was recorded.
    let timestamp: Date
    /// File the action touched, if any (nil for commands/tool-calls without a
    /// file target).
    let fileURL: URL?
    /// Human-readable one-line summary (file name, command text, …).
    let summary: String

    init(
        id: UUID = UUID(),
        sessionID: UUID,
        agentType: AgentType,
        kind: AgentActionKind,
        status: AgentActionStatus = .completed,
        timestamp: Date = Date(),
        fileURL: URL? = nil,
        summary: String
    ) {
        self.id = id
        self.sessionID = sessionID
        self.agentType = agentType
        self.kind = kind
        self.status = status
        self.timestamp = timestamp
        self.fileURL = fileURL
        self.summary = summary
    }
}
