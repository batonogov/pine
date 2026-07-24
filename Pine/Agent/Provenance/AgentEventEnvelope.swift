//
//  AgentEventEnvelope.swift
//  Pine
//
//  Trusted event provenance slice (epic #933, section 1 — "Trusted event
//  provenance").
//
//  `AgentEventEnvelope` is the single structured record that captures WHO did
//  WHAT, WHERE, and HOW TRUSTWORTHY the observation is. It is the foundation
//  for trustworthy agent awareness: terminal/process observation stays useful
//  for presence and attention, but file/tool attribution requires explicit
//  provenance like this envelope (#933).
//
//  Safety boundary with #1183 (heuristic history undo):
//  - This is a pure DATA MODEL. It carries provenance and, optionally, an
//    exact content-identity change set. It performs no working-tree mutation
//    and authorizes none.
//  - A `.verified` trust level means the event's SOURCE is trustworthy (an
//    explicit structured report), NOT that an undo is safe. A safe inverse
//    still requires a checked change set AND a divergence check against the
//    current file (handled separately by #1183).
//  - Trust levels and sources decode forward-compatibly: an unknown value
//    from a future Pine never upgrades into a more trusted level — it fails
//    closed to `.inferred` / a preserved-raw source.
//

import Foundation

/// How trustworthy the attribution of an event is.
///
/// Ordered weakest-to-strongest: `observed` < `inferred` < `verified`.
/// Temporal correlation alone can never reach `.verified` (#933); only an
/// explicit structured report can.
nonisolated enum TrustLevel: String, Codable, Sendable, Equatable, CaseIterable {
    /// A terminal/process was observed to be present or active, but no
    /// specific action was attributed (e.g. an agent was detected running).
    case observed
    /// Pine inferred an action by correlating file-system/git activity with
    /// an active agent in time. The strongest level the current heuristic
    /// correlation can reach; explicitly NOT proof of exclusive authorship.
    case inferred
    /// An explicit structured report identified the actor and, when relevant,
    /// the exact change. The only level that can carry a verified change set.
    case verified

    /// `true` only for `.verified`. Callers that gate destructive behavior on
    /// trust must additionally require a checked change set and a divergence
    /// check — `.verified` alone is necessary but not sufficient (#1183).
    var isVerified: Bool { self == .verified }

    /// `true` for levels based on correlation rather than an explicit report.
    var isHeuristic: Bool { self != .verified }

    /// Unknown future values fail closed as `.inferred` (the strongest level
    /// correlation can reach, still non-verified). Trust levels can outlive
    /// the app version that wrote them, and an older Pine must never turn an
    /// unfamiliar level into `.verified`. Mirrors the tolerant decoding of
    /// `AgentHistoryAttribution`.
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = Self(rawValue: rawValue) ?? .inferred
    }
}

/// What produced an event. Used together with `TrustLevel` to describe both
/// the origin and the reliability of an observation.
nonisolated enum EventSource: Sendable, Equatable {
    /// A terminal process was detected (presence/lifecycle).
    case terminalProcess
    /// File-system observation (FSEvents refresh).
    case fileSystemObservation
    /// Git status/diff correlation.
    case gitCorrelation
    /// An explicit structured report from the agent or a trusted integration.
    case explicitAgentEvent
    /// A direct user action attributed for context.
    case userAction

    /// A stable, version-independent string used for persistence. Survives
    /// the addition of new cases; round-trips via `init?(stableIdentifier:)`.
    /// `.unknown` preserves its original raw value so a newer-Pine source
    /// string survives a round-trip through an older build.
    var stableIdentifier: String {
        switch self {
        case .terminalProcess: "terminalProcess"
        case .fileSystemObservation: "fileSystemObservation"
        case .gitCorrelation: "gitCorrelation"
        case .explicitAgentEvent: "explicitAgentEvent"
        case .userAction: "userAction"
        case .unknown(let raw): raw
        }
    }

    /// Only an explicit structured agent event can establish verified agent
    /// attribution. Every other source remains observational or heuristic.
    var canEstablishVerifiedTrust: Bool {
        if case .explicitAgentEvent = self {
            return true
        }
        return false
    }

    /// Reconstructs a source from its `stableIdentifier`. Returns `nil` for an
    /// unrecognised identifier so decoding stays forward-compatible.
    init?(stableIdentifier: String) {
        switch stableIdentifier {
        case "terminalProcess": self = .terminalProcess
        case "fileSystemObservation": self = .fileSystemObservation
        case "gitCorrelation": self = .gitCorrelation
        case "explicitAgentEvent": self = .explicitAgentEvent
        case "userAction": self = .userAction
        default: return nil
        }
    }

    /// Forward-compatible decoder: an unknown source is preserved verbatim via
    /// the `unknown` case rather than throwing, so a log from a newer Pine
    /// still loads. The raw value is retained for round-tripping.
    case unknown(raw: String)
}

nonisolated extension EventSource: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, raw
    }

    init(from decoder: Decoder) throws {
        // Known values and legacy unknown values use the original single-string
        // representation. New unknown values use a tagged representation so an
        // unknown raw value that aliases a known identifier cannot become a
        // trusted source after an encode/decode round-trip.
        if let raw = try? decoder.singleValueContainer().decode(String.self) {
            self = EventSource(stableIdentifier: raw) ?? .unknown(raw: raw)
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        guard kind == "unknown" else {
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "Unsupported EventSource representation"
            )
        }
        self = .unknown(raw: try container.decode(String.self, forKey: .raw))
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .unknown(let raw):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("unknown", forKey: .kind)
            try container.encode(raw, forKey: .raw)
        default:
            var container = encoder.singleValueContainer()
            try container.encode(stableIdentifier)
        }
    }
}

nonisolated extension TrustLevel {
    /// Returns the effective trust after applying the source and provenance
    /// invariants. A caller or persisted record may request `.verified`, but it
    /// is granted only to a complete explicit structured event.
    static func effective(
        requested: TrustLevel,
        source: EventSource,
        provenanceIsComplete: Bool,
        payloadIsValid: Bool = true
    ) -> TrustLevel {
        guard requested == .verified else { return requested }
        guard source.canEstablishVerifiedTrust,
              provenanceIsComplete,
              payloadIsValid else {
            return .inferred
        }
        return .verified
    }
}

/// Identifies the agent process that produced an event.
nonisolated struct AgentProcessIdentity: Codable, Sendable, Equatable {
    /// Stable identifier of the terminal tab hosting the agent.
    let terminalID: UUID
    /// Monotonic generation of the process within that terminal. A new shell
    /// or a relaunched agent increments this, so events from a stale process
    /// cannot be confused with a fresh one.
    let processGeneration: UInt64
}

/// Where an agent event occurred.
nonisolated struct AgentEventLocation: Codable, Sendable, Equatable {
    /// The git worktree root path at event time. Disambiguates nested
    /// worktrees sharing one project (#1183). Stored as a path string because
    /// worktrees may live outside the project root.
    let worktreePath: String
    /// The working directory at event time. May equal `worktreePath`.
    let cwd: String
}

/// The result of an observed command, carried as optional evidence.
nonisolated struct AgentCommandResult: Codable, Sendable, Equatable {
    /// The command line that was observed (e.g. `git commit -m "..."`).
    let command: String
    /// The process exit status (`0` on success).
    let exitStatus: Int32
}

/// An exact file change identified by content hashes — never by content.
///
/// `before` is `nil` for a newly created file. Both identities are content
/// fingerprints: a future safe-undo path can detect divergence by re-hashing
/// the current file and comparing it to `after` (#1183).
nonisolated struct AgentFileChange: Codable, Sendable, Equatable {
    /// Relative path from the project root. Never absolute, never content.
    let relativePath: String
    /// Identity of the content before the change; `nil` for a new file.
    let before: ContentIdentity?
    /// Identity of the content after the change.
    let after: ContentIdentity
}

/// Optional evidence carried by an event. A presence-only event carries `.none`.
nonisolated enum AgentEventPayload: Codable, Sendable, Equatable {
    /// No structured payload; the event records presence/observation only.
    case none
    /// A command was observed to complete with this result.
    case commandResult(AgentCommandResult)
    /// An exact file change, identified by content hashes — never content.
    case fileChange(AgentFileChange)

    private enum CodingKeys: String, CodingKey {
        case kind, commandResult, fileChange
    }

    private init(fromKnown container: KeyedDecodingContainer<Self.CodingKeys>) throws {
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "none":
            self = .none
        case "commandResult":
            self = .commandResult(try container.decode(AgentCommandResult.self, forKey: .commandResult))
        case "fileChange":
            self = .fileChange(try container.decode(AgentFileChange.self, forKey: .fileChange))
        default:
            // Unknown payload kinds are preserved as `.none` rather than
            // throwing: a future Pine may record payload kinds this build
            // cannot interpret, and the provenance (identity/trust/source)
            // remains useful without the payload.
            self = .none
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(fromKnown: container)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .none:
            try container.encode("none", forKey: .kind)
        case .commandResult(let result):
            try container.encode("commandResult", forKey: .kind)
            try container.encode(result, forKey: .commandResult)
        case .fileChange(let change):
            try container.encode("fileChange", forKey: .kind)
            try container.encode(change, forKey: .fileChange)
        }
    }
}

/// One structured record of a trusted (or explicitly heuristic) agent event.
///
/// Captures project + worktree identity, agent/session identity, terminal
/// process generation, working directory, a monotonic event cursor + wall-clock
/// timestamp, the event source, its trust level, and an optional payload. This
/// is the unit a provenance pipeline records so that the UI and a future
/// safe-undo path can answer "what did this verified agent actually do?"
/// without relying on temporal correlation alone (#933).
nonisolated struct AgentEventEnvelope: Codable, Identifiable, Sendable, Equatable {
    /// Stable identifier for this envelope.
    let id: UUID
    /// Identifier of the Pine project the event occurred in.
    let projectID: UUID
    /// Identifier of the agent session that produced the event.
    let sessionID: UUID
    /// Stable string representation of the agent type (`AgentType.stableIdentifier`).
    /// Kept as a plain string so a new agent type added later decodes cleanly.
    let agentTypeRaw: String
    /// The agent process that produced the event (terminal + generation).
    let process: AgentProcessIdentity
    /// Where the event occurred (worktree root + cwd).
    let location: AgentEventLocation
    /// Monotonic sequence number from this process's `EventCursor`.
    let cursorValue: UInt64
    /// When the event was recorded (wall-clock).
    let timestamp: Date
    /// What produced the event.
    let source: EventSource
    /// How trustworthy the attribution is.
    let trustLevel: TrustLevel
    /// Optional evidence (command result or exact file-change identity).
    let payload: AgentEventPayload

    init(
        id: UUID = UUID(),
        projectID: UUID,
        sessionID: UUID,
        agentTypeRaw: String,
        process: AgentProcessIdentity,
        location: AgentEventLocation,
        cursorValue: UInt64,
        timestamp: Date = Date(),
        source: EventSource,
        trustLevel: TrustLevel,
        payload: AgentEventPayload = .none
    ) {
        self.init(
            id: id,
            projectID: projectID,
            sessionID: sessionID,
            agentTypeRaw: agentTypeRaw,
            process: process,
            location: location,
            cursorValue: cursorValue,
            timestamp: timestamp,
            source: source,
            requestedTrustLevel: trustLevel,
            payload: payload,
            payloadIsValid: true
        )
    }

    private init(
        id: UUID,
        projectID: UUID,
        sessionID: UUID,
        agentTypeRaw: String,
        process: AgentProcessIdentity,
        location: AgentEventLocation,
        cursorValue: UInt64,
        timestamp: Date,
        source: EventSource,
        requestedTrustLevel: TrustLevel,
        payload: AgentEventPayload,
        payloadIsValid: Bool
    ) {
        self.id = id
        self.projectID = projectID
        self.sessionID = sessionID
        self.agentTypeRaw = agentTypeRaw
        self.process = process
        self.location = location
        self.cursorValue = cursorValue
        self.timestamp = timestamp
        self.source = source
        self.payload = payload
        self.trustLevel = TrustLevel.effective(
            requested: requestedTrustLevel,
            source: source,
            provenanceIsComplete: Self.provenanceIsComplete(
                ProvenanceValidationInput(
                    id: id,
                    projectID: projectID,
                    sessionID: sessionID,
                    agentTypeRaw: agentTypeRaw,
                    process: process,
                    location: location,
                    cursorValue: cursorValue,
                    timestamp: timestamp
                )
            ),
            payloadIsValid: payloadIsValid
        )
    }

    /// Forward-compatible decoder. Missing or unrecognised values fail closed
    /// to the least-trusting safe default rather than throwing, so a log from a
    /// newer or older Pine always loads as read-only provenance.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(UUID.self, forKey: .id)
        let projectID = try container.decode(UUID.self, forKey: .projectID)
        let sessionID = try container.decode(UUID.self, forKey: .sessionID)
        let agentTypeRaw = try container.decodeIfPresent(
            String.self,
            forKey: .agentTypeRaw
        ) ?? "generic:Unknown"
        let process = try container.decodeIfPresent(
            AgentProcessIdentity.self,
            forKey: .process
        ) ?? AgentProcessIdentity(terminalID: Self.zeroUUID, processGeneration: 0)
        let location = try container.decodeIfPresent(AgentEventLocation.self, forKey: .location)
            ?? AgentEventLocation(worktreePath: "", cwd: "")
        let cursorValue = try container.decodeIfPresent(UInt64.self, forKey: .cursorValue) ?? 0
        let timestamp = try container.decodeIfPresent(Date.self, forKey: .timestamp)
            ?? Date(timeIntervalSince1970: 0)
        let source = (try? container.decodeIfPresent(
            EventSource.self,
            forKey: .source
        )) ?? .unknown(raw: "")
        // Unknown / missing trust levels decode as `.inferred` (the strongest
        // level correlation can reach, still non-verified) so provenance never
        // silently upgrades into `.verified`.
        let requestedTrustLevel = (try? container.decodeIfPresent(
            TrustLevel.self,
            forKey: .trustLevel
        )) ?? .inferred

        let payload: AgentEventPayload
        let payloadIsValid: Bool
        do {
            payload = try container.decodeIfPresent(
                AgentEventPayload.self,
                forKey: .payload
            ) ?? .none
            payloadIsValid = true
        } catch {
            payload = .none
            payloadIsValid = false
        }

        self.init(
            id: id,
            projectID: projectID,
            sessionID: sessionID,
            agentTypeRaw: agentTypeRaw,
            process: process,
            location: location,
            cursorValue: cursorValue,
            timestamp: timestamp,
            source: source,
            requestedTrustLevel: requestedTrustLevel,
            payload: payload,
            payloadIsValid: payloadIsValid
        )
    }

    private static func provenanceIsComplete(
        _ input: ProvenanceValidationInput
    ) -> Bool {
        let timestampSeconds = input.timestamp.timeIntervalSince1970
        return input.id != zeroUUID
            && input.projectID != zeroUUID
            && input.sessionID != zeroUUID
            && !input.agentTypeRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && input.process.terminalID != zeroUUID
            && input.process.processGeneration > 0
            && isAbsoluteMetadataPath(input.location.worktreePath)
            && isAbsoluteMetadataPath(input.location.cwd)
            && input.cursorValue > 0
            && timestampSeconds.isFinite
            && timestampSeconds != 0
    }

    private static func isAbsoluteMetadataPath(_ path: String) -> Bool {
        !path.isEmpty && path.hasPrefix("/") && !path.utf8.contains(0)
    }

    private static let zeroUUID = UUID(
        uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    )

    private struct ProvenanceValidationInput {
        let id: UUID
        let projectID: UUID
        let sessionID: UUID
        let agentTypeRaw: String
        let process: AgentProcessIdentity
        let location: AgentEventLocation
        let cursorValue: UInt64
        let timestamp: Date
    }
}
