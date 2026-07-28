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

    /// Localized, human-readable name used by the detail view and VoiceOver.
    /// Resolved through ``Strings`` for the 9 supported languages (#1245).
    var displayName: String {
        switch self {
        case .fileWrite: Strings.agentActionKindFileWrite
        case .fileRead: Strings.agentActionKindFileRead
        case .command: Strings.agentActionKindCommand
        case .toolCall: Strings.agentActionKindToolCall
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
    ///
    /// Resolved through ``Strings`` so the badge, filter chips, accessibility
    /// values, and detail view share one localized source of truth across the
    /// 9 supported languages.
    var displayName: String {
        switch self {
        case .pending: Strings.agentActionStatusPending
        case .inProgress: Strings.agentActionStatusInProgress
        case .completed: Strings.agentActionStatusCompleted
        case .failed: Strings.agentActionStatusFailed
        }
    }
}

/// One agent-session identity that may be associated with an activity row.
///
/// This is deliberately smaller than the trusted provenance envelope from
/// #933: the Activity panel only needs enough identity to avoid assigning a
/// heuristic file-system observation to the wrong agent. It grants no trust
/// or mutation authority, and it does not snapshot session liveness.
struct AgentActionCandidate: Equatable, Sendable {
    let sessionID: UUID
    let agentType: AgentType
}

/// How an Activity action is associated with live agent sessions.
///
/// Directly recorded actions retain the legacy single-session association.
/// File-system correlation is always explicit about its weaker evidence:
/// `.inferred` when one live session is a candidate, and `.ambiguous` when
/// several sessions could have caused the same observation. An ambiguous
/// action intentionally has no selected owner.
enum AgentActionAttribution: Equatable, Sendable {
    /// A structured event whose provenance was validated by Pine's trusted
    /// agent-event pipeline.
    case verified(AgentActionCandidate)
    case session(AgentActionCandidate)
    case inferred(AgentActionCandidate)
    case ambiguous(candidates: [AgentActionCandidate])

    /// Every session that could be associated with the action.
    var candidates: [AgentActionCandidate] {
        switch self {
        case .verified(let candidate),
             .session(let candidate),
             .inferred(let candidate):
            [candidate]
        case .ambiguous(let candidates):
            candidates
        }
    }

    /// The single associated session, or `nil` when ownership is ambiguous.
    var unambiguousCandidate: AgentActionCandidate? {
        switch self {
        case .verified(let candidate),
             .session(let candidate),
             .inferred(let candidate):
            candidate
        case .ambiguous:
            nil
        }
    }

    func contains(sessionID: UUID) -> Bool {
        candidates.contains { $0.sessionID == sessionID }
    }
}

/// A single structured action attributed to an AI agent session.
///
/// Links to one or more `AgentSession` candidates via ``attribution``. Being
/// a value type keeps the store and views free of live-terminal coupling —
/// matching the `AgentStatusSummary` projection pattern used by the
/// status-bar item (#952).
struct AgentAction: Identifiable, Equatable, Sendable {
    /// Stable identifier for this action.
    let id: UUID
    /// The candidate session association and its correlation strength.
    let attribution: AgentActionAttribution
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
    /// Working directory the agent was operating in when the action happened,
    /// if known. Surfaced in the Activity detail view (#1245).
    let workingDirectory: URL?

    /// Backwards-compatible single-session accessor. Returns `nil` for an
    /// ambiguous action instead of selecting one candidate as the owner.
    var sessionID: UUID? {
        attribution.unambiguousCandidate?.sessionID
    }

    /// Backwards-compatible single-agent accessor. Returns `nil` for an
    /// ambiguous action so the UI cannot color it as one candidate's work.
    var agentType: AgentType? {
        attribution.unambiguousCandidate?.agentType
    }

    /// Safe-to-copy text for the Activity detail view's Copy action (#1245).
    ///
    /// The free-form summary is deliberately excluded. Command/tool summaries
    /// can contain shell assignments, authorization headers, URLs with
    /// credentials, or other secrets that cannot be reliably identified after
    /// the fact. Copy therefore exports only bounded structured metadata.
    var copyableSummary: String {
        var lines: [String] = []
        lines.append(Strings.agentActionDetailKindLabel + ": " + kind.displayName)
        lines.append(Strings.agentActionDetailStatusLabel + ": " + status.displayName)
        if let fileURL {
            lines.append(Strings.agentActionDetailFileLabel + ": " + fileURL.path)
        }
        if let workingDirectory {
            lines.append(Strings.agentActionDetailWorkingDirectoryLabel + ": " + workingDirectory.path)
        }
        return lines.joined(separator: "\n")
    }

    init(
        id: UUID = UUID(),
        sessionID: UUID,
        agentType: AgentType,
        kind: AgentActionKind,
        status: AgentActionStatus = .completed,
        timestamp: Date = Date(),
        fileURL: URL? = nil,
        summary: String,
        workingDirectory: URL? = nil
    ) {
        self.id = id
        self.attribution = .session(
            AgentActionCandidate(sessionID: sessionID, agentType: agentType)
        )
        self.kind = kind
        self.status = status
        self.timestamp = timestamp
        self.fileURL = fileURL
        self.summary = summary
        self.workingDirectory = workingDirectory
    }

    init(
        id: UUID = UUID(),
        attribution: AgentActionAttribution,
        kind: AgentActionKind,
        status: AgentActionStatus = .completed,
        timestamp: Date = Date(),
        fileURL: URL? = nil,
        summary: String,
        workingDirectory: URL? = nil
    ) {
        self.id = id
        self.attribution = attribution
        self.kind = kind
        self.status = status
        self.timestamp = timestamp
        self.fileURL = fileURL
        self.summary = summary
        self.workingDirectory = workingDirectory
    }
}
