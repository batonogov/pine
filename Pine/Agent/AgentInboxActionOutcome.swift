//
//  AgentInboxActionOutcome.swift
//  Pine
//
//  What the Inbox popover does after one navigation or recovery attempt.
//

import Foundation

/// Maps the result of an Inbox action onto the popover's own fate.
///
/// Reaching the requested session is the only reason to close: the popover
/// has done its job. Every failure keeps it visible with an actionable
/// status, because closing on failure would drop the user somewhere they did
/// not ask for and hide the one surface that can retry.
nonisolated enum AgentInboxActionOutcome: Equatable, Sendable {
    /// The user reached the session; the popover closes.
    case dismiss
    /// Nothing was reached. Stay open and say why.
    case keepVisible(AgentInboxActionStatus)

    static func forNavigation(_ result: AgentInboxNavigationResult) -> Self {
        switch result {
        case .focused:
            .dismiss
        case .taskMissing, .projectUnavailable, .routeStale:
            .keepVisible(.routeUnavailable)
        }
    }

    /// Every failed recovery keeps the popover open *and* carries the reason
    /// it failed. The reason is not decoration: thirteen distinguishable
    /// failures used to arrive here as one `.recoveryUnavailable` token and
    /// leave as one sentence that named no cause and offered no next step
    /// (#1541). Carrying ``AgentRecoveryFailure`` as a payload is what makes
    /// dropping the distinction a compile error rather than a wording choice.
    static func forRecovery(_ result: AgentInboxRecoveryResult) -> Self {
        guard let failure = AgentRecoveryFailure.forResult(result) else {
            return .dismiss
        }
        return .keepVisible(.recoveryUnavailable(failure))
    }
}

/// The status the Inbox shows while it stays open after a failed action.
nonisolated enum AgentInboxActionStatus: Equatable, Sendable {
    case routeUnavailable
    case recoveryUnavailable(AgentRecoveryFailure)
}
