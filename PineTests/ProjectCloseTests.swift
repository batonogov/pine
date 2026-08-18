//
//  ProjectCloseTests.swift
//  PineTests
//
//  Taking one project out of a window that holds several.
//

import AppKit
import Foundation
import Testing

@testable import Pine

@Suite("Project close", .serialized)
@MainActor
struct ProjectCloseTests {
    @Test("closing the shown project hands the window to its neighbour")
    func closingActiveProjectSwitchesToNeighbour() async throws {
        let fixture = try ProjectCloseFixture()
        defer { fixture.cleanup() }
        let registry = fixture.makeRegistry()
        let session = fixture.makeSession(initial: fixture.projectA)
        await session.openProject(fixture.projectB, registry: registry)
        #expect(session.activeProjectURL == fixture.canonical(fixture.projectB))

        let didClose = await session.closeProject(
            fixture.projectB,
            registry: registry
        )

        #expect(didClose)
        #expect(session.projectURLs == [fixture.canonical(fixture.projectA)])
        #expect(session.activeProjectURL == fixture.canonical(fixture.projectA))
    }

    @Test("closing a project that is not on screen leaves the view alone")
    func closingBackgroundProjectKeepsActive() async throws {
        let fixture = try ProjectCloseFixture()
        defer { fixture.cleanup() }
        let registry = fixture.makeRegistry()
        let session = fixture.makeSession(initial: fixture.projectA)
        await session.openProject(fixture.projectB, registry: registry)
        await session.activate(fixture.projectA, registry: registry)

        let didClose = await session.closeProject(
            fixture.projectB,
            registry: registry
        )

        #expect(didClose)
        #expect(session.activeProjectURL == fixture.canonical(fixture.projectA))
        #expect(session.projectURLs == [fixture.canonical(fixture.projectA)])
    }

    @Test("closing is not destructive: the project keeps running in background")
    func closingIsNotDestructive() async throws {
        let fixture = try ProjectCloseFixture()
        defer { fixture.cleanup() }
        let registry = fixture.makeRegistry()
        let session = fixture.makeSession(initial: fixture.projectA)
        await session.openProject(fixture.projectB, registry: registry)
        let canonicalB = fixture.canonical(fixture.projectB)
        let manager = try #require(registry.openProjects[canonicalB])
        let pane = manager.paneManager.createTerminalPaneAtBottom(
            workingDirectory: fixture.projectB
        )
        let state = try #require(manager.paneManager.terminalState(for: pane))
        let terminalCount = state.terminalTabs.count
        #expect(terminalCount > 0)

        _ = await session.closeProject(fixture.projectB, registry: registry)

        // Same manager, still retained, just suspended — exactly what closing
        // the window does. Terminals and their processes are untouched.
        #expect(registry.openProjects[canonicalB] === manager)
        #expect(registry.backgroundProjects.contains(canonicalB))
        #expect(
            manager.paneManager.terminalState(for: pane)?.terminalTabs.count
                == terminalCount
        )
    }

    @Test("a closed project is released, not pinned by a stale lease")
    func closingReleasesBackgroundLease() async throws {
        let fixture = try ProjectCloseFixture()
        defer { fixture.cleanup() }
        let registry = fixture.makeRegistry()
        let session = fixture.makeSession(initial: fixture.projectA)
        await session.openProject(fixture.projectB, registry: registry)
        // Switching away takes a presentation lease on B; closing it must
        // hand that lease back, or background reclamation can never collect
        // the project for the rest of the session.
        await session.activate(fixture.projectA, registry: registry)
        let canonicalB = fixture.canonical(fixture.projectB)

        _ = await session.closeProject(fixture.projectB, registry: registry)
        registry.runBackgroundReclamationPassForTesting()

        #expect(registry.openProjects[canonicalB] == nil)
    }

    @Test("agent worktrees leave with the project they hang off")
    func closingTakesWorktreesAlong() async throws {
        let fixture = try ProjectCloseFixture()
        defer { fixture.cleanup() }
        let registry = fixture.makeRegistry()
        let session = fixture.makeSession(initial: fixture.projectA)
        await session.openProject(fixture.projectB, registry: registry)
        let worktreeRoot = try fixture.makeDirectory("managed/b-agent")
        session.adoptWorktreeForTesting(fixture.makeWorktree(
            repositoryRoot: fixture.canonical(fixture.projectB),
            worktreeRoot: worktreeRoot
        ))
        let survivor = try fixture.makeDirectory("managed/a-agent")
        session.adoptWorktreeForTesting(fixture.makeWorktree(
            repositoryRoot: fixture.canonical(fixture.projectA),
            worktreeRoot: survivor
        ))

        _ = await session.closeProject(fixture.projectB, registry: registry)

        #expect(session.managedWorktrees[worktreeRoot.standardizedFileURL] == nil)
        // A worktree belonging to a project that stayed is untouched.
        #expect(session.managedWorktrees[survivor.standardizedFileURL] != nil)
    }

    @Test("the window moves to the next project, or the previous one if last")
    func successorPicksNeighbour() async throws {
        let fixture = try ProjectCloseFixture()
        defer { fixture.cleanup() }
        let registry = fixture.makeRegistry()
        let projectC = try fixture.makeDirectory("projectC")
        let session = fixture.makeSession(initial: fixture.projectA)
        await session.openProject(fixture.projectB, registry: registry)
        await session.openProject(projectC, registry: registry)

        // Middle of the list: the window moves forward.
        await session.activate(fixture.projectB, registry: registry)
        _ = await session.closeProject(fixture.projectB, registry: registry)
        #expect(session.activeProjectURL == fixture.canonical(projectC))

        // Last in the list: there is no next, so it falls back to the one
        // before rather than leaving the window pointed at nothing.
        _ = await session.closeProject(projectC, registry: registry)
        #expect(session.activeProjectURL == fixture.canonical(fixture.projectA))
        #expect(session.projectURLs == [fixture.canonical(fixture.projectA)])
    }

    @Test("the last project cannot be closed; that is a window close")
    func lastProjectIsRefused() async throws {
        let fixture = try ProjectCloseFixture()
        defer { fixture.cleanup() }
        let registry = fixture.makeRegistry()
        let session = fixture.makeSession(initial: fixture.projectA)

        #expect(session.canCloseProject(fixture.projectA) == false)
        let didClose = await session.closeProject(
            fixture.projectA,
            registry: registry
        )

        #expect(didClose == false)
        #expect(session.projectURLs == [fixture.canonical(fixture.projectA)])
    }

    @Test("a project this window never held cannot be closed through it")
    func foreignProjectIsRefused() async throws {
        let fixture = try ProjectCloseFixture()
        defer { fixture.cleanup() }
        let registry = fixture.makeRegistry()
        let session = fixture.makeSession(initial: fixture.projectA)
        await session.openProject(fixture.projectB, registry: registry)
        let foreign = try fixture.makeDirectory("elsewhere")

        #expect(session.canCloseProject(foreign) == false)
        #expect(
            await session.closeProject(foreign, registry: registry) == false
        )
        #expect(session.projectURLs.count == 2)
    }

    @Test("closing the scene's own project does not resurrect it on relaunch")
    func closedAnchorStaysClosed() async throws {
        let fixture = try ProjectCloseFixture()
        defer { fixture.cleanup() }
        let registry = fixture.makeRegistry()
        let session = fixture.makeSession(initial: fixture.projectA)
        await session.openProject(fixture.projectB, registry: registry)
        #expect(session.sceneProjectURL == fixture.canonical(fixture.projectA))

        _ = await session.closeProject(fixture.projectA, registry: registry)

        // The scene is keyed by A, so a reopening window asks for A again.
        let reopened = fixture.makeSession(initial: fixture.projectA)
        #expect(reopened.projectURLs == [fixture.canonical(fixture.projectB)])
        #expect(reopened.activeProjectURL == fixture.canonical(fixture.projectB))
    }

    @Test("state written before project closing existed still restores")
    func legacyPersistedStateDecodes() throws {
        let fixture = try ProjectCloseFixture()
        defer { fixture.cleanup() }
        let canonicalA = fixture.canonical(fixture.projectA)
        let canonicalB = fixture.canonical(fixture.projectB)
        // Exactly the shape Pine wrote before `closedAnchor` was added.
        let legacy = """
        {"version":1,\
        "projectURLs":["\(canonicalA.absoluteString)",\
        "\(canonicalB.absoluteString)"],\
        "worktrees":[],\
        "activeURL":"\(canonicalB.absoluteString)"}
        """
        fixture.writePersistedState(
            Data(legacy.utf8),
            anchor: canonicalA
        )

        let session = fixture.makeSession(initial: fixture.projectA)

        #expect(session.projectURLs == [canonicalA, canonicalB])
    }

    @Test("an unsaved file blocks the close until the user decides")
    func unsavedChangesGateTheClose() async throws {
        let fixture = try ProjectCloseFixture()
        defer { fixture.cleanup() }
        let registry = fixture.makeRegistry()
        let manager = try #require(
            registry.projectManager(for: fixture.projectA)
        )
        fixture.appendDirtyTab(
            to: manager.primaryTabManager,
            path: fixture.projectA.appendingPathComponent("note.txt").path
        )
        #expect(manager.allDirtyTabs.isEmpty == false)

        let cancelled = await ProjectCloseConfirmation.confirm(
            projectManager: manager,
            context: .unscoped,
            presentAlert: { _, _, _, _ in .alertThirdButtonReturn }
        )
        #expect(cancelled == .cancel)

        let failedSave = await ProjectCloseConfirmation.confirm(
            projectManager: manager,
            context: .unscoped,
            presentAlert: { _, _, _, _ in .alertFirstButtonReturn },
            saveAll: { _, _ in false }
        )
        #expect(failedSave == .cancel)

        let discarded = await ProjectCloseConfirmation.confirm(
            projectManager: manager,
            context: .unscoped,
            presentAlert: { _, _, _, _ in .alertSecondButtonReturn }
        )
        guard case .approve(let authorization) = discarded else {
            Issue.record("Discard should approve the close")
            return
        }
        #expect(authorization != nil)
    }

    @Test("a file dirtied while the sheet is up cancels the close")
    func editDuringSheetCancels() async throws {
        let fixture = try ProjectCloseFixture()
        defer { fixture.cleanup() }
        let registry = fixture.makeRegistry()
        let manager = try #require(
            registry.projectManager(for: fixture.projectA)
        )
        let tabManager = manager.primaryTabManager
        fixture.appendDirtyTab(
            to: tabManager,
            path: fixture.projectA.appendingPathComponent("first.txt").path
        )

        let decision = await ProjectCloseConfirmation.confirm(
            projectManager: manager,
            context: .unscoped,
            presentAlert: { _, _, _, _ in
                // The user agreed to discard one file; a second one became
                // dirty before the sheet returned and was never covered by
                // that answer.
                fixture.appendDirtyTab(
                    to: tabManager,
                    path: fixture.projectA
                        .appendingPathComponent("second.txt").path
                )
                return .alertSecondButtonReturn
            }
        )

        #expect(decision == .cancel)
    }

    @Test("a clean project approves with nothing to discard")
    func cleanProjectApproves() async throws {
        let fixture = try ProjectCloseFixture()
        defer { fixture.cleanup() }
        let registry = fixture.makeRegistry()
        let manager = try #require(
            registry.projectManager(for: fixture.projectA)
        )

        let decision = await ProjectCloseConfirmation.confirm(
            projectManager: manager,
            context: .unscoped,
            presentAlert: { _, _, _, _ in
                Issue.record("A clean project must not ask anything")
                return .alertThirdButtonReturn
            }
        )

        #expect(decision == .approve(discard: nil))
    }
}

// MARK: - Fixture

@MainActor
private final class ProjectCloseFixture {
    let root: URL
    let projectA: URL
    let projectB: URL
    private let suiteName: String
    private let defaults: UserDefaults

    init() throws {
        root = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent(
                "PineProjectClose-\(UUID().uuidString)",
                isDirectory: true
            )
        projectA = root.appendingPathComponent("projectA", isDirectory: true)
        projectB = root.appendingPathComponent("projectB", isDirectory: true)
        for url in [projectA, projectB] {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true
            )
        }
        suiteName = "ProjectCloseTests.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
    }

    func makeRegistry() -> ProjectRegistry {
        ProjectRegistry(
            defaults: defaults,
            agentDetectionProcessRunner: { _, _, _, _ in
                ProcessRunResult(
                    stdout: "",
                    stderr: "",
                    exitCode: 0,
                    timedOut: false
                )
            },
            agentDetectionPollInterval: 3_600,
            backgroundReclamationInterval: .seconds(3_600)
        )
    }

    func makeSession(initial: URL) -> ProjectWindowSession {
        ProjectWindowSession(initialProjectURL: initial, defaults: defaults)
    }

    /// Adds an editor tab whose content differs from disk, without touching
    /// the filesystem — the confirmation only ever reads dirty state.
    func appendDirtyTab(to manager: TabManager, path: String) {
        let tab = EditorTab(
            url: URL(fileURLWithPath: path),
            content: "edited",
            savedContent: "saved"
        )
        manager.tabs.append(tab)
        manager.activeTabID = tab.id
    }

    func canonical(_ url: URL) -> URL {
        ProjectRegistry.canonicalProjectURL(url).standardizedFileURL
    }

    func makeDirectory(_ relativePath: String) throws -> URL {
        let url = root.appendingPathComponent(relativePath, isDirectory: true)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }

    func makeWorktree(
        repositoryRoot: URL,
        worktreeRoot: URL
    ) -> AgentManagedWorktree {
        AgentManagedWorktree(
            taskID: UUID(),
            repositoryRoot: repositoryRoot.standardizedFileURL,
            managedRoot: worktreeRoot.deletingLastPathComponent(),
            worktreeRoot: worktreeRoot.standardizedFileURL,
            branchName: "pine/agent/codex/close",
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

    /// Writes a session state straight into defaults, so a state shaped by an
    /// older build can be restored without going through today's encoder.
    func writePersistedState(_ data: Data, anchor: URL) {
        defaults.set(data, forKey: ProjectWindowSession.persistenceKeyForTesting(
            for: anchor
        ))
    }

    func cleanup() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }
}
