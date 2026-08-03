//
//  AgentHistoryEntry.swift
//  Pine
//
//  Persistent history entry for a single AI-agent run (vision #933,
//  Phase 2 — Visibility, issue #1073). Stored as JSON in
//  `.pine/agent-log.json` by `AgentHistoryStore`. The current implementation
//  records observed file paths for review, but does not treat heuristic
//  attribution as proof that an agent exclusively authored those changes.
//
//  `agentTypeRaw` persists `AgentType` via `stableIdentifier` (a plain string)
//  rather than the enum's associated-value form, so the on-disk file survives
//  the introduction of new `AgentType` cases without throwing on decode.
//

import Foundation

/// Confidence of the file-to-session attribution stored in a history entry.
///
/// This describes attribution only. Even `.verified` is not sufficient for
/// undo: a safe inverse also requires an exact before/after change set and a
/// divergence check, neither of which the current history format stores
/// (#1183).
nonisolated enum AgentHistoryAttribution: String, Codable, Sendable {
    /// Pine inferred the paths from process/file-system activity.
    case heuristic
    /// More than one session or writer could have produced the changes.
    case ambiguous
    /// Explicit provenance identified the writer. Reserved for a future
    /// provenance pipeline; it still does not make whole-file checkout safe.
    case verified

    /// Unknown future values fail closed as `.heuristic`. History files can
    /// outlive the app version that wrote them, and an older Pine must never
    /// turn unfamiliar provenance into permission for destructive undo.
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = Self(rawValue: rawValue) ?? .heuristic
    }
}

/// Why an Agent History entry cannot currently be undone safely.
///
/// The first five cases are structural and computable from the stored entry
/// alone. The remaining cases are runtime refusals surfaced by the checked
/// undo engine after consulting the owner-private authority and the live
/// workspace; `effectiveUndoAvailability` on `AgentHistoryStore` reports them.
nonisolated enum AgentHistoryUndoUnavailableReason: Sendable, Equatable {
    case heuristicAttribution
    case ambiguousAttribution
    case missingVerifiedReversibleChangeSet
    case invalidVerifiedReversibleChangeSet
    case checkedUndoEngineUnavailable
    // Runtime refusals from the checked undo engine (#1183).
    /// No owner-private authority record exists for this entry's change set.
    case authorityRecordMissing
    /// The authority was already consumed by a previous undo (single-use).
    case authorityConsumed
    /// The workspace root, HEAD, or git index changed since capture.
    case workspaceChanged
    /// A recorded file's current content no longer matches its recorded
    /// after-state; reverting could discard unrelated post-capture edits.
    case currentContentDiverged
    /// The inverse payload blob is missing or failed its integrity check.
    case inversePayloadMissing
}

/// Fail-closed decision used by both the UI and the mutation boundary.
nonisolated enum AgentHistoryUndoAvailability: Sendable, Equatable {
    /// The entry has a verified, structurally complete change set. This pure
    /// property never returns `.available` by itself — it returns
    /// `.checkedUndoEngineUnavailable` for structurally ready entries because
    /// confirming the owner-private authority requires filesystem access.
    /// `AgentHistoryStore.effectiveUndoAvailability(for:)` is the source the UI
    /// reads; it returns `.available` only after the engine confirms the
    /// authority exists and is unconsumed.
    case available
    case unavailable(AgentHistoryUndoUnavailableReason)
}

/// A persistent, `Codable` record of one finished AI-agent session, including
/// the files it touched and whether its changes have been reverted.
///
/// `affectedFiles` holds **relative paths** from the project root (never
/// absolute paths or file contents) so the log is portable across machines and
/// never leaks file contents. Decoding is forward-compatible: an unknown
/// `agentTypeRaw` decodes into a generic entry instead of throwing, because the
/// log file outlives individual app versions.
nonisolated struct AgentHistoryEntry: Codable, Identifiable, Equatable, Sendable {
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
    /// Confidence of the association between this session and `affectedFiles`.
    /// Legacy entries decode as `.heuristic`.
    let attribution: AgentHistoryAttribution
    /// Content-free, versioned contract from a trusted provenance pipeline.
    /// Current heuristic recording never supplies one. Patch/content bytes
    /// live outside the project and are referenced opaquely by this value.
    let verifiedChangeSet: VerifiedAgentChangeSet?
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
        attribution: AgentHistoryAttribution = .heuristic,
        verifiedChangeSet: VerifiedAgentChangeSet? = nil,
        summary: String,
        reverted: Bool = false
    ) {
        self.id = id
        self.sessionID = sessionID
        self.agentTypeRaw = agentTypeRaw
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.affectedFiles = affectedFiles
        self.attribution = attribution
        self.verifiedChangeSet = verifiedChangeSet
        self.summary = summary
        self.reverted = reverted
    }

    /// Heuristic and ambiguous attribution can never authorize a working-tree
    /// mutation. Verified entries must pass the pure change-set preflight;
    /// structurally complete records remain locked here until
    /// `AgentHistoryStore.effectiveUndoAvailability(for:)` confirms their
    /// owner-private authority and the checked engine validates live state.
    var undoAvailability: AgentHistoryUndoAvailability {
        switch attribution {
        case .heuristic:
            return .unavailable(.heuristicAttribution)
        case .ambiguous:
            return .unavailable(.ambiguousAttribution)
        case .verified:
            switch AgentHistoryUndoPreflight.evaluate(self) {
            case .readyForPrivateAuthorityValidation:
                return .unavailable(.checkedUndoEngineUnavailable)
            case .blocked(.missingChangeSet):
                return .unavailable(.missingVerifiedReversibleChangeSet)
            case .blocked:
                return .unavailable(.invalidVerifiedReversibleChangeSet)
            }
        }
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
        // Logs written before #1183 have no attribution field. They contain
        // only inferred paths, so legacy and malformed/future values must
        // remain read-only rather than inheriting destructive permissions.
        attribution = (try? container.decodeIfPresent(
            AgentHistoryAttribution.self,
            forKey: .attribution
        )) ?? .heuristic
        // Missing/invalid future contracts fail closed without making the
        // entire long-lived history log unreadable.
        verifiedChangeSet = try? container.decodeIfPresent(
            VerifiedAgentChangeSet.self,
            forKey: .verifiedChangeSet
        )
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
        case .openCode: "openCode"
        case .gemini: "gemini"
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
        case "openCode": self = .openCode
        case "gemini": self = .gemini
        default:
            guard stableIdentifier.hasPrefix("generic:") else { return nil }
            let name = String(stableIdentifier.dropFirst("generic:".count))
            guard !name.isEmpty else { return nil }
            self = .generic(name: name)
        }
    }
}
