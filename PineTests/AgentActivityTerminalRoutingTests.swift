//
//  AgentActivityTerminalRoutingTests.swift
//  PineTests
//

import Foundation
import Testing

@testable import Pine

@Suite("Agent Activity Terminal Routing")
@MainActor
struct AgentActivityTerminalRoutingTests {
    private static let noOpProcessRunner: ProcessRunner = { _, _, _, _ in
        ProcessRunResult(
            stdout: "",
            stderr: "",
            exitCode: 0,
            timedOut: false
        )
    }

    @Test("Resolver returns the exact pane, tab, owner, and available directory")
    func resolvesExactLiveOwner() throws {
        let fixture = try makeTwoPaneFixture()
        let sessionID = UUID()
        fixture.secondTab.name = " Codex task "
        fixture.secondTab.agentSession = AgentSession(
            id: sessionID,
            agentType: .codex,
            state: .executing
        )
        let action = makeAction(sessionID: sessionID, agentType: .codex)

        let target = try #require(
            AgentActivityTerminalTargetResolver.resolve(
                attribution: action.attribution,
                in: fixture.paneManager
            )
        )

        #expect(target.paneID == fixture.secondPaneID)
        #expect(target.tabID == fixture.secondTab.id)
        #expect(target.sessionID == sessionID)
        #expect(target.agentType == .codex)
        #expect(target.label == "Codex task")
        #expect(target.workingDirectory == fixture.secondDirectory)

        let row = AgentActivityRow(action, terminalTarget: target)
        #expect(row.terminalTarget == target)
        #expect(row.workingDirectory == fixture.secondDirectory)
    }

    @Test("Routing selects the exact target in a multi-pane layout")
    func routesExactMultiPaneTarget() throws {
        let fixture = try makeTwoPaneFixture()
        let firstSessionID = UUID()
        let secondSessionID = UUID()
        fixture.firstTab.agentSession = AgentSession(
            id: firstSessionID,
            agentType: .claudeCode
        )
        fixture.secondTab.agentSession = AgentSession(
            id: secondSessionID,
            agentType: .codex
        )
        fixture.paneManager.activePaneID = fixture.firstPaneID
        let terminalManager = TerminalManager(
            agentDetectionProcessRunner: Self.noOpProcessRunner
        )
        terminalManager.paneManager = fixture.paneManager
        terminalManager.lastActiveTerminalPaneID = fixture.firstPaneID
        let target = try #require(
            AgentActivityTerminalTargetResolver.resolve(
                attribution: makeAction(
                    sessionID: secondSessionID,
                    agentType: .codex
                ).attribution,
                in: fixture.paneManager
            )
        )

        let didRoute = AgentActivityTerminalRouter.route(
            to: target,
            paneManager: fixture.paneManager,
            terminalManager: terminalManager
        )

        #expect(didRoute)
        #expect(fixture.paneManager.activePaneID == fixture.secondPaneID)
        #expect(
            fixture.paneManager
                .terminalState(for: fixture.secondPaneID)?
                .activeTerminalID == fixture.secondTab.id
        )
        #expect(
            fixture.paneManager
                .terminalState(for: fixture.secondPaneID)?
                .pendingFocusTabID == fixture.secondTab.id
        )
        #expect(terminalManager.lastActiveTerminalPaneID == fixture.secondPaneID)
    }

    @Test("Resolver carries stale and terminated process evidence into detail")
    func resolvesLivenessEvidence() throws {
        let fixture = try makeTwoPaneFixture()
        let sessionID = UUID()
        let session = AgentSession(
            id: sessionID,
            agentType: .codex,
            liveness: .stale
        )
        fixture.secondTab.agentSession = session
        let action = AgentAction(
            attribution: .verified(
                AgentActionCandidate(
                    sessionID: sessionID,
                    agentType: .codex
                )
            ),
            kind: .command,
            summary: "safe display only"
        )

        let staleTarget = try #require(
            AgentActivityTerminalTargetResolver.resolve(
                attribution: action.attribution,
                in: fixture.paneManager
            )
        )
        #expect(staleTarget.liveness == .stale)
        #expect(
            AgentActivityRow(action, terminalTarget: staleTarget)
                .activityPresentation.evidenceKind == .stale
        )

        fixture.secondTab.agentSession = AgentSession(
            id: sessionID,
            agentType: .codex,
            liveness: .terminated
        )
        let terminatedTarget = try #require(
            AgentActivityTerminalTargetResolver.resolve(
                attribution: action.attribution,
                in: fixture.paneManager
            )
        )
        #expect(terminatedTarget.liveness == .terminated)
        #expect(
            AgentActivityRow(action, terminalTarget: terminatedTarget)
                .activityPresentation.evidenceKind == .terminated
        )
    }

    @Test("A tab in another pane never satisfies a mismatched pane target")
    func rejectsWrongPaneForExistingTab() throws {
        let fixture = try makeTwoPaneFixture()
        let sessionID = UUID()
        fixture.secondTab.agentSession = AgentSession(
            id: sessionID,
            agentType: .codex
        )
        let resolved = try #require(
            AgentActivityTerminalTargetResolver.resolve(
                attribution: makeAction(
                    sessionID: sessionID,
                    agentType: .codex
                ).attribution,
                in: fixture.paneManager
            )
        )
        let wrongPaneTarget = AgentActivityTerminalTarget(
            paneID: fixture.firstPaneID,
            tabID: resolved.tabID,
            sessionID: resolved.sessionID,
            agentType: resolved.agentType,
            liveness: resolved.liveness,
            label: resolved.label,
            workingDirectory: resolved.workingDirectory
        )
        fixture.paneManager.activePaneID = fixture.firstPaneID
        let terminalManager = TerminalManager(
            agentDetectionProcessRunner: Self.noOpProcessRunner
        )
        terminalManager.paneManager = fixture.paneManager
        terminalManager.lastActiveTerminalPaneID = fixture.firstPaneID

        let didRoute = AgentActivityTerminalRouter.route(
            to: wrongPaneTarget,
            paneManager: fixture.paneManager,
            terminalManager: terminalManager
        )

        #expect(!didRoute)
        #expect(fixture.paneManager.activePaneID == fixture.firstPaneID)
        #expect(terminalManager.lastActiveTerminalPaneID == fixture.firstPaneID)
    }

    @Test("A removed target fails closed without changing terminal focus")
    func rejectsMissingTarget() throws {
        let fixture = try makeTwoPaneFixture()
        let sessionID = UUID()
        fixture.secondTab.agentSession = AgentSession(
            id: sessionID,
            agentType: .codex
        )
        let target = try #require(
            AgentActivityTerminalTargetResolver.resolve(
                attribution: makeAction(
                    sessionID: sessionID,
                    agentType: .codex
                ).attribution,
                in: fixture.paneManager
            )
        )
        fixture.paneManager.removePane(fixture.secondPaneID)
        fixture.paneManager.activePaneID = fixture.firstPaneID
        let terminalManager = TerminalManager(
            agentDetectionProcessRunner: Self.noOpProcessRunner
        )
        terminalManager.paneManager = fixture.paneManager
        terminalManager.lastActiveTerminalPaneID = fixture.firstPaneID

        let didRoute = AgentActivityTerminalRouter.route(
            to: target,
            paneManager: fixture.paneManager,
            terminalManager: terminalManager
        )

        #expect(!didRoute)
        #expect(fixture.paneManager.activePaneID == fixture.firstPaneID)
        #expect(terminalManager.lastActiveTerminalPaneID == fixture.firstPaneID)
    }

    @Test("A tab reassigned to another session invalidates a resolved target")
    func rejectsChangedSessionOwnership() throws {
        let fixture = try makeTwoPaneFixture()
        let sessionID = UUID()
        fixture.secondTab.agentSession = AgentSession(
            id: sessionID,
            agentType: .codex
        )
        let target = try #require(
            AgentActivityTerminalTargetResolver.resolve(
                attribution: makeAction(
                    sessionID: sessionID,
                    agentType: .codex
                ).attribution,
                in: fixture.paneManager
            )
        )
        fixture.secondTab.agentSession = AgentSession(
            agentType: .claudeCode
        )
        fixture.paneManager.activePaneID = fixture.firstPaneID
        let terminalManager = TerminalManager(
            agentDetectionProcessRunner: Self.noOpProcessRunner
        )
        terminalManager.paneManager = fixture.paneManager
        terminalManager.lastActiveTerminalPaneID = fixture.firstPaneID

        let didRoute = AgentActivityTerminalRouter.route(
            to: target,
            paneManager: fixture.paneManager,
            terminalManager: terminalManager
        )

        #expect(!didRoute)
        #expect(fixture.paneManager.activePaneID == fixture.firstPaneID)
        #expect(terminalManager.lastActiveTerminalPaneID == fixture.firstPaneID)
    }

    @Test("Missing or ambiguous ownership exposes no terminal fields or action")
    func hidesUnavailableTerminalContext() {
        let paneManager = PaneManager()
        let first = AgentActionCandidate(
            sessionID: UUID(),
            agentType: .claudeCode
        )
        let second = AgentActionCandidate(
            sessionID: UUID(),
            agentType: .codex
        )
        let action = AgentAction(
            attribution: .ambiguous(candidates: [first, second]),
            kind: .fileWrite,
            summary: "changed file"
        )

        let target = AgentActivityTerminalTargetResolver.resolve(
            attribution: action.attribution,
            in: paneManager
        )
        let row = AgentActivityRow(action, terminalTarget: target)

        #expect(target == nil)
        #expect(row.terminalTarget == nil)
        #expect(row.workingDirectory == nil)
    }

    @Test("Duplicate session ownership is not guessed")
    func rejectsDuplicateSessionOwnership() throws {
        let fixture = try makeTwoPaneFixture()
        let sessionID = UUID()
        fixture.firstTab.agentSession = AgentSession(
            id: sessionID,
            agentType: .claudeCode
        )
        fixture.secondTab.agentSession = AgentSession(
            id: sessionID,
            agentType: .claudeCode
        )

        let target = AgentActivityTerminalTargetResolver.resolve(
            attribution: makeAction(
                sessionID: sessionID,
                agentType: .claudeCode
            ).attribution,
            in: fixture.paneManager
        )

        #expect(target == nil)
    }

    @Test("Recorded action directory remains available without a terminal")
    func preservesRecordedWorkingDirectory() {
        let directory = URL(fileURLWithPath: "/project/recorded")
        let action = AgentAction(
            sessionID: UUID(),
            agentType: .claudeCode,
            kind: .command,
            summary: "ran command",
            workingDirectory: directory
        )
        let row = AgentActivityRow(action)

        #expect(row.terminalTarget == nil)
        #expect(row.workingDirectory == directory)
    }

    @Test("Recorded action directory wins over current terminal context")
    func prefersRecordedWorkingDirectory() {
        let recordedDirectory = URL(fileURLWithPath: "/project/at-action-time")
        let currentDirectory = URL(fileURLWithPath: "/project/current-terminal")
        let sessionID = UUID()
        let action = AgentAction(
            sessionID: sessionID,
            agentType: .claudeCode,
            kind: .fileWrite,
            summary: "changed file",
            workingDirectory: recordedDirectory
        )
        let target = AgentActivityTerminalTarget(
            paneID: PaneID(),
            tabID: UUID(),
            sessionID: sessionID,
            agentType: .claudeCode,
            liveness: .live,
            label: "Claude task",
            workingDirectory: currentDirectory
        )

        let row = AgentActivityRow(action, terminalTarget: target)

        #expect(row.workingDirectory == recordedDirectory)
    }

    private func makeAction(
        sessionID: UUID,
        agentType: AgentType
    ) -> AgentAction {
        AgentAction(
            sessionID: sessionID,
            agentType: agentType,
            kind: .command,
            summary: "ran command"
        )
    }

    private func makeTwoPaneFixture() throws -> TwoPaneFixture {
        let paneManager = PaneManager()
        let editorPaneID = paneManager.activePaneID
        let firstDirectory = URL(fileURLWithPath: "/project/first")
        let secondDirectory = URL(fileURLWithPath: "/project/second")
        let firstPaneID = try #require(
            paneManager.createTerminalPane(
                relativeTo: editorPaneID,
                axis: .vertical,
                workingDirectory: firstDirectory
            )
        )
        let secondPaneID = try #require(
            paneManager.createTerminalPane(
                relativeTo: firstPaneID,
                axis: .horizontal,
                workingDirectory: secondDirectory
            )
        )
        let firstTab = try #require(
            paneManager.terminalState(for: firstPaneID)?.activeTab
        )
        let secondTab = try #require(
            paneManager.terminalState(for: secondPaneID)?.activeTab
        )
        return TwoPaneFixture(
            paneManager: paneManager,
            firstPaneID: firstPaneID,
            firstTab: firstTab,
            secondPaneID: secondPaneID,
            secondTab: secondTab,
            secondDirectory: secondDirectory
        )
    }
}

@MainActor
private struct TwoPaneFixture {
    let paneManager: PaneManager
    let firstPaneID: PaneID
    let firstTab: TerminalTab
    let secondPaneID: PaneID
    let secondTab: TerminalTab
    let secondDirectory: URL
}
