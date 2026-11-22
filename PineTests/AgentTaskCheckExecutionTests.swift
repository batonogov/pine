import Foundation
import Testing
@testable import Pine

@MainActor
struct AgentTaskCheckExecutionTests {
    private var code: AgentTaskCodeStateIdentity {
        AgentTaskCodeStateIdentity(
            headCommit: String(repeating: "a", count: 40), trackedFingerprint: String(repeating: "b", count: 64),
            untrackedFingerprint: String(repeating: "c", count: 64), ignoredRelevantFingerprint: String(repeating: "d", count: 64)
        )
    }
    private var environment: AgentTaskEnvironmentIdentity {
        AgentTaskEnvironmentIdentity(osBuild: "26B131", toolchain: "test", configurationFingerprint: String(repeating: "e", count: 64))
    }

    private func journal() -> AgentTaskCheckExecution {
        AgentTaskCheckExecution(
            id: UUID(), runID: UUID(), processGeneration: 1, passID: UUID(), attempt: 1, grantID: UUID(),
            planFingerprint: String(repeating: "f", count: 64),
            requiredCommands: [String(repeating: "1", count: 64), String(repeating: "2", count: 64)],
            code: code, environment: environment
        )
    }

    private func operation(
        _ digit: String, status: AgentTaskCheckExecution.Status = .succeeded, required: Bool = true,
        matched: Bool = true
    ) -> AgentTaskCheckExecution.Operation {
        .init(
            id: UUID(), commandFingerprint: String(repeating: digit, count: 64), required: required,
            startedAt: Date(timeIntervalSince1970: 10), finishedAt: Date(timeIntervalSince1970: 11),
            status: status, exitCode: status == .succeeded ? 0 : 1, identitiesMatched: matched
        )
    }

    private func fact(_ journal: AgentTaskCheckExecution, executionID: UUID?) -> AgentTaskEvidenceFact {
        AgentTaskEvidenceFact(
            kind: .independentCheck, runID: journal.runID, processGeneration: journal.processGeneration,
            trust: .verified, result: journal.passed ? .succeeded : .failed, observedAt: Date(),
            codeState: journal.code, environment: journal.environment, preOperationCodeState: journal.code,
            postOperationCodeState: journal.code, checkExecutionID: executionID
        )
    }

    @Test func requiredSetCannotBeReplacedByOptionalHistoricalOrIncompleteSuccess() {
        var value = journal()
        #expect(!value.passed)
        value.operations = [operation("1"), operation("3", required: false)]
        value.completed = true
        #expect(!value.passed)
        value.operations.append(operation("2", status: .failed))
        #expect(!value.passed)
        #expect(value.isJudgment)
        value.operations = [operation("1"), operation("2")]
        value.completed = false
        #expect(!value.passed)
        value.completed = true
        #expect(value.passed)
        #expect(value.authorizes(fact(value, executionID: value.id)))
        #expect(!value.authorizes(fact(value, executionID: UUID())))
        #expect(!value.authorizes(fact(value, executionID: nil)))
    }

    @Test func changedOrUnavailableIdentitiesNeverEstablishPassingOperations() {
        for status in [AgentTaskCheckExecution.Status.identityChanged, .identityUnavailable, .authorityChanged, .cancelled] {
            var value = journal()
            value.operations = [operation("1"), operation("2", status: status, matched: false)]
            value.completed = true
            #expect(!value.passed)
            #expect(!value.isJudgment)
        }
        var value = journal()
        value.completed = true
        value.operations = [operation("1"), operation("2", matched: false)]
        #expect(!value.passed)
        var empty = AgentTaskCheckExecution(
            id: UUID(), runID: value.runID, processGeneration: 1, passID: value.passID, attempt: 1,
            grantID: value.grantID, planFingerprint: value.planFingerprint, requiredCommands: [],
            code: code, environment: environment
        )
        empty.completed = true
        #expect(!empty.passed)
    }

    @Test func processOutcomesRetainDistinctFailureReasons() {
        let outcomes: [(UserTaskOutcome, Bool, AgentTaskCheckExecution.Status)] = [
            (UserTaskOutcome(taskID: "test", stdout: "", stderr: "", exitCode: 0, timedOut: false), false, .succeeded),
            (UserTaskOutcome(taskID: "test", stdout: "", stderr: "", exitCode: 7, timedOut: false), false, .failed),
            (UserTaskOutcome(taskID: "test", stdout: "", stderr: "", exitCode: 0, timedOut: true), false, .timedOut),
            (UserTaskOutcome(taskID: "test", stdout: "", stderr: "", exitCode: 0, timedOut: false), true, .cancelled),
            (UserTaskOutcome(taskID: "test", stdout: "", stderr: "", exitCode: -1, timedOut: false), false, .launchFailed),
            (UserTaskOutcome(taskID: "test", stdout: "", stderr: "", exitCode: 0, timedOut: false,
                             outputCaptureSucceeded: false), false, .outputUnavailable),
            (UserTaskOutcome(taskID: "test", stdout: "", stderr: "", exitCode: 0, timedOut: false,
                             cleanupSucceeded: false), false, .cleanupFailed),
            (UserTaskOutcome(taskID: "test", stdout: "", stderr: "", exitCode: -1, timedOut: false,
                             preSpawnRejected: true), false, .authorityChanged)
        ]
        for (outcome, cancelled, status) in outcomes {
            #expect(AgentTaskCheckExecutor.classify(outcome, cancelled: cancelled) == status)
        }
    }

    @Test func journalRoundTripContainsNoRawCommandOrDiagnosticOutput() throws {
        var value = journal()
        value.operations = [operation("1"), operation("2")]
        value.completed = true
        let data = try JSONEncoder().encode(value)
        #expect(try JSONDecoder().decode(AgentTaskCheckExecution.self, from: data) == value)
        let text = try #require(String(data: data, encoding: .utf8))
        for key in ["arguments", "stdout", "stderr", "executable", "workingDirectory", "environmentValues"] {
            #expect(!text.contains("\"\(key)\""))
        }
    }

    @Test func completedNonjudgmentProblemUsesUnresolvedRequiredOperation() {
        for status in [AgentTaskCheckExecution.Status.timedOut, .launchFailed, .outputUnavailable] {
            var value = journal()
            value.operations = [operation("1", status: status, matched: false), operation("2")]
            value.completed = true
            #expect(value.problem == status)
            #expect(value.problem != .succeeded)
        }
    }

    @Test func observationBindsEveryOperationAndWithholdsPostIdentityForNonjudgment() throws {
        var value = journal()
        value.operations = [operation("1"), operation("2")]
        value.completed = true
        let taskID = UUID()
        let observation = try #require(value.observation(taskID: taskID))
        #expect(observation.executionID == value.id)
        #expect(observation.passID == value.passID)
        #expect(observation.planFingerprint == value.planFingerprint)
        #expect(observation.processGeneration == value.processGeneration)
        #expect(observation.results.map(\.operationID) == value.operations.map(\.id))
        #expect(observation.results.map(\.fingerprint) == value.operations.map(\.commandFingerprint))
        #expect(observation.isJudgment && observation.requiredSucceeded)
        value.operations[1] = operation("2", status: .timedOut, matched: false)
        let timedOut = try #require(value.observation(taskID: taskID))
        #expect(!timedOut.isJudgment)
        #expect(timedOut.postCodeState == nil)
    }
}
