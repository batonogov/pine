//
//  AgentHistoryEntry.swift
//  Pine
//
//  Persistent audit-log entry for a single AI-agent run (vision #933,
//  Phase 2 — Visibility, issue #1073). Stored as JSON in
//  `.pine/agent-log.json` by `AgentHistoryStore`. This is the durable,
//  replayable counterpart to the live `AgentSession`: it captures what the
//  agent did so a user can review and revert it long after the process exits.
//
//  `agentTypeRaw` persists `AgentType` via `stableIdentifier` (a plain string)
//  rather than the enum's associated-value form, so the on-disk file survives
//  the introduction of new `AgentType` cases without throwing on decode.
//

import Foundation

/// A persistent, `Codable` record of one finished AI-agent session, including
/// the files it touched and whether its changes have been reverted.
///
/// `affectedFiles` holds **relative paths** from the project root (never
/// absolute paths or file contents) so the log is portable across machines and
/// never leaks file contents. Decoding is forward-compatible: an unknown
/// `agentTypeRaw` decodes into a generic entry instead of throwing, because the
/// log file outlives individual app versions.
struct AgentHistoryEntry: Codable, Identifiable, Equatable, Sendable {
    /// Stable identifier for this log entry.
    let id: UUID
    /// Identifier of the `AgentSession` this entry records. Lets the UI and
    /// undo logic correlate a log row back to the session that produced it,
    /// so two agents touching the same project never roll back the wrong run
    /// (see #933 comment by Snailflyer).
    let sessionID: UUID
    /// Stable string representation of the agent type (`AgentType.stableIdentifier`).
    let agentTypeRaw: String
    /// When the session started.
    let startedAt: Date
    /// When the session ended (set when the entry is finalized). `nil` until then.
    let endedAt: Date?
    /// Relative paths (from project root) of files the agent modified.
    let affectedFiles: [String]
    /// Human-readable summary, e.g. "5 files, +142/-38 lines".
    let summary: String
    /// Whether the entry's changes have been reverted via `AgentHistoryStore.revert`.
    var reverted: Bool

    init(
        id: UUID = UUID(),
        sessionID: UUID,
        agentTypeRaw: String,
        startedAt: Date,
        endedAt: Date? = nil,
        affectedFiles: [String],
        summary: String,
        reverted: Bool = false
    ) {
        self.id = id
        self.sessionID = sessionID
        self.agentTypeRaw = agentTypeRaw
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.affectedFiles = affectedFiles
        self.summary = summary
        self.reverted = reverted
    }

    /// Forward-compatible decoder: an unknown `agentTypeRaw` is preserved as-is
    /// rather than throwing. The stored value is a plain string, so no key is
    /// actually invalid — this custom `init(from:)` exists primarily to keep
    /// decoding resilient if extra/optional keys are added in future versions
    /// and to centralise the tolerant philosophy documented above.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        sessionID = try container.decode(UUID.self, forKey: .sessionID)
        // Tolerant: unknown agent types are kept verbatim; never throw here.
        agentTypeRaw = try container.decodeIfPresent(String.self, forKey: .agentTypeRaw) ?? "generic:Unknown"
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        endedAt = try container.decodeIfPresent(Date.self, forKey: .endedAt)
        affectedFiles = try container.decodeIfPresent([String].self, forKey: .affectedFiles) ?? []
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        reverted = try container.decodeIfPresent(Bool.self, forKey: .reverted) ?? false
    }
}

// MARK: - AgentType stable codable representation

extension AgentType {
    /// A stable, version-independent string representation suitable for
    /// persistence. Unlike the enum's synthesized `Codable` (which encodes
    /// associated values and breaks when cases are reordered/added), this is a
    /// plain string that survives new agent types. Round-trips via
    /// `init?(stableIdentifier:)`.
    var stableIdentifier: String {
        switch self {
        case .claudeCode: "claudeCode"
        case .codex: "codex"
        case .aider: "aider"
        case .copilot: "copilot"
        case .pi: "pi"
        case .generic(let name): "generic:\(name)"
        }
    }

    /// Reconstructs an `AgentType` from its `stableIdentifier`. Returns `nil`
    /// for an unrecognised identifier (the caller may fall back to a generic
    /// type). This makes the on-disk log forward-compatible: a new agent type
    /// added in a future version decodes as a generic entry under older builds
    /// instead of crashing.
    init?(stableIdentifier: String) {
        switch stableIdentifier {
        case "claudeCode": self = .claudeCode
        case "codex": self = .codex
        case "aider": self = .aider
        case "copilot": self = .copilot
        case "pi": self = .pi
        default:
            guard stableIdentifier.hasPrefix("generic:") else { return nil }
            let name = String(stableIdentifier.dropFirst("generic:".count))
            guard !name.isEmpty else { return nil }
            self = .generic(name: name)
        }
    }
}
