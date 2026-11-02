//
//  ProjectWindowSessionWorktreeCleanupTests.swift
//  PineTests
//
//  #1524, close-project half. Closing a project drops its agent worktrees from
//  the window's record while `git worktree remove` is never run for them, so
//  the directories and branches survive. Before this, that happened silently.
//  These tests pin the reporting contract: the set of worktrees the close
//  dropped and the set it accounted for are the same set.
//

import AppKit
import Foundation
import Testing

@testable import Pine

@Suite("Project Window Session worktree cleanup", .serialized)
@MainActor
struct ProjectWindowSessionWorktreeCleanupTests {
    fileprivate static let noOpProcessRunner: ProcessRunner = { _, _, _, _ in
        ProcessRunResult(
            stdout: "",
            stderr: "",
            exitCode: 0,
            timedOut: false
        )
    }

    @Test("Nested admitted projects block ancestor worktree removal", arguments: ["Sources", "Sources/Nested"])
    func nestedOwnerBlocksRemoval(path: String) async throws {
        let fixture = try WorktreeCleanupFixture()
        defer { fixture.cleanup() }
        let registry = fixture.makeRegistry()
        let worktree = fixture.worktree(for: fixture.firstProject, branch: "pine/agent/codex/nested")
        let nested = worktree.worktreeRoot.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let manager = try #require(registry.projectManager(for: nested))
        let tabs = try #require(manager.paneManager.allTabManagers.first)
        _ = tabs.createUntitledTab(displayName: "Unsaved nested work")
        tabs.updateContent("Unsaved nested work")
        #expect(tabs.tabs.contains { $0.isDirty })
        let result = await registry.withWorktreeRemoval(worktree) {
            Issue.record("Removal admitted with a nested dirty editor")
            return .removed
        }
        #expect(result == .failed(.liveProject))
        #expect(tabs.tabs[0].isDirty)
        #expect(registry.projectManagerIfAdmitted(for: nested) === manager)
    }

    @Test("Quick Terminal ownership survives without any ProjectManager", arguments: [false, true])
    func quickTerminalOwnerBlocksRemoval(pendingStart: Bool) async throws {
        let fixture = try WorktreeCleanupFixture()
        defer { fixture.cleanup() }
        let registry = fixture.makeRegistry()
        let worktree = fixture.worktree(for: fixture.firstProject, branch: "pine/agent/codex/quick")
        let nested = worktree.worktreeRoot.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let controller = QuickTerminalController(settings: QuickTerminalSettings(defaults: fixture.defaults))
        controller.registry = registry
        registry.quickTerminalAgentRouter = controller
        controller.paneState.addTab(workingDirectory: nested)
        let tab = try #require(controller.agentTerminalTabs.first)
        let gate = WorktreeStartValidationGate()
        if pendingStart {
            tab.configureWorkingDirectoryValidation { _ in
                await gate.wait()
                return false
            }
            tab.terminalView.frame = NSRect(x: 0, y: 0, width: 200, height: 100)
            tab.startIfNeeded()
            #expect(tab.isStartValidationPendingForTesting)
        } else {
            tab.agentSession = AgentSession(id: UUID(), agentType: .codex, state: .executing, startedAt: Date())
        }
        #expect(registry.projectManagerIfAdmitted(for: nested) == nil)
        #expect(controller.retainsWorkingDirectory(in: registry.canonicalProjectURL(worktree.worktreeRoot)))
        let result = await registry.withWorktreeRemoval(worktree) {
            Issue.record("Removal admitted with an independent Quick Terminal agent")
            return .removed
        }
        #expect(result == .failed(.liveProject))
        if !pendingStart { #expect(tab.agentSession?.liveness != .terminated) }
        await gate.release()
        controller.shutdown()
    }

    @Test("Shell exit keeps the exact cleanup fence, including after tab removal",
          arguments: [false, true], [false, true])
    func shellExitRetainsUntilCleanupCompletes(removeTab: Bool, cleanupSucceeded: Bool) async throws {
        let fixture = try WorktreeCleanupFixture()
        defer { fixture.cleanup() }
        let registry = fixture.makeRegistry()
        let worktree = fixture.worktree(for: fixture.firstProject, branch: "pine/agent/codex/cleanup")
        let nested = worktree.worktreeRoot.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let controller = QuickTerminalController(settings: QuickTerminalSettings(defaults: fixture.defaults))
        controller.registry = registry
        registry.quickTerminalAgentRouter = controller
        defer { controller.shutdown() }
        let tab = controller.paneState.addTab(workingDirectory: nested)
        let retention = TerminalWorkingDirectoryRetention(canonicalDirectory: registry.canonicalProjectURL(nested))
        // Test teardown only: failed production cleanup must never release this fence.
        defer { retention.finishCleanup(succeeded: true) }
        let enteredCleanup = DispatchSemaphore(value: 0)
        let releaseCleanup = DispatchSemaphore(value: 0)
        defer { releaseCleanup.signal() }
        let processController = TerminalProcessTreeController(retention: retention) {
            enteredCleanup.signal()
            guard releaseCleanup.wait(timeout: .now() + 30) == .success else { return false }
            return cleanupSucceeded
        }
        tab.installProcessTreeControllerForTesting(processController)
        // The shell exits now; its descendant cleanup is deterministically paused.
        tab.processDidTerminate()
        let waitForEntry: @Sendable () -> Bool = {
            enteredCleanup.wait(timeout: .now() + 10) == .success
        }
        let entered = await Task.detached { waitForEntry() }.value
        #expect(entered)
        #expect(!tab.isProcessRunning)
        #expect(tab.requiresWorkingDirectoryRetention)
        #expect(controller.retainsWorkingDirectory(in: registry.canonicalProjectURL(worktree.worktreeRoot)))
        #expect(registry.projectManagerIfAdmitted(for: nested) == nil)
        if removeTab { controller.paneState.removeTab(id: tab.id) }
        let pausedResult = await registry.withWorktreeRemoval(worktree) { .removed }
        #expect(pausedResult == .failed(.liveProject))

        releaseCleanup.signal()
        let completed = await Task.detached {
            processController.waitForTermination(timeout: 10)
        }.value
        #expect(completed == cleanupSucceeded)
        #expect(tab.requiresWorkingDirectoryRetention == !cleanupSucceeded)
        let completedResult = await registry.withWorktreeRemoval(worktree) { .removed }
        #expect(completedResult == (cleanupSucceeded ? .removed : .failed(.liveProject)))
    }

    @Test("Detached process cleanup prevents both explicit and automatic project reclamation",
          arguments: [false, true])
    func detachedCleanupRetainsProjectOwner(automaticReclaim: Bool) throws {
        let fixture = try WorktreeCleanupFixture()
        defer { fixture.cleanup() }
        let registry = fixture.makeRegistry()
        let manager = try #require(registry.projectManager(for: fixture.firstProject))
        let retention = TerminalWorkingDirectoryRetention(
            canonicalDirectory: registry.canonicalProjectURL(fixture.firstProject)
        )
        defer { retention.finishCleanup(succeeded: true) }
        registry.closeProjectWindow(
            fixture.firstProject, expectedManager: manager, expectedWindowGeneration: nil
        )
        #expect(!registry.releaseIdleWorktreeProject(fixture.firstProject))
        registry.runBackgroundReclamationPassForTesting()
        #expect(registry.projectManagerIfAdmitted(for: fixture.firstProject) === manager)
        retention.finishCleanup(succeeded: false)
        #expect(!registry.releaseIdleWorktreeProject(fixture.firstProject))

        retention.finishCleanup(succeeded: true)
        if automaticReclaim {
            registry.runBackgroundReclamationPassForTesting()
        } else {
            #expect(registry.releaseIdleWorktreeProject(fixture.firstProject))
        }
        #expect(registry.projectManagerIfAdmitted(for: fixture.firstProject) == nil)
    }

    @Test("Quick Terminal scope resolution, commit, and validation share the removal fence")
    func quickTerminalAdmissionIsFenced() async throws {
        let fixture = try WorktreeCleanupFixture()
        defer { fixture.cleanup() }
        let registry = fixture.makeRegistry()
        let worktree = fixture.worktree(for: fixture.firstProject, branch: "pine/agent/codex/quick-fence")
        let nested = worktree.worktreeRoot.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let registration = try #require(await registry.resolveQuickTerminalAgentScope(
            workingDirectory: nested, surface: .quickTerminalStandalone
        ))
        let result = await registry.withWorktreeRemoval(worktree) {
            #expect(await registry.resolveQuickTerminalAgentScope(
                workingDirectory: nested, surface: .quickTerminalStandalone
            ) == nil)
            #expect(!(await registry.commitQuickTerminalAgentScope(
                registration, workingDirectory: nested, requestedSurface: .quickTerminalStandalone
            )))
            #expect(!(await registry.validateQuickTerminalAgentScope(registration, workingDirectory: nested)))
            return .failed(.inspectionFailed)
        }
        #expect(result == .failed(.inspectionFailed))
        #expect(await registry.commitQuickTerminalAgentScope(
            registration, workingDirectory: nested, requestedSurface: .quickTerminalStandalone
        ))
    }

    @Test("An admitted worktree cannot lose its directory, even when currently idle")
    func admittedWorktreeBlocksRemoval() async throws {
        let fixture = try WorktreeCleanupFixture()
        defer { fixture.cleanup() }
        let registry = fixture.makeRegistry()
        let worktree = fixture.worktree(for: fixture.firstProject, branch: "pine/agent/codex/live")
        try FileManager.default.createDirectory(at: worktree.worktreeRoot, withIntermediateDirectories: false)
        let manager = try #require(registry.projectManager(for: worktree.worktreeRoot))
        var called = false
        let result = await registry.withWorktreeRemoval(worktree) {
            called = true
            return .removed
        }
        #expect(result == .failed(.liveProject))
        #expect(!called)
        #expect(registry.projectManagerIfAdmitted(for: worktree.worktreeRoot) === manager)
        #expect(FileManager.default.fileExists(atPath: worktree.worktreeRoot.path))
    }

    @Test("Admission and a second removal are fenced until the first removal completes")
    func removalFencesReadmission() async throws {
        let fixture = try WorktreeCleanupFixture()
        defer { fixture.cleanup() }
        let registry = fixture.makeRegistry()
        let worktree = fixture.worktree(for: fixture.firstProject, branch: "pine/agent/codex/reserved")
        try FileManager.default.createDirectory(at: worktree.worktreeRoot, withIntermediateDirectories: false)
        let result = await registry.withWorktreeRemoval(worktree) {
            #expect(registry.projectManager(for: worktree.worktreeRoot) == nil)
            let nested = worktree.worktreeRoot.appendingPathComponent("Sources/Nested", isDirectory: true)
            try? FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            #expect(registry.projectManager(for: nested) == nil)
            let sibling = worktree.worktreeRoot.deletingLastPathComponent().appendingPathComponent(
                worktree.worktreeRoot.lastPathComponent + "-sibling", isDirectory: true
            )
            try? FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: false)
            #expect(registry.projectManager(for: sibling) != nil)
            let second = await registry.withWorktreeRemoval(worktree) {
                Issue.record("A second destructive operation was admitted")
                return .removed
            }
            #expect(second == .failed(.liveProject))
            return .failed(.inspectionFailed)
        }
        #expect(result == .failed(.inspectionFailed))
        #expect(registry.projectManager(for: worktree.worktreeRoot) != nil)
    }

    @Test("Refused worktree admission leaves a persisted, manageable recovery record")
    func refusedAdmissionRetainsRecoveryRecord() async throws {
        let fixture = try WorktreeCleanupFixture()
        defer { fixture.cleanup() }
        let registry = fixture.makeRegistry()
        let session = ProjectWindowSession(initialProjectURL: fixture.firstProject, defaults: fixture.defaults)
        let worktree = fixture.worktree(for: fixture.firstProject, branch: "pine/agent/codex/refused")
        session.retainWorktreeForRecovery(worktree)
        #expect(await registry.projectManager(for: worktree) == nil)
        let reloaded = ProjectWindowSession(initialProjectURL: fixture.firstProject, defaults: fixture.defaults)
        #expect(reloaded.allManagedWorktrees == [worktree])
        #expect(session.allManagedWorktrees == [worktree])
        #expect(reloaded.activeProjectURL == fixture.firstProject.standardizedFileURL)
    }

    @Test("Closing a project reports every worktree it left on disk")
    func closingReportsEveryRetainedWorktree() async throws {
        let fixture = try WorktreeCleanupFixture()
        defer { fixture.cleanup() }
        let registry = fixture.makeRegistry()
        _ = try #require(registry.projectManager(for: fixture.firstProject))
        let session = ProjectWindowSession(
            initialProjectURL: fixture.firstProject,
            defaults: fixture.defaults
        )
        await session.openProject(fixture.secondProject, registry: registry)

        let departing = [
            fixture.worktree(
                for: fixture.firstProject,
                branch: "pine/agent/codex/11111111"
            ),
            fixture.worktree(
                for: fixture.firstProject,
                branch: "pine/agent/claude/22222222"
            ),
        ]
        let staying = fixture.worktree(
            for: fixture.secondProject,
            branch: "pine/agent/codex/33333333"
        )
        for worktree in departing + [staying] {
            session.adoptWorktreeForTesting(worktree)
        }
        let before = Set(session.managedWorktrees.keys)

        #expect(
            await session.closeProject(
                fixture.firstProject,
                registry: registry
            )
        )

        let report = try #require(session.retainedWorktreeReport)
        let dropped = before.subtracting(session.managedWorktrees.keys)
        // The exact acceptance criterion: nothing the close removed from the
        // record may be missing from what it told the user about.
        #expect(dropped == report.worktreeRoots)
        #expect(dropped.count == 2)
        #expect(report.branchNames == [
            "pine/agent/claude/22222222",
            "pine/agent/codex/11111111",
        ])
        #expect(report.managedRoot == fixture.managedRoot)
        #expect(report.projectName == "First Project")
        #expect(
            session.managedWorktrees[
                staying.worktreeRoot.standardizedFileURL
            ] == staying
        )
    }

    @Test("The kept-worktrees message names the branches and the folder")
    func retainedMessageNamesBranchesAndFolder() throws {
        let fixture = try WorktreeCleanupFixture()
        defer { fixture.cleanup() }
        let worktree = fixture.worktree(
            for: fixture.firstProject,
            branch: "pine/agent/codex/44444444"
        )
        let report = RetainedAgentWorktreeReport(
            projectName: "First Project",
            managedRoot: fixture.managedRoot,
            worktrees: [worktree]
        )

        let message = Strings.projectSwitcherWorktreesKeptText(
            report.branchNames.joined(separator: ", "),
            report.managedRoot.path,
            locale: Locale(identifier: "en")
        )

        #expect(message.contains("pine/agent/codex/44444444"))
        #expect(message.contains(fixture.managedRoot.path))
    }

    @Test("Closing a project with no worktrees reports nothing")
    func closingWithoutWorktreesReportsNothing() async throws {
        let fixture = try WorktreeCleanupFixture()
        defer { fixture.cleanup() }
        let registry = fixture.makeRegistry()
        _ = try #require(registry.projectManager(for: fixture.firstProject))
        let session = ProjectWindowSession(
            initialProjectURL: fixture.firstProject,
            defaults: fixture.defaults
        )
        await session.openProject(fixture.secondProject, registry: registry)

        #expect(
            await session.closeProject(
                fixture.firstProject,
                registry: registry
            )
        )

        #expect(session.retainedWorktreeReport == nil)
    }

    @Test("A refused close leaves the record and the report untouched")
    func refusedCloseReportsNothing() async throws {
        let fixture = try WorktreeCleanupFixture()
        defer { fixture.cleanup() }
        let registry = fixture.makeRegistry()
        _ = try #require(registry.projectManager(for: fixture.firstProject))
        let session = ProjectWindowSession(
            initialProjectURL: fixture.firstProject,
            defaults: fixture.defaults
        )
        let worktree = fixture.worktree(
            for: fixture.firstProject,
            branch: "pine/agent/codex/55555555"
        )
        session.adoptWorktreeForTesting(worktree)

        // The last project cannot be closed — the window closes instead.
        #expect(
            await session.closeProject(
                fixture.firstProject,
                registry: registry
            ) == false
        )

        #expect(session.retainedWorktreeReport == nil)
        #expect(session.managedWorktrees.count == 1)
    }

    @Test("Acknowledging the report clears it without touching the record")
    func acknowledgingClearsTheReport() async throws {
        let fixture = try WorktreeCleanupFixture()
        defer { fixture.cleanup() }
        let registry = fixture.makeRegistry()
        _ = try #require(registry.projectManager(for: fixture.firstProject))
        let session = ProjectWindowSession(
            initialProjectURL: fixture.firstProject,
            defaults: fixture.defaults
        )
        await session.openProject(fixture.secondProject, registry: registry)
        session.adoptWorktreeForTesting(fixture.worktree(
            for: fixture.firstProject,
            branch: "pine/agent/codex/66666666"
        ))

        _ = await session.closeProject(
            fixture.firstProject,
            registry: registry
        )
        #expect(session.retainedWorktreeReport != nil)
        session.acknowledgeRetainedWorktrees()

        #expect(session.retainedWorktreeReport == nil)
    }

    @Test("Forgetting a removed worktree drops it and survives a reload")
    func forgetWorktreeDropsTheRecordAndPersists() async throws {
        let fixture = try WorktreeCleanupFixture()
        defer { fixture.cleanup() }
        let registry = fixture.makeRegistry()
        _ = try #require(registry.projectManager(for: fixture.firstProject))
        let session = ProjectWindowSession(
            initialProjectURL: fixture.firstProject,
            defaults: fixture.defaults
        )
        let removed = fixture.worktree(
            for: fixture.firstProject,
            branch: "pine/agent/codex/77777777"
        )
        let kept = fixture.worktree(
            for: fixture.firstProject,
            branch: "pine/agent/codex/88888888"
        )
        session.adoptWorktreeForTesting(removed)
        session.adoptWorktreeForTesting(kept)

        await session.forgetWorktree(removed, registry: registry)

        #expect(
            Set(session.managedWorktrees.keys)
                == [kept.worktreeRoot.standardizedFileURL]
        )
        // Persisted, not just in memory: a window reopened after the removal
        // must not resurrect a directory that no longer exists. Nothing else
        // in this test writes state — no `windowDidClose`, no activation — so
        // the reload sees exactly what `forgetWorktree` chose to save, and an
        // unsaved removal reads back as no state at all.
        let reloaded = ProjectWindowSession(
            initialProjectURL: fixture.firstProject,
            defaults: fixture.defaults
        )
        #expect(
            Set(reloaded.managedWorktrees.keys)
                == [kept.worktreeRoot.standardizedFileURL]
        )
    }

    @Test("Forgetting a worktree this window never held changes nothing")
    func forgetUnknownWorktreeIsANoOp() async throws {
        let fixture = try WorktreeCleanupFixture()
        defer { fixture.cleanup() }
        let registry = fixture.makeRegistry()
        _ = try #require(registry.projectManager(for: fixture.firstProject))
        let session = ProjectWindowSession(
            initialProjectURL: fixture.firstProject,
            defaults: fixture.defaults
        )
        let kept = fixture.worktree(
            for: fixture.firstProject,
            branch: "pine/agent/codex/99999999"
        )
        session.adoptWorktreeForTesting(kept)
        let foreign = fixture.worktree(
            for: fixture.secondProject,
            branch: "pine/agent/codex/aaaabbbb"
        )

        await session.forgetWorktree(foreign, registry: registry)

        #expect(
            Set(session.managedWorktrees.keys)
                == [kept.worktreeRoot.standardizedFileURL]
        )
    }

    @Test("The manager lists every worktree the window holds")
    func managerListsEveryWorktree() throws {
        let fixture = try WorktreeCleanupFixture()
        defer { fixture.cleanup() }
        let session = ProjectWindowSession(
            initialProjectURL: fixture.firstProject,
            defaults: fixture.defaults
        )
        let first = fixture.worktree(
            for: fixture.firstProject,
            branch: "pine/agent/codex/ccccdddd"
        )
        let second = fixture.worktree(
            for: fixture.firstProject,
            branch: "pine/agent/claude/eeeeffff"
        )
        session.adoptWorktreeForTesting(first)
        session.adoptWorktreeForTesting(second)

        #expect(session.allManagedWorktrees.map(\.branchName) == [
            "pine/agent/claude/eeeeffff",
            "pine/agent/codex/ccccdddd",
        ])
    }
}

private actor WorktreeStartValidationGate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        released = true
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }
}

@MainActor
private final class WorktreeCleanupFixture {
    let root: URL
    let firstProject: URL
    let secondProject: URL
    let managedRoot: URL
    let defaults: UserDefaults
    private let suiteName: String

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "Pine-WorktreeCleanup-\(UUID().uuidString)",
                isDirectory: true
            )
        firstProject = root.appendingPathComponent(
            "First Project",
            isDirectory: true
        )
        secondProject = root.appendingPathComponent(
            "Second Project",
            isDirectory: true
        )
        managedRoot = root.appendingPathComponent("Managed", isDirectory: true)
        for directory in [firstProject, secondProject, managedRoot] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        suiteName = "ProjectWindowSessionWorktreeCleanupTests.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
    }

    func makeRegistry() -> ProjectRegistry {
        ProjectRegistry(
            defaults: defaults,
            agentDetectionProcessRunner:
                ProjectWindowSessionWorktreeCleanupTests.noOpProcessRunner,
            agentDetectionPollInterval: 3_600,
            backgroundReclamationInterval: .seconds(3_600)
        )
    }

    func worktree(
        for project: URL,
        branch: String
    ) -> AgentManagedWorktree {
        let taskID = UUID()
        return AgentManagedWorktree(
            taskID: taskID,
            repositoryRoot: project.standardizedFileURL,
            managedRoot: managedRoot.standardizedFileURL,
            worktreeRoot: managedRoot.appendingPathComponent(
                taskID.uuidString.lowercased(),
                isDirectory: true
            ).standardizedFileURL,
            branchName: branch,
            baseCommit: String(repeating: "a", count: 40),
            repositoryProof: RecentAgentTaskRepositoryProof(
                commonDirectoryDevice: 1,
                commonDirectoryInode: 2,
                commonDirectoryGeneration: 3,
                commonDirectoryBirthSeconds: 4,
                commonDirectoryBirthNanoseconds: 5
            )
        )
    }

    func cleanup() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }
}
