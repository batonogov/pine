import CryptoKit
import Foundation
import Synchronization

/// Explicit session action for one Kimi ACP process. Each action starts a NEW
/// `kimi acp` child: `load` replays history, `resume` skips replay, and
/// `fork` branches a source session. None reattaches to an old live process,
/// and each creates a new Pine attempt + source namespace at registry ingress.
nonisolated enum KimiACPSessionAction: Equatable, Sendable {
    case new(additionalDirectories: [String] = [])
    case load(sessionID: String)
    case resume(sessionID: String)
    case fork(sessionID: String)

    func validate() throws {
        switch self {
        case .new(let directories):
            guard directories.count <= 8 else { throw KimiACPWireError.capacity }
            for directory in directories {
                guard directory.hasPrefix("/"), directory.utf8.count <= 4_096,
                      !directory.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                    throw KimiACPWireError.invalidProtocol
                }
            }
        case .load(let value), .resume(let value), .fork(let value):
            guard KimiACPWire.validSessionID(value) else { throw KimiACPWireError.invalidSessionID }
        }
    }

    var sourceSessionID: String? {
        switch self {
        case .new: nil
        case .load(let value), .resume(let value), .fork(let value): value
        }
    }
}

/// ACP prompt content. Image and resource blocks are included ONLY when the
/// user explicitly supplied them; a blob resource (no text) is rejected with
/// an explanation before submission because Kimi drops it with only a warn.
nonisolated struct KimiACPPromptContent: Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    struct Image: Equatable, Sendable {
        let mimeType: String
        let data: Data
    }
    struct Resource: Equatable, Sendable {
        let uri: String
        let text: String
    }
    static let maximumTextBytes = 65_536
    static let maximumImages = 4
    static let maximumImageBase64Bytes = 512 * 1_024
    static let maximumResources = 8
    static let maximumResourceTextBytes = 65_536
    /// Image base64 + resource text joint cap: keeps text and JSON overhead
    /// under the 1 MB frame limit so `KimiACPWire.encode` cannot fail.
    static let maximumTotalContentBytes = 900 * 1_024

    let text: String
    let images: [Image]
    let resources: [Resource]

    var description: String { "<redacted:kimi-prompt-content>" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["value": description]) }

    init(text: String, images: [Image] = [], resources: [Resource] = []) throws {
        guard !text.isEmpty, text.utf8.count <= Self.maximumTextBytes else {
            throw KimiACPWireError.invalidProtocol
        }
        guard images.count <= Self.maximumImages else { throw KimiACPWireError.capacity }
        for image in images {
            guard image.mimeType.utf8.count >= 3, image.mimeType.utf8.count <= 128,
                  image.data.base64EncodedData().count <= Self.maximumImageBase64Bytes else {
                throw KimiACPWireError.invalidProtocol
            }
        }
        guard resources.count <= Self.maximumResources else { throw KimiACPWireError.capacity }
        for resource in resources {
            guard resource.uri.utf8.count >= 1, resource.uri.utf8.count <= 2_048,
                  !resource.uri.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  !resource.text.isEmpty, resource.text.utf8.count <= Self.maximumResourceTextBytes else {
                throw KimiACPWireError.invalidProtocol
            }
        }
        let totalContentBytes = images.reduce(0) { $0 + $1.data.base64EncodedData().count }
            + resources.reduce(0) { $0 + $1.text.utf8.count }
        guard totalContentBytes <= Self.maximumTotalContentBytes else {
            throw KimiACPWireError.capacity
        }
        self.text = text
        self.images = images
        self.resources = resources
    }

    /// Fails closed against the observed capability matrix. The blob-resource
    /// drop is documented by Kimi as warn-only, so it is refused here with an
    /// explanation instead of being submitted to be silently lost.
    func blocks(capabilities: KimiACPAgentIdentity.Capabilities) throws -> [AgentEventJSON] {
        var blocks: [AgentEventJSON] = [.object(["type": .string("text"), "text": .string(text)])]
        for image in images {
            guard capabilities.image else { throw KimiACPWireError.unsupportedCapability }
            let base64 = image.data.base64EncodedString()
            blocks.append(.object([
                "type": .string("image"),
                "data": .string(base64),
                "mimeType": .string(image.mimeType)
            ]))
        }
        for resource in resources {
            guard capabilities.embeddedContext else { throw KimiACPWireError.unsupportedCapability }
            blocks.append(.object([
                "type": .string("resource"),
                "resource": .object([
                    "uri": .string(resource.uri),
                    "text": .string(resource.text)
                ])
            ]))
        }
        return blocks
    }
}

/// One supervised `kimi acp` conversation attempt. All presentation data is
/// transient and bounded; no transcript, token, or credential is retained.
/// JSON-RPC IDs are request correlation, never a global lifecycle sequence.
actor KimiACPSession: AgentAdapterReviewingSession, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable {
    nonisolated var description: String { "<redacted:kimi-acp-session>" }
    nonisolated var debugDescription: String { description }
    nonisolated var customMirror: Mirror { Mirror(self, children: ["value": description]) }

    enum State: Equatable, Sendable {
        case fresh, starting, idle, submitted, working, waiting, cancelRequested
        case cancelled, unverified, failed, unknown, stopped
    }

    /// Acknowledgement is not request resolution, confirmed cancellation, or
    /// aggregate settlement. Uncertain dispatch is never retried implicitly.
    enum Dispatch: Equatable, Sendable { case acknowledged, uncertain }

    enum ResponseDisposition: Sendable { case recorded, fenced }

    struct Question: Sendable, CustomStringConvertible,
        CustomDebugStringConvertible, CustomReflectable {
        enum Kind: Sendable { case question, approval }
        let request: VendorReference
        let context: VendorReference
        let kind: Kind
        let toolCall: VendorReference?
        let form: KimiACPForm?
        let options: [String: String]
        let sequence: Int
        var description: String { "<redacted:kimi-question>" }
        var debugDescription: String { description }
        var customMirror: Mirror { Mirror(self, children: ["value": description]) }
    }

    struct Snapshot: Sendable, CustomStringConvertible,
        CustomDebugStringConvertible, CustomReflectable {
        let state: State
        let result: String
        /// True once presentation retention hit its cap and dropped chunks.
        let resultTruncated: Bool
        let questions: [Question]
        let submittedQuestions: [Question]
        let context: VendorReference?
        let nativeSession: VendorReference?
        let cancellationRequested: Bool
        let answersAwaitingEvidence: Int
        /// Last explicit parent prompt's outcome, separate from late activity.
        let parentOutcome: State?
        let inputFenced: Bool
        let effectiveConfig: [KimiACPConfigOption]
        /// ACP has no turn settlement event; provider completion is a claim.
        let settlementKnown = false
        let ready = false
        var description: String { "<redacted:kimi-snapshot>" }
        var debugDescription: String { description }
        var customMirror: Mirror { Mirror(self, children: ["value": description]) }
    }

    private struct Pending {
        let wireID: CodexAppServerRequestID
        let question: Question
        let method: String
        let fence: KimiACPRequestFence
    }

    nonisolated let contract: NegotiatedAdapterContract
    private let request: AgentAdapterSessionRequest
    private let launch: @Sendable (ContinuousClock.Instant) async throws -> any KimiACPTransport
    private var ownedTransport: (any KimiACPTransport)?
    private var transport: any KimiACPTransport {
        get throws {
            guard let ownedTransport else { throw KimiACPWireError.unavailable }
            return ownedTransport
        }
    }
    private let cwd: String
    private let deadline: ContinuousClock.Instant
    private let action: KimiACPSessionAction
    private let beforeStartWrite: @Sendable () throws -> Void
    private let revokeOwnership: @Sendable () -> Void
    private let sessionBound: @Sendable (VendorReference) async throws -> Void
    private let promptResponded: @Sendable (State) async throws -> ResponseDisposition
    private let accountGate: @Sendable () throws -> Bool
    private var connection = KimiACPConnection()
    private var mapper: KimiACPTaskMapper?
    private var identity: KimiACPAgentIdentity?
    private var state = State.fresh
    private var nativeSession: String?
    private var promptID: CodexAppServerRequestID?
    private var promptContext: VendorReference?
    private var pending: [VendorReference: Pending] = [:]
    private var sentResponses: [VendorReference: Pending] = [:]
    private var result = ""
    private var resultTruncated = false
    private var writing = false
    private var cancellationRequested = false
    private var parentOutcome: State?
    private var inputFenced = false
    private var effectiveConfig: [KimiACPConfigOption] = []
    private var reader: Task<Void, Never>?
    private var observer: (@Sendable (Snapshot) async -> Void)?
    private var questionSequence = 0
    /// Teardown ran exactly once: settle/failure set `.unknown` inline before
    /// calling, so a state check cannot express idempotency here.
    private var connectionLost = false
    /// Launch-boundary observation for the discovery report; nil when the
    /// session owner cannot attribute the executable.
    private let discovery: KimiACPConfigurationDiscovery.Input?
    /// Read-only discovery observation produced from the pinned initialize
    /// gate and the session setup response. Effective values stay unknown
    /// without a resolved executable.
    private(set) var discoveryReport: AgentTaskDiscoveryReport?

    /// `load`/`resume`/`fork` are explicit exact-ID actions, never
    /// latest-session lookup. Their gate must revalidate cwd/configuration
    /// and the new attempt binding before the process starts.
    init(request: AgentAdapterSessionRequest,
         launch: @escaping @Sendable (ContinuousClock.Instant) async throws -> any KimiACPTransport,
         cwd: String, deadline: ContinuousClock.Instant,
         action: KimiACPSessionAction = .new(),
         beforeStartWrite: @escaping @Sendable () throws -> Void,
         revokeOwnership: @escaping @Sendable () -> Void,
         sessionBound: @escaping @Sendable (VendorReference) async throws -> Void,
         promptResponded: @escaping @Sendable (State) async throws -> ResponseDisposition,
         accountGate: @escaping @Sendable () throws -> Bool,
         discovery: KimiACPConfigurationDiscovery.Input? = nil) throws {
        try action.validate()
        guard request.resumeFrom == nil else { throw AdapterSessionError.checkpointNotSupported }
        guard request.contract.profile == (try Self.profile()),
              request.contract.agentID.value == "kimiCode",
              request.contract.version == PineAdapterContractVersion(major: 1, minor: 1),
              cwd.hasPrefix("/"), !cwd.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              request.reviewBinding.map({
                  cwd == $0.lease.canonicalWorktree.path
              }) ?? true else {
            throw AdapterSessionError.contractMismatch
        }
        self.request = request
        contract = request.contract
        self.launch = launch
        self.cwd = cwd
        self.deadline = deadline
        self.action = action
        self.beforeStartWrite = beforeStartWrite
        self.revokeOwnership = revokeOwnership
        self.sessionBound = sessionBound
        self.promptResponded = promptResponded
        self.accountGate = accountGate
        self.discovery = discovery
    }

    /// ACP delivers session updates without a lifecycle sequence or replay
    /// cursor; ordering is unordered and replay is none. JSON-RPC IDs never
    /// substitute for a global sequence.
    nonisolated static func profile() throws -> AdapterCapabilityProfile {
        try AdapterCapabilityProfile(
            transport: .ownedStandardIO,
            lifecycle: AdapterLifecycleCapabilities(signals: [
                .init(scope: .session, phase: .working),
                .init(scope: .session, phase: .waitingForQuestion),
                .init(scope: .session, phase: .waitingForApproval),
                // Required by requestResolved validation, never session settlement.
                .init(scope: .session, phase: .settled)
            ], evidence: []),
            delivery: AdapterDeliverySemantics(ordering: .unordered, minimumAuthentication: .ownedChildPipe)
        )
    }

    /// One application-lifetime consumer; reopening a window reuses that owner.
    func observe(_ observer: @escaping @Sendable (Snapshot) async -> Void) async throws {
        guard self.observer == nil else { throw KimiACPWireError.invalidState }
        self.observer = observer
        await notify()
    }

    private func notify() async {
        if let observer { await observer(snapshot()) }
    }

    func snapshot() -> Snapshot {
        // A dead physical owner must not leave an actionable cached question.
        if ownedTransport != nil, (try? transport.validate()) == nil,
           state != .fresh, state != .starting, state != .stopped {
            loseConnection()
        }
        return Snapshot(
            state: state, result: result, resultTruncated: resultTruncated,
            questions: pending.values.sorted { $0.question.sequence < $1.question.sequence }.map(\.question),
            submittedQuestions: sentResponses.values.sorted { $0.question.sequence < $1.question.sequence }.map(\.question),
            context: promptContext,
            nativeSession: nativeSession.flatMap { try? VendorReference(role: .conversation, value: $0) },
            cancellationRequested: cancellationRequested,
            answersAwaitingEvidence: sentResponses.count, parentOutcome: parentOutcome,
            inputFenced: inputFenced, effectiveConfig: effectiveConfig
        )
    }

    var reviewerIdentity: AgentVendorSessionIdentity {
        get throws {
            guard let nativeSession else { throw KimiACPWireError.invalidState }
            return AgentVendorSessionIdentity(
                provider: contract.agentID.value, opaqueIdentifier: nativeSession,
                executableVersion: KimiACPExecutableIdentity.supportedVersion
            )
        }
    }

    /// Structured review response from this exact owned ACP session. Provider
    /// completion remains only a review claim until the coordinator admits it.
    func review(
        _ review: AgentAdapterReviewRequest,
        beforeDispatch: @escaping @Sendable () throws -> Void
    ) async throws -> AgentAdapterReviewResult {
        let prompt = """
        Independently review the exact candidate without modifying it.
        Requested outcome:\n\(review.objective)
        Explicit criteria:\n\(review.criteria)
        Candidate fingerprint: \(review.candidateFingerprint)
        Check plan: \(review.checkPlanIdentity)
        Pine-observed required checks passed for this exact candidate; execution: \
        \(review.binding.checks.executionID.uuidString).
        Candidate changes:\n\(review.binding.changeContext)
        Return only JSON: {"outcome":"passed"} or \
        {"outcome":"requestedChanges","finding":"one actionable finding"}.
        """
        let content = try KimiACPPromptContent(text: prompt)
        guard try await submit(content, beforeDispatch: beforeDispatch) == .acknowledged else {
            throw KimiACPWireError.unavailable
        }
        while promptID != nil {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw KimiACPWireError.closed }
            try await Task.sleep(for: .milliseconds(10))
        }
        switch parentOutcome {
        case .cancelled: throw CancellationError()
        case .unverified: break
        default: throw KimiACPWireError.invalidState
        }
        guard !resultTruncated else { throw KimiACPWireError.capacity }
        let response = try JSONDecoder().decode(ReviewResponse.self, from: Data(result.utf8))
        switch response.outcome {
        case "passed":
            guard response.finding == nil else { throw KimiACPWireError.invalidProtocol }
            return AgentAdapterReviewResult(outcome: .passed, finding: nil)
        case "requestedChanges":
            guard let finding = response.finding, !finding.isEmpty,
                  finding.utf8.count <= 8_192 else { throw KimiACPWireError.invalidProtocol }
            return AgentAdapterReviewResult(outcome: .requestedChanges, finding: finding)
        default:
            throw KimiACPWireError.invalidProtocol
        }
    }

    private struct ReviewResponse: Decodable {
        let outcome: String
        let finding: String?
    }

    func start() async throws {
        guard state == .fresh else { throw KimiACPWireError.invalidState }
        state = .starting
        await notify()
        do {
            let launched = try await launch(min(deadline, .now.advanced(by: .seconds(30))))
            guard state == .starting, !Task.isCancelled else {
                launched.close()
                await launched.stop(deadline: min(deadline, .now.advanced(by: .seconds(2))))
                throw CancellationError()
            }
            ownedTransport = launched
            var initialization: Data?
            try connection.initialize { initialization = $0 }
            guard let initialization else { throw KimiACPWireError.invalidState }
            try await bootstrapWrite(initialization)
            let initResult: AgentEventJSON
            switch try await bootstrapRead(id: .integer(0)) {
            case .initialized(let result): initResult = result
            default: throw KimiACPWireError.invalidProtocol
            }
            let identity = try KimiACPAgentIdentity(
                response: initResult,
                agentName: KimiACPCapabilities.agentName,
                pinnedVersion: KimiACPCapabilities.pinnedCLIVersion
            )
            self.identity = identity
            // Provider authentication is checked separately: transport
            // ownership never proves the account is authenticated.
            if identity.requiresAuthentication {
                guard try accountGate() else { throw KimiACPWireError.authenticationRequired }
            }
            try await createSession(identity: identity)
            guard state == .starting, !Task.isCancelled else {
                await stop(deadline: min(deadline, .now.advanced(by: .seconds(2))))
                throw CancellationError()
            }
            state = .idle
            reader = Task { await self.readLoop() }
            await notify()
        } catch {
            await stop(deadline: min(deadline, .now.advanced(by: .seconds(2))))
            throw error
        }
    }

    private func bootstrapWrite(_ bytes: Data) async throws {
        let limit = min(deadline, .now.advanced(by: .seconds(30)))
        let transport = try self.transport
        let gate = beforeStartWrite
        try await transport.write(bytes, deadline: limit, beforeWrite: {
            try gate()
            try transport.validate()
        })
    }

    private enum BootstrapDelivery {
        case initialized(AgentEventJSON)
        case settled(AgentEventJSON)
    }

    /// Reads until the correlated bootstrap response. Only `session/load`
    /// replays `session/update` history before settling; replay is bounded
    /// historical data, never live activity, questions, or execution
    /// authority.
    private func bootstrapRead(id: CodexAppServerRequestID) async throws -> BootstrapDelivery {
        let limit = min(deadline, .now.advanced(by: .seconds(30)))
        var replayCount = 0
        while let message = try await transport.read(deadline: limit), state == .starting {
            switch message {
            case .response(let receivedID, _) where receivedID == id,
                 .failure(let receivedID, _) where receivedID == id:
                // Consume through the connection so pending stays accurate.
                var replay: Data?
                let delivery = try connection.receive(message, connection: connection.identity) {
                    replay = $0
                }
                guard replay == nil else { throw KimiACPWireError.invalidProtocol }
                switch delivery {
                case .initialized(let value):
                    guard id == .integer(0) else { throw KimiACPWireError.invalidProtocol }
                    return .initialized(value)
                case .response(_, _, let result):
                    return .settled(result)
                case .failure(_, _, let code):
                    throw KimiACPWireError.providerFailure(code)
                default:
                    throw KimiACPWireError.invalidProtocol
                }
            case .notification(let method, let params)
                where id != .integer(0) && method == "session/update" && isLoadAction():
                let fields = try KimiACPWire.object(params)
                guard let source = action.sourceSessionID,
                      KimiACPWire.matches(fields["sessionId"], string: source) else {
                    throw KimiACPWireError.invalidProtocol
                }
                replayCount += 1
                guard replayCount <= 256 else { throw KimiACPWireError.capacity }
            default:
                throw KimiACPWireError.invalidProtocol
            }
        }
        throw KimiACPWireError.closed
    }

    private func isLoadAction() -> Bool {
        if case .load = action { return true }
        return false
    }

    private func createSession(identity: KimiACPAgentIdentity) async throws {
        let params: [String: AgentEventJSON]
        let method: String
        switch action {
        case .new(let directories):
            guard directories.isEmpty || identity.capabilities.additionalDirectories else {
                throw KimiACPWireError.unsupportedCapability
            }
            var fields: [String: AgentEventJSON] = ["cwd": .string(cwd), "mcpServers": .array([])]
            if !directories.isEmpty {
                // Documented honored-on-new-only field; sending it elsewhere
                // would claim an environment change Kimi ignores.
                fields["additionalDirectories"] = .array(directories.map { .string($0) })
            }
            params = fields
            method = "session/new"
        case .load(let source):
            guard identity.capabilities.loadSession else { throw KimiACPWireError.unsupportedCapability }
            params = ["sessionId": .string(source), "cwd": .string(cwd), "mcpServers": .array([])]
            method = "session/load"
        case .resume(let source):
            guard identity.capabilities.sessionResume else { throw KimiACPWireError.unsupportedCapability }
            params = ["sessionId": .string(source), "cwd": .string(cwd), "mcpServers": .array([])]
            method = "session/resume"
        case .fork(let source):
            // Kimi documents fork ignoring supplied cwd/directories/MCP; send
            // only the source ID and never advertise an environment change
            // merely because a field would have been accepted.
            guard identity.capabilities.sessionFork else { throw KimiACPWireError.unsupportedCapability }
            params = ["sessionId": .string(source)]
            method = "session/fork"
        }
        var bytes: Data?
        let id = try connection.request(method: method, params: .object(params)) { bytes = $0 }
        guard let bytes else { throw KimiACPWireError.invalidState }
        try await bootstrapWrite(bytes)
        let result: AgentEventJSON
        switch try await bootstrapRead(id: id) {
        case .settled(let value): result = value
        default: throw KimiACPWireError.invalidProtocol
        }
        let fields = try KimiACPWire.object(result)
        let sessionID: String
        if let source = action.sourceSessionID, case .fork = action {
            sessionID = try KimiACPWire.string(fields["sessionId"] ?? .null)
        } else if let source = action.sourceSessionID {
            // load/resume settle on the same session; a different ID is not a
            // reattachment and not a new conversation we requested.
            sessionID = try KimiACPWire.string(fields["sessionId"] ?? .string(source))
            guard sessionID == source else { throw KimiACPWireError.invalidProtocol }
        } else {
            sessionID = try KimiACPWire.string(fields["sessionId"])
        }
        guard KimiACPWire.validSessionID(sessionID), sessionID != nativeSession else {
            throw KimiACPWireError.invalidProtocol
        }
        nativeSession = sessionID
        effectiveConfig = try KimiACPConfigOptions.parse(fields["configOptions"])
        // Without a launch-boundary input the session cannot attribute the
        // observation to a resolved executable, so it produces no report:
        // the shared model forbids claiming transport/session state without
        // an identity.
        if let discovery {
            do {
                discoveryReport = try KimiACPConfigurationDiscovery.report(
                    input: discovery,
                    requiresAuthentication: identity.requiresAuthentication,
                    sessionConfigOptions: fields["configOptions"],
                    sessionStarted: true
                )
            } catch {
                // A malformed observation is a negative observation, never a
                // fabricated capability: the report stays nil.
                discoveryReport = nil
            }
        }
        mapper = try KimiACPTaskMapper(connectionID: connection.identity, sessionID: sessionID)
        try await sessionBound(VendorReference(role: .conversation, value: sessionID))
    }

    // MARK: Controls (exact session/attempt/request identity, one-shot)

    /// Explicit user instruction on the bound session. No queue, no
    /// auto-resend after cancellation or reconnect: a submitted prompt that
    /// lost its channel is unknown, and the next instruction is a new turn.
    @discardableResult
    func submit(_ content: KimiACPPromptContent,
                beforeDispatch: @escaping @Sendable () throws -> Void = {}) async throws -> Dispatch {
        try request.controlAuthority.validate()
        try transport.validate()
        guard !writing, let session = nativeSession, let identity, let mapper else {
            throw KimiACPWireError.invalidState
        }
        guard [State.idle, .unverified, .cancelled, .failed].contains(state),
              promptID == nil, !cancellationRequested, !inputFenced,
              !mapper.promptActive else {
            throw KimiACPWireError.invalidState
        }
        let blocks = try content.blocks(capabilities: identity.capabilities)
        var bytes: Data?
        let id = try connection.request(method: "session/prompt", params: .object([
            "sessionId": .string(session), "prompt": .array(blocks)
        ])) { bytes = $0 }
        guard let bytes else { throw KimiACPWireError.invalidState }
        // Reserve before awaiting the physical write. No retry after uncertainty.
        promptID = id
        promptContext = try VendorReference(role: .request, value: requestDigest(id))
        result = ""
        resultTruncated = false
        cancellationRequested = false
        parentOutcome = nil
        state = .submitted
        try mutateMapper { try $0.beginPrompt() }
        let authority = request.controlAuthority
        return try await writeWithGate(bytes, gate: {
            try authority.validate()
            try beforeDispatch()
            try authority.validate()
        })
    }

    /// session/cancel is REQUESTED, not confirmed: the resulting turn state
    /// comes only from the provider's cancelled stop reason. Pending asks are
    /// answered with the spec-mandated cancelled outcome immediately.
    @discardableResult
    func cancel(beforeDispatch: @escaping @Sendable () throws -> Void = {}) async throws -> Dispatch {
        try request.controlAuthority.validate()
        try transport.validate()
        guard let session = nativeSession, promptID != nil, state != .cancelRequested, !writing else {
            throw KimiACPWireError.invalidState
        }
        state = .cancelRequested
        cancellationRequested = true
        let message = CodexAppServerMessage.notification(
            method: "session/cancel", params: .object(["sessionId": .string(session)])
        )
        let bytes = try KimiACPWire.encode(message)
        let authority = request.controlAuthority
        let dispatch = try await writeWithGate(bytes, gate: {
            try authority.validate()
            try beforeDispatch()
            try authority.validate()
        })
        // Spec MUST: answer every pending permission/elicitation request with
        // the cancelled outcome. A failed answer fence already lost the
        // connection; remaining asks are unknown, never silently dropped.
        if case .acknowledged = dispatch {
            let cancelled = try mutateMapper { try $0.cancelledPending() }
            for wireID in cancelled {
                guard case .acknowledged = try? await sendCancelledOutcome(wireID) else {
                    loseConnection()
                    return .uncertain
                }
            }
        }
        await notify()
        return dispatch
    }

    private func sendCancelledOutcome(_ wireID: CodexAppServerRequestID) async throws -> Dispatch {
        guard let item = pending.values.first(where: { $0.wireID == wireID }) else {
            throw KimiACPWireError.invalidState
        }
        let result: AgentEventJSON
        if item.method == "session/request_permission" {
            result = .object(["outcome": .object(["outcome": .string("cancelled")])])
        } else {
            result = .object(["action": .string("cancel")])
        }
        let prepared = try connection.prepareAnswer(wireID, result: result)
        try await writePrepared(prepared, permission: item.fence)
        try connection.confirmResponseWritten(prepared)
        try mutateMapper { try $0.markAnswered(wireID) }
        // Mirrors answer(): the answered ask leaves the session-level pending
        // set, or it stays visible after the turn settles.
        pending.removeValue(forKey: item.question.request)
        sentResponses[item.question.request] = item
        return .acknowledged
    }

    @discardableResult
    func answerPermission(_ reference: VendorReference, context: VendorReference,
                          decision: KimiACPPermissionDecision,
                          beforeDispatch: @escaping @Sendable () throws -> Void = {}) async throws -> Dispatch {
        guard let item = try pendingItem(reference, context: context, kind: .approval) else {
            throw KimiACPWireError.invalidAnswer
        }
        let kind = switch decision {
        case .allowOnce: "allow_once"
        case .deny: "reject_once"
        }
        guard let optionID = item.question.options[kind] else { throw KimiACPWireError.invalidAnswer }
        return try await answer(item, reference: reference, result: .object([
            "outcome": .object(["outcome": .string("selected"), "optionId": .string(optionID)])
        ]), beforeDispatch: beforeDispatch)
    }

    @discardableResult
    func answerQuestion(_ reference: VendorReference, context: VendorReference,
                        answers: [String: [String]],
                        beforeDispatch: @escaping @Sendable () throws -> Void = {}) async throws -> Dispatch {
        guard let item = try pendingItem(reference, context: context, kind: .question),
              let form = item.question.form else {
            throw KimiACPWireError.invalidAnswer
        }
        let content = try form.content(answers: answers)
        return try await answer(item, reference: reference, result: .object([
            "action": .string("accept"), "content": content
        ]), beforeDispatch: beforeDispatch)
    }

    private func pendingItem(_ reference: VendorReference, context: VendorReference,
                             kind: Question.Kind) throws -> Pending? {
        try transport.validate()
        guard !cancellationRequested, let mapper, let item = pending[reference],
              item.question.context == context, item.question.kind == kind,
              mapper.isActionable(item.wireID) else {
            return nil
        }
        return item
    }

    private func answer(_ item: Pending, reference: VendorReference, result: AgentEventJSON,
                        beforeDispatch: @escaping @Sendable () throws -> Void) async throws -> Dispatch {
        guard let mapper, mapper.isActionable(item.wireID) else { throw KimiACPWireError.invalidAnswer }
        let prepared = try connection.prepareAnswer(item.wireID, result: result)
        let authority = request.controlAuthority
        let transport = try self.transport
        let fence = item.fence
        writing = true
        defer { writing = false }
        await notify()
        do {
            try await transport.write(prepared.bytes,
                                      deadline: min(deadline, .now.advanced(by: .seconds(5))),
                                      beforeWrite: {
                try authority.validate()
                try beforeDispatch()
                try fence.validate()
                try transport.validate()
            })
            try transport.validate()
            guard state != .stopped, state != .unknown else { return .uncertain }
            try connection.confirmResponseWritten(prepared)
            try mutateMapper { try $0.markAnswered(item.wireID) }
            pending.removeValue(forKey: reference)
            sentResponses[reference] = item
            // A physical pipe write has no ACP acknowledgement; resolution
            // stays unknown until the owning tool ends or the turn settles.
            if state == .waiting, pending.isEmpty {
                state = promptID == nil ? (parentOutcome ?? .unknown) : .submitted
            }
            await notify()
            return .acknowledged
        } catch {
            loseConnection()
            await notify()
            if fence.wasEngaged { return .uncertain }
            throw error
        }
    }

    // MARK: Ingress

    private func readLoop() async {
        do {
            while let message = try await transport.read(deadline: deadline) {
                try transport.validate()
                guard state != .stopped, state != .unknown else { return }
                var replay: Data?
                let delivery = try connection.receive(message, connection: connection.identity) {
                    replay = $0
                }
                if let replay, let writer = ownedTransport {
                    // Idempotent redelivery of an already answered request:
                    // replay the exact cached bytes, never re-prompt the user.
                    _ = try await writer.write(replay, deadline: min(deadline, .now.advanced(by: .seconds(5))),
                                               beforeWrite: { try writer.validate() })
                }
                try await handle(delivery, message: message)
                await notify()
            }
            loseConnection()
        } catch {
            loseConnection()
        }
        await notify()
    }

    private func handle(_ delivery: KimiACPConnection.Delivery, message: CodexAppServerMessage) async throws {
        guard self.mapper != nil else { throw KimiACPWireError.invalidState }
        switch delivery {
        case .initialized:
            throw KimiACPWireError.invalidState
        case .response(let id, let method, let result):
            guard method == "session/prompt", id == promptID else {
                throw KimiACPWireError.invalidProtocol
            }
            try await settle(result: result)
        case .failure(let id, _, let code):
            guard id == promptID else { throw KimiACPWireError.invalidProtocol }
            promptID = nil
            if self.mapper?.promptActive ?? false {
                try mutateMapper { try $0.endPrompt() }
            }
            promptContext = nil
            if pending.isEmpty {
                state = cancellationRequested ? .unknown : .failed
            } else {
                // The turn failed with an open ask: with no active prompt the
                // ask is unanswerable, so the channel is unknown, never a
                // .waiting with a displayed-but-stale question.
                state = .unknown
            }
            parentOutcome = state
            if try await promptResponded(state) == .fenced { inputFenced = true }
            if state == .unknown { loseConnection() }
            _ = code
        case .serverRequest(let id, let method, let params):
            try await handleServerRequest(id: id, method: method, params: params)
        case .notification:
            let effects = try mutateMapper { try $0.map(message, connection: connection.identity) }
            for effect in effects {
                try await apply(effect)
            }
        case .duplicateRequest, .replayedResponse, .ignoredForeignConnection:
            return
        }
    }

    private func handleServerRequest(id: CodexAppServerRequestID,
                                     method: String, params: AgentEventJSON) async throws {
        let supported = method == "session/request_permission" || method == "elicitation/create"
        guard supported else {
            // fs/*, terminal/*, URL-mode elicitation, and every other
            // reverse-RPC Pine does not own get methodNotFound, never a
            // permissive default answer.
            try await reject(id)
            return
        }
        let effect = try mutateMapper { try $0.noteRequest(id, method: method, params: params) }
        switch effect {
        case .attention(let question, let wireID, let wireMethod):
            questionSequence += 1
            let question = Question(
                request: question.request, context: question.context,
                kind: wireMethod == "session/request_permission" ? .approval : .question,
                toolCall: question.toolCall, form: question.form,
                options: question.options, sequence: questionSequence
            )
            let item = Pending(wireID: wireID, question: question, method: wireMethod,
                               fence: KimiACPRequestFence())
            pending[question.request] = item
            let attention = try CandidateAttentionEvent(
                scope: .session,
                phase: question.kind == .approval ? .waitingForApproval : .waitingForQuestion,
                request: question.request, context: question.context
            )
            try await emit(question.kind == .approval ? .approval(attention) : .question(attention))
            if !cancellationRequested { state = .waiting }
        case .unsupportedRequest(let wireID):
            try await reject(wireID)
        case .working, .requestResolved, .ignored:
            throw KimiACPWireError.invalidProtocol
        case .needsReconciliation:
            throw KimiACPWireError.invalidProtocol
        }
    }

    private func apply(_ effect: KimiACPTaskMapper.Effect) async throws {
        switch effect {
        case .working(let chunk):
            if let chunk {
                // Presentation-only retention, not a trust boundary: keep the
                // HEAD, stop at the cap, and flag the truncation instead of
                // fencing a healthy channel over size.
                if !resultTruncated {
                    let room = KimiACPPromptContent.maximumTextBytes - result.utf8.count
                    if chunk.utf8.count <= room {
                        result += chunk
                    } else {
                        // Keep the head up to the cap, backed off to a UTF-8
                        // boundary; retention is presentation-only, so the
                        // dropped tail is not evidence.
                        var kept = room
                        var head = ""
                        while kept > 0 {
                            if let candidate = String(bytes: Array(chunk.utf8.prefix(kept)),
                                                       encoding: .utf8) {
                                head = candidate
                                break
                            }
                            kept -= 1
                        }
                        result.append(head)
                        resultTruncated = true
                    }
                }
            }
            // Observed activity during an in-flight prompt is working; it is
            // not completion or evidence of check success.
            if !cancellationRequested, promptID != nil, pending.isEmpty {
                state = .working
            }
            try await emit(.lifecycle(CandidateLifecycleEvent(
                scope: .session, phase: .working,
                reference: nativeSession.flatMap { try? VendorReference(role: .conversation, value: $0) }
            )))
        case .attention:
            // Attention is only ever minted by handleServerRequest, which
            // owns the wire ID the mapper cannot see again.
            throw KimiACPWireError.invalidProtocol
        case .requestResolved(let request):
            if let item = pending.removeValue(forKey: request) {
                item.fence.revoke()
                sentResponses.removeValue(forKey: request)
                try connection.resolveServerRequest(item.wireID)
                let resolution = try CandidateRequestResolutionEvent(
                    scope: .session, request: request, context: item.question.context
                )
                try await emit(.requestResolved(resolution))
                if state == .waiting, pending.isEmpty {
                    state = promptID == nil ? (parentOutcome ?? .unknown) : .working
                }
            }
        case .unsupportedRequest(let id):
            try await reject(id)
        case .ignored:
            return
        case .needsReconciliation:
            throw KimiACPWireError.invalidProtocol
        }
    }

    /// The correlated session/prompt response is the only turn terminator in
    /// ACP. Provider success is a claim: Ready still requires Pine-observed
    /// checks, independent review, and current fingerprints.
    private func settle(result: AgentEventJSON) async throws {
        let fields = try KimiACPWire.object(result)
        let reason = try KimiACPWire.string(fields["stopReason"])
        let wasCancelled = cancellationRequested
        // The provider confirmed the turn outcome; the flag is turn-scoped, so
        // a settled .cancelled attempt can start a new prompt on this attempt.
        cancellationRequested = false
        promptID = nil
        promptContext = nil
        try mutateMapper { try $0.endPrompt() }
        let outcome: State
        switch reason {
        case "cancelled":
            outcome = wasCancelled ? .cancelled : .unknown
        case "end_turn", "max_tokens", "max_turn_requests", "refusal":
            outcome = wasCancelled ? .unknown : .unverified
        default:
            outcome = .unknown
        }
        if pending.isEmpty {
            state = outcome
        } else {
            // The turn settled with an open ask: with no active prompt the ask
            // is unanswerable, so the channel is unknown, never a .waiting
            // with a displayed-but-stale question.
            state = .unknown
        }
        parentOutcome = state
        if try await promptResponded(state) == .fenced { inputFenced = true }
        if state == .unknown { loseConnection() }
    }

    private func reject(_ id: CodexAppServerRequestID) async throws {
        let prepared = try connection.prepareRejection(id)
        try await writePrepared(prepared, permission: nil)
        try connection.confirmResponseWritten(prepared)
    }

    private func mutateMapper<T>(_ body: (inout KimiACPTaskMapper) throws -> T) throws -> T {
        guard var mapper = self.mapper else { throw KimiACPWireError.invalidState }
        let value = try body(&mapper)
        self.mapper = mapper
        return value
    }

    private func writePrepared(_ prepared: KimiACPConnection.PreparedResponse,
                               permission: KimiACPRequestFence?) async throws {
        let transport = try self.transport
        try await transport.write(prepared.bytes,
                                  deadline: min(deadline, .now.advanced(by: .seconds(5))),
                                  beforeWrite: {
            try permission?.validate()
            try transport.validate()
        })
        try transport.validate()
    }

    private func writeWithGate(_ bytes: Data, gate: @escaping @Sendable () throws -> Void) async throws -> Dispatch {
        let transport = try self.transport
        let possibleEffect = Mutex(false)
        do {
            try await transport.write(bytes, deadline: min(deadline, .now.advanced(by: .seconds(30))),
                                      beforeWrite: {
                try transport.validate()
                try gate()
                try transport.validate()
                possibleEffect.withLock { $0 = true }
            })
            try transport.validate()
            guard state != .stopped, state != .unknown else { return .uncertain }
            return .acknowledged
        } catch {
            loseConnection()
            await notify()
            if !possibleEffect.withLock({ $0 }) { throw error }
            return .uncertain
        }
    }

    private func emit(_ event: AdapterCandidateEvent) async throws {
        try transport.validate()
        let outcome = await request.sink.ingest(AdapterCandidate(event: event))
        guard outcome == .accepted || outcome == .bufferedUntilActivation else {
            throw KimiACPWireError.unavailable
        }
        try transport.validate()
    }

    private func loseConnection() {
        guard state != .stopped, !connectionLost else { return }
        connectionLost = true
        // Missing pending-request evidence after channel loss is UNKNOWN,
        // never an empty request set: the provider may still hold live asks.
        if state != .cancelled { state = .unknown }
        for item in pending.values { item.fence.revoke() }
        for item in sentResponses.values { item.fence.revoke() }
        mapper?.close()
        connection.close()
        request.controlAuthority.revoke()
        revokeOwnership()
        ownedTransport?.close()
    }

    func stop(deadline: ContinuousClock.Instant) async {
        state = .stopped
        for item in pending.values { item.fence.revoke() }
        for item in sentResponses.values { item.fence.revoke() }
        pending.removeAll()
        sentResponses.removeAll()
        mapper?.close()
        connection.close()
        request.controlAuthority.revoke()
        revokeOwnership()
        ownedTransport?.close()
        reader?.cancel()
        reader = nil
        await notify()
        await ownedTransport?.stop(deadline: deadline)
    }

    private func requestDigest(_ identifier: CodexAppServerRequestID) throws -> String {
        SHA256.hash(data: try identifier.json.canonicalData()).map { String(format: "%02x", $0) }.joined()
    }
}

/// Negative-only, connection-local fence checked by every physical reply
/// write. A revoked fence turns a later write into dispatch uncertainty.
nonisolated final class KimiACPRequestFence: Sendable {
    private let active = Mutex(true)
    private let engaged = Mutex(false)
    func revoke() { active.withLock { $0 = false } }
    var wasEngaged: Bool { engaged.withLock { $0 } }
    func validate() throws {
        engaged.withLock { $0 = true }
        try active.withLock { if !$0 { throw KimiACPWireError.invalidAnswer } }
    }
}

nonisolated enum KimiACPPermissionDecision: Equatable, Sendable { case allowOnce, deny }
