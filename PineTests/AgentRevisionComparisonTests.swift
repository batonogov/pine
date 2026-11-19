//
//  AgentRevisionComparisonTests.swift
//  PineTests
//
//  The before/after result comparison contract (#1758): honest historical
//  evidence, label derivation, change summaries, and the focus contract.
//

import Foundation
import Testing
@testable import Pine

@MainActor
@Suite("Before/after result comparison contract", .serialized)
struct AgentRevisionComparisonTests {
    // MARK: - Fixtures

    private func hex(_ digit: Character) -> String {
        String(repeating: String(digit), count: 64)
    }

    private func date(_ seconds: Double) -> Date {
        Date(timeIntervalSince1970: seconds)
    }

    private func uuid(_ seed: Int) -> UUID {
        let suffix = String(format: "%012X", UInt64(seed))
        return UUID(uuidString: "00000000-0000-0000-0000-\(suffix)")
            ?? UUID()
    }

    private func codeState(_ tag: Character) -> AgentTaskCodeStateIdentity {
        AgentTaskCodeStateIdentity(
            headCommit: String(repeating: "b", count: 40),
            trackedFingerprint: hex(tag),
            untrackedFingerprint: hex(tag),
            ignoredRelevantFingerprint: hex(tag)
        )
    }

    private var environment: AgentTaskEnvironmentIdentity {
        AgentTaskEnvironmentIdentity(
            osBuild: "26A5388g",
            toolchain: "Xcode 27.0",
            configurationFingerprint: hex("c")
        )
    }

    private func candidate(
        run: UUID,
        outcome: AgentTaskOutcome = .success,
        code: AgentTaskCodeStateIdentity,
        recorded: Double
    ) -> AgentTaskResultSnapshot {
        AgentTaskResultSnapshot(
            runID: run,
            outcome: outcome,
            codeState: code,
            environment: environment,
            recordedAt: date(recorded)
        )
    }

    private var candidateA: AgentTaskResultSnapshot {
        candidate(run: uuid(10), code: codeState("a"), recorded: 120)
    }

    private var candidateB: AgentTaskResultSnapshot {
        candidate(run: uuid(11), code: codeState("b"), recorded: 170)
    }

    /// A task with two settled attempts whose required evidence passes,
    /// bound to each candidate's own code state.
    private func makeTask() -> AgentTask {
        let context = AgentTaskBridgeContext(
            project: AgentTaskProjectIdentity(
                canonicalProjectPath: "/tmp/pine-compare",
                canonicalWorktreePath: "/tmp/pine-compare"
            ),
            route: AgentTaskRoute(
                paneID: uuid(1),
                tabID: uuid(2),
                terminalID: uuid(2)
            ),
            origin: .discoveredInTerminal,
            observedAt: date(180)
        )
        var task = AgentTask(
            descriptor: AgentDescriptor(agentType: .claudeCode),
            context: context
        )
        task.runs = [
            AgentTaskRun(AgentTaskRunInput(
                id: uuid(10),
                terminalID: uuid(2),
                process: AgentProcessEvidence(
                    processIdentifier: 1_000,
                    processGeneration: 1,
                    startIdentifier: "run-0",
                    observedStartedAt: date(100),
                    startIsAuthoritative: true
                ),
                status: AgentTaskRunStatus(
                    state: .done,
                    liveness: .terminated,
                    observedAt: date(120)
                )
            )),
            AgentTaskRun(AgentTaskRunInput(
                id: uuid(11),
                terminalID: uuid(2),
                process: AgentProcessEvidence(
                    processIdentifier: 1_001,
                    processGeneration: 2,
                    startIdentifier: "run-1",
                    observedStartedAt: date(150),
                    startIsAuthoritative: true
                ),
                status: AgentTaskRunStatus(
                    state: .done,
                    liveness: .terminated,
                    observedAt: date(170)
                )
            ))
        ]
        task.evidence = [
            AgentTaskEvidenceFact(
                kind: .independentCheck,
                runID: uuid(10),
                processGeneration: 1,
                trust: .verified,
                result: .succeeded,
                observedAt: date(119),
                codeState: codeState("a"),
                environment: environment
            ),
            AgentTaskEvidenceFact(
                kind: .reviewerOutcome,
                runID: uuid(10),
                processGeneration: 1,
                trust: .verified,
                result: .succeeded,
                observedAt: date(119.5),
                codeState: codeState("a"),
                environment: environment
            ),
            AgentTaskEvidenceFact(
                kind: .independentCheck,
                runID: uuid(11),
                processGeneration: 2,
                trust: .verified,
                result: .succeeded,
                observedAt: date(169),
                codeState: codeState("b"),
                environment: environment
            ),
            AgentTaskEvidenceFact(
                kind: .reviewerOutcome,
                runID: uuid(11),
                processGeneration: 2,
                trust: .verified,
                result: .succeeded,
                observedAt: date(169.5),
                codeState: codeState("b"),
                environment: environment
            )
        ]
        task.updatedAt = date(180)
        task.lastActivityAt = date(180)
        return task
    }

    private func side(
        _ candidate: AgentTaskResultSnapshot,
        _ evidence: AgentRevisionComparisonEvidence
    ) -> AgentRevisionComparisonSide {
        guard let side = AgentRevisionComparisonSide(candidate: candidate, evidence: evidence) else {
            preconditionFailure("fixture side should be valid")
        }
        return side
    }

    private func build(
        _ before: AgentRevisionComparisonSide,
        _ after: AgentRevisionComparisonSide,
        feedbackSubmissionID: UUID? = nil,
        changesSinceFeedback: AgentRevisionChangeSummary? = nil,
        in task: AgentTask
    ) -> Result<AgentRevisionComparison, AgentRevisionComparisonFailure> {
        AgentRevisionComparisonBuilder.build(
            taskID: task.id,
            before: before,
            after: after,
            feedbackSubmissionID: feedbackSubmissionID,
            changesSinceFeedback: changesSinceFeedback,
            in: task
        )
    }

    // MARK: - Acceptance 5: real retained artifacts, disclosed gaps

    @Test("An absent historical runtime is never recreated as a live 'before'")
    func historicalSideNeverLivePreview() {
        let task = makeTask()
        let livePreview = AgentRevisionComparisonSide(
            candidate: nil,
            evidence: .uncheckedPreview
        )
        #expect(livePreview != nil)
        guard let livePreview else {
            Issue.record("preview side should be constructible")
            return
        }
        #expect(build(livePreview, side(candidateB, .retainedArtifact), in: task)
            == .failure(.historicalSideIsLivePreview))
    }

    @Test("Unavailable history is disclosed, not faked")
    func unavailableHistoryDisclosed() throws {
        let task = makeTask()
        let result = build(
            side(candidateA, .unavailable(.retentionExpired)),
            side(candidateB, .retainedArtifact),
            in: task
        )
        let comparison = try result.get()
        #expect(comparison.before.label(in: task) == .unavailable)
        #expect(!comparison.before.label(in: task).isReady)
        #expect(comparison.after.label(in: task) == .checked)
    }

    @Test("A deleted or renamed target is an honest gap, not a silent match")
    func targetMissingGap() throws {
        let task = makeTask()
        let result = build(
            side(candidateA, .unavailable(.targetMissing)),
            side(candidateB, .unavailable(.captureNeverTaken)),
            in: task
        )
        let comparison = try result.get()
        #expect(comparison.before.label(in: task) == .unavailable)
        #expect(comparison.after.label(in: task) == .unavailable)
    }

    @Test("Retained captures compare with clear content identities")
    func retainedCaptureIdentity() throws {
        let task = makeTask()
        let result = build(
            side(candidateA, .retainedCapture(sha256: hex("7"), byteCount: 123_456)),
            side(candidateB, .retainedCapture(sha256: hex("8"), byteCount: 123_456)),
            in: task
        )
        let comparison = try result.get()
        #expect(comparison.before.label(in: task).isReady)
        #expect(comparison.after.label(in: task).isReady)
    }

    // MARK: - Acceptance 8: Ready is derived, never assumed

    @Test("An unchecked preview is never labeled Ready")
    func uncheckedPreviewNeverReady() throws {
        let task = makeTask()
        let preview = AgentRevisionComparisonSide(
            candidate: nil,
            evidence: .uncheckedPreview
        )
        #expect(preview != nil)
        guard let preview else {
            Issue.record("preview side should be constructible")
            return
        }
        let comparison = try build(
            side(candidateA, .retainedArtifact),
            preview,
            in: task
        ).get()
        #expect(comparison.after.label(in: task) == .uncheckedPreview)
        #expect(!comparison.after.label(in: task).isReady)
    }

    @Test("Checked requires passing evidence bound to the candidate's own code state")
    func checkedRequiresBoundEvidence() {
        let task = makeTask()
        #expect(side(candidateA, .retainedArtifact).label(in: task) == .checked)
        #expect(side(candidateB, .retainedArtifact).label(in: task) == .checked)

        // Facts bound to a different code state do not count.
        var foreignState = makeTask()
        foreignState.evidence = [
            AgentTaskEvidenceFact(
                kind: .independentCheck,
                runID: uuid(10),
                processGeneration: 1,
                trust: .verified,
                result: .succeeded,
                observedAt: date(119),
                codeState: codeState("b"),
                environment: environment
            ),
            AgentTaskEvidenceFact(
                kind: .reviewerOutcome,
                runID: uuid(10),
                processGeneration: 1,
                trust: .verified,
                result: .succeeded,
                observedAt: date(119.5),
                codeState: codeState("b"),
                environment: environment
            )
        ]
        #expect(side(candidateA, .retainedArtifact).label(in: foreignState) == .unverified)

        // A failing bound fact vetoes.
        var failing = makeTask()
        failing.evidence[0] = AgentTaskEvidenceFact(
            kind: .independentCheck,
            runID: uuid(10),
            processGeneration: 1,
            trust: .verified,
            result: .failed,
            observedAt: date(119),
            codeState: codeState("a"),
            environment: environment
        )
        #expect(side(candidateA, .retainedArtifact).label(in: failing) == .unverified)

        // A failing bound fact vetoes even when a passing one coexists.
        var coexisting = makeTask()
        coexisting.evidence.append(AgentTaskEvidenceFact(
            kind: .independentCheck,
            runID: uuid(10),
            processGeneration: 1,
            trust: .verified,
            result: .failed,
            observedAt: date(119.9),
            codeState: codeState("a"),
            environment: environment
        ))
        #expect(side(candidateA, .retainedArtifact).label(in: coexisting) == .unverified)

        // A non-success outcome is never checked.
        let unverifiedOutcome = candidate(
            run: uuid(10),
            outcome: .unverified,
            code: codeState("a"),
            recorded: 120
        )
        #expect(side(unverifiedOutcome, .retainedArtifact).label(in: task) == .unverified)
    }

    @Test("A side pairs candidate and evidence consistently")
    func sideInvariants() {
        #expect(AgentRevisionComparisonSide(candidate: candidateA, evidence: .uncheckedPreview) == nil)
        #expect(AgentRevisionComparisonSide(candidate: nil, evidence: .retainedArtifact) == nil)
        #expect(AgentRevisionComparisonSide(
            candidate: candidateA,
            evidence: .retainedCapture(sha256: hex("a"), byteCount: 12)
        ) != nil)
        #expect(AgentRevisionComparisonSide(candidate: nil, evidence: .uncheckedPreview) != nil)
    }

    // MARK: - Acceptance 5 + 6: revision rules and nonvisual comparisons

    @Test("Comparison rejects identical or inverted revisions")
    func candidateRules() {
        let task = makeTask()
        #expect(build(
            side(candidateA, .retainedArtifact),
            side(candidateA, .retainedArtifact),
            in: task
        ) == .failure(.identicalCandidates))
        #expect(build(
            side(candidateB, .retainedArtifact),
            side(candidateA, .retainedArtifact),
            in: task
        ) == .failure(.beforeLaterThanAfter))
        let foreign = candidate(run: uuid(99), code: codeState("a"), recorded: 120)
        #expect(build(
            side(foreign, .retainedArtifact),
            side(candidateB, .retainedArtifact),
            in: task
        ) == .failure(.candidateNotInTask(uuid(99))))
    }

    @Test("The change summary exists exactly when bound to feedback")
    func summaryBoundToFeedback() throws {
        let task = makeTask()
        let summary = AgentRevisionChangeSummary(
            agentSummary: "Kept the spacing, new wording.",
            items: [AgentRevisionChangeItem(
                relativePath: "Pine/View.swift",
                kind: .modified,
                statistics: AgentCompletionDiffStatistics(
                    addedLineCount: 2,
                    removedLineCount: 1
                ),
                attribution: .agentReported
            )]
        )
        #expect(build(
            side(candidateA, .retainedArtifact),
            side(candidateB, .retainedArtifact),
            changesSinceFeedback: summary,
            in: task
        ) == .failure(.summaryWithoutFeedbackBinding))
        #expect(build(
            side(candidateA, .retainedArtifact),
            side(candidateB, .retainedArtifact),
            feedbackSubmissionID: uuid(7),
            in: task
        ) == .failure(.feedbackBindingWithoutSummary))
        let comparison = try build(
            side(candidateA, .retainedArtifact),
            side(candidateB, .retainedArtifact),
            feedbackSubmissionID: uuid(7),
            changesSinceFeedback: summary,
            in: task
        ).get()
        #expect(comparison.feedbackSubmissionID == uuid(7))
        #expect(comparison.diffPaths == ["Pine/View.swift"])
    }

    @Test("Agent-authored summaries are attributed and inspectable; nonvisual results compare examples and output")
    func summaryAttributionAndNonvisual() throws {
        let task = makeTask()
        let visual = AgentRevisionChangeSummary(
            agentSummary: "Tightened the header.",
            items: [
                AgentRevisionChangeItem(
                    relativePath: "Pine/View.swift",
                    kind: .modified,
                    attribution: .agentReported,
                    inspectable: true
                ),
                AgentRevisionChangeItem(
                    relativePath: "Pine/Other.swift",
                    kind: .created,
                    attribution: .verified,
                    inspectable: false
                )
            ]
        )
        #expect(visual.isValid)
        #expect(visual.inspectablePaths == ["Pine/View.swift"])
        _ = try build(
            side(candidateA, .retainedArtifact),
            side(candidateB, .retainedArtifact),
            feedbackSubmissionID: uuid(7),
            changesSinceFeedback: visual,
            in: task
        ).get()

        // A non-runnable task compares the failing/passing example instead.
        let nonvisual = AgentRevisionChangeSummary(
            agentSummary: nil,
            items: [AgentRevisionChangeItem(
                relativePath: "tests/failing-case.md",
                kind: .modified,
                attribution: .agentReported
            )]
        )
        let comparison = try build(
            side(candidateA, .retainedArtifact),
            side(candidateB, .retainedArtifact),
            feedbackSubmissionID: uuid(8),
            changesSinceFeedback: nonvisual,
            in: task
        ).get()
        #expect(comparison.diffPaths == ["tests/failing-case.md"])
    }

    @Test("An invalid summary or path fails closed")
    func invalidSummaryFailsClosed() {
        let task = makeTask()
        let badPath = AgentRevisionChangeSummary(
            agentSummary: nil,
            items: [AgentRevisionChangeItem(
                relativePath: "../escape",
                kind: .modified,
                attribution: .agentReported
            )]
        )
        #expect(!badPath.isValid)
        #expect(build(
            side(candidateA, .retainedArtifact),
            side(candidateB, .retainedArtifact),
            feedbackSubmissionID: uuid(7),
            changesSinceFeedback: badPath,
            in: task
        ) == .failure(.invalidSummary))
        let tooLong = AgentRevisionChangeSummary(
            agentSummary: String(repeating: "x", count: AgentRevisionChangeSummary.maximumSummaryBytes + 1),
            items: []
        )
        #expect(build(
            side(candidateA, .retainedArtifact),
            side(candidateB, .retainedArtifact),
            feedbackSubmissionID: uuid(7),
            changesSinceFeedback: tooLong,
            in: task
        ) == .failure(.invalidSummary))
    }

    // MARK: - Acceptance 7 (contract level): focus and no-command authority

    @Test("The focus descriptor preserves place and carries no command authority")
    func focusContract() throws {
        let targets: [AgentComparisonFocusTarget] = [
            .feedbackTarget(.lineRange(path: "Pine/View.swift", start: 10, end: 20)),
            .comparison,
            .manualEdit(relativePath: "Pine/View.swift", line: 12)
        ]
        for target in targets {
            let labels = Set(Mirror(reflecting: target).children.compactMap(\.label))
            #expect(labels.isDisjoint(with: ["command", "rollback", "reset", "execute"]))
        }
        // The descriptor survives relaunch exactly.
        let data = try JSONEncoder().encode(targets[2])
        #expect(try JSONDecoder().decode(AgentComparisonFocusTarget.self, from: data)
            == targets[2])
        // The comparison value itself carries no mutation authority.
        let task = makeTask()
        let comparison = try build(
            side(candidateA, .retainedArtifact),
            side(candidateB, .retainedArtifact),
            in: task
        ).get()
        let comparisonLabels = Set(Mirror(reflecting: comparison).children.compactMap(\.label))
        #expect(comparisonLabels.isDisjoint(with: ["command", "rollback", "reset"]))
    }
}
