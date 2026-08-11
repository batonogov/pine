//
//  AgentProjectTerminalOwnershipTests.swift
//  PineTests
//

import Foundation
import Testing

@testable import Pine

@Suite("Agent Project Terminal Ownership")
@MainActor
struct AgentProjectTerminalOwnershipTests {
    @Test("Activity candidates stay inside exact owning project terminals")
    func activityCandidatesAreProjectScoped() throws {
        let fixtureA = try makeProjectFixture(name: "A", terminalCount: 2)
        let fixtureB = try makeProjectFixture(name: "B", terminalCount: 1)
        defer {
            try? FileManager.default.removeItem(at: fixtureA.root)
            try? FileManager.default.removeItem(at: fixtureB.root)
        }

        let firstA = exactSession(
            id: try #require(UUID(
                uuidString: "00000000-0000-0000-0000-000000000001"
            )),
            type: .claudeCode,
            pid: 101,
            generation: 1
        )
        let secondA = exactSession(
            id: try #require(UUID(
                uuidString: "00000000-0000-0000-0000-000000000002"
            )),
            type: .codex,
            pid: 102,
            generation: 2
        )
        let onlyB = exactSession(
            id: try #require(UUID(
                uuidString: "00000000-0000-0000-0000-000000000003"
            )),
            type: .pi,
            pid: 201,
            generation: 1
        )
        fixtureA.tabs[0].agentSession = firstA
        fixtureA.tabs[1].agentSession = secondA
        fixtureB.tabs[0].agentSession = onlyB
        fixtureA.project.terminal.captureProjectAgentOwnership(
            of: firstA,
            in: fixtureA.tabs[0]
        )
        fixtureA.project.terminal.captureProjectAgentOwnership(
            of: secondA,
            in: fixtureA.tabs[1]
        )
        fixtureB.project.terminal.captureProjectAgentOwnership(
            of: onlyB,
            in: fixtureB.tabs[0]
        )

        // Both per-project detectors see an unrelated machine-wide process.
        // It is deliberately not attached to either project's terminal tree.
        fixtureA.project.terminal.agentDetector.processSnapshotDidUpdate([
            DetectedProcess(pid: 900, command: "gemini"),
        ])
        fixtureB.project.terminal.agentDetector.processSnapshotDidUpdate([
            DetectedProcess(pid: 900, command: "gemini"),
        ])
        #expect(fixtureA.project.terminal.agentDetector.activeSessions.count == 1)
        #expect(fixtureB.project.terminal.agentDetector.activeSessions.count == 1)

        recordNewChange("A.swift", in: fixtureA)
        recordNewChange("B.swift", in: fixtureB)

        let actionA = try #require(fixtureA.project.agentActivity.actions.first)
        let actionB = try #require(fixtureB.project.agentActivity.actions.first)
        #expect(candidateIDs(actionA) == Set([firstA.id, secondA.id]))
        #expect(candidateIDs(actionB) == Set([onlyB.id]))
        #expect(!candidateIDs(actionA).contains(onlyB.id))
        #expect(!candidateIDs(actionB).contains(firstA.id))
        #expect(!candidateIDs(actionB).contains(secondA.id))
        if case .ambiguous = actionA.attribution {
            // Expected: both owner-local sessions remain candidates.
        } else {
            Issue.record("Project A attribution should be ambiguous")
        }
        if case .inferred = actionB.attribution {
            // Expected: the sibling has exactly one owner-local candidate.
        } else {
            Issue.record("Project B attribution should be inferred")
        }

        // Window availability changes do not widen the project boundary, and
        // reopening the same manager recovers the same exact bindings.
        fixtureA.project.terminal.setAgentTaskWindowOpen(false)
        #expect(
            Set(fixtureA.project.terminal.projectOwnedActiveAgentSessions.map(\.id))
                == Set([firstA.id, secondA.id])
        )
        fixtureA.project.terminal.setAgentTaskWindowOpen(true)
        #expect(
            Set(fixtureA.project.terminal.projectOwnedActiveAgentSessions.map(\.id))
                == Set([firstA.id, secondA.id])
        )
        #expect(
            fixtureB.project.terminal.projectOwnedActiveAgentSessions.map(\.id)
                == [onlyB.id]
        )
    }

    @Test("Unavailable precise ownership fails closed and exact reattach is stable")
    func unavailableOwnershipAndReattach() throws {
        let fixture = try makeProjectFixture(name: "Unavailable", terminalCount: 1)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let tab = fixture.tabs[0]

        let missingEvidence = AgentSession(agentType: .codex)
        tab.agentSession = missingEvidence
        #expect(fixture.project.terminal.projectOwnedActiveAgentSessions.isEmpty)
        fixture.project.terminal.captureProjectAgentOwnership(
            of: missingEvidence,
            in: tab
        )

        let fallback = AgentSession(agentType: .claudeCode)
        _ = fallback.bindProcessEvidence(AgentProcessEvidence(
            processIdentifier: 301,
            processGeneration: 1,
            startIdentifier: "coarse-301",
            observedStartedAt: Date(timeIntervalSince1970: 301),
            startIsAuthoritative: false
        ))
        tab.agentSession = fallback
        #expect(fixture.project.terminal.projectOwnedActiveAgentSessions.isEmpty)

        let exact = exactSession(type: .aider, pid: 302, generation: 2)
        tab.agentSession = exact
        // A forged authoritative-looking object in a tab is not ownership:
        // only the coordinator capture can attest the exact binding.
        #expect(fixture.project.terminal.projectOwnedActiveAgentSessions.isEmpty)
        fixture.project.terminal.captureProjectAgentOwnership(
            of: exact,
            in: tab
        )
        #expect(
            fixture.project.terminal.projectOwnedActiveAgentSessions.first
                === exact
        )
        exact.applyLiveness(.stale)
        #expect(fixture.project.terminal.projectOwnedActiveAgentSessions.isEmpty)

        tab.agentSession = nil
        #expect(fixture.project.terminal.projectOwnedActiveAgentSessions.isEmpty)
        exact.applyLiveness(.live)
        tab.agentSession = exact
        #expect(
            fixture.project.terminal.projectOwnedActiveAgentSessions.first
                === exact
        )

        let nonFinite = AgentSession(agentType: .pi)
        _ = nonFinite.bindProcessEvidence(AgentProcessEvidence(
            processIdentifier: 303,
            processGeneration: 3,
            startIdentifier: "coarse-303",
            observedStartedAt: Date(timeIntervalSinceReferenceDate: .infinity),
            startIsAuthoritative: true
        ))
        tab.agentSession = nonFinite
        fixture.project.terminal.captureProjectAgentOwnership(
            of: nonFinite,
            in: tab
        )
        #expect(fixture.project.terminal.projectOwnedActiveAgentSessions.isEmpty)

        let terminatedBeforeCapture = exactSession(
            type: .codex,
            pid: 304,
            generation: 4
        )
        markDone(terminatedBeforeCapture)
        tab.agentSession = terminatedBeforeCapture
        fixture.project.terminal.captureProjectAgentOwnership(
            of: terminatedBeforeCapture,
            in: tab
        )

        markDone(missingEvidence)
        markDone(fallback)
        #expect(
            fixture.project.terminal.takeProjectOwnedCompletedAgentSessions()
                .isEmpty
        )
    }

    @Test("Coordinator production reconciliation attests the exact binding")
    func coordinatorAutomaticallyAttestsBinding() throws {
        let fixture = try makeProjectFixture(name: "Coordinator", terminalCount: 1)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let tab = fixture.tabs[0]
        let coordinator = AgentDetectionCoordinator(
            detector: fixture.project.terminal.agentDetector,
            terminalManager: fixture.project.terminal
        )
        let agent = coordinatorProcess(
            pid: 350,
            command: "codex",
            startedAt: 350
        )
        setCoordinatorOwnership(agent, on: tab)

        #expect(fixture.project.terminal.projectOwnedActiveAgentSessions.isEmpty)
        coordinator.applySnapshotForTesting(processes: [agent])

        let session = try #require(tab.agentSession)
        #expect(
            fixture.project.terminal.projectOwnedActiveAgentSessions.first
                === session
        )
        recordNewChange("Coordinator.swift", in: fixture)
        let action = try #require(fixture.project.agentActivity.actions.first)
        #expect(candidateIDs(action) == [session.id])
    }

    @Test("ProjectRegistry background reopen preserves exact ownership boundary")
    func registryBackgroundReopenPreservesOwnership() throws {
        let root = try makeTemporaryRoot(name: "Registry")
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = ProjectRegistry()
        let project = try #require(registry.projectManager(for: root))
        let paneID = project.paneManager.createTerminalPaneAtBottom(
            workingDirectory: root
        )
        let tab = try #require(
            project.paneManager.terminalState(for: paneID)?.activeTab
        )
        let session = exactSession(type: .pi, pid: 360, generation: 1)
        tab.agentSession = session
        project.terminal.captureProjectAgentOwnership(of: session, in: tab)
        #expect(project.terminal.projectOwnedActiveAgentSessions == [session])

        registry.closeProjectWindow(root)
        let canonical = ProjectRegistry.canonicalProjectURL(root)
        #expect(registry.backgroundProjects.contains(canonical))
        #expect(project.terminal.projectOwnedActiveAgentSessions == [session])

        let reopened = try #require(registry.projectManager(for: root))
        #expect(reopened === project)
        #expect(!registry.backgroundProjects.contains(canonical))
        #expect(reopened.allTerminalTabs.contains(where: { $0 === tab }))
        #expect(reopened.terminal.projectOwnedActiveAgentSessions == [session])
    }

    @Test("Sequential process-generation conflict remains quarantined")
    func sequentialProcessConflictFailsClosed() throws {
        let fixture = try makeProjectFixture(name: "Sequential", terminalCount: 1)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let tab = fixture.tabs[0]
        let first = exactSession(type: .codex, pid: 450, generation: 8)
        let conflicting = exactSession(
            type: .claudeCode,
            pid: 450,
            generation: 8
        )

        tab.agentSession = first
        fixture.project.terminal.captureProjectAgentOwnership(
            of: first,
            in: tab
        )
        #expect(fixture.project.terminal.projectOwnedActiveAgentSessions == [first])

        tab.agentSession = nil
        tab.agentSession = conflicting
        fixture.project.terminal.captureProjectAgentOwnership(
            of: conflicting,
            in: tab
        )

        #expect(fixture.project.terminal.projectOwnedActiveAgentSessions.isEmpty)
        markDone(first)
        markDone(conflicting)
        #expect(
            fixture.project.terminal.takeProjectOwnedCompletedAgentSessions()
                .isEmpty
        )
    }

    @Test("Maximize keeps hidden owned terminal sessions in project scope")
    func maximizePreservesHiddenTerminalOwnership() throws {
        let fixture = try makeProjectFixture(name: "Maximize", terminalCount: 1)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let secondPaneID = try #require(
            fixture.project.paneManager.createTerminalPane(
                relativeTo: fixture.paneID,
                axis: .horizontal,
                workingDirectory: fixture.root
            )
        )
        let hiddenTab = try #require(
            fixture.project.paneManager.terminalState(for: secondPaneID)?.activeTab
        )
        let visible = exactSession(type: .codex, pid: 460, generation: 1)
        let hidden = exactSession(type: .pi, pid: 461, generation: 2)
        fixture.tabs[0].agentSession = visible
        hiddenTab.agentSession = hidden
        fixture.project.terminal.captureProjectAgentOwnership(
            of: visible,
            in: fixture.tabs[0]
        )
        fixture.project.terminal.captureProjectAgentOwnership(
            of: hidden,
            in: hiddenTab
        )

        fixture.project.paneManager.maximize(paneID: fixture.paneID)

        #expect(fixture.project.paneManager.maximizedPaneID == fixture.paneID)
        #expect(fixture.project.paneManager.terminalPaneIDs == [fixture.paneID])
        #expect(
            Set(fixture.project.terminal.projectOwnedActiveAgentSessions.map(\.id))
                == Set([visible.id, hidden.id])
        )
    }

    @Test("Duplicate binding deduplicates and conflicting identity fails closed")
    func duplicateAndConflictingBindings() throws {
        let fixture = try makeProjectFixture(name: "Conflicts", terminalCount: 3)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let evidence = AgentProcessEvidence(
            processIdentifier: 401,
            processGeneration: 7,
            startIdentifier: "coarse-401",
            observedStartedAt: Date(timeIntervalSince1970: 401),
            startIsAuthoritative: true
        )
        let first = AgentSession(agentType: .codex)
        let second = AgentSession(agentType: .claudeCode)
        _ = first.bindProcessEvidence(evidence)
        _ = second.bindProcessEvidence(evidence)

        fixture.tabs[0].agentSession = first
        fixture.tabs[1].agentSession = first
        #expect(fixture.project.terminal.projectOwnedActiveAgentSessions.isEmpty)
        fixture.project.terminal.captureProjectAgentOwnership(
            of: first,
            in: fixture.tabs[0]
        )
        fixture.project.terminal.captureProjectAgentOwnership(
            of: first,
            in: fixture.tabs[1]
        )
        #expect(fixture.project.terminal.projectOwnedActiveAgentSessions == [first])

        fixture.tabs[2].agentSession = second
        #expect(fixture.project.terminal.projectOwnedActiveAgentSessions.isEmpty)
        fixture.project.terminal.captureProjectAgentOwnership(
            of: second,
            in: fixture.tabs[2]
        )
        markDone(first)
        markDone(second)
        #expect(
            fixture.project.terminal.takeProjectOwnedCompletedAgentSessions()
                .isEmpty
        )
    }

    @Test("Terminated generation finalizes once in only its owning project")
    func terminatedGenerationFinalizesOnce() throws {
        let owner = try makeProjectFixture(name: "HistoryOwner", terminalCount: 2)
        let sibling = try makeProjectFixture(name: "HistorySibling", terminalCount: 1)
        defer {
            try? FileManager.default.removeItem(at: owner.root)
            try? FileManager.default.removeItem(at: sibling.root)
        }
        let session = exactSession(
            type: .codex,
            pid: 501,
            generation: 9,
            filesModified: [owner.root.appendingPathComponent("Owned.swift")]
        )

        // Duplicate representation inside the owning pane tree is one exact
        // session/process generation, never two History candidates.
        owner.tabs[0].agentSession = session
        owner.tabs[1].agentSession = session
        owner.project.terminal.captureProjectAgentOwnership(
            of: session,
            in: owner.tabs[0]
        )
        owner.project.terminal.captureProjectAgentOwnership(
            of: session,
            in: owner.tabs[1]
        )

        markDone(session)
        owner.tabs[0].agentSession = nil
        owner.tabs[1].agentSession = nil

        owner.project.finalizeAgentSessionsForHistory()
        owner.project.finalizeAgentSessionsForHistory()
        sibling.project.finalizeAgentSessionsForHistory()

        #expect(owner.project.agentHistory.entries.map(\.sessionID) == [session.id])
        #expect(owner.project.agentHistory.entries.first?.affectedFiles == ["Owned.swift"])
        #expect(sibling.project.agentHistory.entries.isEmpty)
    }

    @Test("History ownership ledger stays bounded")
    func historyOwnershipLedgerIsBounded() throws {
        let fixture = try makeProjectFixture(name: "Bounded", terminalCount: 1)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let tab = fixture.tabs[0]
        var sessions: [AgentSession] = []

        for index in 1...501 {
            let session = exactSession(
                type: .codex,
                pid: Int32(1_000 + index),
                generation: UInt64(index)
            )
            tab.agentSession = session
            fixture.project.terminal.captureProjectAgentOwnership(
                of: session,
                in: tab
            )
            sessions.append(session)
        }
        for session in sessions {
            markDone(session)
        }

        let completed = fixture.project.terminal
            .takeProjectOwnedCompletedAgentSessions()
        #expect(completed.count == 500)
        #expect(!completed.contains(where: { $0 === sessions[0] }))
        #expect(completed.contains(where: { $0 === sessions[500] }))
        #expect(
            fixture.project.terminal.takeProjectOwnedCompletedAgentSessions()
                .isEmpty
        )
    }

    private func makeProjectFixture(
        name: String,
        terminalCount: Int
    ) throws -> ProjectOwnershipFixture {
        let root = try makeTemporaryRoot(name: name)
        let project = ProjectManager()
        project.loadDirectory(url: root)
        let paneID = project.paneManager.createTerminalPaneAtBottom(
            workingDirectory: root
        )
        let state = try #require(project.paneManager.terminalState(for: paneID))
        while state.terminalTabs.count < terminalCount {
            state.addTab(workingDirectory: root)
        }
        return ProjectOwnershipFixture(
            project: project,
            root: root,
            paneID: paneID,
            tabs: state.terminalTabs
        )
    }

    private func makeTemporaryRoot(name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "pine-agent-project-ownership-\(name)-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        return root
    }

    private func exactSession(
        id: UUID = UUID(),
        type: AgentType,
        pid: Int32,
        generation: UInt64,
        filesModified: [URL] = []
    ) -> AgentSession {
        let session = AgentSession(
            id: id,
            agentType: type,
            state: .executing,
            filesModified: filesModified
        )
        _ = session.bindProcessEvidence(AgentProcessEvidence(
            processIdentifier: pid,
            processGeneration: generation,
            startIdentifier: "coarse-\(pid)-\(generation)",
            observedStartedAt: Date(
                timeIntervalSince1970: TimeInterval(pid) + Double(generation)
            ),
            startIsAuthoritative: true
        ))
        return session
    }

    private func recordNewChange(
        _ path: String,
        in fixture: ProjectOwnershipFixture
    ) {
        fixture.project.gitProvider.fileStatuses = ["seed.txt": .modified]
        fixture.project.correlateAgentActivity(rootURL: fixture.root)
        fixture.project.gitProvider.fileStatuses[path] = .modified
        fixture.project.correlateAgentActivity(rootURL: fixture.root)
    }

    private func candidateIDs(_ action: AgentAction) -> Set<UUID> {
        Set(action.attribution.candidates.map(\.sessionID))
    }

    private func markDone(_ session: AgentSession) {
        session.recordLifecycleState(
            .done,
            accuracy: .processTerminationOnly
        )
        session.applyLiveness(.terminated)
    }
}

@MainActor
private func setCoordinatorOwnership(
    _ process: DetectedProcess,
    on tab: TerminalTab
) {
    let identity = process.preciseStartedAt.flatMap {
        TerminalProcessStartIdentity(processID: process.pid, startedAt: $0)
    }
    tab.agentProcessIdentityResolverForTesting = { processID in
        processID == process.pid ? identity : nil
    }
    tab.foregroundProcessIDOverrideForTesting = process.processGroupID
    tab.foregroundStartOverrideForTesting = identity
}

nonisolated private func coordinatorProcess(
    pid: Int32,
    command: String,
    startedAt: TimeInterval
) -> DetectedProcess {
    DetectedProcess(
        pid: pid,
        parentProcessID: 1,
        processGroupID: pid,
        command: command,
        cpuTime: 0,
        startIdentifier: "generation-\(startedAt)",
        preciseStartedAt: Date(timeIntervalSince1970: startedAt)
    )
}

@MainActor
private struct ProjectOwnershipFixture {
    let project: ProjectManager
    let root: URL
    let paneID: PaneID
    let tabs: [TerminalTab]
}
