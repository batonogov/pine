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

    static func forRecovery(_ result: AgentInboxRecoveryResult) -> Self {
        switch result {
        case .openedNewSession, .resumed:
            .dismiss
        case .taskMissing, .projectUnavailable, .unavailable,
                .changedWhilePreparing, .launchRejected:
            .keepVisible(.recoveryUnavailable)
        }
    }
}

/// The status the Inbox shows while it stays open after a failed action.
nonisolated enum AgentInboxActionStatus: Equatable, Sendable {
    case routeUnavailable
    case recoveryUnavailable
}
