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

/// Stable value route back to the terminal surface that owns a run.
///
/// `terminalID` identifies the terminal lifetime; `tabID` and `paneID` locate
/// it in the current layout. Moving a tab changes only `paneID`.
nonisolated struct AgentTaskRoute: Codable, Equatable, Sendable {
    let paneID: UUID
    let tabID: UUID
    let terminalID: UUID
    var availability: AgentTaskRouteAvailability

    private enum CodingKeys: String, CodingKey {
        case paneID
        case tabID
        case terminalID
        case availability
    }

    init(
        paneID: UUID,
        tabID: UUID,
        terminalID: UUID,
        availability: AgentTaskRouteAvailability = .available
    ) {
        self.paneID = paneID
        self.tabID = tabID
        self.terminalID = terminalID
        self.availability = availability
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

    private enum CodingKeys: String, CodingKey {
        case typeIdentifier
    }

    @MainActor
    init(agentType: AgentType) {
        typeIdentifier = agentType.stableIdentifier
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
/// It is intentionally excluded from persisted `AgentTaskRun` metadata.
nonisolated struct AgentVendorSessionIdentity: Equatable, Sendable {
    let provider: String
    let opaqueIdentifier: String
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

    private enum CodingKeys: String, CodingKey {
        case id
        case terminalID
        case process
        case state
        case liveness
        case startedAt
        case lastObservedAt
        case endedAt
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
        vendorIdentity = nil
    }
}

/// Durable user work identity. A task survives individual runs and process
/// generations, and stores only bounded value metadata.
nonisolated struct AgentTask: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    let project: AgentTaskProjectIdentity
    var route: AgentTaskRoute
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

    private enum CodingKeys: String, CodingKey {
        case id
        case project
        case route
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
    }
}

/// Value bundle used by the terminal bridge. It cannot retain UI or process
/// objects and can therefore be safely copied into registry mutations.
nonisolated struct AgentTaskBridgeContext: Sendable {
    let project: AgentTaskProjectIdentity
    let route: AgentTaskRoute
    let origin: AgentTaskOrigin
    let observedAt: Date

    init(
        project: AgentTaskProjectIdentity,
        route: AgentTaskRoute,
        origin: AgentTaskOrigin,
        observedAt: Date = Date()
    ) {
        self.project = project
        self.route = route
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
