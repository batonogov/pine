import Foundation
import Testing
@testable import Pine

nonisolated private final class AgentResultCleanupGate: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)

    func wait(until deadline: DispatchTime) -> Bool {
        semaphore.wait(timeout: deadline) == .success
    }

    func open() { semaphore.signal() }
}

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
    private var cleanupGate: AgentResultCleanupGate?

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

    func gateCleanup() -> AgentResultCleanupGate {
        let gate = AgentResultCleanupGate()
        lock.withLock { cleanupGate = gate }
        return gate
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
        let gate = lock.withLock { cleanupGate }
        return UserTaskCancellation(
            terminate: { self.requestCancellation() },
            waitForCompletion: { deadline in gate?.wait(until: deadline) ?? true }
        )
    }
}

private actor AgentResultReplyStore: AgentTaskPersisting {
    private var data = Data("[]".utf8)
    private var saveSucceeds = true

    func setSaveSucceeds(_ value: Bool) { saveSucceeds = value }

    func savedRevisionCount(_ reference: String) -> Int {
        let tasks = (try? JSONDecoder().decode([AgentTask].self, from: data)) ?? []
        return tasks.flatMap(\.revisions).filter { $0.feedbackReference == reference }.count
    }

    func load(project: AgentTaskProjectIdentity) async -> AgentTaskMetadataLoadResult {
        AgentTaskMetadataLoadResult(
            status: .loaded,
            tasks: (try? JSONDecoder().decode([AgentTask].self, from: data)) ?? [],
            revision: nil, requiresMigration: false, envelope: .empty
        )
    }

    func save(
        tasks: [AgentTask], project: AgentTaskProjectIdentity,
        authorization: AgentTaskPublicationAuthorization?
    ) async -> AgentTaskMetadataSaveResult {
        guard saveSucceeds else { return .rejected(.ioFailure) }
        guard let encoded = try? JSONEncoder().encode(tasks) else {
            return .rejected(.invalidMetadata)
        }
        data = encoded
        return .saved(taskCount: tasks.count)
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

    func setEnvironmentCurrent(_ value: Bool) {
        lock.withLock { storedEnvironmentCurrent = value }
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

    private func decisionTask(findingReference: String? = nil) throws -> AgentTask {
        let code = ADEContractFixtures.codeState("a")
        let environment = ADEContractFixtures.environment
        var task = try ADEContractFixtures.verifiedSuccessTask(
            seed: 1760, codeState: code, environment: environment
        )
        let run = try #require(task.runs.last)
        var cycle = AgentTaskCorrectionCycle(
            taskID: task.id, runID: run.id, codeState: code, environment: environment,
            requestedOutcomeReference: "outcome", criteriaVersion: "criteria",
            checkPlanIdentity: ADEContractFixtures.hex("f"),
            reviewerControl: .writeDisabledAtAdapter
        )
        if let findingReference { cycle.recordRejectedReference(findingReference) }
        cycle.stop(.checksFailed)
        task.reviewCycle = cycle
        return task
    }

    /// A verified Ready task with no recipe selected and no result action
    /// bound: what it presents on open depends only on `resolve`.
    private func openVerifiedTask(
        projectPath: String = "/tmp/pine-result-project",
        mutate: (inout AgentTask) -> Void = { _ in },
        resolve: @escaping AgentTaskResultIdentityResolver
    ) async throws -> (
        controller: AgentTaskResultController, registry: AgentTaskRegistry
    ) {
        var task = try ADEContractFixtures.verifiedSuccessTask(
            seed: 1762, codeState: ADEContractFixtures.codeState("a"),
            environment: ADEContractFixtures.environment, projectPath: projectPath
        )
        mutate(&task)
        let registry = AgentTaskRegistry()
        registry.setTasksForTesting([task])
        // The optional-closure init parameter escapes; the resolver stays out
        // of #require's sendable expansion, which cannot capture it.
        let controller = AgentTaskResultController(
            registry: registry, taskID: task.id,
            editorPreflight: { .available([], isCurrent: { true }) },
            identityResolver: resolve
        )
        return (try #require(controller), registry)
    }

    /// Recipe discovery only reports a proposal for a recognized project,
    /// which is the observable end of an open.
    private func temporarySwiftPackage() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-result-open-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appending(path: "Sources/Example"), withIntermediateDirectories: true
        )
        try "// swift-tools-version: 5.9".write(
            to: root.appending(path: "Package.swift"), atomically: true, encoding: .utf8
        )
        try "print(\"example\")".write(
            to: root.appending(path: "Sources/Example/main.swift"), atomically: true, encoding: .utf8
        )
        return root
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
            driver.state.phase == .failed(.launchRefused(.grantNotCurrent))
        })
        #expect(driver.state.ownership == nil)
        #expect(authority.environmentChecks == 1) // grant fence ran before the lease check
    }

    @Test func preSpawnEnvironmentLossIsRefusedAsEnvironmentUnavailable() async throws {
        let fixture = try fixture()
        let executor = AgentResultExecutorDouble()
        let authority = AgentResultAuthorityProbe(grant: fixture.grant)
        let driver = AgentTaskResultActionDriver(binding: fixture.binding, executor: executor)
        driver.launch { _ in context(fixture, authority: authority) }
        try #require(await waitUntilMainActor { executor.count == 1 })

        authority.setEnvironmentCurrent(false)
        do {
            try executor.spawn()
            Issue.record("A lost environment reached process observation")
        } catch {
            try executor.finish(-1, preSpawnRejected: true)
        }
        try #require(await waitUntilMainActor {
            driver.state.phase == .failed(.launchRefused(.environmentUnavailable))
        })
        #expect(driver.state.ownership == nil)
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
            driver.state.phase == .failed(.launchRefused(.bindingChanged))
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
            driver.state.phase == .failed(.launchRefused(.notReady))
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

    @Test func candidateChangeDuringLaunchFencesRelaunchUntilFinalCleanup() async throws {
        let fixture = try fixture()
        let executor = AgentResultExecutorDouble()
        let cleanupGate = executor.gateCleanup()
        let authority = AgentResultAuthorityProbe(grant: fixture.grant)
        let driver = AgentTaskResultActionDriver(binding: fixture.binding, executor: executor)
        driver.launch { _ in context(fixture, authority: authority) }
        try #require(await waitUntilMainActor { executor.count == 1 })
        try executor.spawn(7)
        try #require(await waitUntilMainActor { driver.state.ownership?.processID == 7 })

        driver.candidateChanged()
        #expect(driver.state.phase == .stopping)
        #expect(driver.state.ownership?.processID == 7)
        #expect(executor.cancellationRequested)
        driver.launch { _ in context(fixture, authority: authority) }
        await Task.yield()
        #expect(executor.count == 1)
        let rebound = AgentTaskResultActionBinding(
            taskID: fixture.binding.taskID, project: fixture.binding.project,
            recipeFingerprint: fixture.binding.recipeFingerprint,
            resultActionID: fixture.binding.resultActionID, output: fixture.binding.output,
            snapshot: AgentVerificationIdentitySnapshot(
                code: ADEContractFixtures.codeState("b"),
                environment: fixture.binding.snapshot.environment
            )
        )
        #expect(!driver.rebind(to: rebound))
        #expect(driver.lastOutcome == nil)

        try executor.finish(0, cancelled: true)
        try #require(await waitUntilMainActor { driver.lastOutcome != nil })
        #expect(driver.state.phase == .stopping)
        driver.launch { _ in context(fixture, authority: authority) }
        await Task.yield()
        #expect(executor.count == 1)
        #expect(!driver.rebind(to: rebound))

        cleanupGate.open()
        try #require(await waitUntilMainActor { driver.state.phase == .cancelled })
        #expect(driver.state.ownership == nil)
        #expect(driver.rebind(to: rebound))
        let refreshed = Fixture(
            task: fixture.task, binding: rebound,
            selection: fixture.selection, grant: fixture.grant
        )
        driver.launch { _ in context(refreshed, authority: authority) }
        try #require(await waitUntilMainActor { executor.count == 2 })
    }

    @Test func preSpawnRejectionWhileStoppingFinishesAndAllowsFreshLaunch() async throws {
        let fixture = try fixture()
        let executor = AgentResultExecutorDouble()
        let authority = AgentResultAuthorityProbe(grant: fixture.grant)
        let driver = AgentTaskResultActionDriver(binding: fixture.binding, executor: executor)
        driver.launch { _ in context(fixture, authority: authority) }
        try #require(await waitUntilMainActor { executor.count == 1 })
        driver.candidateChanged()
        #expect(driver.state.phase == .stopping)

        try executor.finish(0, cancelled: true, preSpawnRejected: true)
        try #require(await waitUntilMainActor { driver.state.phase == .cancelled })
        #expect(driver.state.ownership == nil)

        driver.launch { _ in context(fixture, authority: authority) }
        try #require(await waitUntilMainActor { executor.count == 2 })
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

    @Test func replyPersistsBeforeDispatchAndAllowsExplicitRetryAfterFailure() async throws {
        let store = AgentResultReplyStore()
        let registry = AgentTaskRegistry(persistence: store)
        let task = try decisionTask()
        registry.registerProject(task.project)
        #expect(await registry.flushPersistence(project: task.project) == .saved)
        registry.setTasksForTesting([task])
        await store.setSaveSucceeds(false)
        let text = "Fix the build, then repeat the check"
        let reference = AgentHistoryContentHash.sha256Hex(Data(text.utf8))
        var deliveries: [String] = []
        var deliverySucceeds = true
        let created = AgentTaskResultController(
            registry: registry, taskID: task.id,
            editorPreflight: { .available([], isCurrent: { true }) },
            replyDispatcher: { reply, decision in
                #expect(decision.taskID == task.id)
                let replyReference = AgentHistoryContentHash.sha256Hex(Data(reply.utf8))
                #expect(await store.savedRevisionCount(replyReference) == 1)
                deliveries.append(reply)
                return deliverySucceeds
            }
        )
        let controller = try #require(created)
        defer { controller.close() }
        #expect(controller.presentation.canReplyToDecision)

        controller.reply(text)
        try #require(await waitUntilMainActor {
            controller.replyDeliveryFailed && !controller.presentation.replyInFlight
        })
        #expect(deliveries.isEmpty)
        #expect(registry.task(for: task.id)?.revisions.count == 1)
        #expect(await store.savedRevisionCount(reference) == 0)
        #expect(controller.presentation.canReplyToDecision)

        await store.setSaveSucceeds(true)
        controller.reply(text)
        try #require(await waitUntilMainActor { deliveries.count == 1 })
        try #require(await waitUntilMainActor { !controller.presentation.replyInFlight })
        #expect(deliveries == [text])
        #expect(!controller.replyDeliveryFailed)
        #expect(registry.task(for: task.id)?.revisions.count == 1)
        #expect(await store.savedRevisionCount(reference) == 1)

        deliverySucceeds = false
        controller.reply("Revise the failed check")
        try #require(await waitUntilMainActor {
            deliveries.count == 2 && controller.replyDeliveryFailed
                && !controller.presentation.replyInFlight
        })
        await Task.yield()
        #expect(deliveries.count == 2)
        #expect(registry.task(for: task.id)?.revisions.count == 2)
    }

    @Test func closeReopenSharesFinalCleanupFenceAndPreventsDuplicateLaunch() async throws {
        let fixture = try fixture()
        let registry = AgentTaskRegistry()
        registry.setTasksForTesting([fixture.task])
        let executor = AgentResultExecutorDouble()
        let cleanupGate = executor.gateCleanup()
        let authority = AgentResultAuthorityProbe(grant: fixture.grant)
        let driver = AgentTaskResultActionDriver(binding: fixture.binding, executor: executor)
        var first: AgentTaskResultController? = try #require(AgentTaskResultController(
            registry: registry, taskID: fixture.task.id,
            editorPreflight: { .available([], isCurrent: { true }) },
            executor: executor, initialDriver: driver
        ))
        driver.launch { _ in context(fixture, authority: authority) }
        try #require(await waitUntilMainActor { executor.count == 1 })
        try executor.spawn(71)
        try #require(await waitUntilMainActor { driver.state.ownership?.processID == 71 })

        first?.close()
        #expect(driver.state.phase == .stopping)
        #expect(executor.cancellationRequested)
        #expect(first?.driver == nil)
        first = nil
        let reopened = try #require(AgentTaskResultController(
            registry: registry, taskID: fixture.task.id,
            editorPreflight: { .available([], isCurrent: { true }) }, executor: executor
        ))
        #expect(reopened.driver === driver)
        reopened.driver?.launch { _ in context(fixture, authority: authority) }
        await Task.yield()
        #expect(executor.count == 1)

        try executor.finish(0, cancelled: true)
        try #require(await waitUntilMainActor { driver.lastOutcome != nil })
        #expect(driver.state.phase == .stopping)
        reopened.driver?.launch { _ in context(fixture, authority: authority) }
        await Task.yield()
        #expect(executor.count == 1)

        cleanupGate.open()
        try #require(await waitUntilMainActor { driver.state.phase == .cancelled })
        reopened.driver?.launch { _ in context(fixture, authority: authority) }
        try #require(await waitUntilMainActor { executor.count == 2 })
    }

    @Test func productionReopenRestoresPreparationAndLaunchesThroughController() async throws {
        let base = try fixture()
        let code = ADEContractFixtures.codeState("a")
        let environment = ADEContractFixtures.environment
        var task = base.task
        task.runs = [AgentTaskRun(ADEContractFixtures.makeAttempt(seed: 1761))]
        let run = try #require(task.runs.last)
        task.evidence.append(ADEContractFixtures.fact(
            .agentReportedCompletion, runID: run.id, generation: run.process.processGeneration,
            result: .reported, at: run.lastObservedAt, codeState: code, environment: environment,
            sequence: 1
        ))
        task.evidence.append(ADEContractFixtures.fact(
            .independentCheck, runID: run.id, generation: run.process.processGeneration,
            result: .succeeded, at: run.lastObservedAt.addingTimeInterval(1),
            codeState: code, environment: environment, sequence: 2, pre: code, post: code
        ))
        task.evidence.append(ADEContractFixtures.fact(
            .reviewerOutcome, runID: run.id, generation: run.process.processGeneration,
            result: .succeeded, at: run.lastObservedAt.addingTimeInterval(2),
            codeState: code, environment: environment, sequence: 3, pre: code, post: code
        ))
        AgentTaskLifecycleReducer.settleLatestRun(of: &task, runIndex: task.runs.count - 1)
        let binding = try #require(AgentTaskResultActionBinding(
            task: task, selection: base.selection, actionID: "run-example",
            snapshot: AgentVerificationIdentitySnapshot(code: code, environment: environment)
        ))
        let grant = AgentTaskCheckGrant(
            scheme: AgentTaskCheckGrant.currentScheme, id: UUID(), taskID: task.id,
            planFingerprint: base.selection.plan.fingerprint, environment: environment,
            approvedAt: Date(), revokedAt: nil
        )
        let fixture = Fixture(
            task: task, binding: binding, selection: base.selection, grant: grant
        )
        let registry = AgentTaskRegistry()
        registry.setTasksForTesting([task])
        let executor = AgentResultExecutorDouble()
        let authority = AgentResultAuthorityProbe(grant: grant)
        let driver = registry.retainResultActionDriver(
            AgentTaskResultActionDriver(binding: binding, executor: executor)
        )
        var preparation = AgentProjectPreparation(recipe: base.selection.recipe)
        for name in preparation.prerequisiteNames {
            preparation = preparation.reduced(by: .prerequisiteResolved(name))
        }
        for action in preparation.setupActionIDs {
            preparation = preparation.reduced(by: .setupSucceeded(action))
        }
        registry.updateResultActionSelection(base.selection, for: task.id)
        registry.updateResultActionPreparation(preparation, for: task.id)
        let commandAuthority: AgentTaskResultCommandAuthorityProvider = { _, _ in
            context(fixture, authority: authority).authority
        }
        var first: AgentTaskResultController? = try #require(AgentTaskResultController(
            registry: registry, taskID: task.id,
            editorPreflight: { .available([], isCurrent: { true }) },
            executor: executor, commandAuthority: commandAuthority
        ))
        #expect(first?.presentation.canLaunchAction == true)

        first?.close()
        first = nil
        let reopened = try #require(AgentTaskResultController(
            registry: registry, taskID: task.id,
            editorPreflight: { .available([], isCurrent: { true }) },
            executor: executor, commandAuthority: commandAuthority
        ))
        #expect(reopened.presentation.canLaunchAction)
        #expect(reopened.presentation.preparation == preparation)

        reopened.launchResult()
        try #require(await waitUntilMainActor { executor.count == 1 })
        #expect(driver.state.phase == .starting)
    }

    @Test func preparationRetryAndReopenWaitForDeferredCleanup() async throws {
        let fixture = try fixture()
        let registry = AgentTaskRegistry()
        registry.setTasksForTesting([fixture.task])
        let executor = AgentResultExecutorDouble()
        let cleanupGate = executor.gateCleanup()
        let authority = AgentResultAuthorityProbe(grant: fixture.grant)
        let driver = AgentTaskResultActionDriver(binding: fixture.binding, executor: executor)
        let created = AgentTaskResultController(
            registry: registry, taskID: fixture.task.id,
            editorPreflight: { .available([], isCurrent: { true }) },
            executor: executor, initialDriver: driver, initialSelection: fixture.selection,
            commandAuthority: { _, _ in context(fixture, authority: authority).authority }
        )
        let controller = try #require(created)
        controller.prepareResult()
        try #require(await waitUntilMainActor { executor.count == 1 })

        try executor.finish(1)
        #expect(registry.resultPreparationExecutionIsPending(for: fixture.task.id))
        controller.prepareResult()
        let reopenedController = AgentTaskResultController(
            registry: registry, taskID: fixture.task.id,
            editorPreflight: { .available([], isCurrent: { true }) },
            executor: executor, initialSelection: fixture.selection,
            commandAuthority: { _, _ in context(fixture, authority: authority).authority }
        )
        let reopened = try #require(reopenedController)
        #expect(reopened.driver === driver)
        reopened.prepareResult()
        await Task.yield()
        #expect(executor.count == 1)

        cleanupGate.open()
        try #require(await waitUntilMainActor {
            !registry.resultPreparationExecutionIsPending(for: fixture.task.id)
        })
        reopened.prepareResult()
        try #require(await waitUntilMainActor { executor.count == 2 })

        cleanupGate.open()
        try executor.finish(1)
        try #require(await waitUntilMainActor {
            !registry.resultPreparationExecutionIsPending(for: fixture.task.id)
        })
    }

    @Test func dismissalStopsAndEvictsRunningResultOwner() async throws {
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
        try executor.spawn(72)
        try #require(await waitUntilMainActor { driver.state.ownership?.processID == 72 })

        var dismissed = fixture.task
        dismissed.lifecycle = .dismissed
        registry.setTasksForTesting([dismissed])
        #expect(driver.state.phase == .stopping)
        #expect(executor.cancellationRequested)
        #expect(controller.driver == nil)
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

    // MARK: - First open and honest refusals (#1725)

    @Test func secretBearingResultCommandIsRefusedBeforeAnySpawn() async throws {
        let base = try fixture()
        let recipe = base.selection.recipe
        // A result command that needs a secret can never become a launch
        // context: no resolution path exists, so the launch is refused.
        let secret = AgentProjectRecipe(
            scheme: recipe.scheme, kind: recipe.kind,
            canonicalProjectPath: recipe.canonicalProjectPath,
            prerequisites: recipe.prerequisites, setup: recipe.setup, checks: recipe.checks,
            results: recipe.results,
            secretRequirements: ["run": [AgentProjectSecretReference(name: "DEPLOY_TOKEN")]]
        )
        let selection = try AgentProjectRecipe.select(projectCheckedIn: secret, for: base.task.project)
        let binding = try #require(AgentTaskResultActionBinding(
            task: base.task, selection: selection, actionID: "run-example",
            snapshot: base.binding.snapshot
        ))
        let grant = AgentTaskCheckGrant(
            scheme: AgentTaskCheckGrant.currentScheme, id: UUID(), taskID: base.task.id,
            planFingerprint: selection.plan.fingerprint,
            environment: base.binding.snapshot.environment, approvedAt: Date(), revokedAt: nil
        )
        let secretFixture = Fixture(task: base.task, binding: binding, selection: selection, grant: grant)
        let executor = AgentResultExecutorDouble()
        let authority = AgentResultAuthorityProbe(grant: grant)
        let driver = AgentTaskResultActionDriver(binding: binding, executor: executor)
        // The same make-gated shape as the controller's production launch.
        driver.launch { _ in
            let built = context(secretFixture, authority: authority)
            return AgentTaskResultLaunchContext.make(
                binding: built.binding, selection: selection,
                preparation: built.preparation, authority: built.authority
            )
        }
        try #require(await waitUntilMainActor {
            driver.state.phase == .failed(.launchRefused(.authorityChanged))
        })
        #expect(executor.isEmpty)
    }

    @Test func firstOpenOfReadyTaskIsReadyWhenItsIdentityIsCurrent() async throws {
        let opened = try await openVerifiedTask(resolve: { _ in
            .current(AgentVerificationIdentitySnapshot(
                code: ADEContractFixtures.codeState("a"), environment: ADEContractFixtures.environment
            ))
        })
        defer { opened.controller.close() }
        try #require(await waitUntilMainActor { opened.controller.presentation.readiness.isReady })
        // Ready came from the proof alone: no recipe was selected and no
        // result action was bound by opening.
        let taskID = opened.controller.presentation.taskID
        #expect(opened.controller.presentation.action == nil)
        #expect(opened.controller.presentation.identityGap == nil)
        #expect(opened.registry.resultActionSelection(for: taskID) == nil)
        #expect(opened.registry.resultActionDriver(for: taskID) == nil)
    }

    @Test(arguments: [
        AgentVerificationIdentityCaptureResult.unavailable(.unsavedEditorChanges),
        .unavailable(.unavailableBinding), .changed, .cancelled,
    ])
    func firstOpenWithoutProvenIdentityStaysUnverifiedWithItsReason(
        result: AgentVerificationIdentityCaptureResult
    ) async throws {
        let opened = try await openVerifiedTask(resolve: { _ in result })
        defer { opened.controller.close() }
        var expected = AgentTaskResultIdentityGap.unproven
        if case .unavailable(.unsavedEditorChanges) = result { expected = .unsavedEditorChanges }
        try #require(await waitUntilMainActor {
            opened.controller.presentation.identityGap == expected
        })
        #expect(!opened.controller.presentation.readiness.isReady)
        #expect(opened.controller.presentation.readiness.gaps.contains(.codeStateUnknown))
    }

    @Test func firstOpenWithNoProofAttemptStaysUnverifiedAndSelectsNothing() async throws {
        let root = try temporarySwiftPackage()
        defer { try? FileManager.default.removeItem(at: root) }
        let opened = try await openVerifiedTask(projectPath: root.path, resolve: { _ in nil })
        defer { opened.controller.close() }
        try #require(await waitUntilMainActor { opened.controller.proposal != nil })
        let taskID = opened.controller.presentation.taskID
        #expect(opened.controller.presentation.identityGap == .unproven)
        #expect(!opened.controller.presentation.readiness.isReady)
        #expect(opened.registry.resultActionSelection(for: taskID) == nil)
        #expect(opened.registry.resultActionDriver(for: taskID) == nil)
    }

    @Test func identityIsNotCapturedWhileReadyIsUnreachable() async throws {
        let root = try temporarySwiftPackage()
        defer { try? FileManager.default.removeItem(at: root) }
        var captures = 0
        let opened = try await openVerifiedTask(
            projectPath: root.path, mutate: { $0.verificationState = .stale },
            resolve: { _ in
                captures += 1
                return .current(AgentVerificationIdentitySnapshot(
                    code: ADEContractFixtures.codeState("a"), environment: ADEContractFixtures.environment
                ))
            }
        )
        defer { opened.controller.close() }
        try #require(await waitUntilMainActor { opened.controller.proposal != nil })
        #expect(captures == 0)
        #expect(opened.controller.presentation.identityGap == nil)
        #expect(opened.controller.presentation.readiness.gaps.contains(.verificationNotCurrent))
    }

    @Test func openedResultIsNotReadyWhenTheObservedIdentityMoved() async throws {
        let moved = AgentTaskCodeStateIdentity(
            headCommit: String(repeating: "b", count: 40),
            trackedFingerprint: ADEContractFixtures.hex("9"),
            untrackedFingerprint: ADEContractFixtures.hex("9"),
            ignoredRelevantFingerprint: ADEContractFixtures.hex("9")
        )
        let opened = try await openVerifiedTask(resolve: { _ in
            .current(AgentVerificationIdentitySnapshot(
                code: moved, environment: ADEContractFixtures.environment
            ))
        })
        defer { opened.controller.close() }
        try #require(await waitUntilMainActor { opened.controller.presentation.codeState == moved })
        // What was observed is shown as is; the evidence is stale for it.
        #expect(!opened.controller.presentation.readiness.isReady)
        #expect(opened.controller.presentation.readiness.gaps.contains(.staleEvidence(.independentCheck)))
        #expect(opened.controller.presentation.identityGap == nil)
    }

    @Test func findingTextReachesThePresentationOnlyFromItsProvider() throws {
        let reference = ADEContractFixtures.hex("f")
        let finding = "The example exits with code 1 when it is run without arguments."
        let task = try decisionTask(findingReference: reference)
        let registry = AgentTaskRegistry()
        registry.setTasksForTesting([task])
        // The provider closure stays out of #require's sendable expansion,
        // which cannot capture it.
        let controller = AgentTaskResultController(
            registry: registry, taskID: task.id,
            editorPreflight: { .available([], isCurrent: { true }) },
            findingProvider: { decision in
                #expect(decision.unresolvedFindingReference == reference)
                return finding
            }
        )
        let held = try #require(controller)
        defer { held.close() }
        #expect(held.presentation.unresolvedFinding == .text(finding))

        // Without a holder of the text nothing invents it, and the opaque
        // reference is not presented as a finding.
        let bare = try #require(AgentTaskResultController(
            registry: registry, taskID: task.id,
            editorPreflight: { .available([], isCurrent: { true }) }
        ))
        defer { bare.close() }
        #expect(bare.presentation.unresolvedFinding == .textUnavailable)
    }
}
