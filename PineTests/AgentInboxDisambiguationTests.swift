//
//  AgentInboxDisambiguationTests.swift
//  PineTests
//
//  Stable, privacy-safe Agent Inbox context (issue #1419).
//

import Foundation
import Testing
@testable import Pine

@MainActor
@Suite("Agent Inbox Disambiguation Tests", .serialized)
struct AgentInboxDisambiguationTests {
    @Test("manual Codex sessions in separate panes use stable terminal context")
    func manualSessionsAcrossPanes() throws {
        let fixture = try ProjectFixture()
        defer { fixture.cleanup() }
        let taskRegistry = AgentTaskRegistry()
        let projectRegistry = ProjectRegistry(agentTasks: taskRegistry)
        let manager = try #require(
            projectRegistry.projectManager(for: fixture.project)
        )
        let firstPane = manager.paneManager.createTerminalPaneAtBottom(
            workingDirectory: fixture.project
        )
        let secondPane = try #require(manager.paneManager.createTerminalPane(
            relativeTo: firstPane,
            axis: .horizontal,
            workingDirectory: fixture.project
        ))
        let firstTab = try #require(
            manager.paneManager.terminalState(for: firstPane)?.activeTab
        )
        let secondTab = try #require(
            manager.paneManager.terminalState(for: secondPane)?.activeTab
        )
        #expect(firstTab.stableLabel == secondTab.stableLabel)
        #expect(!firstTab.isProcessRunning)
        #expect(!secondTab.isProcessRunning)

        let dynamicTitle = "SECRET prompt customer-token"
        let secretCWD = URL(fileURLWithPath: "/private/secret/customer")
        let secretExecutable = "/private/bin/secret-agent"
        let secretArgument = "--token=do-not-render"
        firstTab.name = dynamicTitle
        firstTab.configure(
            workingDirectory: secretCWD,
            initialProcess: TerminalInitialProcess(
                executablePath: secretExecutable,
                arguments: [secretArgument]
            )
        )
        // `configure` only stores deferred launch values. Keeping the tab out
        // of a TerminalContainerView proves this privacy fixture never starts
        // the deliberately invalid executable or creates a PTY child.
        #expect(!firstTab.isProcessRunning)
        let first = makeSession(seed: 1)
        let second = makeSession(seed: 2)
        manager.terminal.bridgeAgentSession(
            first,
            replacing: nil,
            in: firstTab
        )
        manager.terminal.bridgeAgentSession(
            second,
            replacing: nil,
            in: secondTab
        )

        let initial = AgentInboxSnapshot(tasks: taskRegistry.tasks)
        let labels = initial.rows.map(\.terminalLabel)
        #expect(labels.count == 2)
        #expect(Set(labels).count == 2)
        #expect(labels.allSatisfy { $0.contains(firstTab.stableLabel) })
        let persisted = try JSONEncoder().encode(taskRegistry.tasks)
        let persistedText = try #require(String(data: persisted, encoding: .utf8))
        #expect(persistedText.contains(firstTab.stableLabel))
        #expect(!persistedText.contains(dynamicTitle))
        #expect(!persistedText.contains(secretCWD.path))
        #expect(!persistedText.contains(secretExecutable))
        #expect(!persistedText.contains(secretArgument))

        let initialLabels = labelsByTask(initial)
        projectRegistry.closeProjectWindow(fixture.project)
        let background = AgentInboxSnapshot(tasks: taskRegistry.tasks)
        #expect(labelsByTask(background) == initialLabels)
        let reopened = try #require(
            projectRegistry.projectManager(for: fixture.project)
        )
        #expect(reopened === manager)
        #expect(labelsByTask(AgentInboxSnapshot(
            tasks: taskRegistry.tasks
        )) == initialLabels)
    }

    @Test("different stable labels need no opaque suffix")
    func differentStableLabelsRemainVerbatim() {
        let first = makeTask(seed: 10, stableLabel: "Terminal 1")
        let second = makeTask(seed: 11, stableLabel: "Terminal 2")
        let labels = AgentInboxSnapshot(tasks: [second, first])
            .rows.map(\.terminalLabel)

        #expect(Set(labels) == ["Terminal 1", "Terminal 2"])
    }

    @Test("repeated task rows for one terminal do not create a collision")
    func repeatedTerminalIdentityDoesNotAddSuffix() {
        let terminalID = uuid("11111100-0000-0000-0000-000000000001")
        let first = makeTask(
            seed: 20,
            terminalID: terminalID,
            stableLabel: "Terminal 1"
        )
        let second = makeTask(
            seed: 21,
            terminalID: terminalID,
            stableLabel: "Terminal 1"
        )
        let labels = AgentInboxSnapshot(tasks: [first, second])
            .rows.map(\.terminalLabel)

        #expect(labels == ["Terminal 1", "Terminal 1"])
    }

    @Test("legacy rows use collision-safe scoped terminal fallbacks")
    func legacyFallbackDisambiguatesCollidingPrefixes() {
        let first = makeTask(
            seed: 30,
            terminalID: uuid("ABCDEF10-0000-0000-0000-000000000001"),
            stableLabel: nil
        )
        let second = makeTask(
            seed: 31,
            terminalID: uuid("ABCDEF20-0000-0000-0000-000000000002"),
            stableLabel: nil
        )
        let labels = AgentInboxSnapshot(tasks: [first, second])
            .rows.map(\.terminalLabel)

        #expect(Set(labels).count == 2)
        #expect(labels.allSatisfy {
            $0.hasPrefix(Strings.terminalLabelText() + " #ABCDEF")
        })
    }

    @Test("unrelated project cannot expand another project's terminal tokens")
    func unrelatedProjectDoesNotChangeTokens() {
        let first = makeTask(
            seed: 40,
            project: "/projects/one/app",
            terminalID: uuid("ABCDEF10-0000-0000-0000-000000000001"),
            stableLabel: "Terminal 1"
        )
        let second = makeTask(
            seed: 41,
            project: "/projects/one/app",
            terminalID: uuid("ABCDEF20-0000-0000-0000-000000000002"),
            stableLabel: "Terminal 1"
        )
        let unrelated = makeTask(
            seed: 42,
            project: "/projects/two/app",
            terminalID: uuid("ABCDEF11-0000-0000-0000-000000000003"),
            stableLabel: "Terminal 1"
        )
        let before = labelsByTask(AgentInboxSnapshot(tasks: [first, second]))
        let after = labelsByTask(AgentInboxSnapshot(
            tasks: [unrelated, second, first]
        ))

        #expect(after[first.id] == before[first.id])
        #expect(after[second.id] == before[second.id])
    }

    @Test("project labels use unique suffixes over distinct canonical paths")
    func shortestProjectSuffixesDeduplicatePaths() {
        let customerA = makeTask(seed: 50, project: "/customer-a/app")
        let customerARepeated = makeTask(seed: 51, project: "/customer-a/app")
        let customerB = makeTask(seed: 52, project: "/customer-b/app")
        let suffixOwner = makeTask(seed: 53, project: "/workspace/app")
        let suffixPath = makeTask(seed: 54, project: "/app")
        let snapshot = AgentInboxSnapshot(tasks: [
            suffixPath, customerARepeated, customerB, suffixOwner, customerA,
        ])
        let names = Dictionary(grouping: snapshot.rows, by: \.projectPath)
            .mapValues { Set($0.map(\.projectName)) }

        #expect(names["/customer-a/app"] == ["customer-a/app"])
        #expect(names["/customer-b/app"] == ["customer-b/app"])
        #expect(names["/workspace/app"] == ["workspace/app"])
        #expect(names["/app"] == ["app"])
    }

    @Test("worktree suffixes have an independent presentation namespace")
    func worktreeNamespaceIsIndependent() {
        let first = makeTask(
            seed: 60,
            project: "/repos/customer/app",
            worktree: "/trees/alpha/release"
        )
        let second = makeTask(
            seed: 61,
            project: "/repos/customer/app",
            worktree: "/trees/beta/release"
        )
        let projectNamedRelease = makeTask(
            seed: 62,
            project: "/repos/reference/release"
        )
        let snapshot = AgentInboxSnapshot(tasks: [
            projectNamedRelease, second, first,
        ])
        let firstRow = snapshot.rows.first { $0.id == first.id }
        let secondRow = snapshot.rows.first { $0.id == second.id }
        let releaseRow = snapshot.rows.first { $0.id == projectNamedRelease.id }

        #expect(firstRow?.projectName == "app")
        #expect(secondRow?.projectName == "app")
        #expect(firstRow?.worktreeName == "alpha/release")
        #expect(secondRow?.worktreeName == "beta/release")
        #expect(releaseRow?.projectName == "release")
        #expect(releaseRow?.worktreeName == nil)
    }

    @Test("labels and ordering survive poll changes and input permutation")
    func pollAndInputOrderStability() {
        var newer = makeTask(
            seed: 70,
            project: "/projects/newer/app",
            stableLabel: "Terminal 1"
        )
        var older = makeTask(
            seed: 69,
            project: "/projects/older/app",
            stableLabel: "Terminal 1"
        )
        let initial = AgentInboxSnapshot(tasks: [older, newer])
        let initialIDs = initial.rows.map(\.id)
        let initialLabels = labelsByTask(initial)

        newer.runs[0].lastObservedAt = Date(timeIntervalSince1970: 71)
        older.runs[0].lastObservedAt = Date(timeIntervalSince1970: 99)
        newer.route.availability = .background
        older.route.availability = .background
        let polled = AgentInboxSnapshot(tasks: [newer, older])

        #expect(polled.rows.map(\.id) == initialIDs)
        #expect(labelsByTask(polled) == initialLabels)
    }

    @Test("new and legacy task JSON decode presentation additively")
    func presentationContextCodableCompatibility() throws {
        let task = makeTask(seed: 80, stableLabel: "Terminal 7")
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let currentData = try encoder.encode(task)
        let current = try decoder.decode(AgentTask.self, from: currentData)
        #expect(current.presentationContext?.terminalLabel == "Terminal 7")
        #expect(current.route == task.route)

        var legacyJSON = try #require(
            JSONSerialization.jsonObject(with: currentData) as? [String: Any]
        )
        legacyJSON.removeValue(forKey: "presentationContext")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyJSON)
        let legacy = try decoder.decode(AgentTask.self, from: legacyData)
        #expect(legacy.presentationContext == nil)
        #expect(legacy.route == task.route)
        let fallback = try #require(
            AgentInboxSnapshot(tasks: [legacy]).rows.first?.terminalLabel
        )
        #expect(fallback.hasPrefix(Strings.terminalLabelText() + " #"))
    }

    @Test("metadata rejects unsafe persisted presentation labels")
    func persistedPresentationValidation() async throws {
        let fixture = try ProjectFixture()
        defer { fixture.cleanup() }
        let projectURL = ProjectRegistry.canonicalProjectURL(fixture.project)
        let identity = AgentTaskProjectIdentity(
            canonicalProjectPath: projectURL.path,
            canonicalWorktreePath: projectURL.path
        )
        let store = AgentTaskMetadataStore(storageRoot: fixture.storage)
        let task = makeTask(
            seed: 90,
            project: identity.canonicalProjectPath,
            stableLabel: "Terminal 1"
        )
        #expect(await store.save(
            tasks: [task],
            project: identity
        ) == .saved(taskCount: 1))
        let file = AgentTaskMetadataStore.metadataURL(
            for: identity,
            storageRoot: fixture.storage
        )
        let original = try Data(contentsOf: file)

        for invalid in [
            "bad\0label",
            "bad\nlabel",
            "bad\rlabel",
            String(repeating: "x", count: 257),
        ] {
            var envelope = try #require(
                JSONSerialization.jsonObject(with: original) as? [String: Any]
            )
            var tasks = try #require(envelope["tasks"] as? [[String: Any]])
            tasks[0]["presentationContext"] = ["terminalLabel": invalid]
            envelope["tasks"] = tasks
            let tampered = try JSONSerialization.data(withJSONObject: envelope)
            try tampered.write(to: file)

            #expect(await store.load(project: identity).status
                == .rejected(.invalidMetadata))
        }
    }

    @Test("presentation-only backfill preserves lifecycle chronology")
    func presentationOnlyBackfill() throws {
        let policy = AgentLifecycleAccuracyPolicy { _ in
            .verifiedLifecycleTransitions
        }
        let registry = AgentTaskRegistry(accuracyPolicy: policy)
        let identity = AgentTaskProjectIdentity(
            canonicalProjectPath: "/projects/backfill/app",
            canonicalWorktreePath: "/projects/backfill/app"
        )
        let route = AgentTaskRoute(
            paneID: uuid("10000000-0000-0000-0000-000000000001"),
            tabID: uuid("10000000-0000-0000-0000-000000000002"),
            terminalID: uuid("10000000-0000-0000-0000-000000000002")
        )
        let observedAt = Date(timeIntervalSince1970: 100)
        let legacyContext = AgentTaskBridgeContext(
            project: identity,
            route: route,
            origin: .discoveredInTerminal,
            observedAt: observedAt
        )
        let session = makeSession(
            seed: 100,
            state: .waitingInput,
            lifecycleAccuracy: .verifiedLifecycleTransitions
        )
        registry.bridge(session, replacing: nil, context: legacyContext)
        let before = try #require(registry.task(forSessionID: session.id))
        #expect(before.presentationContext == nil)
        #expect(before.attention == .waitingInput)
        #expect(before.isUnread)

        let currentContext = AgentTaskBridgeContext(
            project: identity,
            route: route,
            presentationContext: AgentTaskPresentationContext(
                terminalStableLabel: "Terminal 1"
            ),
            origin: .discoveredInTerminal,
            observedAt: observedAt
        )
        registry.bridge(
            session,
            replacing: session,
            context: currentContext
        )
        let after = try #require(registry.task(forSessionID: session.id))

        #expect(after.presentationContext?.terminalLabel == "Terminal 1")
        #expect(after.route == before.route)
        #expect(after.lifecycle == before.lifecycle)
        #expect(after.runs == before.runs)
        #expect(after.createdAt == before.createdAt)
        #expect(after.updatedAt == before.updatedAt)
        #expect(after.lastActivityAt == before.lastActivityAt)
        #expect(after.attention == before.attention)
        #expect(after.isUnread == before.isUnread)
    }

    @Test("VoiceOver uses the exact projected disambiguation fields")
    func accessibilityUsesProjectedContext() throws {
        let first = makeTask(
            seed: 110,
            project: "/owners/a/app",
            worktree: "/trees/alpha/release",
            stableLabel: "Terminal 1"
        )
        let second = makeTask(
            seed: 111,
            project: "/owners/b/app",
            worktree: "/trees/beta/release",
            stableLabel: "Terminal 2"
        )
        let row = try #require(AgentInboxSnapshot(
            tasks: [second, first]
        ).rows.first { $0.id == first.id })

        #expect(row.projectName == "a/app")
        #expect(row.worktreeName == "alpha/release")
        #expect(AgentInboxView.accessibilityLabel(
            for: row,
            locale: Locale(identifier: "en")
        ) == "Codex, Executing, Terminal 1, a/app, alpha/release")
    }

    @Test("presentation metadata cannot bypass lifecycle accuracy policy")
    func presentationDoesNotBypassAttentionPolicy() throws {
        let task = makeTask(
            seed: 120,
            stableLabel: "Terminal 1",
            state: .waitingInput,
            attention: .waitingInput,
            unread: true,
            lifecycleAccuracy: .verifiedLifecycleTransitions
        )
        let snapshot = AgentInboxSnapshot(tasks: [task])

        #expect(snapshot.sections.map(\.id) == [.working])
        #expect(snapshot.rows.first?.state == .idle)
        #expect(snapshot.rows.first?.terminalLabel == "Terminal 1")
    }

    private func makeTask(
        seed: Int,
        project: String = "/projects/shared/app",
        worktree: String? = nil,
        terminalID: UUID? = nil,
        stableLabel: String? = "Terminal 1",
        state: AgentRunState = .executing,
        attention: AgentTaskAttention = .none,
        unread: Bool = false,
        lifecycleAccuracy: FirstPartyAgentNotificationAccuracy =
            .processTerminationOnly
    ) -> AgentTask {
        let identity = AgentTaskProjectIdentity(
            canonicalProjectPath: project,
            canonicalWorktreePath: worktree ?? project
        )
        let terminalID = terminalID ?? deterministicUUID(seed + 10_000)
        let startedAt = Date(timeIntervalSince1970: TimeInterval(seed))
        let context = AgentTaskBridgeContext(
            project: identity,
            route: AgentTaskRoute(
                paneID: deterministicUUID(seed + 20_000),
                tabID: terminalID,
                terminalID: terminalID
            ),
            presentationContext: stableLabel.flatMap {
                AgentTaskPresentationContext(terminalStableLabel: $0)
            },
            origin: .discoveredInTerminal,
            observedAt: startedAt
        )
        var task = AgentTask(
            descriptor: AgentDescriptor(agentType: .codex),
            context: context,
            createdAt: startedAt
        )
        task.runs = [AgentTaskRun(AgentTaskRunInput(
            id: deterministicUUID(seed + 30_000),
            terminalID: terminalID,
            process: AgentProcessEvidence(
                processIdentifier: Int32(seed + 1_000),
                processGeneration: UInt64(seed + 1),
                startIdentifier: "verified-\(seed)",
                observedStartedAt: startedAt,
                startIsAuthoritative: true
            ),
            status: AgentTaskRunStatus(
                state: state,
                liveness: .live,
                observedAt: startedAt
            ),
            lifecycleAccuracy: lifecycleAccuracy
        ))]
        task.lifecycle = .active
        task.attention = attention
        task.isUnread = unread
        return task
    }

    private func makeSession(
        seed: Int,
        state: AgentState = .executing,
        lifecycleAccuracy: FirstPartyAgentNotificationAccuracy =
            .processTerminationOnly
    ) -> AgentSession {
        let startedAt = Date(timeIntervalSince1970: TimeInterval(seed))
        let session = AgentSession(
            agentType: .codex,
            state: state,
            lifecycleAccuracy: lifecycleAccuracy,
            startedAt: startedAt
        )
        _ = session.bindProcessEvidence(AgentProcessEvidence(
            processIdentifier: Int32(seed + 2_000),
            processGeneration: UInt64(seed),
            startIdentifier: "verified-session-\(seed)",
            observedStartedAt: startedAt,
            startIsAuthoritative: true
        ))
        return session
    }

    private func labelsByTask(
        _ snapshot: AgentInboxSnapshot
    ) -> [UUID: String] {
        Dictionary(uniqueKeysWithValues: snapshot.rows.map {
            ($0.id, $0.terminalLabel)
        })
    }

    private func deterministicUUID(_ seed: Int) -> UUID {
        let suffix = String(format: "%012llX", UInt64(seed))
        return uuid("00000000-0000-0000-0000-\(suffix)")
    }

    private func uuid(_ value: String) -> UUID {
        guard let identifier = UUID(uuidString: value) else {
            preconditionFailure("Malformed deterministic UUID fixture: \(value)")
        }
        return identifier
    }
}

private final class AgentInboxDisambiguationProjectFixture {
    let root: URL
    let project: URL
    let storage: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent(
                "PineInboxDisambiguation-\(UUID().uuidString)",
                isDirectory: true
            )
        project = root.appendingPathComponent("project", isDirectory: true)
        storage = root.appendingPathComponent("metadata", isDirectory: true)
        try FileManager.default.createDirectory(
            at: project,
            withIntermediateDirectories: true
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

private typealias ProjectFixture = AgentInboxDisambiguationProjectFixture
