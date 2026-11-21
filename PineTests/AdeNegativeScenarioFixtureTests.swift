//
//  AdeNegativeScenarioFixtureTests.swift
//  PineTests
//
//  Deterministic acceptance fixtures for issue #1761 (release-readiness
//  integration gate): the negative and recovery scenario list from the issue
//  is encoded in PineTests/Fixtures/AgentAdapters/ade-negative-scenarios-v1.json.
//  Every row is classified as existing (a named test in this base), added
//  (executed by this suite), or pending (owned by a named in-flight branch).
//  Rows are model-level and deterministic: no LLM prose, no provider
//  install, no network.
//

import Foundation
import Testing
@testable import Pine

@MainActor
@Suite("ADE negative and recovery scenario fixtures (#1761)", .serialized)
struct AdeNegativeScenarioFixtureTests {
    // MARK: - Fixture

    private static let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent(
            "Fixtures/AgentAdapters/ade-negative-scenarios-v1.json"
        )

    private struct ScenarioRow: Decodable {
        let id: String
        let group: String
        let scenario: String
        let expected: String
        let coverage: String
        let evidence: String?
        let owner: String?
    }

    private struct Fixture: Decodable {
        let schemaVersion: Int
        let fixtureVersion: String
        let coverageValues: [String]
        let scenarios: [ScenarioRow]
    }

    private func loadFixture() throws -> Fixture {
        try JSONDecoder().decode(
            Fixture.self,
            from: Data(contentsOf: Self.fixtureURL)
        )
    }

    /// The issue's negative and recovery scenario list (#1761, section 3),
    /// one id per scenario. The fixture must contain exactly this set: a
    /// missing row is a silently skipped scenario, an extra row is an
    /// unowned claim.
    private static let requiredScenarioIDs: Set<String> = [
        // Missing/failed/timed-out/cancelled required checks; reviewer
        // rejection; provider success without independent evidence.
        "missing-required-check",
        "failed-required-check",
        "timed-out-required-check",
        "cancelled-required-check",
        "reviewer-rejection",
        "provider-success-without-independent-evidence",
        // Tracked/untracked/ignored-input changes after verification and
        // mutations during checks/review.
        "changes-after-verification",
        "mutation-during-check-or-review",
        // Missing/moved/wrong environments, expired/revoked grants,
        // unavailable tools, and provider authentication/capability loss.
        "missing-environment",
        "moved-environment",
        "wrong-environment",
        "expired-grant",
        "revoked-grant",
        "unavailable-check-tools",
        "transport-loss-degrades-execution",
        "provider-auth-capability-loss",
        // Duplicate, stale, foreign-task, and reordered requests/events;
        // lost responses; late completion after cancellation.
        "duplicate-events",
        "stale-events",
        "foreign-task-events",
        "reordered-events",
        "lost-responses",
        "late-completion-after-cancellation",
        // Crashes between invalidation, dispatch, round accounting,
        // evidence, and metadata writes.
        "crash-between-evidence-and-metadata-writes",
        "crash-between-dispatch-steps",
        "crash-between-round-accounting",
        "crash-between-invalidation",
        // Relaunch with a live channel, a dead process, unavailable
        // provider history, and an exhausted correction budget.
        "relaunch-live-channel",
        "relaunch-dead-process",
        "relaunch-unavailable-provider-history",
        "relaunch-exhausted-correction-budget",
        // Output/event pressure and task scheduling at and beyond the
        // documented limit.
        "event-pressure-at-limit",
        "event-pressure-beyond-limit",
        "run-history-pressure",
    ]

    @Test("the fixture covers every required negative scenario exactly once")
    func fixtureCoversEveryRequiredScenario() throws {
        let fixture = try loadFixture()
        #expect(fixture.schemaVersion == 1)
        #expect(fixture.fixtureVersion == "ade-negative-scenarios-v1")
        #expect(fixture.coverageValues == ["existing", "added", "pending"])

        let ids = Set(fixture.scenarios.map(\.id))
        #expect(
            ids.count == fixture.scenarios.count,
            "duplicate scenario ids in the fixture"
        )
        let missing = Self.requiredScenarioIDs.subtracting(ids)
        #expect(
            missing.isEmpty,
            "silently skipped scenarios: \(missing.sorted())"
        )
        let unowned = ids.subtracting(Self.requiredScenarioIDs)
        #expect(
            unowned.isEmpty,
            "fixture rows without a required-scenario owner: \(unowned.sorted())"
        )
        for row in fixture.scenarios {
            #expect(!row.scenario.isEmpty, "\(row.id): empty scenario")
            #expect(!row.expected.isEmpty, "\(row.id): empty expectation")
            switch row.coverage {
            case "existing", "added":
                #expect(
                    row.evidence?.isEmpty == false,
                    "\(row.id): \(row.coverage) row must name its test"
                )
                #expect(row.owner == nil, "\(row.id): covered row has no owner")
            case "pending":
                #expect(
                    row.owner?.isEmpty == false,
                    "\(row.id): pending row must name its owning branch"
                )
                #expect(
                    row.evidence == nil,
                    "\(row.id): pending row must not claim test evidence"
                )
            default:
                Issue.record("\(row.id): unknown coverage \(row.coverage)")
            }
        }
    }

    @Test("every existing and added row cites a test that exists in this base")
    func citedTestsExist() throws {
        let fixture = try loadFixture()
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        for row in fixture.scenarios where row.coverage != "pending" {
            let evidence = try #require(row.evidence, "\(row.id): no evidence")
            // "PineTests/SomeFile.swift — funcA; funcB"
            let parts = evidence.components(separatedBy: "\u{2014}")
            #expect(parts.count == 2, "\(row.id): unparsable evidence \(evidence)")
            let fileName = parts[0].trimmingCharacters(in: .whitespaces)
            let fileURL = repository.appendingPathComponent(fileName)
            #expect(fileURL.isFileURL && FileManager.default.fileExists(atPath: fileURL.path), "\(row.id): missing \(fileName)")
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            let functions = parts[1]
                .components(separatedBy: ";")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            #expect(!functions.isEmpty, "\(row.id): evidence names no test")
            for function in functions {
                #expect(
                    content.contains("func \(function)("),
                    "\(row.id): cited test \(function) not found in \(fileName)"
                )
            }
        }
    }

    @Test("added scenarios are exactly the tests this suite executes")
    func addedRowsMatchThisSuite() throws {
        let fixture = try loadFixture()
        let added = fixture.scenarios.filter { $0.coverage == "added" }
        #expect(
            added.map(\.id).sorted() == ["late-completion-after-cancellation"],
            "added rows must stay in lockstep with this suite"
        )
    }

    // MARK: - Added scenario execution

    private func hex(_ digit: Character) -> String {
        String(repeating: String(digit), count: 64)
    }

    private func codeState(
        _ tag: Character,
        head: String = String(repeating: "b", count: 40)
    ) -> AgentTaskCodeStateIdentity {
        AgentTaskCodeStateIdentity(
            headCommit: head,
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

    private func project(_ path: String) -> AgentTaskProjectIdentity {
        AgentTaskProjectIdentity(
            canonicalProjectPath: URL(fileURLWithPath: path)
                .standardizedFileURL.path,
            canonicalWorktreePath: URL(fileURLWithPath: path)
                .standardizedFileURL.path
        )
    }

    private func uuid(_ seed: Int) -> UUID {
        let suffix = String(format: "%012llX", UInt64(seed))
        return UUID(uuidString: "00000000-0000-0000-0000-\(suffix)")
            ?? UUID()
    }

    /// One terminated attempt with honest chronology, as production
    /// settlement produces it (process-completion fact bound, outcome
    /// settled). `now` pins timestamps so registry loads do not trip the
    /// seven-day retention sweep.
    private func settledTask(seed: Int) -> AgentTask {
        let now = Date(timeIntervalSince1970: 1_000)
        let context = AgentTaskBridgeContext(
            project: project("/tmp/pine-ade-\(seed)"),
            route: AgentTaskRoute(
                paneID: uuid(seed),
                tabID: uuid(seed + 100),
                terminalID: uuid(seed + 100),
                availability: .missing
            ),
            origin: .discoveredInTerminal,
            observedAt: now
        )
        var task = AgentTask(
            descriptor: AgentDescriptor(agentType: .claudeCode),
            context: context
        )
        var run = AgentTaskRun(AgentTaskRunInput(
            id: uuid(seed + 200),
            terminalID: uuid(seed + 100),
            process: AgentProcessEvidence(
                processIdentifier: Int32(5_000 + seed),
                processGeneration: UInt64(seed),
                startIdentifier: "ade-\(seed)",
                observedStartedAt: now.addingTimeInterval(-300),
                startIsAuthoritative: true
            ),
            status: AgentTaskRunStatus(
                state: .done,
                liveness: .terminated,
                observedAt: now
            )
        ))
        task.runs = [run]
        task.lifecycle = .paused
        task.updatedAt = now
        task.lastActivityAt = now
        task.executionState = AgentTaskLifecycleReducer.executionState(for: task)
        AgentTaskLifecycleReducer.settleTerminated(task: &task, runIndex: 0)
        return task
    }

    private func fact(
        _ kind: AgentTaskEvidenceKind,
        runID: UUID,
        generation: UInt64,
        result: AgentTaskEvidenceResult,
        at: Date,
        trust: TrustLevel = .verified,
        codeState: AgentTaskCodeStateIdentity? = nil,
        environment: AgentTaskEnvironmentIdentity? = nil,
        sequence: UInt64? = nil
    ) -> AgentTaskEvidenceFact {
        AgentTaskEvidenceFact(
            kind: kind,
            runID: runID,
            processGeneration: generation,
            trust: trust,
            result: result,
            observedAt: at,
            codeState: codeState,
            environment: environment,
            sourceSequence: sequence
        )
    }

    /// late-completion-after-cancellation: the provider reports completion
    /// after the user already cancelled the attempt. The late claim is
    /// admitted as history, but cancellation wins the settlement and the
    /// task never becomes Ready or flips to another outcome.
    @Test("late completion after cancellation keeps the cancellation outcome")
    func lateCompletionAfterCancellationCannotFlipOutcome() throws {
        let registry = AgentTaskRegistry()
        let task = settledTask(seed: 771)
        registry.setTasksForTesting([task])
        let run = try #require(task.runs.first)
        let now = task.lastActivityAt
        let code = codeState("a")
        let env = environment

        #expect(
            registry.recordEvidence(
                fact(
                    .userCancellation,
                    runID: run.id,
                    generation: 771,
                    result: .cancelled,
                    at: now
                ),
                taskID: task.id
            ) == .accepted
        )
        let cancelled = try #require(registry.task(for: task.id))
        #expect(cancelled.runs.last?.outcome == .cancellation)
        #expect(cancelled.lifecycle == .paused)

        // The provider's completion claim arrives after the cancellation.
        #expect(
            registry.recordEvidence(
                fact(
                    .agentReportedCompletion,
                    runID: run.id,
                    generation: 771,
                    result: .reported,
                    at: now.addingTimeInterval(30),
                    codeState: code,
                    environment: env,
                    sequence: 1
                ),
                taskID: task.id
            ) == .accepted
        )
        let after = try #require(registry.task(for: task.id))
        #expect(after.runs.last?.outcome == .cancellation)
        #expect(after.lifecycle == .paused)
        #expect(after.attention == .none)
        #expect(after.completedAt == nil)
        let readiness = registry.readiness(
            for: task.id,
            codeState: code,
            environment: env
        )
        #expect(!readiness.isReady)
        #expect(readiness.gaps.contains(.cancelledAttempt))
    }
}
