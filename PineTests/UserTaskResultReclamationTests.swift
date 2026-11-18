import Foundation
import Observation
import Testing

@testable import Pine

nonisolated private final class CommandResultSpawnGate: @unchecked Sendable {
    private let lock = NSLock()
    private let release = DispatchSemaphore(value: 0)
    private var entered = false
    private var spawns = 0
    var hasEntered: Bool { lock.withLock { entered } }
    var spawnCount: Int { lock.withLock { spawns } }
    func recordSpawn() { lock.withLock { spawns += 1 } }
    func resume() { release.signal() }
    func wait() throws {
        lock.withLock { entered = true }
        guard release.wait(timeout: .now() + .seconds(120)) == .success else {
            throw CocoaError(.userCancelled)
        }
    }
}

#if DEBUG
nonisolated private final class CommandResultObservationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var invalidated = false
    var didInvalidate: Bool { lock.withLock { invalidated } }
    func recordInvalidation() { lock.withLock { invalidated = true } }
}

@MainActor
private final class CommandResultRecoveryGate {
    private(set) var reached = false
    private var waiter: CheckedContinuation<Void, Never>?
    func pause() async {
        reached = true
        await withCheckedContinuation { waiter = $0 }
    }
    func resume() {
        waiter?.resume()
        waiter = nil
    }
}

@MainActor
private final class CommandResultPublicationGate {
    var heldPreparations: Set<UUID> = []
    private(set) var reachedPreparations: Set<UUID> = []
    private(set) var capturedPreparations: Set<UUID>?
    private(set) var firstWrite: Set<UUID>?
    private var preparationWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var writerWaiter: CheckedContinuation<Void, Never>?

    func checkpoint(_ checkpoint: UserTaskResultCheckpoint) async {
        switch checkpoint {
        case .recovered, .recoveryDropped:
            break
        case .preparing(let id):
            reachedPreparations.insert(id)
            if heldPreparations.contains(id) {
                await withCheckedContinuation { preparationWaiters[id] = $0 }
            }
        case .capturedPreparations(let ids):
            if capturedPreparations == nil { capturedPreparations = ids }
        case .beforeWrite(let ids):
            if firstWrite == nil {
                firstWrite = ids
                await withCheckedContinuation { writerWaiter = $0 }
            }
        }
    }

    func releasePreparation(_ id: UUID) {
        heldPreparations.remove(id)
        preparationWaiters.removeValue(forKey: id)?.resume()
    }

    func releaseWriter() {
        writerWaiter?.resume()
        writerWaiter = nil
    }

    func releaseAll() {
        heldPreparations.removeAll()
        for waiter in preparationWaiters.values { waiter.resume() }
        preparationWaiters.removeAll()
        releaseWriter()
    }
}
#endif

@Suite("Command results across actual reclamation", .serialized)
@MainActor
struct UserTaskResultReclamationTests {
    #if DEBUG
    @Test("successful recovery invalidates observation of the hidden output affordance")
    func recoveryInvalidatesOutputObservation() async throws {
        // While recovery is still loading there is nothing to show: the
        // affordance appears only for restored runs or a failed recovery.
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = UserTaskResultPersistence(directory: root.appendingPathComponent("results"))
        // Seed one durable result on the same root so the recovery under
        // observation publishes a real state change (a restored run).
        let seeder = UserTaskRunStore(resultPersistence: persistence)
        try #require(seeder.updateResultRoot(root))
        let seed = start(in: seeder)
        finish(seed, in: seeder)
        try #require(await seeder.flushResultPersistence())
        let store = UserTaskRunStore(resultPersistence: persistence)
        let gate = CommandResultRecoveryGate()
        defer { gate.resume() }
        store.resultCheckpointForTesting = { checkpoint in
            if case .recovered = checkpoint { await gate.pause() }
        }
        try #require(store.updateResultRoot(root))
        try #require(await waitUntilMainActor { gate.reached })
        #expect(store.runs.isEmpty)
        #expect(!store.resultPersistenceFailed)
        #expect(!store.isOutputVisible)
        let probe = CommandResultObservationProbe()
        let showedOutput = withObservationTracking {
            UserTaskRunPresenter(store: store).showsOutputButton
        } onChange: {
            probe.recordInvalidation()
        }
        #expect(!showedOutput)
        #expect(!probe.didInvalidate)
        gate.resume()
        try #require(await waitUntilMainActor { !store.hasPendingResultPersistence })
        #expect(probe.didInvalidate)
        #expect(store.runs.count == 1)
        #expect(store.run(forID: seed.id)?.state == .failed)
        #expect(!store.resultPersistenceFailed)
        #expect(UserTaskRunPresenter(store: store).showsOutputButton)
    }

    @Test("reclaiming mid-recovery drops the orphaned load and loses nothing")
    func reclamationDuringRecoveryLosesNothing() async throws {
        try #require(PineStorageContext.isTestHost)
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = UserTaskResultPersistence()
        let initial = try await persistence.load(root: root)
        let now = Date()
        func record(id: UUID, finishedAge: TimeInterval) -> UserTaskResultRecord {
            UserTaskResultRecord(
                id: id, commandIdentity: UserTaskResultRecord.identity("command"),
                taskIdentity: UserTaskResultRecord.identity("task"),
                startedAt: now.addingTimeInterval(-finishedAge - 1),
                finishedAt: now.addingTimeInterval(-finishedAge),
                state: .succeeded, exitCode: 0, processExitCode: 0,
                outputCaptureSucceeded: true, preSpawnRejected: false, timedOut: false,
                cleanupSucceeded: true, standardInputCompleted: true, output: nil
            )
        }
        let validID = UUID()
        let expiredID = UUID()
        let seed = UserTaskResultPersistence.Snapshot(
            version: 1, workspace: initial.workspace, revision: UUID(),
            records: [
                record(id: validID, finishedAge: 3_600),
                record(id: expiredID, finishedAge: UserTaskResultRecord.lifetime + 1)
            ]
        )
        let path = recoveryPath(workspace: initial.workspace)
        defer {
            try? FileManager.default.removeItem(at: path)
            try? FileManager.default.removeItem(
                at: path.deletingPathExtension().appendingPathExtension("lock")
            )
        }
        try await runOnBackground {
            let created = FileManager.default.createFile(
                atPath: path.path, contents: try JSONEncoder().encode(seed),
                attributes: [.posixPermissions: 0o600]
            )
            guard created else { throw CocoaError(.fileWriteUnknown) }
        }
        let registry = makeRegistry()
        defer { _ = registry.destroyAllProjects() }
        var recoveryDropped = false
        let gate = CommandResultRecoveryGate()
        defer { gate.resume() }
        let original = try #require(registry.projectManager(for: root))
        original.taskRunStore.resultCheckpointForTesting = { checkpoint in
            if case .recovered = checkpoint { await gate.pause() }
            if case .recoveryDropped = checkpoint { recoveryDropped = true }
        }
        try #require(await waitUntilMainActor { gate.reached })
        registry.closeProjectWindow(root)
        registry.runBackgroundReclamationPassForTesting()
        let canonical = registry.canonicalProjectURL(root)
        #expect(registry.openProjects[canonical] == nil)
        #expect(original.presentationLifecycle == .destroyed)
        #expect(try await persistence.load(root: root) == seed)
        gate.resume()
        try #require(await waitUntilMainActor { recoveryDropped })
        #expect(try await persistence.load(root: root) == seed)
        let reopened = try #require(registry.projectManager(for: root))
        try #require(await reopened.taskRunStore.flushResultPersistence())
        let pruned = try await persistence.load(root: root)
        #expect(pruned.revision != seed.revision)
        #expect(pruned.records.map(\.id) == [validID])
        #expect(reopened.taskRunStore.run(forID: validID)?.state == .succeeded)
        #expect(reopened.taskRunStore.run(forID: expiredID) == nil)
    }
    #endif

    @Test("failed read-only recovery does not restart forever during reclamation")
    func failedReadOnlyRecoveryDoesNotRetainManager() async throws {
        try #require(PineStorageContext.isTestHost)
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let initial = try await UserTaskResultPersistence().load(root: root)
        let path = recoveryPath(workspace: initial.workspace)
        defer {
            try? FileManager.default.removeItem(at: path)
            try? FileManager.default.removeItem(
                at: path.deletingPathExtension().appendingPathExtension("lock")
            )
        }
        try await runOnBackground {
            let created = FileManager.default.createFile(
                atPath: path.path, contents: Data("invalid-json".utf8),
                attributes: [.posixPermissions: 0o600]
            )
            guard created else { throw CocoaError(.fileWriteUnknown) }
        }
        let registry = makeRegistry()
        defer { _ = registry.destroyAllProjects() }
        let original = try #require(registry.projectManager(for: root))
        #expect(!(await original.taskRunStore.flushResultPersistence()))
        #expect(original.taskRunStore.resultPersistenceFailed)
        #expect(!original.hasPendingCommandResults)
        #expect(await original.flushCommandResultPersistence())
        registry.closeProjectWindow(root)
        registry.runBackgroundReclamationPassForTesting()
        #expect(registry.openProjects[registry.canonicalProjectURL(root)] == nil)
        #expect(original.presentationLifecycle == .destroyed)
        #expect(try Data(contentsOf: path) == Data("invalid-json".utf8))
    }

    @Test("reclamation retries failed writes without releasing the only copy", arguments: [false, true])
    func failedWriteKeepsManager(explicitRelease: Bool) async throws {
        try #require(PineStorageContext.isTestHost)
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = makeRegistry()
        defer { _ = registry.destroyAllProjects() }
        let original = try #require(registry.projectManager(for: root))
        let store = original.taskRunStore
        let seed = start(in: store)
        finish(seed, in: store)
        try #require(await store.flushResultPersistence())
        let disk = try await UserTaskResultPersistence().load(root: root)
        let path = PineStorageContext.applicationSupportDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("Pine/CommandResults")
            .appendingPathComponent(disk.workspace.identity + ".json")
        try await runOnBackground {
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: path.path)
        }
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path) }
        defer {
            try? FileManager.default.removeItem(at: path)
            try? FileManager.default.removeItem(
                at: path.deletingPathExtension().appendingPathExtension("lock")
            )
        }
        let run = start(in: store)
        await store.retainOutput(forRunID: run.id)
        registry.closeProjectWindow(root)
        finish(run, in: store)
        #expect(!(await store.flushResultPersistence()))
        if explicitRelease {
            #expect(!registry.releaseIdleWorktreeProject(root))
        } else {
            registry.runBackgroundReclamationPassForTesting()
        }
        let canonical = registry.canonicalProjectURL(root)
        #expect(registry.openProjects[canonical] === original)
        #expect(original.hasPendingCommandResults)
        #expect(!registry.destroyAllProjects())
        try await runOnBackground {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        }
        try #require(await waitUntilMainActor {
            if explicitRelease {
                _ = registry.releaseIdleWorktreeProject(root)
            } else {
                registry.runBackgroundReclamationPassForTesting()
            }
            return registry.openProjects[canonical] == nil
        })
        let reopened = try #require(registry.projectManager(for: root))
        try #require(await reopened.taskRunStore.flushResultPersistence())
        #expect(reopened.taskRunStore.run(forID: run.id)?.stdout == "retained-stdout")
        #expect(reopened.taskRunStore.run(forID: run.id)?.exitCode == 7)
    }

    @Test("a deleted project root releases pending result ownership and Quit")
    func deletedRootReleasesOwnership() async throws {
        try #require(PineStorageContext.isTestHost)
        let root = try makeRoot()
        let resultFiles = defaultResultFiles(forRoot: root)
        defer { resultFiles.forEach { try? FileManager.default.removeItem(at: $0) } }
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = makeRegistry()
        defer { _ = registry.destroyAllProjects() }
        let original = try #require(registry.projectManager(for: root))
        let store = original.taskRunStore
        let first = start(in: store)
        finish(first, in: store)
        try #require(await store.flushResultPersistence())
        registry.closeProjectWindow(root)
        try await runOnBackground {
            try FileManager.default.removeItem(at: root)
        }
        let second = start(in: store)
        finish(second, in: store)
        try #require(await waitUntilMainActor { !store.hasUnpersistedResultOwnership })
        #expect(!store.hasPendingResultPersistence)
        #expect(!store.resultPersistenceFailed)
        #expect(await original.flushCommandResultPersistence())
        #expect(!registry.hasPendingCommandResults)
        let canonical = registry.canonicalProjectURL(root)
        try #require(await waitUntilMainActor {
            registry.runBackgroundReclamationPassForTesting()
            return registry.openProjects[canonical] == nil
        })
        #expect(original.presentationLifecycle == .destroyed)
        #expect(registry.projectManager(for: root) == nil)
    }

    @Test("a recreated project root re-derives result persistence under the new identity")
    func recreatedRootRecoversResultPersistence() async throws {
        try #require(PineStorageContext.isTestHost)
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let resultFilesX = defaultResultFiles(forRoot: root)
        #expect(resultFilesX.count == 2)
        defer {
            for file in resultFilesX + defaultResultFiles(forRoot: root) {
                try? FileManager.default.removeItem(at: file)
            }
        }
        let registry = makeRegistry()
        defer { _ = registry.destroyAllProjects() }
        let original = try #require(registry.projectManager(for: root))
        let store = original.taskRunStore
        let first = start(in: store)
        finish(first, in: store)
        try #require(await store.flushResultPersistence())
        #expect(FileManager.default.fileExists(atPath: resultFilesX[0].path))
        registry.closeProjectWindow(root)
        try await runOnBackground {
            try FileManager.default.removeItem(at: root)
        }
        // Finishing while the root is missing must not poison the store.
        let mid = start(in: store)
        finish(mid, in: store)
        try #require(await waitUntilMainActor { !store.hasUnpersistedResultOwnership })
        #expect(!store.resultPersistenceFailed)
        // Recreate the project directory: a new inode means a new workspace
        // identity, and the identity-X file is orphaned by design.
        try await runOnBackground {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        let reopened = try #require(registry.projectManager(for: root))
        #expect(reopened === original)
        try #require(await reopened.taskRunStore.flushResultPersistence())
        let second = start(in: reopened.taskRunStore)
        await reopened.taskRunStore.retainOutput(forRunID: second.id)
        finish(second, in: reopened.taskRunStore)
        try #require(await reopened.flushCommandResultPersistence())
        #expect(!reopened.hasPendingCommandResults)
        #expect(reopened.taskRunStore.run(forID: second.id)?.retainedOutput?.stdout == "retained-stdout")
        let resultFilesY = defaultResultFiles(forRoot: root)
        #expect(resultFilesY != resultFilesX)
        #expect(FileManager.default.fileExists(atPath: resultFilesY[0].path))
    }

    @Test("a real bounded argv command finishes after close and survives actual reclamation")
    func controlledCommandSurvivesReclamation() async throws {
        try #require(PineStorageContext.isTestHost)
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let resultFiles = defaultResultFiles(forRoot: root)
        defer { resultFiles.forEach { try? FileManager.default.removeItem(at: $0) } }
        let registry = makeRegistry()
        defer { _ = registry.destroyAllProjects() }
        let original = try #require(registry.projectManager(for: root))
        let store = original.taskRunStore
        let run = store.start(UserTaskRun(
            taskID: "controlled-argv", taskLabel: "Controlled argv",
            command: "/usr/bin/printf retained-command-output", replacesFileContent: false
        ))
        await store.retainOutput(forRunID: run.id)
        let gate = CommandResultSpawnGate()
        defer { gate.resume() }
        // Use the landed literal-argv runner, not an interactive shell or user startup files.
        let runner = UserTaskRunner(timeout: 10, processDidSpawn: { _ in gate.recordSpawn() })
        let handle = runner.run(
            taskID: run.taskID,
            executableURL: URL(fileURLWithPath: "/usr/bin/printf"),
            arguments: ["retained-command-output"],
            workingDirectory: root,
            preSpawnValidation: { _ in try gate.wait() },
            progress: UserTaskProgress(
                onStart: { Task { @MainActor in run.markRunning() } },
                onFinish: { outcome, cancelled in
                    Task { @MainActor in
                        store.finishRun(id: run.id, outcome: outcome, cancelled: cancelled)
                    }
                }
            )
        )
        defer { _ = handle.cancel() }
        store.registerCancellation(handle, forRunID: run.id)
        try #require(await waitUntilMainActor { gate.hasEntered })
        registry.closeProjectWindow(root)
        #expect(original.paneManager.allTerminalTabs.isEmpty)
        gate.resume()
        let canonical = registry.canonicalProjectURL(root)
        try #require(await waitUntilMainActor {
            registry.runBackgroundReclamationPassForTesting()
            return registry.openProjects[canonical] == nil
        })
        #expect(original.presentationLifecycle == .destroyed)
        #expect(run.state == .succeeded)
        let reopened = try #require(registry.projectManager(for: root))
        try #require(await reopened.taskRunStore.flushResultPersistence())
        let restored = try #require(reopened.taskRunStore.run(forID: run.id))
        #expect(reopened !== original)
        #expect(restored.state == .succeeded)
        #expect(restored.exitCode == 0)
        #expect(restored.stdout == "retained-command-output")
        #expect(reopened.taskRunStore.runs.count == 1)
        #expect(!reopened.hasOutstandingUserTaskExecution)
        #expect(gate.spawnCount == 1)
    }

    @Test("per-run retained output survives close, completion, actual reclamation and repeated reopen")
    func optedInResultSurvivesReclamation() async throws {
        try #require(PineStorageContext.isTestHost)
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let resultFiles = defaultResultFiles(forRoot: root)
        defer { resultFiles.forEach { try? FileManager.default.removeItem(at: $0) } }
        let registry = makeRegistry()
        defer { _ = registry.destroyAllProjects() }
        let original = try #require(registry.projectManager(for: root))
        let run = start(in: original.taskRunStore)
        await original.taskRunStore.retainOutput(forRunID: run.id)
        registry.closeProjectWindow(root)
        finish(run, in: original.taskRunStore)
        let canonical = registry.canonicalProjectURL(root)
        try #require(await waitUntilMainActor {
            registry.runBackgroundReclamationPassForTesting()
            return registry.openProjects[canonical] == nil
        })
        #expect(original.presentationLifecycle == .destroyed)
        #expect(original.paneManager.allTerminalTabs.isEmpty)
        for _ in 0..<2 {
            let reopened = try #require(registry.projectManager(for: root))
            #expect(reopened !== original)
            try #require(await reopened.taskRunStore.flushResultPersistence())
            let restored = try #require(reopened.taskRunStore.run(forID: run.id))
            #expect(reopened.taskRunStore.runs.count == 1)
            #expect(restored.stdout == "retained-stdout")
            #expect(restored.stderr == "retained-stderr")
            #expect(restored.exitCode == 7)
            #expect(restored.state == .failed)
            #expect(restored.command.isEmpty)
            #expect(!reopened.hasOutstandingUserTaskExecution)
            registry.closeProjectWindow(root)
            #expect(registry.releaseIdleWorktreeProject(root))
        }
    }

    #if DEBUG
    @Test("late prepared result cannot inherit an older write acknowledgement")
    func latePreparationCannotInheritAcknowledgement() async throws {
        try #require(PineStorageContext.isTestHost)
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let resultFiles = defaultResultFiles(forRoot: root)
        defer { resultFiles.forEach { try? FileManager.default.removeItem(at: $0) } }
        let registry = makeRegistry()
        defer { _ = registry.destroyAllProjects() }
        let original = try #require(registry.projectManager(for: root))
        let store = original.taskRunStore
        try #require(await store.flushResultPersistence())
        let gate = CommandResultPublicationGate()
        defer { gate.releaseAll() }
        store.resultCheckpointForTesting = { await gate.checkpoint($0) }
        let first = start(in: store)
        let second = start(in: store)
        let late = start(in: store)
        for run in [first, second, late] { await store.retainOutput(forRunID: run.id) }
        gate.heldPreparations = [second.id, late.id]
        finish(second, in: store)
        try #require(await waitUntilMainActor { gate.reachedPreparations.contains(second.id) })
        finish(first, in: store)
        try #require(await waitUntilMainActor { gate.capturedPreparations != nil })
        #expect(gate.capturedPreparations == Set([second.id]))
        finish(late, in: store)
        try #require(await waitUntilMainActor { gate.reachedPreparations.contains(late.id) })
        gate.releasePreparation(second.id)
        try #require(await waitUntilMainActor { gate.firstWrite != nil })
        #expect(gate.firstWrite == Set([first.id, second.id]))
        gate.releasePreparation(late.id)
        try #require(await waitUntilMainActor { late.retainedOutput != nil })
        #expect(original.hasPendingCommandResults)
        gate.releaseWriter()
        try #require(await waitUntilMainActor { !original.hasPendingCommandResults })
        registry.closeProjectWindow(root)
        #expect(registry.releaseIdleWorktreeProject(root))
        let reopened = try #require(registry.projectManager(for: root))
        try #require(await reopened.taskRunStore.flushResultPersistence())
        #expect(Set(reopened.taskRunStore.runs.map(\.id)) == Set([first.id, second.id, late.id]))
        #expect(reopened.taskRunStore.run(forID: late.id)?.stdout == "retained-stdout")
    }
    #endif

    private func makeRoot() throws -> URL {
        guard let resolved = realpath(FileManager.default.temporaryDirectory.path, nil) else {
            throw CocoaError(.fileNoSuchFile)
        }
        defer { free(resolved) }
        let root = URL(fileURLWithPath: String(cString: resolved))
            .appendingPathComponent("Pine-1784-reclamation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func recoveryPath(workspace: UserTaskResultPersistence.Workspace) -> URL {
        PineStorageContext.applicationSupportDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("Pine/CommandResults")
            .appendingPathComponent(workspace.identity + ".json")
    }

    /// The default-persistence result file and lock for this root, keyed the
    /// same way production derives the workspace identity (path+device+inode).
    private func defaultResultFiles(forRoot root: URL) -> [URL] {
        let canonical = root.resolvingSymlinksInPath()
        var info = stat()
        guard lstat(canonical.path, &info) == 0 else { return [] }
        let identity = UserTaskResultRecord.identity(
            "\(canonical.path)\0\(info.st_dev)\0\(info.st_ino)"
        )
        let file = recoveryPath(workspace: .init(
            identity: identity, device: UInt64(info.st_dev), inode: info.st_ino
        ))
        return [file, file.deletingPathExtension().appendingPathExtension("lock")]
    }

    private func makeRegistry() -> ProjectRegistry {
        ProjectRegistry(
            agentDetectionProcessRunner: { _, _, _, _ in
                ProcessRunResult(stdout: "", stderr: "", exitCode: 0, timedOut: false)
            },
            agentDetectionInitialPollDelay: 3_600,
            backgroundReclamationInterval: .seconds(3_600)
        )
    }

    private func start(in store: UserTaskRunStore) -> UserTaskRun {
        store.start(UserTaskRun(
            taskID: "controlled", taskLabel: "Controlled",
            command: "not-executed-by-this-test", replacesFileContent: false
        ))
    }

    private func finish(_ run: UserTaskRun, in store: UserTaskRunStore) {
        store.finishRun(
            id: run.id,
            outcome: UserTaskOutcome(
                taskID: run.taskID, stdout: "retained-stdout", stderr: "retained-stderr",
                exitCode: 7, timedOut: false
            ),
            cancelled: false
        )
    }
}
