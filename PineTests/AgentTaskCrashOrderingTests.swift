//
//  AgentTaskCrashOrderingTests.swift
//  PineTests
//
//  Crash-ordering contract (#1722): invalidation and new-attempt state must
//  be durable BEFORE dependent positive evidence. A crash between the
//  metadata write and the journal write fails closed — recovery never
//  adopts evidence whose durable attempt basis it cannot prove.
//

import Foundation
import Testing
@testable import Pine

@MainActor
@Suite("ADE crash ordering", .serialized)
struct AgentTaskCrashOrderingTests {
    private var stateA: AgentTaskCodeStateIdentity {
        ADEContractFixtures.codeState("a")
    }
    private var stateB: AgentTaskCodeStateIdentity {
        ADEContractFixtures.codeState("b")
    }
    private var env: AgentTaskEnvironmentIdentity { ADEContractFixtures.environment }

    @Test("a crash between the invalidation write and dependent evidence fails closed")
    func crashBetweenInvalidationAndDependentEvidenceFailsClosed() async throws {
        let fixture = try ADEContractPersistenceFixture()
        defer { fixture.cleanup() }
        let identity = ADEContractFixtures.project(fixture.project.path)
        let fault = ArmedADEWriteFault()
        let store = AgentTaskMetadataStore(
            storageRoot: fixture.storage,
            configuration: AgentTaskStoreConfiguration(
                faultInjector: PersistenceFaultInjector(injection: { storeKind, phase in
                    try fault.throwWhileArmed(store: storeKind, phase: phase)
                })
            )
        )
        let writer = AgentTaskRegistry(persistence: store)
        writer.registerProject(identity)
        #expect(await writer.flushPersistence() == .saved)
        let verified = try ADEContractFixtures.verifiedSuccessTask(
            seed: 31,
            codeState: stateA,
            environment: env,
            // Wall clock: the crash relaunches register the project over the
            // store, and a settled 1970-epoch task would be dismissed by the
            // 7-day retention sweep mid-test.
            now: Date(),
            projectPath: fixture.project.path
        )
        writer.setTasksForTesting([verified])
        #expect(await writer.flushPersistence() == .saved)

        // A relevant edit: the invalidation and its resulting state are
        // durable FIRST.
        let gaps = writer.invalidateEvidence(
            taskID: verified.id,
            codeState: stateB,
            environment: env
        )
        #expect(gaps.contains(.staleEvidence(.independentCheck)))
        #expect(gaps.contains(.staleEvidence(.reviewerOutcome)))
        #expect(await writer.flushPersistence() == .saved)
        let file = AgentTaskMetadataStore.metadataURL(
            for: identity,
            storageRoot: fixture.storage
        )
        let afterInvalidation = try Data(contentsOf: file)
        let invalidationRoot = try #require(
            JSONSerialization.jsonObject(with: afterInvalidation) as? [String: Any]
        )
        let invalidationTask = try #require(
            (invalidationRoot["tasks"] as? [[String: Any]])?[0]
        )
        #expect(invalidationTask["verificationState"] as? String == "stale")
        #expect(invalidationTask["reviewedSnapshot"] != nil)
        #expect(
            ((invalidationTask["evidence"] as? [[String: Any]]) ?? []).count == 4
        )

        // The crash: the dependent positive evidence for the edited state is
        // recorded in memory, but its write never becomes durable.
        fault.arm()
        let run = try #require(writer.task(for: verified.id)?.runs.last)
        #expect(
            writer.recordEvidence(ADEContractFixtures.fact(
                .independentCheck,
                runID: run.id,
                generation: 31,
                result: .succeeded,
                at: Date(),
                codeState: stateB,
                environment: env,
                sequence: 4,
                pre: stateB,
                post: stateB
            ), taskID: verified.id) == .accepted
        )
        #expect(await writer.flushPersistence() == .failed)

        // The durable file is byte-for-byte the pre-evidence state: no
        // partial evidence, no half invalidation.
        #expect(try Data(contentsOf: file) == afterInvalidation)

        // A crash relaunch fails closed: the durable invalidation stands,
        // the dependent evidence is absent, and Ready is refused.
        let crashed = AgentTaskRegistry(
            persistence: AgentTaskMetadataStore(storageRoot: fixture.storage)
        )
        crashed.registerProject(identity)
        #expect(await crashed.flushPersistence() == .saved)
        let recovered = try #require(crashed.task(for: verified.id))
        #expect(recovered.verificationState == .stale)
        #expect(!recovered.evidence.contains { $0.codeState == stateB })
        #expect(recovered.reviewedSnapshot != nil)
        #expect(recovered.acceptanceState == .notAccepted)
        #expect(recovered.runs.last?.outcome == .success)
        #expect(
            !AgentTaskLifecycleReducer.readiness(
                for: recovered,
                codeState: stateB,
                environment: env
            ).isReady
        )

        // With the fault gone, the dependent evidence lands atomically with
        // the invalidation it depends on — and still cannot re-upgrade the
        // stale verification by itself.
        fault.disarm()
        #expect(await writer.flushPersistence() == .saved)
        let healed = AgentTaskRegistry(
            persistence: AgentTaskMetadataStore(storageRoot: fixture.storage)
        )
        healed.registerProject(identity)
        #expect(await healed.flushPersistence() == .saved)
        let healedTask = try #require(healed.task(for: verified.id))
        #expect(
            healedTask.evidence.contains {
                $0.kind == .independentCheck && $0.codeState == stateB
            }
        )
        #expect(healedTask.verificationState == .stale)
        #expect(
            !AgentTaskLifecycleReducer.readiness(
                for: healedTask,
                codeState: stateB,
                environment: env
            ).isReady
        )
    }

    @Test("journal evidence without a durable attempt is never adopted")
    func orphanJournalEvidenceFailsClosed() async throws {
        let fixture = try ADEContractPersistenceFixture()
        defer { fixture.cleanup() }
        let identity = ADEContractFixtures.project(fixture.project.path)
        let stateA = ADEContractFixtures.codeState("a")
        let env = ADEContractFixtures.environment

        // Seed a real durable task with one settled run through the store.
        let store = AgentTaskMetadataStore(storageRoot: fixture.storage)
        let writer = AgentTaskRegistry(persistence: store)
        writer.registerProject(identity)
        #expect(await writer.flushPersistence() == .saved)
        let seeded = try ADEContractFixtures.verifiedSuccessTask(
            seed: 72,
            codeState: stateA,
            environment: env,
            // Wall clock: the recovery registry below loads the project and
            // would retention-sweep a settled 1970-epoch task mid-test.
            now: Date(),
            projectPath: fixture.project.path
        )
        writer.setTasksForTesting([seeded])
        #expect(
            writer.recordFeedback("seed-ref", codeState: stateA, for: seeded.id)
        )
        #expect(await writer.flushPersistence() == .saved)
        let seededRun = try #require(seeded.runs.first)
        let seededEvidenceCount = seeded.evidence.count
        #expect(seededEvidenceCount > 1)

        // The provenance journal then receives a record for a DIFFERENT
        // attempt: its metadata write was lost to a crash, the journal write
        // survived. The orphan's session, terminal, and incarnation match
        // nothing in the durable task.
        let journalScope = try AgentEventStoreScope(
            projectID: ADEContractFixtures.uuid(73),
            worktreeURL: fixture.project
        )
        let journalStore = try AgentEventProvenanceStore(
            scope: journalScope,
            storageRoot: fixture.root.appendingPathComponent("journal", isDirectory: true)
        )
        let orphan = AgentEventEnvelope(
            id: UUID(),
            projectID: journalScope.projectID,
            sessionID: ADEContractFixtures.uuid(74),
            agentTypeRaw: "claudeCode",
            process: AgentProcessIdentity(
                terminalID: ADEContractFixtures.uuid(75),
                processGeneration: 7
            ),
            location: AgentEventLocation(
                worktreePath: journalScope.worktreePath,
                cwd: journalScope.worktreePath
            ),
            cursorValue: 1,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            source: .explicitAgentEvent,
            trustLevel: .verified,
            payload: .none
        )
        await (journalStore as AgentEventProvenanceCollector).record(orphan)
        #expect(await journalStore.snapshot().records.count == 1)

        // Recovery over the same storage: the durable task is unchanged.
        // The orphaned journal record is provenance history, never a
        // promotion path into the task model.
        let reloaded = AgentTaskRegistry(
            persistence: AgentTaskMetadataStore(storageRoot: fixture.storage)
        )
        reloaded.registerProject(identity)
        #expect(await reloaded.flushPersistence() == .saved)
        #expect(reloaded.tasks.count == 1)
        let recovered = try #require(reloaded.task(for: seeded.id))
        #expect(recovered.runs.count == 1)
        #expect(recovered.evidence.count == seededEvidenceCount)
        #expect(recovered.evidence.allSatisfy { $0.runID == seededRun.id })
    }
}
