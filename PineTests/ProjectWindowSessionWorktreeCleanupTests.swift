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
