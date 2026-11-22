import Foundation
import Synchronization

/// ACP v1 only. Presentation data is transient, bounded, and excluded from
/// diagnostic reflection. This actor persists no transcript or credentials;
/// the existing task registry owns the exact native ID for explicit recovery.
actor OpenCodeACPSession: AgentAdapterControlledSession, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable {
    nonisolated var description: String { "<redacted:opencode-acp-session>" }
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
        let form: OpenCodeACPForm?
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
        let fence: OpenCodeACPRequestFence
    }

    nonisolated let contract: NegotiatedAdapterContract
    private let request: AgentAdapterSessionRequest
    private let launch: @Sendable (ContinuousClock.Instant) async throws -> any OpenCodeACPTransport
    private var ownedTransport: (any OpenCodeACPTransport)?
    private var transport: any OpenCodeACPTransport {
        get throws {
            guard let ownedTransport else { throw OpenCodeACPError.unavailable }
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
    private let native: OpenCodeACPNativeControl?
    private var nativeSubmission: OpenCodeACPNativeSubmission?
    private var nativeResponseClaimedID: UUID?
    private var children: [VendorReference: String] = [:]
    private var childParents: [VendorReference: VendorReference] = [:]
    private var childDepths: [VendorReference: Int] = [:]
    private var childTurns: [VendorReference: Int] = [:]
    private var childTools: [Data: VendorReference] = [:]
    private var state = State.fresh
    private var nativeSession: String?
    // Actual client RPC correlation, never a fabricated provider operation ID.
    private var promptContext: VendorReference?
    private var promptID: CodexAppServerRequestID?
    private var nextID: Int64 = 2
    private var pending: [VendorReference: Pending] = [:]
    private var sentResponses: [VendorReference: Pending] = [:]
    private var seenRequests: Set<CodexAppServerRequestID> = []
    private var result = ""
    private var resultStarted = false
    private var turnOrdinal = 0
    private var writing = false
    private var cancellationRequested = false
    private var parentOutcome: State?
    private var inputFenced = false
    private var reader: Task<Void, Never>?
    private var observer: (@Sendable (Snapshot) async -> Void)?

    /// One application-lifetime consumer; reopening a window reuses that owner.
    func observe(_ observer: @escaping @Sendable (Snapshot) async -> Void) async throws {
        guard self.observer == nil else { throw OpenCodeACPError.invalidState }
        self.observer = observer
        await notify()
    }

    private func notify() async {
        if let observer { await observer(snapshot()) }
    }

    /// `loadSession` is an explicit exact-ID action, never latest-session lookup.
    /// Its gate must revalidate original cwd/configuration and new attempt binding.
    init(request: AgentAdapterSessionRequest,
         launch: @escaping @Sendable (ContinuousClock.Instant) async throws -> any OpenCodeACPTransport,
         cwd: String, deadline: ContinuousClock.Instant,
         loadSession: VendorReference? = nil,
         native: OpenCodeACPNativeControl? = nil,
         beforeStartWrite: @escaping @Sendable () throws -> Void,
         revokeOwnership: @escaping @Sendable () -> Void,
         sessionBound: @escaping @Sendable (VendorReference) async throws -> Void,
         promptResponded: @escaping @Sendable (State) async throws -> ResponseDisposition) throws {
        guard request.resumeFrom == nil else { throw AdapterSessionError.checkpointNotSupported }
        guard request.contract.profile == (try Self.profile()),
              request.contract.agentID.value == "openCode",
              request.contract.version == PineAdapterContractVersion(major: 1, minor: 1),
              loadSession == nil || loadSession?.role == .conversation,
              loadSession.map({ OpenCodeACPWire.validSessionID($0.rawValue) }) ?? true,
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

    /// SINGLE SOURCE OF TRUTH for the pinned OpenCode ADE version.
    /// Re-probed 2026-11-21 (sanitized evidence:
    /// $TMPDIR/opencode/pine-1811-real-probe/sanitized-result.json):
    /// CLI `opencode --version` -> "opencode v2.3.2"; ACP initialize
    /// agentInfo -> {name: "OpenCode", version: "2.3.2"}. The launch gate
    /// (OpenCodeACPExecutableIdentity.supportedVersion) derives the CLI
    /// spelling from this constant; the handshake gate compares agentInfo.
    nonisolated static let pinnedVersion = "2.3.2"

    func start() async throws {
        guard state == .fresh else { throw OpenCodeACPError.invalidState }
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
                    "elicitation": .object(["form": .object([:])]),
                    "_meta": .object(["opencode/child-session-updates": .bool(true)])
                ])
            ]))
            let initialized = try OpenCodeACPWire.object(initialization)
            guard initialized["protocolVersion"] == .number("1") else { throw OpenCodeACPError.invalidProtocol }
            let agent = try OpenCodeACPWire.object(initialized["agentInfo"] ?? .null)
            // Pinned extension: do not promote simplified generic ACP docs to
            // a guarantee for arbitrary versions. Native hash validation is admission's job.
            let capabilities = try OpenCodeACPWire.object(initialized["agentCapabilities"] ?? .null)
            let meta = try OpenCodeACPWire.object(capabilities["_meta"] ?? .null)
            guard agent["name"] == .string("OpenCode"), agent["version"] == .string(Self.pinnedVersion),
                  meta["opencode/child-session-updates"] == .bool(true) else { throw OpenCodeACPError.unavailable }
            var creation: [String: AgentEventJSON] = ["cwd": .string(cwd), "mcpServers": .array([])]
            if let loadSession {
                guard capabilities["loadSession"] == .bool(true) else { throw OpenCodeACPError.unavailable }
                creation["sessionId"] = .string(loadSession.rawValue)
            }
            let session = try await bootstrap(id: .integer(1),
                                             method: loadSession == nil ? "session/new" : "session/load",
                                             params: .object(creation))
            let fields = try OpenCodeACPWire.object(session)
            let sessionID = try OpenCodeACPWire.string(fields["sessionId"] ?? loadSession.map {
                AgentEventJSON.string($0.rawValue)
            })
            guard OpenCodeACPWire.validSessionID(sessionID),
                  loadSession == nil || sessionID == loadSession?.rawValue else {
                throw OpenCodeACPError.invalidProtocol
            }
            nativeSession = sessionID
            try await sessionBound(VendorReference(role: .conversation, value: sessionID))
            guard state == .starting else { throw OpenCodeACPError.unavailable }
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
        try await transport.write(OpenCodeACPWire.encode(.request(id, method: method, params: params)),
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
                throw OpenCodeACPError.providerFailure(code)
            case .notification(let method, let params) where id == .integer(1) && method == "session/update":
                let fields = try OpenCodeACPWire.object(params)
                if let loadSession, !OpenCodeACPWire.matches(fields["sessionId"], string: loadSession.rawValue) {
                    throw OpenCodeACPError.invalidProtocol
                }
                replayCount += 1
                guard replayCount <= 256 else { throw OpenCodeACPError.capacity }
            default: throw OpenCodeACPError.invalidProtocol
            }
        }
        throw OpenCodeACPError.unavailable
    }

    private var hasUnresolvedPriorWork: Bool {
        !sentResponses.isEmpty || children.values.contains {
            !["completed", "failed", "interrupted"].contains($0)
        }
    }

    func dispatch(_ control: AgentAdapterControl,
                  beforeDispatch: @escaping @Sendable () throws -> Void) async throws -> AgentAdapterControlDispatch {
        try request.controlAuthority.validate()
        try transport.validate()
        guard !writing, ![.fresh, .starting, .blocked, .unknown, .stopped].contains(state),
              let session = nativeSession else { throw OpenCodeACPError.invalidState }
        writing = true
        defer { writing = false }
        let message: CodexAppServerMessage
        var resolved: Pending?
        var prepared: OpenCodeACPNativeSubmission?
        var effect: AgentTaskNativeOwnership.Effect?
        switch control {
        case .submitInstruction(let text):
            guard state == .idle || parentOutcome != nil,
                  promptID == nil, pending.isEmpty, !hasUnresolvedPriorWork,
                  !cancellationRequested, !inputFenced,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  text.utf8.count <= 65_536, nextID < Int64.max, turnOrdinal < Int.max else {
                throw OpenCodeACPError.invalidState
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
                    throw OpenCodeACPError.invalidState
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
            turnOrdinal += 1
            resultStarted = false
            cancellationRequested = false
            parentOutcome = nil
            state = .submitted
        case .requestCancellation(let context):
            guard context == promptContext, promptID != nil, state != .cancelRequested else {
                throw OpenCodeACPError.invalidState
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
                throw OpenCodeACPError.invalidState
            }
            effect = native.map { _ in .cancellation }
            message = .notification(method: "session/cancel", params: .object(["sessionId": .string(session)]))
        case .answerQuestion(let reference, let context, let answers):
            guard let item = pending[reference], item.question.context == context,
                  let form = item.question.form, !cancellationRequested else { throw OpenCodeACPError.invalidAnswer }
            message = .response(item.wireID, result: .object([
                "action": .string("accept"), "content": try form.content(answers: answers)
            ]))
            resolved = item
            pending.removeValue(forKey: reference)
            effect = native.map { _ in .decision }
        case .answerPermission(let reference, let context, let decision):
            guard let item = pending[reference], item.question.context == context,
                  item.question.permission, !cancellationRequested else { throw OpenCodeACPError.invalidAnswer }
            let kind = switch decision {
            case .allowOnce: "allow_once"
            case .deny: "reject_once"
            }
            guard let option = item.options[kind] else { throw OpenCodeACPError.invalidAnswer }
            message = .response(item.wireID, result: .object([
                "outcome": .object(["outcome": .string("selected"), "optionId": .string(option)])
            ]))
            resolved = item
            pending.removeValue(forKey: reference)
            effect = native.map { _ in .decision }
        }
        // Reserve before the async write so a fast owning-tool completion
        // cannot be lost and then overwritten by the write's acknowledgement.
        if let resolved { sentResponses[resolved.question.request] = resolved }
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
            while let message = try await transport.read(deadline: .opencodeACPUnbounded) {
                try transport.validate()
                guard state != .stopped, state != .unknown else { return }
                try await receive(message)
                await notify()
            }
            loseConnection()
        } catch OpenCodeACPError.unsupportedQuestion {
            state = .blocked
            loseConnection()
        } catch { loseConnection() }
        await notify()
    }

    private func receive(_ message: CodexAppServerMessage) async throws {
        switch message {
        case .notification(let method, let params):
            if method == "opencode/session/child_update" {
                try await receiveChild(params)
                return
            }
            guard method == "session/update" else { return }
            let fields = try OpenCodeACPWire.object(params)
            guard OpenCodeACPWire.matches(fields["sessionId"], string: nativeSession) else {
                throw OpenCodeACPError.invalidProtocol
            }
            let update = try OpenCodeACPWire.object(fields["update"] ?? .null)
            let kind = try OpenCodeACPWire.string(update["sessionUpdate"])
            let child = try observeChild(update["_meta"])
            if let child, kind == "agent_message_chunk", childTurns[child] != turnOrdinal {
                // A child from an earlier prompt has no current-turn authority.
                throw OpenCodeACPError.invalidProtocol
            }
            if let child, ["tool_call", "tool_call_update"].contains(kind),
               case .string(let identifier) = update["toolCallId"] {
                try rememberTool(identifier, child: child)
                if children[child] == nil { children[child] = "observed" }
            }
            try await resolveToolRequests(update)
            // Command/config notifications can precede a prompt; none are lifecycle.
            guard ["agent_message_chunk", "tool_call", "tool_call_update"].contains(kind),
                  promptContext != nil else { return }
            if promptID == nil {
                // Root activity after the correlated response is late output of the
                // settled turn. ACP 2.3.2 supplies no root-final boundary, so the text
                // can never start or pollute a result and input stays fenced.
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
                guard result.utf8.count + text.utf8.count <= 65_536 else { throw OpenCodeACPError.capacity }
                result += text
            }
            // Observed activity is not completion or evidence of check success.
            if !cancellationRequested {
                if pending.isEmpty { state = .working }
                try await emit(.lifecycle(CandidateLifecycleEvent(
                    scope: .session, phase: .working,
                    reference: VendorReference(role: .conversation, value: try OpenCodeACPWire.string(fields["sessionId"]))
                )))
            }
        case .response(let id, let response):
            let submission = try claimParentResponse(id)
            let fields = try OpenCodeACPWire.object(response)
            let reason = try OpenCodeACPWire.string(fields["stopReason"])
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
    ) throws -> OpenCodeACPNativeSubmission? {
        guard id == promptID else { throw OpenCodeACPError.invalidProtocol }
        // Claim synchronously before registry/persistence awaits. Cancellation
        // and write acknowledgement can no longer transition this prompt first.
        promptID = nil
        guard let submission = nativeSubmission else { return nil }
        nativeSubmission = nil
        nativeResponseClaimedID = submission.id
        return submission
    }

    private func observeParentResponse(_ submission: OpenCodeACPNativeSubmission?) async throws {
        guard let native, let submission else { return }
        try await native.responseObserved(submission)
    }

    private func emitParentOutcome(_ phase: AdapterLifecyclePhase) async throws {
        guard let nativeSession else { throw OpenCodeACPError.invalidState }
        try await emit(.lifecycle(CandidateLifecycleEvent(
            scope: .session, phase: phase,
            reference: VendorReference(role: .conversation, value: nativeSession)
        )))
    }

    private func receiveRequest(_ id: CodexAppServerRequestID, method: String, params: AgentEventJSON) async throws {
        let fields = try OpenCodeACPWire.object(params)
        guard OpenCodeACPWire.matches(fields["sessionId"], string: nativeSession), promptContext != nil,
              let nativeSession else {
            throw OpenCodeACPError.invalidProtocol
        }
        if seenRequests.contains(id) {
            guard pending.values.contains(where: { $0.wireID == id && $0.params == params && $0.method == method }) else {
                throw OpenCodeACPError.invalidProtocol
            }
            return
        }
        guard pending.count + sentResponses.count < 16, seenRequests.count < 256,
              try params.canonicalData().count <= 65_536 else { throw OpenCodeACPError.capacity }
        let form: OpenCodeACPForm?
        var options: [String: String] = [:]
        switch method {
        case "elicitation/create":
            // Unsupported schemas fail the connection, rather than sending a
            // method error that lets OpenCode continue without the user's answer.
            form = try OpenCodeACPForm(fields)
        case "session/request_permission":
            form = nil
            guard case .array(let values) = fields["options"], values.count <= 16 else {
                throw OpenCodeACPError.invalidProtocol
            }
            for value in values {
                let option = try OpenCodeACPWire.object(value)
                let kind = try OpenCodeACPWire.string(option["kind"])
                let optionID = try OpenCodeACPWire.string(option["optionId"])
                guard options[kind] == nil, !options.values.contains(optionID) else {
                    throw OpenCodeACPError.invalidProtocol
                }
                options[kind] = optionID
            }
            guard options["allow_once"] != nil, options["reject_once"] != nil else {
                throw OpenCodeACPError.invalidProtocol
            }
        // Pinned-version contract (re-probe 2026-11-21, agent 2.3.2): during
        // initialize and session/new the agent issues NO server->client
        // requests; the only documented requests during a turn are
        // elicitation/create and session/request_permission (child-session
        // activity arrives as the opencode/session/child_update notification,
        // advertised by the pinned _meta capability). Anything else is a
        // protocol violation -> fail-closed kill.
        default: throw OpenCodeACPError.invalidProtocol
        }
        let questionID = UUID()
        let reference = try VendorReference(role: .request, value: questionID.uuidString)
        let details = form == nil ? fields["toolCall"] : nil
        if form == nil { _ = try OpenCodeACPWire.object(details ?? .null) }
        let toolID: String?
        let directChild: VendorReference?
        if let details {
            let tool = try OpenCodeACPWire.object(details)
            toolID = try tool["toolCallId"].map { try OpenCodeACPWire.string($0) }
            directChild = try observeChild(tool["_meta"])
        } else {
            toolID = try fields["toolCallId"].map { try OpenCodeACPWire.string($0) }
            directChild = nil
        }
        let mappedChild = toolID.flatMap { childTools[Data($0.utf8)] }
        if let directChild, let mappedChild, directChild.rawValue != mappedChild.rawValue {
            throw OpenCodeACPError.invalidProtocol
        }
        // The native wire scopes asks to the session, not to a root prompt.
        // Closing a parent turn must not close this attention context.
        let context = try VendorReference(role: .conversation, value: nativeSession)
        let question = Question(id: questionID, request: reference, context: context, form: form, permission: form == nil,
                                 details: details, childOwner: directChild ?? mappedChild,
                                 allowOnceOptionID: options["allow_once"], denyOptionID: options["reject_once"])
        let item = Pending(wireID: id, question: question, params: params, method: method,
                           options: options, sequence: seenRequests.count, fence: OpenCodeACPRequestFence())
        pending[reference] = item
        seenRequests.insert(id)
        if cancellationRequested || (native != nil && parentOutcome == .cancelled) {
            // Cancellation forbids fresh decisions. Service late child work
            // with the terminal outcome, not a stale actionable UI ask.
            pending.removeValue(forKey: reference)
            sentResponses[reference] = item
            let reply = try await writeWithGate(
                .response(id, result: Self.cancelledResult(for: method)),
                beforeDispatch: {}, requestFence: item.fence, effect: .cancellation
            )
            guard reply == .acknowledged else { throw OpenCodeACPError.unavailable }
            return
        }
        if !cancellationRequested { state = .waiting }
        let attention = try CandidateAttentionEvent(
            scope: .session, phase: form == nil ? .waitingForApproval : .waitingForQuestion,
            request: reference, context: context
        )
        try await emit(form == nil ? .approval(attention) : .question(attention))
    }

    private func receiveChild(_ params: AgentEventJSON) async throws {
        let fields = try OpenCodeACPWire.object(params)
        guard OpenCodeACPWire.matches(fields["rootSessionId"], string: nativeSession), promptContext != nil else {
            throw OpenCodeACPError.invalidProtocol
        }
        let child = try observeChild(.object(["opencode/child-session": .object([
            "id": fields["childSessionId"] ?? .null,
            "parentID": fields["parentSessionId"] ?? .null,
            "depth": fields["depth"] ?? .null
        ])]))
        guard let child else { throw OpenCodeACPError.invalidProtocol }
        switch fields["type"] {
        case .string("status"):
            let status = try OpenCodeACPWire.string(fields["status"])
            guard ["created", "running", "completed", "failed", "interrupted"].contains(status) else {
                throw OpenCodeACPError.invalidProtocol
            }
            children[child] = status
        case .string("update"):
            if children[child] == nil { children[child] = "unknown" }
            let update = try OpenCodeACPWire.object(fields["update"] ?? .null)
            if update["sessionUpdate"] == .string("agent_message_chunk"),
               childTurns[child] != turnOrdinal {
                throw OpenCodeACPError.invalidProtocol
            }
            try await resolveToolRequests(update)
            if let id = update["toolCallId"] {
                try rememberTool(OpenCodeACPWire.string(id), child: child)
            }
        default: throw OpenCodeACPError.invalidProtocol
        }
        if promptID == nil {
            // Child activity after the correlated response settles a turn without
            // a root-final boundary; later input cannot attribute results reliably.
            inputFenced = true
            await notify()
        }
        // Known-child completion never supplies an exhaustive child inventory,
        // a root turn boundary, or Ready. The reader stays alive after end_turn.
    }

    /// Documented OpenCode child metadata is scoped to this root conversation.
    /// IDs and parent links use exact UTF-8 bytes; unknown ownership stays nil.
    private func observeChild(_ metadata: AgentEventJSON?) throws -> VendorReference? {
        guard let metadata, metadata != .null else { return nil }
        let wrapper = try OpenCodeACPWire.object(metadata)
        guard let value = wrapper["opencode/child-session"] else { return nil }
        let fields = try OpenCodeACPWire.object(value)
        let child = try VendorReference(
            role: .conversation, value: OpenCodeACPWire.string(fields["id"])
        )
        let parent = try VendorReference(
            role: .conversation, value: OpenCodeACPWire.string(fields["parentID"])
        )
        guard OpenCodeACPWire.validSessionID(child.rawValue),
              OpenCodeACPWire.validSessionID(parent.rawValue),
              child.rawValue != nativeSession, child.rawValue != parent.rawValue,
              case .number(let rawDepth) = fields["depth"], let depth = Int(rawDepth),
              (1...32).contains(depth) else { throw OpenCodeACPError.invalidProtocol }
        if depth == 1 {
            guard parent.rawValue == nativeSession else { throw OpenCodeACPError.invalidProtocol }
        } else {
            guard childDepths[parent] == depth - 1 else { throw OpenCodeACPError.invalidProtocol }
        }
        let isNew = childDepths[child] == nil
        guard childParents[child] == nil || childParents[child]?.rawValue == parent.rawValue,
              childDepths[child] == nil || childDepths[child] == depth else {
            throw OpenCodeACPError.invalidProtocol
        }
        guard !isNew || childDepths.count < 64 else { throw OpenCodeACPError.capacity }
        childParents[child] = parent
        childDepths[child] = depth
        if isNew { childTurns[child] = turnOrdinal }
        if children[child] == nil { children[child] = "observed" }
        return child
    }

    private func rememberTool(_ identifier: String, child: VendorReference) throws {
        let key = Data(identifier.utf8)
        if let existing = childTools[key] {
            guard existing.rawValue == child.rawValue else { throw OpenCodeACPError.invalidProtocol }
        }
        guard childTools[key] != nil || childTools.count < 256 else { throw OpenCodeACPError.capacity }
        childTools[key] = child
    }

    private func resolveToolRequests(_ update: [String: AgentEventJSON]) async throws {
        guard update["sessionUpdate"] == .string("tool_call_update"),
              update["status"] == .string("completed") || update["status"] == .string("failed"),
              case .string(let toolID) = update["toolCallId"] else { return }
        for (reference, item) in Array(pending) + Array(sentResponses) {
            let params = try OpenCodeACPWire.object(item.params)
            let associatedID: AgentEventJSON?
            if item.question.permission {
                associatedID = try OpenCodeACPWire.object(params["toolCall"] ?? .null)["toolCallId"]
            } else { associatedID = params["toolCallId"] }
            guard OpenCodeACPWire.matches(associatedID, string: toolID) else { continue }
            item.fence.revoke()
            pending.removeValue(forKey: reference)
            sentResponses.removeValue(forKey: reference)
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
            let reply = try await writeWithGate(
                .response(item.wireID, result: result), beforeDispatch: beforeDispatch,
                requestFence: item.fence, effect: native.map { _ in .cancellation }
            )
            if reply == .uncertain { return .uncertain }
        }
        return .acknowledged
    }

    private func writeWithGate(
        _ message: CodexAppServerMessage,
        beforeDispatch: @escaping @Sendable () throws -> Void,
        requestFence: OpenCodeACPRequestFence?,
        effect: AgentTaskNativeOwnership.Effect?
    ) async throws -> AgentAdapterControlDispatch {
        let bytes = try OpenCodeACPWire.encode(message)
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
        requestFence: OpenCodeACPRequestFence?
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
        guard outcome == .accepted || outcome == .bufferedUntilActivation else { throw OpenCodeACPError.unavailable }
        try transport.validate()
    }

    private func loseConnection() {
        guard state != .stopped else { return }
        if state != .blocked { state = .unknown }
        for item in pending.values { item.fence.revoke() }
        for item in sentResponses.values { item.fence.revoke() }
        pending.removeAll()
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
    static var opencodeACPUnbounded: ContinuousClock.Instant {
        .now.advanced(by: .seconds(3_153_600_000))
    }
}

/// Negative-only, connection-local fence checked by every physical reply write.
nonisolated private final class OpenCodeACPRequestFence: Sendable {
    private let active = Mutex(true)
    func revoke() { active.withLock { $0 = false } }
    func validate() throws {
        try active.withLock { if !$0 { throw OpenCodeACPError.invalidAnswer } }
    }
}
