import Foundation
import Testing
@testable import Pine

@Suite("Agent activity lifecycle")
@MainActor
struct AgentActivityLifecycleTests {
    @Test("Completion within dedupe window updates the existing row and filters")
    func completionUpdatesExistingIdentity() {
        let store = AgentActivityStore()
        let original = action(status: .inProgress)
        store.record(original)
        let completion = action(id: original.id, status: .completed,
                                timestamp: original.timestamp.addingTimeInterval(0.1))
        store.record(completion)
        #expect(store.actions.count == 1)
        #expect(store.actions.first?.id == original.id)
        #expect(store.actions.first?.timestamp == original.timestamp)
        #expect(store.filtered(status: .completed).count == 1)
        #expect(store.filtered(status: .inProgress).isEmpty)
    }

    @Test("Lifecycle updates are in-place even beyond the window and behind newer work")
    func completionPreservesChronology() {
        let store = AgentActivityStore()
        let original = action(status: .inProgress)
        let newer = action(status: .failed, timestamp: original.timestamp.addingTimeInterval(2))
        store.record(original)
        store.record(newer)
        store.record(action(id: original.id, status: .completed,
                            timestamp: original.timestamp.addingTimeInterval(10)))
        #expect(store.actions.map(\.id) == [original.id, newer.id])
        #expect(store.actions.first?.timestamp == original.timestamp)
        #expect(store.actions.first?.status == .completed)
    }

    @Test("Different IDs with differing lifecycle status are not deduplicated")
    func dedupeIncludesStatus() {
        let store = AgentActivityStore()
        let original = action(status: .inProgress)
        store.record(original)
        store.record(action(status: .completed, timestamp: original.timestamp))
        #expect(store.actions.count == 2)
        #expect(store.filtered(status: .completed).count == 1)
    }

    @Test("Identical refreshes still deduplicate")
    func unchangedStatusDeduplicates() {
        let store = AgentActivityStore()
        let original = action(status: .completed)
        store.record(original)
        store.record(action(status: .completed, timestamp: original.timestamp))
        #expect(store.actions.count == 1)
    }

    @Test("Out-of-order timestamps are not treated as within the dedupe window")
    func earlierEventIsNotDuplicate() {
        let store = AgentActivityStore()
        let original = action(status: .completed)
        store.record(original)
        store.record(action(status: .completed, timestamp: original.timestamp.addingTimeInterval(-2)))
        #expect(store.actions.count == 2)
    }

    @Test("Distinct in-flight IDs survive dedupe so each completion reaches its own row")
    func distinctInFlightActionsRetainIdentity() {
        let store = AgentActivityStore()
        let first = action(status: .inProgress)
        let second = action(status: .inProgress, timestamp: first.timestamp)
        store.record(first)
        store.record(second)
        #expect(store.actions.map(\.id) == [first.id, second.id])
        #expect(store.filtered(status: .inProgress).count == 2)
        store.record(action(id: second.id, status: .completed, timestamp: first.timestamp))
        #expect(store.actions.map(\.id) == [first.id, second.id])
        #expect(store.actions.first?.status == .inProgress)
        #expect(store.actions.last?.status == .completed)
        store.record(action(id: first.id, status: .completed, timestamp: first.timestamp))
        #expect(store.filtered(status: .completed).count == 2)
    }

    private func action(id: UUID = UUID(), status: AgentActionStatus, timestamp: Date = Date()) -> AgentAction {
        AgentAction(id: id, sessionID: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1)),
                    agentType: .codex, kind: .command, status: status, timestamp: timestamp, summary: "build")
    }
}
