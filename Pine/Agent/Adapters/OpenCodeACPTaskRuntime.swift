import Foundation
import Observation

/// A live projection/control handle for ONE existing durable task attempt.
/// The shared task/session owner retains this across windows; this is neither a
/// task store nor an execution grant, and constructing it starts nothing.
@MainActor
@Observable
final class OpenCodeACPTaskRuntime: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    nonisolated var description: String { "<redacted:opencode-task-runtime>" }
    nonisolated var debugDescription: String { description }
    nonisolated var customMirror: Mirror { Mirror(self, children: ["value": description]) }
    let taskID: UUID
    let runID: UUID
    let bindingID: UUID
    let source: ValidatedAgentSourceIdentity
    private(set) var snapshot: OpenCodeACPSession.Snapshot?
    private(set) var lastDispatch: AgentAdapterControlDispatch?
    private(set) var isDispatching = false
    /// The session's read-only discovery observation, available once the
    /// session has started. Drives the contextual "How to run" surface.
    private(set) var discoveryReport: AgentTaskDiscoveryReport?

    @ObservationIgnored private let owner: any AgentAdapterSession
    @ObservationIgnored private let provider: OpenCodeACPSession
    @ObservationIgnored private let controls: any AgentAdapterControlledSession
    /// Reads current IDs/availability from the existing durable task registry.
    /// It must not perform filesystem work or create/recover a task.
    @ObservationIgnored private let taskIsCurrent: @MainActor () -> Bool
    /// Shared native owner revalidates task/run/source/binding/grant on EVERY
    /// physical write, including deferred writes. No I/O on the main actor.
    @ObservationIgnored private let prepareControl: @MainActor (AgentAdapterControl) async throws -> Void
    @ObservationIgnored private let beforeDispatch: @Sendable (AgentAdapterControl) throws -> Void
    private var started = false
    private var active = false
    private var stopped = false

    init(taskID: UUID, runID: UUID, bindingID: UUID,
         registry: AgentAdapterRegistry, owner: any AgentAdapterSession, provider: OpenCodeACPSession,
         taskIsCurrent: @escaping @MainActor () -> Bool,
         prepareControl: @escaping @MainActor (AgentAdapterControl) async throws -> Void,
         beforeDispatch: @escaping @Sendable (AgentAdapterControl) throws -> Void) throws {
        guard owner.contract == provider.contract else { throw AdapterSessionError.contractMismatch }
        self.taskID = taskID
        self.runID = runID
        self.bindingID = bindingID
        source = try registry.sourceIdentity(for: owner)
        controls = try registry.controls(for: owner)
        self.owner = owner
        self.provider = provider
        self.taskIsCurrent = taskIsCurrent
        self.beforeDispatch = beforeDispatch
        self.prepareControl = prepareControl
    }

    /// The provider session's state outlives this handle: a runtime whose
    /// provider already stopped (failed start or explicit stop) is dead and
    /// must not be returned to a replacement ownership.
    func isProviderStopped() async -> Bool { await provider.isStopped }

    var isCurrent: Bool { !stopped && taskIsCurrent() }
    var isActive: Bool {
        guard active, isCurrent, let state = snapshot?.state else { return false }
        return ![.unknown, .blocked, .stopped].contains(state)
    }

    /// Explicit launch/attachment after task admission, not a window onAppear.
    func start() async throws {
        guard !started, isCurrent else { throw OpenCodeACPError.invalidState }
        started = true
        try await provider.observe { [weak self] snapshot in
            await self?.receive(snapshot)
        }
        try await owner.start()
        guard isCurrent else {
            await stop(deadline: .now.advanced(by: .seconds(2)))
            throw OpenCodeACPError.unavailable
        }
        discoveryReport = await provider.discoveryReport
        active = true
    }

    /// Both the first request and explicit feedback use the same owner/session.
    @discardableResult
    func submit(_ instruction: String) async throws -> AgentAdapterControlDispatch {
        try await dispatch(.submitInstruction(instruction))
    }

    @discardableResult
    func answerQuestion(_ question: OpenCodeACPSession.Question,
                        answers: [String: [String]]) async throws -> AgentAdapterControlDispatch {
        try await dispatch(.answerQuestion(request: question.request, context: question.context, answers: answers))
    }

    @discardableResult
    func answerPermission(_ question: OpenCodeACPSession.Question,
                          optionID: String,
                          decision: AgentAdapterControl.Permission) async throws -> AgentAdapterControlDispatch {
        guard let current = snapshot?.questions.first(where: { $0.id == question.id }),
              current.request == question.request, current.context == question.context else {
            throw OpenCodeACPError.invalidAnswer
        }
        let expected = switch decision {
        case .allowOnce: current.allowOnceOptionID
        case .deny: current.denyOptionID
        }
        guard expected?.utf8.elementsEqual(optionID.utf8) == true else { throw OpenCodeACPError.invalidAnswer }
        return try await dispatch(.answerPermission(request: current.request, context: current.context, decision: decision))
    }

    @discardableResult
    func cancel() async throws -> AgentAdapterControlDispatch {
        // Unsupported input already fenced the pipe. Explicit Cancel still
        // cleans up its owner, but cannot fabricate a native "cancelled" reply.
        if isCurrent, snapshot?.state == .blocked {
            await owner.stop(deadline: .now.advanced(by: .seconds(2)))
            lastDispatch = .acknowledged
            return .acknowledged
        }
        guard let context = snapshot?.context else { throw OpenCodeACPError.invalidState }
        return try await dispatch(.requestCancellation(context: context))
    }

    private func dispatch(_ control: AgentAdapterControl) async throws -> AgentAdapterControlDispatch {
        guard isActive, !isDispatching else { throw OpenCodeACPError.unavailable }
        isDispatching = true
        defer { isDispatching = false }
        try await prepareControl(control)
        guard isActive else { throw OpenCodeACPError.unavailable }
        let controls = self.controls
        let gate = beforeDispatch
        // The common wrapper also calls its gate before entering the provider
        // actor; even that preflight must not move filesystem work onto UI.
        let operation = Task.detached {
            try await controls.dispatch(control, beforeDispatch: {
                try autoreleasepool { try gate(control) }
            })
        }
        let result = try await withTaskCancellationHandler {
            try await operation.value
        } onCancel: { operation.cancel() }
        guard isCurrent else {
            lastDispatch = .uncertain
            return .uncertain
        }
        lastDispatch = result
        return result
    }

    private func receive(_ snapshot: OpenCodeACPSession.Snapshot) {
        guard isCurrent else { self.snapshot = nil; return }
        self.snapshot = snapshot
    }

    /// Task/application owner cleanup only; closing a window must not call it.
    func stop(deadline: ContinuousClock.Instant) async {
        stopped = true
        active = false
        snapshot = nil
        discoveryReport = nil
        await owner.stop(deadline: deadline)
    }
}
