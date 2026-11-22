import Foundation
import Synchronization
import Testing
@testable import Pine

nonisolated private struct CheckPortFailure: Error {}
nonisolated private struct CheckCaptureFailure: Error {
    let result: String
}

/// The executor is driven only from this MainActor-serialized suite, so a
/// plain holder is safe to send to the main queue from @Sendable callbacks.
/// The strict cross-toolchain send checker rejects Mutex<AgentTaskCheckExecutor?>
/// because the executor's mutable state is not Sendable.
private final class ExecutorHolder: @unchecked Sendable {
    var executor: AgentTaskCheckExecutor?
}

@MainActor
@Suite(.serialized)
struct AgentTaskCheckExecutorIntegrationTests {
    private func replacementPlan(_ plan: AgentTaskCheckPlan) -> AgentTaskCheckPlan {
        AgentTaskCheckPlan(
            scheme: plan.scheme, recipeFingerprint: plan.recipeFingerprint,
            commands: plan.commands + [AgentTaskCheckCommand(
                id: "replacement", required: true, executable: URL(fileURLWithPath: "/usr/bin/true"),
                arguments: [], workingDirectory: "", timeout: 10
            )], capturePolicy: plan.capturePolicy, configurationFiles: plan.configurationFiles
        )
    }

    @Test func revokedGrantAndMissingToolNeverSpawn() async throws {
        let missing = AgentTaskCheckCommand(
            id: "missing", required: true, executable: URL(fileURLWithPath: "/pine-checks/missing-tool"),
            arguments: [], workingDirectory: "", timeout: 10
        )
        let prepared = try await PreparedChecks(commands: [missing], approvalTools: [URL(fileURLWithPath: "/usr/bin/true")])
        defer { prepared.fixture.remove() }
        let spawned = Mutex(0)
        let executor = AgentTaskCheckExecutor(
            registry: prepared.registry, bindings: prepared.bindings,
            runner: { timeout in UserTaskRunner(timeout: timeout, processDidSpawn: { _ in spawned.withLock { $0 += 1 } }) }
        )
        #expect(await executor.approve(taskID: prepared.task.id, plan: prepared.plan, environment: prepared.environment))
        #expect(await executor.revoke(taskID: prepared.task.id))
        #expect(await prepared.run(executor) == nil)
        #expect(spawned.withLock { $0 } == 0)
        #expect(await executor.approve(taskID: prepared.task.id, plan: prepared.plan, environment: prepared.environment))
        #expect(await prepared.run(executor) == nil)
        #expect(spawned.withLock { $0 } == 0)
        #expect(prepared.registry.task(for: prepared.task.id)?.checkProblem == .identityUnavailable)
        #expect(prepared.registry.task(for: prepared.task.id)?.checkExecution == nil)
    }

    @Test func literalArgumentsReachExecutableWithoutShellInterpolationOrAggregateEvidence() async throws {
        let fixture = try await runOnBackground { try CheckExecutorFixture() }
        let report = fixture.root.appending(path: "argv-report")
        let payload = [";", "$(echo pwned)", "`id`", "", "é✓", "-leading dash"]
        let perl = """
            my $report = shift @ARGV;
            open my $out, '>', $report or die "argv-report-open";
            for my $arg (@ARGV) { print $out $arg, "\\n" or die "argv-report-write"; }
            close $out or die "argv-report-close";
            """
        let command = AgentTaskCheckCommand(
            id: "argv", required: true, executable: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["-i", "PATH=/usr/bin:/bin", "/usr/bin/perl", "-e", perl, report.path] + payload,
            workingDirectory: "", timeout: 10
        )
        let prepared = try await PreparedChecks(fixture: fixture, commands: [command])
        defer { fixture.remove() }
        let executor = AgentTaskCheckExecutor(registry: prepared.registry, bindings: prepared.bindings)
        #expect(await executor.approve(taskID: prepared.task.id, plan: prepared.plan, environment: prepared.environment))
        let observation = try #require(await prepared.run(executor))
        #expect(observation.requiredSucceeded && observation.isJudgment)
        let lines = try await runOnBackground {
            try String(contentsOf: report, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init)
        }
        #expect(lines == payload)
        let journal = try #require(prepared.registry.task(for: prepared.task.id)?.checkExecution)
        let wrongPassFact = AgentTaskEvidenceFact(
            kind: .independentCheck, runID: journal.runID, processGeneration: journal.processGeneration,
            trust: .verified, result: .succeeded, observedAt: Date(),
            codeState: journal.code, environment: journal.environment,
            preOperationCodeState: journal.code, postOperationCodeState: journal.code,
            checkExecutionID: journal.id
        )
        #expect(prepared.registry.recordEvidence(
            wrongPassFact, taskID: prepared.task.id, deferSettlement: true, verificationPassID: UUID()
        ) == .fencedOut(.unknownRun))
        #expect(prepared.registry.task(for: prepared.task.id)?.evidence.contains {
            $0.kind == .independentCheck
        } == false)
        #expect(!prepared.registry.readiness(
            for: prepared.task.id, codeState: observation.preCodeState, environment: observation.environment
        ).isReady)
    }

    @Test func realTimeoutIsAJournaledNonjudgment() async throws {
        let command = AgentTaskCheckCommand(
            id: "timeout", required: true, executable: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["30"], workingDirectory: "", timeout: 1
        )
        let prepared = try await PreparedChecks(commands: [command])
        defer { prepared.fixture.remove() }
        let executor = AgentTaskCheckExecutor(registry: prepared.registry, bindings: prepared.bindings)
        #expect(await executor.approve(taskID: prepared.task.id, plan: prepared.plan, environment: prepared.environment))
        let observation = try #require(await prepared.run(executor))
        #expect(observation.results.map(\.status) == [.timedOut])
        #expect(!observation.isJudgment)
        #expect(prepared.registry.task(for: prepared.task.id)?.checkProblem == .timedOut)
        #expect(prepared.registry.task(for: prepared.task.id)?.evidence.contains {
            $0.kind == .independentCheck
        } == false)
        let disk = await prepared.store.load(project: prepared.task.project)
        #expect(disk.tasks.first?.checkExecution?.operations.last?.status == .timedOut)
    }

    @Test func cancellationPersistsTerminalOperationWithoutEvidence() async throws {
        let command = AgentTaskCheckCommand(
            id: "wait", required: true, executable: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["30"], workingDirectory: "", timeout: 10
        )
        let prepared = try await PreparedChecks(commands: [command])
        defer { prepared.fixture.remove() }
        let spawned = Mutex<Int32?>(nil)
        let executor = AgentTaskCheckExecutor(
            registry: prepared.registry, bindings: prepared.bindings,
            runner: { timeout in UserTaskRunner(timeout: timeout, processDidSpawn: { pid in spawned.withLock { $0 = pid } }) }
        )
        #expect(await executor.approve(taskID: prepared.task.id, plan: prepared.plan, environment: prepared.environment))
        let passID = UUID()
        let run = prepared.task.runs[0]
        #expect(prepared.registry.markVerificationPending(
            taskID: prepared.task.id, expectedRunID: run.id,
            processGeneration: run.process.processGeneration, verificationPassID: passID
        ))
        let request = AgentTaskVerificationCheckRequest(
            taskID: prepared.task.id, runID: run.id, passID: passID,
            processGeneration: run.process.processGeneration, expected: prepared.snapshot, attempt: 1
        )
        let operation = Task {
            await executor.run(request: request, plan: prepared.plan, binding: prepared.binding, editor: prepared.editor)
        }
        #expect(await waitUntilMainActor({ spawned.withLock { $0 != nil } }, ceiling: .seconds(15)))
        operation.cancel()
        _ = await operation.value
        if let pid = spawned.withLock({ $0 }) {
            #expect(await runOnBackground { UserTaskProcessInspector.identity(for: pid) == nil })
        }
        prepared.registry.clearVerificationPending(
            taskID: prepared.task.id, runID: run.id,
            processGeneration: run.process.processGeneration, verificationPassID: passID
        )
        let disk = await prepared.store.load(project: prepared.task.project)
        #expect(disk.tasks.first?.checkExecution?.operations.last?.status == .cancelled)
        #expect(disk.tasks.first?.checkExecution?.completed == false)
        #expect(disk.tasks.first?.checkProblem == .cancelled)
        #expect(disk.tasks.first?.evidence.contains { $0.kind == .independentCheck } == false)
    }

    @Test func failingThenPassingRevisionProducesOnlyCoordinatorAggregateEvidence() async throws {
        let prepared = try await PreparedChecks()
        defer { prepared.fixture.remove() }
        let executor = AgentTaskCheckExecutor(registry: prepared.registry, bindings: prepared.bindings)
        #expect(await executor.approve(taskID: prepared.task.id, plan: prepared.plan, environment: prepared.environment))
        try await runOnBackground { try Data("FAIL\n".utf8).write(to: prepared.fixture.worktree.appending(path: "check.txt")) }
        let grantID = prepared.registry.task(for: prepared.task.id)?.checkGrant?.id
        let failed = await prepared.verify(executor)
        #expect(failed.status == .notReady && failed.reason == .checksFailed)
        let failedTask = try #require(prepared.registry.task(for: prepared.task.id))
        let failedJournal = try #require(failedTask.checkExecution)
        #expect(failedJournal.completed && !failedJournal.passed)
        #expect(failedJournal.operations.map(\.status) == [.succeeded, .failed])
        #expect(failedTask.evidence.last?.result == .failed)
        #expect(failedTask.evidence.last?.checkExecutionID == failedJournal.id)

        try await prepared.reviseToPassingCandidate()
        let passed = await prepared.verify(executor)
        #expect(passed.status == .ready)
        let passedTask = try #require(prepared.registry.task(for: prepared.task.id))
        let passedJournal = try #require(passedTask.checkExecution)
        #expect(passedJournal.passed && passedJournal.code != failedJournal.code)
        #expect(passedTask.checkGrant?.id == grantID)
        #expect(passedTask.evidence.contains {
            $0.kind == .independentCheck && $0.result == .succeeded && $0.checkExecutionID == passedJournal.id
        })
        let disk = await prepared.store.load(project: prepared.task.project)
        #expect(disk.tasks.first?.checkExecution == passedJournal)
        #expect(disk.tasks.first?.checkGrant?.id == grantID)
    }

    @Test func preSpawnIdentityChangeCreatesNoChild() async throws {
        let prepared = try await PreparedChecks()
        defer { prepared.fixture.remove() }
        let spawned = Mutex(0)
        var changed = false
        let executor = AgentTaskCheckExecutor(
            registry: prepared.registry, bindings: prepared.bindings,
            checkpoint: { point in
                if point == .beforeCommand && !changed {
                    changed = true
                    try? await runOnBackground {
                        try Data("PASS changed\n".utf8).write(to: prepared.fixture.worktree.appending(path: "check.txt"))
                    }
                }
            },
            runner: { timeout in UserTaskRunner(timeout: timeout, processDidSpawn: { _ in spawned.withLock { $0 += 1 } }) }
        )
        #expect(await executor.approve(taskID: prepared.task.id, plan: prepared.plan, environment: prepared.environment))
        let observation = try #require(await prepared.run(executor))
        #expect(observation.results.map(\.status) == [.identityChanged])
        #expect(!observation.isJudgment)
        #expect(spawned.withLock { $0 } == 0)
    }

    @Test func planReplacementInvalidatesPriorJournalBeforeAnotherLaunch() async throws {
        let prepared = try await PreparedChecks()
        defer { prepared.fixture.remove() }
        let executor = AgentTaskCheckExecutor(registry: prepared.registry, bindings: prepared.bindings)
        #expect(await executor.approve(taskID: prepared.task.id, plan: prepared.plan, environment: prepared.environment))
        #expect(await prepared.run(executor)?.requiredSucceeded == true)
        let replacement = AgentTaskCheckPlan(
            scheme: 1, recipeFingerprint: prepared.plan.recipeFingerprint,
            commands: prepared.plan.commands + [AgentTaskCheckCommand(
                id: "additional", required: true, executable: URL(fileURLWithPath: "/usr/bin/true"),
                arguments: [], workingDirectory: "", timeout: 10
            )], capturePolicy: prepared.plan.capturePolicy, configurationFiles: []
        )
        #expect(await executor.approve(taskID: prepared.task.id, plan: replacement, environment: prepared.environment))
        #expect(prepared.registry.task(for: prepared.task.id)?.checkExecution == nil)
        #expect(await prepared.run(executor, plan: prepared.plan) == nil)
    }

    @Test func planReplacementBeforeEvidenceFencesOldPassAndJournal() async throws {
        let prepared = try await PreparedChecks()
        defer { prepared.fixture.remove() }
        let executor = AgentTaskCheckExecutor(registry: prepared.registry, bindings: prepared.bindings)
        #expect(await executor.approve(taskID: prepared.task.id, plan: prepared.plan, environment: prepared.environment))
        let result = await prepared.verify(executor, onProbe: { call in
            if call == 2 {
                #expect(await executor.approve(
                    taskID: prepared.task.id, plan: replacementPlan(prepared.plan), environment: prepared.environment
                ))
            }
        })
        #expect(result.status != .ready)
        let task = try #require(prepared.registry.task(for: prepared.task.id))
        #expect(task.checkExecution == nil)
        #expect(!task.evidence.contains { $0.kind == .independentCheck })
        #expect(!prepared.registry.readiness(
            for: task.id, codeState: prepared.snapshot.code, environment: prepared.snapshot.environment
        ).isReady)
    }

    @Test(arguments: [
        AgentTaskCheckExecutor.Checkpoint.beforeFinalCapture,
        .beforeCompletedJournalWrite, .completedJournal
    ])
    func cancellationAtCompletionCheckpointIsTerminal(
        point: AgentTaskCheckExecutor.Checkpoint
    ) async throws {
        let prepared = try await PreparedChecks()
        defer { prepared.fixture.remove() }
        let spawned = Mutex(0)
        var cancel: (@MainActor () -> Void)?
        let executor = AgentTaskCheckExecutor(
            registry: prepared.registry, bindings: prepared.bindings,
            checkpoint: { checkpoint in
                if checkpoint == point { cancel?() }
            },
            runner: { timeout in UserTaskRunner(timeout: timeout, processDidSpawn: { _ in spawned.withLock { $0 += 1 } }) }
        )
        cancel = { executor.cancel(taskID: prepared.task.id) }
        #expect(await executor.approve(taskID: prepared.task.id, plan: prepared.plan, environment: prepared.environment))
        let result = await prepared.verify(executor)
        #expect(result.status == .cancelled)
        let task = try #require(prepared.registry.task(for: prepared.task.id))
        #expect(task.checkExecution?.attempt == 1)
        #expect(spawned.withLock { $0 } == 2)
        #expect(!task.evidence.contains { $0.kind == .independentCheck })
        #expect(!task.evidence.contains { $0.kind == .reviewerOutcome })
        #expect(!result.readiness.isReady)
        if point == .beforeFinalCapture {
            let disk = await prepared.store.load(project: prepared.task.project)
            #expect(disk.tasks.first?.checkProblem == .cancelled)
        }
    }

    @Test func cancellationDuringInitialCaptureIsTerminalWithoutJournalOrRetry() async throws {
        let prepared = try await PreparedChecks()
        defer { prepared.fixture.remove() }
        let spawned = Mutex(0)
        let holder = ExecutorHolder()
        let executor = AgentTaskCheckExecutor(
            registry: prepared.registry, bindings: prepared.bindings,
            runner: { timeout in UserTaskRunner(timeout: timeout, processDidSpawn: { _ in spawned.withLock { $0 += 1 } }) }
        )
        holder.executor = executor
        let entered = Mutex(false)
        let editor = AgentVerificationEditorPreflight.available([], isCurrent: {
            let shouldCancel = entered.withLock { value in
                if value { return false }
                value = true
                return true
            }
            if shouldCancel {
                DispatchQueue.main.async { holder.executor?.cancel(taskID: prepared.task.id) }
            }
            return true
        })
        #expect(await executor.approve(taskID: prepared.task.id, plan: prepared.plan, environment: prepared.environment))
        let result = await prepared.verify(executor, editor: editor)
        #expect(result.status == .cancelled)
        #expect(prepared.registry.task(for: prepared.task.id)?.checkExecution == nil)
        #expect(spawned.withLock { $0 } == 0)
    }

    @Test func cancellationDuringOptionalCommandPreventsRequiredSpawnAndRetry() async throws {
        let optional = AgentTaskCheckCommand(
            id: "optional-wait", required: false, executable: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["30"], workingDirectory: "", timeout: 10
        )
        let required = AgentTaskCheckCommand(
            id: "required-never-run", required: true, executable: URL(fileURLWithPath: "/usr/bin/true"),
            arguments: [], workingDirectory: "", timeout: 10
        )
        let prepared = try await PreparedChecks(commands: [optional, required])
        defer { prepared.fixture.remove() }
        let spawned = Mutex(0)
        let holder = ExecutorHolder()
        let executor = AgentTaskCheckExecutor(
            registry: prepared.registry, bindings: prepared.bindings,
            runner: { timeout in UserTaskRunner(timeout: timeout, processDidSpawn: { _ in
                if spawned.withLock({ $0 += 1; return $0 }) == 1 {
                    DispatchQueue.main.async { holder.executor?.cancel(taskID: prepared.task.id) }
                }
            }) }
        )
        holder.executor = executor
        #expect(await executor.approve(taskID: prepared.task.id, plan: prepared.plan, environment: prepared.environment))
        let result = await prepared.verify(executor)
        #expect(result.status == .cancelled)
        #expect(spawned.withLock { $0 } == 1)
        #expect(prepared.registry.task(for: prepared.task.id)?.checkExecution?.attempt == 1)
        #expect(prepared.registry.task(for: prepared.task.id)?.evidence.contains {
            $0.kind == .independentCheck
        } == false)
    }

    @Test(arguments: [false, true])
    func reviewTimeGrantChangeFencesFinalSettlement(replacePlan: Bool) async throws {
        let prepared = try await PreparedChecks()
        defer { prepared.fixture.remove() }
        let executor = AgentTaskCheckExecutor(registry: prepared.registry, bindings: prepared.bindings)
        #expect(await executor.approve(taskID: prepared.task.id, plan: prepared.plan, environment: prepared.environment))
        let entered = Mutex(false)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let operation = Task {
            await prepared.verify(executor, onReview: {
                await runOnBackground {
                    entered.withLock { $0 = true }
                    _ = release.wait(timeout: .now() + 30)
                }
            })
        }
        #expect(await waitUntilMainActor({ entered.withLock { $0 } }, ceiling: .seconds(15)))
        if replacePlan {
            #expect(await executor.approve(
                taskID: prepared.task.id, plan: replacementPlan(prepared.plan), environment: prepared.environment
            ))
        } else {
            #expect(await executor.revoke(taskID: prepared.task.id))
        }
        release.signal()
        let result = await operation.value
        #expect(result.status != .ready)
        #expect(!result.readiness.isReady)
        #expect(!prepared.registry.readiness(
            for: prepared.task.id, codeState: prepared.snapshot.code, environment: prepared.snapshot.environment
        ).isReady)
    }

    @Test func initialCaptureMismatchIsIdentityChanged() async throws {
        let prepared = try await PreparedChecks()
        defer { prepared.fixture.remove() }
        let executor = AgentTaskCheckExecutor(
            registry: prepared.registry, bindings: prepared.bindings,
            checkpoint: { point in
                if point == .invalidated {
                    try? await runOnBackground {
                        try Data("PASS initial change\n".utf8).write(to: prepared.fixture.worktree.appending(path: "check.txt"))
                    }
                }
            }
        )
        #expect(await executor.approve(taskID: prepared.task.id, plan: prepared.plan, environment: prepared.environment))
        #expect(await prepared.run(executor) == nil)
        #expect(prepared.registry.task(for: prepared.task.id)?.checkProblem == .identityChanged)
    }

    @Test func requiredTimeoutFollowedBySuccessRetainsTimeoutProblem() async throws {
        let timeout = AgentTaskCheckCommand(
            id: "required-timeout", required: true, executable: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["30"], workingDirectory: "", timeout: 1
        )
        let success = AgentTaskCheckCommand(
            id: "later-success", required: true, executable: URL(fileURLWithPath: "/usr/bin/true"),
            arguments: [], workingDirectory: "", timeout: 10
        )
        let prepared = try await PreparedChecks(commands: [timeout, success])
        defer { prepared.fixture.remove() }
        let executor = AgentTaskCheckExecutor(registry: prepared.registry, bindings: prepared.bindings)
        #expect(await executor.approve(taskID: prepared.task.id, plan: prepared.plan, environment: prepared.environment))
        let observation = try #require(await prepared.run(executor))
        #expect(observation.results.map(\.status) == [.timedOut, .succeeded])
        #expect(prepared.registry.task(for: prepared.task.id)?.checkProblem == .timedOut)
    }

    @Test func bindingRevocationDuringInitialCapturePreventsSpawn() async throws {
        let prepared = try await PreparedChecks()
        defer { prepared.fixture.remove() }
        let spawned = Mutex(0)
        let executor = AgentTaskCheckExecutor(
            registry: prepared.registry, bindings: prepared.bindings,
            runner: { timeout in UserTaskRunner(timeout: timeout, processDidSpawn: { _ in spawned.withLock { $0 += 1 } }) }
        )
        #expect(await executor.approve(taskID: prepared.task.id, plan: prepared.plan, environment: prepared.environment))
        let entered = Mutex(false)
        let editor = AgentVerificationEditorPreflight.available([], isCurrent: {
            let shouldRevoke = entered.withLock { value in
                if value { return false }
                value = true
                return true
            }
            if shouldRevoke {
                DispatchQueue.main.async {
                    Task { @MainActor in
                        await prepared.bindings.revoke(
                            taskID: prepared.task.id, runID: prepared.binding.reservationRunID
                        )
                    }
                }
            }
            return true
        })
        #expect(await prepared.run(executor, editor: editor) == nil)
        #expect(spawned.withLock { $0 } == 0)
        #expect(prepared.registry.task(for: prepared.task.id)?.checkProblem == .authorityChanged)
    }

    @Test func floodedRequiredOutputFollowedBySuccessRemainsOutputUnavailable() async throws {
        let fixture = try await runOnBackground { try CheckExecutorFixture() }
        defer { fixture.remove() }
        let flood = fixture.root.appending(path: "flood.txt")
        try await runOnBackground {
            try Data(String(repeating: "0123456789\n", count: 500_000).utf8).write(to: flood)
        }
        let commands = [
            AgentTaskCheckCommand(
                id: "flood", required: true, executable: URL(fileURLWithPath: "/bin/dd"),
                arguments: ["if=\(flood.path)", "bs=1048576"], workingDirectory: "", timeout: 30
            ),
            AgentTaskCheckCommand(
                id: "later-success", required: true, executable: URL(fileURLWithPath: "/usr/bin/true"),
                arguments: [], workingDirectory: "", timeout: 10
            )
        ]
        let prepared = try await PreparedChecks(fixture: fixture, commands: commands)
        let executor = AgentTaskCheckExecutor(registry: prepared.registry, bindings: prepared.bindings)
        #expect(await executor.approve(taskID: prepared.task.id, plan: prepared.plan, environment: prepared.environment))
        let observation = try #require(await prepared.run(executor))
        #expect(observation.results.map(\.status) == [.outputUnavailable, .succeeded])
        #expect(!observation.isJudgment)
        #expect(prepared.registry.task(for: prepared.task.id)?.checkProblem == .outputUnavailable)
        #expect(prepared.registry.task(for: prepared.task.id)?.evidence.contains {
            $0.kind == .independentCheck
        } == false)
    }

    @Test func midProcessIdentityChangeInvalidatesOperation() async throws {
        let script = "open my $f, '>', 'check.txt' or die; print {$f} \"PASS mid\\n\"; close $f;"
        let command = AgentTaskCheckCommand(
            id: "mutate", required: true, executable: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["-i", "PATH=/usr/bin:/bin", "/usr/bin/perl", "-e", script],
            workingDirectory: "", timeout: 10
        )
        let prepared = try await PreparedChecks(commands: [command])
        defer { prepared.fixture.remove() }
        let executor = AgentTaskCheckExecutor(registry: prepared.registry, bindings: prepared.bindings)
        #expect(await executor.approve(taskID: prepared.task.id, plan: prepared.plan, environment: prepared.environment))
        let observation = try #require(await prepared.run(executor))
        #expect(observation.results.map(\.status) == [.identityChanged])
        #expect(!observation.isJudgment)
        #expect(prepared.registry.task(for: prepared.task.id)?.evidence.contains {
            $0.kind == .independentCheck
        } == false)
    }

    @Test func postProcessCaptureIdentityChangeInvalidatesOperation() async throws {
        let prepared = try await PreparedChecks()
        defer { prepared.fixture.remove() }
        let executor = AgentTaskCheckExecutor(
            registry: prepared.registry, bindings: prepared.bindings,
            captureAfterProcess: { capture in
                try? await runOnBackground {
                    try Data("PASS post-process\n".utf8).write(to: prepared.fixture.worktree.appending(path: "check.txt"))
                }
                return await capture.capture()
            }
        )
        #expect(await executor.approve(taskID: prepared.task.id, plan: prepared.plan, environment: prepared.environment))
        let observation = try #require(await prepared.run(executor))
        #expect(observation.results.map(\.status) == [.identityChanged])
        #expect(!observation.isJudgment)
    }

    enum FinalCaptureScenario: Sendable {
        case changed, unavailable
    }

    @Test(arguments: [FinalCaptureScenario.changed, .unavailable])
    func finalCaptureFailurePersistsAccurateProblem(scenario: FinalCaptureScenario) async throws {
        let prepared = try await PreparedChecks()
        defer { prepared.fixture.remove() }
        let executor = AgentTaskCheckExecutor(
            registry: prepared.registry, bindings: prepared.bindings,
            checkpoint: { point in
                if point == .beforeFinalCapture {
                    try? await runOnBackground {
                        switch scenario {
                        case .changed:
                            try Data("PASS final-change\n".utf8).write(
                                to: prepared.fixture.worktree.appending(path: "check.txt")
                            )
                        case .unavailable:
                            try FileManager.default.createSymbolicLink(
                                at: prepared.fixture.worktree.appending(path: "unsupported-final-input"),
                                withDestinationURL: URL(fileURLWithPath: "/etc/passwd")
                            )
                        }
                    }
                }
            }
        )
        #expect(await executor.approve(taskID: prepared.task.id, plan: prepared.plan, environment: prepared.environment))
        #expect(await prepared.run(executor) != nil)
        let expected: AgentTaskCheckExecution.Status = scenario == .changed ? .identityChanged : .identityUnavailable
        #expect(prepared.registry.task(for: prepared.task.id)?.checkProblem == expected)
        let disk = await prepared.store.load(project: prepared.task.project)
        #expect(disk.tasks.first?.checkProblem == expected)
    }

    @Test func duplicateProcessCompletionResumesOnceAndProducesOneAggregate() async throws {
        let prepared = try await PreparedChecks(commands: [AgentTaskCheckCommand(
            id: "single", required: true, executable: URL(fileURLWithPath: "/usr/bin/true"),
            arguments: [], workingDirectory: "", timeout: 10
        )])
        defer { prepared.fixture.remove() }
        let executor = AgentTaskCheckExecutor(
            registry: prepared.registry, bindings: prepared.bindings,
            progress: { progress in
                UserTaskProgress(onFinish: { outcome, cancelled in
                    progress.onFinish?(outcome, cancelled)
                    progress.onFinish?(outcome, cancelled)
                })
            }
        )
        #expect(await executor.approve(taskID: prepared.task.id, plan: prepared.plan, environment: prepared.environment))
        let result = await prepared.verify(executor)
        #expect(result.status == .ready)
        let task = try #require(prepared.registry.task(for: prepared.task.id))
        #expect(task.checkExecution?.operations.count == prepared.plan.commands.count)
        #expect(task.evidence.filter { $0.kind == .independentCheck }.count == 1)
    }

    @Test func duplicateCompletedJournalWriteIsRejected() async throws {
        let prepared = try await PreparedChecks()
        defer { prepared.fixture.remove() }
        let rejected = Mutex(false)
        let executor = AgentTaskCheckExecutor(
            registry: prepared.registry, bindings: prepared.bindings,
            checkpoint: { point in
                if point == .completedJournal, let journal = prepared.registry.task(for: prepared.task.id)?.checkExecution {
                    let accepted = await prepared.registry.persistCheckExecution(
                        journal, taskID: prepared.task.id, replacing: journal.id
                    )
                    rejected.withLock { $0 = !accepted }
                }
            }
        )
        #expect(await executor.approve(taskID: prepared.task.id, plan: prepared.plan, environment: prepared.environment))
        #expect(await prepared.run(executor)?.requiredSucceeded == true)
        #expect(rejected.withLock { $0 })
    }

    @Test func uncertainCleanupQuarantinesRetryUntilShutdownReaping() async throws {
        let command = AgentTaskCheckCommand(
            id: "cleanup", required: true, executable: URL(fileURLWithPath: "/usr/bin/true"),
            arguments: [], workingDirectory: "", timeout: 10
        )
        let prepared = try await PreparedChecks(commands: [command])
        defer { prepared.fixture.remove() }
        let workers = CheckHoldingIOWorkers()
        defer { workers.release() }
        let executor = AgentTaskCheckExecutor(
            registry: prepared.registry, bindings: prepared.bindings,
            runner: { timeout in UserTaskRunner(
                timeout: timeout,
                ioExecutionPolicy: UserTaskIOExecutionPolicy(
                    workerScheduler: workers, startupDeadline: 0.2, shutdownDeadline: 0
                ), maximumConcurrentExecutions: 1
            ) }
        )
        #expect(await executor.approve(taskID: prepared.task.id, plan: prepared.plan, environment: prepared.environment))
        let observation = try #require(await prepared.run(executor))
        #expect(observation.results.map(\.status) == [.cleanupFailed])
        #expect(await prepared.run(executor) == nil)
        #expect(await prepared.registry.shutdownCheckExecutions(until: .now() + 0.1) == false)
        workers.release()
        #expect(await prepared.registry.shutdownCheckExecutions(until: .now() + 15))
        #expect(prepared.registry.checkShutdownIsPrepared)
    }

    enum CheckMutation: Sendable {
        case selection, problem, execution, cancelledProblem, cancelledOperation
    }

    @Test(arguments: [
        CheckMutation.selection, .problem, .execution, .cancelledProblem, .cancelledOperation
    ])
    func taskRemovalObserverFencesCheckStateMutation(mutation: CheckMutation) async throws {
        let prepared = try await PreparedChecks()
        defer { prepared.fixture.remove() }
        let executor = AgentTaskCheckExecutor(registry: prepared.registry, bindings: prepared.bindings)
        if mutation != .selection {
            #expect(await executor.approve(taskID: prepared.task.id, plan: prepared.plan, environment: prepared.environment))
        }
        let run = prepared.task.runs[0]
        let passID = UUID()
        let owner = AgentTaskCheckAuthority()
        if mutation != .selection {
            #expect(prepared.registry.markVerificationPending(
                taskID: prepared.task.id, expectedRunID: run.id,
                processGeneration: run.process.processGeneration, verificationPassID: passID
            ))
            #expect(prepared.registry.claimCheckRun(taskID: prepared.task.id, owner: owner))
        }
        let grant = prepared.registry.task(for: prepared.task.id)?.checkGrant ?? AgentTaskCheckGrant(
            scheme: 1, id: UUID(), taskID: prepared.task.id, planFingerprint: prepared.plan.fingerprint,
            environment: prepared.environment, approvedAt: run.startedAt, revokedAt: nil
        )
        let command = prepared.plan.commands[0].fingerprint
        var journal = AgentTaskCheckExecution(
            id: UUID(), runID: run.id, processGeneration: run.process.processGeneration,
            passID: passID, attempt: 1, grantID: grant.id, planFingerprint: prepared.plan.fingerprint,
            requiredCommands: [command], code: prepared.snapshot.code, environment: prepared.snapshot.environment
        )
        if mutation == .cancelledOperation {
            #expect(await prepared.registry.persistCheckExecution(journal, taskID: prepared.task.id, replacing: nil))
            journal.operations.append(.init(
                id: UUID(), commandFingerprint: command, required: true,
                startedAt: Date(), finishedAt: Date(), status: .cancelled,
                exitCode: nil, identitiesMatched: false
            ))
        }
        let notified = Mutex(false)
        let observer = prepared.registry.addTaskChangeObserver { _, _ in
            if notified.withLock({ value in
                if value { return false }
                value = true
                return true
            }) {
                prepared.registry.setTasksForTesting([])
            }
        }
        defer { prepared.registry.removeTaskChangeObserver(observer) }
        switch mutation {
        case .selection:
            #expect(await executor.approve(
                taskID: prepared.task.id, plan: prepared.plan, environment: prepared.environment
            ) == false)
        case .problem:
            await prepared.registry.persistCheckProblem(
                .identityChanged, taskID: prepared.task.id, runID: run.id, grantID: grant.id
            )
        case .execution:
            #expect(await prepared.registry.persistCheckExecution(
                journal, taskID: prepared.task.id, replacing: nil
            ) == false)
        case .cancelledProblem:
            let write = Task {
                await prepared.registry.persistCancelledCheckProblem(
                    taskID: prepared.task.id, runID: run.id, grant: grant,
                    executionID: nil, owner: owner
                )
            }
            write.cancel()
            #expect(await write.value == false)
        case .cancelledOperation:
            let write = Task {
                await prepared.registry.persistCancelledCheckOperation(
                    journal, taskID: prepared.task.id, owner: owner
                )
            }
            write.cancel()
            #expect(await write.value == false)
        }
        #expect(notified.withLock { $0 })
        #expect(prepared.registry.task(for: prepared.task.id) == nil)
        prepared.registry.finishCheckRun(taskID: prepared.task.id)
        owner.finish()
    }

    @Test(arguments: [true, false])
    func generationReplacementFencesResetAndProblemWrites(reset: Bool) async throws {
        let prepared = try await PreparedChecks()
        defer { prepared.fixture.remove() }
        let executor = AgentTaskCheckExecutor(registry: prepared.registry, bindings: prepared.bindings)
        #expect(await executor.approve(taskID: prepared.task.id, plan: prepared.plan, environment: prepared.environment))
        let run = prepared.task.runs[0]
        let passID = UUID()
        #expect(prepared.registry.markVerificationPending(
            taskID: prepared.task.id, expectedRunID: run.id,
            processGeneration: run.process.processGeneration, verificationPassID: passID
        ))
        let owner = AgentTaskCheckAuthority()
        #expect(prepared.registry.claimCheckRun(taskID: prepared.task.id, owner: owner))
        let grant = try #require(prepared.registry.task(for: prepared.task.id)?.checkGrant)
        var replacement = try #require(prepared.registry.task(for: prepared.task.id))
        replacement.runs[0].process = AgentProcessEvidence(
            processIdentifier: 9_001, processGeneration: run.process.processGeneration + 1,
            startIdentifier: "replacement-generation", observedStartedAt: Date(), startIsAuthoritative: true
        )
        prepared.registry.setTasksForTesting([replacement])
        if reset {
            #expect(await prepared.registry.persistCheckSelection(
                grant, taskID: prepared.task.id, resettingExecution: true
            ) == false)
        } else {
            await prepared.registry.persistCheckProblem(
                .identityChanged, taskID: prepared.task.id, runID: run.id, grantID: grant.id
            )
        }
        #expect(prepared.registry.task(for: prepared.task.id) == replacement)
        prepared.registry.finishCheckRun(taskID: prepared.task.id)
        owner.finish()
    }

    @Test func revocationDuringCompletedJournalFlushCannotPublishReady() async throws {
        let armed = Mutex(false)
        let entered = Mutex(false)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let hooks = AgentTaskStoreHooks(phase: { phase in
            if phase == .beforeAtomicRename, armed.withLock({ value in
                let previous = value
                value = false
                return previous
            }) {
                entered.withLock { $0 = true }
                _ = release.wait(timeout: .now() + 30)
            }
        })
        let prepared = try await PreparedChecks(hooks: hooks)
        defer { prepared.fixture.remove() }
        let executor = AgentTaskCheckExecutor(
            registry: prepared.registry, bindings: prepared.bindings,
            checkpoint: { point in
                if point == .beforeCompletedJournalWrite { armed.withLock { $0 = true } }
            }
        )
        #expect(await executor.approve(taskID: prepared.task.id, plan: prepared.plan, environment: prepared.environment))
        let operation = Task { await prepared.verify(executor) }
        #expect(await waitUntilMainActor({ entered.withLock { $0 } }, ceiling: .seconds(15)))
        #expect(await executor.revoke(taskID: prepared.task.id) == false)
        release.signal()
        let result = await operation.value
        #expect(result.status != .ready)
        #expect(!result.readiness.isReady)
        let task = try #require(prepared.registry.task(for: prepared.task.id))
        #expect(!task.evidence.contains { $0.kind == .independentCheck })
        #expect(!task.evidence.contains { $0.kind == .reviewerOutcome })
    }

    @Test(arguments: [
        AgentTaskCheckExecutor.Checkpoint.operationFinished,
        .beforeCompletedJournalWrite, .completedJournal
    ])
    func writeFailuresRestoreOnlyDurablePrefixWithoutAggregateEvidence(
        point: AgentTaskCheckExecutor.Checkpoint
    ) async throws {
        let armed = Mutex(false)
        let hits = Mutex(0)
        let injector = PersistenceFaultInjector { store, phase in
            if store == .agentTask, phase == .beforeAtomicReplace, armed.withLock({ $0 }) {
                hits.withLock { $0 += 1 }
                throw PersistenceFailureKind.interrupted
            }
        }
        let prepared = try await PreparedChecks(faultInjector: injector)
        defer { prepared.fixture.remove() }
        let executor = AgentTaskCheckExecutor(
            registry: prepared.registry, bindings: prepared.bindings,
            checkpoint: { checkpoint in
                if checkpoint == point { armed.withLock { $0 = true } }
            }
        )
        #expect(await executor.approve(taskID: prepared.task.id, plan: prepared.plan, environment: prepared.environment))
        let result = await prepared.verify(executor)
        #expect(result.status != .ready)
        #expect(hits.withLock { $0 } > 0)
        // Settle the first registry's in-flight save before a second store
        // opens the same path (otherwise the restored load is rejected with
        // lockContention). The fault injector is still armed, so the flush
        // itself may fail — we only need the save attempt to finish and
        // release the flock, not a successful save.
        _ = await prepared.registry.flushPersistence(project: prepared.task.project)
        let fresh = AgentTaskMetadataStore(
            storageRoot: prepared.fixture.root.appending(path: "metadata"),
            configuration: AgentTaskStoreConfiguration(privateComponentCount: 1, faultInjector: .none)
        )
        let disk = await fresh.load(project: prepared.task.project)
        #expect(disk.status == .loaded)
        let task = try #require(disk.tasks.first)
        #expect(!task.evidence.contains { $0.kind == .independentCheck })
        if point == .operationFinished { #expect(task.checkExecution?.completed == false) }
        if point == .beforeCompletedJournalWrite { #expect(task.checkExecution?.completed == false) }
        if point == .completedJournal { #expect(task.checkExecution?.completed == true) }
        let restored = AgentTaskRegistry(persistence: fresh)
        #expect(await restored.prepareDurableWork(in: prepared.task.project))
        #expect(!restored.readiness(
            for: prepared.task.id, codeState: prepared.snapshot.code, environment: prepared.snapshot.environment
        ).isReady)
    }

    @Test func relaunchRestoresRealJournalWithoutStartingProcessOrReady() async throws {
        let prepared = try await PreparedChecks()
        defer { prepared.fixture.remove() }
        let spawned = Mutex(0)
        let executor = AgentTaskCheckExecutor(
            registry: prepared.registry, bindings: prepared.bindings,
            runner: { timeout in UserTaskRunner(timeout: timeout, processDidSpawn: { _ in spawned.withLock { $0 += 1 } }) }
        )
        #expect(await executor.approve(taskID: prepared.task.id, plan: prepared.plan, environment: prepared.environment))
        let result = await prepared.verify(executor)
        #expect(result.status == .ready)
        let journal = try #require(prepared.registry.task(for: prepared.task.id)?.checkExecution)
        let count = spawned.withLock { $0 }
        // The first registry must finish its pending save before the
        // restored store opens the same path (otherwise the load is
        // rejected with lockContention under load).
        #expect(await prepared.registry.flushPersistence(project: prepared.task.project) == .saved)
        let fresh = AgentTaskMetadataStore(
            storageRoot: prepared.fixture.root.appending(path: "metadata"),
            configuration: AgentTaskStoreConfiguration(privateComponentCount: 1, faultInjector: .none)
        )
        let restored = AgentTaskRegistry(persistence: fresh)
        #expect(await restored.prepareDurableWork(in: prepared.task.project))
        let task = try #require(restored.task(for: prepared.task.id))
        #expect(task.checkExecution == journal)
        #expect(task.evidence.contains {
            $0.kind == .independentCheck && $0.checkExecutionID == journal.id
        })
        #expect(!restored.readiness(for: task.id, codeState: journal.code, environment: journal.environment).isReady)
        #expect(spawned.withLock { $0 } == count)
    }

    @Test func metadataRunTrimmingClearsRemovedRunJournalAndLoads() async throws {
        let prepared = try await PreparedChecks(limits: AgentTaskPersistenceLimits(maxRunsPerTask: 1))
        defer { prepared.fixture.remove() }
        let executor = AgentTaskCheckExecutor(registry: prepared.registry, bindings: prepared.bindings)
        #expect(await executor.approve(taskID: prepared.task.id, plan: prepared.plan, environment: prepared.environment))
        #expect(await prepared.run(executor)?.requiredSucceeded == true)
        try await prepared.reviseToPassingCandidate()
        let task = try #require(prepared.registry.task(for: prepared.task.id))
        #expect(task.runs.count == 2)
        #expect(await prepared.store.save(tasks: [task], project: task.project) == .saved(taskCount: 1))
        let disk = await prepared.store.load(project: task.project)
        #expect(disk.status == .loaded)
        #expect(disk.tasks.first?.runs.count == 1)
        #expect(disk.tasks.first?.checkExecution == nil)
    }

    @Test func malformedV6RejectsExecutionLinkOnReviewerFact() async throws {
        let prepared = try await PreparedChecks()
        defer { prepared.fixture.remove() }
        let executor = AgentTaskCheckExecutor(registry: prepared.registry, bindings: prepared.bindings)
        #expect(await executor.approve(taskID: prepared.task.id, plan: prepared.plan, environment: prepared.environment))
        let file = AgentTaskMetadataStore.metadataURL(
            for: prepared.task.project, storageRoot: prepared.fixture.root.appending(path: "metadata")
        )
        let run = prepared.task.runs[0]
        let malformed = AgentTaskEvidenceFact(
            kind: .reviewerOutcome, runID: run.id, processGeneration: run.process.processGeneration,
            trust: .verified, result: .succeeded, observedAt: Date(),
            codeState: prepared.snapshot.code, environment: prepared.snapshot.environment,
            reviewerSession: AgentVendorSessionIdentity(provider: "other", opaqueIdentifier: "reviewer"),
            criteriaDigest: String(repeating: "a", count: 64),
            preOperationCodeState: prepared.snapshot.code, postOperationCodeState: prepared.snapshot.code,
            checkExecutionID: UUID()
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let factData = try encoder.encode(malformed)
        try await runOnBackground {
            var envelope = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            var tasks = try #require(envelope["tasks"] as? [[String: Any]])
            var task = try #require(tasks.first)
            task["evidence"] = [try #require(JSONSerialization.jsonObject(with: factData) as? [String: Any])]
            tasks[0] = task
            envelope["tasks"] = tasks
            #expect(envelope["schemaVersion"] as? Int == 6)
            try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys]).write(to: file)
        }
        let disk = await prepared.store.load(project: prepared.task.project)
        #expect(disk.status == .rejected(.invalidMetadata))
    }
}

@MainActor
private struct PreparedChecks {
    let fixture: CheckExecutorFixture
    let store: AgentTaskMetadataStore
    let registry: AgentTaskRegistry
    let task: AgentTask
    let bindings: AgentTaskEnvironmentBindings
    let binding: AgentTaskEnvironmentBinding
    let plan: AgentTaskCheckPlan
    let editor = AgentVerificationEditorPreflight.available([], isCurrent: { true })
    let environment: AgentTaskEnvironmentIdentity
    let snapshot: AgentVerificationIdentitySnapshot

    init(
        fixture fixtureOverride: CheckExecutorFixture? = nil, commands: [AgentTaskCheckCommand]? = nil,
        approvalTools: [URL]? = nil, faultInjector: PersistenceFaultInjector = .none,
        hooks: AgentTaskStoreHooks = AgentTaskStoreHooks(),
        limits: AgentTaskPersistenceLimits = AgentTaskPersistenceLimits()
    ) async throws {
        let fixture: CheckExecutorFixture
        if let fixtureOverride {
            fixture = fixtureOverride
        } else {
            fixture = try await runOnBackground { try CheckExecutorFixture() }
        }
        let task = fixture.task()
        let bindings = AgentTaskEnvironmentBindings()
        let run = try #require(task.runs.last)
        _ = try await bindings.reserve(
            taskID: task.id, runID: run.id, canonicalProject: fixture.project, expectedWorktree: fixture.worktree
        )
        try await runOnBackground {
            try fixture.git(["worktree", "add", "-b",
                             AgentTaskEnvironmentBindings.branchName(taskID: task.id, runID: run.id), fixture.worktree.path])
            try Data("PASS\n".utf8).write(to: fixture.worktree.appending(path: "check.txt"))
        }
        let binding = try await bindings.adopt(taskID: task.id, runID: run.id, candidates: [fixture.worktree])
        let store = AgentTaskMetadataStore(
            storageRoot: fixture.root.appending(path: "metadata"), limits: limits,
            configuration: AgentTaskStoreConfiguration(
                privateComponentCount: 1, faultInjector: faultInjector, hooks: hooks
            )
        )
        let registry = AgentTaskRegistry(persistence: store, limits: limits)
        #expect(await store.save(tasks: [task], project: task.project) == .saved(taskCount: 1))
        #expect(await registry.prepareDurableWork(in: task.project))
        let plan = AgentTaskCheckPlan(
            scheme: 1, recipeFingerprint: fixture.plan.recipeFingerprint,
            commands: commands ?? fixture.plan.commands, capturePolicy: .conservative, configurationFiles: []
        )
        let snapshot = try await Self.capture(
            bindings: bindings, binding: binding,
            tools: approvalTools ?? Self.tools(plan)
        )
        #expect(registry.recordEvidence(AgentTaskEvidenceFact(
            kind: .agentReportedCompletion, runID: run.id, processGeneration: run.process.processGeneration,
            trust: .verified, result: .reported, observedAt: Date(),
            codeState: snapshot.code, environment: snapshot.environment
        ), taskID: task.id) == .accepted)
        self.fixture = fixture
        self.task = task
        self.bindings = bindings
        self.binding = binding
        self.store = store
        self.registry = registry
        self.plan = plan
        environment = snapshot.environment
        self.snapshot = snapshot
    }

    static func tools(_ plan: AgentTaskCheckPlan) -> [URL] {
        Array(Set(plan.commands.map(\.executable))).sorted { $0.absoluteString < $1.absoluteString }
    }

    static func capture(
        bindings: AgentTaskEnvironmentBindings, binding: AgentTaskEnvironmentBinding, tools: [URL]
    ) async throws -> AgentVerificationIdentitySnapshot {
        let lease = try await bindings.revalidate(binding)
        let capture = AgentVerificationIdentityCapture(
            inputs: .init(
                lease: lease, policy: .conservative,
                editor: .available([], isCurrent: { true }), tools: tools, configurationFiles: []
            ),
            cancellation: GitCommandCancellationToken()
        )
        let result = await capture.capture()
        guard case .current(let snapshot) = result else {
            throw CheckCaptureFailure(result: String(describing: result))
        }
        return snapshot
    }

    func currentSnapshot() async -> AgentVerificationIdentitySnapshot? {
        try? await Self.capture(bindings: bindings, binding: binding, tools: Self.tools(plan))
    }

    func run(
        _ executor: AgentTaskCheckExecutor, plan: AgentTaskCheckPlan? = nil,
        editor editorOverride: AgentVerificationEditorPreflight? = nil
    ) async -> AgentTaskCheckObservation? {
        let run = task.runs[0]
        let passID = UUID()
        guard registry.markVerificationPending(
            taskID: task.id, expectedRunID: run.id,
            processGeneration: run.process.processGeneration, verificationPassID: passID
        ) else { return nil }
        let request = AgentTaskVerificationCheckRequest(
            taskID: task.id, runID: run.id, passID: passID,
            processGeneration: run.process.processGeneration, expected: snapshot, attempt: 1
        )
        let result = await executor.run(
            request: request, plan: plan ?? self.plan, binding: binding, editor: editorOverride ?? editor
        )
        registry.clearVerificationPending(
            taskID: task.id, runID: run.id, processGeneration: run.process.processGeneration,
            verificationPassID: passID
        )
        return result
    }

    func verify(
        _ executor: AgentTaskCheckExecutor,
        editor editorOverride: AgentVerificationEditorPreflight? = nil,
        onProbe: (@MainActor @Sendable (Int) async -> Void)? = nil,
        onReview: (@MainActor @Sendable () async -> Void)? = nil
    ) async -> AgentTaskVerificationResult {
        let probeCalls = Mutex(0)
        let coordinator = AgentTaskVerificationCoordinator(
            probeIdentity: { [bindings, binding, plan] _ in
                let call = probeCalls.withLock { $0 += 1; return $0 }
                await onProbe?(call)
                return try? await Self.capture(bindings: bindings, binding: binding, tools: Self.tools(plan))
            },
            grantIsCurrent: { [plan] task in
                guard let grant = task.checkGrant else { return false }
                return grant.matchesScope(taskID: task.id, plan: plan, environment: grant.environment)
            },
            runRequiredChecks: { [executor, binding, editor] request in
                guard let observation = await executor.run(
                    request: request, plan: plan, binding: binding, editor: editorOverride ?? editor
                ) else { throw CheckPortFailure() }
                return observation
            },
            startReview: { request in
                await onReview?()
                return AgentTaskReviewObservation(
                    taskID: request.taskID, runID: request.runID, passID: request.passID,
                    reviewerSession: AgentVendorSessionIdentity(provider: "claude", opaqueIdentifier: "reviewer"),
                    criteriaDigest: request.criteriaDigest, outcome: .passed,
                    preCodeState: request.expected.code, postCodeState: request.expected.code,
                    environment: request.expected.environment
                )
            }
        )
        return await coordinator.runVerificationPass(
            taskID: task.id, criteria: "Candidate meets the issue acceptance", registry: registry
        )
    }

    func reviseToPassingCandidate() async throws {
        try await runOnBackground { try Data("PASS revised\n".utf8).write(to: fixture.worktree.appending(path: "check.txt")) }
        let revised = try await Self.capture(bindings: bindings, binding: binding, tools: Self.tools(plan))
        var current = try #require(registry.task(for: task.id))
        let previous = try #require(current.runs.last)
        let now = Date()
        let terminalID = previous.terminalID
        var run = AgentTaskRun(AgentTaskRunInput(
            id: UUID(), terminalID: terminalID,
            process: AgentProcessEvidence(
                processIdentifier: nil, processGeneration: previous.process.processGeneration + 1,
                startIdentifier: nil, observedStartedAt: now, startIsAuthoritative: false
            ),
            status: AgentTaskRunStatus(state: .done, liveness: .terminated, observedAt: now)
        ))
        run.vendorIdentity = previous.vendorIdentity
        current.runs.append(run)
        current.updatedAt = now.addingTimeInterval(1)
        current.lastActivityAt = now.addingTimeInterval(1)
        registry.setTasksForTesting(registry.tasks.map { $0.id == task.id ? current : $0 })
        #expect(registry.recordEvidence(AgentTaskEvidenceFact(
            kind: .agentReportedCompletion, runID: run.id, processGeneration: run.process.processGeneration,
            trust: .verified, result: .reported, observedAt: now.addingTimeInterval(1),
            codeState: revised.code, environment: revised.environment
        ), taskID: task.id) == .accepted)
    }
}

nonisolated private final class CheckHoldingIOWorkers: UserTaskIOWorkerScheduling, Sendable {
    private struct State {
        var holding = true
        var pending: [@Sendable () -> Void] = []
    }
    private let state = Mutex(State())
    func schedule(_ operation: @escaping @Sendable () -> Void) {
        let held = state.withLock {
            guard $0.holding else { return false }
            $0.pending.append(operation)
            return true
        }
        if !held { UserTaskThreadIOWorkerScheduler().schedule(operation) }
    }
    func release() {
        let pending = state.withLock {
            $0.holding = false
            let pending = $0.pending
            $0.pending = []
            return pending
        }
        pending.forEach { UserTaskThreadIOWorkerScheduler().schedule($0) }
    }
}

nonisolated private struct CheckExecutorFixture: Sendable {
    let root: URL
    let project: URL
    let worktree: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "PineCheckExecutor-\(UUID())").resolvingSymlinksInPath()
        project = root.appending(path: "project")
        worktree = root.appending(path: "worktree")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try git(["init", "-b", "main"])
        try Data("FAIL\n".utf8).write(to: project.appending(path: "check.txt"))
        try git(["add", "check.txt"])
        try git(["-c", "user.name=Pine Test", "-c", "user.email=pine@example.invalid", "commit", "-m", "fixture"])
    }

    func git(_ arguments: [String]) throws {
        var environment = ["-i", "PATH=/usr/bin:/bin", "HOME=/var/empty", "LC_ALL=C",
                           "GIT_CONFIG_NOSYSTEM=1", "GIT_CONFIG_GLOBAL=/dev/null"]
        if let developer = ProcessInfo.processInfo.environment["DEVELOPER_DIR"] {
            environment.append("DEVELOPER_DIR=" + developer)
        }
        let result = GitCommand.runExecutable(
            URL(fileURLWithPath: "/usr/bin/env"), arguments: environment + [
                "/usr/bin/git", "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false", "-c", "init.templateDir="
            ] + arguments, at: project, timeout: 10
        )
        guard result.succeeded else { throw CocoaError(.fileReadUnknown) }
    }

    var plan: AgentTaskCheckPlan {
        AgentTaskCheckPlan(
            scheme: 1, recipeFingerprint: String(repeating: "a", count: 64),
            commands: [
                AgentTaskCheckCommand(id: "first", required: true, executable: URL(fileURLWithPath: "/usr/bin/true"),
                                      arguments: [], workingDirectory: "", timeout: 10),
                AgentTaskCheckCommand(id: "project-check", required: true, executable: URL(fileURLWithPath: "/usr/bin/grep"),
                                      arguments: ["-q", "PASS", "check.txt"], workingDirectory: "", timeout: 10)
            ], capturePolicy: .conservative, configurationFiles: []
        )
    }

    @MainActor func task() -> AgentTask {
        let now = Date()
        let terminalID = UUID()
        let identity = AgentTaskProjectIdentity(canonicalProjectPath: project.path, canonicalWorktreePath: worktree.path)
        var task = AgentTask(
            descriptor: AgentDescriptor(agentType: .claudeCode),
            context: AgentTaskBridgeContext(
                project: identity,
                route: AgentTaskRoute(paneID: UUID(), tabID: terminalID, terminalID: terminalID, availability: .missing),
                origin: .discoveredInTerminal, observedAt: now
            )
        )
        var run = AgentTaskRun(AgentTaskRunInput(
            id: UUID(), terminalID: terminalID,
            process: AgentProcessEvidence(
                processIdentifier: nil, processGeneration: 1, startIdentifier: nil,
                observedStartedAt: now.addingTimeInterval(-1), startIsAuthoritative: false
            ),
            status: AgentTaskRunStatus(state: .done, liveness: .terminated, observedAt: now)
        ))
        run.outcome = .unverified
        run.vendorIdentity = AgentVendorSessionIdentity(provider: "claude", opaqueIdentifier: "author")
        task.runs = [run]
        task.lifecycle = .paused
        return task
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
