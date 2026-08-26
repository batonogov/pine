//
//  ProjectWindowSwitchOrderTests.swift
//  PineTests
//
//  Issue #1525: switching the window's active project/worktree has to be
//  reachable from the menu bar, which means the switcher's visual order needs
//  a headless, testable form the Next/Previous commands can walk.
//

import Foundation
import Testing

@testable import Pine

@Suite("Project Window Switch Order")
struct ProjectWindowSwitchOrderTests {
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

    private func url(_ path: String) -> URL {
        URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Worktree roots are built by `appendingPathComponent`, which produces a
    /// URL without the directory marker — and a URL with a trailing slash is
    /// not equal to one without.
    private func worktreeURL(_ project: String, _ index: Int) -> URL {
        url(project).appendingPathComponent("managed/\(index)")
    }

    @Test("targets flatten each project ahead of its own worktrees")
    func targetsMatchTheSwitcherReadingOrder() {
        let groups = [group("/a", worktrees: 2), group("/b")]

        #expect(
            ProjectWindowSwitchOrder.targets(in: groups) == [
                url("/a"),
                worktreeURL("/a", 0),
                worktreeURL("/a", 1),
                url("/b"),
            ]
        )
    }

    @Test("next steps to the following row and wraps at the end")
    func nextWalksForwardAndWraps() {
        let targets = ProjectWindowSwitchOrder.targets(
            in: [group("/a", worktrees: 1), group("/b")]
        )

        #expect(
            ProjectWindowSwitchOrder.neighbour(
                of: url("/a"),
                in: targets,
                direction: .next
            ) == worktreeURL("/a", 0)
        )
        #expect(
            ProjectWindowSwitchOrder.neighbour(
                of: url("/b"),
                in: targets,
                direction: .next
            ) == url("/a")
        )
    }

    @Test("previous steps to the preceding row and wraps at the start")
    func previousWalksBackwardAndWraps() {
        let targets = ProjectWindowSwitchOrder.targets(
            in: [group("/a", worktrees: 1), group("/b")]
        )

        #expect(
            ProjectWindowSwitchOrder.neighbour(
                of: worktreeURL("/a", 0),
                in: targets,
                direction: .previous
            ) == url("/a")
        )
        #expect(
            ProjectWindowSwitchOrder.neighbour(
                of: url("/a"),
                in: targets,
                direction: .previous
            ) == url("/b")
        )
    }

    /// A window showing one project has nowhere to go. Wrapping would
    /// "switch" to the row already on screen, and the menu item that reports
    /// itself enabled would do nothing when clicked.
    @Test("a lone target has no neighbour in either direction")
    func singleTargetHasNoNeighbour() {
        let targets = ProjectWindowSwitchOrder.targets(in: [group("/a")])

        #expect(
            ProjectWindowSwitchOrder.neighbour(
                of: url("/a"),
                in: targets,
                direction: .next
            ) == nil
        )
        #expect(
            ProjectWindowSwitchOrder.neighbour(
                of: url("/a"),
                in: targets,
                direction: .previous
            ) == nil
        )
    }

    /// The active URL can disappear between a menu opening and the command
    /// firing — a worktree closed from another surface, say. Guessing a
    /// starting row would switch the window somewhere the user never asked
    /// for, so an unknown origin yields nothing.
    @Test("an origin outside the window yields no neighbour")
    func unknownOriginYieldsNothing() {
        let targets = ProjectWindowSwitchOrder.targets(
            in: [group("/a"), group("/b")]
        )

        #expect(
            ProjectWindowSwitchOrder.neighbour(
                of: url("/elsewhere"),
                in: targets,
                direction: .next
            ) == nil
        )
    }

    /// The session stores standardized paths; a caller handing back a URL with
    /// a trailing slash or a `.` segment still means the same row.
    @Test("a non-standardized origin still finds its row")
    func nonStandardizedOriginIsMatched() {
        let targets = ProjectWindowSwitchOrder.targets(
            in: [group("/a"), group("/b")]
        )

        #expect(
            ProjectWindowSwitchOrder.neighbour(
                of: URL(fileURLWithPath: "/a/./", isDirectory: true),
                in: targets,
                direction: .next
            ) == url("/b")
        )
    }
}
