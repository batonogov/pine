import Darwin
import Foundation
import Testing

@testable import Pine

nonisolated private final class CommandResultWriteFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var failing = false
    func setFailing(_ value: Bool) { lock.withLock { failing = value } }
    func check() throws {
        if lock.withLock({ failing }) { throw CocoaError(.fileWriteNoPermission) }
    }
}

nonisolated private final class CommandResultCompletionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var observed = false
    var hasWaited: Bool { lock.withLock { observed } }
    func wait() -> Bool { lock.withLock { observed = true }; return true }
}

@Suite("Command result retention", .serialized)
@MainActor
struct UserTaskResultPersistenceTests {
    @Test("metadata is private, output requires per-run consent, recovery never replays")
    func retentionAndRepeatedRecovery() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let store = UserTaskRunStore(resultPersistence: fixture.persistence)
        try #require(store.updateResultRoot(fixture.root))
        try #require(await store.flushResultPersistence())
        let metadata = start(in: store)
        finish(metadata, in: store)
        let retained = start(in: store)
        await store.retainOutput(forRunID: retained.id)
        finish(retained, in: store, cancelled: true)
        let notConsented = start(in: store)
        finish(notConsented, in: store)
        try #require(await store.flushResultPersistence())
        let disk = try await fixture.persistence.load(root: fixture.root)
        #expect(disk.records.count == 3)
        #expect(disk.records.first { $0.id == metadata.id }?.output == nil)
        #expect(disk.records.first { $0.id == notConsented.id }?.output == nil)
        #expect(disk.records.first { $0.id == retained.id }?.state == .cancelled)
        #expect(disk.records.first { $0.id == retained.id }?.output?.stderr == "private-stderr")
        let path = fixture.storage.appendingPathComponent(disk.workspace.identity + ".json")
        let bytes = try await runOnBackground { try Data(contentsOf: path) }
        let text = try #require(String(data: bytes, encoding: .utf8))
        #expect(!text.contains("private-command"))
        #expect(!text.contains("private-label"))
        #expect(!text.contains("private-task-id"))
        let permissions = try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
        for _ in 0..<2 {
            let recovered = UserTaskRunStore(resultPersistence: fixture.persistence)
            try #require(recovered.updateResultRoot(fixture.root))
            try #require(await recovered.flushResultPersistence())
            #expect(Set(recovered.runs.map(\.id)) == Set([metadata.id, retained.id, notConsented.id]))
            #expect(recovered.activeRuns.isEmpty)
            #expect(!recovered.hasOutstandingExecutionOwnership)
            #expect(recovered.run(forID: metadata.id)?.stdout.isEmpty == true)
            #expect(recovered.run(forID: retained.id)?.stderr == "private-stderr")
            #expect(recovered.run(forID: retained.id)?.command.isEmpty == true)
            #expect(!recovered.canRetainOutput(forRunID: metadata.id))
        }
    }

    @Test("completed-run output opt-in is durable before fresh recovery", arguments: [false, true])
    func completedRunOutputOptIn(failFirstWrite: Bool) async throws {
        let failure = CommandResultWriteFailure()
        let fixture = try makeFixture(beforeWrite: { try failure.check() })
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let store = UserTaskRunStore(resultPersistence: fixture.persistence)
        try #require(store.updateResultRoot(fixture.root))
        try #require(await store.flushResultPersistence())
        let run = start(in: store)
        finish(run, in: store)
        try #require(await store.flushResultPersistence())
        let metadata = try await fixture.persistence.load(root: fixture.root)
        try #require(metadata.records.first?.id == run.id)
        #expect(metadata.records.first?.output == nil)
        #expect(!run.state.isActive)
        #expect(!run.outputRetentionRequested)
        #expect(store.canRetainOutput(forRunID: run.id))
        failure.setFailing(failFirstWrite)

        await store.retainOutput(forRunID: run.id)

        #expect(run.outputRetentionRequested)
        #expect(run.retainedOutput?.stdout == "private-stdout")
        #expect(run.retainedOutput?.stderr == "private-stderr")
        if failFirstWrite {
            #expect(!(await store.flushResultPersistence()))
            #expect(store.resultPersistenceFailed)
            #expect(store.hasUnpersistedResultOwnership)
            #expect(store.hasPendingResultPersistence)
            #expect(!store.canChangeResultRoot(to: fixture.base))
            #expect(try await fixture.persistence.load(root: fixture.root) == metadata)
            failure.setFailing(false)
        }
        try #require(await store.flushResultPersistence())
        #expect(!store.resultPersistenceFailed)
        #expect(!store.hasUnpersistedResultOwnership)
        #expect(!store.hasPendingResultPersistence)
        let freshPersistence = UserTaskResultPersistence(directory: fixture.storage)
        let saved = try await freshPersistence.load(root: fixture.root)
        #expect(saved.revision != metadata.revision)
        #expect(saved.records.first?.output?.stdout == "private-stdout")
        #expect(saved.records.first?.output?.stderr == "private-stderr")
        let restoredStore = UserTaskRunStore(resultPersistence: freshPersistence)
        try #require(restoredStore.updateResultRoot(fixture.root))
        try #require(await restoredStore.flushResultPersistence())
        let restored = try #require(restoredStore.run(forID: run.id))
        #expect(restoredStore.runs.count == 1)
        #expect(restored.isRestoredResult)
        #expect(restored.outputRetentionRequested)
        #expect(restored.stdout == "private-stdout")
        #expect(restored.stderr == "private-stderr")
        #expect(restored.state == run.state)
        #expect(restored.exitCode == run.exitCode)
        #expect(!restoredStore.hasOutstandingExecutionOwnership)
    }

    @Test("failed initial recovery stays reachable with an empty hidden panel")
    func failedEmptyRecoveryHasOutputAffordance() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        try FileManager.default.createDirectory(
            at: fixture.storage, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o500]
        )
        let store = UserTaskRunStore(resultPersistence: fixture.persistence)
        try #require(store.updateResultRoot(fixture.root))
        #expect(!(await store.flushResultPersistence()))
        #expect(store.resultPersistenceFailed)
        #expect(store.runs.isEmpty)
        #expect(!store.hasUnpersistedResultOwnership)
        #expect(!store.isOutputVisible)
        #expect(UserTaskRunPresenter(store: store).showsOutputButton)
        store.isOutputVisible = true
        #expect(!UserTaskRunPresenter(store: store).showsOutputButton)
        try await runOnBackground {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.storage.path)
        }
        store.retryFailedResultPersistence()
        try #require(await store.flushResultPersistence())
        #expect(!store.resultPersistenceFailed)
        store.isOutputVisible = false
        #expect(!UserTaskRunPresenter(store: store).showsOutputButton)
    }

    @Test("failed Clear remains reachable after closing the empty output panel")
    func failedClearHasOutputAffordance() async throws {
        let failure = CommandResultWriteFailure()
        let fixture = try makeFixture(beforeWrite: { try failure.check() })
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let store = UserTaskRunStore(resultPersistence: fixture.persistence)
        try #require(store.updateResultRoot(fixture.root))
        try #require(await store.flushResultPersistence())
        let run = start(in: store)
        finish(run, in: store)
        try #require(await store.flushResultPersistence())
        failure.setFailing(true)
        store.clearFinished()
        #expect(!(await store.flushResultPersistence()))
        #expect(store.runs.isEmpty)
        #expect(store.resultPersistenceFailed)
        #expect(store.hasUnpersistedResultOwnership)
        store.isOutputVisible = false
        #expect(UserTaskRunPresenter(store: store).showsOutputButton)
        store.isOutputVisible = true
        #expect(!UserTaskRunPresenter(store: store).showsOutputButton)
        failure.setFailing(false)
        store.retryFailedResultPersistence()
        try #require(await store.flushResultPersistence())
        #expect(!store.resultPersistenceFailed)
        #expect(!store.hasUnpersistedResultOwnership)
        #expect(try await fixture.persistence.load(root: fixture.root).records.isEmpty)
        store.isOutputVisible = false
        #expect(!UserTaskRunPresenter(store: store).showsOutputButton)
    }

    @Test("failed persistence owns the result until repair; Clear is durable")
    func failureAndClear() async throws {
        let failure = CommandResultWriteFailure()
        let fixture = try makeFixture(beforeWrite: { try failure.check() })
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let manager = ProjectManager(taskResultPersistence: fixture.persistence)
        manager.loadDirectory(url: fixture.root)
        manager.workspace.suspend()
        let store = manager.taskRunStore
        try #require(await store.flushResultPersistence())
        failure.setFailing(true)
        let run = start(in: store)
        await store.retainOutput(forRunID: run.id)
        finish(run, in: store)
        #expect(!(await store.flushResultPersistence()))
        #expect(store.resultPersistenceFailed)
        #expect(manager.requiresBackgroundRetention)
        #expect(manager.hasPendingCommandResults)
        #expect(!store.canChangeResultRoot(to: fixture.base))
        #expect(run.retainedOutput?.stdout == "private-stdout")
        failure.setFailing(false)
        try #require(await manager.flushCommandResultPersistence())
        #expect(!manager.hasPendingCommandResults)
        let recovered = UserTaskRunStore(resultPersistence: fixture.persistence)
        try #require(recovered.updateResultRoot(fixture.root))
        // Clear must include records still in flight from load.
        recovered.clearFinished()
        try #require(await recovered.flushResultPersistence())
        #expect(try await fixture.persistence.load(root: fixture.root).records.isEmpty)
        #expect(recovered.runs.isEmpty)
    }

    @Test("failed Clear survives unchanged-root reopen until repair and fresh reload")
    func failedClearSurvivesUnchangedRootReopen() async throws {
        let failure = CommandResultWriteFailure()
        let fixture = try makeFixture(beforeWrite: { try failure.check() })
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let store = UserTaskRunStore(resultPersistence: fixture.persistence)
        try #require(store.updateResultRoot(fixture.root))
        try #require(await store.flushResultPersistence())
        let run = start(in: store)
        finish(run, in: store)
        try #require(await store.flushResultPersistence())
        let workspace = try await fixture.persistence.load(root: fixture.root).workspace
        failure.setFailing(true)
        store.clearFinished()
        #expect(!(await store.flushResultPersistence()))

        store.recoverRecreatedRoot()
        #expect(!(await store.flushResultPersistence()))
        #expect(store.run(forID: run.id) == nil)
        #expect(try await fixture.persistence.load(root: fixture.root).workspace == workspace)
        failure.setFailing(false)
        store.retryFailedResultPersistence()
        try #require(await store.flushResultPersistence())
        let fresh = UserTaskRunStore(resultPersistence: fixture.persistence)
        try #require(fresh.updateResultRoot(fixture.root))
        try #require(await fresh.flushResultPersistence())
        #expect(fresh.runs.isEmpty)
        let disk = try await fixture.persistence.load(root: fixture.root)
        #expect(disk.workspace == workspace)
        #expect(disk.records.isEmpty)
    }

    @Test("stream limits preserve UTF-8 and report truncation independently")
    func streamLimits() {
        let output = UserTaskResultRecord.Output(
            stdout: String(repeating: "😀", count: 20_000),
            stderr: "diagnostic"
        )
        #expect(output.stdout.utf8.count == 65_536)
        #expect(output.stdoutTruncated)
        #expect(!output.stderrTruncated)
        #expect(!output.stdout.contains("\u{FFFD}"))
    }

    @Test("failure, timeout, cleanup and truncation survive recovery", arguments: [false, true])
    func truthfulOutcome(captureFailed: Bool) async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let store = UserTaskRunStore(resultPersistence: fixture.persistence)
        try #require(store.updateResultRoot(fixture.root))
        try #require(await store.flushResultPersistence())
        let run = start(in: store)
        await store.retainOutput(forRunID: run.id)
        store.finishRun(
            id: run.id,
            outcome: UserTaskOutcome(
                taskID: run.taskID, stdout: String(repeating: "x", count: 70_000),
                stderr: "diagnostic", exitCode: 0, timedOut: !captureFailed,
                cleanupSucceeded: captureFailed, processExitCode: 0,
                outputCaptureSucceeded: !captureFailed
            ),
            cancelled: false
        )
        try #require(await store.flushResultPersistence())
        let disk = try await fixture.persistence.load(root: fixture.root)
        let record = try #require(disk.records.first)
        #expect(record.state == .failed)
        #expect(record.timedOut == !captureFailed)
        #expect(record.cleanupSucceeded == captureFailed)
        #expect(record.processExitCode == 0)
        #expect(record.outputCaptureSucceeded == !captureFailed)
        let restored = UserTaskRun(result: record)
        #expect(restored.state == .failed)
        #expect(restored.retainedOutput?.stdoutTruncated == true)
        #expect(restored.outputCaptureSucceeded == !captureFailed)
        #expect(restored.stderr == "diagnostic")
    }

    @Test("unknown fields and redirected result files cannot be overwritten", arguments: [false, true])
    func unsafeStoredResultIsPreserved(symlink: Bool) async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let initial = try await fixture.persistence.load(root: fixture.root)
        let snapshot = UserTaskResultPersistence.Snapshot(
            version: 1, workspace: initial.workspace, revision: UUID(), records: []
        )
        _ = try await fixture.persistence.save(snapshot, root: fixture.root, replacing: nil)
        let path = fixture.storage.appendingPathComponent(initial.workspace.identity + ".json")
        let outside = fixture.base.appendingPathComponent("unrelated")
        let external = try await runOnBackground {
            if symlink {
                try Data("unrelated-data".utf8).write(to: outside)
                try FileManager.default.removeItem(at: path)
                try FileManager.default.createSymbolicLink(at: path, withDestinationURL: outside)
                return try Data(contentsOf: outside)
            }
            var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
            json["futureField"] = NSNull()
            let data = try JSONSerialization.data(withJSONObject: json)
            try data.write(to: path)
            return data
        }
        do {
            _ = try await fixture.persistence.save(snapshot, root: fixture.root, replacing: snapshot.revision)
            Issue.record("Unsafe storage was accepted")
        } catch {
            #expect(try Data(contentsOf: symlink ? outside : path) == external)
        }
    }

    @Test("shutdown prepares only after accepted result delivery is durable")
    func shutdownWaitsForResultDelivery() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let store = UserTaskRunStore(resultPersistence: fixture.persistence)
        try #require(store.updateResultRoot(fixture.root))
        try #require(await store.flushResultPersistence())
        let run = start(in: store)
        await store.retainOutput(forRunID: run.id)
        let probe = CommandResultCompletionProbe()
        store.registerCancellation(
            UserTaskCancellation(terminate: { true }, waitForCompletion: { _ in probe.wait() }),
            forRunID: run.id
        )
        let authorization = store.captureShutdownAuthorization()
        let waiting = Task {
            await store.waitForShutdown(authorizedBy: authorization, until: .now() + .seconds(120))
        }
        try #require(await waitUntilMainActor { probe.hasWaited })
        #expect(!store.shutdownIsPreparedForCommit(authorizedBy: authorization))
        finish(run, in: store)
        try #require(await waiting.value)
        #expect(store.run(forID: run.id) === run)
        #expect(store.shutdownIsPreparedForCommit(authorizedBy: authorization))
        store.commitPreparedShutdown(authorizedBy: authorization)
        #expect(store.runs.isEmpty)
        #expect(try await fixture.persistence.load(root: fixture.root).records.first?.id == run.id)
    }

    @Test("result count and seven-day expiry are enforced on disk")
    func countAndExpiry() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let initial = try await fixture.persistence.load(root: fixture.root)
        let now = Date()
        func record(age: TimeInterval) -> UserTaskResultRecord {
            UserTaskResultRecord(
                id: UUID(), commandIdentity: UserTaskResultRecord.identity("command"),
                taskIdentity: UserTaskResultRecord.identity("task"),
                startedAt: now.addingTimeInterval(-age - 1), finishedAt: now.addingTimeInterval(-age),
                state: .succeeded, exitCode: 0, processExitCode: 0,
                outputCaptureSucceeded: true, preSpawnRejected: false, timedOut: false,
                cleanupSucceeded: true, standardInputCompleted: true, output: nil
            )
        }
        let expired = record(age: UserTaskResultRecord.lifetime + 1)
        let records = (0..<30).map { record(age: Double($0)) } + [expired]
        let saved = try await fixture.persistence.save(
            .init(version: 1, workspace: initial.workspace, revision: UUID(), records: records),
            root: fixture.root, replacing: initial.revision
        )
        #expect(saved.records.count == 25)
        #expect(!saved.records.contains { $0.id == expired.id })
        #expect(try await fixture.persistence.load(root: fixture.root).records == saved.records)
    }

    @Test("stale writers cannot undo durable Clear")
    func staleWriter() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let initial = try await fixture.persistence.load(root: fixture.root)
        let cleared = UserTaskResultPersistence.Snapshot(
            version: 1, workspace: initial.workspace, revision: UUID(), records: []
        )
        _ = try await fixture.persistence.save(cleared, root: fixture.root, replacing: initial.revision)
        do {
            _ = try await fixture.persistence.save(
                .init(version: 1, workspace: initial.workspace, revision: UUID(), records: []),
                root: fixture.root, replacing: initial.revision
            )
            Issue.record("Stale writer was accepted")
        } catch UserTaskResultPersistence.Failure.conflict {
            // Expected: never merge removed results back into history.
        }
        #expect(try await fixture.persistence.load(root: fixture.root).revision == cleared.revision)
    }

    private func start(in store: UserTaskRunStore) -> UserTaskRun {
        store.start(UserTaskRun(
            taskID: "private-task-id", taskLabel: "private-label",
            command: "private-command", replacesFileContent: false
        ))
    }

    private func finish(_ run: UserTaskRun, in store: UserTaskRunStore, cancelled: Bool = false) {
        store.finishRun(
            id: run.id,
            outcome: UserTaskOutcome(
                taskID: run.taskID, stdout: "private-stdout", stderr: "private-stderr",
                exitCode: 5, timedOut: false
            ),
            cancelled: cancelled
        )
    }

    private func makeFixture(
        beforeWrite: (@Sendable () throws -> Void)? = nil
    ) throws -> (base: URL, root: URL, storage: URL, persistence: UserTaskResultPersistence) {
        guard let resolved = realpath(FileManager.default.temporaryDirectory.path, nil) else {
            throw CocoaError(.fileNoSuchFile)
        }
        defer { free(resolved) }
        let base = URL(fileURLWithPath: String(cString: resolved))
            .appendingPathComponent("Pine-1784-\(UUID().uuidString)")
        let root = base.appendingPathComponent("project")
        let storage = base.appendingPathComponent("private")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (base, root, storage, UserTaskResultPersistence(directory: storage, beforeWrite: beforeWrite))
    }
}
