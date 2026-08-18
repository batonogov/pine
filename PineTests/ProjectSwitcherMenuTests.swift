//
//  ProjectSwitcherMenuTests.swift
//  PineTests
//

import Foundation
import Testing

@testable import Pine

@Suite("Project Switcher Menu Layout")
struct ProjectSwitcherMenuLayoutTests {
    private func group(
        _ path: String,
        worktrees: Int = 0
    ) -> ProjectWindowGroup {
        let root = URL(fileURLWithPath: path, isDirectory: true)
        let proof = RecentAgentTaskRepositoryProof(
            commonDirectoryDevice: 1,
            commonDirectoryInode: 2,
            commonDirectoryGeneration: 3,
            commonDirectoryBirthSeconds: 4,
            commonDirectoryBirthNanoseconds: 5
        )
        return ProjectWindowGroup(
            projectURL: root,
            worktrees: (0..<worktrees).map { index in
                AgentManagedWorktree(
                    taskID: UUID(),
                    repositoryRoot: root,
                    managedRoot: root.appendingPathComponent("managed"),
                    worktreeRoot: root
                        .appendingPathComponent("managed/\(index)"),
                    branchName: "pine/agent/codex/\(index)",
                    baseCommit: String(repeating: "a", count: 40),
                    repositoryProof: proof
                )
            }
        )
    }

    @Test("the first group never draws a leading divider")
    func firstGroupHasNoDivider() {
        let groups = [group("/a", worktrees: 2), group("/b", worktrees: 2)]

        #expect(
            ProjectSwitcherMenuLayout.needsDivider(before: 0, in: groups)
                == false
        )
    }

    @Test("plain projects run together with no dividers between them")
    func plainProjectsAreNotSeparated() {
        let groups = [group("/a"), group("/b"), group("/c"), group("/d")]

        for index in groups.indices {
            #expect(
                ProjectSwitcherMenuLayout.needsDivider(
                    before: index,
                    in: groups
                ) == false
            )
        }
    }

    @Test("a group with worktrees is fenced off on both sides")
    func worktreeGroupIsFenced() {
        let groups = [group("/a"), group("/b", worktrees: 1), group("/c")]

        // Before the worktree group, because it is about to open a block.
        #expect(ProjectSwitcherMenuLayout.needsDivider(before: 1, in: groups))
        // And before what follows it, because that block just closed.
        #expect(ProjectSwitcherMenuLayout.needsDivider(before: 2, in: groups))
    }

    @Test("adjacent worktree groups stay separated from each other")
    func adjacentWorktreeGroupsAreSeparated() {
        let groups = [
            group("/a", worktrees: 1),
            group("/b", worktrees: 3),
        ]

        #expect(ProjectSwitcherMenuLayout.needsDivider(before: 1, in: groups))
    }

    @Test("out-of-range indices ask for nothing")
    func outOfRangeIndicesAreSafe() {
        let groups = [group("/a", worktrees: 1), group("/b", worktrees: 1)]

        #expect(
            ProjectSwitcherMenuLayout.needsDivider(before: 2, in: groups)
                == false
        )
        #expect(
            ProjectSwitcherMenuLayout.needsDivider(before: 99, in: groups)
                == false
        )
        #expect(
            ProjectSwitcherMenuLayout.needsDivider(before: -1, in: groups)
                == false
        )
        #expect(
            ProjectSwitcherMenuLayout.needsDivider(before: 0, in: [])
                == false
        )
    }
}

@Suite("Project Switcher Naming", .serialized)
@MainActor
struct ProjectSwitcherNamingTests {
    private static let noOpProcessRunner: ProcessRunner = { _, _, _, _ in
        ProcessRunResult(
            stdout: "",
            stderr: "",
            exitCode: 0,
            timedOut: false
        )
    }

    @Test("two same-named checkouts in one window read differently")
    func sameNamedProjectsAreDistinguishable() async throws {
        // Resolve `/var` → `/private/var` up front: `openProject` canonicalizes
        // through `resolvingSymlinksInPath`, and the session would then key its
        // names by paths the test never mentions.
        let root = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent(
                "Pine-SwitcherNaming-\(UUID().uuidString)",
                isDirectory: true
            )
        let first = root.appendingPathComponent(
            "project1/infra",
            isDirectory: true
        )
        let second = root.appendingPathComponent(
            "project2/infra",
            isDirectory: true
        )
        let solo = root.appendingPathComponent(
            "project1/backend",
            isDirectory: true
        )
        for url in [first, second, solo] {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true
            )
        }
        let suiteName = "ProjectSwitcherNamingTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }
        let registry = ProjectRegistry(
            defaults: defaults,
            agentDetectionProcessRunner: Self.noOpProcessRunner,
            agentDetectionPollInterval: 3_600,
            backgroundReclamationInterval: .seconds(3_600)
        )

        let session = ProjectWindowSession(
            initialProjectURL: first,
            defaults: defaults
        )

        // One project in the window: nothing to disambiguate against.
        #expect(session.displayName(for: first) == "infra")
        #expect(session.activeProjectDisplayName == "infra")

        await session.openProject(second, registry: registry)
        await session.openProject(solo, registry: registry)

        #expect(session.displayName(for: first) == "project1/infra")
        #expect(session.displayName(for: second) == "project2/infra")
        // The uncontested name stays short even while its neighbours grow.
        #expect(session.displayName(for: solo) == "backend")
        // The title bar follows the switcher, so the window is identifiable in
        // the Window menu and Mission Control too.
        #expect(session.activeProjectDisplayName == "backend")

        await session.activate(second, registry: registry)

        #expect(session.activeProjectDisplayName == "project2/infra")
        #expect(session.activeDisplayName == "project2/infra")

        // A URL this window does not hold has nothing to collide with.
        #expect(
            session.displayName(
                for: root.appendingPathComponent("elsewhere/infra")
            ) == "infra"
        )
    }
}
