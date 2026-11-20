import Foundation

/// The preparation state of one task environment against a specific
/// selected recipe version. A value contract: the executor drives
/// transitions with observed facts; nothing here starts a process.
///
/// Partial setup never appears usable: `usable` requires every setup
/// action complete and every prerequisite resolved in the environment.
/// A changed recipe fingerprint invalidates the state for the new version.
nonisolated struct AgentProjectPreparation: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case preparing
        case usable
        case failed
        case unavailable
        case cancelled
    }

    enum Reason: Equatable, Sendable {
        /// A prerequisite executable is missing or unusable.
        case missingPrerequisite(String)
        /// A setup action failed.
        case setupActionFailed(String)
        /// The bounded retry budget is exhausted.
        case retryBudgetExhausted
    }

    /// Bounded retries: the initial attempt plus this many re-runs.
    static let maximumRetries = 3

    let recipeFingerprint: String
    let setupActionIDs: [String]
    let prerequisiteNames: [String]
    private(set) var phase: Phase = .preparing
    private(set) var reason: Reason? = nil
    private(set) var completedActions: Set<String> = []
    private(set) var resolvedPrerequisites: Set<String> = []
    private(set) var retries = 0

    init(recipe: AgentProjectRecipe) {
        recipeFingerprint = recipe.fingerprint
        setupActionIDs = recipe.setup.map(\.id)
        prerequisiteNames = recipe.prerequisites.map(\.name)
    }

    enum Event: Equatable, Sendable {
        case prerequisiteResolved(String)
        case prerequisiteUnavailable(String)
        case setupSucceeded(String)
        case setupFailed(String)
        case cancelled
        case retryRequested
    }

    var isUsable: Bool { phase == .usable }

    /// Whether this preparation still authorizes the given recipe version.
    func isCurrentFor(_ recipeFingerprint: String) -> Bool {
        self.recipeFingerprint == recipeFingerprint && phase == .usable
    }

    func reduced(by event: Event) -> Self {
        var next = self
        switch (phase, event) {
        case (.preparing, .prerequisiteResolved(let name)):
            if prerequisiteNames.contains(name) {
                next.resolvedPrerequisites.insert(name)
                next.completeIfReady()
            }
        case (.preparing, .prerequisiteUnavailable(let name)):
            if prerequisiteNames.contains(name) {
                next.phase = .unavailable
                next.reason = .missingPrerequisite(name)
            }
        case (.preparing, .setupSucceeded(let id)):
            if setupActionIDs.contains(id), !next.completedActions.contains(id) {
                next.completedActions.insert(id)
                next.completeIfReady()
            }
        case (.preparing, .setupFailed(let id)):
            if setupActionIDs.contains(id) {
                next.phase = .failed
                next.reason = .setupActionFailed(id)
            }
        case (.preparing, .cancelled), (.failed, .cancelled), (.unavailable, .cancelled):
            next.phase = .cancelled
        case (.failed, .retryRequested):
            if next.retries < Self.maximumRetries {
                next.retries += 1
                next.phase = .preparing
                next.reason = nil
                // Recovery resumes at the first failure: successful setup
                // stays completed; the executor re-runs only what did not
                // succeed and must not assume idempotency.
            } else {
                next.reason = .retryBudgetExhausted
            }
        default:
            break
        }
        return next
    }

    private mutating func completeIfReady() {
        guard phase == .preparing else { return }
        if setupActionIDs.allSatisfy(completedActions.contains),
           prerequisiteNames.allSatisfy(resolvedPrerequisites.contains) {
            phase = .usable
        }
    }
}
