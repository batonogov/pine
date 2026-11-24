import Foundation
import Synchronization

/// ACP v1 only. Presentation data is transient, bounded, and excluded from
/// diagnostic reflection. This actor persists no transcript or credentials;
/// the existing task registry owns the exact native ID for explicit recovery.
actor ClaudeCodeACPSession: AgentAdapterControlledSession, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable {
    nonisolated var description: String { "<redacted:claude-code-acp-session>" }
    nonisolated var debugDescription: String { description }
    nonisolated var customMirror: Mirror { Mirror(self, children: ["value": description]) }
    enum State: Equatable, Sendable {
        case fresh, starting, idle, submitted, working, waiting, unverified
        case cancelRequested, cancelled, failed, blocked, unknown, stopped
    }
    enum ResponseDisposition: Sendable { case recorded, fenced }
    struct Question: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
        let id: UUID
        let request: VendorReference
        let context: VendorReference
        let form: ClaudeCodeACPForm?
        let permission: Bool
        let details: AgentEventJSON?
        /// Nil means root-scoped/unknown, never guessed from a question's title.
        let childOwner: VendorReference?
        let allowOnceOptionID: String?
        let denyOptionID: String?
        var description: String { "<redacted:acp-question>" }
        var debugDescription: String { description }
        var customMirror: Mirror { Mirror(self, children: ["value": description]) }
    }
    struct Snapshot: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
        let state: State
        let result: String
        let questions: [Question]
        let submittedQuestions: [Question]
        let context: VendorReference?
        let nativeSession: VendorReference?
        let children: [VendorReference: String]
        let cancellationRequested: Bool
        let answersAwaitingEvidence: Int
        /// Last explicit parent prompt's outcome, separate from late activity.
        let parentOutcome: State?
        let inputFenced: Bool
        /// ACP parent completion does not reconcile children, including late questions.
        let settlementKnown = false
        let ready = false
        var description: String { "<redacted:acp-snapshot>" }
        var debugDescription: String { description }
        var customMirror: Mirror { Mirror(self, children: ["value": description]) }
    }
    private struct Pending {
        let wireID: CodexAppServerRequestID
        let question: Question
        let params: AgentEventJSON
        let method: String
        let options: [String: String]
        let sequence: Int
        let fence: ClaudeCodeACPRequestFence
    }

    nonisolated let contract: NegotiatedAdapterContract
    private let request: AgentAdapterSessionRequest
    private let launch: @Sendable (ContinuousClock.Instant) async throws -> any ClaudeCodeACPTransport
    private var ownedTransport: (any ClaudeCodeACPTransport)?
    private var transport: any ClaudeCodeACPTransport {
        get throws {
            guard let ownedTransport else { throw ClaudeCodeACPError.unavailable }
            return ownedTransport
        }
    }
    private let cwd: String
    /// Outer cap for the bounded launch/bootstrap windows only. Session I/O
    /// keeps per-operation bounds and outlives this instant (readLoop,
    /// writeWithGate), so a healthy long turn is never fenced by it.
    private let deadline: ContinuousClock.Instant
    private let beforeStartWrite: @Sendable () throws -> Void
    private let revokeOwnership: @Sendable () -> Void
    private let sessionBound: @Sendable (VendorReference) async throws -> Void
    private let promptResponded: @Sendable (State) async throws -> ResponseDisposition
    private let loadSession: VendorReference?
    private let native: ClaudeCodeACPNativeControl?
    /// Launch-boundary observation for the discovery report; nil when the
    /// session owner cannot attribute the executable.
    private let discovery: ClaudeCodeACPConfigurationDiscovery.Input?
    /// Read-only discovery observation produced from the pinned adapter
    /// identity and the session setup response.
    private(set) var discoveryReport: AgentTaskDiscoveryReport?
    private var nativeSubmission: ClaudeCodeACPNativeSubmission?
    private var nativeResponseClaimedID: UUID?
    // Reserved for the shared projection; this ACP v1 slice negotiates no
    // provider-specific child-session extension and never invents children.
    private var children: [VendorReference: String] = [:]
    private var state = State.fresh
    private var nativeSession: String?
    // Actual client RPC correlation, never a fabricated provider operation ID.
    private var promptContext: VendorReference?
    private var promptID: CodexAppServerRequestID?
    private var nextID: Int64 = 2
    private var pending: [VendorReference: Pending] = [:]
    private var sentResponses: [VendorReference: Pending] = [:]
    private var sentMessages: [VendorReference: CodexAppServerMessage] = [:]
    private var seenRequests: Set<CodexAppServerRequestID> = []
    private var result = ""
    private var resultStarted = false
    private var writing = false
    private var cancellationRequested = false
    private var parentOutcome: State?
    private var inputFenced = false
    private var reader: Task<Void, Never>?
    private var observer: (@Sendable (Snapshot) async -> Void)?

    /// One application-lifetime consumer; reopening a window reuses that owner.
    func observe(_ observer: @escaping @Sendable (Snapshot) async -> Void) async throws {
        guard self.observer == nil else { throw ClaudeCodeACPError.invalidState }
        self.observer = observer
        await notify()
    }

    private func notify() async {
        if let observer { await observer(snapshot()) }
    }

    /// `loadSession` is an explicit exact-ID action, never latest-session lookup.
    /// Its gate must revalidate original cwd/configuration and new attempt binding.
    init(request: AgentAdapterSessionRequest,
         launch: @escaping @Sendable (ContinuousClock.Instant) async throws -> any ClaudeCodeACPTransport,
         cwd: String, deadline: ContinuousClock.Instant,
         loadSession: VendorReference? = nil,
         native: ClaudeCodeACPNativeControl? = nil,
         beforeStartWrite: @escaping @Sendable () throws -> Void,
         revokeOwnership: @escaping @Sendable () -> Void,
         sessionBound: @escaping @Sendable (VendorReference) async throws -> Void,
         promptResponded: @escaping @Sendable (State) async throws -> ResponseDisposition,
         discovery: ClaudeCodeACPConfigurationDiscovery.Input? = nil) throws {
        guard request.resumeFrom == nil else { throw AdapterSessionError.checkpointNotSupported }
        guard request.contract.profile == (try Self.profile()),
              request.contract.agentID.value == "claudeCode",
              request.contract.version == PineAdapterContractVersion(major: 1, minor: 1),
              loadSession == nil || loadSession?.role == .conversation,
              loadSession.map({ ClaudeCodeACPWire.validSessionID($0.rawValue) }) ?? true,
              cwd.hasPrefix("/"), !cwd.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw AdapterSessionError.contractMismatch
        }
        self.request = request
        contract = request.contract
        self.launch = launch
        self.cwd = cwd
        self.deadline = deadline
        self.beforeStartWrite = beforeStartWrite
        self.revokeOwnership = revokeOwnership
        self.sessionBound = sessionBound
        self.promptResponded = promptResponded
        self.loadSession = loadSession
        self.native = native
        self.discovery = discovery
    }

    nonisolated static func profile() throws -> AdapterCapabilityProfile {
        try AdapterCapabilityProfile(
            transport: .ownedStandardIO,
            lifecycle: AdapterLifecycleCapabilities(signals: [
                .init(scope: .session, phase: .working),
                .init(scope: .session, phase: .waitingForQuestion),
                .init(scope: .session, phase: .waitingForApproval),
                .init(scope: .session, phase: .failed),
                .init(scope: .session, phase: .cancelled),
                // Required by requestResolved validation, never session settlement.
                .init(scope: .session, phase: .settled)
            ], evidence: []),
            delivery: AdapterDeliverySemantics(ordering: .unordered, minimumAuthentication: .ownedChildPipe)
        )
    }

    var isStopped: Bool { state == .stopped }

    func snapshot() -> Snapshot {
        // A dead physical owner must not leave an actionable cached question.
        if ownedTransport != nil, (try? transport.validate()) == nil, state != .fresh, state != .stopped {
            loseConnection()
        }
        return Snapshot(state: state, result: result,
                        questions: pending.values.sorted { $0.sequence < $1.sequence }.map(\.question),
                        submittedQuestions: sentResponses.values.sorted { $0.sequence < $1.sequence }.map(\.question),
                        context: promptContext,
                        nativeSession: nativeSession.flatMap { try? VendorReference(role: .conversation, value: $0) },
                        children: children, cancellationRequested: cancellationRequested,
                        answersAwaitingEvidence: sentResponses.count, parentOutcome: parentOutcome,
                        inputFenced: inputFenced)
    }

    /// Exact official adapter pin. Tagged v0.109.1 package/source reviewed
    /// 2026-11-23: `--version` prints this value and initialize returns the
    /// same agentInfo.version. No real adapter execution is claimed here.
    nonisolated static let pinnedVersion = "0.109.1"
    nonisolated static let pinnedAgentName = "@agentclientprotocol/claude-agent-acp"

    func start() async throws {
        guard state == .fresh else { throw ClaudeCodeACPError.invalidState }
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
            let initialization = try await bootstrap(id: .integer(0), method: "initialize", params: .object([
                "protocolVersion": .number("1"),
                "clientInfo": .object(["name": .string("pine"), "version": .string("3.0")]),
                "clientCapabilities": .object([
                    "elicitation": .object(["form": .object([:])])
                ])
            ]))
            let initialized = try ClaudeCodeACPWire.object(initialization)
            guard initialized["protocolVersion"] == .number("1") else { throw ClaudeCodeACPError.invalidProtocol }
            let agent = try ClaudeCodeACPWire.object(initialized["agentInfo"] ?? .null)
            // ACP v1 is the only negotiated baseline in this slice. Exact
            // adapter identity/version and executable hash remain fail-closed.
            let capabilities = try ClaudeCodeACPWire.object(initialized["agentCapabilities"] ?? .null)
            guard agent["name"] == .string(Self.pinnedAgentName),
                  agent["version"] == .string(Self.pinnedVersion) else {
                throw ClaudeCodeACPError.unavailable
            }
            var creation: [String: AgentEventJSON] = ["cwd": .string(cwd), "mcpServers": .array([])]
            if let loadSession {
                guard capabilities["loadSession"] == .bool(true) else { throw ClaudeCodeACPError.unavailable }
                creation["sessionId"] = .string(loadSession.rawValue)
            }
            let session = try await bootstrap(id: .integer(1),
                                             method: loadSession == nil ? "session/new" : "session/load",
                                             params: .object(creation))
            let fields = try ClaudeCodeACPWire.object(session)
            let sessionID = try ClaudeCodeACPWire.string(fields["sessionId"] ?? loadSession.map {
                AgentEventJSON.string($0.rawValue)
            })
            guard ClaudeCodeACPWire.validSessionID(sessionID),
                  loadSession == nil || sessionID == loadSession?.rawValue else {
                throw ClaudeCodeACPError.invalidProtocol
            }
            nativeSession = sessionID
            // Without a launch-boundary input the session cannot attribute the
            // observation to a resolved executable, so it produces no report.
            if let discovery {
                do {
                    discoveryReport = try ClaudeCodeACPConfigurationDiscovery.report(
                        input: discovery,
                        sessionConfigOptions: fields["configOptions"],
                        sessionStarted: true
                    )
                } catch {
                    // A malformed observation is a negative observation, never a
                    // fabricated capability: the report stays nil.
                    discoveryReport = nil
                }
            }
            try await sessionBound(VendorReference(role: .conversation, value: sessionID))
            guard state == .starting else { throw ClaudeCodeACPError.unavailable }
            state = .idle
            reader = Task { await self.readLoop() }
            await notify()
        } catch {
            await stop(deadline: min(deadline, .now.advanced(by: .seconds(2))))
            throw error
        }
    }

    private func bootstrap(id: CodexAppServerRequestID, method: String,
                           params: AgentEventJSON) async throws -> AgentEventJSON {
        let limit = min(deadline, .now.advanced(by: .seconds(30)))
        let transport = try self.transport
        let gate = beforeStartWrite
        try await transport.write(ClaudeCodeACPWire.encode(.request(id, method: method, params: params)),
                                  deadline: limit, beforeWrite: {
            try gate()
            try transport.validate()
        })
        // session/load replays saved session/update messages before its reply.
        // They are historical, not live activity, questions, or execution authority.
        var replayCount = 0
        while let message = try await transport.read(deadline: limit), state == .starting {
            switch message {
            case .response(let receivedID, let result) where receivedID == id: return result
            case .failure(let receivedID, let code) where receivedID == id:
                throw ClaudeCodeACPError.providerFailure(code)
            case .notification(let method, _) where method == "_auth/status_update" || method == "auth/status_update":
                // The adapter probes provider auth asynchronously. These pushes
                // carry no Pine authentication evidence and may precede session/new.
                continue
            case .notification(let method, let params) where id == .integer(1) && method == "session/update":
                let fields = try ClaudeCodeACPWire.object(params)
                if let loadSession, !ClaudeCodeACPWire.matches(fields["sessionId"], string: loadSession.rawValue) {
                    throw ClaudeCodeACPError.invalidProtocol
                }
                replayCount += 1
                guard replayCount <= 256 else { throw ClaudeCodeACPError.capacity }
            default: throw ClaudeCodeACPError.invalidProtocol
            }
        }
        throw ClaudeCodeACPError.unavailable
    }

    private var hasUnresolvedPriorWork: Bool { !sentResponses.isEmpty }

    func dispatch(_ control: AgentAdapterControl,
                  beforeDispatch: @escaping @Sendable () throws -> Void) async throws -> AgentAdapterControlDispatch {
        try request.controlAuthority.validate()
        try transport.validate()
        guard !writing, ![.fresh, .starting, .blocked, .unknown, .stopped].contains(state),
              let session = nativeSession else { throw ClaudeCodeACPError.invalidState }
        writing = true
        defer { writing = false }
        let message: CodexAppServerMessage
        var resolved: Pending?
        var prepared: ClaudeCodeACPNativeSubmission?
        var effect: AgentTaskNativeOwnership.Effect?
        switch control {
        case .submitInstruction(let text):
            guard state == .idle || parentOutcome != nil,
                  promptID == nil, pending.isEmpty, !hasUnresolvedPriorWork,
                  !cancellationRequested, !inputFenced,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  text.utf8.count <= 65_536, nextID < Int64.max else {
                throw ClaudeCodeACPError.invalidState
            }
            if let native {
                let submission = try await native.prepareSubmission()
                prepared = submission
                nativeSubmission = submission
                effect = .submission(submission.receipt)
                // Durable preparation awaits the registry and releases this
                // actor. Late work from the prior parent must reopen no prompt.
                guard promptID == nil, pending.isEmpty, !hasUnresolvedPriorWork,
                      !cancellationRequested, !inputFenced,
                      state == .idle || parentOutcome != nil else {
                    try? await native.submissionUnknown(submission)
                    nativeSubmission = nil
                    throw ClaudeCodeACPError.invalidState
                }
            }
            let id = CodexAppServerRequestID.integer(nextID)
            let requestNumber = nextID
            nextID += 1
            message = .request(id, method: "session/prompt", params: .object([
                "sessionId": .string(session),
                "prompt": .array([.object(["type": .string("text"), "text": .string(text)])])
            ]))
            // Reserve before awaiting the physical write. No retry after uncertainty.
            promptID = id
            promptContext = try VendorReference(
                role: native == nil ? .request : .turn, value: String(requestNumber)
            )
            nativeResponseClaimedID = nil
            resultStarted = false
            cancellationRequested = false
            parentOutcome = nil
            state = .submitted
        case .requestCancellation(let context):
            guard context == promptContext, promptID != nil, state != .cancelRequested else {
                throw ClaudeCodeACPError.invalidState
            }
            // Claim cancellation before the durable await. A response that wins
            // afterwards observes this request and cannot become an unverified success.
            state = .cancelRequested
            cancellationRequested = true
            do {
                try await native?.prepareCancellation()
            } catch {
                loseConnection()
                throw error
            }
            if promptID == nil {
                // The correlated response won while cancellation was persisted.
                // It already proves delivery of the prompt; do not send a stale cancel.
                // On a live transport, owned questions still need their terminal
                // wire answer; a dead transport fails closed like any other write.
                try request.controlAuthority.validate()
                let replies = try await cancelPendingRequests(beforeDispatch: beforeDispatch)
                await notify()
                return replies == .uncertain ? .uncertain : .acknowledged
            }
            guard context == promptContext else {
                loseConnection()
                throw ClaudeCodeACPError.invalidState
            }
            effect = native.map { _ in .cancellation }
            message = .notification(method: "session/cancel", params: .object(["sessionId": .string(session)]))
        case .answerQuestion(let reference, let context, let answers):
            guard let item = pending[reference], item.question.context == context,
                  let form = item.question.form, !cancellationRequested else { throw ClaudeCodeACPError.invalidAnswer }
            message = .response(item.wireID, result: .object([
                "action": .string("accept"), "content": try form.content(answers: answers)
            ]))
            resolved = item
            pending.removeValue(forKey: reference)
            effect = native.map { _ in .decision }
        case .answerPermission(let reference, let context, let decision):
            guard let item = pending[reference], item.question.context == context,
                  item.question.permission, !cancellationRequested else { throw ClaudeCodeACPError.invalidAnswer }
            let kind = switch decision {
            case .allowOnce: "allow_once"
            case .deny: "reject_once"
            }
            guard let option = item.options[kind] else { throw ClaudeCodeACPError.invalidAnswer }
            message = .response(item.wireID, result: .object([
                "outcome": .object(["outcome": .string("selected"), "optionId": .string(option)])
            ]))
            resolved = item
            pending.removeValue(forKey: reference)
            effect = native.map { _ in .decision }
        }
        // Reserve before the async write so a fast owning-tool completion
        // cannot be lost and then overwritten by the write's acknowledgement.
        if let resolved {
            sentResponses[resolved.question.request] = resolved
            sentMessages[resolved.question.request] = message
        }
        await notify()
        do {
            let dispatch = try await writeWithGate(
                message, beforeDispatch: beforeDispatch, requestFence: resolved?.fence, effect: effect
            )
            if case .requestCancellation = control, dispatch == .acknowledged {
                let replies = try await cancelPendingRequests(beforeDispatch: beforeDispatch)
                if replies == .uncertain { return .uncertain }
            }
            if let native, let prepared,
               nativeSubmission?.id == prepared.id || nativeResponseClaimedID == prepared.id {
                await native.waitForAcknowledgement()
                if nativeResponseClaimedID == prepared.id {
                    // A correlated response proves delivery. Acknowledgement
                    // loses cleanly and must not turn into submissionUnknown.
                    try request.controlAuthority.validate()
                    await notify()
                    return .acknowledged
                }
                if nativeSubmission?.id == prepared.id {
                    if dispatch == .acknowledged {
                        try await native.acknowledge(prepared)
                    } else {
                        try? await native.submissionUnknown(prepared)
                        nativeSubmission = nil
                    }
                }
            }
            if resolved != nil, state == .waiting, pending.isEmpty {
                // Pipe acknowledgement does not prove that the request resolved.
                state = promptID == nil ? (parentOutcome ?? .unknown) : .submitted
            }
            await notify()
            return dispatch
        } catch {
            if let native, let prepared {
                if nativeResponseClaimedID == prepared.id {
                    // The correlated response claimed this submission while a durable
                    // transition was in flight. It proves delivery, so a now-invalid
                    // registry transition must not fail the dispatch.
                    try request.controlAuthority.validate()
                    await notify()
                    return .acknowledged
                }
                if nativeSubmission?.id == prepared.id {
                    try? await native.submissionUnknown(prepared)
                    nativeSubmission = nil
                }
            }
            throw error
        }
    }

    private func readLoop() async {
        do {
            // Session lifetime is owner-supervised (cancellation/stop and
            // transport loss), not a fixed instant: a healthy long turn must
            // never be fenced by the launch window.
            while let message = try await transport.read(deadline: .claudeCodeACPUnbounded) {
                try transport.validate()
                guard state != .stopped, state != .unknown else { return }
                try await receive(message)
                await notify()
            }
            loseConnection()
        } catch ClaudeCodeACPError.unsupportedQuestion {
            state = .blocked
            loseConnection()
        } catch { loseConnection() }
        await notify()
    }

    private func receive(_ message: CodexAppServerMessage) async throws {
        switch message {
        case .notification(let method, let params):
            if method == "$/cancel_request" {
                try await withdrawRequest(params)
                return
            }
            guard method == "session/update" else { return }
            let fields = try ClaudeCodeACPWire.object(params)
            guard ClaudeCodeACPWire.matches(fields["sessionId"], string: nativeSession) else {
                throw ClaudeCodeACPError.invalidProtocol
            }
            let update = try ClaudeCodeACPWire.object(fields["update"] ?? .null)
            let kind = try ClaudeCodeACPWire.string(update["sessionUpdate"])
            try await resolveToolRequests(update)
            // Command/config notifications can precede a prompt; none are lifecycle.
            guard ["agent_message_chunk", "tool_call", "tool_call_update"].contains(kind),
                  promptContext != nil else { return }
            if promptID == nil {
                // Root activity after the correlated response is late output of
                // the settled main turn, never a new result or Ready evidence.
                // Without an exhaustive background-work boundary, input stays fenced.
                inputFenced = true
                await notify()
                return
            }
            if kind == "agent_message_chunk",
               case .object(let content) = update["content"], content["type"] == .string("text"),
               case .string(let text) = content["text"] {
                if !resultStarted {
                    result = ""
                    resultStarted = true
                }
                guard result.utf8.count + text.utf8.count <= 65_536 else { throw ClaudeCodeACPError.capacity }
                result += text
            }
            // Observed activity is not completion or evidence of check success.
            if !cancellationRequested {
                if pending.isEmpty { state = .working }
                try await emit(.lifecycle(CandidateLifecycleEvent(
                    scope: .session, phase: .working,
                    reference: VendorReference(role: .conversation, value: try ClaudeCodeACPWire.string(fields["sessionId"]))
                )))
            }
        case .response(let id, let response):
            let submission = try claimParentResponse(id)
            let fields = try ClaudeCodeACPWire.object(response)
            let reason = try ClaudeCodeACPWire.string(fields["stopReason"])
            let wasCancelled = cancellationRequested
            try await observeParentResponse(submission)
            let outcome: State = switch reason {
            case "cancelled": .cancelled
            case "end_turn", "max_tokens", "max_turn_requests", "refusal": wasCancelled ? .unknown : .unverified
            default: .unknown
            }
            if try await promptResponded(outcome) == .fenced { inputFenced = true }
            switch reason {
            case "cancelled":
                parentOutcome = .cancelled
                cancellationRequested = false
                state = pending.isEmpty ? .cancelled : .waiting
            case "end_turn", "max_tokens", "max_turn_requests", "refusal":
                parentOutcome = wasCancelled ? .unknown : .unverified
                state = wasCancelled ? .unknown : (pending.isEmpty ? .unverified : .waiting)
            default:
                parentOutcome = .unknown
                state = .unknown
            }
            if reason == "cancelled" { try await emitParentOutcome(.cancelled) }
            if state == .unknown { loseConnection() }
            // No succeeded/settled event: late child requests remain possible.
        case .failure(let id, _):
            let submission = try claimParentResponse(id)
            try await observeParentResponse(submission)
            state = cancellationRequested ? .unknown : .failed
            parentOutcome = state
            if try await promptResponded(state) == .fenced { inputFenced = true }
            if !pending.isEmpty, state == .failed { state = .waiting }
            if state == .failed { try await emitParentOutcome(.failed) }
            if state == .unknown { loseConnection() }
        case .request(let id, let method, let params):
            try await receiveRequest(id, method: method, params: params)
        }
    }

    private func claimParentResponse(
        _ id: CodexAppServerRequestID
    ) throws -> ClaudeCodeACPNativeSubmission? {
        guard id == promptID else { throw ClaudeCodeACPError.invalidProtocol }
        // Claim synchronously before registry/persistence awaits. Cancellation
        // and write acknowledgement can no longer transition this prompt first.
        promptID = nil
        guard let submission = nativeSubmission else { return nil }
        nativeSubmission = nil
        nativeResponseClaimedID = submission.id
        return submission
    }

    private func observeParentResponse(_ submission: ClaudeCodeACPNativeSubmission?) async throws {
        guard let native, let submission else { return }
        try await native.responseObserved(submission)
    }

    private func emitParentOutcome(_ phase: AdapterLifecyclePhase) async throws {
        guard let nativeSession else { throw ClaudeCodeACPError.invalidState }
        try await emit(.lifecycle(CandidateLifecycleEvent(
            scope: .session, phase: phase,
            reference: VendorReference(role: .conversation, value: nativeSession)
        )))
    }

    private func receiveRequest(_ id: CodexAppServerRequestID, method: String, params: AgentEventJSON) async throws {
        let fields = try ClaudeCodeACPWire.object(params)
        guard ClaudeCodeACPWire.matches(fields["sessionId"], string: nativeSession), promptContext != nil,
              let nativeSession else {
            throw ClaudeCodeACPError.invalidProtocol
        }
        if seenRequests.contains(id) {
            if pending.values.contains(where: { $0.wireID == id && $0.params == params && $0.method == method }) {
                return
            }
            // A transport may redeliver an already answered server request.
            // Replay its remembered decision unless the turn is now cancelled.
            guard let answered = sentResponses.first(where: {
                $0.value.wireID == id && $0.value.params == params && $0.value.method == method
            }), let remembered = sentMessages[answered.key] else {
                throw ClaudeCodeACPError.invalidProtocol
            }
            let terminal = cancellationRequested || parentOutcome == .cancelled
            let message = terminal
                ? CodexAppServerMessage.response(id, result: Self.cancelledResult(for: method))
                : remembered
            // Redelivery never records a new decision, but every physical write
            // still revalidates native ownership and the appropriate purpose gate.
            let effect = native.map { _ in
                terminal ? AgentTaskNativeOwnership.Effect.cancellation : .decision
            }
            let replay = try await writeWithGate(
                message,
                beforeDispatch: {
                    if let native = self.native, let effect { try native.validateReplayWrite(effect) }
                },
                requestFence: answered.value.fence, effect: effect
            )
            guard replay == .acknowledged else { throw ClaudeCodeACPError.unavailable }
            return
        }
        guard pending.count + sentResponses.count < 16, seenRequests.count < 256,
              try params.canonicalData().count <= 65_536 else { throw ClaudeCodeACPError.capacity }
        let form: ClaudeCodeACPForm?
        var options: [String: String] = [:]
        switch method {
        case "elicitation/create":
            // Unsupported schemas fail the connection, rather than sending a
            // method error that lets ClaudeCode continue without the user's answer.
            form = try ClaudeCodeACPForm(fields)
        case "session/request_permission":
            form = nil
            guard case .array(let values) = fields["options"], values.count <= 16 else {
                throw ClaudeCodeACPError.invalidProtocol
            }
            for value in values {
                let option = try ClaudeCodeACPWire.object(value)
                let kind = try ClaudeCodeACPWire.string(option["kind"])
                let optionID = try ClaudeCodeACPWire.string(option["optionId"])
                guard options[kind] == nil, !options.values.contains(optionID) else {
                    throw ClaudeCodeACPError.invalidProtocol
                }
                options[kind] = optionID
            }
            guard options["allow_once"] != nil, options["reject_once"] != nil else {
                throw ClaudeCodeACPError.invalidProtocol
            }
        // Pine advertises no fs/terminal client capability. The only accepted
        // reverse requests are the explicitly supported form and permission
        // surfaces; everything else fails closed rather than gaining authority.
        default: throw ClaudeCodeACPError.invalidProtocol
        }
        let questionID = UUID()
        let reference = try VendorReference(role: .request, value: questionID.uuidString)
        let details = form == nil ? fields["toolCall"] : nil
        if form == nil { _ = try ClaudeCodeACPWire.object(details ?? .null) }
        if let details {
            let tool = try ClaudeCodeACPWire.object(details)
            _ = try tool["toolCallId"].map { try ClaudeCodeACPWire.string($0) }
        } else {
            _ = try fields["toolCallId"].map { try ClaudeCodeACPWire.string($0) }
        }
        // The native wire scopes asks to the session, not to a root prompt.
        // Closing a parent turn must not close this attention context.
        let context = try VendorReference(role: .conversation, value: nativeSession)
        let question = Question(id: questionID, request: reference, context: context, form: form, permission: form == nil,
                                 details: details, childOwner: nil,
                                 allowOnceOptionID: options["allow_once"], denyOptionID: options["reject_once"])
        let item = Pending(wireID: id, question: question, params: params, method: method,
                           options: options, sequence: seenRequests.count, fence: ClaudeCodeACPRequestFence())
        pending[reference] = item
        seenRequests.insert(id)
        if cancellationRequested || (native != nil && parentOutcome == .cancelled) {
            // Cancellation forbids fresh decisions. Service late child work
            // with the terminal outcome, not a stale actionable UI ask.
            pending.removeValue(forKey: reference)
            sentResponses[reference] = item
            let message = CodexAppServerMessage.response(id, result: Self.cancelledResult(for: method))
            sentMessages[reference] = message
            let reply = try await writeWithGate(
                message, beforeDispatch: {}, requestFence: item.fence, effect: .cancellation
            )
            guard reply == .acknowledged else { throw ClaudeCodeACPError.unavailable }
            return
        }
        if !cancellationRequested { state = .waiting }
        let attention = try CandidateAttentionEvent(
            scope: .session, phase: form == nil ? .waitingForApproval : .waitingForQuestion,
            request: reference, context: context
        )
        try await emit(form == nil ? .approval(attention) : .question(attention))
    }

    private func withdrawRequest(_ params: AgentEventJSON) async throws {
        let fields = try ClaudeCodeACPWire.object(params)
        let id = try CodexAppServerRequestID(fields["requestId"] ?? .null)
        guard let withdrawn = pending.first(where: { $0.value.wireID == id }) else { return }
        let (reference, item) = withdrawn
        item.fence.revoke()
        pending.removeValue(forKey: reference)
        if state == .waiting, pending.isEmpty {
            state = promptID == nil ? (parentOutcome ?? .unknown) : .submitted
        }
        try await emit(.requestResolved(CandidateRequestResolutionEvent(
            scope: .session, request: reference, context: item.question.context
        )))
    }

    private func resolveToolRequests(_ update: [String: AgentEventJSON]) async throws {
        guard update["sessionUpdate"] == .string("tool_call_update"),
              update["status"] == .string("completed") || update["status"] == .string("failed"),
              case .string(let toolID) = update["toolCallId"] else { return }
        for (reference, item) in Array(pending) + Array(sentResponses) {
            let params = try ClaudeCodeACPWire.object(item.params)
            let associatedID: AgentEventJSON?
            if item.question.permission {
                associatedID = try ClaudeCodeACPWire.object(params["toolCall"] ?? .null)["toolCallId"]
            } else { associatedID = params["toolCallId"] }
            guard ClaudeCodeACPWire.matches(associatedID, string: toolID) else { continue }
            item.fence.revoke()
            pending.removeValue(forKey: reference)
            sentResponses.removeValue(forKey: reference)
            sentMessages.removeValue(forKey: reference)
            try await emit(.requestResolved(CandidateRequestResolutionEvent(
                scope: .session, request: reference, context: item.question.context
            )))
        }
    }

    private static func cancelledResult(for method: String) -> AgentEventJSON {
        method == "session/request_permission"
            ? .object(["outcome": .object(["outcome": .string("cancelled")])])
            : .object(["action": .string("cancel")])
    }

    private func cancelPendingRequests(
        beforeDispatch: @escaping @Sendable () throws -> Void
    ) async throws -> AgentAdapterControlDispatch {
        let items = pending.values.sorted { $0.sequence < $1.sequence }
        for item in items {
            let result = Self.cancelledResult(for: item.method)
            pending.removeValue(forKey: item.question.request)
            sentResponses[item.question.request] = item
            let message = CodexAppServerMessage.response(item.wireID, result: result)
            sentMessages[item.question.request] = message
            let reply = try await writeWithGate(
                message, beforeDispatch: beforeDispatch,
                requestFence: item.fence, effect: native.map { _ in .cancellation }
            )
            if reply == .uncertain { return .uncertain }
        }
        return .acknowledged
    }

    private func writeWithGate(
        _ message: CodexAppServerMessage,
        beforeDispatch: @escaping @Sendable () throws -> Void,
        requestFence: ClaudeCodeACPRequestFence?,
        effect: AgentTaskNativeOwnership.Effect?
    ) async throws -> AgentAdapterControlDispatch {
        let bytes = try ClaudeCodeACPWire.encode(message)
        // A fresh per-operation bound, never the session lifetime.
        let writeDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        if let native, let effect {
            return try await native.perform(effect, deadline: writeDeadline) {
                try await self.writeWithGate(
                    bytes, deadline: writeDeadline, beforeDispatch: beforeDispatch, requestFence: requestFence
                )
            }
        }
        return try await writeWithGate(
            bytes, deadline: writeDeadline, beforeDispatch: beforeDispatch, requestFence: requestFence
        )
    }

    private func writeWithGate(
        _ bytes: Data,
        deadline writeDeadline: ContinuousClock.Instant,
        beforeDispatch: @escaping @Sendable () throws -> Void,
        requestFence: ClaudeCodeACPRequestFence?
    ) async throws -> AgentAdapterControlDispatch {
        let transport = try self.transport
        let authority = request.controlAuthority
        let possibleEffect = Mutex(false)
        do {
            try await transport.write(bytes, deadline: writeDeadline, beforeWrite: {
                try authority.validate()
                try beforeDispatch()
                try authority.validate()
                try transport.validate()
                try requestFence?.validate()
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
        guard outcome == .accepted || outcome == .bufferedUntilActivation else { throw ClaudeCodeACPError.unavailable }
        try transport.validate()
    }

    private func loseConnection() {
        guard state != .stopped else { return }
        if state != .blocked { state = .unknown }
        for item in pending.values { item.fence.revoke() }
        for item in sentResponses.values { item.fence.revoke() }
        pending.removeAll()
        sentMessages.removeAll()
        request.controlAuthority.revoke()
        revokeOwnership()
        // Fence I/O now; the revoked owner retains bounded process cleanup.
        ownedTransport?.close()
    }

    func stop(deadline: ContinuousClock.Instant) async {
        state = .stopped
        for item in pending.values { item.fence.revoke() }
        for item in sentResponses.values { item.fence.revoke() }
        pending.removeAll()
        sentResponses.removeAll()
        sentMessages.removeAll()
        nativeSubmission = nil
        request.controlAuthority.revoke()
        revokeOwnership()
        ownedTransport?.close()
        reader?.cancel()
        reader = nil
        await notify()
        await ownedTransport?.stop(deadline: deadline)
        await native?.invalidate()
    }
}

extension ContinuousClock.Instant {
    /// Effectively unbounded session I/O lifetime (100 years). The session
    /// ends on transport loss or explicit owner stop, never on a fixed
    /// launch-window instant; per-operation bounds stay with each write.
    static var claudeCodeACPUnbounded: ContinuousClock.Instant {
        .now.advanced(by: .seconds(3_153_600_000))
    }
}

/// Negative-only, connection-local fence checked by every physical reply write.
nonisolated private final class ClaudeCodeACPRequestFence: Sendable {
    private let active = Mutex(true)
    func revoke() { active.withLock { $0 = false } }
    func validate() throws {
        try active.withLock { if !$0 { throw ClaudeCodeACPError.invalidAnswer } }
    }
}
