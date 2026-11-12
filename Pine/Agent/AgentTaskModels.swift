//
//  AgentTaskModels.swift
//  Pine
//
//  Durable, value-only identity for cross-project agent work (#1302).
//

import Foundation

/// Canonical project and worktree scope for one durable agent task.
///
/// Paths are standardized lexically here. Project discovery resolves symlinks
/// before constructing the value, while persistence revalidates both paths away
/// from MainActor. The value deliberately contains no project or window object.
nonisolated struct AgentTaskProjectIdentity: Codable, Hashable, Sendable {
    let canonicalProjectPath: String
    let canonicalWorktreePath: String

    private enum CodingKeys: String, CodingKey {
        case canonicalProjectPath
        case canonicalWorktreePath
    }

    init(canonicalProjectPath: String, canonicalWorktreePath: String) {
        self.canonicalProjectPath = Self.standardize(canonicalProjectPath)
        self.canonicalWorktreePath = Self.standardize(canonicalWorktreePath)
    }

    private static func standardize(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    var persistenceKey: String {
        canonicalProjectPath + "\u{0}" + canonicalWorktreePath
    }
}

nonisolated enum AgentTaskRouteAvailability: String, Codable, Sendable {
    case available
    case background
    case missing
}

/// The runtime surface that owns a terminal route.
///
/// Surface identity is navigation and lifecycle authority. A project pane and
/// the application-wide Quick Terminal must never become interchangeable only
/// because their runtime UUIDs happen to match.
nonisolated enum AgentTaskTerminalSurface: String, Codable, Hashable, Sendable {
    case projectWindow
    case quickTerminalProject
    case quickTerminalStandalone

    var isQuickTerminal: Bool {
        self != .projectWindow
    }

    var isProjectBacked: Bool {
        self != .quickTerminalStandalone
    }
}

/// Stable value route back to the terminal surface that owns a run.
///
/// `terminalID` identifies the terminal lifetime; `tabID` and `paneID` locate
/// it in the current layout. Moving a tab changes only `paneID`.
nonisolated struct AgentTaskRoute: Codable, Equatable, Sendable {
    let surface: AgentTaskTerminalSurface
    let paneID: UUID
    let tabID: UUID
    let terminalID: UUID
    var availability: AgentTaskRouteAvailability

    private enum CodingKeys: String, CodingKey {
        case surface
        case paneID
        case tabID
        case terminalID
        case availability
    }

    init(
        surface: AgentTaskTerminalSurface = .projectWindow,
        paneID: UUID,
        tabID: UUID,
        terminalID: UUID,
        availability: AgentTaskRouteAvailability = .available
    ) {
        self.surface = surface
        self.paneID = paneID
        self.tabID = tabID
        self.terminalID = terminalID
        self.availability = availability
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // Routes persisted before Quick Terminal integration are all project
        // pane routes. Decode them additively without a metadata schema bump.
        surface = try values.decodeIfPresent(
            AgentTaskTerminalSurface.self,
            forKey: .surface
        ) ?? .projectWindow
        paneID = try values.decode(UUID.self, forKey: .paneID)
        tabID = try values.decode(UUID.self, forKey: .tabID)
        terminalID = try values.decode(UUID.self, forKey: .terminalID)
        availability = try values.decode(
            AgentTaskRouteAvailability.self,
            forKey: .availability
        )
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(surface, forKey: .surface)
        try values.encode(paneID, forKey: .paneID)
        try values.encode(tabID, forKey: .tabID)
        try values.encode(terminalID, forKey: .terminalID)
        try values.encode(availability, forKey: .availability)
    }
}

/// Privacy-safe presentation metadata captured from Pine-owned UI state.
///
/// This value is deliberately separate from ``AgentTaskRoute``: it is never
/// process, claim, navigation, or lifecycle authority. Production callers may
/// supply only the terminal's immutable `stableLabel`, never its dynamic OSC
/// title, working directory, command line, prompt, or output.
nonisolated struct AgentTaskPresentationContext: Codable, Equatable, Sendable {
    static let maximumTerminalLabelBytes = 256

    let terminalLabel: String

    init?(terminalStableLabel: String) {
        guard !terminalStableLabel.isEmpty,
              terminalStableLabel.utf8.count <= Self.maximumTerminalLabelBytes,
              !terminalStableLabel.contains("\0"),
              !terminalStableLabel.contains("\n"),
              !terminalStableLabel.contains("\r") else {
            return nil
        }
        terminalLabel = terminalStableLabel
    }
}

/// The source that first established durable task intent.
nonisolated enum AgentTaskOrigin: String, Codable, Sendable {
    /// A user launched an agent manually and Pine discovered its process.
    case discoveredInTerminal
    /// Pine reserved the task before launching an agent in its terminal.
    case pineLaunched
}

/// Forward-compatible agent metadata. Unknown type identifiers remain opaque.
nonisolated struct AgentDescriptor: Codable, Equatable, Sendable {
    let typeIdentifier: String
    let launchExecutable: String?

    private enum CodingKeys: String, CodingKey {
        case typeIdentifier
        case launchExecutable
    }

    @MainActor
    init(agentType: AgentType, launchExecutable: String? = nil) {
        typeIdentifier = agentType.stableIdentifier
        self.launchExecutable = launchExecutable
    }

    @MainActor
    var agentType: AgentType {
        AgentType(stableIdentifier: typeIdentifier)
            ?? .generic(name: String(typeIdentifier.prefix(64)))
    }
}

nonisolated enum AgentTaskLifecycle: String, Codable, Sendable {
    case active
    case paused
    case completed
    case dismissed
}

nonisolated enum AgentTaskAttention: String, Codable, Sendable {
    case none
    case waitingInput
    case completed
    case failed
}

/// Honest durable state for a Pine-owned launch that reached the PTY but was
/// interrupted by application termination before detector evidence arrived.
/// No PID, process generation, or start time is inferred for this marker.
nonisolated enum AgentTaskLaunchInterruption: String, Codable, Sendable {
    case acknowledgedBeforeVerification
}

/// A run's last reported state, kept separate from evidence freshness.
nonisolated enum AgentRunState: String, Codable, Sendable {
    case idle
    case thinking
    case executing
    case waitingInput
    case done

    @MainActor
    init(_ state: AgentState) {
        switch state {
        case .idle: self = .idle
        case .thinking: self = .thinking
        case .executing: self = .executing
        case .waitingInput: self = .waitingInput
        case .done: self = .done
        }
    }
}

/// Whether a run's last state is current evidence, stale evidence, or ended.
nonisolated enum AgentRunLiveness: String, Codable, Sendable {
    case live
    case stale
    case terminated

    init(_ liveness: AgentLiveness) {
        switch liveness {
        case .live: self = .live
        case .stale: self = .stale
        case .terminated: self = .terminated
        }
    }
}

/// Opaque vendor identity is an adapter hint, never Pine identity or authority.
///
/// It is persisted only in Pine's mode-0600 task metadata so a documented
/// adapter can offer an explicit resume after restart. Presentation code must
/// never render either value, and launch code must pass the identifier as one
/// argument instead of interpolating it into a shell command.
nonisolated struct AgentVendorSessionIdentity: Codable, Equatable, Hashable, Sendable {
    let provider: String
    let opaqueIdentifier: String
    /// Exact executable version observed when the adapter issued the identity.
    /// A resume is rejected when the immediately re-probed version differs.
    let executableVersion: String?

    init(
        provider: String,
        opaqueIdentifier: String,
        executableVersion: String? = nil
    ) {
        self.provider = provider
        self.opaqueIdentifier = opaqueIdentifier
        self.executableVersion = executableVersion
    }
}

// MARK: - ADE lifecycle and evidence contract (#1722)

/// The execution dimension of a task's current attempt.
///
/// This is a *current* view derived from the latest run, kept distinct from
/// the historical run state. `unknown` is the honest default: missing,
/// stale, contradictory, or unsupported positive evidence is never presented
/// as idle or working. Terminal silence and process exit are not idle.
nonisolated enum AgentTaskExecutionState: String, Codable, Sendable {
    /// A current attempt has an unresolved active turn.
    case working
    /// A current live authenticated attempt has an unresolved question or
    /// approval request. Transport loss degrades execution to `unknown`; the
    /// historical request is not actionable until revalidated.
    case blocked
    /// A current live session has no active turn or outstanding request,
    /// established by provider state or reconciliation. Idle is not task
    /// completion.
    case idle
    /// Current execution evidence is absent, stale, contradictory, or
    /// unsupported.
    case unknown

    /// Unknown future values fail closed to `.unknown`, never to a positive
    /// state.
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = Self(rawValue: rawValue) ?? .unknown
    }
}

/// The outcome of a settled attempt. `nil` while the attempt is in flight.
///
/// `success` requires an agent-reported completion plus all required
/// independent evidence bound to one code-state identity. Process exit,
/// terminal silence, and an agent claim alone establish `unverified`, never
/// `success`.
nonisolated enum AgentTaskOutcome: String, Codable, Sendable {
    case success
    case failure
    case cancellation
    case superseded
    case unverified

    /// Unknown future values fail closed to `.unverified`; an unfamiliar
    /// outcome can never decode into `.success`.
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = Self(rawValue: rawValue) ?? .unverified
    }
}

/// The independent verification dimension of the task's current result.
///
/// Verification is separate from the outcome: a settled attempt is
/// `unverified` until required independent evidence is recorded, and a later
/// relevant change downgrades `verified` to `stale` instead of erasing it.
nonisolated enum AgentTaskVerificationState: String, Codable, Sendable {
    /// No verification evidence has been recorded.
    case none
    /// Required verification is in flight (produced by the verification
    /// layer).
    case pending
    /// Required independent evidence is complete and bound to the code-state
    /// identity it was recorded against.
    case verified
    /// Evidence existed but was invalidated by relevant edits, environment
    /// changes, or relaunch. It must be repeated before Ready.
    case stale

    /// Unknown future values fail closed to `.stale`: evidence Pine cannot
    /// interpret is treated as invalidated, never as current.
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = Self(rawValue: rawValue) ?? .stale
    }
}

/// The user acceptance dimension.
///
/// Acceptance is a separate fact from verification: it never upgrades an
/// unverified result, and it is never silently inherited across relevant
/// changes.
nonisolated enum AgentTaskAcceptanceState: String, Codable, Sendable {
    case notAccepted
    case accepted

    /// Unknown future values fail closed to `.notAccepted`.
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = Self(rawValue: rawValue) ?? .notAccepted
    }
}

/// Conservative identity of the code state evidence was recorded against.
///
/// A commit ID alone never identifies a dirty tree: the fingerprints cover
/// tracked modifications, untracked files, and the relevant ignored inputs.
/// Only bounded hashes and identifiers are stored — no paths, contents, or
/// environment values.
nonisolated struct AgentTaskCodeStateIdentity: Codable, Hashable, Sendable {
    static let currentScheme: UInt8 = 1
    static let maximumHeadCommitBytes = 40
    static let fingerprintBytes = 64

    let scheme: UInt8
    /// Full 40-hex worktree head commit, or `nil` when the worktree has no
    /// head commit.
    let headCommit: String?
    /// SHA-256 (lowercase hex) over canonicalized tracked status entries.
    let trackedFingerprint: String
    /// SHA-256 (lowercase hex) over the sorted untracked path list.
    let untrackedFingerprint: String
    /// SHA-256 (lowercase hex) over relevant ignored inputs (for example
    /// generated files the required checks consume).
    let ignoredRelevantFingerprint: String

    init(
        scheme: UInt8 = Self.currentScheme,
        headCommit: String?,
        trackedFingerprint: String,
        untrackedFingerprint: String,
        ignoredRelevantFingerprint: String
    ) {
        self.scheme = scheme
        self.headCommit = headCommit
        self.trackedFingerprint = trackedFingerprint
        self.untrackedFingerprint = untrackedFingerprint
        self.ignoredRelevantFingerprint = ignoredRelevantFingerprint
    }
}

/// Bounded identity of the environment a verification ran under.
///
/// Components are opaque bounded strings; the configuration fingerprint
/// covers the relevant configuration inputs without storing their values.
nonisolated struct AgentTaskEnvironmentIdentity: Codable, Hashable, Sendable {
    static let currentScheme: UInt8 = 1
    static let maximumComponentBytes = 64

    let scheme: UInt8
    let osBuild: String?
    let toolchain: String?
    /// SHA-256 (lowercase hex) over the relevant configuration inputs, or
    /// `nil` when unknown.
    let configurationFingerprint: String?

    init(
        scheme: UInt8 = Self.currentScheme,
        osBuild: String?,
        toolchain: String?,
        configurationFingerprint: String?
    ) {
        self.scheme = scheme
        self.osBuild = osBuild
        self.toolchain = toolchain
        self.configurationFingerprint = configurationFingerprint
    }
}

/// One separate, individually bound evidence fact about an attempt (#1722).
///
/// Observed process completion, agent-reported completion, independent
/// checks, reviewer outcomes, and user acceptance remain separate facts: no
/// single fact establishes any other.
nonisolated enum AgentTaskEvidenceKind: String, Codable, Sendable {
    /// A Pine-observed process termination (process exit or terminal close).
    /// Never trusted beyond observation; not successful completion.
    case processCompletion
    /// The agent itself reported completion. A claim, not proof.
    case agentReportedCompletion
    /// An independent check result (produced by the verification layer).
    case independentCheck
    /// An independent reviewer outcome (produced by the review layer).
    case reviewerOutcome
    /// The user accepted the result.
    case userAcceptance
    /// The user cancelled the attempt.
    case userCancellation

    /// The results this kind may carry. Kind/result pairs outside this table
    /// are invalid.
    func allows(result: AgentTaskEvidenceResult) -> Bool {
        switch (self, result) {
        case (.processCompletion, .exited):
            return true
        case (.agentReportedCompletion, .reported):
            return true
        case (.independentCheck, .succeeded),
             (.independentCheck, .failed):
            return true
        case (.reviewerOutcome, .succeeded),
             (.reviewerOutcome, .failed),
             (.reviewerOutcome, .requestedChanges):
            return true
        case (.userAcceptance, .accepted):
            return true
        case (.userCancellation, .cancelled):
            return true
        default:
            return false
        }
    }

    /// Whether a fact of this kind may carry `verified` trust. A Pine process
    /// observation is at most `observed`; user actions and structured
    /// reports may be verified.
    var allowsVerifiedTrust: Bool {
        switch self {
        case .processCompletion:
            return false
        case .agentReportedCompletion,
             .independentCheck,
             .reviewerOutcome,
             .userAcceptance,
             .userCancellation:
            return true
        }
    }

    /// Whether a result of this kind counts as passing for settlement.
    func isPassing(_ result: AgentTaskEvidenceResult) -> Bool {
        switch (self, result) {
        case (.independentCheck, .succeeded),
             (.reviewerOutcome, .succeeded),
             (.userAcceptance, .accepted):
            return true
        default:
            return false
        }
    }
}

nonisolated enum AgentTaskEvidenceResult: Codable, Hashable, Sendable {
    case exited(status: Int32?)
    case reported
    case succeeded
    case failed
    case requestedChanges
    case accepted
    case cancelled
}

/// Stable identity of one evidence event, used for duplicate fencing.
///
/// Ordered structured delivery deduplicates by source sequence ALONE: a
/// reconnect re-emission (or clock skew) may carry a different observed
/// timestamp, so `observedAt` is dropped from the identity whenever a
/// sequence is present. Unordered delivery deduplicates by the observed
/// timestamp quantized to millisecond precision — the same quantization the
/// persistence encoding applies — so two sub-millisecond facts that were
/// admitted in memory stay distinct across a save/load round trip. Both
/// paths share this single definition, used by admission AND storage
/// validation.
nonisolated struct AgentTaskEvidenceEventIdentity: Hashable, Sendable {
    let kind: AgentTaskEvidenceKind
    let runID: UUID
    let processGeneration: UInt64
    let sourceSequence: UInt64?
    /// `nil` when `sourceSequence` is present (ordered delivery); otherwise
    /// the observed timestamp quantized to millisecond precision.
    let observedAt: Date?

    static func make(
        kind: AgentTaskEvidenceKind,
        runID: UUID,
        processGeneration: UInt64,
        sourceSequence: UInt64?,
        observedAt: Date
    ) -> AgentTaskEvidenceEventIdentity {
        AgentTaskEvidenceEventIdentity(
            kind: kind,
            runID: runID,
            processGeneration: processGeneration,
            sourceSequence: sourceSequence,
            observedAt: sourceSequence == nil
                ? quantizeToMilliseconds(observedAt)
                : nil
        )
    }

    /// Deterministic millisecond quantization matching the persistence
    /// encoding (`.millisecondsSince1970`).
    static func quantizeToMilliseconds(_ date: Date) -> Date {
        let milliseconds = (date.timeIntervalSince1970 * 1_000)
            .rounded(.towardZero)
        return Date(timeIntervalSince1970: milliseconds / 1_000)
    }
}

/// One bounded evidence fact bound to one attempt.
///
/// Fencing keys: attempt identity (`runID`), process incarnation
/// (`processGeneration`), provider session reference (`vendorSession`, where
/// available), and source sequence for ordered structured delivery. A late,
/// duplicate, replayed, nested, or foreign-provider event is fenced by these
/// keys and never settles a different or newer attempt.
nonisolated struct AgentTaskEvidenceFact: Codable, Hashable, Sendable {
    let kind: AgentTaskEvidenceKind
    let runID: UUID
    let processGeneration: UInt64
    let trust: TrustLevel
    let result: AgentTaskEvidenceResult
    let observedAt: Date
    /// Code-state identity the fact was recorded against, or `nil` when the
    /// recording layer has not bound one. Unbound facts cannot establish a
    /// verified result.
    let codeState: AgentTaskCodeStateIdentity?
    let environment: AgentTaskEnvironmentIdentity?
    /// Provider session reference where available. `nil` for facts the
    /// provider did not state (for example Pine process observations).
    let vendorSession: AgentVendorSessionIdentity?
    /// Source sequence for ordered structured delivery. `nil` for unordered
    /// or non-structured sources.
    let sourceSequence: UInt64?

    init(
        kind: AgentTaskEvidenceKind,
        runID: UUID,
        processGeneration: UInt64,
        trust: TrustLevel,
        result: AgentTaskEvidenceResult,
        observedAt: Date,
        codeState: AgentTaskCodeStateIdentity? = nil,
        environment: AgentTaskEnvironmentIdentity? = nil,
        vendorSession: AgentVendorSessionIdentity? = nil,
        sourceSequence: UInt64? = nil
    ) {
        self.kind = kind
        self.runID = runID
        self.processGeneration = processGeneration
        self.trust = trust
        self.result = result
        self.observedAt = observedAt
        self.codeState = codeState
        self.environment = environment
        self.vendorSession = vendorSession
        self.sourceSequence = sourceSequence
    }

    var eventIdentity: AgentTaskEvidenceEventIdentity {
        AgentTaskEvidenceEventIdentity.make(
            kind: kind,
            runID: runID,
            processGeneration: processGeneration,
            sourceSequence: sourceSequence,
            observedAt: observedAt
        )
    }
}

/// Identifiable record of the state a review or acceptance was made against.
///
/// Invalidation never erases a snapshot: later edits must be able to prove
/// they do not inherit an older review or acceptance, and the snapshot is the
/// identity that proof is checked against.
nonisolated struct AgentTaskResultSnapshot: Codable, Hashable, Sendable {
    let runID: UUID
    let outcome: AgentTaskOutcome
    let codeState: AgentTaskCodeStateIdentity?
    let environment: AgentTaskEnvironmentIdentity?
    let recordedAt: Date
}

/// Why a task is not Ready. Ready is derived only from current required
/// evidence; every gap names what must be repeated or recorded.
nonisolated enum AgentTaskReadinessGap: Hashable, Sendable, Codable {
    /// The current attempt has not settled yet.
    case attemptInProgress
    /// No settled attempt with a recorded outcome exists.
    case noSettledAttempt
    /// The settled attempt ended without all required independent evidence.
    case unverifiedOutcome
    case failedAttempt
    case cancelledAttempt
    case supersededAttempt
    /// The verification state is not currently `verified`.
    case verificationNotCurrent
    /// A required evidence kind has no recorded fact.
    case missingEvidence(AgentTaskEvidenceKind)
    /// A required evidence kind only has failing facts.
    case failingEvidence(AgentTaskEvidenceKind)
    /// Recorded evidence no longer matches the current code state (or its
    /// binding is missing), so the named check or review must be repeated.
    case staleEvidence(AgentTaskEvidenceKind)
    /// The current code state could not be established.
    case codeStateUnknown
    /// The current environment could not be established.
    case environmentUnknown
    /// The current environment differs from the evidence's environment.
    case environmentChanged
}

nonisolated struct AgentTaskReadiness: Equatable, Sendable {
    let isReady: Bool
    let gaps: [AgentTaskReadinessGap]
}

nonisolated enum AgentTaskEvidenceFence: String, Sendable, Equatable {
    /// The fact references a run this task does not contain.
    case unknownRun
    /// The fact's process incarnation does not match the bound run.
    case foreignProcess
    /// The fact carries a provider session reference that differs from the
    /// bound run's vendor identity (foreign or nested session).
    case foreignVendorSession
    /// The fact predates the bound run's start.
    case lateEvent
    /// An equivalent event was already admitted.
    case duplicate
    /// The fact violates the kind/result or trust contract.
    case invalidFact
    /// The task already holds the bounded maximum of evidence facts.
    case limitReached
}

nonisolated enum AgentTaskEvidenceAdmission: Sendable, Equatable {
    case accepted
    case fencedOut(AgentTaskEvidenceFence)
}

/// Process-start evidence that prevents PID reuse from extending an old run.
nonisolated struct AgentProcessEvidence: Codable, Equatable, Sendable {
    let processIdentifier: Int32?
    let processGeneration: UInt64
    let startIdentifier: String?
    let observedStartedAt: Date
    let startIsAuthoritative: Bool

    private enum CodingKeys: String, CodingKey {
        case processGeneration
        case observedStartedAt
    }

    init(
        processIdentifier: Int32?,
        processGeneration: UInt64,
        startIdentifier: String?,
        observedStartedAt: Date,
        startIsAuthoritative: Bool = false
    ) {
        self.processIdentifier = processIdentifier
        self.processGeneration = processGeneration
        self.startIdentifier = startIdentifier
        self.observedStartedAt = observedStartedAt
        self.startIsAuthoritative = startIsAuthoritative
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        processIdentifier = nil
        processGeneration = try values.decode(
            UInt64.self,
            forKey: .processGeneration
        )
        startIdentifier = nil
        startIsAuthoritative = false
        observedStartedAt = try values.decode(
            Date.self,
            forKey: .observedStartedAt
        )
    }

    func identifiesSameProcess(as other: Self) -> Bool {
        processIdentifier == other.processIdentifier
            && processGeneration == other.processGeneration
            && startIdentifier == other.startIdentifier
            && observedStartedAt == other.observedStartedAt
            && startIsAuthoritative == other.startIsAuthoritative
    }
}

/// One observed execution of an agent task. The UUID intentionally equals the
/// bridged legacy `AgentSession.id` so Activity, History, provenance, verified
/// patches, and checked undo retain their existing join key.
nonisolated struct AgentTaskRunInput: Sendable {
    let id: UUID
    let terminalID: UUID
    let process: AgentProcessEvidence
    let status: AgentTaskRunStatus
    let lifecycleAccuracy: FirstPartyAgentNotificationAccuracy

    init(
        id: UUID,
        terminalID: UUID,
        process: AgentProcessEvidence,
        status: AgentTaskRunStatus,
        lifecycleAccuracy: FirstPartyAgentNotificationAccuracy = .processTerminationOnly
    ) {
        self.id = id
        self.terminalID = terminalID
        self.process = process
        self.status = status
        self.lifecycleAccuracy = lifecycleAccuracy
    }
}

nonisolated struct AgentTaskRunStatus: Sendable {
    let state: AgentRunState
    let liveness: AgentRunLiveness
    let observedAt: Date
}

nonisolated struct AgentTaskRun: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let terminalID: UUID
    var process: AgentProcessEvidence
    var state: AgentRunState
    var liveness: AgentRunLiveness
    let startedAt: Date
    var lastObservedAt: Date
    var endedAt: Date?
    var vendorIdentity: AgentVendorSessionIdentity?
    var lifecycleAccuracy: FirstPartyAgentNotificationAccuracy
    /// Recorded outcome of this attempt. `nil` while the attempt is in
    /// flight; only a settled attempt may carry one (#1722).
    var outcome: AgentTaskOutcome?

    private enum CodingKeys: String, CodingKey {
        case id
        case terminalID
        case process
        case state
        case liveness
        case startedAt
        case lastObservedAt
        case endedAt
        case vendorIdentity
        case lifecycleAccuracy
        case outcome
    }

    init(_ input: AgentTaskRunInput) {
        id = input.id
        terminalID = input.terminalID
        process = input.process
        state = input.status.state
        liveness = input.status.liveness
        startedAt = input.process.observedStartedAt
        lastObservedAt = input.status.observedAt
        endedAt = input.status.liveness == .terminated
            ? input.status.observedAt
            : nil
        vendorIdentity = nil
        lifecycleAccuracy = input.lifecycleAccuracy
        outcome = nil
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        terminalID = try values.decode(UUID.self, forKey: .terminalID)
        process = try values.decode(AgentProcessEvidence.self, forKey: .process)
        state = try values.decode(AgentRunState.self, forKey: .state)
        liveness = try values.decode(AgentRunLiveness.self, forKey: .liveness)
        startedAt = try values.decode(Date.self, forKey: .startedAt)
        lastObservedAt = try values.decode(Date.self, forKey: .lastObservedAt)
        endedAt = try values.decodeIfPresent(Date.self, forKey: .endedAt)
        vendorIdentity = try values.decodeIfPresent(
            AgentVendorSessionIdentity.self,
            forKey: .vendorIdentity
        )
        lifecycleAccuracy = try values.decodeIfPresent(
            FirstPartyAgentNotificationAccuracy.self,
            forKey: .lifecycleAccuracy
        ) ?? .processTerminationOnly
        outcome = try values.decodeIfPresent(
            AgentTaskOutcome.self,
            forKey: .outcome
        )
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(terminalID, forKey: .terminalID)
        try values.encode(process, forKey: .process)
        try values.encode(state, forKey: .state)
        try values.encode(liveness, forKey: .liveness)
        try values.encode(startedAt, forKey: .startedAt)
        try values.encode(lastObservedAt, forKey: .lastObservedAt)
        try values.encodeIfPresent(endedAt, forKey: .endedAt)
        try values.encodeIfPresent(vendorIdentity, forKey: .vendorIdentity)
        try values.encode(lifecycleAccuracy, forKey: .lifecycleAccuracy)
        try values.encodeIfPresent(outcome, forKey: .outcome)
    }
}

/// Durable user work identity. A task survives individual runs and process
/// generations, and stores only bounded value metadata.
nonisolated struct AgentTask: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let project: AgentTaskProjectIdentity
    var route: AgentTaskRoute
    var presentationContext: AgentTaskPresentationContext?
    let descriptor: AgentDescriptor
    let origin: AgentTaskOrigin
    var lifecycle: AgentTaskLifecycle
    var runs: [AgentTaskRun]
    let createdAt: Date
    var updatedAt: Date
    var lastActivityAt: Date
    var completedAt: Date?
    var isUnread: Bool
    var attention: AgentTaskAttention
    var title: String?
    var objective: String?
    var launchInterruption: AgentTaskLaunchInterruption?
    // ADE lifecycle and evidence contract (#1722). All additive: metadata
    // persisted before schema v3 decodes to the fail-closed defaults.
    var executionState: AgentTaskExecutionState
    var evidence: [AgentTaskEvidenceFact]
    var verificationState: AgentTaskVerificationState
    var acceptanceState: AgentTaskAcceptanceState
    var reviewedSnapshot: AgentTaskResultSnapshot?
    var acceptedSnapshot: AgentTaskResultSnapshot?

    private enum CodingKeys: String, CodingKey {
        case id
        case project
        case route
        case presentationContext
        case descriptor
        case origin
        case lifecycle
        case runs
        case createdAt
        case updatedAt
        case lastActivityAt
        case completedAt
        case isUnread
        case attention
        case title
        case objective
        case launchInterruption
        case executionState
        case evidence
        case verificationState
        case acceptanceState
        case reviewedSnapshot
        case acceptedSnapshot
    }

    init(
        descriptor: AgentDescriptor,
        context: AgentTaskBridgeContext,
        title: String? = nil,
        objective: String? = nil,
        createdAt: Date? = nil
    ) {
        let timestamp = createdAt ?? context.observedAt
        id = UUID()
        project = context.project
        route = context.route
        presentationContext = context.presentationContext
        self.descriptor = descriptor
        origin = context.origin
        lifecycle = .active
        runs = []
        self.createdAt = timestamp
        updatedAt = timestamp
        lastActivityAt = timestamp
        completedAt = nil
        isUnread = false
        attention = .none
        self.title = title
        self.objective = objective
        launchInterruption = nil
        executionState = .unknown
        evidence = []
        verificationState = .none
        acceptanceState = .notAccepted
        reviewedSnapshot = nil
        acceptedSnapshot = nil
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        project = try values.decode(
            AgentTaskProjectIdentity.self,
            forKey: .project
        )
        route = try values.decode(AgentTaskRoute.self, forKey: .route)
        presentationContext = try values.decodeIfPresent(
            AgentTaskPresentationContext.self,
            forKey: .presentationContext
        )
        descriptor = try values.decode(
            AgentDescriptor.self,
            forKey: .descriptor
        )
        origin = try values.decode(AgentTaskOrigin.self, forKey: .origin)
        lifecycle = try values.decode(
            AgentTaskLifecycle.self,
            forKey: .lifecycle
        )
        runs = try values.decode([AgentTaskRun].self, forKey: .runs)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        lastActivityAt = try values.decode(
            Date.self,
            forKey: .lastActivityAt
        )
        completedAt = try values.decodeIfPresent(
            Date.self,
            forKey: .completedAt
        )
        isUnread = try values.decode(Bool.self, forKey: .isUnread)
        attention = try values.decode(
            AgentTaskAttention.self,
            forKey: .attention
        )
        title = try values.decodeIfPresent(String.self, forKey: .title)
        objective = try values.decodeIfPresent(
            String.self,
            forKey: .objective
        )
        launchInterruption = try values.decodeIfPresent(
            AgentTaskLaunchInterruption.self,
            forKey: .launchInterruption
        )
        // Additive schema v3 fields with fail-closed defaults.
        executionState = try values.decodeIfPresent(
            AgentTaskExecutionState.self,
            forKey: .executionState
        ) ?? .unknown
        evidence = try values.decodeIfPresent(
            [AgentTaskEvidenceFact].self,
            forKey: .evidence
        ) ?? []
        verificationState = try values.decodeIfPresent(
            AgentTaskVerificationState.self,
            forKey: .verificationState
        ) ?? .none
        acceptanceState = try values.decodeIfPresent(
            AgentTaskAcceptanceState.self,
            forKey: .acceptanceState
        ) ?? .notAccepted
        reviewedSnapshot = try values.decodeIfPresent(
            AgentTaskResultSnapshot.self,
            forKey: .reviewedSnapshot
        )
        acceptedSnapshot = try values.decodeIfPresent(
            AgentTaskResultSnapshot.self,
            forKey: .acceptedSnapshot
        )
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(project, forKey: .project)
        try values.encode(route, forKey: .route)
        try values.encodeIfPresent(
            presentationContext,
            forKey: .presentationContext
        )
        try values.encode(descriptor, forKey: .descriptor)
        try values.encode(origin, forKey: .origin)
        try values.encode(lifecycle, forKey: .lifecycle)
        try values.encode(runs, forKey: .runs)
        try values.encode(createdAt, forKey: .createdAt)
        try values.encode(updatedAt, forKey: .updatedAt)
        try values.encode(lastActivityAt, forKey: .lastActivityAt)
        try values.encodeIfPresent(completedAt, forKey: .completedAt)
        try values.encode(isUnread, forKey: .isUnread)
        try values.encode(attention, forKey: .attention)
        try values.encodeIfPresent(title, forKey: .title)
        try values.encodeIfPresent(objective, forKey: .objective)
        try values.encodeIfPresent(
            launchInterruption,
            forKey: .launchInterruption
        )
        try values.encode(executionState, forKey: .executionState)
        try values.encode(evidence, forKey: .evidence)
        try values.encode(verificationState, forKey: .verificationState)
        try values.encode(acceptanceState, forKey: .acceptanceState)
        try values.encodeIfPresent(reviewedSnapshot, forKey: .reviewedSnapshot)
        try values.encodeIfPresent(
            acceptedSnapshot,
            forKey: .acceptedSnapshot
        )
    }
}

/// Value bundle used by the terminal bridge. It cannot retain UI or process
/// objects and can therefore be safely copied into registry mutations.
nonisolated struct AgentTaskBridgeContext: Sendable {
    let project: AgentTaskProjectIdentity
    let route: AgentTaskRoute
    let presentationContext: AgentTaskPresentationContext?
    let origin: AgentTaskOrigin
    let observedAt: Date

    init(
        project: AgentTaskProjectIdentity,
        route: AgentTaskRoute,
        presentationContext: AgentTaskPresentationContext? = nil,
        origin: AgentTaskOrigin,
        observedAt: Date = Date()
    ) {
        self.project = project
        self.route = route
        self.presentationContext = presentationContext
        self.origin = origin
        self.observedAt = observedAt
    }
}

nonisolated enum AgentTaskPersistenceFlushResult: Equatable, Sendable {
    case saved
    case failed
}

nonisolated struct AgentTaskLaunchBoundary: Sendable {
    let generationFloor: UInt64
    let capturedAt: Date
}
