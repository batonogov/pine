//
//  AgentTaskResultView.swift
//  Pine
//
//  Task-local Ready and Needs-decision presentation (#1725). This is display
//  data plus explicit user callbacks, never an editor, terminal, acceptance,
//  verification, Git, or publication authority.
//

import SwiftUI

nonisolated enum AgentTaskResultSection: String, CaseIterable, Sendable {
    case outcome
    case tryResult
    case evidence
    case changesSinceReview
    case commandContext
}

nonisolated enum AgentTaskResultGapAction: Equatable, Sendable {
    case working
    case unverified
    case repeatEvidence(AgentTaskEvidenceKind)
    case reverify
    case failClosed
    case continueAttempt
}

nonisolated enum AgentTaskSnapshotChangeStatus: String, Equatable, Sendable {
    case unchanged
    case diverged
    case unknown
    case notRecorded
}

nonisolated struct AgentTaskSnapshotChange: Equatable, Sendable {
    enum Kind: String, Sendable { case reviewed, accepted }
    let kind: Kind
    let snapshot: AgentTaskResultSnapshot?
    let status: AgentTaskSnapshotChangeStatus
}

/// One display-safe check-journal row. Literal argv and diagnostics are not
/// presentation evidence; fingerprints, status, exit code and environment are.
nonisolated struct AgentTaskResultCheckEntry: Equatable, Sendable {
    let commandFingerprint: String
    let required: Bool
    let status: AgentTaskCheckObservation.Status
    let exitCode: Int32?
    let codeState: AgentTaskCodeStateIdentity?
    let environment: AgentTaskEnvironmentIdentity?

    init(
        result: AgentTaskCheckObservation.CommandResult,
        codeState: AgentTaskCodeStateIdentity? = nil,
        environment: AgentTaskEnvironmentIdentity?,
        exitCode: Int32? = nil
    ) {
        commandFingerprint = result.fingerprint
        required = result.required
        status = result.status
        self.exitCode = exitCode
        self.codeState = codeState
        self.environment = environment
    }
}

nonisolated struct AgentTaskResultPresentation: Equatable, Sendable {
    static let sectionOrder = AgentTaskResultSection.allCases

    let taskID: UUID
    let objective: String
    let changes: AgentRevisionChangeSummary
    let readiness: AgentTaskReadiness
    let acceptanceState: AgentTaskAcceptanceState
    let action: AgentTaskResultActionState?
    let preparation: AgentProjectPreparation?
    let preparationIsRunning: Bool
    let lastOutcome: UserTaskOutcome?
    let checkJournal: [AgentTaskResultCheckEntry]
    let reviewerOutcome: AgentTaskEvidenceFact?
    let reviewerOutcomeIsCurrent: Bool
    let codeState: AgentTaskCodeStateIdentity?
    let environment: AgentTaskEnvironmentIdentity?
    let limitations: [String]
    let snapshotChanges: [AgentTaskSnapshotChange]
    let decision: AgentTaskReviewDecision?
    let hasDecisionRequest: Bool
    let revisionComparison: AgentRevisionComparison?

    init(
        task: AgentTask,
        codeState: AgentTaskCodeStateIdentity?,
        environment: AgentTaskEnvironmentIdentity?,
        changes: AgentRevisionChangeSummary = AgentRevisionChangeSummary(
            agentSummary: nil, items: []
        ),
        action: AgentTaskResultActionState? = nil,
        preparation: AgentProjectPreparation? = nil,
        preparationIsRunning: Bool = false,
        lastOutcome: UserTaskOutcome? = nil,
        checkJournal: [AgentTaskResultCheckEntry] = [],
        limitations: [String] = [],
        revisionComparison: AgentRevisionComparison? = nil
    ) {
        taskID = task.id
        objective = task.objective ?? ""
        self.changes = changes.isValid ? changes : AgentRevisionChangeSummary(
            agentSummary: nil, items: []
        )
        let projectedReadiness = AgentTaskLifecycleReducer.readiness(
            for: task, codeState: codeState, environment: environment
        )
        readiness = projectedReadiness
        acceptanceState = task.acceptanceState
        if let action, action.binding.taskID == task.id,
           action.binding.project == task.project {
            self.action = action
            self.lastOutcome = lastOutcome
        } else {
            self.action = nil
            self.lastOutcome = nil
        }
        self.preparation = preparation
        self.preparationIsRunning = preparationIsRunning
        self.checkJournal = checkJournal
        self.codeState = codeState
        self.environment = environment
        self.limitations = limitations
        self.revisionComparison = revisionComparison?.taskID == task.id
            ? revisionComparison : nil
        if let run = task.runs.last {
            let reviews = task.evidence.filter {
                $0.runID == run.id && $0.kind == .reviewerOutcome
            }
            let current: AgentTaskEvidenceFact?
            if codeState == nil || environment == nil {
                current = nil
            } else {
                current = reviews.filter {
                    $0.codeState == codeState && $0.environment == environment
                        && $0.preOperationCodeState == codeState
                        && $0.postOperationCodeState == codeState
                        && (!projectedReadiness.isReady || $0.result == .succeeded)
                }.max { $0.observedAt < $1.observedAt }
            }
            if let current {
                reviewerOutcome = current
                reviewerOutcomeIsCurrent = true
            } else {
                reviewerOutcome = reviews.max { $0.observedAt < $1.observedAt }
                reviewerOutcomeIsCurrent = false
            }
        } else {
            reviewerOutcome = nil
            reviewerOutcomeIsCurrent = false
        }
        let proposedDecision = AgentTaskReviewOrchestrator.decisionRequest(for: task)
        hasDecisionRequest = proposedDecision != nil
        if let proposedDecision, let codeState, let environment,
           proposedDecision.taskID == task.id,
           proposedDecision.runID == task.runs.last?.id,
           proposedDecision.candidateCodeState == codeState,
           proposedDecision.candidateEnvironment == environment {
            decision = proposedDecision
        } else {
            decision = nil
        }
        snapshotChanges = [
            Self.change(
                kind: .reviewed, snapshot: task.reviewedSnapshot,
                codeState: codeState, environment: environment
            ),
            Self.change(
                kind: .accepted, snapshot: task.acceptedSnapshot,
                codeState: codeState, environment: environment
            ),
        ]
    }

    var needsDecision: Bool { decision != nil }
    var hasStaleDecision: Bool { hasDecisionRequest && decision == nil }
    var canReplyToDecision: Bool { decision != nil }
    var actionSupportsExecution: Bool { action?.binding.output.isOneShot == true }

    var canLaunchAction: Bool {
        guard readiness.isReady, !hasDecisionRequest,
              actionMatchesCurrentCandidate, actionSupportsExecution,
              let action else { return false }
        if let preparation {
            return preparation.isCurrentFor(action.binding.recipeFingerprint)
        }
        return true
    }

    var actionMatchesCurrentCandidate: Bool {
        guard let action, let codeState, let environment else { return false }
        return action.binding.snapshot == AgentVerificationIdentitySnapshot(
            code: codeState, environment: environment
        )
    }

    static func action(for gap: AgentTaskReadinessGap) -> AgentTaskResultGapAction {
        switch gap {
        case .attemptInProgress:
            return .working
        case .unverifiedOutcome:
            return .unverified
        case .missingEvidence(let kind), .failingEvidence(let kind), .staleEvidence(let kind):
            return .repeatEvidence(kind)
        case .verificationNotCurrent:
            return .reverify
        case .codeStateUnknown, .environmentUnknown, .environmentChanged:
            return .failClosed
        case .noSettledAttempt, .failedAttempt, .cancelledAttempt, .supersededAttempt:
            return .continueAttempt
        }
    }

    private static func change(
        kind: AgentTaskSnapshotChange.Kind,
        snapshot: AgentTaskResultSnapshot?,
        codeState: AgentTaskCodeStateIdentity?,
        environment: AgentTaskEnvironmentIdentity?
    ) -> AgentTaskSnapshotChange {
        guard let snapshot else {
            return AgentTaskSnapshotChange(kind: kind, snapshot: nil, status: .notRecorded)
        }
        guard let codeState, let environment else {
            return AgentTaskSnapshotChange(kind: kind, snapshot: snapshot, status: .unknown)
        }
        let unchanged = snapshot.codeState == codeState && snapshot.environment == environment
        return AgentTaskSnapshotChange(
            kind: kind, snapshot: snapshot, status: unchanged ? .unchanged : .diverged
        )
    }
}

struct AgentTaskResultView: View {
    @Environment(\.locale) private var locale
    let model: AgentTaskResultPresentation
    let onLaunch: (() -> Void)?
    let onStop: (() -> Void)?
    let onViewChanges: (() -> Void)?
    let onReverify: (() -> Void)?
    let onReply: ((String) -> Void)?
    let onSelectRecipe: (() -> Void)?
    let onPrepare: (() -> Void)?
    let onCancelPreparation: (() -> Void)?

    @State private var reply = ""
    @FocusState private var replyIsFocused: Bool

    init(
        model: AgentTaskResultPresentation,
        onLaunch: (() -> Void)? = nil,
        onStop: (() -> Void)? = nil,
        onViewChanges: (() -> Void)? = nil,
        onReverify: (() -> Void)? = nil,
        onReply: ((String) -> Void)? = nil,
        onSelectRecipe: (() -> Void)? = nil,
        onPrepare: (() -> Void)? = nil,
        onCancelPreparation: (() -> Void)? = nil
    ) {
        self.model = model
        self.onLaunch = onLaunch
        self.onStop = onStop
        self.onViewChanges = onViewChanges
        self.onReverify = onReverify
        self.onReply = onReply
        self.onSelectRecipe = onSelectRecipe
        self.onPrepare = onPrepare
        self.onCancelPreparation = onCancelPreparation
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                outcomeSection
                trySection
                evidenceSection
                snapshotSection
                commandContextSection
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .frame(minWidth: 520, idealWidth: 720, minHeight: 480)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityIdentifier(AccessibilityID.agentTaskResult)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: model.readiness.isReady && !model.hasDecisionRequest
                ? "checkmark.seal" : "info.circle")
                .foregroundStyle(model.readiness.isReady && !model.hasDecisionRequest
                    ? .green : .secondary)
                .accessibilityHidden(true)
            Text(verbatim: copy(statusCopy))
                .font(.title3.weight(.semibold))
            Spacer()
            Text(verbatim: copy(model.acceptanceState == .accepted
                ? .accepted : .notAccepted))
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.quaternary, in: Capsule())
                .accessibilityIdentifier(AccessibilityID.agentTaskResultAcceptance)
        }
        .accessibilityElement(children: .contain)
    }

    private var statusCopy: Strings.AgentResultCopy {
        if model.hasStaleDecision { return .staleDecisionTitle }
        if model.needsDecision { return .needsDecisionTitle }
        if model.readiness.isReady { return .readyTitle }
        if model.readiness.gaps.contains(.attemptInProgress) { return .workingTitle }
        if model.readiness.gaps.contains(where: {
            if case .failedAttempt = $0 { return true }
            if case .cancelledAttempt = $0 { return true }
            return false
        }) { return .notReadyTitle }
        return .unverifiedTitle
    }

    private var outcomeSection: some View {
        section(.outcomeTitle, identifier: AccessibilityID.agentTaskResultOutcome) {
            Text(verbatim: model.objective.isEmpty ? copy(.objectiveUnavailable) : model.objective)
                .font(.body.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if let summary = model.changes.agentSummary {
                Label(copy(.agentReportedSummary), systemImage: "sparkles")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(verbatim: summary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if model.changes.items.isEmpty {
                Text(verbatim: copy(.noVerifiedChanges))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(model.changes.items.enumerated()), id: \.offset) { _, change in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: changeIcon(change.kind))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text(verbatim: change.relativePath)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                        Spacer()
                        if let statistics = change.statistics {
                            Text(verbatim: "+\(statistics.addedLineCount) −\(statistics.removedLineCount)")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityLabel(Text(verbatim: change.relativePath))
                }
            }
            if !model.readiness.isReady {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(model.readiness.gaps.enumerated()), id: \.offset) { _, gap in
                        gapView(gap)
                    }
                }
                .padding(.top, 4)
            }
            if model.hasDecisionRequest { decisionContent }
        }
    }

    private var trySection: some View {
        section(.tryTitle, identifier: AccessibilityID.agentTaskResultTry) {
            if let action = model.action {
                if action.verb != .viewChanges && !model.actionSupportsExecution {
                    Text(verbatim: copy(.unsupportedOutput))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier(AccessibilityID.agentTaskResultUnsupported)
                }
                HStack(spacing: 10) {
                    actionButton(action)
                    Text(verbatim: phaseText(action.phase))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier(AccessibilityID.agentTaskResultPhase)
                }
                if !model.actionMatchesCurrentCandidate, let onSelectRecipe {
                    Button(copy(.rebindResult), action: onSelectRecipe)
                }
                if let preparation = model.preparation,
                   !preparation.isCurrentFor(action.binding.recipeFingerprint) {
                    if preparation.phase == .preparing && model.preparationIsRunning {
                        Button(copy(.cancel)) { onCancelPreparation?() }
                            .disabled(onCancelPreparation == nil)
                    } else if preparation.phase == .preparing || preparation.phase == .failed {
                        Button(copy(.prepareResult)) { onPrepare?() }
                            .disabled(!model.readiness.isReady || model.hasDecisionRequest
                                || !model.actionMatchesCurrentCandidate || onPrepare == nil)
                    } else if let onSelectRecipe {
                        Button(copy(.rebindResult), action: onSelectRecipe)
                    }
                    Text(verbatim: preparationText(preparation))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if case .failed(let reason) = action.phase {
                    Text(verbatim: failureText(reason))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if action.phase == .portConflict {
                    Text(verbatim: copy(.portConflictDetail))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if action.verb != .viewChanges {
                    Text(verbatim: copy(.commandDisclosure))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let outcome = model.lastOutcome {
                    outcomeView(outcome)
                }
            } else {
                Text(verbatim: copy(.noResultAction))
                    .foregroundStyle(.secondary)
                if let onSelectRecipe {
                    Button(copy(.selectResultAction), action: onSelectRecipe)
                }
            }
        }
    }

    @ViewBuilder
    private func actionButton(_ action: AgentTaskResultActionState) -> some View {
        if action.verb == .viewChanges {
            Button(copy(.viewChanges)) { onViewChanges?() }
                .disabled(onViewChanges == nil)
                .accessibilityIdentifier(AccessibilityID.agentTaskResultPrimaryAction)
        } else if !model.actionSupportsExecution {
            if action.ownership != nil {
                Button(copy(.stop)) { onStop?() }
                    .disabled(onStop == nil)
                    .accessibilityIdentifier(AccessibilityID.agentTaskResultStop)
            }
        } else if action.phase == .starting || action.phase == .stopping {
            Button(copy(.cancel)) { onStop?() }
                .disabled(onStop == nil)
                .accessibilityIdentifier(AccessibilityID.agentTaskResultStop)
        } else if action.phase == .ready || action.phase == .stale,
                  action.ownership != nil {
            HStack(spacing: 10) {
                if action.phase == .ready {
                    Button(verbText(action.verb)) { onLaunch?() }
                        .disabled(!model.canLaunchAction || onLaunch == nil)
                        .accessibilityIdentifier(AccessibilityID.agentTaskResultPrimaryAction)
                }
                Button(copy(.stop)) { onStop?() }
                    .disabled(onStop == nil)
                    .accessibilityIdentifier(AccessibilityID.agentTaskResultStop)
            }
        } else {
            Button(verbText(action.verb)) { onLaunch?() }
                .disabled(!model.canLaunchAction || action.phase == .stale || onLaunch == nil)
                .accessibilityIdentifier(AccessibilityID.agentTaskResultPrimaryAction)
        }
    }

    private func preparationText(_ preparation: AgentProjectPreparation) -> String {
        switch preparation.phase {
        case .preparing:
            return copy(model.preparationIsRunning ? .preparing : .preparationRequired)
        case .usable: return copy(.prepared)
        case .failed: return copy(.actionFailed)
        case .unavailable:
            if case .missingPrerequisite(let name) = preparation.reason {
                return copy(.missingPrerequisite, [name])
            }
            return copy(.environmentUnavailable)
        case .cancelled: return copy(.cancelled)
        }
    }

    private func outcomeView(_ outcome: UserTaskOutcome) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: copy(.commandExit, [String(outcome.processExitCode ?? -1)]))
                .font(.caption)
                .foregroundStyle(.secondary)
            if !outcome.outputPreview.text.isEmpty {
                Text(verbatim: outcome.outputPreview.text)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if outcome.outputPreview.wasTruncated {
                Text(verbatim: copy(.outputTruncated))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var evidenceSection: some View {
        section(.evidenceTitle, identifier: AccessibilityID.agentTaskResultEvidence) {
            if model.checkJournal.isEmpty {
                Text(verbatim: copy(.noChecks))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(model.checkJournal.enumerated()), id: \.offset) { _, entry in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: entry.commandFingerprint)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                        Text(verbatim: checkMetadata(entry))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let codeState = entry.codeState {
                            codeStateText(codeState)
                        }
                        if let environment = entry.environment {
                            environmentText(environment)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            reviewerView
            if let codeState = model.codeState {
                codeStateText(codeState)
            }
            if let environment = model.environment {
                environmentText(environment)
            }
            if model.limitations.isEmpty {
                Text(verbatim: copy(.noRecordedLimitations))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(verbatim: copy(.limitations))
                    .font(.caption.weight(.semibold))
                ForEach(Array(model.limitations.enumerated()), id: \.offset) { _, limitation in
                    Text(verbatim: limitation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var reviewerView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: copy(.reviewerOutcome))
                .font(.caption.weight(.semibold))
            if let review = model.reviewerOutcome {
                Text(verbatim: reviewerResultText(review.result))
                    .foregroundStyle(review.result == .succeeded && model.reviewerOutcomeIsCurrent
                        ? .green : .orange)
                if !model.reviewerOutcomeIsCurrent {
                    Text(verbatim: copy(.historicalReview, [
                        review.codeState?.trackedFingerprint ?? copy(.unknown),
                    ]))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let criteria = review.criteriaDigest {
                    Text(verbatim: criteria)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            } else {
                Text(verbatim: copy(.noReviewerOutcome))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func codeStateText(_ code: AgentTaskCodeStateIdentity) -> some View {
        Text(verbatim: copy(.codeIdentity, [
            code.headCommit ?? copy(.unknown), code.trackedFingerprint,
            code.untrackedFingerprint, code.ignoredRelevantFingerprint,
        ]))
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
    }

    private func environmentText(_ environment: AgentTaskEnvironmentIdentity) -> some View {
        Text(verbatim: [
            environment.osBuild ?? copy(.unknown),
            environment.toolchain ?? copy(.unknown),
            environment.configurationFingerprint ?? copy(.unknown),
        ].joined(separator: " · "))
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
    }

    private var snapshotSection: some View {
        section(.snapshotTitle, identifier: AccessibilityID.agentTaskResultSnapshots) {
            ForEach(Array(model.snapshotChanges.enumerated()), id: \.offset) { _, change in
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: snapshotChangeText(change))
                        .foregroundStyle(change.status == .diverged ? .orange : .secondary)
                    if let snapshot = change.snapshot {
                        Text(verbatim: snapshotIdentity(snapshot))
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var commandContextSection: some View {
        section(.contextTitle, identifier: AccessibilityID.agentTaskResultContext) {
            if let comparison = model.revisionComparison {
                Text(verbatim: comparisonText(comparison))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(verbatim: copy(.contextPlaceholder))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var decisionContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let decision = model.decision {
                Text(verbatim: decisionReason(decision.blocker))
                    .font(.body.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: copy(.decisionConsequence))
                    .foregroundStyle(.secondary)
                Text(verbatim: decisionAction(decision.blocker))
                    .fixedSize(horizontal: false, vertical: true)
                if let finding = decision.unresolvedFindingReference {
                    Text(verbatim: copy(.unresolvedFinding, [finding]))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            } else {
                Text(verbatim: copy(.staleDecisionDetail))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(verbatim: copy(.preservedWork))
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(copy(.replyPlaceholder), text: $reply, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...5)
                .focused($replyIsFocused)
                .disabled(!model.canReplyToDecision)
                .accessibilityIdentifier(AccessibilityID.agentTaskResultReply)
            Button(copy(.sendReply)) {
                let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
                guard model.canReplyToDecision, !text.isEmpty else { return }
                onReply?(text)
                reply = ""
            }
            .disabled(!model.canReplyToDecision
                || reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || onReply == nil)
            .accessibilityIdentifier(AccessibilityID.agentTaskResultSendReply)
        }
        .padding(12)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
    }

    private func gapView(_ gap: AgentTaskReadinessGap) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: gapIcon(gap))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(verbatim: gapText(gap))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if AgentTaskResultPresentation.action(for: gap) == .reverify,
               let onReverify {
                Button(copy(.verifyAgain), action: onReverify)
                    .accessibilityIdentifier(AccessibilityID.agentTaskResultReverify)
            }
        }
    }

    private func section<Content: View>(
        _ title: Strings.AgentResultCopy,
        identifier: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: copy(title))
                .font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }

    private func copy(
        _ value: Strings.AgentResultCopy,
        _ arguments: [String] = []
    ) -> String {
        Strings.agentResult(value, arguments: arguments, locale: locale)
    }

    private func verbText(_ verb: AgentProjectResultVerb) -> String {
        switch verb {
        case .openPreview: copy(.openPreview)
        case .runApplication: copy(.runApplication)
        case .runExample: copy(.runExample)
        case .viewChanges: copy(.viewChanges)
        }
    }

    private func phaseText(_ phase: AgentTaskResultActionState.Phase) -> String {
        switch phase {
        case .prepared: copy(.prepared)
        case .starting: copy(.starting)
        case .ready: copy(.actionReady)
        case .failed: copy(.actionFailed)
        case .portConflict: copy(.portConflict)
        case .stopping: copy(.stopping)
        case .stopped: copy(.stopped)
        case .cancelled: copy(.cancelled)
        case .stale: copy(.stale)
        }
    }

    private func failureText(_ reason: AgentTaskResultActionState.FailureReason) -> String {
        switch reason {
        case .startupFailed: copy(.startupFailed)
        case .missingPrerequisite(let name): copy(.missingPrerequisite, [name])
        case .processExited(let code): copy(.processExited, [String(code)])
        case .launchRefused(let refusal): launchRefusalText(refusal)
        }
    }

    private func launchRefusalText(_ refusal: AgentTaskResultLaunchRefusal) -> String {
        switch refusal {
        case .bindingChanged: copy(.bindingChanged)
        case .notReady: copy(.launchNotReady)
        case .grantNotCurrent: copy(.grantNotCurrent)
        case .environmentUnavailable: copy(.environmentUnavailable)
        case .originalCheckout: copy(.originalCheckout)
        case .unsupportedOutput: copy(.unsupportedOutput)
        case .authorityChanged: copy(.authorityChanged)
        }
    }

    private func checkMetadata(_ entry: AgentTaskResultCheckEntry) -> String {
        let requirement = copy(entry.required ? .requiredCheck : .optionalCheck)
        let status = checkStatus(entry.status)
        let exit = entry.exitCode.map(String.init) ?? copy(.exitUnavailable)
        return copy(.checkMetadata, [requirement, status, exit])
    }

    private func checkStatus(_ status: AgentTaskCheckObservation.Status) -> String {
        switch status {
        case .succeeded: copy(.checkSucceeded)
        case .failed: copy(.checkFailed)
        case .timedOut: copy(.checkTimedOut)
        case .cancelled: copy(.cancelled)
        case .launchFailed: copy(.startupFailed)
        case .outputUnavailable: copy(.outputUnavailable)
        case .cleanupFailed: copy(.cleanupFailed)
        case .authorityChanged: copy(.authorityChanged)
        case .identityChanged: copy(.identityChanged)
        case .identityUnavailable: copy(.identityUnavailable)
        }
    }

    private func reviewerResultText(_ result: AgentTaskEvidenceResult) -> String {
        switch result {
        case .succeeded: copy(.reviewPassed)
        case .requestedChanges: copy(.reviewRequestedChanges)
        case .failed: copy(.reviewFailed)
        default: copy(.unknown)
        }
    }

    private func snapshotChangeText(_ change: AgentTaskSnapshotChange) -> String {
        let label = copy(change.kind == .reviewed ? .reviewedSnapshot : .acceptedSnapshot)
        let status: String = switch change.status {
        case .unchanged: copy(.snapshotUnchanged)
        case .diverged: copy(.snapshotDiverged)
        case .unknown: copy(.snapshotUnknown)
        case .notRecorded: copy(.snapshotNotRecorded)
        }
        return copy(.snapshotStatus, [label, status])
    }

    private func snapshotIdentity(_ snapshot: AgentTaskResultSnapshot) -> String {
        let code = snapshot.codeState?.trackedFingerprint ?? copy(.unknown)
        let environment = snapshot.environment?.configurationFingerprint ?? copy(.unknown)
        return copy(.snapshotIdentity, [code, environment])
    }

    private func comparisonText(_ comparison: AgentRevisionComparison) -> String {
        copy(.comparison, [
            snapshotIdentity(comparison.before.candidate),
            snapshotIdentity(comparison.after.candidate),
        ])
    }

    private func snapshotIdentity(_ candidate: AgentTaskResultSnapshot?) -> String {
        candidate?.codeState?.trackedFingerprint ?? copy(.unknown)
    }

    private func decisionReason(_ blocker: AgentTaskCorrectionCycle.Blocker) -> String {
        switch blocker {
        case .correctionLimit: copy(.decisionCorrectionLimit)
        case .deliveryUnknown: copy(.decisionDeliveryUnknown)
        case .infrastructureFailure: copy(.decisionInfrastructure)
        case .checksFailed: copy(.decisionChecksFailed)
        case .reviewerBoundaryUnavailable: copy(.decisionReviewerBoundary)
        }
    }

    private func decisionAction(_ blocker: AgentTaskCorrectionCycle.Blocker) -> String {
        switch blocker {
        case .correctionLimit: copy(.actionCorrectionLimit)
        case .deliveryUnknown: copy(.actionDeliveryUnknown)
        case .infrastructureFailure: copy(.actionInfrastructure)
        case .checksFailed: copy(.actionChecksFailed)
        case .reviewerBoundaryUnavailable: copy(.actionReviewerBoundary)
        }
    }

    private func gapText(_ gap: AgentTaskReadinessGap) -> String {
        switch gap {
        case .attemptInProgress: copy(.gapWorking)
        case .noSettledAttempt: copy(.gapNoAttempt)
        case .unverifiedOutcome: copy(.gapUnverified)
        case .failedAttempt: copy(.gapFailed)
        case .cancelledAttempt: copy(.gapCancelled)
        case .supersededAttempt: copy(.gapSuperseded)
        case .verificationNotCurrent: copy(.gapReverify)
        case .missingEvidence(let kind): copy(.gapMissing, [evidenceName(kind)])
        case .failingEvidence(let kind): copy(.gapFailing, [evidenceName(kind)])
        case .staleEvidence(let kind): copy(.gapStale, [evidenceName(kind)])
        case .codeStateUnknown: copy(.gapCodeUnknown)
        case .environmentUnknown: copy(.gapEnvironmentUnknown)
        case .environmentChanged: copy(.gapEnvironmentChanged)
        }
    }

    private func evidenceName(_ kind: AgentTaskEvidenceKind) -> String {
        switch kind {
        case .independentCheck: copy(.evidenceCheck)
        case .reviewerOutcome: copy(.evidenceReview)
        case .agentReportedCompletion: copy(.evidenceCompletion)
        default: copy(.unknown)
        }
    }

    private func gapIcon(_ gap: AgentTaskReadinessGap) -> String {
        switch AgentTaskResultPresentation.action(for: gap) {
        case .working: "hourglass"
        case .unverified, .repeatEvidence, .reverify: "checkmark.shield"
        case .failClosed: "exclamationmark.lock"
        case .continueAttempt: "arrow.uturn.forward"
        }
    }

    private func changeIcon(_ kind: AgentCompletionChangeKind) -> String {
        switch kind {
        case .modified: "pencil"
        case .created: "plus.circle"
        case .deleted: "minus.circle"
        case .renamed: "arrow.right"
        case .unknown: "questionmark.circle"
        }
    }
}
