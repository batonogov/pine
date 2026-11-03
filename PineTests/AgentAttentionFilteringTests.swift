import Testing
import Foundation

@testable import Pine

@MainActor
struct AgentAttentionFilteringTests {
    @Test("idle-only input has no attention rows", arguments: [AgentLiveness.live, .stale, .terminated])
    func idleOnlyIsEmpty(liveness: AgentLiveness) {
        let idle = summary(state: .idle, liveness: liveness)
        #expect(AgentAttentionOverlay.attentionSummaries([idle]).isEmpty)
    }

    @Test("attention filtering does not discard status summaries or non-idle evidence")
    func mixedInput() {
        let idle = summary(state: .idle)
        let working = summary(state: .executing)
        let stale = summary(state: .waitingInput, liveness: .stale)
        let exited = summary(state: .done, liveness: .terminated)
        let input = [idle, exited, stale, working]
        #expect(AgentAttentionOverlay.attentionSummaries(input).map(\.id) == [working.id, stale.id, exited.id])
        #expect(input.count == 4)
        #expect(input.first?.state == .idle)
    }

    private func summary(state: AgentState, liveness: AgentLiveness = .live) -> AgentStatusSummary {
        AgentStatusSummary(id: UUID(), agentType: .codex, state: state, liveness: liveness,
                           paneID: PaneID(), tabID: UUID())
    }
}
