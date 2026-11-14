import Foundation
import Testing
@testable import Pine

// These are fresh-registry, real-disk tests. The process-boundary/AX assertion
// remains in WelcomeWindowTests; this suite does not claim to replace it.
@Suite("Recovery fixture persisted restart evidence", .serialized)
@MainActor
struct AgentRecoveryRestartEvidenceTests {
    @Test("Unseeded fresh registry restores original task, settled run and result history")
    func restoresOriginalHistory() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let original = try await fixture.seedAndStop()
        let restored = try await fixture.launch(arguments: [])
        #expect(restored.agentTasks.loadStatusByProject[fixture.identity.persistenceKey] == .loaded)
        let task = try #require(restored.agentTasks.tasks.only)
        #expect(task.id == original.id)
        #expect(task.createdAt == original.createdAt)
        #expect(task.runs == original.runs)
        #expect(task.runs.allSatisfy {
            $0.process.processIdentifier == nil
                && $0.process.startIdentifier == nil
                && !$0.process.startIsAuthoritative
        })
        #expect(task.evidence == original.evidence)
        #expect(task.reviewedSnapshot == original.reviewedSnapshot)
        #expect(task.acceptedSnapshot == original.acceptedSnapshot)
        #expect(task.objective == original.objective)
        fixture.expectNoExecution(restored, terminalIDs: original.runs.map(\.terminalID))
    }

    @Test("Missing metadata demonstrates the old reseed oracle and rejects it without seed argv")
    func missingStoreCannotMasqueradeAsRestoration() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let original = try await fixture.seedAndStop()
        try FileManager.default.removeItem(at: fixture.metadata)

        // Same body and arguments as the old UI restart. The row exists, but
        // task/run/result identities distinguish reseeding from restoration.
        let reseeded = try await fixture.launch(arguments: ["--ui-test-agent-recovery"])
        let replacement = try #require(reseeded.agentTasks.tasks.only)
        #expect(replacement.title == original.title)
        #expect(replacement.objective == original.objective)
        #expect(replacement.id != original.id)
        #expect(replacement.runs.only?.id != original.runs.only?.id)
        #expect(replacement.runs != original.runs)
        fixture.expectNoExecution(reseeded, terminalIDs: replacement.runs.map(\.terminalID))
        reseeded.agentTasks.prepareForApplicationTermination()
        #expect(await reseeded.agentTasks.flushPersistence() == .saved)
        try FileManager.default.removeItem(at: fixture.metadata)

        let unseeded = try await fixture.launch(arguments: [])
        #expect(unseeded.agentTasks.loadStatusByProject[fixture.identity.persistenceKey] == .missing)
        #expect(unseeded.agentTasks.tasks.isEmpty)
        fixture.expectNoExecution(unseeded, terminalIDs: original.runs.map(\.terminalID))
    }

    @Test("Corrupt metadata is rejected and cannot be replaced on an unseeded restart")
    func corruptStoreFailsClosed() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let original = try await fixture.seedAndStop()
        let beforeCorruption = try Data(contentsOf: fixture.metadata)
        try beforeCorruption.write(to: fixture.root.appendingPathComponent("original-metadata.json"))
        try Data("not task metadata".utf8).write(to: fixture.metadata)
        let restored = try await fixture.launch(arguments: [])
        #expect(restored.agentTasks.loadStatusByProject[fixture.identity.persistenceKey] == .rejected(.corrupt))
        #expect(restored.agentTasks.tasks.isEmpty)
        #expect(try Data(contentsOf: fixture.metadata) == Data("not task metadata".utf8))
        fixture.expectNoExecution(restored, terminalIDs: original.runs.map(\.terminalID))
    }

    @MainActor
    private struct Fixture {
        let root: URL
        let storage: URL
        let identity: AgentTaskProjectIdentity
        let defaults: UserDefaults
        let suite: String

        var metadata: URL { AgentTaskMetadataStore.metadataURL(for: identity, storageRoot: storage) }

        init() throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent("PineRecoveryRestart-\(UUID().uuidString)")
            let project = root.appendingPathComponent("project")
            storage = root.appendingPathComponent("private-store")
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            identity = AgentTaskProjectIdentity(
                canonicalProjectPath: project.path, canonicalWorktreePath: project.path
            )
            suite = "PineRecoveryRestart.\(UUID().uuidString)"
            defaults = try #require(UserDefaults(suiteName: suite))
        }

        func launch(arguments: [String]) async throws -> ProjectRegistry {
            let tasks = AgentTaskRegistry(persistence: AgentTaskMetadataStore(storageRoot: storage))
            let registry = ProjectRegistry(
                defaults: defaults,
                agentTasks: tasks,
                agentDetectionProcessRunner: { _, _, _, _ in
                    Issue.record("Restoring metadata must not dispatch process detection")
                    return ProcessRunResult(stdout: "", stderr: "disabled by test", exitCode: 1, timedOut: false)
                }
            )
            tasks.registerProject(identity)
            #expect(await tasks.flushPersistence() == .saved)
            // Calls the actual production UI fixture, not a model of seeding.
            let seed = registry.seedAgentRecoveryUITestFixture(project: identity, arguments: arguments)
            #expect((seed != nil) == arguments.contains("--ui-test-agent-recovery"))
            await seed?.value
            return registry
        }

        func seedAndStop() async throws -> AgentTask {
            let registry = try await launch(arguments: ["--ui-test-agent-recovery"])
            let task = try #require(registry.agentTasks.tasks.only)
            let run = try #require(task.runs.only)
            #expect(run.liveness == .terminated)
            #expect(run.endedAt != nil)
            #expect(run.outcome == .unverified)
            #expect(!task.evidence.isEmpty, "Preserve real process-completion evidence")
            expectNoExecution(registry, terminalIDs: [run.terminalID])
            registry.agentTasks.prepareForApplicationTermination()
            #expect(await registry.agentTasks.flushPersistence() == .saved)
            // Capture the actual durable representation before creating the
            // restarted registry. The codec intentionally removes live process
            // authority and can round Date's floating epoch conversion.
            let persisted = await AgentTaskMetadataStore(storageRoot: storage).load(project: identity)
            #expect(persisted.status == .loaded)
            let original = try #require(persisted.tasks.only)
            #expect(original.id == task.id)
            #expect(original.runs.map(\.id) == task.runs.map(\.id))
            #expect(original.runs.map(\.terminalID) == task.runs.map(\.terminalID))
            #expect(original.runs.map(\.outcome) == task.runs.map(\.outcome))
            #expect(original.evidence.count == task.evidence.count)
            #expect(abs(original.createdAt.timeIntervalSince(task.createdAt)) <= 0.000001)
            return original
        }

        func expectNoExecution(_ registry: ProjectRegistry, terminalIDs: [UUID]) {
            #expect(registry.openProjects.isEmpty, "Metadata recovery must not create terminal managers")
            #if PINE_TEST_HOST
            let evidence = RecoveryUITestEvidence.shared
            // Scope observations to these fixture routes; other suites may be
            // exercising unrelated terminal seams concurrently.
            #expect(evidence.processLaunches.filter { terminalIDs.contains($0) }.isEmpty)
            #expect(evidence.processStarts.filter { terminalIDs.contains($0) }.isEmpty)
            #expect(evidence.inputDispatches.filter { terminalIDs.contains($0) }.isEmpty)
            #endif
        }

        func cleanup() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
