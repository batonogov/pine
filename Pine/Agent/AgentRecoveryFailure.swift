//
//  AgentRecoveryFailure.swift
//  Pine
//
//  One named cause — and one next step — for every way Agent Inbox recovery
//  can fail (#1541).
//
//  Recovery fails in thirteen distinguishable ways: the five outcomes
//  `AgentInboxRecoveryResult` reports directly, plus the nine reasons
//  `AgentTaskRecoveryPlanner` can refuse a plan for. Every one of them used
//  to reach the user as the single sentence "Safe recovery is unavailable",
//  which names no cause and offers no way forward — the failure state #1494
//  asked us not to ship. This type is the mapping that keeps them apart, and
//  it is a value rather than a switch inside the view so each cause can be
//  enumerated by a test.
//

import Foundation

/// A recovery attempt that did not start a session, named by its cause.
///
/// `CaseIterable` on purpose: the tests walk every case and assert it has its
/// own cause text and a non-empty next step, so a case added here cannot
/// quietly inherit another one's wording.
nonisolated enum AgentRecoveryFailure: String, CaseIterable, Equatable, Sendable {
    // MARK: Outcomes reported by the Inbox itself

    /// The task left the Inbox between the click and the attempt.
    case taskGone
    /// The project window could not be presented for the task.
    case projectWindowUnavailable
    /// The task or its window changed while Pine was preparing the launch.
    case changedWhilePreparing
    /// The terminal refused to host the recovery session.
    case launchRejected

    // MARK: Reasons the planner refuses a plan

    /// Lifecycle or liveness does not admit recovery at all.
    case notRecoverable
    /// The recorded project directory is gone.
    case projectFolderMissing
    /// The recorded worktree directory is gone.
    case worktreeMissing
    /// The agent's executable is no longer on `PATH`.
    case agentExecutableMissing
    /// No reviewed adapter covers this provider/agent/executable triple.
    case adapterUnavailable
    /// The run recorded no vendor session identity to resume.
    case sessionIdentityMissing
    /// The recorded vendor session identity failed validation.
    case sessionIdentityInvalid
    /// The executable did not answer `--version` within the probe budget.
    case versionProbeFailed
    /// The executable's version no longer matches the recorded one.
    case versionChanged

    /// The failure behind one Inbox recovery result, or `nil` when the
    /// result is a success.
    ///
    /// Written as a total switch with no `default` so a new result case is a
    /// compile error here rather than a silent fall-through into whichever
    /// generic sentence happens to be nearest.
    static func forResult(_ result: AgentInboxRecoveryResult) -> Self? {
        switch result {
        case .openedNewSession, .resumed:
            nil
        case .taskMissing:
            .taskGone
        case .projectUnavailable:
            .projectWindowUnavailable
        case .changedWhilePreparing:
            .changedWhilePreparing
        case .launchRejected:
            .launchRejected
        case .unavailable(let reason):
            forReason(reason)
        }
    }

    /// The failure behind one planner refusal. Total, for the same reason.
    static func forReason(_ reason: AgentTaskRecoveryUnavailableReason) -> Self {
        switch reason {
        case .taskNotRecoverable: .notRecoverable
        case .projectMissing: .projectFolderMissing
        case .worktreeMissing: .worktreeMissing
        case .executableMissing: .agentExecutableMissing
        case .adapterUnavailable: .adapterUnavailable
        case .vendorIdentityMissing: .sessionIdentityMissing
        case .vendorIdentityInvalid: .sessionIdentityInvalid
        case .versionProbeFailed: .versionProbeFailed
        case .versionChanged: .versionChanged
        }
    }

    /// Catalog key for the sentence naming what went wrong.
    var causeKey: String { "agentRecovery.cause.\(rawValue)" }

    /// Catalog key for the sentence telling the user what to do about it.
    ///
    /// Causes outnumber remedies, and saying so is more useful than inventing
    /// thirteen different sentences: five distinct executables, versions and
    /// identities all fail the same way and all have the same way forward —
    /// start a fresh session in the same worktree, which the Inbox is already
    /// offering one button away. Distinctness is asserted on ``causeKey``;
    /// this one is asserted only to be present and non-empty.
    var nextStepKey: String {
        switch self {
        case .taskGone:
            "agentRecovery.nextStep.nothingToRecover"
        case .projectWindowUnavailable, .projectFolderMissing:
            "agentRecovery.nextStep.reopenProject"
        case .changedWhilePreparing:
            "agentRecovery.nextStep.retry"
        case .launchRejected:
            "agentRecovery.nextStep.startManually"
        case .notRecoverable:
            "agentRecovery.nextStep.openInstead"
        case .worktreeMissing:
            "agentRecovery.nextStep.restoreWorktree"
        case .agentExecutableMissing, .adapterUnavailable,
             .sessionIdentityMissing, .sessionIdentityInvalid,
             .versionProbeFailed, .versionChanged:
            "agentRecovery.nextStep.newSession"
        }
    }
}
