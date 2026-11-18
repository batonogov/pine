import Foundation
import Synchronization

// MARK: - Materials

/// One-shot spawn materials for a supervised owned-stdio Codex session
/// (#1723).
///
/// Carries the registry-owned admission state: the session consumes the
/// registry's persist-before-send path and never keeps a second journal.
/// Possession is not an execution grant: the ownership revalidates the
/// binding, environment, and filesystem before spawn and before every
/// physical effect.
nonisolated struct CodexAppServerNativeMaterials: Sendable {
    let registry: AgentTaskRegistry
    let ownership: AgentTaskNativeOwnership
    let workingDirectory: URL
    let sessionDeadline: ContinuousClock.Instant
    let experimentalAPI: Bool
    /// Returns exactly one owned child plus the process receipt the registry
    /// admits. Production is the literal-argv spawner; tests may substitute
    /// an in-memory child.
    let spawn: @Sendable (ContinuousClock.Instant) throws -> Spawn

    /// One spawned child plus its receipt. The child belongs to the client;
    /// the receipt belongs to the registry.
    struct Spawn: Sendable {
        let child: CodexAppServerOwnedChild
        let receipt: AgentTaskOwnedProcessReceipt
    }

    /// Production materials: one registry-prepared ownership, one pinned
    /// executable, one bound worktree, no shell, no overrides. Inherited
    /// native configuration is the only permitted settings intent in this
    /// slice.
    static func owned(
        registry: AgentTaskRegistry,
        ownership: AgentTaskNativeOwnership,
        executable: CodexAppServerExecutableIdentity,
        workingDirectory: URL,
        sessionDeadline: ContinuousClock.Instant
    ) -> Self {
        let working = workingDirectory
        let arguments: [String] = ["app-server"]
        return Self(
            registry: registry,
            ownership: ownership,
            workingDirectory: working,
            sessionDeadline: sessionDeadline,
            experimentalAPI: true,
            spawn: { deadline in
                try CodexAppServerNativeSpawner.spawn(
                    ownership: ownership, executable: executable,
                    workingDirectory: working, arguments: arguments, deadline: deadline
                )
            }
        )
    }
}

// MARK: - Owned child

/// One spawned owned child plus its process-group teardown ownership. Both
/// the client's bounded-startup cleanup and the session's explicit stop call
/// `stop`; exactly one executes the teardown.
nonisolated final class CodexAppServerNativeChild: @unchecked Sendable {
    private struct StopState: Sendable {
        var stopped = false
    }
    private struct ReaperSlot: Sendable {
        var reaper: UserTaskBackgroundReaper?
    }
    private let stopState = Mutex(StopState())
    private let reaperSlot = Mutex(ReaperSlot())
    let channel: CodexAppServerStdioChannel
    let receipt: AgentTaskOwnedProcessReceipt
    private let subprocess: UserTaskSubprocess

    init(subprocess: UserTaskSubprocess, channel: CodexAppServerStdioChannel, receipt: AgentTaskOwnedProcessReceipt) {
        self.subprocess = subprocess
        self.channel = channel
        self.receipt = receipt
    }

    /// Closes the channel's input side, supervises the process group to the
    /// deadline, and fences the receipt. Never blocks the cooperative pool.
    func stop(deadline: ContinuousClock.Instant) async {
        let shouldRun = stopState.withLock { value -> Bool in
            guard !value.stopped else { return false }
            value.stopped = true
            return true
        }
        guard shouldRun else { return }
        let subprocess = self.subprocess
        let receipt = self.receipt
        await runOnBackground {
            let group = subprocess.processGroup
            if group.isAlive {
                group.requestTermination()
            }
            let remaining = Self.timeInterval(to: deadline)
            _ = group.waitForRequestedTermination(completionTimeout: remaining)
            if case .running = subprocess.pollExit() {
                let reaper = subprocess.reapInBackground()
                self.reaperSlot.withLock { $0.reaper = reaper }
                if group.isAlive {
                    Task.detached { [group] in group.finishDeferredCleanup() }
                }
            }
        }
        receipt.revoke()
    }

    private static func timeInterval(to deadline: ContinuousClock.Instant) -> TimeInterval {
        let components = ContinuousClock.now.duration(to: deadline).components
        return max(0, Double(components.seconds) + Double(components.attoseconds) / 1e18)
    }
}

// MARK: - Spawner

/// Literal-argv spawn for the pinned Codex app-server. No shell, no PATH
/// search, no retry: a failed spawn leaves nothing to clean up or fences the
/// just-created child immediately.
///
/// Synchronous by contract: it runs inside the registry-owned `.launch`
/// effect action, already off-main, immediately after the ownership's
/// pre-launch revalidation. The pinned version was probed at preparation;
/// here the exact-image stamp, the pre-spawn validation, and the receipt's
/// image gate cover the spawn.
nonisolated enum CodexAppServerNativeSpawner {
    static func spawn(
        ownership: AgentTaskNativeOwnership,
        executable: CodexAppServerExecutableIdentity,
        workingDirectory: URL,
        arguments: [String],
        deadline: ContinuousClock.Instant
    ) throws -> CodexAppServerNativeMaterials.Spawn {
        precondition(!Thread.isMainThread)
        guard ContinuousClock.now < deadline else { throw CodexAppServerExecutableError.unavailable }
        try executable.validateMetadataSynchronously()
        let subprocess: UserTaskSubprocess
        do {
            subprocess = try UserTaskSubprocess(
                executableURL: executable.canonicalURL,
                arguments: arguments,
                workingDirectory: workingDirectory,
                preSpawnValidation: { _ in try ownership.validate() }
            )
        } catch {
            throw CodexAppServerExecutableError.unavailable
        }
        do {
            let channel = try CodexAppServerStdioChannel(
                standardInput: subprocess.standardInput,
                standardOutput: subprocess.standardOutput,
                standardError: subprocess.standardError
            )
            let receipt = try AgentTaskOwnedProcessReceipt(process: subprocess, ownership: ownership) {
                try executable.validateProcessImageSynchronously(processID: $0.processID, incarnation: $0)
            }
            let child = CodexAppServerNativeChild(subprocess: subprocess, channel: channel, receipt: receipt)
            return CodexAppServerNativeMaterials.Spawn(
                child: CodexAppServerOwnedChild(
                    channel: child.channel,
                    processIdentity: child.receipt.identity,
                    stop: { stopDeadline in await child.stop(deadline: stopDeadline) }
                ),
                receipt: child.receipt
            )
        } catch {
            let group = subprocess.processGroup
            if group.isAlive {
                group.requestTermination()
            }
            _ = group.waitForRequestedTermination(completionTimeout: 2)
            _ = subprocess.pollExit()
            throw CodexAppServerExecutableError.unavailable
        }
    }
}

// MARK: - Session

/// Negative replay fence for one session. A previously written answer is
/// replayable only while the session's live gates still hold; stop deactivates
/// it synchronously.
nonisolated private final class CodexAppServerNativeReplayFence:
    CodexAppServerResponseReplayAuthority, @unchecked Sendable {
    private struct Gates: Sendable {
        var active = false
        var ownership: AgentTaskNativeOwnership?
        var controlAuthority: AgentAdapterControlAuthority?
    }
    private let gates = Mutex(Gates())

    func activate(
        ownership: AgentTaskNativeOwnership,
        controlAuthority: AgentAdapterControlAuthority
    ) {
        gates.withLock {
            $0.active = true
            $0.ownership = ownership
            $0.controlAuthority = controlAuthority
        }
    }

    func deactivate() {
        gates.withLock { $0.active = false }
    }

    func validateReplay() throws {
        try gates.withLock { value in
            guard value.active, let ownership = value.ownership,
                  let controlAuthority = value.controlAuthority else {
                throw CodexAppServerWireError.closed
            }
            try ownership.validate()
            try controlAuthority.validate()
        }
    }
}

/// One mutable bit shared with the client's synchronous account-change hook.
nonisolated private final class CodexAppServerNativeFlag: @unchecked Sendable {
    private let flag = Mutex(false)
    func isSet() -> Bool { flag.withLock { $0 } }
    func set() { flag.withLock { $0 = true } }
}

/// A supervised owned-stdio Codex app-server session bound to one
/// registry-prepared ownership and one pinned executable (#1723).
///
/// The session is a pure consumer of the registry path: every input-affecting
/// effect is recorded durably before it is written, and every wire event is
/// ingested through the registry-owned sink. Wire data stays untrusted until
/// mapped and ingested; unknown methods and fields never gain authority;
/// lost, duplicate, or stale traffic is fenced, never retried. A dead
/// process or transport is a negative observation for the registry, never a
/// live run.
///
/// The base mapper retains a completed turn's binding, so each logical turn
/// gets a fresh mapper instance and connection namespace; pre-binding
/// traffic for the new turn is buffered by that instance and replayed after
/// the correlated response.
actor CodexAppServerNativeSession: AgentAdapterSession,
    AgentAdapterControlledSession {
    private enum Phase: Sendable { case unstarted, starting, ready, tornDown }
    private struct ActionableRequest: Sendable {
        let method: String
        let request: VendorReference
        let context: VendorReference?
        let params: AgentEventJSON
    }

    nonisolated let contract: NegotiatedAdapterContract
    private let registry: AgentTaskRegistry
    private let ownership: AgentTaskNativeOwnership
    private let spawn: @Sendable (ContinuousClock.Instant) throws -> CodexAppServerNativeMaterials.Spawn
    private let workingDirectory: URL
    private let sessionDeadline: ContinuousClock.Instant
    private let experimentalAPI: Bool
    private let sink: any AgentEventSink
    private var phase: Phase = .unstarted
    private var client: CodexAppServerClient?
    private var mapper: CodexAppServerTaskMapper?
    private var threadValue: String?
    private var activeTurnValue: String?
    /// The claimed receipt of the turn whose completion is not yet observed.
    private var activeSubmission: AgentTaskNativeSubmissionReceipt?
    private var actionable: [CodexAppServerRequestID: ActionableRequest] = [:]
    private var pumpTask: Task<Void, Never>?
    private var accountState: CodexAppServerAccountState = .unknown
    private let turnStarted = CodexAppServerNativeFlag()
    private let replayFence = CodexAppServerNativeReplayFence()

    init(materials: CodexAppServerNativeMaterials, request: AgentAdapterSessionRequest) {
        guard materials.ownership.policy.requestedSettings == .inheritNativeConfiguration else {
            preconditionFailure("Native sessions only inherit native configuration")
        }
        self.registry = materials.registry
        self.ownership = materials.ownership
        self.spawn = materials.spawn
        self.workingDirectory = materials.workingDirectory
        self.sessionDeadline = materials.sessionDeadline
        self.experimentalAPI = materials.experimentalAPI
        self.contract = request.contract
        self.sink = request.sink
        replayFence.activate(
            ownership: materials.ownership, controlAuthority: request.controlAuthority
        )
    }

    // MARK: AgentAdapterSession

    func start() async throws {
        guard phase == .unstarted else { throw AdapterSessionError.invalidLifecycle }
        phase = .starting
        do {
            // The spawn runs inside the registry-owned launch effect: the
            // ownership revalidates binding, environment, and filesystem
            // immediately before the off-main action executes.
            let environment = ProcessInfo.processInfo.environment
            let spawn = self.spawn
            let sessionDeadline = self.sessionDeadline
            let spawned = try await registry.performNativeEffect(
                .launch(environment: environment), ownership: ownership
            ) {
                try spawn(sessionDeadline)
            }
            try await registry.admitNativeProcess(ownership, receipt: spawned.receipt)
            let turnStarted = self.turnStarted
            let client = CodexAppServerClient(
                sessionDeadline: sessionDeadline,
                experimentalAPI: experimentalAPI,
                accountChanged: { turnStarted.isSet() },
                onConnectionClosed: { [weak self] in
                    Task { await self?.connectionClosed() }
                },
                launch: { _ in spawned.child }
            )
            self.client = client
            try await client.start()

            // Discovery only: account state is informational and is not
            // transport or execution authority.
            if let result = try? await client.call(
                method: "account/read",
                params: .object(["refreshToken": .bool(false)])
            ) {
                accountState = (try? CodexAppServerAccountState(response: result)) ?? .unknown
            }

            // A fresh provider conversation rooted in the bound worktree.
            // No model, approval, or sandbox overrides: native inheritance.
            let started = try await client.call(
                method: "thread/start",
                params: .object(["cwd": .string(workingDirectory.path)]),
                beforeDispatch: preflightGate()
            )
            guard case .object(let fields) = started,
                  case .object(let threadObject) = fields["thread"],
                  case .string(let threadID) = threadObject["id"] else {
                throw CodexAppServerTaskError.unavailable
            }
            let mapper = try CodexAppServerTaskMapper(connectionID: UUID(), threadID: threadID)
            self.mapper = mapper
            threadValue = threadID
            try await registry.recordNativeTransition(.sessionBound(AgentVendorSessionIdentity(
                provider: ownership.policy.agentID.value,
                opaqueIdentifier: threadID,
                executableVersion: CodexAppServerExecutableIdentity.supportedVersion
            )), ownership: ownership)
            pumpTask = Task { await pump() }
            phase = .ready
        } catch {
            await stop(deadline: .now.advanced(by: .seconds(2)))
            throw error
        }
    }

    func stop(deadline: ContinuousClock.Instant) async {
        guard phase != .tornDown else { return }
        phase = .tornDown
        pumpTask?.cancel()
        pumpTask = nil
        replayFence.deactivate()
        actionable.removeAll()
        activeSubmission = nil
        if let client {
            await client.stop(deadline: deadline)
        }
        // A stopped or dead transport is a negative observation: the
        // registry-owned run goes stale in-session, never live.
        await registry.invalidateNativeOwnership(ownership)
    }

    // MARK: AgentAdapterControlledSession

    func dispatch(
        _ control: AgentAdapterControl,
        beforeDispatch: @escaping @Sendable () throws -> Void
    ) async throws -> AgentAdapterControlDispatch {
        guard phase == .ready, let client else {
            throw CodexAppServerClientError.unavailable
        }
        let gate = preflightGate(beforeDispatch)
        switch control {
        case .submitInstruction(let text):
            return try await submit(text, client: client, gate: gate)
        case .answerPermission(let request, let context, let decision):
            let result: AgentEventJSON = .object([
                "decision": .string(decision == .allowOnce ? "accept" : "decline")
            ])
            return try await answer(request, context: context, result: result,
                                    client: client, gate: gate)
        case .answerQuestion(let request, let context, let answers):
            let result = try Self.questionAnswerResult(answers)
            return try await answer(request, context: context, result: result,
                                    client: client, gate: gate)
        case .requestCancellation(let context):
            return try await cancel(context, client: client, gate: gate)
        }
    }

    // MARK: Private

    /// The registry wrapper already folds the control-authority check into
    /// `beforeDispatch`; this gate adds the live ownership fence so every
    /// physical byte revalidates both.
    private func preflightGate(
        _ beforeDispatch: @escaping @Sendable () throws -> Void
    ) -> @Sendable () throws -> Void {
        let ownership = self.ownership
        return {
            try beforeDispatch()
            try ownership.validate()
        }
    }

    private func connectionClosed() async {
        guard phase == .ready else { return }
        await stop(deadline: .now.advanced(by: .seconds(2)))
    }

    private func pump() async {
        guard let client else { return }
        for await event in client.events {
            await handle(event)
            if phase == .tornDown { return }
        }
        guard phase != .tornDown else { return }
        await stop(deadline: .now.advanced(by: .seconds(2)))
    }

    private func handle(_ event: CodexAppServerClient.Event) async {
        guard phase == .ready, let client else { return }
        switch event {
        case .disconnected:
            await stop(deadline: .now.advanced(by: .seconds(2)))
        case .notification(let method, let params):
            do {
                guard var mapper = mapper else { return }
                let message = CodexAppServerMessage.notification(method: method, params: params)
                let effect = try mapper.map(message, connection: mapper.connectionID)
                self.mapper = mapper
                try await apply(effect, client: client)
            } catch {
                await stop(deadline: .now.advanced(by: .seconds(2)))
            }
        case .request(let identifier, let method, let params):
            do {
                guard var mapper = mapper else { return }
                let message = CodexAppServerMessage.request(identifier, method: method, params: params)
                let effect = try mapper.map(message, connection: mapper.connectionID)
                self.mapper = mapper
                switch effect {
                case .unsupportedRequest(let requestID):
                    _ = try? await client.reject(requestID)
                default:
                    try await apply(effect, client: client)
                }
            } catch {
                await stop(deadline: .now.advanced(by: .seconds(2)))
            }
        }
    }

    private func apply(_ effect: CodexAppServerTaskMapper.Effect, client: CodexAppServerClient) async throws {
        guard phase == .ready else { return }
        switch effect {
        case .candidate(let candidate):
            await settleTurn(for: candidate)
            try await ingest(candidate)
            if isTerminalLifecycle(candidate) {
                // A failed or cancelled turn ends this run: the journal
                // cannot start another turn after that terminal phase.
                await stop(deadline: .now.advanced(by: .seconds(2)))
            }
        case .attention(let candidate, let requestID, let method, let params):
            register(requestID, method: method, candidate: candidate, params: params)
            try await ingest(candidate)
        case .requestResolved(let candidate, let requestID):
            actionable.removeValue(forKey: requestID)
            try await ingest(candidate)
            try? await client.resolveServerRequest(requestID)
        case .parentSettlementUnknown:
            await settleActiveTurn()
        case .lateCompletionAfterCancellation:
            // A race outcome, never Ready: the turn ended some other way
            // after cancellation was requested.
            await settleActiveTurn()
            await stop(deadline: .now.advanced(by: .seconds(2)))
        case .bufferedUntilTurnBinding, .ignored, .unsupportedRequest:
            break
        case .needsReconciliation:
            // Authoritative state cannot be re-established on this channel.
            // A new process is a new explicit attempt, never auto-recovery.
            await stop(deadline: .now.advanced(by: .seconds(2)))
        }
    }

    private func isTerminalLifecycle(_ candidate: AdapterCandidate) -> Bool {
        guard case .lifecycle(let event) = candidate.event else { return false }
        return [.failed, .cancelled].contains(event.phase)
    }

    private func register(
        _ requestID: CodexAppServerRequestID,
        method: String,
        candidate: AdapterCandidate,
        params: AgentEventJSON
    ) {
        switch candidate.event {
        case let .question(attention), let .approval(attention):
            actionable[requestID] = ActionableRequest(
                method: method,
                request: attention.request,
                context: attention.context,
                params: params
            )
        default:
            return
        }
    }

    private func ingest(_ candidate: AdapterCandidate) async throws {
        let outcome = try await sink.ingest(candidate)
        guard outcome != .revoked else {
            await stop(deadline: .now.advanced(by: .seconds(2)))
            throw CodexAppServerClientError.unavailable
        }
    }

    /// A terminal turn lifecycle settles the observed response before the
    /// registry ingests the event, so the journal reaches
    /// parentSettlementUnknown first and the terminal phase applies cleanly.
    private func settleTurn(for candidate: AdapterCandidate) async {
        guard isTerminalLifecycle(candidate) else { return }
        await settleActiveTurn()
    }

    private func settleActiveTurn() async {
        guard let receipt = activeSubmission else { return }
        let operationID = await registry.task(for: ownership.policy.taskID)?.nativeDispatch?.operationID
        try? await registry.recordNativeTransition(
            .submissionResponseObserved(receipt, operationID: operationID),
            ownership: ownership
        )
        activeSubmission = nil
        activeTurnValue = nil
    }

    private func submit(
        _ text: String,
        client: CodexAppServerClient,
        gate: @escaping @Sendable () throws -> Void
    ) async throws -> AgentAdapterControlDispatch {
        guard !text.isEmpty, text.utf8.count <= 16_384 else {
            throw AgentAdapterControlError.unsupported
        }
        guard let threadValue else { throw CodexAppServerClientError.unavailable }
        // One mapper instance per logical turn: the base mapper retains a
        // completed turn's binding, so the next turn needs a fresh one.
        // Install it before the RPC: while the request is in flight the pump
        // buffers pre-binding traffic (turn/started, early questions, fast
        // completions) into this instance; the correlated response replays it.
        let mapper = try CodexAppServerTaskMapper(connectionID: UUID(), threadID: threadValue)
        try mapper.prepareTurn()
        self.mapper = mapper
        let taskID = ownership.policy.taskID
        let previous = await registry.task(for: taskID)?.nativeDispatch?.submissions.last?.id
        let submissionID = try await registry.prepareNativeSubmission(afterResponseTo: previous, ownership: ownership)
        let receipt = try ownership.claimSubmission(submissionID)
        activeSubmission = receipt
        let params: AgentEventJSON = .object([
            "threadId": .string(threadValue),
            "input": .array([.object([
                "type": .string("text"),
                "text": .string(text)
            ])])
        ])
        let rpcDeadline = min(sessionDeadline, ContinuousClock.now.advanced(by: .seconds(30)))
        do {
            let response = try await registry.performNativeEffect(.submission(receipt), ownership: ownership) {
                try runBoundedRPC(deadline: rpcDeadline) {
                    try await client.call(method: "turn/start", params: params, beforeDispatch: gate)
                }
            }
            guard case .object(let fields) = response,
                  case .object(let turn) = fields["turn"],
                  case .string(let turnID) = turn["id"] else {
                throw CodexAppServerTaskError.unavailable
            }
            // Bind against the installed copy: the pump may have buffered
            // pre-binding traffic into it while the RPC was in flight, and
            // bindTurnResponse replays exactly that buffer.
            var current = self.mapper
            let effects = try current.bindTurnResponse(turnID)
            self.mapper = current
            activeTurnValue = turnID
            turnStarted.set()
            let transition: AgentTaskNativeTransition = previous == nil
                ? .initialInputAcknowledged(operationID: turnID)
                : .submissionAcknowledged(receipt, operationID: turnID)
            try await registry.recordNativeTransition(transition, ownership: ownership)
            for effect in effects {
                try await apply(effect, client: client)
            }
            return .acknowledged
        } catch {
            // A racing turn completion may have settled the journal: success.
            // The .submissionUnknown record below is a no-op on the
            // write-failure path (the ownership is already revoked and
            // stop() -> .unavailable is the durable state); it only fires for
            // task cancellation before the effect.
            let checkpoint = await registry.task(for: taskID)?.nativeDispatch
            let settled = checkpoint?.submissions.last.map {
                $0.id == submissionID && $0.phase == .responseObserved
            } ?? false
            guard !settled else {
                return .acknowledged
            }
            try? await registry.recordNativeTransition(.submissionUnknown(submissionID: submissionID), ownership: ownership)
            await stop(deadline: .now.advanced(by: .seconds(2)))
            throw error
        }
    }

    private func answer(
        _ request: VendorReference,
        context: VendorReference,
        result: AgentEventJSON,
        client: CodexAppServerClient,
        gate: @escaping @Sendable () throws -> Void
    ) async throws -> AgentAdapterControlDispatch {
        guard let entry = actionableEntry(request: request, context: context) else {
            // Resolved, cancelled, stale, or foreign: never answerable.
            throw AgentAdapterControlError.unsupported
        }
        if entry.method != "item/tool/requestUserInput" {
            guard CodexAppServerApprovalPolicy.allowsOneShot(
                method: entry.method,
                payload: entry.params,
                workingDirectory: workingDirectory
            ) else {
                throw CodexAppServerTaskError.unsupportedApproval
            }
        }
        // One-shot from this point: duplicate user input cannot double-answer.
        actionable.removeValue(forKey: entry.id)
        let rpcDeadline = min(sessionDeadline, ContinuousClock.now.advanced(by: .seconds(30)))
        try await registry.performNativeEffect(.decision, ownership: ownership) {
            try runBoundedRPC(deadline: rpcDeadline) {
                try await client.answer(entry.id, result: result,
                                         replayAuthority: replayFence, beforeResponse: gate)
            }
        }
        return .acknowledged
    }

    private func actionableEntry(
        request: VendorReference,
        context: VendorReference
    ) -> (id: CodexAppServerRequestID, method: String, params: AgentEventJSON)? {
        for (id, entry) in actionable where entry.request == request && entry.context == context {
            return (id, entry.method, entry.params)
        }
        return nil
    }

    private static func questionAnswerResult(
        _ answers: [String: [String]]
    ) throws -> AgentEventJSON {
        guard !answers.isEmpty, answers.count <= 8 else {
            throw AgentAdapterControlError.unsupported
        }
        var fields: [String: AgentEventJSON] = [:]
        for (questionID, values) in answers {
            guard !questionID.isEmpty, questionID.utf8.count <= 256,
                  !values.isEmpty, values.count <= 16,
                  values.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 8_192 }) else {
                throw AgentAdapterControlError.unsupported
            }
            fields[questionID] = .object(["answers": .array(values.map { .string($0) })])
        }
        return .object(["answers": .object(fields)])
    }

    private func cancel(
        _ context: VendorReference,
        client: CodexAppServerClient,
        gate: @escaping @Sendable () throws -> Void
    ) async throws -> AgentAdapterControlDispatch {
        guard let threadValue, let activeTurnValue, var mapper = mapper else {
            throw CodexAppServerClientError.unavailable
        }
        let activeTurn = try VendorReference(role: .turn, value: activeTurnValue)
        guard context == activeTurn else { throw AgentAdapterControlError.unsupported }
        let taskID = ownership.policy.taskID
        // Cancellation is a one-time intent per turn; it stays requested
        // until the provider confirms it.
        guard await registry.task(for: taskID)?.nativeDispatch?.cancellationRequested != true else {
            throw AgentAdapterControlError.unsupported
        }
        try mapper.requestCancellation()
        // Persist the intent before the write: it fences responses and
        // authorizes the physical interruption.
        try await registry.recordNativeTransition(.cancellationRequested, ownership: ownership)
        self.mapper = mapper
        // Cancelled requests leave the Needs decision and cannot be answered.
        actionable.removeAll()
        let rpcDeadline = min(sessionDeadline, ContinuousClock.now.advanced(by: .seconds(30)))
        do {
            try await registry.performNativeEffect(.cancellation, ownership: ownership) {
                try runBoundedRPC(deadline: rpcDeadline) {
                    try await client.call(
                        method: "turn/interrupt",
                        params: .object([
                            "threadId": .string(threadValue),
                            "turnId": .string(activeTurnValue)
                        ]),
                        beforeDispatch: gate
                    )
                }
            }
            return .acknowledged
        } catch {
            // Requested but the write outcome is uncertain. The registry
            // already retired the ownership; the turn's fate arrives only
            // through wire events or teardown. Never presented as cancelled.
            await stop(deadline: .now.advanced(by: .seconds(2)))
            throw error
        }
    }
}

// MARK: - Factory

/// One-shot factory for one registry-prepared owned-stdio Codex task
/// (#1723).
///
/// It mints at most one session; the session consumes the registry-owned
/// admission state. The probe reports capability evidence for the
/// already-pinned executable; it never searches PATH and never proves
/// account authentication.
nonisolated final class CodexAppServerNativeFactory: AgentAdapterFactory, @unchecked Sendable {
    static let contractVersion = PineAdapterContractVersion(major: 1, minor: 1)

    nonisolated let id: AdapterFactoryID
    /// The exact profile this factory offers; the registry descriptor must
    /// grant at least this much.
    let maximumProfile: AdapterCapabilityProfile
    private let materials: CodexAppServerNativeMaterials
    private let consumed = Mutex(false)

    init(materials: CodexAppServerNativeMaterials, factoryID: AdapterFactoryID) throws {
        self.materials = materials
        self.id = factoryID
        let signals: Set<AdapterLifecycleCapabilities.Signal> = [
            .init(scope: .turn, phase: .started),
            .init(scope: .turn, phase: .waitingForQuestion),
            .init(scope: .turn, phase: .waitingForApproval),
            .init(scope: .turn, phase: .failed),
            .init(scope: .turn, phase: .cancelled)
        ]
        maximumProfile = try AdapterCapabilityProfile(
            transport: .ownedStandardIO,
            lifecycle: AdapterLifecycleCapabilities(signals: signals, evidence: []),
            delivery: AdapterDeliverySemantics(
                replay: .none, ordering: .unordered, minimumAuthentication: .ownedChildPipe
            )
        )
    }

    func probe() async throws -> AdapterProbeResult {
        try AdapterProbeResult(
            detectedVendorVersion: DetectedVendorVersion(
                CodexAppServerExecutableIdentity.supportedVersion
            ),
            detectedSchema: nil,
            offeredProfiles: [maximumProfile],
            offeredContractVersions: PineAdapterContractVersionRange(
                minimum: Self.contractVersion, maximum: Self.contractVersion
            )
        )
    }

    func makeSession(_ request: AgentAdapterSessionRequest) async throws -> any AgentAdapterSession {
        guard request.resumeFrom == nil else { throw AdapterSessionError.checkpointNotSupported }
        guard consumed.withLock({ value -> Bool in
            guard !value else { return false }
            value = true
            return true
        }) else {
            throw AdapterSessionError.contractAlreadyConsumed
        }
        return CodexAppServerNativeSession(materials: materials, request: request)
    }
}

// MARK: - Bounded RPC

/// Runs one bounded asynchronous client RPC from the registry's synchronous
/// effect action. That action executes on an off-main global-queue thread, so
/// blocking it is safe; the detached task carries the actor hops. A timeout
/// cancels the RPC and fails closed — an entered write is never retried.
nonisolated private func runBoundedRPC<T: Sendable>(
    deadline: ContinuousClock.Instant,
    _ operation: @escaping @Sendable () async throws -> T
) throws -> T {
    guard ContinuousClock.now < deadline else { throw CodexAppServerClientError.unavailable }
    final class Outcome: @unchecked Sendable {
        private let lock = NSLock()
        private var settled = false
        private var success: T?
        private var failure: (any Error)?
        private let semaphore = DispatchSemaphore(value: 0)
        func settle(success value: T) {
            lock.lock(); defer { lock.unlock() }
            guard !settled else { return }
            settled = true
            success = value
            semaphore.signal()
        }
        func settle(failure error: any Error) {
            lock.lock(); defer { lock.unlock() }
            guard !settled else { return }
            settled = true
            failure = error
            semaphore.signal()
        }
        func wait(until deadline: DispatchTime) -> Bool {
            semaphore.wait(timeout: deadline) == .success
        }
        var success: T? { lock.lock(); defer { lock.unlock() }; return success }
        var failure: (any Error)? { lock.lock(); defer { lock.unlock() }; return failure }
    }
    let outcome = Outcome<T>()
    let task = Task.detached {
        do { outcome.settle(success: try await operation()) }
        catch { outcome.settle(failure: error) }
    }
    // The RPC's own deadlines are bounded by `deadline`; the five-second
    // slack only covers settling after that bound.
    let timeout = ContinuousClock.now.duration(to: deadline).components
    let slack = max(timeout.seconds + 5, 1)
    guard outcome.wait(until: DispatchTime.now() + .seconds(slack)) else {
        task.cancel()
        throw CodexAppServerClientError.unavailable
    }
    task.cancel()
    if let failure = outcome.failure { throw failure }
    guard let success = outcome.success else { throw CodexAppServerClientError.unavailable }
    return success
}
