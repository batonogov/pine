//
//  ADEWorkspaceModelTests.swift
//  PineTests
//
//  One project window's state (#1760): selection persistence, the explicit
//  Request/Command modes, and the truthful captions for each. Nothing in
//  this suite launches or resumes an agent: Command mode uses a recording
//  stub, and Request sends that would resolve the real OpenCode binary are
//  covered by OpenCodeTaskSubmissionTests at the registry admission path.
//

import AppKit
import Foundation
import Testing
@testable import Pine

@MainActor
private final class RecordingCommandRunner: CommandRunner {
    private(set) var runs: [(command: String, taskID: UUID?)] = []
    private let result: ADECommandResult
    private let error: Error?
    private let pauseFirstRun: Bool
    /// When armed, the next run suspends until the test releases it.
    private var releaseRun: CheckedContinuation<Void, Never>?

    init(
        result: ADECommandResult = ADECommandResult(
            exitCode: 0, output: .make(stdout: "ok\n", stderr: "")
        ),
        error: Error? = nil,
        pauseFirstRun: Bool = false
    ) {
        self.result = result
        self.error = error
        self.pauseFirstRun = pauseFirstRun
    }

    func run(
        _ command: String, in environment: ADECommandEnvironment
    ) async throws -> ADECommandResult {
        runs.append((command, environment.taskID))
        if pauseFirstRun, runs.count == 1 {
            await withCheckedContinuation { releaseRun = $0 }
        }
        if let error { throw error }
        return result
    }

    /// Lets the suspended run finish.
    func release() {
        releaseRun?.resume()
        releaseRun = nil
    }
}

@Suite("ADE workspace model", .serialized)
@MainActor
struct ADEWorkspaceModelTests {
    private let projectURL = FileManager.default.temporaryDirectory
        .resolvingSymlinksInPath()
        .appendingPathComponent("ADEModel-\(UUID().uuidString)", isDirectory: true)

    private func makeRegistry() async throws -> (ProjectRegistry, UserDefaults, String) {
        try FileManager.default.createDirectory(
            at: projectURL, withIntermediateDirectories: true
        )
        let suiteName = "ADEWorkspaceModelTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let registry = ProjectRegistry(
            defaults: defaults,
            agentTasks: AgentTaskRegistry(
                accuracyPolicy: AgentLifecycleAccuracyPolicy { _ in
                    .verifiedLifecycleTransitions
                }
            ),
            agentDetectionProcessRunner: { _, _, _, _ in
                ProcessRunResult(stdout: "", stderr: "", exitCode: 0, timedOut: false)
            },
            agentDetectionPollInterval: 3_600,
            agentDetectionInitialPollDelay: 3_600
        )
        // Complete the admission read before the model mounts: an empty,
        // fresh store yields `.missing`, which is the authoritative empty
        // list these tests' selection semantics are written against.
        let identity = AgentTaskProjectIdentity(
            canonicalProjectPath: projectURL.path, canonicalWorktreePath: projectURL.path
        )
        registry.agentTasks.registerProject(identity)
        #expect(
            await waitUntilMainActor {
                registry.agentTasks.metadataLoadStatus(for: identity) != nil
            },
            "the admission read should complete for a fresh project"
        )
        return (registry, defaults, suiteName)
    }

    /// A registry whose metadata read is held open by the test, so the
    /// model mounts during the load window (status still `nil`).
    private func makeGatedRegistry(
        store: GatedLoadAgentTaskStore
    ) throws -> (ProjectRegistry, UserDefaults, String) {
        try FileManager.default.createDirectory(
            at: projectURL, withIntermediateDirectories: true
        )
        let suiteName = "ADEWorkspaceModelTests.gated.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let registry = ProjectRegistry(
            defaults: defaults,
            agentTasks: AgentTaskRegistry(
                persistence: store,
                accuracyPolicy: AgentLifecycleAccuracyPolicy { _ in
                    .verifiedLifecycleTransitions
                }
            ),
            agentDetectionProcessRunner: { _, _, _, _ in
                ProcessRunResult(stdout: "", stderr: "", exitCode: 0, timedOut: false)
            },
            agentDetectionPollInterval: 3_600,
            agentDetectionInitialPollDelay: 3_600
        )
        return (registry, defaults, suiteName)
    }

    private func makeModel(
        _ registry: ProjectRegistry,
        selectionStore: ADETaskSelectionStore,
        commandRunner: (any CommandRunner)? = nil,
        announce: (String) -> Void = { _ in }
    ) -> ADEWorkspaceModel {
        let model = ADEWorkspaceModel(
            registry: registry, projectURL: projectURL, commandRunner: commandRunner,
            selectionStore: selectionStore,
            announce: announce
        )
        model.activate()
        return model
    }

    private func makeSelectionStore(
        _ defaults: UserDefaults
    ) throws -> (ADETaskSelectionStore, String) {
        let suiteName = "ADEWorkspaceModelTests.store.\(UUID().uuidString)"
        let storeDefaults = try #require(UserDefaults(suiteName: suiteName))
        storeDefaults.removePersistentDomain(forName: suiteName)
        return (ADETaskSelectionStore(defaults: storeDefaults), suiteName)
    }

    private func seedTask(
        _ registry: ProjectRegistry, title: String
    ) -> UUID {
        var task = AgentTask(
            descriptor: AgentDescriptor(agentType: .codex),
            context: AgentTaskBridgeContext(
                project: AgentTaskProjectIdentity(
                    canonicalProjectPath: projectURL.path,
                    canonicalWorktreePath: projectURL.path
                ),
                route: AgentTaskRoute(
                    paneID: UUID(), tabID: UUID(), terminalID: UUID()
                ),
                origin: .discoveredInTerminal,
                observedAt: Date()
            ),
            title: title, objective: title, createdAt: Date()
        )
        task.lifecycle = .paused
        registry.agentTasks.setTasksForTesting(registry.agentTasks.tasks + [task])
        return task.id
    }

    /// Builds a loadable task with a known, fixed ID: the model type's `id`
    /// is immutable at construction, so the value is patched through its own
    /// coding round-trip (the same trick the UI-test fixture uses).
    private func makeIdentifiedTask(id: UUID, title: String) -> AgentTask {
        var task = AgentTask(
            descriptor: AgentDescriptor(agentType: .codex),
            context: AgentTaskBridgeContext(
                project: AgentTaskProjectIdentity(
                    canonicalProjectPath: projectURL.path,
                    canonicalWorktreePath: projectURL.path
                ),
                route: AgentTaskRoute(
                    paneID: UUID(), tabID: UUID(), terminalID: UUID()
                ),
                origin: .discoveredInTerminal,
                observedAt: Date()
            ),
            title: title, objective: title, createdAt: Date()
        )
        task.lifecycle = .paused
        guard let data = try? JSONEncoder().encode(task),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return task
        }
        object["id"] = id.uuidString
        guard let patched = try? JSONSerialization.data(withJSONObject: object),
              let identified = try? JSONDecoder().decode(AgentTask.self, from: patched) else {
            return task
        }
        return identified
    }

    // MARK: - Selection

    @Test("selecting a listed task persists and clears the composer; an unknown task is refused")
    func selectionPersistsAndRefusesUnknown() async throws {
        let (registry, defaults, suite) = try await makeRegistry()
        defer { defaults.removePersistentDomain(forName: suite) }
        let (store, storeSuite) = try makeSelectionStore(defaults)
        defer { defaults.removePersistentDomain(forName: storeSuite) }

        let taskID = seedTask(registry, title: "Fix the boundary")
        let model = makeModel(registry, selectionStore: store)

        model.selectTask(UUID())
        #expect(model.selectedTaskID == nil)

        model.selectTask(taskID)
        #expect(model.selectedTaskID == taskID)
        #expect(model.selectedRow?.goal == "Fix the boundary")
        #expect(store.taskID(forProject: projectURL.path) == taskID)
    }

    @Test("a new model restores the stored selection and sends nothing")
    func restoreSendsNothing() async throws {
        let (registry, defaults, suite) = try await makeRegistry()
        defer { defaults.removePersistentDomain(forName: suite) }
        let (store, storeSuite) = try makeSelectionStore(defaults)
        defer { defaults.removePersistentDomain(forName: storeSuite) }

        let taskID = seedTask(registry, title: "Restore me")
        let first = makeModel(registry, selectionStore: store)
        first.selectTask(taskID)
        first.input = "a draft the user never sent"
        let runner = RecordingCommandRunner()

        // A fresh window over the same store restores the selection view-only.
        let second = makeModel(registry, selectionStore: store, commandRunner: runner)
        #expect(second.selectedTaskID == taskID)
        #expect(second.input.isEmpty)
        #expect(runner.runs.isEmpty)
        #expect(registry.agentTasks.tasks.count == 1)
    }

    @Test("a selection whose task vanished is dropped, not guessed")
    func unknownStoredSelectionIsForgotten() async throws {
        let (registry, defaults, suite) = try await makeRegistry()
        defer { defaults.removePersistentDomain(forName: suite) }
        let (store, storeSuite) = try makeSelectionStore(defaults)
        defer { defaults.removePersistentDomain(forName: storeSuite) }

        store.set(UUID(), forProject: projectURL.path)
        let model = makeModel(registry, selectionStore: store)
        #expect(model.selectedTaskID == nil)
        #expect(store.taskID(forProject: projectURL.path) == nil)
    }

    @Test("switching selection clears the composer and its failure state")
    func switchingSelectionClearsComposer() async throws {
        let (registry, defaults, suite) = try await makeRegistry()
        defer { defaults.removePersistentDomain(forName: suite) }
        let (store, storeSuite) = try makeSelectionStore(defaults)
        defer { defaults.removePersistentDomain(forName: storeSuite) }

        let first = seedTask(registry, title: "First")
        let second = seedTask(registry, title: "Second")

        let model = makeModel(registry, selectionStore: store)
        model.selectTask(first)
        model.input = "typed text"
        model.selectTask(second)
        #expect(model.input.isEmpty)
    }

    @Test("startNewTask returns to the overview with an empty composer")
    func startNewTaskResetsDraft() async throws {
        let (registry, defaults, suite) = try await makeRegistry()
        defer { defaults.removePersistentDomain(forName: suite) }
        let (store, storeSuite) = try makeSelectionStore(defaults)
        defer { defaults.removePersistentDomain(forName: storeSuite) }

        let taskID = seedTask(registry, title: "Existing")
        let model = makeModel(registry, selectionStore: store)
        model.selectTask(taskID)
        model.input = "leftover"

        model.startNewTask()
        #expect(model.selectedTaskID == nil)
        #expect(model.input.isEmpty)
        #expect(store.taskID(forProject: projectURL.path) == nil)
    }

    @Test("a selected task that leaves the list takes the selection with it")
    func vanishingTaskClearsSelection() async throws {
        let (registry, defaults, suite) = try await makeRegistry()
        defer { defaults.removePersistentDomain(forName: suite) }
        let (store, storeSuite) = try makeSelectionStore(defaults)
        defer { defaults.removePersistentDomain(forName: storeSuite) }

        let taskID = seedTask(registry, title: "Doomed")
        let model = makeModel(registry, selectionStore: store)
        model.selectTask(taskID)
        #expect(model.selectedTaskID == taskID)

        registry.agentTasks.setTasksForTesting([])
        #expect(model.selectedTaskID == nil)
        #expect(model.rows.isEmpty)
        #expect(store.taskID(forProject: projectURL.path) == nil)
    }

    // MARK: - Modes and truthful captions

    @Test("Command mode without a runner says so and cannot send")
    func commandModeWithoutRunnerIsUnavailable() async throws {
        let (registry, defaults, suite) = try await makeRegistry()
        defer { defaults.removePersistentDomain(forName: suite) }
        let (store, storeSuite) = try makeSelectionStore(defaults)
        defer { defaults.removePersistentDomain(forName: storeSuite) }

        let model = makeModel(registry, selectionStore: store, commandRunner: nil)
        model.inputMode = .command
        model.input = "swift build"

        #expect(model.notice == .commandUnavailable)
        #expect(!model.canSend)
    }

    @Test("Command mode runs only on an explicit Send, through the runner")
    func commandSendUsesTheRunner() async throws {
        let (registry, defaults, suite) = try await makeRegistry()
        defer { defaults.removePersistentDomain(forName: suite) }
        let (store, storeSuite) = try makeSelectionStore(defaults)
        defer { defaults.removePersistentDomain(forName: storeSuite) }

        let runner = RecordingCommandRunner()
        let model = makeModel(registry, selectionStore: store, commandRunner: runner)
        model.inputMode = .command
        model.input = "swift build"

        #expect(model.notice == nil)
        #expect(model.canSend)
        #expect(runner.runs.isEmpty, "typing alone must never run anything")

        await model.send()
        #expect(runner.runs.count == 1)
        #expect(runner.runs[0].command == "swift build")
        #expect(model.input.isEmpty)
        #expect(model.failure == nil)
    }

    @Test("a failed Command reports the failure and keeps the text")
    func failedCommandKeepsText() async throws {
        let (registry, defaults, suite) = try await makeRegistry()
        defer { defaults.removePersistentDomain(forName: suite) }
        let (store, storeSuite) = try makeSelectionStore(defaults)
        defer { defaults.removePersistentDomain(forName: storeSuite) }

        struct Boom: Error {}
        let runner = RecordingCommandRunner(error: Boom())
        let model = makeModel(registry, selectionStore: store, commandRunner: runner)
        model.inputMode = .command
        model.input = "swift build"
        await model.send()

        #expect(runner.runs.count == 1)
        #expect(model.failure == .actionFailed)
        #expect(model.input == "swift build")
    }

    @Test("Request mode on a task with no live session says Pine will not resume it")
    func requestWithoutLiveSessionIsTruthful() async throws {
        let (registry, defaults, suite) = try await makeRegistry()
        defer { defaults.removePersistentDomain(forName: suite) }
        let (store, storeSuite) = try makeSelectionStore(defaults)
        defer { defaults.removePersistentDomain(forName: storeSuite) }

        let taskID = seedTask(registry, title: "Settled")
        let model = makeModel(registry, selectionStore: store)
        model.selectTask(taskID)
        model.input = "continue this"

        #expect(model.notice == .noLiveSession)
        #expect(!model.canSend, "selection is view-only: no resume, no launch")
    }

    @Test("Request mode on the overview arms Send for well-formed text and refuses over-long text")
    func requestOnOverviewArmsTruthfully() async throws {
        let (registry, defaults, suite) = try await makeRegistry()
        defer { defaults.removePersistentDomain(forName: suite) }
        let (store, storeSuite) = try makeSelectionStore(defaults)
        defer { defaults.removePersistentDomain(forName: storeSuite) }

        let model = makeModel(registry, selectionStore: store)
        #expect(model.notice == nil)
        #expect(!model.canSend, "empty text cannot send")

        model.input = "Add a regression test"
        #expect(model.notice == nil)
        #expect(model.canSend)

        let limits = registry.agentTasks.persistenceLimits
        model.input = String(repeating: "x", count: limits.maxObjectiveBytes + 1)
        #expect(model.notice == .instructionTooLong)
        #expect(!model.canSend)
    }

    @Test("Send is serial: a busy composer cannot send again")
    func busyComposerCannotSend() async throws {
        let (registry, defaults, suite) = try await makeRegistry()
        defer { defaults.removePersistentDomain(forName: suite) }
        let (store, storeSuite) = try makeSelectionStore(defaults)
        defer { defaults.removePersistentDomain(forName: storeSuite) }

        let runner = RecordingCommandRunner(pauseFirstRun: true)
        let model = makeModel(registry, selectionStore: store, commandRunner: runner)
        model.inputMode = .command
        model.input = "long build"
        let sendTask = Task { await model.send() }
        let reached = await waitUntilMainActor { runner.runs.count == 1 && model.isBusy }
        #expect(reached, "the command run should be in flight")
        #expect(!model.canSend)

        runner.release()
        await sendTask.value
        #expect(!model.isBusy)
        #expect(model.input.isEmpty)
    }

    // MARK: - Attention announcements

    @Test("entering Needs decision or Ready is spoken; other transitions are not")
    func attentionTransitionsAreAnnounced() async throws {
        let (registry, defaults, suite) = try await makeRegistry()
        defer { defaults.removePersistentDomain(forName: suite) }
        let (store, storeSuite) = try makeSelectionStore(defaults)
        defer { defaults.removePersistentDomain(forName: storeSuite) }

        let taskID = seedTask(registry, title: "Announce me")
        var announcements: [String] = []
        let model = makeModel(registry, selectionStore: store, announce: {
            announcements.append($0)
        })
        model.isKey = true

        var working = registry.agentTasks.tasks[0]
        working.runs = [AgentTaskRun(AgentTaskRunInput(
            id: UUID(),
            terminalID: working.route.terminalID,
            process: AgentProcessEvidence(
                processIdentifier: 42, processGeneration: 1,
                startIdentifier: "model-announce",
                observedStartedAt: Date(), startIsAuthoritative: true
            ),
            status: AgentTaskRunStatus(
                state: .executing, liveness: .live, observedAt: Date()
            )
        ))]
        working.lifecycle = .active
        registry.agentTasks.setTasksForTesting([working])
        #expect(announcements.isEmpty, "working is intermediate activity, not attention")

        var waiting = registry.agentTasks.tasks[0]
        waiting.runs[0] = AgentTaskRun(AgentTaskRunInput(
            id: waiting.runs[0].id,
            terminalID: waiting.route.terminalID,
            process: waiting.runs[0].process,
            status: AgentTaskRunStatus(
                state: .waitingInput, liveness: .live, observedAt: Date()
            )
        ))
        waiting.attention = .waitingInput
        waiting.isUnread = true
        registry.agentTasks.setTasksForTesting([waiting])
        #expect(announcements.count == 1)
        #expect(announcements[0].contains("Announce me"))

        _ = taskID
    }

    // MARK: - The metadata-load window (#1760)

    @Test("a persisted selection survives the load window and applies when its task arrives")
    func persistedSelectionSurvivesLoadWindow() async throws {
        let taskID = UUID(uuidString: "0ADE00D1-0000-4000-8000-000000000001") ?? UUID()
        let store = GatedLoadAgentTaskStore(tasks: [makeIdentifiedTask(id: taskID, title: "Loaded late")])
        let (registry, defaults, suite) = try makeGatedRegistry(store: store)
        defer { defaults.removePersistentDomain(forName: suite) }
        let (selectionStore, storeSuite) = try makeSelectionStore(defaults)
        defer { defaults.removePersistentDomain(forName: storeSuite) }

        // The admission read starts now and blocks on the gate.
        let identity = AgentTaskProjectIdentity(
            canonicalProjectPath: projectURL.path, canonicalWorktreePath: projectURL.path
        )
        registry.agentTasks.registerProject(identity)

        selectionStore.set(taskID, forProject: projectURL.path)
        let model = makeModel(registry, selectionStore: selectionStore)

        // The empty list is not authoritative: nothing applied, and the
        // persisted selection was NOT erased (the lens-B P1 regression).
        #expect(model.selectedTaskID == nil)
        #expect(selectionStore.taskID(forProject: projectURL.path) == taskID)

        // Tasks arrive through the completed load: the first post-load
        // projection applies the held selection.
        store.release()
        #expect(
            await waitUntilMainActor { model.selectedTaskID == taskID },
            "the held selection applies once the task list is authoritative"
        )
        #expect(selectionStore.taskID(forProject: projectURL.path) == taskID)
    }

    @Test("a task absent after a completed load is forgotten; a rejected load never forgets")
    func absentAfterCompletedLoadIsForgotten() async throws {
        let (registry, defaults, suite) = try await makeRegistry()
        defer { defaults.removePersistentDomain(forName: suite) }
        let (selectionStore, storeSuite) = try makeSelectionStore(defaults)
        defer { defaults.removePersistentDomain(forName: storeSuite) }

        // `makeRegistry` completed the admission read with an empty store:
        // the list is authoritative and the stored task is confirmed absent.
        selectionStore.set(UUID(), forProject: projectURL.path)
        let model = makeModel(registry, selectionStore: selectionStore)
        #expect(model.selectedTaskID == nil)
        #expect(
            selectionStore.taskID(forProject: projectURL.path) == nil,
            "a completed load that proves absence may forget the selection"
        )
    }

    @Test("selectTask holds its request across the load window and applies on load")
    func selectTaskHoldsRequestAcrossLoadWindow() async throws {
        let taskID = UUID(uuidString: "0ADE00D1-0000-4000-8000-000000000002") ?? UUID()
        let store = GatedLoadAgentTaskStore(tasks: [makeIdentifiedTask(id: taskID, title: "Routed late")])
        let (registry, defaults, suite) = try makeGatedRegistry(store: store)
        defer { defaults.removePersistentDomain(forName: suite) }
        let (selectionStore, storeSuite) = try makeSelectionStore(defaults)
        defer { defaults.removePersistentDomain(forName: storeSuite) }

        let identity = AgentTaskProjectIdentity(
            canonicalProjectPath: projectURL.path, canonicalWorktreePath: projectURL.path
        )
        registry.agentTasks.registerProject(identity)

        let model = makeModel(registry, selectionStore: selectionStore)
        // Attention routing asks for a task the still-loading list does not
        // show yet: held, not refused.
        model.selectTask(taskID)
        #expect(model.selectedTaskID == nil)

        store.release()
        #expect(
            await waitUntilMainActor { model.selectedTaskID == taskID },
            "the held routing request applies once the task list is authoritative"
        )
    }
}

/// A persistence store whose initial read blocks until the test releases it,
/// so a model can be mounted inside the metadata-load window.
private actor GatedLoadAgentTaskStore: AgentTaskPersisting {
    private var data: Data
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    init(tasks: [AgentTask]) {
        data = (try? JSONEncoder().encode(tasks)) ?? Data("[]".utf8)
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }

    func load(project: AgentTaskProjectIdentity) async -> AgentTaskMetadataLoadResult {
        if !released {
            await withCheckedContinuation { continuation = $0 }
        }
        return AgentTaskMetadataLoadResult(
            status: .loaded,
            tasks: (try? JSONDecoder().decode([AgentTask].self, from: data)) ?? [],
            revision: nil, requiresMigration: false, envelope: .empty
        )
    }

    func save(
        tasks: [AgentTask], project: AgentTaskProjectIdentity,
        authorization: AgentTaskPublicationAuthorization?
    ) async -> AgentTaskMetadataSaveResult {
        guard let encoded = try? JSONEncoder().encode(tasks) else {
            return .rejected(.invalidMetadata)
        }
        data = encoded
        return .saved(taskCount: tasks.count)
    }
}
