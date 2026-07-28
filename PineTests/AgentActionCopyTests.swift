//
//  AgentActionCopyTests.swift
//  PineTests
//

import Foundation
import Testing

@testable import Pine

@Suite("Agent Activity Safe Copy")
@MainActor
struct AgentActionCopyTests {
    @Test(
        "Free-form command and tool summaries are never copied",
        arguments: [
            "API_TOKEN=super-secret npm test",
            "curl -H 'Authorization: Bearer sk-secret' https://example.test",
            "https://user:password@example.test/path?token=secret",
            "tool(password: \"secret\")"
        ]
    )
    func summariesAreExcluded(_ summary: String) {
        let action = AgentAction(
            sessionID: UUID(),
            agentType: .codex,
            kind: .command,
            status: .failed,
            summary: summary,
            workingDirectory: URL(fileURLWithPath: "/project")
        )

        let copied = action.copyableSummary
        #expect(!copied.contains(summary))
        #expect(!copied.localizedCaseInsensitiveContains("super-secret"))
        #expect(!copied.localizedCaseInsensitiveContains("sk-secret"))
        #expect(!copied.localizedCaseInsensitiveContains("password"))
        #expect(copied.contains(action.kind.displayName))
        #expect(copied.contains(action.status.displayName))
    }

    @Test("Row carries only the structured safe copy payload")
    func rowUsesStructuredPayload() {
        let action = AgentAction(
            sessionID: UUID(),
            agentType: .claudeCode,
            kind: .toolCall,
            summary: "TOKEN=must-not-copy"
        )
        let row = AgentActivityRow(action)

        #expect(row.safeCopyText == action.copyableSummary)
        #expect(!row.safeCopyText.contains("must-not-copy"))
    }
}
