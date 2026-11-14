import Foundation
import Synchronization

/// Transport seam; the task registry additionally requires the concrete
/// native-bridge receipt before installing native process ownership.
nonisolated protocol CodexAppServerProcessEvidence: Sendable {
    var identity: UserTaskProcessIdentity { get }
    func revalidate() async -> Bool
}

/// A previously written answer is replayable only while its exact owner still
/// exists and its source/request/run/binding/account gates remain current.
/// Validation grants nothing new and must not consume another user response.
nonisolated protocol CodexAppServerResponseReplayAuthority: AnyObject, Sendable {
    func validateReplay() throws
}

/// Synchronous, irreversible liveness fence. Buffered events are historical
/// data after loss; consumers must validate this fence before applying them.
/// This is not registry activation, an account proof, or an execution grant.
nonisolated private final class CodexAppServerTransportAuthority: Sendable {
    private struct Ready: Sendable {
        let channel: CodexAppServerStdioChannel
        let deadline: ContinuousClock.Instant
    }
    private enum Phase: Sendable { case fresh, ready(Ready), closed }
    private let phase = Mutex(Phase.fresh)
    func activate(channel: CodexAppServerStdioChannel, deadline: ContinuousClock.Instant) throws {
        try channel.validateOpen()
        try phase.withLock {
            guard case .fresh = $0 else { throw CodexAppServerClientError.unavailable }
            $0 = .ready(Ready(channel: channel, deadline: deadline))
        }
    }
    func close() {
        let channel = phase.withLock { value -> CodexAppServerStdioChannel? in
            let channel: CodexAppServerStdioChannel?
            if case .ready(let ready) = value { channel = ready.channel } else { channel = nil }
            value = .closed
            return channel
        }
        channel?.close()
    }
    func validate() throws {
        let ready = try phase.withLock { value in
            guard case .ready(let ready) = value else { throw CodexAppServerClientError.unavailable }
            return ready
        }
        do {
            guard ContinuousClock.now < ready.deadline else { throw CodexAppServerClientError.unavailable }
            try ready.channel.validateOpen()
        } catch {
            close()
            throw CodexAppServerClientError.unavailable
        }
        try phase.withLock { guard case .ready = $0 else { throw CodexAppServerClientError.unavailable } }
    }
}

nonisolated private final class CodexAppServerReplayPermission: Sendable {
    private struct Owner: Sendable { weak var value: (any CodexAppServerResponseReplayAuthority)? }
    private enum Kind: Sendable { case approval(Owner), nonAuthorizingError }
    private let kind: Kind
    private let active = Mutex(true)
    init(approval owner: any CodexAppServerResponseReplayAuthority) { kind = .approval(Owner(value: owner)) }
    init() { kind = .nonAuthorizingError }
    func invalidate() { active.withLock { $0 = false } }
    func validate() throws {
        try active.withLock { guard $0 else { throw CodexAppServerWireError.closed } }
        if case .approval(let owner) = kind {
            guard let authority = owner.value else { throw CodexAppServerWireError.closed }
            try authority.validateReplay()
        }
        try active.withLock { guard $0 else { throw CodexAppServerWireError.closed } }
    }
}

/// A launch factory supplies exactly one verified owned child. Neither this
/// handle nor successful initialization proves provider account authentication.
nonisolated struct CodexAppServerOwnedChild: Sendable {
    let channel: CodexAppServerStdioChannel
    let processIdentity: UserTaskProcessIdentity?
    let processReceipt: (any CodexAppServerProcessEvidence)?
    let stop: @Sendable (ContinuousClock.Instant) async -> Void

    init(channel: CodexAppServerStdioChannel, processIdentity: UserTaskProcessIdentity? = nil,
         processReceipt: (any CodexAppServerProcessEvidence)? = nil,
         stop: @escaping @Sendable (ContinuousClock.Instant) async -> Void) {
        self.channel = channel
        self.processIdentity = processIdentity
        self.processReceipt = processReceipt
        self.stop = stop
    }
}

nonisolated enum CodexAppServerClientError: Error, Equatable {
    case providerFailure(Int64)
    case unavailable
    case accountChanged
}

/// Owned-stdio RPC supervision, injected at the process-launch boundary. Task
/// creation/binding and the registry-owned adapter session remain its caller's
/// responsibilities. Events are untrusted wire data until mapped and ingested.
actor CodexAppServerClient {
    enum Event: Sendable {
        case notification(method: String, params: AgentEventJSON)
        case request(CodexAppServerRequestID, method: String, params: AgentEventJSON)
        case disconnected
    }
    private enum State { case fresh, starting, ready, stopped }
    private struct Reply {
        let token: UUID
        let continuation: CheckedContinuation<AgentEventJSON, any Error>
        var timeout: Task<Void, Never>?
    }

    nonisolated let events: AsyncStream<Event>
    nonisolated private let transportAuthority = CodexAppServerTransportAuthority()
    private let eventContinuation: AsyncStream<Event>.Continuation
    private let launch: @Sendable (ContinuousClock.Instant) async throws -> CodexAppServerOwnedChild
    private let sessionDeadline: ContinuousClock.Instant
    private let experimentalAPI: Bool
    private let accountChanged: @Sendable () -> Bool
    private let onConnectionClosed: @Sendable () -> Void
    private var state: State = .fresh
    private var connection = CodexAppServerConnection()
    private var launchGate: CodexAppServerLaunchGate?
    private var child: CodexAppServerOwnedChild?
    private var writer: CodexAppServerOutbound?
    private var replies: [CodexAppServerRequestID: Reply] = [:]
    // Bounded by the connection's 64 preparing/confirmed-response entries. Weak owners
    // prevent a cached answer from retaining a retired request or task owner.
    private var replayPermissions: [CodexAppServerRequestID: CodexAppServerReplayPermission] = [:]
    private var readTask: Task<Void, Never>?
    private var errorTask: Task<Void, Never>?

    /// Every consumer must check immediately before effects and treat stream
    /// EOF as loss. A disconnected event is only a best-effort wakeup: a full
    /// bounded queue can drop it. This check never hops onto the client actor.
    nonisolated func validateConnection() throws { try transportAuthority.validate() }

    init(
        sessionDeadline: ContinuousClock.Instant,
        experimentalAPI: Bool = false,
        accountChanged: @escaping @Sendable () -> Bool = { false },
        onConnectionClosed: @escaping @Sendable () -> Void = {},
        launch: @escaping @Sendable (ContinuousClock.Instant) async throws -> CodexAppServerOwnedChild
    ) {
        self.launch = launch
        self.sessionDeadline = sessionDeadline
        self.experimentalAPI = experimentalAPI
        self.accountChanged = accountChanged
        self.onConnectionClosed = onConnectionClosed
        let stream = AsyncStream<Event>.makeStream(bufferingPolicy: .bufferingOldest(32))
        events = stream.stream
        eventContinuation = stream.continuation
    }

    func start() async throws {
        guard state == .fresh else { throw CodexAppServerWireError.invalidState }
        guard ContinuousClock.now < sessionDeadline else { throw CodexAppServerWireError.closed }
        state = .starting
        let deadline = min(sessionDeadline, .now.advanced(by: .seconds(5)))
        let gate = CodexAppServerLaunchGate()
        launchGate = gate
        let launch = self.launch
        Task.detached {
            do {
                let launched = try await launch(deadline)
                if !(await gate.resolve(.success(launched))) {
                    launched.channel.close()
                    await launched.stop(.now.advanced(by: .seconds(2)))
                }
            } catch { _ = await gate.resolve(.failure(error)) }
        }
        let timeout = Task.detached {
            do {
                try await Task.sleep(until: deadline, clock: .continuous)
                await gate.cancel()
            } catch { /* The launch or caller already settled startup. */ }
        }
        defer { timeout.cancel() }
        do {
            let launched = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await gate.value()
            } onCancel: {
                Task { await gate.cancel() }
            }
            guard state == .starting, !Task.isCancelled else {
                launched.channel.close()
                await Task.detached { await launched.stop(.now.advanced(by: .seconds(2))) }.value
                throw CancellationError()
            }
            child = launched
            try launched.channel.installCloseObserver(onConnectionClosed)
            let writer = CodexAppServerOutbound(channel: launched.channel)
            self.writer = writer
            let sessionDeadline = self.sessionDeadline
            errorTask = Task {
                do {
                    try await launched.channel.drainStandardError(until: sessionDeadline)
                } catch {
                    await self.stop(deadline: .now.advanced(by: .seconds(2)))
                }
            }
            var initialize: Data?
            try connection.initialize(experimentalAPI: experimentalAPI) { initialize = $0 }
            guard let initialize else { throw CodexAppServerWireError.invalidState }
            try await writer.send(initialize, deadline: deadline)
            guard let response = try await launched.channel.readNext(deadline: deadline) else {
                throw CodexAppServerWireError.closed
            }
            var acknowledgement: Data?
            let delivery = try connection.receive(response, connection: connection.identity) { acknowledgement = $0 }
            guard delivery == .initialized, let acknowledgement else { throw CodexAppServerWireError.invalidEnvelope }
            try await writer.send(acknowledgement, deadline: deadline)
            guard state == .starting, !Task.isCancelled else { throw CancellationError() }
            try transportAuthority.activate(channel: launched.channel, deadline: sessionDeadline)
            state = .ready
            readTask = Task { await readLoop(channel: launched.channel) }
        } catch {
            await stop(deadline: .now.advanced(by: .seconds(2)))
            throw error
        }
    }

    func runtimeProcessIdentity() -> UserTaskProcessIdentity? {
        guard state == .ready, (try? validateConnection()) != nil else { return nil }
        return child?.processIdentity
    }

    func runtimeProcessReceipt() -> (any CodexAppServerProcessEvidence)? {
        guard state == .ready, (try? validateConnection()) != nil else { return nil }
        return child?.processReceipt
    }

    func call(method: String, params: AgentEventJSON,
              beforeDispatch: @escaping @Sendable () throws -> Void = {}) async throws -> AgentEventJSON {
        guard state == .ready, let writer else { throw CodexAppServerClientError.unavailable }
        try validateConnection()
        let transport = transportAuthority
        guard replies.count < CodexAppServerConnection.maximumPendingRequests else {
            await stop(deadline: .now.advanced(by: .seconds(2)))
            throw CodexAppServerWireError.capacityExceeded
        }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                do {
                    var bytes: Data?
                    let identifier = try connection.request(method: method, params: params) { bytes = $0 }
                    guard let bytes else { throw CodexAppServerWireError.invalidState }
                    let deadline = min(sessionDeadline, .now.advanced(by: .seconds(30)))
                    let token = UUID()
                    replies[identifier] = Reply(token: token, continuation: continuation)
                    let timeout = Task {
                        do {
                            try await Task.sleep(until: deadline, clock: .continuous)
                            await self.expireReply(identifier, token: token)
                        } catch { /* A settled reply cancels its own watchdog. */ }
                    }
                    replies[identifier]?.timeout = timeout
                    Task {
                        do {
                            try await writer.send(bytes, deadline: deadline, beforeWrite: {
                                try transport.validate()
                                try beforeDispatch()
                                try transport.validate()
                            })
                        } catch {
                            await self.stop(deadline: .now.advanced(by: .seconds(2)))
                        }
                    }
                } catch {
                    child?.channel.close()
                    continuation.resume(throwing: error)
                    Task { await self.stop(deadline: .now.advanced(by: .seconds(2))) }
                }
            }
        } onCancel: {
            transport.close()
            Task { await self.stop(deadline: .now.advanced(by: .seconds(2))) }
        }
    }

    /// The adapter owner must check mapper.isActionable and current task,
    /// attempt, binding and grant immediately before invoking this method.
    func answer(_ identifier: CodexAppServerRequestID, result: AgentEventJSON,
                replayAuthority: any CodexAppServerResponseReplayAuthority,
                beforeResponse: @escaping @Sendable () throws -> Void) async throws {
        guard state == .ready, let writer else { throw CodexAppServerClientError.unavailable }
        try validateConnection()
        let transport = transportAuthority
        let prepared = try connection.prepareAnswer(identifier, result: result)
        let permission = CodexAppServerReplayPermission(approval: replayAuthority)
        replayPermissions[identifier] = permission
        do {
            try await writer.send(prepared.bytes, deadline: min(sessionDeadline, .now.advanced(by: .seconds(30))),
                                  beforeWrite: {
                                      try transport.validate()
                                      try permission.validate()
                                      try beforeResponse()
                                      try permission.validate()
                                      try transport.validate()
                                  })
            try connection.confirmResponseWritten(prepared)
        } catch {
            await stop(deadline: .now.advanced(by: .seconds(2)))
            throw error
        }
    }

    func reject(_ identifier: CodexAppServerRequestID) async throws {
        guard state == .ready, let writer else { throw CodexAppServerClientError.unavailable }
        try validateConnection()
        let transport = transportAuthority
        let prepared = try connection.prepareRejection(identifier)
        let permission = CodexAppServerReplayPermission()
        replayPermissions[identifier] = permission
        do {
            try await writer.send(prepared.bytes, deadline: min(sessionDeadline, .now.advanced(by: .seconds(30))),
                                  beforeWrite: { try transport.validate(); try permission.validate(); try transport.validate() })
            try connection.confirmResponseWritten(prepared)
        } catch {
            await stop(deadline: .now.advanced(by: .seconds(2)))
            throw error
        }
    }

    /// Invoke only for a requestResolved effect validated by the owning mapper,
    /// never directly from an unscoped raw server notification.
    func resolveServerRequest(_ identifier: CodexAppServerRequestID) async throws {
        do {
            replayPermissions.removeValue(forKey: identifier)?.invalidate()
            try connection.resolveServerRequest(identifier)
        } catch {
            await stop(deadline: .now.advanced(by: .seconds(2)))
            throw error
        }
    }

    func stop(deadline: ContinuousClock.Instant) async {
        guard state != .stopped else { return }
        state = .stopped
        onConnectionClosed()
        transportAuthority.close()
        connection.close()
        child?.channel.close()
        replayPermissions.values.forEach { $0.invalidate() }
        replayPermissions.removeAll()
        await launchGate?.cancel()
        launchGate = nil
        readTask?.cancel()
        errorTask?.cancel()
        readTask = nil
        errorTask = nil
        let pending = replies
        replies.removeAll()
        for reply in pending.values {
            reply.timeout?.cancel()
            reply.continuation.resume(throwing: CodexAppServerClientError.unavailable)
        }
        // This wakeup can be dropped by a full queue. The irreversible fence
        // above and mandatory consumer EOF cleanup carry terminal authority.
        _ = eventContinuation.yield(.disconnected)
        eventContinuation.finish()
        if let writer { await writer.close() }
        if let child { await Task.detached { await child.stop(deadline) }.value }
    }

    private func expireReply(_ identifier: CodexAppServerRequestID, token: UUID) async {
        guard replies[identifier]?.token == token else { return }
        await stop(deadline: .now.advanced(by: .seconds(2)))
    }

    private func readLoop(channel: CodexAppServerStdioChannel) async {
        do {
            while state == .ready, let message = try await channel.readNext(deadline: sessionDeadline) {
                guard state == .ready else { return }
                var replay: Data?
                let delivery = try connection.receive(message, connection: connection.identity) { replay = $0 }
                if let replay, let writer {
                    guard case .request(let identifier, _, _) = message,
                          let permission = replayPermissions[identifier] else { throw CodexAppServerWireError.closed }
                    let transport = transportAuthority
                    try await writer.send(replay, deadline: min(sessionDeadline, .now.advanced(by: .seconds(30))), beforeWrite: {
                        try transport.validate()
                        try permission.validate()
                        try transport.validate()
                    })
                }
                switch delivery {
                case .response(let identifier, _, let result):
                    guard let reply = replies.removeValue(forKey: identifier) else { throw CodexAppServerWireError.foreignResponse }
                    reply.timeout?.cancel()
                    reply.continuation.resume(returning: result)
                case .failure(let identifier, _, let code):
                    guard let reply = replies.removeValue(forKey: identifier) else { throw CodexAppServerWireError.foreignResponse }
                    reply.timeout?.cancel()
                    reply.continuation.resume(throwing: CodexAppServerClientError.providerFailure(code))
                case .serverRequest(let identifier, let method, let params):
                    let supported = ["item/commandExecution/requestApproval", "item/fileChange/requestApproval"].contains(method)
                        || (experimentalAPI && method == "item/tool/requestUserInput")
                    if supported {
                        try deliver(.request(identifier, method: method, params: params))
                    } else {
                        let rejection = try connection.prepareRejection(identifier)
                        guard let writer else { throw CodexAppServerWireError.closed }
                        let permission = CodexAppServerReplayPermission()
                        let transport = transportAuthority
                        replayPermissions[identifier] = permission
                        try await writer.send(rejection.bytes, deadline: min(sessionDeadline, .now.advanced(by: .seconds(30))),
                                              beforeWrite: { try transport.validate(); try permission.validate(); try transport.validate() })
                        try connection.confirmResponseWritten(rejection)
                    }
                case .notification(let method, let params):
                    if method == "account/updated" {
                        let stopForAccountChange = accountChanged()
                        try deliver(.notification(method: method, params: params))
                        if stopForAccountChange { throw CodexAppServerClientError.accountChanged }
                        continue
                    }
                    // Text/tool-output deltas are deliberately not queued or
                    // granted authority. These are the mapper's scoped inputs.
                    if ["turn/started", "turn/completed", "serverRequest/resolved"].contains(method) {
                        try deliver(.notification(method: method, params: params))
                    }
                case .duplicateRequest, .replayedResponse, .ignoredForeignConnection:
                    break
                case .initialized:
                    throw CodexAppServerWireError.invalidState
                }
            }
        } catch { /* Payloads and provider error text are never logged. */ }
        await stop(deadline: .now.advanced(by: .seconds(2)))
    }

    private func deliver(_ event: Event) throws {
        switch eventContinuation.yield(event) {
        case .enqueued: break
        case .dropped, .terminated: throw CodexAppServerWireError.capacityExceeded
        @unknown default: throw CodexAppServerWireError.closed
        }
    }
}

/// Single-use race between launch, cancellation, and the startup deadline.
/// A late successful launch is returned to its producer for owned cleanup;
/// cancelling a Swift task never silently abandons a child launched afterward.
private actor CodexAppServerLaunchGate {
    private var finished = false
    private var waited = false
    private var result: Result<CodexAppServerOwnedChild, any Error>?
    private var continuation: CheckedContinuation<CodexAppServerOwnedChild, any Error>?

    func value() async throws -> CodexAppServerOwnedChild {
        guard !waited else { throw CodexAppServerWireError.invalidState }
        waited = true
        if let result {
            self.result = nil
            return try result.get()
        }
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    @discardableResult
    func resolve(_ result: Result<CodexAppServerOwnedChild, any Error>) -> Bool {
        guard !finished else { return false }
        finished = true
        if let continuation {
            self.continuation = nil
            continuation.resume(with: result)
        } else {
            self.result = result
        }
        return true
    }

    func cancel() { resolve(.failure(CodexAppServerWireError.closed)) }
}
