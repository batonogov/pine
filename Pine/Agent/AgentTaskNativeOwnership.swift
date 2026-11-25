import CryptoKit
import Foundation
import Synchronization

nonisolated protocol AgentTaskNativeBindingValidator: Sendable {
    func revalidate(_ binding: AgentTaskEnvironmentBinding) async throws -> RecentAgentTaskFilesystemValidationLease
}

extension AgentTaskEnvironmentBindings: AgentTaskNativeBindingValidator {}

/// Runtime correlation only. Keep beside the actual provider request; never
/// reconstruct it from a UUID, wire event, journal or restored task.
nonisolated final class AgentTaskNativeSubmissionReceipt: Sendable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private struct Owner: Sendable { weak var value: AgentTaskNativeOwnership? }
    let submissionID: UUID
    private let owner: Owner
    fileprivate init(submissionID: UUID, owner: AgentTaskNativeOwnership) {
        self.submissionID = submissionID
        self.owner = Owner(value: owner)
    }
    fileprivate func belongs(to ownership: AgentTaskNativeOwnership) -> Bool { owner.value === ownership }
    var description: String { "<redacted:native-submission-receipt>" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["value": description]) }
}

/// Core-owned runtime join. Persisted IDs and provider metadata cannot construct
/// a source or process receipt. This object is never encoded or restored.
nonisolated final class AgentTaskNativeOwnership: Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable {
    enum Effect: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
        case launch(environment: [String: String])
        case submission(AgentTaskNativeSubmissionReceipt)
        case decision
        case cancellation
        var description: String { "<redacted:native-effect>" }
        var debugDescription: String { description }
        var customMirror: Mirror { Mirror(self, children: ["value": description]) }
    }
    private struct State: Sendable {
        var active = true
        var source: ValidatedAgentSourceIdentity?
        var process: AgentTaskOwnedProcessReceipt?
        var admitted = false
        var initialInput: InitialInput = .disabled
        var cancellationPending = false
        var cancellationDurable = false
        /// Once the cancellation persisted, terminal wire answers to owned
        /// requests stay permitted even after the submission is suspended.
        var cancellationWasDurable = false
        var submissionID: UUID?
        var submissionReceipt: AgentTaskNativeSubmissionReceipt?
        var isInitialSubmission = true
        var submissionFenced = false
    }
    private enum InitialInput: Equatable, Sendable { case disabled, intent, acknowledged, responded, unknown }
    nonisolated private final class EffectCancellation: Sendable {
        private let cancelled = Mutex(false)
        func cancel() { cancelled.withLock { $0 = true } }
        func check() throws {
            try cancelled.withLock { if $0 { throw CancellationError() } }
        }
    }
    let policy: AgentTaskNativeLaunchPolicy
    let binding: AgentTaskEnvironmentBinding
    let filesystem: RecentAgentTaskFilesystemValidationLease
    private let bindings: any AgentTaskNativeBindingValidator
    private let environmentDigest: Data
    private let state = Mutex(State())
    var description: String { "<redacted:native-ownership>" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["value": description]) }

    /// `explicitRestore` marks the ownership of an explicit exact-session
    /// restore (#1811): the composition is driven by the restoring caller,
    /// never by the auto-prepare notification, so none is posted.
    /// `restoreResponded` seeds the input state from the JOURNAL, not the
    /// process: when the journal proves the prior owner's last submission
    /// was responded to, this owner's first submission is a follow-up and
    /// `authorizeSubmission` requires `.responded`. A submission is only
    /// reachable in that state when the journal says the response was
    /// observed, so the seed is honest in every reachable case.
    init(
        policy: AgentTaskNativeLaunchPolicy, binding: AgentTaskEnvironmentBinding,
        filesystem: RecentAgentTaskFilesystemValidationLease, bindings: any AgentTaskNativeBindingValidator,
        environment: [String: String], explicitRestore: Bool = false,
        restoreResponded: Bool = false
    ) throws {
        guard policy.taskID == binding.taskID, policy.bindingID == binding.id,
              policy.runID == binding.reservationRunID else {
            throw AgentTaskNativeAdmissionError.invalidPolicy
        }
        self.policy = policy
        self.binding = binding
        self.filesystem = filesystem
        self.bindings = bindings
        environmentDigest = try Self.digest(environment)
        if explicitRestore, restoreResponded {
            state.withLock { $0.initialInput = .responded }
        }
        guard explicitRestore else {
            if policy.agentID.value == "openCode" {
                NotificationCenter.default.post(name: .openCodeNativeOwnershipPrepared, object: self)
            } else if policy.agentID.value == "claudeCode" {
                NotificationCenter.default.post(name: .claudeCodeNativeOwnershipPrepared, object: self)
            }
            return
        }
    }

    func bindSource(_ source: ValidatedAgentSourceIdentity) throws {
        try state.withLock {
            guard $0.active, $0.source == nil else { throw AgentTaskNativeAdmissionError.unavailable }
            $0.source = source
        }
    }

    func bindProcess(_ process: AgentTaskOwnedProcessReceipt) async throws {
        guard process.belongs(to: self), await process.revalidate() else { throw AgentTaskNativeAdmissionError.unavailable }
        try state.withLock {
            guard $0.active, $0.source != nil, $0.process == nil else { throw AgentTaskNativeAdmissionError.unavailable }
            $0.process = process
        }
    }

    func validate() throws {
        try validateSelection()
        try state.withLock {
            guard $0.source != nil else { throw AgentTaskNativeAdmissionError.unavailable }
        }
    }

    /// Before registry source creation, only the explicitly selected executable
    /// version probe is permitted. Owned transport launch additionally requires source.
    func validateSelection() throws {
        try binding.validateAuthority()
        try state.withLock {
            guard $0.active else { throw AgentTaskNativeAdmissionError.unavailable }
        }
    }

    func accepts(_ event: ValidatedAgentEvent) -> Bool {
        (try? validate()) != nil && state.withLock { $0.source == event.sourceIdentity }
    }

    private func checkLaunch(environment: [String: String]) throws {
        precondition(!Thread.isMainThread)
        try validateSelection()
        guard try Self.digest(environment) == environmentDigest else { throw AgentTaskNativeAdmissionError.invalidPolicy }
        guard filesystem.revalidate() else { throw AgentTaskNativeAdmissionError.unavailable }
        try validateSelection()
    }

    /// Full validation cannot be omitted by the physical effect entry point.
    func validateOperation() async throws {
        do {
            try validateSelection()
            _ = try await bindings.revalidate(binding)
            try validateSelection()
            if state.withLock({ $0.admitted }), !(await revalidateProcess()) {
                throw AgentTaskNativeAdmissionError.unavailable
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            revoke()
            throw AgentTaskNativeAdmissionError.unavailable
        }
    }

    /// Core registry entry wraps failures with retirement. The callback performs
    /// the actual effect now, not an enqueue for a later unguarded write.
    func perform<Result: Sendable>(
        _ effect: Effect, action: @escaping @Sendable () throws -> Result
    ) async throws -> Result {
        let cancellation = EffectCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await validateOperation()
            try Task.checkCancellation()
            return try await runOnBackground {
                try cancellation.check()
                do {
                    switch effect {
                    case .launch(let environment):
                        try self.validate()
                        try self.checkLaunch(environment: environment)
                    default:
                        try self.validatePhysical()
                    }
                } catch {
                    self.revoke()
                    throw error
                }
                // No slow validation may follow the final purpose fence.
                switch effect {
                case .launch: break
                case .submission(let receipt): try self.checkSubmission(receipt)
                case .decision: try self.checkControl()
                case .cancellation: try self.checkCancellation()
                }
                try cancellation.check()
                // Once entered, cancellation cannot claim this effect was undone.
                do { return try action() } catch {
                    self.revoke()
                    throw error
                }
            }
        } onCancel: { cancellation.cancel() }
    }

    private func validatePhysical() throws {
        try validate()
        let process = try state.withLock {
            guard $0.admitted, let process = $0.process else { throw AgentTaskNativeAdmissionError.unavailable }
            return process
        }
        try process.validateDispatch()
        try validate()
    }

    func revalidateProcess() async -> Bool {
        guard (try? validate()) != nil,
              let process = state.withLock({ $0.admitted ? $0.process : nil }),
              await process.revalidate() else { return false }
        return (try? validate()) != nil
    }

    func revoke() { state.withLock { $0.active = false } }

    func markAdmitted() throws {
        try validate()
        try state.withLock {
            guard $0.process != nil else { throw AgentTaskNativeAdmissionError.unavailable }
            $0.admitted = true
        }
    }

    func authorizeSubmission(_ id: UUID, initial: Bool) throws {
        try validate()
        try state.withLock {
            guard $0.active, $0.admitted, !$0.cancellationPending,
                  initial ? $0.initialInput == .disabled : $0.initialInput == .responded else {
                throw AgentTaskNativeAdmissionError.invalidTransition
            }
            $0.initialInput = .intent
            $0.submissionID = id
            $0.submissionReceipt = nil
            $0.isInitialSubmission = initial
            $0.submissionFenced = false
        }
    }

    /// Claim once before the actual RPC. Repeat physical-write validation with
    /// the returned receipt; never call claim again to retry an uncertain write.
    func claimSubmission(_ id: UUID) throws -> AgentTaskNativeSubmissionReceipt {
        try validate()
        return try state.withLock {
            guard $0.active, $0.admitted, $0.submissionID == id, $0.initialInput == .intent,
                  $0.submissionReceipt == nil, !$0.submissionFenced, !$0.cancellationPending else {
                throw AgentTaskNativeAdmissionError.unavailable
            }
            let receipt = AgentTaskNativeSubmissionReceipt(submissionID: id, owner: self)
            $0.submissionReceipt = receipt
            return receipt
        }
    }

    private func checkSubmission(_ receipt: AgentTaskNativeSubmissionReceipt) throws {
        try validateSubmissionCorrelation(receipt)
        try state.withLock {
            guard $0.active, $0.initialInput == .intent, !$0.submissionFenced, !$0.cancellationPending else {
                throw AgentTaskNativeAdmissionError.unavailable
            }
        }
    }

    func fenceSubmission(_ id: UUID) throws {
        try validate()
        try state.withLock {
            guard $0.submissionID == id, [.intent, .acknowledged].contains($0.initialInput) else {
                throw AgentTaskNativeAdmissionError.invalidTransition
            }
            $0.submissionFenced = true
        }
    }

    func validateSubmissionCorrelation(_ receipt: AgentTaskNativeSubmissionReceipt) throws {
        try validate()
        try state.withLock {
            guard $0.active, $0.admitted, !$0.submissionFenced, receipt.belongs(to: self),
                  $0.submissionReceipt === receipt, $0.submissionID == receipt.submissionID,
                  [.intent, .acknowledged].contains($0.initialInput) else {
                throw AgentTaskNativeAdmissionError.unavailable
            }
        }
    }

    func closeSubmission(responded: Bool) throws -> Bool {
        try validate()
        return try state.withLock {
            guard $0.active, [.intent, .acknowledged, .unknown].contains($0.initialInput) else {
                throw AgentTaskNativeAdmissionError.invalidTransition
            }
            if responded && $0.submissionFenced { return false }
            $0.initialInput = responded ? .responded : .unknown
            return true
        }
    }

    func acknowledgeInitialInput() throws {
        try validate()
        try state.withLock {
            guard $0.active, $0.admitted, [.intent, .acknowledged].contains($0.initialInput) else {
                throw AgentTaskNativeAdmissionError.invalidTransition
            }
            $0.initialInput = .acknowledged
        }
    }

    /// Combine this purpose gate with validatePhysical on the off-main writer.
    #if PINE_TEST_HOST
    // Inspection-only draft test helpers; production effects require perform.
    func validateLaunch(environment: [String: String]) throws { try checkLaunch(environment: environment) }
    func validateSubmission(_ receipt: AgentTaskNativeSubmissionReceipt) throws { try checkSubmission(receipt) }
    func validateControl() throws { try checkControl() }
    func validateCancellation() throws {
        try validate()
        try state.withLock {
            // Strict durable window: once the provider confirmed the
            // cancellation and the submission was suspended, the
            // cancellation is consumed and must no longer validate. The
            // production .cancellation wire gate (checkCancellation) is
            // deliberately broader: terminal answers to owned requests
            // stay permitted after suspension (cancellationWasDurable).
            guard $0.active, $0.admitted, $0.cancellationPending,
                  $0.cancellationDurable else {
                throw AgentTaskNativeAdmissionError.unavailable
            }
        }
    }
    func validateInitialInput() throws {
        try validate()
        try state.withLock {
            guard $0.active, $0.admitted, $0.isInitialSubmission, $0.initialInput == .intent,
                  !$0.submissionFenced, !$0.cancellationPending else {
                throw AgentTaskNativeAdmissionError.unavailable
            }
        }
    }
    #endif

    /// Recheck the selected physical purpose at the actual write boundary.
    /// Selection-time validation alone cannot fence a delayed replay write.
    func validatePhysicalEffect(_ effect: Effect) throws {
        switch effect {
        case .decision:
            try checkControl()
            try state.withLock {
                guard !$0.cancellationPending, !$0.cancellationWasDurable else {
                    throw AgentTaskNativeAdmissionError.unavailable
                }
            }
        case .cancellation: try checkCancellation()
        default: throw AgentTaskNativeAdmissionError.invalidTransition
        }
    }

    private func checkControl() throws {
        try validate()
        try state.withLock {
            guard $0.active, $0.admitted, $0.initialInput != .disabled, !$0.cancellationPending else {
                throw AgentTaskNativeAdmissionError.unavailable
            }
        }
    }

    func fenceResponsesForCancellation() { state.withLock { $0.cancellationPending = true } }
    func authorizeCancellation() throws {
        try validate()
        try state.withLock {
            guard $0.admitted, $0.cancellationPending else { throw AgentTaskNativeAdmissionError.invalidTransition }
            $0.cancellationDurable = true
            $0.cancellationWasDurable = true
        }
    }
    private func checkCancellation() throws {
        try validate()
        try state.withLock {
            guard $0.active, $0.admitted, $0.cancellationPending,
                  $0.cancellationDurable || $0.cancellationWasDurable else {
                throw AgentTaskNativeAdmissionError.unavailable
            }
        }
    }
    func suspendSubmission() {
        state.withLock {
            $0.submissionFenced = true
            $0.initialInput = .unknown
            $0.cancellationDurable = false
        }
    }

    private static func digest(_ environment: [String: String]) throws -> Data {
        guard environment.count <= 1_024,
              environment.reduce(0, { $0 + $1.key.utf8.count + $1.value.utf8.count }) <= 1_048_576 else {
            throw AgentTaskNativeAdmissionError.invalidPolicy
        }
        // Ephemeral equality only; neither values nor digest enter task history.
        return Data(SHA256.hash(data: try AgentEventJSON.object(environment.mapValues(AgentEventJSON.string)).canonicalData()))
    }
}
