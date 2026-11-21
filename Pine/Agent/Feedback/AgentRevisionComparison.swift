//
//  AgentRevisionComparison.swift
//  Pine
//
//  The before/after result comparison contract (#1758).
//
//  A comparison pairs a selected prior result with the current result,
//  each with a clear candidate identity and honest evidence. Historical
//  sides carry retained captures or artifacts, or an explicit unavailable
//  gap: an absent historical runtime is never recreated by launching
//  today's code and labeling it "before". Reopening a comparison never
//  executes a command, and a historical selection is read-only.
//

import Foundation

/// Why one side's historical evidence is unavailable.
nonisolated enum AgentRevisionHistoryGap: String, Codable, Sendable {
    /// The retained capture/artifact was reclaimed by the retention
    /// policy.
    case retentionExpired
    /// The artifact's target no longer exists (deleted or renamed).
    case targetMissing
    /// No capture or artifact was retained for that revision.
    case captureNeverTaken
    /// The candidate identity cannot be re-proven against retained bytes.
    case identityUnverifiable
}

/// The retained evidence one side of a comparison can honestly present.
nonisolated enum AgentRevisionComparisonEvidence: Codable, Hashable, Sendable {
    /// An immutable retained capture, content-addressed.
    case retainedCapture(sha256: String, byteCount: UInt64)
    /// A retained source/diff artifact bound to the candidate's code
    /// state.
    case retainedArtifact
    /// The historical evidence is unavailable. Disclosed, never replaced
    /// by a live re-run.
    case unavailable(AgentRevisionHistoryGap)
    /// A live, mutable, unchecked preview. It can only appear on the
    /// current side, and it is never labeled Ready.
    case uncheckedPreview
}

/// One side of a before/after comparison: a real retained artifact with a
/// clear identity, or an honest disclosure.
///
/// The value carries no command and no mutation authority by construction:
/// opening it never executes anything, and a historical selection is
/// read-only (no reset/rollback under a comparison button).
nonisolated struct AgentRevisionComparisonSide: Codable, Hashable, Sendable {
    /// The checked candidate the side presents; `nil` exactly for an
    /// ``AgentRevisionComparisonEvidence/uncheckedPreview`` side.
    let candidate: AgentTaskResultSnapshot?
    let evidence: AgentRevisionComparisonEvidence

    init?(candidate: AgentTaskResultSnapshot?, evidence: AgentRevisionComparisonEvidence) {
        guard (candidate == nil) == (evidence == .uncheckedPreview) else { return nil }
        self.candidate = candidate
        self.evidence = evidence
    }
}

/// The label a side may be shown with.
nonisolated enum AgentRevisionSideLabel: String, Codable, Sendable {
    /// A settled result whose required independent evidence passes, bound
    /// to its own code state. The only label presentation may show as
    /// "Ready".
    case checked
    /// A settled result without bound passing evidence.
    case unverified
    /// A live, mutable preview that has not been checked.
    case uncheckedPreview
    /// No retained evidence to present.
    case unavailable

    var isReady: Bool { self == .checked }
}

extension AgentRevisionComparisonSide {
    /// Derives the side's label from the task's bound evidence.
    ///
    /// `checked` requires the candidate's outcome to be `.success` and
    /// every required independent fact to pass, bound to the candidate's
    /// own code state — the same standard Ready uses. An unchecked
    /// preview is never "Ready"; a missing side is never "checked".
    func label(in task: AgentTask) -> AgentRevisionSideLabel {
        switch evidence {
        case .uncheckedPreview:
            return .uncheckedPreview
        case .unavailable:
            return .unavailable
        case .retainedCapture, .retainedArtifact:
            guard let candidate, candidate.outcome == .success,
                  let codeState = candidate.codeState else {
                return .unverified
            }
            let facts = AgentTaskLifecycleReducer.facts(forRun: candidate.runID, in: task)
            // The Ready standard's veto, mirrored here: a bound failing fact
            // for the candidate's own code state names the gap; no passing-
            // fact lookup overrides it.
            guard !facts.contains(where: { fact in
                (fact.kind == .independentCheck || fact.kind == .reviewerOutcome)
                    && !fact.kind.isPassing(fact.result)
                    && fact.codeState == codeState
            }) else {
                return .unverified
            }
            let requiredPassing = AgentTaskLifecycleReducer.requiredEvidenceForSuccess
                .allSatisfy { kind in
                    facts.contains { fact in
                        fact.kind == kind
                            && fact.kind.isPassing(fact.result)
                            && fact.codeState == codeState
                    }
                }
            return requiredPassing ? .checked : .unverified
        }
    }
}

/// One observable change in a "changed since your feedback" summary.
nonisolated struct AgentRevisionChangeItem: Equatable, Sendable {
    /// The observable change: a file, a failing/passing example, a
    /// relevant output, or a document section.
    let relativePath: String
    let kind: AgentCompletionChangeKind
    let statistics: AgentCompletionDiffStatistics?
    /// The evidence level of the claim about this change.
    let attribution: AgentCompletionEvidenceLevel
    /// The diff/example is directly available for inspection.
    let inspectable: Bool

    init(
        relativePath: String,
        kind: AgentCompletionChangeKind,
        statistics: AgentCompletionDiffStatistics? = nil,
        attribution: AgentCompletionEvidenceLevel,
        inspectable: Bool = true
    ) {
        self.relativePath = relativePath
        self.kind = kind
        self.statistics = statistics
        self.attribution = attribution
        self.inspectable = inspectable
    }

    var isValid: Bool {
        AgentHistoryUndoPreflight.isCanonicalRelativePath(relativePath)
            && (statistics.map {
                $0.addedLineCount >= 0 && $0.removedLineCount >= 0
            } ?? true)
    }
}

/// A compact "changed since your feedback" summary.
///
/// `agentSummary` is agent-authored and attributed as a claim; `items`
/// are the observable changes it is inspectable against, so the summary
/// can always be checked against artifacts and diffs.
nonisolated struct AgentRevisionChangeSummary: Equatable, Sendable {
    static let maximumItems = 32
    static let maximumSummaryBytes = 4 * 1024

    let agentSummary: String?
    let items: [AgentRevisionChangeItem]

    var isValid: Bool {
        let summaryValid = agentSummary.map {
            !$0.isEmpty && $0.utf8.count <= Self.maximumSummaryBytes
                && !$0.utf8.contains(0)
        } ?? true
        return summaryValid
            && items.count <= Self.maximumItems
            && items.allSatisfy(\.isValid)
    }

    /// The changes directly available for code/diff inspection.
    var inspectablePaths: [String] {
        items.filter(\.inspectable).map(\.relativePath)
    }
}

/// A before/after comparison of two revisions of one task (#1758).
///
/// Carries no command and no mutation authority by construction: reopening
/// history never executes anything.
nonisolated struct AgentRevisionComparison: Equatable, Sendable {
    let taskID: UUID
    /// The feedback this comparison is bound to, when one exists.
    let feedbackSubmissionID: UUID?
    let before: AgentRevisionComparisonSide
    let after: AgentRevisionComparisonSide
    /// Present exactly when the comparison is bound to feedback.
    let changesSinceFeedback: AgentRevisionChangeSummary?

    /// Directly available code/diff inspection for the compared changes.
    var diffPaths: [String] {
        changesSinceFeedback?.inspectablePaths ?? []
    }
}

nonisolated enum AgentRevisionComparisonFailure: Error, Sendable, Equatable {
    /// A historical side was constructed from a live preview: the absent
    /// historical runtime is never recreated and labeled "before".
    case historicalSideIsLivePreview
    case identicalCandidates
    /// A side's candidate is not an attempt of the task.
    case candidateNotInTask(UUID)
    case beforeLaterThanAfter
    case summaryWithoutFeedbackBinding
    case feedbackBindingWithoutSummary
    /// The summary exceeds its bounds or carries an invalid change item.
    case invalidSummary
}

nonisolated enum AgentRevisionComparisonBuilder {
    /// Builds a before/after comparison with clear identities and honest
    /// evidence. The historical side must present a real retained
    /// artifact or an explicit gap; the current side may additionally be
    /// an unchecked live preview, which is never labeled Ready.
    static func build(
        taskID: UUID,
        before: AgentRevisionComparisonSide,
        after: AgentRevisionComparisonSide,
        feedbackSubmissionID: UUID? = nil,
        changesSinceFeedback: AgentRevisionChangeSummary? = nil,
        in task: AgentTask
    ) -> Result<AgentRevisionComparison, AgentRevisionComparisonFailure> {
        guard taskID == task.id else {
            return .failure(.candidateNotInTask(taskID))
        }
        switch before.evidence {
        case .uncheckedPreview:
            return .failure(.historicalSideIsLivePreview)
        case .retainedCapture, .retainedArtifact, .unavailable:
            break
        }
        guard let beforeCandidate = before.candidate,
              task.runs.contains(where: { $0.id == beforeCandidate.runID }) else {
            return .failure(.candidateNotInTask(before.candidate?.runID ?? taskID))
        }
        let afterIsPreview: Bool
        switch after.evidence {
        case .uncheckedPreview:
            afterIsPreview = true
        case .retainedCapture, .retainedArtifact, .unavailable:
            afterIsPreview = false
        }
        if !afterIsPreview {
            guard let afterCandidate = after.candidate,
                  task.runs.contains(where: { $0.id == afterCandidate.runID }) else {
                return .failure(.candidateNotInTask(after.candidate?.runID ?? taskID))
            }
            guard beforeCandidate != afterCandidate else {
                return .failure(.identicalCandidates)
            }
            guard beforeCandidate.recordedAt <= afterCandidate.recordedAt else {
                return .failure(.beforeLaterThanAfter)
            }
        }
        guard (changesSinceFeedback != nil) == (feedbackSubmissionID != nil) else {
            return .failure(
                changesSinceFeedback == nil
                    ? .feedbackBindingWithoutSummary
                    : .summaryWithoutFeedbackBinding
            )
        }
        if let summary = changesSinceFeedback {
            guard summary.isValid else { return .failure(.invalidSummary) }
        }
        return .success(AgentRevisionComparison(
            taskID: taskID,
            feedbackSubmissionID: feedbackSubmissionID,
            before: before,
            after: after,
            changesSinceFeedback: changesSinceFeedback
        ))
    }
}

/// The navigation/focus contract between the feedback target, the
/// comparison, and manual editing. Presentation (#1735) restores focus to
/// these targets. The descriptor carries no command and no mutation
/// authority by construction — reopening history never executes anything,
/// and a historical selection is read-only.
nonisolated enum AgentComparisonFocusTarget: Codable, Hashable, Sendable {
    /// The reference's anchor position in its artifact.
    case feedbackTarget(AgentFeedbackLocationAnchor)
    /// The comparison surface itself.
    case comparison
    /// A manual editing position, revealed read-only.
    case manualEdit(relativePath: String, line: UInt32)
}
