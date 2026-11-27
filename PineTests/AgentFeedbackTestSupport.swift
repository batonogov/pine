//
//  AgentFeedbackTestSupport.swift
//  PineTests
//
//  Shared fixtures for the #1758 suites: a Ready task in a registry backed
//  by a real temporary store (so "durable before dispatch" is exercised
//  through production code), and a feedback route that records every
//  dispatch.
//

import Foundation
import Testing
@testable import Pine

@MainActor
enum AgentFeedbackTestSupport {
    static let code = ADEContractFixtures.codeState("a")
    static let environment = ADEContractFixtures.environment

    final class Harness {
        let fixture: ADEContractPersistenceFixture
        let identity: AgentTaskProjectIdentity
        let registry: AgentTaskRegistry
        let task: AgentTask

        fileprivate init(
            fixture: ADEContractPersistenceFixture,
            identity: AgentTaskProjectIdentity,
            registry: AgentTaskRegistry,
            task: AgentTask
        ) {
            self.fixture = fixture
            self.identity = identity
            self.registry = registry
            self.task = task
        }

        /// What a fresh process would load from the same store.
        func storedTasks() async -> [AgentTask] {
            let result = await AgentTaskMetadataStore(storageRoot: fixture.storage)
                .load(project: identity)
            return result.tasks
        }
    }

    static func readyRegistry(seed: Int = 1_758) async throws -> Harness {
        let fixture = try ADEContractPersistenceFixture()
        let identity = ADEContractFixtures.project(fixture.project.path)
        let registry = AgentTaskRegistry(
            persistence: AgentTaskMetadataStore(storageRoot: fixture.storage)
        )
        registry.registerProject(identity)
        #expect(await registry.flushPersistence() == .saved)
        let task = try ADEContractFixtures.verifiedSuccessTask(
            seed: seed,
            codeState: code,
            environment: environment,
            now: Date(),
            projectPath: fixture.project.path
        )
        registry.setTasksForTesting([task])
        return Harness(fixture: fixture, identity: identity, registry: registry, task: task)
    }

    /// The same task after a newer result was reviewed and verified for its
    /// latest run: every bound fact now belongs to the new code state.
    static func withNewerResult(
        _ task: AgentTask, tag: Character = "d", secondsLater: TimeInterval = 60
    ) -> AgentTask {
        let code = ADEContractFixtures.codeState(tag)
        let reviewed = task.reviewedSnapshot ?? AgentTaskResultSnapshot(
            runID: task.runs[0].id, outcome: .success, codeState: self.code,
            environment: environment, recordedAt: Date(timeIntervalSince1970: 0)
        )
        var newer = task
        newer.evidence = task.evidence.map { fact in
            let rebound = fact.kind == .agentReportedCompletion
                || AgentTaskLifecycleReducer.requiredEvidenceForSuccess.contains(fact.kind)
            guard rebound else { return fact }
            // Operation fingerprints are only valid on the check/review
            // kinds; the completion claim carries none (the store rejects a
            // fact whose pre/post are set on any other kind).
            let isOperationKind = fact.kind == .independentCheck
                || fact.kind == .reviewerOutcome
            return ADEContractFixtures.fact(
                fact.kind,
                runID: fact.runID,
                generation: fact.processGeneration,
                result: fact.result,
                at: fact.observedAt.addingTimeInterval(secondsLater),
                trust: fact.trust,
                codeState: code,
                environment: environment,
                sequence: fact.sourceSequence,
                pre: isOperationKind ? code : nil,
                post: isOperationKind ? code : nil
            )
        }
        newer.reviewedSnapshot = AgentTaskResultSnapshot(
            runID: reviewed.runID,
            outcome: .success,
            codeState: code,
            environment: environment,
            recordedAt: reviewed.recordedAt.addingTimeInterval(secondsLater)
        )
        newer.updatedAt = max(task.updatedAt, reviewed.recordedAt.addingTimeInterval(secondsLater))
        newer.lastActivityAt = newer.updatedAt
        return newer
    }

    /// A valid submission about the task's reviewed revision.
    static func submission(
        for task: AgentTask,
        text: String = "Make the greeting shorter SECRET",
        anchor: AgentFeedbackLocationAnchor = .plainText,
        attachments: [AgentFeedbackAttachment] = []
    ) throws -> AgentFeedbackSubmission {
        let reference = AgentFeedbackReference(
            taskID: task.id,
            candidate: task.reviewedSnapshot ?? AgentTaskResultSnapshot(
                runID: task.runs[0].id, outcome: .success, codeState: code,
                environment: environment, recordedAt: Date()
            ),
            artifactKind: .code,
            anchor: anchor,
            userText: text,
            attachments: attachments
        )
        return try AgentFeedbackStateMachine.submit(
            draft: AgentFeedbackDraft(reference: reference), support: .none, existing: []
        ).get()
    }

    static func image(id: UUID = UUID()) -> AgentFeedbackAttachment {
        AgentFeedbackAttachment(
            id: id,
            kind: .image,
            captureBasis: .livePreviewObservation,
            sha256: String(repeating: "7", count: 64),
            byteCount: 123_456,
            label: "SECRET preview capture"
        )
    }
}

/// A feedback route that records every dispatch and answers from a script.
@MainActor
final class AgentFeedbackRecordingRoute {
    var requests: [AgentFeedbackDispatchRequest] = []
    var reachable = true
    var answer: @MainActor (
        AgentFeedbackDispatchRequest
    ) async throws -> AgentFeedbackDeliveryReceipt? = { request in
        AgentFeedbackDeliveryReceipt(submissionID: request.submissionID)
    }

    lazy var route = AgentFeedbackRoute(
        agentName: "OpenCode",
        isReachable: { self.reachable },
        dispatch: { request in
            self.requests.append(request)
            return try await self.answer(request)
        }
    )
}
