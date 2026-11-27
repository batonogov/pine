//
//  OpenCodeTaskSubmissionTests.swift
//  PineTests
//
//  The Request admission rules shared by the registry and the Pine 3
//  composer (#1760): what becomes a durable task, what is refused before
//  anything exists, and what happens when the launch after a created task
//  is not confirmed. The launch path uses a nonexistent executable so no
//  agent is ever started.
//

import Foundation
import Testing
@testable import Pine

@Suite("OpenCode task submission admission", .serialized)
@MainActor
struct OpenCodeTaskSubmissionTests {
    private func makeFixture() throws -> SubmissionFixture {
        try SubmissionFixture()
    }

    // MARK: - Validation rules

    @Test("the first line is the title, exactly as the registry derives it")
    func titleIsFirstLine() {
        #expect(
            OpenCodeTaskLaunchValidation.title(of: "Fix the bug\nwith detail")
                == "Fix the bug"
        )
        #expect(OpenCodeTaskLaunchValidation.title(of: "\n\nlater") == "later")
        #expect(OpenCodeTaskLaunchValidation.title(of: "   ") == "")
    }

    @Test("valid goals: non-blank, within the objective limit, title within its own limit")
    func validityRules() throws {
        let limits = AgentTaskPersistenceLimits()
        #expect(OpenCodeTaskLaunchValidation.isValid("Fix the bug", limits: limits))
        #expect(
            !OpenCodeTaskLaunchValidation.isValid(
                String(repeating: "x", count: limits.maxObjectiveBytes + 1), limits: limits
            )
        )
        #expect(
            !OpenCodeTaskLaunchValidation.isValid(
                String(repeating: "t", count: limits.maxTitleBytes + 1) + "\nbody",
                limits: limits
            )
        )
        #expect(!OpenCodeTaskLaunchValidation.isValid("   \n  ", limits: limits))
    }

    @Test("a submission refuses an over-long request before anything exists")
    func tooLongCreatesNothing() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let submission = OpenCodeTaskSubmission(
            registry: fixture.registry, project: fixture.identity
        )
        submission.input = String(
            repeating: "x", count: fixture.registry.agentTasks.persistenceLimits.maxObjectiveBytes + 1
        )
        #expect(submission.isTooLong)
        #expect(!submission.isAwaitingRetry)

        await submission.send().value
        #expect(submission.taskID == nil)
        #expect(submission.failure == .instructionTooLong)
        #expect(fixture.registry.agentTasks.tasks.isEmpty, "nothing was created")
    }

    // MARK: - The launch-after-created boundary

    @Test("a created task whose launch is not confirmed is never created twice")
    func unconfirmedLaunchKeepsOneTask() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }

        var reportedTaskID: UUID?
        await #expect(throws: Error.self) {
            reportedTaskID = try await fixture.registry.startOpenCodeTask(
                instruction: "Add a regression test",
                project: fixture.identity,
                executable: fixture.missingBinary,
                managedRoot: fixture.managedRoot,
                onTaskCreated: { reportedTaskID = $0 }
            )
        }

        // The durable task exists, the launch did not.
        let taskID = try #require(reportedTaskID)
        let task = try #require(fixture.registry.agentTasks.task(for: taskID))
        #expect(task.objective == "Add a regression test")
        #expect(task.runs.isEmpty)
        #expect(task.nativeDispatch != nil)
        #expect(fixture.registry.agentTasks.tasks.count == 1)

        // An explicit retry sends the recorded goal and never makes a sibling.
        await #expect(throws: Error.self) {
            try await fixture.registry.retryOpenCodeTaskLaunch(
                taskID: taskID, executable: fixture.missingBinary
            )
        }
        let retried = try #require(fixture.registry.agentTasks.task(for: taskID))
        #expect(retried.objective == "Add a regression test")
        #expect(retried.runs.isEmpty)
        #expect(fixture.registry.agentTasks.tasks.count == 1)
    }

    @Test("a retry refuses a task that already has a run or no reservation")
    func retryIsBounded() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }

        // No reservation at all: nothing to retry.
        var task = AgentTask(
            descriptor: AgentDescriptor(agentType: .openCode, launchExecutable: "opencode"),
            context: AgentTaskBridgeContext(
                project: fixture.identity,
                route: AgentTaskRoute(ownedProcessAvailability: .missing),
                origin: .pineLaunched,
                observedAt: Date()
            ),
            title: "No dispatch", objective: "No dispatch", createdAt: Date()
        )
        task.lifecycle = .paused
        fixture.registry.agentTasks.setTasksForTesting([task])
        await #expect(throws: OpenCodeACPError.unavailable) {
            try await fixture.registry.retryOpenCodeTaskLaunch(
                taskID: task.id, executable: fixture.missingBinary
            )
        }
    }
}

@MainActor
private struct SubmissionFixture {
    let registry: ProjectRegistry
    let identity: AgentTaskProjectIdentity
    let managedRoot: URL
    let missingBinary: URL
    private let root: URL

    init() throws {
        let rawRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("pine-submission-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rawRoot, withIntermediateDirectories: true)
        root = rawRoot.resolvingSymlinksInPath()
        let project = root.appendingPathComponent("project", isDirectory: true)
        managedRoot = root.appendingPathComponent("worktrees", isDirectory: true)
        missingBinary = root.appendingPathComponent("no-such-opencode")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: managedRoot, withIntermediateDirectories: true)

        // The launch path reserves a worktree, which needs a repository.
        try git(["init", "-b", "main"], at: project)
        try Data("tracked\n".utf8).write(to: project.appendingPathComponent("tracked.txt"))
        try git(["add", "."], at: project)
        try git([
            "-c", "user.name=Pine Test", "-c", "user.email=pine@example.invalid",
            "commit", "-m", "fixture",
        ], at: project)

        registry = ProjectRegistry(
            agentTasks: AgentTaskRegistry(
                persistence: InMemoryAgentTaskStore(),
                accuracyPolicy: AgentLifecycleAccuracyPolicy { _ in
                    .verifiedLifecycleTransitions
                }
            )
        )
        identity = AgentTaskProjectIdentity(
            canonicalProjectPath: project.path, canonicalWorktreePath: project.path
        )
    }

    private func git(_ arguments: [String], at directory: URL) throws {
        let result = GitCommand.runExecutable(
            URL(fileURLWithPath: "/usr/bin/env"),
            arguments: AgentTaskReservedWorktreeSetup.arguments(arguments),
            at: directory
        )
        guard result.succeeded else { throw CocoaError(.fileWriteUnknown) }
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private actor InMemoryAgentTaskStore: AgentTaskPersisting {
    private var data = Data("[]".utf8)

    func load(project: AgentTaskProjectIdentity) async -> AgentTaskMetadataLoadResult {
        AgentTaskMetadataLoadResult(
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
