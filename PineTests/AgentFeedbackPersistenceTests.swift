//
//  AgentFeedbackPersistenceTests.swift
//  PineTests
//
//  The durable feedback-submission record (#1758): identities only, a real
//  store round trip that keeps the exact commented revision, fail-closed
//  validation, the documented field set for tasks without feedback, and the
//  duplicate fence shared with the state machine.
//

import Foundation
import Testing
@testable import Pine

@MainActor
@Suite("Durable feedback-submission record", .serialized)
struct AgentFeedbackPersistenceTests {
    private func encodeJSON(_ value: some Encodable) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func readyTask(seed: Int, projectPath: String? = nil) throws -> AgentTask {
        try ADEContractFixtures.verifiedSuccessTask(
            seed: seed,
            codeState: AgentFeedbackTestSupport.code,
            environment: AgentFeedbackTestSupport.environment,
            projectPath: projectPath
        )
    }

    /// The same record with one field rewritten, decoded back.
    private func tampered(
        _ record: AgentFeedbackSubmissionRecord,
        _ edit: (inout [String: Any]) -> Void
    ) throws -> AgentFeedbackSubmissionRecord {
        var json = try encodeJSON(record)
        edit(&json)
        return try JSONDecoder().decode(
            AgentFeedbackSubmissionRecord.self,
            from: JSONSerialization.data(withJSONObject: json)
        )
    }

    @Test("The record persists identities only: never the words, a label, or a path")
    func recordCarriesIdentitiesOnly() throws {
        let task = try readyTask(seed: 1_758)
        let image = AgentFeedbackTestSupport.image()
        let reference = AgentFeedbackReference(
            taskID: task.id,
            candidate: try #require(task.reviewedSnapshot),
            artifactKind: .code,
            anchor: .lineRange(path: "Sources/SECRET/main.swift", start: 3, end: 9),
            userText: "SECRET words",
            attachments: [image]
        )
        // The explicit text-only path: the image is left out and disclosed.
        let gate = AgentFeedbackSubmissionGate.validate(reference, against: .none)
        let textOnly = try AgentFeedbackStateMachine.submitTextOnly(
            draft: AgentFeedbackDraft(reference: reference),
            rejections: gate.rejections,
            existing: []
        ).get()
        let record = AgentFeedbackSubmissionRecord(textOnly)

        #expect(record.isValid)
        #expect(record.candidate == reference.candidate)
        #expect(record.fingerprint == textOnly.fingerprint)
        #expect(record.attachmentIDs == [image.id])
        #expect(record.disclosedOmissions == textOnly.disclosedOmissions)
        #expect(record.anchorResolutionAtSubmission == .resolved)
        // The persisted field set is exactly the documented contract.
        #expect(Set(try encodeJSON(record).keys) == [
            "scheme", "id", "candidate", "fingerprint", "attachmentIDs", "submittedAt",
            "anchorResolutionAtSubmission", "disclosedOmissions", "state", "resolution",
        ])
        let encoded = try #require(String(
            data: JSONEncoder().encode(record), encoding: .utf8
        ))
        #expect(!encoded.contains("SECRET"), "no words, label, or path may be persisted")
    }

    @Test("A submission record round-trips through the real store with its exact reference")
    func storeRoundTripKeepsTheExactReference() async throws {
        let fixture = try ADEContractPersistenceFixture()
        defer { fixture.cleanup() }
        let identity = ADEContractFixtures.project(fixture.project.path)
        var task = try readyTask(seed: 1_759, projectPath: fixture.project.path)
        let submission = try AgentFeedbackTestSupport.submission(for: task)
        task.feedbackSubmissions = [AgentFeedbackSubmissionRecord(submission)]
        let store = AgentTaskMetadataStore(storageRoot: fixture.storage)

        #expect(await store.save(tasks: [task], project: identity) == .saved(taskCount: 1))
        let loaded = await store.load(project: identity)
        let stored = try #require(loaded.tasks.first?.feedbackSubmissions.first)

        // A newer candidate does not re-target what the feedback was about.
        #expect(stored.id == submission.id)
        #expect(stored.fingerprint == submission.fingerprint)
        #expect(stored.candidate.runID == submission.reference.candidate.runID)
        #expect(stored.candidate.codeState == submission.reference.candidate.codeState)
        #expect(stored.candidate.environment == submission.reference.candidate.environment)
        #expect(stored.state == .queued)
        #expect(stored.resolution == .unresolved)
        // The file itself carries the reference and nothing that was typed.
        let file = AgentTaskMetadataStore.metadataURL(
            for: identity, storageRoot: fixture.storage
        )
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.contains(submission.fingerprint))
        #expect(!text.contains("SECRET"))
    }

    @Test("The store rejects a tampered record fail-closed")
    func tamperedRecordIsRejected() async throws {
        let task = try readyTask(seed: 1_760)
        let submission = try AgentFeedbackTestSupport.submission(for: task)
        let record = AgentFeedbackSubmissionRecord(submission)
        var delivered = submission
        _ = delivered.apply(receipt: AgentFeedbackDeliveryReceipt(submissionID: submission.id))
        // An omission that names an attachment the draft never carried.
        let orphanOmission = try AgentFeedbackStateMachine.submitTextOnly(
            draft: AgentFeedbackDraft(reference: submission.reference),
            rejections: [AgentFeedbackAttachmentRejection(
                attachmentID: UUID(), reason: .unsupportedKind
            )],
            existing: []
        ).get()

        let tamperedRecords: [(String, AgentFeedbackSubmissionRecord)] = [
            ("a future scheme", try tampered(record) { $0["scheme"] = 2 }),
            ("a non-hash fingerprint", try tampered(record) { $0["fingerprint"] = "SECRET" }),
            ("an acknowledgment for another id", try tampered(
                AgentFeedbackSubmissionRecord(delivered)
            ) { $0["id"] = UUID().uuidString }),
        ]
        for (name, value) in tamperedRecords {
            #expect(!value.isValid, "\(name)")
        }
        // An omission naming an attachment the draft never carried is inert:
        // the record's field set cannot distinguish it (attachmentIDs
        // includes disclosed omissions by construction) and the fingerprint
        // still binds the exact submitted reference.
        let orphanRecord = AgentFeedbackSubmissionRecord(orphanOmission)
        #expect(orphanRecord.isValid)
        #expect(Set(orphanRecord.disclosedOmissions.map(\.attachmentID))
            .isSubset(of: Set(orphanRecord.attachmentIDs)))

        // One representative violation rejects the whole file.
        let fixture = try ADEContractPersistenceFixture()
        defer { fixture.cleanup() }
        let identity = ADEContractFixtures.project(fixture.project.path)
        var poisoned = try readyTask(seed: 1_761, projectPath: fixture.project.path)
        poisoned.feedbackSubmissions = [
            record, try tampered(record) { $0["scheme"] = 2 },
        ]
        #expect(await AgentTaskMetadataStore(storageRoot: fixture.storage)
            .save(tasks: [poisoned], project: identity) == .rejected(.invalidMetadata))
    }

    @Test("A task without feedback keeps the documented persisted field set")
    func tasksWithoutFeedbackKeepTheirFieldSet() throws {
        let task = try readyTask(seed: 1_762)

        #expect(try !Set(encodeJSON(task).keys).contains("feedbackSubmissions"))
        // Metadata written before the field decodes to no submissions.
        let decoded = try JSONDecoder().decode(
            AgentTask.self, from: JSONEncoder().encode(task)
        )
        #expect(decoded.feedbackSubmissions.isEmpty)

        var withFeedback = task
        withFeedback.feedbackSubmissions = [
            AgentFeedbackSubmissionRecord(try AgentFeedbackTestSupport.submission(for: task)),
        ]
        #expect(try encodeJSON(withFeedback).keys.contains("feedbackSubmissions"))
    }

    @Test("The durable duplicate fence applies the state machine's rule for every state")
    func durableFenceMatchesTheStateMachine() throws {
        let task = try readyTask(seed: 1_763)
        let submission = try AgentFeedbackTestSupport.submission(for: task)
        let delivered = AgentFeedbackDeliveryOutcome(
            receipt: AgentFeedbackDeliveryReceipt(submissionID: submission.id),
            sentAttachmentIDs: []
        )
        let states: [(AgentFeedbackDeliveryState, Bool)] = [
            (.queued, true),
            (.delivered(delivered), true),
            (.failed(.transportUnavailable), false),
            (.cancelled, false),
            (.deliveryUnknown, true),
        ]
        for (state, blocksResubmission) in states {
            var live = submission
            live.state = state
            let machine = AgentFeedbackStateMachine.submit(
                draft: AgentFeedbackDraft(reference: live.reference),
                support: .none,
                existing: [live]
            )
            let fenced = [AgentFeedbackSubmissionRecord(live)]
                .duplicateBlockingSubmission(live.fingerprint)?.id
            // Both fences name the same submission, or neither does.
            #expect((fenced != nil) == blocksResubmission, "\(state)")
            switch machine {
            case .failure(.duplicateSubmission(let id)):
                #expect(blocksResubmission && id == live.id, "\(state)")
            case .success:
                #expect(!blocksResubmission, "\(state)")
            case .failure(let fence):
                Issue.record("unexpected fence for \(state): \(fence)")
            }
        }
    }
}
