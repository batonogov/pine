import Darwin
import Foundation
import Synchronization
import Testing
@testable import Pine

@MainActor
@Suite("Reserved worktree durable setup", .serialized)
struct AgentTaskWorktreeSetupPersistenceTests {
    @Test(arguments: ["cancel", "dismiss", "quit"])
    func revocationDuringDurablePreparationCannotRegenerateAnOwner(action: String) async throws {
        let fixture = try await runOnBackground { try SetupPersistenceFixture() }
        defer { fixture.remove() }
        let armed = Mutex(false)
        let entered = Mutex(false)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let store = AgentTaskMetadataStore(storageRoot: fixture.storage, configuration: AgentTaskStoreConfiguration(
            privateComponentCount: 1, faultInjector: .none, hooks: AgentTaskStoreHooks(phase: { point in
                if point == .beforeAtomicRename, armed.withLock({ value in
                    let wasArmed = value
                    value = false
                    return wasArmed
                }) {
                    entered.withLock { $0 = true }
                    _ = release.wait(timeout: .now() + 45)
                }
            })
        ))
        let registry = AgentTaskRegistry(persistence: store)
        let launch = try await fixture.prepareReservation(in: registry)
        let bindings = AgentTaskEnvironmentBindings()
        let lease = try await bindings.reserve(taskID: launch.taskID, runID: UUID(),
            canonicalProject: fixture.project, expectedWorktree: fixture.target)
        let base = try await runOnBackground { try fixture.baseCommit() }
        let checkpoint = AgentTaskReservedWorktreeCheckpoint(
            reservation: lease.snapshot, baseCommit: base, phase: .creationIntent, worktreeProof: nil)
        #expect(await registry.persistWorktreeSetupCheckpoint(checkpoint))
        try await runOnBackground {
            try fixture.git(["worktree", "add", "--no-checkout", "-b",
                AgentTaskEnvironmentBindings.branchName(taskID: lease.taskID, runID: lease.reservationRunID),
                "--", fixture.target.path, base])
        }
        await bindings.revoke(lease)
        armed.withLock { $0 = true }
        let operation = Task {
            await registry.reconcileReservedWorktree(taskID: launch.taskID, bindings: bindings)
        }
        #expect(await waitUntilMainActor({ entered.withLock { $0 } }, ceiling: .seconds(30)))
        switch action {
        case "cancel": registry.cancelLaunch(launch)
        case "dismiss": #expect(registry.dismissTask(launch.taskID))
        default: registry.prepareForApplicationTermination()
        }
        release.signal()
        #expect(await operation.value == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.target.appendingPathComponent("tracked").path))
        #expect(registry.task(for: launch.taskID)?.worktreeSetup?.phase == .creationIntent)
        if action == "cancel" {
            let later = try #require(await registry.reconcileReservedWorktree(taskID: launch.taskID, bindings: bindings))
            try later.validateAuthority()
            #expect(try Data(contentsOf: fixture.target.appendingPathComponent("tracked")) == Data("raw\n".utf8))
        }
    }

    @Test func sequentialSetupAndDismissalDoesNotExhaustSharedBindings() async throws {
        let fixture = try await runOnBackground { try SetupPersistenceFixture() }
        defer { fixture.remove() }
        let registry = AgentTaskRegistry(persistence: fixture.store(),
            limits: AgentTaskPersistenceLimits(maxTasksPerProject: 1))
        let bindings = AgentTaskEnvironmentBindings()
        var targets: [URL] = []
        // One beyond the unchanged 32-reservation budget, also forcing owner eviction.
        for cycle in 0...32 {
            let launch = try await fixture.prepareReservation(in: registry)
            let target = fixture.target.deletingLastPathComponent().appendingPathComponent("cycle-\(cycle)")
            let binding = try #require(await registry.setupReservedWorktree(taskID: launch.taskID, runID: UUID(),
                expectedWorktree: target, bindings: bindings), "reservation cycle \(cycle)")
            #expect(registry.dismissTask(launch.taskID))
            #expect(throws: AgentTaskEnvironmentBindingError.staleBinding) { try binding.validateAuthority() }
            await registry.waitForReservedWorktreeRetirements()
            targets.append(target)
        }
        for target in targets {
            #expect(try Data(contentsOf: target.appendingPathComponent("tracked")) == Data("raw\n".utf8))
        }
    }

    @Test func productionRegistryPersistsPopulatesAndColdAdoptsBeforeAnyProviderRun() async throws {
        let fixture = try await runOnBackground { try SetupPersistenceFixture() }
        defer { fixture.remove() }
        let taskID: UUID
        let runID = UUID()
        do {
            let store = fixture.store()
            let registry = AgentTaskRegistry(persistence: store)
            taskID = try await fixture.prepareTask(in: registry)
            let binding = try #require(await registry.setupReservedWorktree(
                taskID: taskID, runID: runID, expectedWorktree: fixture.target, bindings: AgentTaskEnvironmentBindings()
            ))
            #expect(binding.taskID == taskID)
            let disk = await store.load(project: fixture.identity)
            #expect(disk.tasks.first?.worktreeSetup?.phase == .populated)
            #expect(disk.tasks.first?.worktreeSetup?.reservation.reservationRunID == runID)
            #expect(disk.tasks.first?.runs.isEmpty == true)
            #expect(disk.tasks.first?.verificationState == AgentTaskVerificationState.none)
            #expect(disk.tasks.first?.executionState == .unknown)
            #expect(try Data(contentsOf: fixture.target.appendingPathComponent("tracked")) == Data("raw\n".utf8))
        }
        let restoredStore = fixture.store()
        let restored = AgentTaskRegistry(persistence: restoredStore)
        #expect(await restored.prepareDurableWork(in: fixture.identity))
        #expect(restored.task(for: taskID)?.worktreeSetup?.phase == .populated)
        #expect(await restored.setupReservedWorktree(
            taskID: taskID, runID: UUID(), expectedWorktree: fixture.target, bindings: AgentTaskEnvironmentBindings()
        ) == nil)
        let binding = try #require(await restored.reconcileReservedWorktree(taskID: taskID, bindings: AgentTaskEnvironmentBindings()))
        #expect(binding.reservationRunID == runID)
        #expect(restored.task(for: taskID)?.runs.isEmpty == true)
        #expect(!FileManager.default.fileExists(atPath: fixture.marker.path))
    }

    @Test func checkpointRoundtripAndLegacyAbsenceDoNotDecodeRuntimeAuthority() async throws {
        let fixture = try await runOnBackground { try SetupPersistenceFixture() }
        defer { fixture.remove() }
        var task = fixture.task()
        let legacy = try JSONDecoder().decode(AgentTask.self, from: JSONEncoder().encode(task))
        #expect(legacy.worktreeSetup == nil)
        let store = fixture.store()
        #expect(await store.save(tasks: [task], project: fixture.identity).isDurablySaved)
        let ordinary = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.metadata)) as? [String: Any])
        #expect(ordinary["schemaVersion"] as? Int == 3)
        #expect(await store.load(project: fixture.identity).requiresMigration == false)
        let bindings = AgentTaskEnvironmentBindings()
        let lease = try await bindings.reserve(taskID: task.id, runID: UUID(), canonicalProject: fixture.project, expectedWorktree: fixture.target)
        let base = try await runOnBackground { try fixture.baseCommit() }
        task.worktreeSetup = AgentTaskReservedWorktreeCheckpoint(
            reservation: lease.snapshot, baseCommit: base, phase: .creationIntent, worktreeProof: nil
        )
        #expect(await store.save(tasks: [task], project: fixture.identity).isDurablySaved)
        let critical = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.metadata)) as? [String: Any])
        #expect(critical["schemaVersion"] as? Int == 5)
        let loaded = await store.load(project: fixture.identity)
        #expect(loaded.status == .loaded)
        #expect(loaded.tasks == [task])
        let checkpoint = try #require(loaded.tasks.first?.worktreeSetup)
        let restoredBindings = AgentTaskEnvironmentBindings()
        let restoredLease = try await restoredBindings.restore(checkpoint.reservation)
        #expect(!restoredLease.claimCreationAttempt())
        let owner = AgentTaskReservedWorktreeSetup(lease: restoredLease, bindings: restoredBindings, recovering: checkpoint)
        await #expect(throws: AgentTaskEnvironmentBindingError.unavailableEnvironment) {
            try await owner.reconcile { _ in Issue.record("missing target acquired authority"); return true }
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.target.path))
    }

    @Test(arguments: ["schema", "oldEnvelope", "phase", "scheme", "base", "task", "mode", "proof", "oversize"])
    func futureOrMalformedCheckpointPreservesTheFileAndBlocksDispatch(field: String) async throws {
        let fixture = try await runOnBackground { try SetupPersistenceFixture() }
        defer { fixture.remove() }
        let store = fixture.store()
        let registry = AgentTaskRegistry(persistence: store)
        let taskID = try await fixture.prepareTask(in: registry)
        #expect(await registry.setupReservedWorktree(
            taskID: taskID, runID: UUID(), expectedWorktree: fixture.target, bindings: AgentTaskEnvironmentBindings()
        ) != nil)
        let changed = try await runOnBackground {
            var file = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.metadata)) as? [String: Any])
            var tasks = try #require(file["tasks"] as? [[String: Any]])
            var checkpoint = try #require(tasks[0]["worktreeSetup"] as? [String: Any])
            var reservation = try #require(checkpoint["reservation"] as? [String: Any])
            switch field {
            case "schema": file["schemaVersion"] = 9_999
            case "oldEnvelope": file["schemaVersion"] = 3
            case "phase": checkpoint["phase"] = "futureUnknownPhase"
            case "scheme": checkpoint["scheme"] = 9_999
            case "base": checkpoint["baseCommit"] = "not-a-commit"
            case "task": reservation["taskID"] = UUID().uuidString
            case "mode":
                var root = try #require(reservation["parentRoot"] as? [String: Any])
                root["kind"] = Int(S_IFREG)
                reservation["parentRoot"] = root
            case "proof": checkpoint.removeValue(forKey: "worktreeProof")
            default: reservation["expectedWorktree"] = "file:///" + String(repeating: "x", count: 16_385)
            }
            checkpoint["reservation"] = reservation
            tasks[0]["worktreeSetup"] = checkpoint
            file["tasks"] = tasks
            let data = try JSONSerialization.data(withJSONObject: file, options: [.sortedKeys])
            try data.write(to: fixture.metadata)
            return data
        }
        let restoredStore = fixture.store()
        if case .rejected = await restoredStore.load(project: fixture.identity).status {} else { Issue.record("accepted invalid checkpoint") }
        let restored = AgentTaskRegistry(persistence: restoredStore)
        #expect(await restored.prepareDurableWork(in: fixture.identity) == false)
        #expect(await restored.reconcileReservedWorktree(taskID: taskID, bindings: AgentTaskEnvironmentBindings()) == nil)
        #expect(try Data(contentsOf: fixture.metadata) == changed)
        #expect(try Data(contentsOf: fixture.target.appendingPathComponent("tracked")) == Data("raw\n".utf8))
    }

    @Test func unknownAgentIdentityAndExistingEnvelopeSurviveCheckpointWrites() async throws {
        let fixture = try await runOnBackground { try SetupPersistenceFixture() }
        defer { fixture.remove() }
        var task = fixture.task()
        let encoded = try JSONEncoder().encode(task)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var descriptor = try #require(object["descriptor"] as? [String: Any])
        descriptor["typeIdentifier"] = "future-agent-1796"
        object["descriptor"] = descriptor
        task = try JSONDecoder().decode(AgentTask.self, from: JSONSerialization.data(withJSONObject: object))
        let bindings = AgentTaskEnvironmentBindings()
        let lease = try await bindings.reserve(taskID: task.id, runID: UUID(), canonicalProject: fixture.project, expectedWorktree: fixture.target)
        task.worktreeSetup = AgentTaskReservedWorktreeCheckpoint(reservation: lease.snapshot,
            baseCommit: try await runOnBackground { try fixture.baseCommit() }, phase: .creationIntent, worktreeProof: nil)
        let envelope = AgentTaskEnvelopeState(rememberedAgent: AgentDescriptor(agentType: .codex),
            rememberedAgentUpdatedAt: Date(timeIntervalSince1970: 1_794_700_000))
        let store = fixture.store()
        #expect(await store.save(tasks: [task], envelope: envelope, project: fixture.identity).isDurablySaved)
        let loaded = await store.load(project: fixture.identity)
        #expect(loaded.tasks.first?.descriptor.typeIdentifier == "future-agent-1796")
        #expect(loaded.tasks.first?.worktreeSetup == task.worktreeSetup)
        #expect(loaded.envelope == envelope)
    }

    @Test func oneShotCheckpointCASRejectsReplaysAndReservationChanges() async throws {
        let fixture = try await runOnBackground { try SetupPersistenceFixture() }
        defer { fixture.remove() }
        let registry = AgentTaskRegistry(persistence: fixture.store())
        let reservation = try await fixture.prepareReservation(in: registry)
        let taskID = reservation.taskID
        let bindings = AgentTaskEnvironmentBindings()
        let lease = try await bindings.reserve(taskID: taskID, runID: UUID(), canonicalProject: fixture.project, expectedWorktree: fixture.target)
        let base = try await runOnBackground { try fixture.baseCommit() }
        let first = AgentTaskReservedWorktreeCheckpoint(reservation: lease.snapshot, baseCommit: base, phase: .creationIntent, worktreeProof: nil)
        #expect(await registry.persistWorktreeSetupCheckpoint(first))
        #expect(await registry.persistWorktreeSetupCheckpoint(first) == false)
        let changed = AgentTaskReservedWorktreeCheckpoint(reservation: lease.snapshot,
            baseCommit: String(repeating: "0", count: 40), phase: .creationIntent, worktreeProof: nil)
        #expect(await registry.persistWorktreeSetupCheckpoint(changed) == false)
        #expect(registry.task(for: taskID)?.worktreeSetup == first)
        registry.cancelLaunch(reservation)
        #expect(registry.task(for: taskID)?.worktreeSetup == first)
        #expect(registry.reconcileTerminalRetention(at: .distantFuture) == 0)
    }

    @Test func cancelledLaunchRequiresFreshRuntimeAdoptionWithoutRecreatingFiles() async throws {
        let fixture = try await runOnBackground { try SetupPersistenceFixture() }
        defer { fixture.remove() }
        let registry = AgentTaskRegistry(persistence: fixture.store())
        let launch = try await fixture.prepareReservation(in: registry)
        let bindings = AgentTaskEnvironmentBindings()
        let initial = try #require(await registry.setupReservedWorktree(taskID: launch.taskID, runID: UUID(),
            expectedWorktree: fixture.target, bindings: bindings))
        registry.cancelLaunch(launch)
        let recovered = try #require(await registry.reconcileReservedWorktree(taskID: launch.taskID, bindings: bindings))
        #expect(recovered.id != initial.id)
        #expect(throws: AgentTaskEnvironmentBindingError.staleBinding) { try initial.validateAuthority() }
        try recovered.validateAuthority()
        #expect(try Data(contentsOf: fixture.target.appendingPathComponent("tracked")) == Data("raw\n".utf8))
    }

    @Test(arguments: ["cancel", "dismiss", "quit"])
    func registryRevocationImmediatelyFencesRetainedAdoptedConsumers(action: String) async throws {
        let fixture = try await runOnBackground { try SetupPersistenceFixture() }
        defer { fixture.remove() }
        let registry = AgentTaskRegistry(persistence: fixture.store())
        let launch = try await fixture.prepareReservation(in: registry)
        let bindings = AgentTaskEnvironmentBindings()
        let binding = try #require(await registry.setupReservedWorktree(taskID: launch.taskID, runID: UUID(),
            expectedWorktree: fixture.target, bindings: bindings))
        let filesystem = try await bindings.revalidate(binding)
        try binding.validateAuthority()
        switch action {
        case "cancel": registry.cancelLaunch(launch)
        case "dismiss": #expect(registry.dismissTask(launch.taskID))
        default: registry.prepareForApplicationTermination()
        }
        // Assert before any await, including explicit owner retirement.
        #expect(throws: AgentTaskEnvironmentBindingError.staleBinding) { try binding.validateAuthority() }
        #expect(await runOnBackground {
            (try? binding.validateAuthority()) != nil && filesystem.revalidate()
        } == false)
        #expect(await runOnBackground { filesystem.revalidate() })
    }

    @Test(arguments: [false, true])
    func revocationWhileIntentIsPublishingCannotReleaseThePhysicalEffect(termination: Bool) async throws {
        let fixture = try await runOnBackground { try SetupPersistenceFixture() }
        defer { fixture.remove() }
        let armed = Mutex(false)
        let entered = Mutex(false)
        let release = DispatchSemaphore(value: 0)
        let store = AgentTaskMetadataStore(storageRoot: fixture.storage, configuration: AgentTaskStoreConfiguration(
            privateComponentCount: 1, faultInjector: .none, hooks: AgentTaskStoreHooks(phase: { point in
                if point == .beforeAtomicRename, armed.withLock({ $0 }) {
                    entered.withLock { $0 = true }
                    _ = release.wait(timeout: .now() + 45)
                }
            })
        ))
        let registry = AgentTaskRegistry(persistence: store)
        let taskID = try await fixture.prepareTask(in: registry)
        _ = registry.addTaskChangeObserver { _, tasks in
            armed.withLock { $0 = tasks.first?.worktreeSetup?.phase == .creationIntent && tasks.first?.lifecycle != .dismissed }
        }
        let operation = Task {
            await registry.setupReservedWorktree(taskID: taskID, runID: UUID(), expectedWorktree: fixture.target,
                bindings: AgentTaskEnvironmentBindings())
        }
        #expect(await waitUntilMainActor({ entered.withLock { $0 } }, ceiling: .seconds(30)))
        if termination {
            registry.prepareForApplicationTermination()
        } else {
            #expect(registry.dismissTask(taskID))
        }
        armed.withLock { $0 = false }
        release.signal()
        #expect(await operation.value == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.target.path))
        #expect(registry.task(for: taskID)?.hasUnresolvedWorktreeSetup == true)
    }

    @Test(arguments: ["creationIntent", "populationIntent", "populated"])
    func realWriteFailureNeverReleasesTheNextEffect(phase: String) async throws {
        let fixture = try await runOnBackground { try SetupPersistenceFixture() }
        defer { fixture.remove() }
        let fail = Mutex(false)
        let injector = PersistenceFaultInjector { _, point in
            if fail.withLock({ $0 }), point == .beforeWrite { throw PersistenceFailureKind.permissionDenied }
        }
        let store = fixture.store(injector: injector)
        let registry = AgentTaskRegistry(persistence: store)
        let taskID = try await fixture.prepareTask(in: registry)
        let bindings = AgentTaskEnvironmentBindings()
        let lease = try await bindings.reserve(taskID: taskID, runID: UUID(), canonicalProject: fixture.project, expectedWorktree: fixture.target)
        let owner = AgentTaskReservedWorktreeSetup(lease: lease, bindings: bindings)
        let result = await owner.create { checkpoint in
            fail.withLock { $0 = checkpoint.phase.rawValue == phase }
            return await registry.persistWorktreeSetupCheckpoint(checkpoint)
        }
        #expect(result == .reconciliationRequired)
        fail.withLock { $0 = false }
        let disk = await store.load(project: fixture.identity)
        switch phase {
        case "creationIntent":
            #expect(!FileManager.default.fileExists(atPath: fixture.target.path))
            #expect(disk.tasks.isEmpty)
        case "populationIntent":
            #expect(disk.tasks.first?.worktreeSetup?.phase == .creationIntent)
            #expect(!FileManager.default.fileExists(atPath: fixture.target.appendingPathComponent("tracked").path))
        default:
            #expect(disk.tasks.first?.worktreeSetup?.phase == .populationIntent)
            #expect(try Data(contentsOf: fixture.target.appendingPathComponent("tracked")) == Data("raw\n".utf8))
            let restored = AgentTaskRegistry(persistence: fixture.store())
            #expect(await restored.prepareDurableWork(in: fixture.identity))
            #expect(await restored.reconcileReservedWorktree(taskID: taskID, bindings: AgentTaskEnvironmentBindings()) != nil)
        }
    }

    @Test func unknownPostPublicationDurabilityDoesNotDispatchPopulationOrReplayAfterRestore() async throws {
        let fixture = try await runOnBackground { try SetupPersistenceFixture() }
        defer { fixture.remove() }
        let fail = Mutex(false)
        let injector = PersistenceFaultInjector { _, point in
            if fail.withLock({ $0 }), point == .afterAtomicReplace { throw PersistenceFailureKind.fsync }
        }
        let store = fixture.store(injector: injector)
        let registry = AgentTaskRegistry(persistence: store)
        let taskID = try await fixture.prepareTask(in: registry)
        let bindings = AgentTaskEnvironmentBindings()
        let lease = try await bindings.reserve(taskID: taskID, runID: UUID(), canonicalProject: fixture.project, expectedWorktree: fixture.target)
        let owner = AgentTaskReservedWorktreeSetup(lease: lease, bindings: bindings)
        #expect(await owner.create { checkpoint in
            fail.withLock { $0 = checkpoint.phase == .populationIntent }
            return await registry.persistWorktreeSetupCheckpoint(checkpoint)
        } == .reconciliationRequired)
        #expect(!FileManager.default.fileExists(atPath: fixture.target.appendingPathComponent("tracked").path))
        if case .publishedButDurabilityUnknown = registry.saveResultByProject[fixture.identity.persistenceKey] {} else {
            Issue.record("unknown durability was not retained")
        }
        let restored = AgentTaskRegistry(persistence: fixture.store())
        #expect(await restored.prepareDurableWork(in: fixture.identity))
        #expect(restored.task(for: taskID)?.worktreeSetup?.phase == .populationIntent)
        #expect(await restored.reconcileReservedWorktree(taskID: taskID, bindings: AgentTaskEnvironmentBindings()) == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.target.appendingPathComponent("tracked").path))
    }

    @Test func unresolvedIntentCannotBeShedByDiskOrRuntimeRetention() async throws {
        let fixture = try await runOnBackground { try SetupPersistenceFixture() }
        defer { fixture.remove() }
        var task = fixture.task()
        let bindings = AgentTaskEnvironmentBindings()
        let lease = try await bindings.reserve(taskID: task.id, runID: UUID(), canonicalProject: fixture.project, expectedWorktree: fixture.target)
        task.worktreeSetup = AgentTaskReservedWorktreeCheckpoint(reservation: lease.snapshot,
            baseCommit: try await runOnBackground { try fixture.baseCommit() }, phase: .creationIntent, worktreeProof: nil)
        task.lifecycle = .dismissed
        var second = fixture.task()
        let other = second
        let otherLease = try await bindings.reserve(taskID: other.id, runID: UUID(), canonicalProject: fixture.project,
            expectedWorktree: fixture.target.deletingLastPathComponent().appendingPathComponent("second"))
        second.worktreeSetup = AgentTaskReservedWorktreeCheckpoint(reservation: otherLease.snapshot,
            baseCommit: try await runOnBackground { try fixture.baseCommit() }, phase: .creationIntent, worktreeProof: nil)
        second.lifecycle = .dismissed
        let store = AgentTaskMetadataStore(storageRoot: fixture.storage, limits: AgentTaskPersistenceLimits(maxTasksPerProject: 1),
            configuration: AgentTaskStoreConfiguration(privateComponentCount: 1, faultInjector: .none))
        #expect(await store.save(tasks: [task, second], project: fixture.identity) == .rejected(.storageLimit))
        #expect(await store.save(tasks: [task], project: fixture.identity).isDurablySaved)
        let loaded = await store.load(project: fixture.identity)
        #expect(loaded.tasks.first?.worktreeSetup == task.worktreeSetup)
        let registry = AgentTaskRegistry(persistence: store, limits: AgentTaskPersistenceLimits(maxTasksPerProject: 1))
        #expect(await registry.prepareDurableWork(in: fixture.identity))
        let attempted = registry.preparePineLaunch(descriptor: AgentDescriptor(agentType: .codex, launchExecutable: "codex"),
            context: fixture.context(availability: .available), title: nil, objective: nil,
            boundary: AgentTaskLaunchBoundary(generationFloor: 0, capturedAt: Date()))
        #expect(attempted == .rejected)
        #expect(registry.task(for: task.id)?.worktreeSetup == task.worktreeSetup)
    }
}

nonisolated private struct SetupPersistenceFixture: Sendable {
    let root: URL
    let project: URL
    let target: URL
    let storage: URL
    let marker: URL
    var identity: AgentTaskProjectIdentity { AgentTaskProjectIdentity(canonicalProjectPath: project.path, canonicalWorktreePath: project.path) }
    var metadata: URL { AgentTaskMetadataStore.metadataURL(for: identity, storageRoot: storage) }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PineSetupPersistence-\(UUID())").resolvingSymlinksInPath()
        project = root.appendingPathComponent("project")
        target = root.appendingPathComponent("tasks/target")
        storage = root.appendingPathComponent("storage")
        marker = root.appendingPathComponent("executed")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let acl = GitCommand.runExecutable(URL(fileURLWithPath: "/bin/chmod"), arguments: ["-N", root.path], at: root)
        guard acl.succeeded else { throw CocoaError(.fileWriteNoPermission) }
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: false)
        try git(["init", "-b", "main"])
        try Data("raw\n".utf8).write(to: project.appendingPathComponent("tracked"))
        try Data("* filter=hostile text eol=crlf\n".utf8).write(to: project.appendingPathComponent(".gitattributes"))
        try git(["add", "."])
        try git(["-c", "user.name=Pine Test", "-c", "user.email=pine@example.invalid", "commit", "-m", "fixture"])
        let hook = root.appendingPathComponent("hook")
        try Data("#!/bin/sh\nprintf executed >> '\(marker.path)'\n".utf8).write(to: hook)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hook.path)
        for (key, value) in [("core.fsmonitor", hook.path), ("filter.hostile.process", hook.path), ("filter.hostile.required", "true")] {
            try git(["config", key, value])
        }
    }

    func store(injector: PersistenceFaultInjector = .none) -> AgentTaskMetadataStore {
        AgentTaskMetadataStore(storageRoot: storage,
            configuration: AgentTaskStoreConfiguration(privateComponentCount: 1, faultInjector: injector))
    }
    func git(_ arguments: [String]) throws {
        guard run(arguments).succeeded else { throw CocoaError(.fileWriteUnknown) }
    }
    func run(_ arguments: [String]) -> GitCommandResult {
        GitCommand.runExecutable(URL(fileURLWithPath: "/usr/bin/env"),
            arguments: AgentTaskReservedWorktreeSetup.arguments(arguments), at: project)
    }
    func baseCommit() throws -> String {
        let result = run(["rev-parse", "HEAD"])
        guard result.succeeded else { throw CocoaError(.fileReadUnknown) }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    @MainActor func context(availability: AgentTaskRouteAvailability = .missing) -> AgentTaskBridgeContext {
        let terminal = UUID()
        return AgentTaskBridgeContext(project: identity, route: AgentTaskRoute(paneID: UUID(), tabID: terminal,
            terminalID: terminal, availability: availability), origin: .pineLaunched,
            observedAt: Date())
    }
    @MainActor func task() -> AgentTask {
        var task = AgentTask(descriptor: AgentDescriptor(agentType: .codex), context: context())
        task.lifecycle = .paused
        return task
    }
    @MainActor func prepareTask(in registry: AgentTaskRegistry) async throws -> UUID {
        try await prepareReservation(in: registry).taskID
    }
    @MainActor func prepareReservation(in registry: AgentTaskRegistry) async throws -> AgentTaskLaunchReservation {
        guard await registry.prepareDurableWork(in: identity) else { throw CocoaError(.fileWriteUnknown) }
        let result = registry.preparePineLaunch(descriptor: AgentDescriptor(agentType: .codex, launchExecutable: "codex"),
            context: context(availability: .available), title: "setup", objective: "controlled fixture",
            boundary: AgentTaskLaunchBoundary(generationFloor: 0, capturedAt: Date()))
        guard case .reserved(let reservation) = result else { throw CocoaError(.fileWriteUnknown) }
        return reservation
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}
