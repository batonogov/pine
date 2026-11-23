import Foundation
import Testing
@testable import Pine

nonisolated private final class AgentResultExecutorDouble: @unchecked Sendable {
    struct Invocation: Sendable {
        let command: AgentTaskCheckCommand
        let workingDirectory: URL
        let preSpawnValidation: @Sendable ([String: String]) throws -> Void
        let processObserved: @Sendable (UInt32) -> Void
        let progress: UserTaskProgress
    }

    private let lock = NSLock()
    private var invocations: [Invocation] = []
    private var cancellationWasRequested = false
    private var cancellationResult = true

    var count: Int { lock.withLock { invocations.count } }
    var isEmpty: Bool { lock.withLock { invocations.isEmpty } }
    var cancellationRequested: Bool { lock.withLock { cancellationWasRequested } }
    var last: Invocation? { lock.withLock { invocations.last } }

    func append(_ invocation: Invocation) {
        lock.withLock { invocations.append(invocation) }
    }

    func requestCancellation() -> Bool {
        lock.withLock {
            cancellationWasRequested = true
            return cancellationResult
        }
    }

    func refuseCancellation() {
        lock.withLock { cancellationResult = false }
    }

    func spawn(
        _ processID: UInt32 = 42,
        environment: [String: String] = [:]
    ) throws {
        let invocation = try #require(last)
        try invocation.preSpawnValidation(environment)
        invocation.processObserved(processID)
    }

    func finish(
        _ exitCode: Int32,
        cancelled: Bool = false,
        preSpawnRejected: Bool = false
    ) throws {
        let invocation = try #require(last)
        let outcome = UserTaskOutcome(
            taskID: invocation.command.id, stdout: "example output", stderr: "",
            exitCode: exitCode, timedOut: false,
            processExitCode: preSpawnRejected ? nil : exitCode,
            preSpawnRejected: preSpawnRejected
        )
        invocation.progress.onFinish?(outcome, cancelled)
    }
}

extension AgentResultExecutorDouble: AgentTaskResultActionExecuting {
    nonisolated func execute(
        command: AgentTaskCheckCommand,
        workingDirectory: URL,
        preSpawnValidation: @escaping @Sendable ([String: String]) throws -> Void,
        processObserved: @escaping @Sendable (UInt32) -> Void,
        progress: UserTaskProgress
    ) -> UserTaskCancellation {
        append(Invocation(
            command: command, workingDirectory: workingDirectory,
            preSpawnValidation: preSpawnValidation,
            processObserved: processObserved, progress: progress
        ))
        return UserTaskCancellation { self.requestCancellation() }
    }
}

nonisolated private final class AgentResultAuthorityProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storedGrant: AgentTaskCheckGrant?
    private var storedEnvironmentCurrent = true
    private var environmentCheckCount = 0
    private var revalidationCount = 0
    private var readiness = AgentTaskReadiness(isReady: true, gaps: [])
    private var identityResult: AgentVerificationIdentityCaptureResult?
    private var capturedEnvironments: [[String: String]] = []
    var environmentChecks: Int { lock.withLock { environmentCheckCount } }
    var revalidations: Int { lock.withLock { revalidationCount } }
    var capturedEnvironment: [String: String]? { lock.withLock { capturedEnvironments.last } }

    func setReadiness(_ value: AgentTaskReadiness) {
        lock.withLock { readiness = value }
    }

    func currentReadiness() -> AgentTaskReadiness {
        lock.withLock { readiness }
    }

    func setIdentityResult(_ value: AgentVerificationIdentityCaptureResult?) {
        lock.withLock { identityResult = value }
    }

    func captureIdentity(
        environment: [String: String], expected: AgentVerificationIdentitySnapshot
    ) -> AgentVerificationIdentityCaptureResult {
        lock.withLock {
            capturedEnvironments.append(environment)
            return identityResult ?? .current(expected)
        }
    }

    func noteRevalidation() {
        lock.withLock { revalidationCount += 1 }
    }

    init(grant: AgentTaskCheckGrant) {
        storedGrant = grant
    }

    var grant: AgentTaskCheckGrant? { lock.withLock { storedGrant } }

    func revokeGrant() {
        lock.withLock {
            storedGrant?.revokedAt = Date()
        }
    }

    func checkEnvironment() -> Bool {
        lock.withLock {
            environmentCheckCount += 1
            return storedEnvironmentCurrent
        }
    }
}

@MainActor
@Suite("Try-the-result driver", .serialized)
struct AgentTaskResultActionDriverTests {
    private struct Fixture {
        let task: AgentTask
        let binding: AgentTaskResultActionBinding
        let selection: AgentProjectRecipe.Selected
        let grant: AgentTaskCheckGrant
    }

    private func fixture(
        originalCheckout: Bool = false,
        output: AgentProjectResultOutput = .cli
    ) throws -> Fixture {
        let template = ADEContractFixtures.makeTask(seed: 1757)
        let projectPath = "/tmp/pine-result-project"
        let worktreePath = originalCheckout ? projectPath : "/tmp/pine-result-task"
        let context = AgentTaskBridgeContext(
            project: AgentTaskProjectIdentity(
                canonicalProjectPath: projectPath, canonicalWorktreePath: worktreePath
            ),
            route: template.route, origin: template.origin,
            observedAt: template.createdAt
        )
        let task = AgentTask(descriptor: template.descriptor, context: context)
        let recipe = try #require(AgentProjectRecipe.propose(
            recognizedFiles: ["Package.swift", "Sources/Example/main.swift"],
            for: task.project
        ))
        let selection = try AgentProjectRecipe.select(projectCheckedIn: recipe, for: task.project)
        let snapshot = AgentVerificationIdentitySnapshot(
            code: ADEContractFixtures.codeState("a"), environment: ADEContractFixtures.environment
        )
        let selectedBinding = try #require(AgentTaskResultActionBinding(
            task: task, selection: selection, actionID: "run-example", snapshot: snapshot
        ))
        let binding = output == selectedBinding.output ? selectedBinding : AgentTaskResultActionBinding(
            taskID: selectedBinding.taskID, project: selectedBinding.project,
            recipeFingerprint: selectedBinding.recipeFingerprint,
            resultActionID: selectedBinding.resultActionID, output: output, snapshot: snapshot
        )
        let grant = AgentTaskCheckGrant(
            scheme: AgentTaskCheckGrant.currentScheme, id: UUID(), taskID: task.id,
            planFingerprint: selection.plan.fingerprint, environment: snapshot.environment,
            approvedAt: Date(), revokedAt: nil
        )
        return Fixture(task: task, binding: binding, selection: selection, grant: grant)
    }

    nonisolated private func context(
        _ fixture: Fixture,
        authority: AgentResultAuthorityProbe,
        readiness: AgentTaskReadiness = AgentTaskReadiness(isReady: true, gaps: []),
        preparation suppliedPreparation: AgentProjectPreparation? = nil
    ) -> AgentTaskResultLaunchContext {
        var preparation = suppliedPreparation ?? AgentProjectPreparation(
            recipe: fixture.selection.recipe
        )
        if suppliedPreparation == nil {
            for name in preparation.prerequisiteNames {
                preparation = preparation.reduced(by: .prerequisiteResolved(name))
            }
            for action in preparation.setupActionIDs {
                preparation = preparation.reduced(by: .setupSucceeded(action))
            }
        }
        authority.setReadiness(readiness)
        let commandAuthority = AgentTaskResultCommandAuthority(
            taskID: fixture.binding.taskID, project: fixture.binding.project,
            plan: fixture.selection.plan, expected: fixture.binding.snapshot,
            currentGrant: { authority.grant },
            currentReadiness: { _ in authority.currentReadiness() },
            captureIdentity: { environment in
                authority.captureIdentity(
                    environment: environment, expected: fixture.binding.snapshot
                )
            },
            environmentIsCurrent: { authority.checkEnvironment() }
        )
        return AgentTaskResultLaunchContext(
            binding: fixture.binding,
            command: fixture.selection.recipe.results[0].command,
            preparation: preparation, authority: commandAuthority
        )
    }

    @Test func bindRevalidateExecuteOwnAndComplete() async throws {
        let fixture = try fixture()
        let executor = AgentResultExecutorDouble()
        let authority = AgentResultAuthorityProbe(grant: fixture.grant)
        let driver = AgentTaskResultActionDriver(binding: fixture.binding, executor: executor)
        #expect(driver.state.phase == .prepared)
        #expect(executor.isEmpty)

        driver.launch { binding in
            #expect(binding == fixture.binding)
            authority.noteRevalidation()
            return context(fixture, authority: authority)
        }
        try #require(await waitUntilMainActor { executor.count == 1 })
        #expect(authority.revalidations == 1)
        #expect(executor.last?.workingDirectory.path == "/tmp/pine-result-task")
        #expect(driver.state.phase == .starting)

        try executor.spawn(42)
        try #require(await waitUntilMainActor { driver.state.ownership?.processID == 42 })
        #expect(driver.state.ownership?.processGroupID == 42)
        try executor.finish(0)
        try #require(await waitUntilMainActor { driver.state.phase == .ready })
        #expect(driver.state.isCurrent)
        #expect(driver.lastOutcome?.outputPreview.text == "example output")
    }

    @Test func launchRevalidatesAgainAtPreSpawnAndRefusesRevocation() async throws {
        let fixture = try fixture()
        let executor = AgentResultExecutorDouble()
        let authority = AgentResultAuthorityProbe(grant: fixture.grant)
        let driver = AgentTaskResultActionDriver(binding: fixture.binding, executor: executor)
        driver.launch { _ in context(fixture, authority: authority) }
        try #require(await waitUntilMainActor { executor.count == 1 })
        #expect(authority.environmentChecks == 1)

        authority.revokeGrant()
        do {
            try executor.spawn()
            Issue.record("Revoked grant reached process observation")
        } catch {
            try executor.finish(-1, preSpawnRejected: true)
        }
        try #require(await waitUntilMainActor {
            driver.state.phase == .failed(.launchRefused(.authorityChanged))
        })
        #expect(driver.state.ownership == nil)
        #expect(authority.environmentChecks == 1) // grant fence ran before the lease check
    }

    @Test func originalCheckoutAndUnreadyContextsNeverReachExecutor() async throws {
        let original = try fixture(originalCheckout: true)
        let originalExecutor = AgentResultExecutorDouble()
        let originalAuthority = AgentResultAuthorityProbe(grant: original.grant)
        let originalDriver = AgentTaskResultActionDriver(
            binding: original.binding, executor: originalExecutor
        )
        originalDriver.launch { _ in context(original, authority: originalAuthority) }
        try #require(await waitUntilMainActor {
            originalDriver.state.phase == .failed(.launchRefused(.originalCheckout))
        })
        #expect(originalExecutor.isEmpty)

        let unready = try fixture()
        let unreadyExecutor = AgentResultExecutorDouble()
        let unreadyAuthority = AgentResultAuthorityProbe(grant: unready.grant)
        let unreadyDriver = AgentTaskResultActionDriver(
            binding: unready.binding, executor: unreadyExecutor
        )
        unreadyDriver.launch { _ in context(
            unready, authority: unreadyAuthority,
            readiness: AgentTaskReadiness(isReady: false, gaps: [.verificationNotCurrent])
        ) }
        try #require(await waitUntilMainActor {
            unreadyDriver.state.phase == .failed(.launchRefused(.notReady))
        })
        #expect(unreadyExecutor.isEmpty)
    }

    @Test func incompletePreparationNeverReachesExecutor() async throws {
        let fixture = try fixture()
        let executor = AgentResultExecutorDouble()
        let authority = AgentResultAuthorityProbe(grant: fixture.grant)
        let driver = AgentTaskResultActionDriver(binding: fixture.binding, executor: executor)
        driver.launch { _ in context(
            fixture, authority: authority,
            preparation: AgentProjectPreparation(recipe: fixture.selection.recipe)
        ) }
        try #require(await waitUntilMainActor {
            driver.state.phase == .failed(.launchRefused(.notReady))
        })
        #expect(executor.isEmpty)
    }

    @Test func preSpawnRecapturesIdentityAndReadinessWithChildEnvironment() async throws {
        let fixture = try fixture()
        let executor = AgentResultExecutorDouble()
        let authority = AgentResultAuthorityProbe(grant: fixture.grant)
        let driver = AgentTaskResultActionDriver(binding: fixture.binding, executor: executor)
        driver.launch { _ in context(fixture, authority: authority) }
        try #require(await waitUntilMainActor { executor.count == 1 })

        authority.setIdentityResult(.changed)
        let environment = ["PINE_RESULT_TEST": "literal child value"]
        do {
            try executor.spawn(environment: environment)
            Issue.record("Changed identity reached process observation")
        } catch {
            try executor.finish(-1, preSpawnRejected: true)
        }
        try #require(await waitUntilMainActor {
            driver.state.phase == .failed(.launchRefused(.authorityChanged))
        })
        #expect(authority.capturedEnvironment == environment)
        #expect(driver.state.ownership == nil)
    }

    @Test func preSpawnRereadsCurrentReadiness() async throws {
        let fixture = try fixture()
        let executor = AgentResultExecutorDouble()
        let authority = AgentResultAuthorityProbe(grant: fixture.grant)
        let driver = AgentTaskResultActionDriver(binding: fixture.binding, executor: executor)
        driver.launch { _ in context(fixture, authority: authority) }
        try #require(await waitUntilMainActor { executor.count == 1 })

        authority.setReadiness(AgentTaskReadiness(
            isReady: false, gaps: [.verificationNotCurrent]
        ))
        do {
            try executor.spawn()
            Issue.record("Invalidated readiness reached process observation")
        } catch {
            try executor.finish(-1, preSpawnRejected: true)
        }
        try #require(await waitUntilMainActor {
            driver.state.phase == .failed(.launchRefused(.authorityChanged))
        })
        #expect(driver.state.ownership == nil)
    }

    @Test func unsupportedServerAndArtifactNeverReachExecutor() async throws {
        for output in [
            AgentProjectResultOutput.server(host: "127.0.0.1", port: 8080),
            .artifact(relativePath: ".build/debug/Example"),
        ] {
            let fixture = try fixture(output: output)
            let executor = AgentResultExecutorDouble()
            let authority = AgentResultAuthorityProbe(grant: fixture.grant)
            let driver = AgentTaskResultActionDriver(binding: fixture.binding, executor: executor)
            driver.launch { _ in context(fixture, authority: authority) }
            try #require(await waitUntilMainActor {
                driver.state.phase == .failed(.launchRefused(.unsupportedOutput))
            })
            #expect(executor.isEmpty)
        }
    }

    @Test func refusedCancellationLeavesCompletionInControl() async throws {
        let fixture = try fixture()
        let executor = AgentResultExecutorDouble()
        executor.refuseCancellation()
        let authority = AgentResultAuthorityProbe(grant: fixture.grant)
        let driver = AgentTaskResultActionDriver(binding: fixture.binding, executor: executor)
        driver.launch { _ in context(fixture, authority: authority) }
        try #require(await waitUntilMainActor { executor.count == 1 })
        try executor.spawn()
        try #require(await waitUntilMainActor { driver.state.ownership != nil })

        driver.stop()
        #expect(driver.state.phase == .starting)
        try executor.finish(0)
        try #require(await waitUntilMainActor { driver.state.phase == .ready })
    }

    @Test func candidateChangeDuringLaunchCancelsAndFencesLateCompletion() async throws {
        let fixture = try fixture()
        let executor = AgentResultExecutorDouble()
        let authority = AgentResultAuthorityProbe(grant: fixture.grant)
        let driver = AgentTaskResultActionDriver(binding: fixture.binding, executor: executor)
        driver.launch { _ in context(fixture, authority: authority) }
        try #require(await waitUntilMainActor { executor.count == 1 })
        try executor.spawn(7)
        try #require(await waitUntilMainActor { driver.state.ownership?.processID == 7 })

        driver.candidateChanged()
        #expect(driver.state.phase == .cancelled)
        #expect(driver.state.ownership == nil)
        #expect(executor.cancellationRequested)
        try executor.finish(0)
        await Task.yield()
        #expect(driver.state.phase == .cancelled)
        #expect(driver.lastOutcome == nil)
    }

    @Test func registryCandidateChangeDrivesProductionController() async throws {
        let fixture = try fixture()
        let registry = AgentTaskRegistry()
        registry.setTasksForTesting([fixture.task])
        let executor = AgentResultExecutorDouble()
        let authority = AgentResultAuthorityProbe(grant: fixture.grant)
        let driver = AgentTaskResultActionDriver(binding: fixture.binding, executor: executor)
        let controller = try #require(AgentTaskResultController(
            registry: registry, taskID: fixture.task.id,
            editorPreflight: { .available([], isCurrent: { true }) },
            executor: executor, initialDriver: driver
        ))
        driver.launch { _ in context(fixture, authority: authority) }
        try #require(await waitUntilMainActor { executor.count == 1 })
        try executor.spawn()
        try executor.finish(0)
        try #require(await waitUntilMainActor { driver.state.phase == .ready })

        var changed = fixture.task
        changed.verificationState = .stale
        registry.setTasksForTesting([changed])
        #expect(driver.state.phase == .stale)
        withExtendedLifetime(controller) {}
    }

    @Test func staleResultRebindsFreshBeforeAnExplicitRelaunch() async throws {
        let fixture = try fixture()
        let executor = AgentResultExecutorDouble()
        let authority = AgentResultAuthorityProbe(grant: fixture.grant)
        let driver = AgentTaskResultActionDriver(binding: fixture.binding, executor: executor)
        driver.launch { _ in context(fixture, authority: authority) }
        try #require(await waitUntilMainActor { executor.count == 1 })
        try executor.spawn()
        try executor.finish(0)
        try #require(await waitUntilMainActor { driver.state.phase == .ready })

        driver.candidateChanged()
        #expect(driver.state.phase == .stale)
        driver.launch { _ in context(fixture, authority: authority) }
        await Task.yield()
        #expect(executor.count == 1) // stale reducer refuses launch

        var binding = fixture.binding
        binding = AgentTaskResultActionBinding(
            taskID: binding.taskID, project: binding.project,
            recipeFingerprint: binding.recipeFingerprint,
            resultActionID: binding.resultActionID, output: binding.output,
            snapshot: AgentVerificationIdentitySnapshot(
                code: ADEContractFixtures.codeState("b"), environment: binding.snapshot.environment
            )
        )
        #expect(driver.rebind(to: binding))
        #expect(driver.state.phase == .prepared)
        let refreshed = Fixture(
            task: fixture.task, binding: binding,
            selection: fixture.selection, grant: fixture.grant
        )
        driver.launch { _ in context(refreshed, authority: authority) }
        try #require(await waitUntilMainActor { executor.count == 2 })
        #expect(driver.state.attempts == 1)
    }
}
