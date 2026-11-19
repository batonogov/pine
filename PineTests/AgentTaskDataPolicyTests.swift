//
//  AgentTaskDataPolicyTests.swift
//  PineTests
//
//  Data classification / redaction / retention policy pins (#1722): the
//  durable task model carries bounded identities and references only —
//  never transcripts, prompts, file contents, environment values, visual
//  attachments, or credentials — and the ordering contract admits
//  legitimate cross-scope reordering without manufacturing sequences.
//

import Foundation
import Testing
@testable import Pine

@MainActor
@Suite("ADE data policy and ordering pins", .serialized)
struct AgentTaskDataPolicyTests {
    private func encodeKeys(_ value: some Encodable) throws -> Set<String> {
        let data = try JSONEncoder().encode(value)
        let root = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        return Set(root.keys)
    }

    @Test("an evidence fact persists only its bounded identity fields")
    func evidenceFactHasNoContentFields() throws {
        let fact = ADEContractFixtures.fact(
            .independentCheck,
            runID: ADEContractFixtures.uuid(61),
            generation: 1,
            result: .succeeded,
            at: Date(timeIntervalSince1970: 1_000),
            codeState: ADEContractFixtures.codeState("a"),
            environment: ADEContractFixtures.environment,
            sequence: 1,
            vendorSession: AgentVendorSessionIdentity(
                provider: "codex",
                opaqueIdentifier: "session-1"
            ),
            pre: ADEContractFixtures.codeState("a"),
            post: ADEContractFixtures.codeState("a")
        )
        #expect(try encodeKeys(fact) == [
            "kind", "runID", "processGeneration", "trust", "result",
            "observedAt", "codeState", "environment", "vendorSession",
            "sourceSequence", "preOperationCodeState", "postOperationCodeState",
        ])
    }

    @Test("the task model persists no transcript, content, or credential field")
    func taskModelHasNoContentFields() throws {
        var task = ADEContractFixtures.makeTask(
            seed: 62,
            state: .done,
            liveness: .terminated,
            now: Date(timeIntervalSince1970: 1_000)
        )
        AgentTaskLifecycleReducer.settleTerminated(task: &task, runIndex: 0)
        task.title = "bounded title"
        task.objective = "bounded objective"
        task.presentationContext = AgentTaskPresentationContext(
            terminalStableLabel: "Terminal 7"
        )
        task.environment = ADEContractFixtures.environment
        task.reviewedSnapshot = AgentTaskResultSnapshot(
            runID: try #require(task.runs.first).id,
            outcome: .success,
            codeState: ADEContractFixtures.codeState("a"),
            environment: ADEContractFixtures.environment,
            recordedAt: task.lastActivityAt
        )
        task.acceptedSnapshot = task.reviewedSnapshot
        task.evidence.append(ADEContractFixtures.fact(
            .agentReportedCompletion,
            runID: try #require(task.runs.first).id,
            generation: 62,
            result: .reported,
            at: task.lastActivityAt
        ))
        // The persisted field set is exactly the documented contract:
        // bounded identifiers, fingerprints, and references. There is no
        // payload, transcript, prompt, attachment, or credential field to
        // leak.
        #expect(try encodeKeys(task) == [
            "id", "project", "route", "presentationContext", "descriptor",
            "origin", "lifecycle", "runs", "createdAt", "updatedAt",
            "lastActivityAt", "isUnread", "attention", "title", "objective",
            "objectiveRevision", "executionState", "evidence", "verificationState",
            "acceptanceState", "reviewedSnapshot", "acceptedSnapshot",
            "environment", "feedback", "decisionReferences",
        ])
    }

    @Test("presentation labels are bounded references, never free text")
    func presentationLabelBounds() {
        #expect(AgentTaskPresentationContext(terminalStableLabel: "") == nil)
        #expect(
            AgentTaskPresentationContext(
                terminalStableLabel: String(repeating: "t", count: 257)
            ) == nil
        )
        #expect(
            AgentTaskPresentationContext(
                terminalStableLabel: "a\0b"
            ) == nil
        )
        #expect(
            AgentTaskPresentationContext(
                terminalStableLabel: "a\nb"
            ) == nil
        )
        #expect(
            AgentTaskPresentationContext(
                terminalStableLabel: String(repeating: "t", count: 256)
            ) != nil
        )
    }

    @Test("feedback references are bounded and content-free at admission")
    func feedbackReferenceBounds() async throws {
        let fixture = try ADEContractPersistenceFixture()
        defer { fixture.cleanup() }
        let identity = ADEContractFixtures.project(fixture.project.path)
        let registry = AgentTaskRegistry(persistence: AgentTaskMetadataStore(
            storageRoot: fixture.storage
        ))
        registry.registerProject(identity)
        #expect(await registry.flushPersistence() == .saved)
        let task = ADEContractFixtures.makeTask(
            seed: 63,
            state: .executing,
            liveness: .live,
            projectPath: fixture.project.path
        )
        registry.setTasksForTesting([task])

        #expect(registry.recordFeedback(
            String(repeating: "r", count: 256),
            codeState: ADEContractFixtures.codeState("a"),
            for: task.id
        ))
        #expect(!registry.recordFeedback(
            String(repeating: "r", count: 257),
            codeState: nil,
            for: task.id
        ))
        #expect(!registry.recordFeedback("", codeState: nil, for: task.id))

        let record = try #require(
            registry.task(for: task.id)?.feedback.first
        )
        #expect(try encodeKeys(record) == [
            "scheme", "reference", "observedAt", "codeState",
        ])
    }

    @Test("legitimate cross-scope reordering is admitted, not rejected")
    func crossScopeReorderingIsAdmitted() throws {
        var task = ADEContractFixtures.makeTask(
            seed: 64,
            now: Date(timeIntervalSince1970: 1_000)
        )
        task.runs[0].liveness = .terminated
        task.runs[0].endedAt = Date(timeIntervalSince1970: 1_000)
        task.runs[0].outcome = .superseded
        let oldRun = task.runs[0]
        task.runs.append(AgentTaskRun(ADEContractFixtures.makeAttempt(
            seed: 65,
            state: .executing,
            liveness: .live,
            now: Date(timeIntervalSince1970: 2_000)
        )))
        task.lifecycle = .active
        let newRun = try #require(task.runs.last)

        // Arrival order is the REVERSE of chronology: the newer attempt's
        // fact arrives before the replaced attempt's. Both are legitimate
        // and both are admitted; no global arrival sequence is invented.
        let newFact = ADEContractFixtures.fact(
            .independentCheck,
            runID: newRun.id,
            generation: 65,
            result: .succeeded,
            at: Date(timeIntervalSince1970: 2_500),
            codeState: ADEContractFixtures.codeState("a"),
            environment: ADEContractFixtures.environment,
            pre: ADEContractFixtures.codeState("a"),
            post: ADEContractFixtures.codeState("a")
        )
        let oldFact = ADEContractFixtures.fact(
            .processCompletion,
            runID: oldRun.id,
            generation: 64,
            result: .exited(status: nil),
            at: Date(timeIntervalSince1970: 1_500),
            trust: .observed
        )
        for candidate in [newFact, oldFact] {
            #expect(
                AgentTaskLifecycleReducer.admit(candidate, into: task)
                    == .accepted
            )
            task.evidence.append(candidate)
        }
        #expect(task.evidence.allSatisfy { $0.sourceSequence == nil })
        #expect(task.runs.last?.outcome == nil)
        #expect(task.runs.last?.liveness == .live)
    }

    @Test("unordered dedup is scoped to event identity, not arrival order")
    func unorderedDedupScope() throws {
        var task = ADEContractFixtures.settledTask(seed: 66)
        let run = try #require(task.runs.first)
        let base = Date(timeIntervalSince1970: 1_000)
        // Two sub-millisecond-apart facts of the same kind within one
        // quantized millisecond are the same event identity: the second is
        // a duplicate.
        let first = ADEContractFixtures.fact(
            .independentCheck,
            runID: run.id,
            generation: 66,
            result: .succeeded,
            at: base
        )
        let duplicate = ADEContractFixtures.fact(
            .independentCheck,
            runID: run.id,
            generation: 66,
            result: .succeeded,
            at: base.addingTimeInterval(0.0004)
        )
        // One millisecond apart is a distinct fact.
        let distinct = ADEContractFixtures.fact(
            .independentCheck,
            runID: run.id,
            generation: 66,
            result: .succeeded,
            at: base.addingTimeInterval(1)
        )
        #expect(
            AgentTaskLifecycleReducer.admit(first, into: task) == .accepted
        )
        task.evidence.append(first)
        #expect(
            AgentTaskLifecycleReducer.admit(duplicate, into: task)
                == .fencedOut(.duplicate)
        )
        #expect(
            AgentTaskLifecycleReducer.admit(distinct, into: task) == .accepted
        )
        // No sequence was manufactured from arrival order.
        #expect(task.evidence.allSatisfy { $0.sourceSequence == nil })
    }

    @Test("unknown future raw values decode fail-closed or reject corrupt")
    func futureRawValuesFailClosed() async throws {
        let fixture = try ADEContractPersistenceFixture()
        defer { fixture.cleanup() }
        let identity = ADEContractFixtures.project(fixture.project.path)
        let stateA = ADEContractFixtures.codeState("a")
        let env = ADEContractFixtures.environment
        // Store-level loads only (no registry reload), so the fixture's
        // pinned 1970 epoch is safe from the retention sweep.
        let seeded = try ADEContractFixtures.verifiedSuccessTask(
            seed: 71,
            codeState: stateA,
            environment: env,
            projectPath: fixture.project.path
        )
        let registry = AgentTaskRegistry(
            persistence: AgentTaskMetadataStore(storageRoot: fixture.storage)
        )
        registry.registerProject(identity)
        #expect(await registry.flushPersistence() == .saved)
        registry.setTasksForTesting([seeded])
        #expect(
            registry.recordFeedback(
                "seed-ref",
                codeState: stateA,
                for: seeded.id,
                at: Date(timeIntervalSince1970: 1_001)
            )
        )
        #expect(await registry.flushPersistence() == .saved)
        let file = AgentTaskMetadataStore.metadataURL(
            for: identity,
            storageRoot: fixture.storage
        )
        let original = try Data(contentsOf: file)

        // Mutate the on-disk JSON (always from the original bytes), write it
        // back, and load it through a FRESH store. No load — accepted or
        // rejected — may rewrite the file.
        func loadMutated(
            _ mutate: (inout [String: Any]) throws -> Void
        ) async throws -> AgentTaskMetadataLoadResult {
            var root = try #require(
                JSONSerialization.jsonObject(with: original) as? [String: Any]
            )
            try mutate(&root)
            let mutated = try JSONSerialization.data(
                withJSONObject: root,
                options: [.sortedKeys]
            )
            try mutated.write(to: file)
            let result = await AgentTaskMetadataStore(
                storageRoot: fixture.storage
            ).load(project: identity)
            #expect(try Data(contentsOf: file) == mutated)
            return result
        }

        // LENIENT half: the four custom fail-closed decoders accept unknown
        // future raw values and decode to their negative defaults; the load
        // SUCCEEDS.
        let execution = try await loadMutated { root in
            var tasks = try #require(root["tasks"] as? [[String: Any]])
            var task = tasks[0]
            task["executionState"] = "future-execution-state"
            tasks[0] = task
            root["tasks"] = tasks
        }
        #expect(execution.status == .loaded)
        #expect(execution.tasks.first?.executionState == .unknown)

        let outcome = try await loadMutated { root in
            var tasks = try #require(root["tasks"] as? [[String: Any]])
            var task = tasks[0]
            var runs = try #require(task["runs"] as? [[String: Any]])
            var run = runs[0]
            run["outcome"] = "future-outcome"
            runs[0] = run
            task["runs"] = runs
            tasks[0] = task
            root["tasks"] = tasks
        }
        #expect(outcome.status == .loaded)
        #expect(outcome.tasks.first?.runs.last?.outcome == .unverified)

        let verification = try await loadMutated { root in
            var tasks = try #require(root["tasks"] as? [[String: Any]])
            var task = tasks[0]
            task["verificationState"] = "future-verification-state"
            tasks[0] = task
            root["tasks"] = tasks
        }
        #expect(verification.status == .loaded)
        #expect(verification.tasks.first?.verificationState == .stale)

        let acceptance = try await loadMutated { root in
            var tasks = try #require(root["tasks"] as? [[String: Any]])
            var task = tasks[0]
            task["acceptanceState"] = "future-acceptance-state"
            tasks[0] = task
            root["tasks"] = tasks
        }
        #expect(acceptance.status == .loaded)
        #expect(acceptance.tasks.first?.acceptanceState == .notAccepted)

        // STRICT half: unknown raw values for plain `String, Codable`
        // persisted enums throw at the envelope decode — the file rejects as
        // `.corrupt` (decode level), not `.invalidMetadata` (validation).
        let strictMutations: [(String, (inout [String: Any]) throws -> Void)] = [
            ("task lifecycle", { root in
                var tasks = try #require(root["tasks"] as? [[String: Any]])
                var task = tasks[0]
                task["lifecycle"] = "future-lifecycle"
                tasks[0] = task
                root["tasks"] = tasks
            }),
            ("run state", { root in
                var tasks = try #require(root["tasks"] as? [[String: Any]])
                var task = tasks[0]
                var runs = try #require(task["runs"] as? [[String: Any]])
                var run = runs[0]
                run["state"] = "future-state"
                runs[0] = run
                task["runs"] = runs
                tasks[0] = task
                root["tasks"] = tasks
            }),
            ("run liveness", { root in
                var tasks = try #require(root["tasks"] as? [[String: Any]])
                var task = tasks[0]
                var runs = try #require(task["runs"] as? [[String: Any]])
                var run = runs[0]
                run["liveness"] = "future-liveness"
                runs[0] = run
                task["runs"] = runs
                tasks[0] = task
                root["tasks"] = tasks
            }),
            ("evidence kind", { root in
                var tasks = try #require(root["tasks"] as? [[String: Any]])
                var task = tasks[0]
                var evidence = try #require(task["evidence"] as? [[String: Any]])
                var fact = evidence[0]
                fact["kind"] = "future-kind"
                evidence[0] = fact
                task["evidence"] = evidence
                tasks[0] = task
                root["tasks"] = tasks
            }),
            ("task origin", { root in
                var tasks = try #require(root["tasks"] as? [[String: Any]])
                var task = tasks[0]
                task["origin"] = "future-origin"
                tasks[0] = task
                root["tasks"] = tasks
            }),
        ]
        for (name, mutate) in strictMutations {
            let result = try await loadMutated(mutate)
            #expect(
                result.status == .rejected(.corrupt),
                "strict decode must reject corrupt: \(name)"
            )
        }

        // The feedback `scheme` is a plain UInt8, not an enum: an unknown
        // scheme decodes without throwing and is rejected at VALIDATION —
        // `.invalidMetadata`, not `.corrupt`.
        let scheme = try await loadMutated { root in
            var tasks = try #require(root["tasks"] as? [[String: Any]])
            var task = tasks[0]
            var feedback = try #require(task["feedback"] as? [[String: Any]])
            var record = feedback[0]
            record["scheme"] = 99
            feedback[0] = record
            task["feedback"] = feedback
            tasks[0] = task
            root["tasks"] = tasks
        }
        #expect(scheme.status == .rejected(.invalidMetadata))
    }
}
