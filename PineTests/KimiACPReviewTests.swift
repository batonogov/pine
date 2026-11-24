import Foundation
import Testing

@testable import Pine

@Suite("Kimi ACP Review")
@MainActor
struct KimiACPReviewTests {
    @Test("Owning structured session supplies the review verdict")
    func registryReviewUsesOwningSession() async throws {
        let candidate = try await ReviewServiceFixture()
        defer { candidate.remove() }
        let lease = try await candidate.bindings.revalidate(candidate.binding)
        let run = try #require(candidate.task.runs.last)
        let observation = AgentTaskCheckObservation(
            taskID: candidate.task.id, runID: run.id, passID: UUID(), executionID: UUID(),
            planFingerprint: candidate.plan.fingerprint, processGeneration: run.process.processGeneration,
            journalCompleted: true,
            results: [AgentTaskCheckObservation.CommandResult(
                operationID: UUID(), fingerprint: try #require(candidate.plan.commands.first).fingerprint,
                required: true, status: .succeeded
            )],
            preCodeState: candidate.snapshot.code, postCodeState: candidate.snapshot.code,
            environment: candidate.snapshot.environment
        )
        let binding = AgentAdapterReviewBinding(
            lease: lease, expected: candidate.snapshot, changeContext: "", checks: observation
        )
        let fixture = try await KimiTestFixture.make(reviewBinding: binding) { _ in .accepted }
        try await fixture.session.start()
        let review = Task {
            try await fixture.registry.review(
                on: fixture.session,
                request: AgentAdapterReviewRequest(
                    objective: "Implement the request", criteria: "Acceptance is satisfied",
                    candidateFingerprint: String(repeating: "a", count: 64),
                    checkPlanIdentity: String(repeating: "b", count: 64),
                    binding: binding
                )
            )
        }
        #expect(await waitUntilMainActor { fixture.transport.promptRequestIDs.count == 1 })
        let prompt = try #require(fixture.transport.promptRequestIDs.first)
        fixture.transport.push(.notification(method: "session/update", params: .object([
            "sessionId": .string(fixture.transport.sessionID),
            "update": .object([
                "sessionUpdate": .string("agent_message_chunk"),
                "content": .object([
                    "type": .string("text"),
                    "text": .string("{\"outcome\":\"requestedChanges\",\"finding\":\"Fix the regression\"}")
                ])
            ])
        ])))
        fixture.transport.push(.response(prompt, result: .object(["stopReason": .string("end_turn")])))

        let result = try await review.value
        #expect(result.outcome == .requestedChanges)
        #expect(result.finding == "Fix the regression")
        #expect(try await fixture.registry.reviewerIdentity(for: fixture.session).opaqueIdentifier
            == fixture.transport.sessionID)
        await fixture.session.stop(deadline: ContinuousClock.now.advanced(by: .seconds(2)))
    }

    @Test("Kimi does not claim an enforced non-writing boundary")
    func kimiBoundaryIsHonest() throws {
        let factory = KimiACPFactory(
            id: try AdapterFactoryID(validating: "kimi-boundary"), observation: nil,
            admit: { _ in throw KimiACPWireError.unavailable }
        )
        #expect(factory.reviewerControl == .promptOnly)
        #expect(!factory.reviewerControl.provesNonWritingReview)
    }
}
