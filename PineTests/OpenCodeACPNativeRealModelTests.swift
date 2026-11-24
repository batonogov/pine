import Foundation
import Testing
@testable import Pine

/// Opt-in real-model journey (#1811): the pinned production dispatch chain
/// (ProjectRegistry → reserved worktree → ownership → composition → owned
/// `opencode acp` process) against the installed real CLI and an
/// authenticated real model. No GUI, no auth mutation, synthetic working
/// directories only. The deterministic contract suites remain the CI gate;
/// this proves the acceptance loop — task → observed activity → real
/// question/permission → unverified result → same-session feedback — and the
/// separate new-owner exact-session restore with context intact.
@Suite("OpenCode real-model journey", .serialized)
struct OpenCodeACPNativeRealModelTests {
    nonisolated private static let optedIn =
        ProcessInfo.processInfo.environment["PINE_RUN_OPENCODE_ACP_SMOKE"] == "1"
        || FileManager.default.fileExists(atPath: FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-opencode-acp-smoke").path)

    nonisolated private static let binary: URL = URL(fileURLWithPath:
        ProcessInfo.processInfo.environment["PINE_OPENCODE_BINARY"] ?? "/opt/homebrew/bin/opencode")

    /// The model is read from the environment; the default is the
    /// authenticated model present on the milestone machine (native OpenCode
    /// credential handling is inherited, never copied).
    nonisolated private static let model: String =
        ProcessInfo.processInfo.environment["PINE_OPENCODE_MODEL"] ?? "oso/local-qwen38-27b-large"

    /// Full first acceptance loop on one task: observed activity, a real
    /// form question answered exactly once, a real one-shot write permission,
    /// a real unverified result, and same-session continuation that proves
    /// the model retained the conversation context.
    @Test(.enabled(if: Self.optedIn, "Forward PINE_RUN_OPENCODE_ACP_SMOKE=1 (PINE_OPENCODE_MODEL selects the model)"))
    func realModelQuestionPermissionResultAndSameSessionContinuation() async throws {
        let fixture = try await runOnBackground { try OpenCodeRealModelFixture(model: Self.model) }
        defer { fixture.remove() }
        let tasks = AgentTaskRegistry(persistence: OpenCodeRealModelTaskStore(file: fixture.storeFile))
        let projects = ProjectRegistry(agentTasks: tasks)
        let codeword = "PINE1811-\(UUID().uuidString.prefix(8).uppercased())"
        let taskID = try await projects.startOpenCodeTask(
            instruction: "Remember the codeword \(codeword). Then ask me a form question with "
                + "exactly one field named 'choice' with options 'keep' and 'drop', asking "
                + "whether I want to keep the codeword. After I answer, create the file "
                + "note.txt containing exactly the text ok. Then reply with exactly: REMEMBERED",
            project: fixture.identity,
            executable: Self.binary,
            managedRoot: fixture.managedRoot
        )
        let runtime = try #require(projects.openCodeRuntime(for: taskID))
        defer { Task { await runtime.stop(deadline: .now.advanced(by: .seconds(10))) } }

        // Observed activity: the submitted turn is seen working before any
        // ask can settle the stage.
        let sawActivity = try await Self.observe(runtime) {
            (runtime.snapshot?.questions.count == 1)
                || runtime.snapshot?.state == .unverified
        }
        #expect(sawActivity.contains(.working) || sawActivity.contains(.submitted))

        // A real question and a real one-shot write permission arrive in
        // either order; each is answered/allowed exactly once on the exact
        // context. The stage ends when both are served or the turn settles.
        var sawQuestion = false
        var sawPermission = false
        let stageDeadline = ContinuousClock.now.advanced(by: .seconds(600))
        while (sawQuestion && sawPermission) == false, ContinuousClock.now < stageDeadline,
              runtime.snapshot?.state != .unverified {
            if let question = runtime.snapshot?.questions.first {
                if question.permission {
                    let allow = try #require(question.allowOnceOptionID)
                    _ = try await runtime.answerPermission(question, optionID: allow, decision: .allowOnce)
                    sawPermission = true
                } else {
                    let answers = try Self.firstChoiceAnswers(for: question)
                    _ = try await runtime.answerQuestion(question, answers: answers)
                    sawQuestion = true
                }
            } else if (sawQuestion && sawPermission) == false {
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        #expect(sawQuestion)
        #expect(sawPermission)
        #expect(sawActivity.contains(.waiting))

        // Real unverified result; the provider turn never settles Ready.
        try #require(await Self.observe(runtime) {
            runtime.snapshot?.state == .unverified
        })
        let settled = try #require(runtime.snapshot)
        #expect(settled.result.trimmingCharacters(in: .whitespacesAndNewlines).contains("REMEMBERED"))
        #expect(!settled.ready && !settled.settlementKnown)
        #expect(tasks.task(for: taskID)?.runs.last?.outcome == nil)
        #expect(fixture.worktreeFile(taskID: taskID, name: "note.txt") == "ok")

        // Same-session continuation: the exact session recalls the codeword
        // without any file containing it (note.txt holds only "ok").
        let exactSession = try #require(settled.nativeSession)
        _ = try await runtime.submit(
            "What was the codeword I gave you in this conversation? Reply with only the codeword."
        )
        try #require(await Self.observe(runtime) {
            (runtime.snapshot?.state == .unverified)
                && runtime.snapshot?.result.trimmingCharacters(in: .whitespacesAndNewlines)
                    .contains(codeword) == true
        })
        #expect(runtime.snapshot?.nativeSession?.rawValue == exactSession.rawValue)
        #expect(runtime.snapshot?.ready == false)
        await runtime.stop(deadline: .now.advanced(by: .seconds(10)))
        // The owned process is gone; the run is honestly stale.
        #expect(tasks.task(for: taskID)?.runs.last?.liveness == .stale
            || tasks.task(for: taskID)?.runs.last?.liveness == .terminated)
    }

    /// New-owner exact-session restore, verified separately from
    /// same-process continuity: owner A binds and uses the exact session,
    /// exits cleanly; a NEW registry/process rehydrated from the same
    /// durable store restores through the production action. The new owner
    /// loads the exact ID (session/load, never session/new) and the model
    /// recalls the codeword from session context — no file holds it.
    @Test(.enabled(if: Self.optedIn, "Forward PINE_RUN_OPENCODE_ACP_SMOKE=1"))
    func newOwnerRestoresExactSessionWithContextIntact() async throws {
        let fixture = try await runOnBackground { try OpenCodeRealModelFixture(model: Self.model) }
        defer { fixture.remove() }
        let codeword = "PINE1811-\(UUID().uuidString.prefix(8).uppercased())"

        // OWNER A: original process.
        let storeFile = fixture.storeFile
        let tasksA = AgentTaskRegistry(persistence: OpenCodeRealModelTaskStore(file: storeFile))
        let projectsA = ProjectRegistry(agentTasks: tasksA)
        let taskID = try await projectsA.startOpenCodeTask(
            instruction: "Remember the codeword \(codeword). Reply with exactly: OK",
            project: fixture.identity,
            executable: Self.binary,
            managedRoot: fixture.managedRoot
        )
        let runtimeA = try #require(projectsA.openCodeRuntime(for: taskID))
        try #require(await Self.observe(runtimeA) { runtimeA.snapshot?.state == .unverified })
        let exactSession = try #require(runtimeA.snapshot?.nativeSession)
        await runtimeA.stop(deadline: .now.advanced(by: .seconds(10)))
        let ownerARun = try #require(tasksA.task(for: taskID)?.runs.last)
        #expect(ownerARun.liveness == .stale || ownerARun.liveness == .terminated)
        #expect(ownerARun.vendorIdentity?.opaqueIdentifier == exactSession.rawValue)

        // OWNER B: a NEW process. A fresh registry rehydrated from the same
        // durable store, a fresh composition, the explicit restore action.
        let tasksB = AgentTaskRegistry(persistence: OpenCodeRealModelTaskStore(file: storeFile))
        #expect(await tasksB.prepareDurableWork(in: fixture.identity))
        let restoredTask = try #require(tasksB.task(for: taskID))
        #expect(restoredTask.runs.count == 1)
        #expect(restoredTask.runs.last?.liveness != .live)
        let projectsB = ProjectRegistry(agentTasks: tasksB)
        let runtimeB = try await projectsB.restoreOpenCodeTaskSession(taskID: taskID)
        defer { Task { await runtimeB.stop(deadline: .now.advanced(by: .seconds(10))) } }
        try await runtimeB.start()
        let loaded = try #require(runtimeB.snapshot)
        #expect(loaded.state == .idle)
        #expect(loaded.nativeSession?.rawValue == exactSession.rawValue)
        #expect(loaded.result.isEmpty && loaded.questions.isEmpty)

        // Context intact: the new owner's model recalls the codeword from
        // the loaded session; no file in the worktree contains it.
        _ = try await runtimeB.submit(
            "What was the codeword I gave you in this conversation? Reply with only the codeword."
        )
        try #require(await Self.observe(runtimeB) {
            (runtimeB.snapshot?.state == .unverified)
                && runtimeB.snapshot?.result.trimmingCharacters(in: .whitespacesAndNewlines)
                    .contains(codeword) == true
        })
        #expect(runtimeB.snapshot?.nativeSession?.rawValue == exactSession.rawValue)
        #expect(runtimeB.snapshot?.ready == false)
        #expect(tasksB.task(for: taskID)?.runs.count == 1)
        // The restore admitted a new incarnation of the same logical attempt.
        let restoredGeneration = try #require(
            tasksB.task(for: taskID)?.runs.last?.process.processGeneration
        )
        #expect(restoredGeneration > ownerARun.process.processGeneration)
        await runtimeB.stop(deadline: .now.advanced(by: .seconds(10)))
        #expect(tasksB.task(for: taskID)?.runs.last?.liveness == .stale
            || tasksB.task(for: taskID)?.runs.last?.liveness == .terminated)
    }

    /// Negative, real CLI: a persisted exact ID the native store no longer
    /// knows is refused by the provider (-32602) through the full production
    /// chain — no fallback to a new or latest session, and the journal stays
    /// a valid restore-eligible record of the same attempt.
    @Test(.enabled(if: Self.optedIn, "Forward PINE_RUN_OPENCODE_ACP_SMOKE=1"))
    func restoreRefusesMissingNativeSessionWithoutFallback() async throws {
        let fixture = try await runOnBackground { try OpenCodeRealModelFixture(model: Self.model) }
        defer { fixture.remove() }
        let storeFile = fixture.storeFile
        let tasksA = AgentTaskRegistry(persistence: OpenCodeRealModelTaskStore(file: storeFile))
        let projectsA = ProjectRegistry(agentTasks: tasksA)
        let taskID = try await projectsA.startOpenCodeTask(
            instruction: "Reply with exactly: OK",
            project: fixture.identity,
            executable: Self.binary,
            managedRoot: fixture.managedRoot
        )
        let runtimeA = try #require(projectsA.openCodeRuntime(for: taskID))
        try #require(await Self.observe(runtimeA) { runtimeA.snapshot?.state == .unverified })
        await runtimeA.stop(deadline: .now.advanced(by: .seconds(10)))

        // The native store lost the session (simulated): the durable
        // identity no longer resolves. Admission still succeeds on the
        // recorded metadata; the provider refusal must fail the start.
        try Self.rewriteStoreIdentity(storeFile: storeFile, taskID: taskID,
                                      toOpaqueIdentifier: "ses_definitely_missing_1811")
        let tasksB = AgentTaskRegistry(persistence: OpenCodeRealModelTaskStore(file: storeFile))
        #expect(await tasksB.prepareDurableWork(in: fixture.identity))
        let projectsB = ProjectRegistry(agentTasks: tasksB)
        let runtimeB = try await projectsB.restoreOpenCodeTaskSession(taskID: taskID)
        defer { Task { await runtimeB.stop(deadline: .now.advanced(by: .seconds(10))) } }
        await #expect(throws: OpenCodeACPError.providerFailure(-32602)) {
            try await runtimeB.start()
        }
        #expect(runtimeB.snapshot?.state == .stopped)
        let journal = try #require(tasksB.task(for: taskID)?.nativeDispatch)
        #expect(journal.conversation?.opaqueIdentifier == "ses_definitely_missing_1811")
        #expect(tasksB.task(for: taskID)?.runs.count == 1)
        #expect(tasksB.task(for: taskID)?.runs.last?.liveness != .live)
    }

    /// Polls the runtime until the predicate, collecting every observed
    /// state so the test can assert observed activity, not just endpoints.
    private static func observe(
        _ runtime: OpenCodeACPTaskRuntime,
        ceiling: Duration = .seconds(420),
        until predicate: @MainActor () -> Bool
    ) async throws -> Set<OpenCodeACPSession.State> {
        var seen = Set<OpenCodeACPSession.State>()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: ceiling)
        while clock.now < deadline {
            if let state = runtime.snapshot?.state { seen.insert(state) }
            if predicate() { return seen }
            if Task.isCancelled { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw OpenCodeACPError.unavailable
    }

    /// Answers every form field with its first documented choice.
    private static func firstChoiceAnswers(for question: OpenCodeACPSession.Question) throws -> [String: [String]] {
        guard let form = question.form else { throw OpenCodeACPError.invalidAnswer }
        var answers: [String: [String]] = [:]
        for (name, field) in form.fields where field.required {
            guard let choice = field.choices?.first else {
                throw OpenCodeACPError.invalidAnswer
            }
            answers[name] = [choice]
        }
        guard !answers.isEmpty else { throw OpenCodeACPError.invalidAnswer }
        return answers
    }

    /// Rewrites the durable store: both the run's vendor identity and the
    /// journal conversation point at a session the native store cannot load.
    private static func rewriteStoreIdentity(
        storeFile: URL, taskID: UUID, toOpaqueIdentifier: String
    ) throws {
        let data = try Data(contentsOf: storeFile)
        var tasks = try JSONDecoder().decode([AgentTask].self, from: data)
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else {
            throw OpenCodeACPError.invalidState
        }
        guard var run = tasks[index].runs.last,
              let identity = run.vendorIdentity else {
            throw OpenCodeACPError.invalidState
        }
        run.vendorIdentity = AgentVendorSessionIdentity(
            provider: identity.provider,
            opaqueIdentifier: toOpaqueIdentifier,
            executableVersion: identity.executableVersion
        )
        tasks[index].runs = [run]
        guard var journal = tasks[index].nativeDispatch,
              let conversation = journal.conversation else {
            throw OpenCodeACPError.invalidState
        }
        journal.conversation = AgentVendorSessionIdentity(
            provider: conversation.provider,
            opaqueIdentifier: toOpaqueIdentifier,
            executableVersion: conversation.executableVersion
        )
        tasks[index].nativeDispatch = journal
        let rewritten = try JSONEncoder().encode(tasks)
        try rewritten.write(to: storeFile, options: .atomic)
    }
}

/// File-backed durable task store: the relaunch simulation shares the same
/// file between two registry incarnations, mirroring a real app exit/relaunch.
actor OpenCodeRealModelTaskStore: AgentTaskPersisting {
    private let file: URL
    init(file: URL) { self.file = file }
    func load(project: AgentTaskProjectIdentity) async -> AgentTaskMetadataLoadResult {
        guard let data = try? Data(contentsOf: file),
              let tasks = try? JSONDecoder().decode([AgentTask].self, from: data) else {
            return AgentTaskMetadataLoadResult(
                status: .loaded, tasks: [], revision: nil, requiresMigration: false, envelope: .empty
            )
        }
        return AgentTaskMetadataLoadResult(
            status: .loaded, tasks: tasks, revision: nil, requiresMigration: false, envelope: .empty
        )
    }
    func save(
        tasks: [AgentTask], project: AgentTaskProjectIdentity,
        authorization: AgentTaskPublicationAuthorization?
    ) async -> AgentTaskMetadataSaveResult {
        guard let encoded = try? JSONEncoder().encode(tasks) else {
            return .rejected(.invalidMetadata)
        }
        do {
            try encoded.write(to: file, options: .atomic)
            return .saved(taskCount: tasks.count)
        } catch {
            return .rejected(.ioFailure)
        }
    }
}

nonisolated struct OpenCodeRealModelFixture: Sendable {
    let root: URL
    let project: URL
    let managedRoot: URL
    let storeFile: URL

    var identity: AgentTaskProjectIdentity {
        AgentTaskProjectIdentity(
            canonicalProjectPath: project.path, canonicalWorktreePath: project.path
        )
    }

    init(model: String) throws {
        let rawRoot = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Caches/pine-opencode-real-model-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: rawRoot, withIntermediateDirectories: true)
        root = rawRoot.resolvingSymlinksInPath()
        project = root.appendingPathComponent("project")
        managedRoot = root.appendingPathComponent("worktrees")
        storeFile = root.appendingPathComponent("tasks.json")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: managedRoot, withIntermediateDirectories: true)
        try Data("tracked\n".utf8).write(to: project.appendingPathComponent("tracked.txt"))
        // Project-level OpenCode config: the pinned model, one-shot edit
        // permission, and no third-party plugins. The adapter inherits this
        // native configuration; no global config is written.
        let config: [String: Any] = [
            "$schema": "https://opencode.ai/config.json",
            "model": model,
            "permission": ["edit": "ask", "bash": "ask"],
            "plugins": [],
        ]
        let configData = try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
        try String(data: configData, encoding: .utf8)!.write(
            toFile: project.appendingPathComponent("opencode.json").path, atomically: true, encoding: .utf8
        )
        try git(["init", "-b", "main"])
        try git(["add", "."])
        try git([
            "-c", "user.name=Pine Test", "-c", "user.email=pine@example.invalid",
            "commit", "-m", "fixture"
        ])
    }

    func worktreeFile(taskID: UUID, name: String) -> String? {
        let worktree = managedRoot.appendingPathComponent(taskID.uuidString.lowercased())
        guard let contents = try? String(contentsOf: worktree.appendingPathComponent(name), encoding: .utf8)
        else { return nil }
        return contents.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    private func git(_ arguments: [String]) throws {
        let result = GitCommand.runExecutable(
            URL(fileURLWithPath: "/usr/bin/env"),
            arguments: AgentTaskReservedWorktreeSetup.arguments(arguments), at: project
        )
        guard result.succeeded else { throw CocoaError(.fileWriteUnknown) }
    }
}
