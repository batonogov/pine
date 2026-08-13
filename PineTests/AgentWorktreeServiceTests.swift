//
//  AgentWorktreeServiceTests.swift
//  PineTests
//

import Foundation
import Testing

@testable import Pine

@Suite("Agent Worktree Service", .serialized)
struct AgentWorktreeServiceTests {
    @Test("Creation preserves primary branch, HEAD, index, and dirty state")
    func createsWithoutContaminatingPrimaryCheckout() async throws {
        let fixture = try WorktreeFixture()
        try fixture.write("local.txt", "untracked\n")
        let before = try fixture.primaryEvidence()
        let service = AgentWorktreeService()

        let result = await service.create(fixture.request(
            taskID: id(1),
            branch: "agent/task-one"
        ))
        let worktree = try created(result)

        #expect(FileManager.default.fileExists(atPath: worktree.worktreeRoot.path))
        #expect(try fixture.primaryEvidence() == before)
        #expect(try fixture.git(
            ["branch", "--show-current"],
            at: worktree.worktreeRoot
        ).trimmingCharacters(in: .whitespacesAndNewlines) == "agent/task-one")
    }

    @Test("Dirty and untracked data require exact destructive confirmation")
    func dirtyRemovalRequiresExactConfirmation() async throws {
        let fixture = try WorktreeFixture()
        let service = AgentWorktreeService()
        let worktree = try created(await service.create(fixture.request(
            taskID: id(2),
            branch: "agent/dirty"
        )))
        try Data("changed\n".utf8).write(
            to: worktree.worktreeRoot.appendingPathComponent("tracked.txt")
        )
        try Data("new\n".utf8).write(
            to: worktree.worktreeRoot.appendingPathComponent("untracked.txt")
        )

        let first = await service.remove(worktree)
        guard case .failed(.confirmationRequired(let inspection)) = first else {
            Issue.record("Expected an exact dirty-worktree confirmation")
            return
        }
        #expect(inspection.dirtyPaths == ["tracked.txt", "untracked.txt"])
        #expect(FileManager.default.fileExists(atPath: worktree.worktreeRoot.path))

        let mismatched = AgentWorktreeRemovalConfirmation(
            worktreeRoot: worktree.worktreeRoot,
            dirtyPaths: ["tracked.txt"],
            acknowledgesUnrecoverableDataLoss: true
        )
        #expect(await service.remove(
            worktree,
            confirmation: mismatched
        ) == .failed(.confirmationMismatch))
        #expect(FileManager.default.fileExists(atPath: worktree.worktreeRoot.path))

        let confirmed = AgentWorktreeRemovalConfirmation(
            worktreeRoot: inspection.worktree.worktreeRoot,
            dirtyPaths: inspection.dirtyPaths,
            acknowledgesUnrecoverableDataLoss: true
        )
        #expect(await service.remove(
            worktree,
            confirmation: confirmed
        ) == .removed)
        #expect(!FileManager.default.fileExists(atPath: worktree.worktreeRoot.path))
    }

    @Test("Invalid branches, missing refs, and symlink roots fail closed")
    func invalidInputsFailClosed() async throws {
        let fixture = try WorktreeFixture()
        let service = AgentWorktreeService()

        #expect(await service.create(fixture.request(
            taskID: id(3),
            branch: "../escape"
        )) == .failed(.invalidBranchName))
        #expect(await service.create(fixture.request(
            taskID: id(4),
            branch: "agent/missing",
            startPoint: "refs/heads/does-not-exist"
        )) == .failed(.missingStartPoint))

        let symlink = fixture.root.appendingPathComponent("linked-root")
        try FileManager.default.createSymbolicLink(
            at: symlink,
            withDestinationURL: fixture.managedRoot
        )
        let request = AgentWorktreeCreateRequest(
            taskID: id(5),
            repositoryRoot: fixture.repository,
            managedRoot: symlink,
            branchName: "agent/symlink",
            startPoint: "HEAD"
        )
        #expect(await service.create(request) == .failed(.unsafeManagedRoot))
    }

    @Test("Concurrent duplicate creation has one winner")
    func concurrentDuplicateCreation() async throws {
        let fixture = try WorktreeFixture()
        let service = AgentWorktreeService()
        let request = fixture.request(
            taskID: id(6),
            branch: "agent/only-once"
        )

        async let first = service.create(request)
        async let second = service.create(request)
        let results = await [first, second]

        #expect(results.filter {
            if case .created = $0 { return true }
            return false
        }.count == 1)
        #expect(results.filter {
            if case .failed(.destinationAlreadyExists) = $0 { return true }
            return false
        }.count == 1)
    }

    @Test("A linked worktree can safely create another isolated worktree")
    func linkedWorktreeRepositoryRoot() async throws {
        let fixture = try WorktreeFixture()
        let service = AgentWorktreeService()
        let first = try created(await service.create(fixture.request(
            taskID: id(7),
            branch: "agent/first"
        )))

        let nestedManagedRoot = fixture.root.appendingPathComponent(
            "second-managed",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: nestedManagedRoot,
            withIntermediateDirectories: false
        )
        let second = await service.create(AgentWorktreeCreateRequest(
            taskID: id(8),
            repositoryRoot: first.worktreeRoot,
            managedRoot: nestedManagedRoot,
            branchName: "agent/second",
            startPoint: "HEAD"
        ))

        #expect(try created(second).branchName == "agent/second")
    }

    @Test("Preview is read-only and integration requires exact approval")
    func integrationIsPreviewedAndExplicit() async throws {
        let fixture = try WorktreeFixture()
        let service = AgentWorktreeService()
        let worktree = try created(await service.create(fixture.request(
            taskID: id(9),
            branch: "agent/integrate"
        )))
        try fixture.write("tracked.txt", "agent result\n", at: worktree.worktreeRoot)
        _ = try fixture.git(["add", "--", "tracked.txt"], at: worktree.worktreeRoot)
        _ = try fixture.git(
            ["commit", "-m", "agent result"],
            at: worktree.worktreeRoot
        )
        let before = try fixture.primaryEvidence()
        let beforeHead = try fixture.git(["rev-parse", "HEAD"])

        let preview = try ready(await service.previewIntegration(
            worktree,
            previewID: id(10)
        ))
        #expect(preview.changedPaths == ["tracked.txt"])
        #expect(!preview.hasConflicts)
        #expect(try fixture.primaryEvidence() == before)

        let mismatch = AgentWorktreeIntegrationConfirmation(
            previewID: preview.id,
            sourceCommit: preview.sourceCommit,
            targetHead: preview.targetHead,
            targetBranch: preview.targetBranch,
            changedPaths: []
        )
        #expect(await service.integrate(
            preview,
            confirmation: mismatch
        ) == .failed(.confirmationMismatch))
        #expect(try fixture.primaryEvidence() == before)

        let confirmation = AgentWorktreeIntegrationConfirmation(
            previewID: preview.id,
            sourceCommit: preview.sourceCommit,
            targetHead: preview.targetHead,
            targetBranch: preview.targetBranch,
            changedPaths: preview.changedPaths
        )
        #expect(await service.integrate(
            preview,
            confirmation: confirmation
        ) == .integratedWithoutCommit)
        #expect(try fixture.git(["rev-parse", "HEAD"]) == beforeHead)
        #expect(try String(contentsOf: fixture.repository.appendingPathComponent(
            "tracked.txt"
        ), encoding: .utf8) == "agent result\n")
    }

    @Test("Conflicts are previewed without touching the primary checkout")
    func conflictsFailBeforeIntegration() async throws {
        let fixture = try WorktreeFixture()
        let service = AgentWorktreeService()
        let worktree = try created(await service.create(fixture.request(
            taskID: id(11),
            branch: "agent/conflict"
        )))
        try fixture.write("tracked.txt", "agent side\n", at: worktree.worktreeRoot)
        _ = try fixture.git(["add", "--", "tracked.txt"], at: worktree.worktreeRoot)
        _ = try fixture.git(
            ["commit", "-m", "agent side"],
            at: worktree.worktreeRoot
        )
        try fixture.write("tracked.txt", "primary side\n")
        _ = try fixture.git(["add", "--", "tracked.txt"])
        _ = try fixture.git(["commit", "-m", "primary side"])
        let before = try fixture.primaryEvidence()

        let preview = try ready(await service.previewIntegration(
            worktree,
            previewID: id(12)
        ))
        #expect(preview.conflictingPaths == ["tracked.txt"])
        #expect(try fixture.primaryEvidence() == before)
        let confirmation = AgentWorktreeIntegrationConfirmation(
            previewID: preview.id,
            sourceCommit: preview.sourceCommit,
            targetHead: preview.targetHead,
            targetBranch: preview.targetBranch,
            changedPaths: preview.changedPaths
        )
        #expect(await service.integrate(
            preview,
            confirmation: confirmation
        ) == .failed(.conflictsRequireResolution(["tracked.txt"])))
        #expect(try fixture.primaryEvidence() == before)
    }

    @Test("Interrupted creation is reported without guessing cleanup")
    func interruptedCreationIsRecoverable() async throws {
        let fixture = try WorktreeFixture()
        let runner = AgentWorktreeGitRunner { arguments, directory in
            if arguments.starts(with: ["worktree", "add"]) {
                return interruptedGitResult()
            }
            return await GitCommand.runAsync(arguments, at: directory)
        }
        let service = AgentWorktreeService(runner: runner)
        let request = fixture.request(
            taskID: id(13),
            branch: "agent/interrupted"
        )
        let result = await service.create(request)
        guard case .failed(.creationInterrupted(let path)) = result else {
            Issue.record("Expected interrupted creation, received \(result)")
            return
        }
        #expect(path.lastPathComponent == id(13).uuidString.lowercased())
        #expect(!FileManager.default.fileExists(atPath: path.path))
    }

    @Test("Sibling worktrees keep independent simultaneous task identities")
    @MainActor
    func siblingWorktreesHaveIndependentTaskScopes() async throws {
        let fixture = try WorktreeFixture()
        let service = AgentWorktreeService()
        let left = try created(await service.create(fixture.request(
            taskID: id(14),
            branch: "agent/left"
        )))
        let right = try created(await service.create(fixture.request(
            taskID: id(15),
            branch: "agent/right"
        )))
        let storage = fixture.root.appendingPathComponent("task-metadata")
        let taskRegistry = AgentTaskRegistry(persistence: AgentTaskMetadataStore(
            storageRoot: storage
        ))
        let suiteName = "AgentWorktreeServiceTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let projects = ProjectRegistry(
            defaults: defaults,
            agentTasks: taskRegistry
        )
        let leftManager = try #require(
            await projects.projectManager(for: left)
        )
        let rightManager = try #require(
            await projects.projectManager(for: right)
        )
        _ = await taskRegistry.flushPersistence()

        let leftTab = try terminalTab(in: leftManager, at: left.worktreeRoot)
        let rightTab = try terminalTab(in: rightManager, at: right.worktreeRoot)
        let leftContext = try #require(
            leftManager.terminal.agentTaskContext(for: leftTab)
        )
        let rightContext = try #require(
            rightManager.terminal.agentTaskContext(for: rightTab)
        )
        #expect(leftContext.project.canonicalProjectPath
            == rightContext.project.canonicalProjectPath)
        #expect(leftContext.project.canonicalWorktreePath
            != rightContext.project.canonicalWorktreePath)
        #expect(leftContext.route.terminalID != rightContext.route.terminalID)

        let descriptor = AgentDescriptor(
            agentType: .codex,
            launchExecutable: "codex"
        )
        let leftReservation = try reservation(
            leftManager.terminal.prepareAgentLaunch(
                in: leftTab,
                descriptor: descriptor,
                objective: "Implement the same objective"
            )
        )
        let rightReservation = try reservation(
            rightManager.terminal.prepareAgentLaunch(
                in: rightTab,
                descriptor: descriptor,
                objective: "Implement the same objective"
            )
        )
        #expect(leftReservation.taskID != rightReservation.taskID)
        #expect(taskRegistry.tasks.count == 2)

        #expect(taskRegistry.armLaunch(leftReservation))
        #expect(taskRegistry.armLaunch(rightReservation))
        leftManager.terminal.bridgeAgentSession(
            session(id: id(16), processIdentifier: 1_316),
            replacing: nil,
            in: leftTab,
            reservation: leftReservation
        )
        rightManager.terminal.bridgeAgentSession(
            session(id: id(17), processIdentifier: 1_317),
            replacing: nil,
            in: rightTab,
            reservation: rightReservation
        )

        projects.closeProjectWindow(left.worktreeRoot)
        #expect(taskRegistry.task(for: leftReservation.taskID)?
            .route.availability == .background)
        #expect(taskRegistry.task(for: rightReservation.taskID)?
            .route.availability == .available)
    }

    private func created(
        _ result: AgentWorktreeCreateResult
    ) throws -> AgentManagedWorktree {
        guard case .created(let worktree) = result else {
            Issue.record("Expected worktree creation, received \(result)")
            throw WorktreeFixtureError.commandFailed
        }
        return worktree
    }

    private func ready(
        _ result: AgentWorktreeIntegrationPreviewResult
    ) throws -> AgentWorktreeIntegrationPreview {
        guard case .ready(let preview) = result else {
            Issue.record("Expected integration preview, received \(result)")
            throw WorktreeFixtureError.commandFailed
        }
        return preview
    }

    @MainActor
    private func terminalTab(
        in manager: ProjectManager,
        at workingDirectory: URL
    ) throws -> TerminalTab {
        let pane = manager.paneManager.createTerminalPaneAtBottom(
            workingDirectory: workingDirectory
        )
        return try #require(
            manager.paneManager.terminalState(for: pane)?.activeTab
        )
    }

    private func reservation(
        _ result: AgentTaskLaunchResult
    ) throws -> AgentTaskLaunchReservation {
        guard case .reserved(let reservation) = result else {
            Issue.record("Expected launch reservation, received \(result)")
            throw WorktreeFixtureError.commandFailed
        }
        return reservation
    }

    @MainActor
    private func session(
        id: UUID,
        processIdentifier: Int32
    ) -> AgentSession {
        let startedAt = Date()
        let session = AgentSession(
            id: id,
            agentType: .codex,
            state: .executing,
            startedAt: startedAt
        )
        _ = session.bindProcessEvidence(AgentProcessEvidence(
            processIdentifier: processIdentifier,
            processGeneration: 1,
            startIdentifier: "worktree-\(processIdentifier)",
            observedStartedAt: startedAt,
            startIsAuthoritative: true
        ))
        return session
    }
}

private enum WorktreeFixtureError: Error {
    case commandFailed
}

private final class WorktreeFixture {
    let root: URL
    let repository: URL
    let managedRoot: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PineAgentWorktree-\(UUID().uuidString)",
            isDirectory: true
        )
        repository = root.appendingPathComponent("repository", isDirectory: true)
        managedRoot = root.appendingPathComponent("managed", isDirectory: true)
        try FileManager.default.createDirectory(
            at: repository,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: managedRoot,
            withIntermediateDirectories: false
        )
        _ = try git(["init", "-b", "main"], at: repository)
        _ = try git(["config", "user.email", "pine-tests@example.invalid"])
        _ = try git(["config", "user.name", "Pine Tests"])
        try write("tracked.txt", "base\n")
        _ = try git(["add", "--", "tracked.txt"])
        _ = try git(["commit", "-m", "base"])
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func request(
        taskID: UUID,
        branch: String,
        startPoint: String = "HEAD"
    ) -> AgentWorktreeCreateRequest {
        AgentWorktreeCreateRequest(
            taskID: taskID,
            repositoryRoot: repository,
            managedRoot: managedRoot,
            branchName: branch,
            startPoint: startPoint
        )
    }

    func write(
        _ relativePath: String,
        _ content: String,
        at directory: URL? = nil
    ) throws {
        guard let data = content.data(using: .utf8) else {
            throw WorktreeFixtureError.commandFailed
        }
        try data.write(to: (directory ?? repository).appendingPathComponent(
            relativePath
        ))
    }

    func primaryEvidence() throws -> [String] {
        [
            try git(["branch", "--show-current"]),
            try git(["rev-parse", "HEAD"]),
            try git(["status", "--porcelain=v1", "-z"]),
            try git(["ls-files", "--stage"]),
        ]
    }

    @discardableResult
    func git(_ arguments: [String], at directory: URL? = nil) throws -> String {
        let result = GitCommand.run(arguments, at: directory ?? repository)
        guard result.succeeded else {
            throw WorktreeFixtureError.commandFailed
        }
        return result.output
    }
}

private func id(_ value: Int) -> UUID {
    UUID(uuid: (
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, UInt8(value)
    ))
}

nonisolated private func interruptedGitResult() -> GitCommandResult {
    GitCommandResult(
        output: "",
        errorOutput: "",
        exitCode: -1,
        timedOut: true,
        cancelled: false,
        outputTruncated: false,
        errorOutputTruncated: false,
        outputCaptureComplete: true,
        errorOutputCaptureComplete: true,
        outputReadError: nil,
        errorOutputReadError: nil
    )
}
