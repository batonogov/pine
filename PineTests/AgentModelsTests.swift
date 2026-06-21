//
//  AgentModelsTests.swift
//  PineTests
//
//  Tests for AgentType, AgentState, and AgentSession (vision #933, Phase 1).
//

import AppKit
import Testing
@testable import Pine

@MainActor
struct AgentModelsTests {

    // MARK: - AgentType properties

    @Test func displayName_returnsExpectedNames() {
        #expect(AgentType.claudeCode.displayName == "Claude Code")
        #expect(AgentType.codex.displayName == "Codex")
        #expect(AgentType.aider.displayName == "Aider")
        #expect(AgentType.copilot.displayName == "Copilot")
        #expect(AgentType.generic(name: "Custom").displayName == "Custom")
    }

    @Test func cliNames_containExpectedValues() {
        #expect(AgentType.claudeCode.cliNames == ["claude"])
        #expect(AgentType.codex.cliNames == ["codex"])
        #expect(AgentType.aider.cliNames == ["aider"])
        // Copilot registers both the full CLI name and the short alias.
        #expect(AgentType.copilot.cliNames.contains("github-copilot-cli"))
        #expect(AgentType.copilot.cliNames.contains("copilot"))
        // Generic agents have no known CLI names.
        #expect(AgentType.generic(name: "Custom").cliNames.isEmpty)
    }

    @Test func color_isNotNil() {
        // All cases must return a concrete system color for UI color-coding.
        for agent in [AgentType.claudeCode, .codex, .aider, .copilot, .generic(name: "X")] {
            // NSColor is always non-nil here; exercise the getter to ensure
            // no crash and a valid object is returned for every case.
            #expect(agent.color != NSColor.clear)
        }
    }

    // MARK: - AgentType.resolve(fromProcessName:)

    @Test func resolve_returnsClaudeCodeForKnownName() {
        #expect(AgentType.resolve(fromProcessName: "claude") == .claudeCode)
    }

    @Test func resolve_returnsCodexForKnownName() {
        #expect(AgentType.resolve(fromProcessName: "codex") == .codex)
    }

    @Test func resolve_returnsAiderForKnownName() {
        #expect(AgentType.resolve(fromProcessName: "aider") == .aider)
    }

    @Test func resolve_returnsCopilotForKnownNames() {
        #expect(AgentType.resolve(fromProcessName: "github-copilot-cli") == .copilot)
        #expect(AgentType.resolve(fromProcessName: "copilot") == .copilot)
    }

    @Test func resolve_isCaseInsensitive() {
        #expect(AgentType.resolve(fromProcessName: "CLAUDE") == .claudeCode)
        #expect(AgentType.resolve(fromProcessName: "Codex") == .codex)
        #expect(AgentType.resolve(fromProcessName: "AIDER") == .aider)
    }

    @Test func resolve_trimsWhitespace() {
        #expect(AgentType.resolve(fromProcessName: "  claude  ") == .claudeCode)
        #expect(AgentType.resolve(fromProcessName: "\tcodex\n") == .codex)
    }

    @Test func resolve_returnsGenericForUnknownName() {
        let result = AgentType.resolve(fromProcessName: "my-custom-agent")
        if case .generic(let name) = result {
            #expect(name == "my-custom-agent")
        } else {
            Issue.record("expected .generic, got \(result)")
        }
    }

    @Test func resolve_returnsNilForEmptyName() {
        #expect(AgentType.resolve(fromProcessName: "") == nil)
        #expect(AgentType.resolve(fromProcessName: "   ") == nil)
        #expect(AgentType.resolve(fromProcessName: "\t\n") == nil)
    }

    // MARK: - AgentState

    @Test func agentState_displayNames() {
        #expect(AgentState.idle.displayName == "Idle")
        #expect(AgentState.thinking.displayName == "Thinking")
        #expect(AgentState.executing.displayName == "Executing")
        #expect(AgentState.waitingInput.displayName == "Waiting for input")
        #expect(AgentState.done.displayName == "Done")
    }

    // MARK: - AgentSession

    @Test func agentSession_defaultsToIdleAndEmptyFileLists() {
        let session = AgentSession(agentType: .claudeCode)
        #expect(session.agentType == .claudeCode)
        #expect(session.state == .idle)
        #expect(session.currentTask == nil)
        #expect(session.filesModified.isEmpty)
        #expect(session.filesRead.isEmpty)
    }

    @Test func agentSession_acceptsInitializerValues() {
        let id = UUID()
        let date = Date(timeIntervalSince1970: 1_000_000)
        let modified = [URL(fileURLWithPath: "/tmp/a.swift")]
        let read = [URL(fileURLWithPath: "/tmp/b.swift")]
        let session = AgentSession(
            id: id,
            agentType: .codex,
            state: .executing,
            startedAt: date,
            currentTask: "fix bug",
            filesModified: modified,
            filesRead: read
        )
        #expect(session.id == id)
        #expect(session.agentType == .codex)
        #expect(session.state == .executing)
        #expect(session.startedAt == date)
        #expect(session.currentTask == "fix bug")
        #expect(session.filesModified == modified)
        #expect(session.filesRead == read)
    }

    @Test func agentSession_stateTransitions() {
        let session = AgentSession(agentType: .claudeCode)
        #expect(session.state == .idle)

        session.state = .thinking
        #expect(session.state == .thinking)

        session.state = .executing
        #expect(session.state == .executing)

        session.state = .waitingInput
        #expect(session.state == .waitingInput)

        session.state = .done
        #expect(session.state == .done)
    }

    @Test func agentSession_updatesCurrentTask() {
        let session = AgentSession(agentType: .aider)
        #expect(session.currentTask == nil)

        session.currentTask = "refactor parser"
        #expect(session.currentTask == "refactor parser")

        session.currentTask = nil
        #expect(session.currentTask == nil)
    }

    @Test func agentSession_accumulatesModifiedAndReadFiles() {
        let session = AgentSession(agentType: .copilot)
        let fileA = URL(fileURLWithPath: "/src/a.swift")
        let fileB = URL(fileURLWithPath: "/src/b.swift")

        session.filesModified.append(fileA)
        session.filesModified.append(fileB)
        #expect(session.filesModified == [fileA, fileB])

        session.filesRead.append(fileA)
        #expect(session.filesRead == [fileA])
    }

    @Test func agentSession_identityIsStableAcrossMutations() {
        let session = AgentSession(agentType: .claudeCode)
        let originalID = session.id

        session.state = .executing
        session.currentTask = "new task"
        session.filesModified.append(URL(fileURLWithPath: "/tmp/x.swift"))

        #expect(session.id == originalID)
    }

    @Test func agentSession_equalityIsByIDOnly() {
        let id = UUID()
        let a = AgentSession(id: id, agentType: .claudeCode)
        let b = AgentSession(id: id, agentType: .codex, state: .done)
        // Same id => equal even if other fields differ (identity semantics).
        #expect(a == b)
    }

    @Test func agentSession_distinctIDsAreNotEqual() {
        let a = AgentSession(agentType: .claudeCode)
        let b = AgentSession(agentType: .claudeCode)
        #expect(a != b)
    }
}
