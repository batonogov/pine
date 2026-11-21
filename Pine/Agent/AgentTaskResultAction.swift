import Foundation

/// A loopback endpoint a result action may own.
nonisolated struct AgentProjectResultEndpoint: Equatable, Hashable, Sendable {
    let host: String
    let port: UInt16

    var isValid: Bool { (host == "127.0.0.1" || host == "::1") && port > 0 }
}

/// Pine-observed ownership of a result process. Stop and relaunch apply
/// only to this exact process group; the model provides no primitive to
/// affect other processes.
nonisolated struct AgentTaskResultOwnership: Equatable, Sendable {
    let processID: UInt32
    let processGroupID: UInt32
    /// Present while the owned server endpoint is up.
    let endpoint: AgentProjectResultEndpoint?
}

/// Binds a result action to the current candidate and environment
/// identity (consumed from #1753's capture contract) and to the owning
/// task. Two actions for different tasks or snapshots are never
/// interchangeable, even when they share a port, artifact path, or recipe.
nonisolated struct AgentTaskResultActionBinding: Equatable, Sendable {
    let taskID: UUID
    let project: AgentTaskProjectIdentity
    let recipeFingerprint: String
    let resultActionID: String
    let output: AgentProjectResultOutput
    let snapshot: AgentVerificationIdentitySnapshot
}

/// The presentation verb for a result output; non-runnable changes keep
/// View changes instead of a fictional launch action. Localization is the
/// presentation layer's concern (#1725).
nonisolated enum AgentProjectResultVerb: String, CaseIterable, Sendable {
    case openPreview
    case runApplication
    case runExample
    case viewChanges

    var title: String {
        switch self {
        case .openPreview: return "Open preview"
        case .runApplication: return "Run application"
        case .runExample: return "Run example"
        case .viewChanges: return "View changes"
        }
    }
}

extension AgentProjectResultOutput {
    nonisolated var verb: AgentProjectResultVerb {
        switch self {
        case .server: return .openPreview
        case .artifact: return .runApplication
        case .cli: return .runExample
        case .document: return .viewChanges
        }
    }
}

/// The lifecycle of one owned result action against one exact binding.
/// The executor drives transitions with observed facts; nothing here
/// starts or kills a process. Preparation and build are separate from
/// execution: a state starts at `.prepared` once the candidate's setup
/// and checks are current, and only an explicit launch runs a result.
nonisolated struct AgentTaskResultActionState: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        /// Preparation and build are complete; nothing is running.
        case prepared
        case starting
        /// A current result is available for this exact binding.
        case ready
        case failed(FailureReason)
        /// The requested endpoint is occupied by a non-owned process.
        /// The occupant is never killed; the user resolves the conflict.
        case portConflict
        case stopping
        /// The owned process terminated; the result is no longer current.
        /// Work (code state) is preserved.
        case stopped
        case cancelled
        /// The candidate or environment changed while the result was
        /// current; the evidence is no longer current.
        case stale
    }

    enum FailureReason: Equatable, Sendable {
        case startupFailed
        case missingPrerequisite(String)
        case processExited(Int32)
    }

    let binding: AgentTaskResultActionBinding
    private(set) var phase: Phase = .prepared
    private(set) var ownership: AgentTaskResultOwnership? = nil
    /// Launch attempts for this binding, including relaunches.
    /// Informational diagnostic only (in-memory, not persisted); every
    /// increment requires an explicit user launch request.
    private(set) var attempts = 0

    init(binding: AgentTaskResultActionBinding) {
        self.binding = binding
    }

    var isCurrent: Bool { phase == .ready }
    /// A current live preview: mutable content that changes without new
    /// evidence whenever the worktree changes.
    var isLivePreview: Bool { isCurrent && binding.output.isLivePreview }
    /// The concrete verb to present for this action.
    var verb: AgentProjectResultVerb { binding.output.verb }

    enum Event: Equatable, Sendable {
        /// An explicit user launch, relaunch, or re-run for this binding.
        case launchRequested
        /// Pine observed the process it launched.
        case processObserved(processID: UInt32, processGroupID: UInt32)
        /// The executor verified readiness (endpoint responded / app alive).
        case readyObserved
        case startupFailed
        case prerequisiteMissing(String)
        /// Bind failed: the endpoint is occupied by a non-owned process.
        case portOccupied
        /// Pine observed the owned process terminate.
        case processExited(Int32)
        /// An explicit user stop of the owned process.
        case stopRequested
        /// The launch was cancelled.
        case cancelled
        /// The candidate or environment identity changed.
        case candidateChanged
    }

    func reduced(by event: Event) -> Self {
        var next = self
        let ownedEndpoint: AgentProjectResultEndpoint? = {
            if case .server(let host, let port) = binding.output {
                return AgentProjectResultEndpoint(host: host, port: port)
            }
            return nil
        }()
        switch (phase, event) {
        case (.prepared, .launchRequested),
             (.stopped, .launchRequested),
             (.failed, .launchRequested),
             (.cancelled, .launchRequested),
             (.portConflict, .launchRequested),
             (.ready, .launchRequested) where binding.output.isOneShot:
            // Initial launch, relaunch, conflict retry, or example re-run
            // reuse the same binding and count as one more attempt. A
            // long-running ready result reuses the live process instead.
            next.phase = .starting
            next.ownership = nil
            next.attempts += 1
        case (.starting, .processObserved(let processID, let processGroupID))
            where processID != 0:
            // A degenerate observation (pid 0) would hand a future killpg the
            // caller's own process group; ignore it.
            next.ownership = AgentTaskResultOwnership(
                processID: processID, processGroupID: processGroupID, endpoint: ownedEndpoint
            )
        case (.starting, .readyObserved) where next.ownership != nil:
            // Readiness requires Pine-observed ownership.
            next.phase = .ready
        case (.starting, .startupFailed):
            next.phase = .failed(.startupFailed)
            next.ownership = nil
        case (.prepared, .prerequisiteMissing(let name)),
             (.starting, .prerequisiteMissing(let name)):
            next.phase = .failed(.missingPrerequisite(name))
            next.ownership = nil
        case (.starting, .portOccupied):
            // The occupant is not ours: never kill it, stay truthful.
            next.phase = .portConflict
            next.ownership = nil
        case (.starting, .cancelled):
            next.phase = .cancelled
            next.ownership = nil
        case (.starting, .processExited(let code)):
            if binding.output.isOneShot, code == 0 {
                // A completed one-shot is the observed result; no live
                // process remains to own.
                next.phase = .ready
            } else {
                next.phase = .failed(.processExited(code))
            }
            next.ownership = nil
        case (.ready, .stopRequested), (.stale, .stopRequested) where next.ownership != nil:
            next.phase = .stopping
        case (.ready, .processExited(let code)),
             (.stale, .processExited(let code)) where !binding.output.isOneShot:
            // The owned result process ended on its own; a stale preview
            // with a dead process must not keep claiming it.
            next.phase = code == 0 ? .stopped : .failed(.processExited(code))
            next.ownership = nil
        case (.stopping, .processExited):
            next.phase = .stopped
            next.ownership = nil
        case (.ready, .candidateChanged):
            // Live changes make current evidence stale.
            next.phase = .stale
        default:
            // Unknown combinations, events for the wrong phase, and
            // requests against a stale binding fail closed as no-ops.
            break
        }
        return next
    }
}
