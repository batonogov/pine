//
//  AgentInboxToolbarBadgeTests.swift
//  PineTests
//
//  Unit coverage for the project-window Agent Inbox toolbar badge (#1337).
//  Exercises `ProjectRegistry.agentInboxAttentionCount(for:)`, which feeds
//  the badge, against durable task fixtures scoped to real temp projects.
//

import Foundation
import Testing

@testable import Pine

@Suite("Agent Inbox toolbar badge")
@MainActor
struct AgentInboxToolbarBadgeTests {

    private func makeTempDirectory() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PineBadge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDir,
            withIntermediateDirectories: true
        )
        return tempDir
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Canonical identity a real `projectManager(for:)` call would register,
    /// so fixture tasks match the registry's internal project map.
    private func identity(
        for url: URL,
        in registry: ProjectRegistry
    ) -> AgentTaskProjectIdentity {
        let canonical = registry.canonicalProjectURL(url)
        return AgentTaskProjectIdentity(
            canonicalProjectPath: canonical.path,
            canonicalWorktreePath: canonical.path
        )
    }

    private func makeTask(
        seed: Int,
        identity: AgentTaskProjectIdentity,
        state: AgentRunState,
        liveness: AgentRunLiveness,
        attention: AgentTaskAttention = .none,
        unread: Bool = false,
        observedAt: Date = Date(timeIntervalSince1970: 10_000)
    ) -> AgentTask {
        let routeContext = AgentTaskBridgeContext(
            project: identity,
            route: AgentTaskRoute(
                paneID: uuid(seed),
                tabID: uuid(seed + 1_000),
                terminalID: uuid(seed + 1_000)
            ),
            origin: .discoveredInTerminal,
            observedAt: observedAt
        )
        var task = AgentTask(
            descriptor: AgentDescriptor(agentType: .codex),
            context: routeContext,
            title: "Task \(seed)",
            createdAt: observedAt.addingTimeInterval(-5)
        )
        task.runs = [AgentTaskRun(AgentTaskRunInput(
            id: uuid(seed + 3_000),
            terminalID: routeContext.route.terminalID,
            process: AgentProcessEvidence(
                processIdentifier: Int32(seed),
                processGeneration: UInt64(seed),
                startIdentifier: "verified-\(seed)",
                observedStartedAt: observedAt.addingTimeInterval(-5),
                startIsAuthoritative: true
            ),
            status: AgentTaskRunStatus(
                state: state,
                liveness: liveness,
                observedAt: observedAt
            ),
            lifecycleAccuracy: .verifiedLifecycleTransitions
        ))]
        task.attention = attention
        task.isUnread = unread
        task.lastActivityAt = observedAt
        task.updatedAt = observedAt
        task.route.availability = liveness == .live ? .available : .missing
        task.lifecycle = liveness == .live ? .active : .paused
        return task
    }

    private func uuid(_ seed: Int) -> UUID {
        let suffix = String(format: "%012llX", UInt64(seed))
        return UUID(uuidString: "00000000-0000-0000-0000-\(suffix)") ?? UUID()
    }

    private func makeVerifiedRegistry() -> ProjectRegistry {
        let policy = AgentLifecycleAccuracyPolicy { _ in
            .verifiedLifecycleTransitions
        }
        return ProjectRegistry(
            agentTasks: AgentTaskRegistry(accuracyPolicy: policy)
        )
    }

    // MARK: - Tests

    @Test("returns zero for a project the registry has never opened")
    func returnsZeroForUnknownProject() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        let registry = makeVerifiedRegistry()
        // No projectManager(for:) call — project is unknown to the registry.
        #expect(registry.agentInboxAttentionCount(for: tempDir) == 0)
    }

    @Test("returns zero for an open project with no tasks")
    func returnsZeroWhenNoTasks() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        let registry = makeVerifiedRegistry()
        _ = registry.projectManager(for: tempDir)

        #expect(registry.agentInboxAttentionCount(for: tempDir) == 0)
    }

    @Test("counts only needs-attention tasks for the focused project")
    func countsNeedsAttentionTasks() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        let registry = makeVerifiedRegistry()
        _ = registry.projectManager(for: tempDir)
        let identity = self.identity(for: tempDir, in: registry)

        registry.agentTasks.setTasksForTesting([
            makeTask(
                seed: 1, identity: identity,
                state: .waitingInput, liveness: .live,
                attention: .waitingInput, unread: true
            ),
            makeTask(
                seed: 2, identity: identity,
                state: .waitingInput, liveness: .live,
                attention: .waitingInput, unread: true
            ),
            // A working task in the same project must NOT count.
            makeTask(
                seed: 3, identity: identity,
                state: .executing, liveness: .live
            ),
        ])

        #expect(registry.agentInboxAttentionCount(for: tempDir) == 2)
    }

    @Test("catalog ceiling suppresses a forged toolbar attention badge")
    func catalogSuppressesForgedAttentionBadge() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        let registry = ProjectRegistry()
        _ = registry.projectManager(for: tempDir)
        let identity = self.identity(for: tempDir, in: registry)
        registry.agentTasks.setTasksForTesting([
            makeTask(
                seed: 99,
                identity: identity,
                state: .waitingInput,
                liveness: .live,
                attention: .waitingInput,
                unread: true
            ),
        ])

        #expect(registry.agentInboxAttentionCount(for: tempDir) == 0)
    }

    @Test("scopes the count per project window")
    func scopesByProject() throws {
        let projectA = try makeTempDirectory()
        let projectB = try makeTempDirectory()
        defer { cleanup(projectA); cleanup(projectB) }

        let registry = makeVerifiedRegistry()
        _ = registry.projectManager(for: projectA)
        _ = registry.projectManager(for: projectB)
        let identityA = self.identity(for: projectA, in: registry)
        let identityB = self.identity(for: projectB, in: registry)

        registry.agentTasks.setTasksForTesting([
            makeTask(
                seed: 1, identity: identityA,
                state: .waitingInput, liveness: .live,
                attention: .waitingInput, unread: true
            ),
            makeTask(
                seed: 2, identity: identityB,
                state: .waitingInput, liveness: .live,
                attention: .waitingInput, unread: true
            ),
            makeTask(
                seed: 3, identity: identityB,
                state: .waitingInput, liveness: .live,
                attention: .waitingInput, unread: true
            ),
        ])

        // Sibling windows never show each other's counts.
        #expect(registry.agentInboxAttentionCount(for: projectA) == 1)
        #expect(registry.agentInboxAttentionCount(for: projectB) == 2)
    }

    @Test("ignores completed, failed, working, and history sections")
    func ignoresNonNeedsAttentionSections() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        let registry = makeVerifiedRegistry()
        _ = registry.projectManager(for: tempDir)
        let identity = self.identity(for: tempDir, in: registry)

        var failed = makeTask(
            seed: 1, identity: identity,
            state: .done, liveness: .terminated,
            attention: .failed, unread: true
        )
        failed.lifecycle = .completed

        var completed = makeTask(
            seed: 2, identity: identity,
            state: .done, liveness: .terminated,
            attention: .completed, unread: true
        )
        completed.lifecycle = .completed

        let working = makeTask(
            seed: 3, identity: identity,
            state: .executing, liveness: .live
        )

        let history = makeTask(
            seed: 4, identity: identity,
            state: .done, liveness: .terminated
        )

        registry.agentTasks.setTasksForTesting([
            failed, completed, working, history,
        ])

        #expect(registry.agentInboxAttentionCount(for: tempDir) == 0)
    }

    @Test("reviewed tasks leave the needs-attention count")
    func reviewedTasksLeaveTheCount() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        let registry = makeVerifiedRegistry()
        _ = registry.projectManager(for: tempDir)
        let identity = self.identity(for: tempDir, in: registry)

        let waiting = makeTask(
            seed: 1, identity: identity,
            state: .waitingInput, liveness: .live,
            attention: .waitingInput, unread: true
        )

        registry.agentTasks.setTasksForTesting([waiting])
        #expect(registry.agentInboxAttentionCount(for: tempDir) == 1)

        // Reviewing the task clears its attention state — it drops out of
        // the needs-attention section while still being active.
        var reviewed = waiting
        reviewed.attention = .none
        reviewed.isUnread = false
        registry.agentTasks.setTasksForTesting([reviewed])
        #expect(registry.agentInboxAttentionCount(for: tempDir) == 0)
    }

    @Test("dismissed tasks are excluded from the snapshot entirely")
    func dismissedTasksExcluded() throws {
        let tempDir = try makeTempDirectory()
        defer { cleanup(tempDir) }

        let registry = makeVerifiedRegistry()
        _ = registry.projectManager(for: tempDir)
        let identity = self.identity(for: tempDir, in: registry)

        var dismissed = makeTask(
            seed: 1, identity: identity,
            state: .waitingInput, liveness: .live,
            attention: .waitingInput, unread: true
        )
        // `AgentInboxSnapshot` drops `.dismissed` tasks before classification,
        // so a dismissed waiting-input task must not count.
        dismissed.lifecycle = .dismissed

        registry.agentTasks.setTasksForTesting([dismissed])
        #expect(registry.agentInboxAttentionCount(for: tempDir) == 0)
    }
}
