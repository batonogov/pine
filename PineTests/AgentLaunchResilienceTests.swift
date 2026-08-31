//
//  AgentLaunchResilienceTests.swift
//  PineTests
//
//  Issue #1590: the agent launch chain used to die inside a fixed
//  three-second PTY budget and evict healthy worktrees from the window
//  session after a single refused activation. These tests pin the wait
//  behaviour, the fast-fail on deterministic dead ends, and the retention
//  rule for worktrees whose root is still on disk.
//

import AppKit
import CryptoKit
import Foundation
import Testing

@testable import Pine

@Suite("Agent launch resilience")
struct AgentLaunchResilienceTests {

    private static func claudeDescriptor() throws -> AgentDescriptor {
        try #require(TerminalManager.exactAgentLaunchDescriptor(for: "claude"))
    }

    private static func makeManager() -> (PaneManager, TerminalManager) {
        let paneManager = PaneManager()
        let manager = TerminalManager()
        manager.paneManager = paneManager
        return (paneManager, manager)
    }

    // MARK: - Admission refusal is observable on the tab

    @Test("a refused working-directory admission marks the tab and never spawns")
    @MainActor
    func refusedAdmissionMarksTabWithoutSpawning() async throws {
        let (paneManager, manager) = Self.makeManager()
        // A nil working directory bypasses admission validation entirely;
        // the validator only runs for a tab that names its directory.
        manager.createTerminalTab(
            relativeTo: paneManager.activePaneID,
            workingDirectory: FileManager.default.temporaryDirectory
        )
        let tab = try #require(manager.allTerminalTabs.first)

        tab.configureWorkingDirectoryValidation { _ in false }
        tab.terminalView.frame = NSRect(x: 0, y: 0, width: 640, height: 320)
        tab.startIfNeeded()
        for _ in 0..<200 where tab.isStartValidationPendingForTesting {
            try? await Task.sleep(for: .milliseconds(2))
        }

        #expect(tab.processStartAdmissionRefused)
        #expect(!tab.isProcessRunning)
        manager.terminateAll()
    }

    @Test("a later successful start clears the refusal mark")
    @MainActor
    func successfulStartClearsRefusalMark() async throws {
        let (paneManager, manager) = Self.makeManager()
        // A nil working directory bypasses admission validation entirely;
        // the validator only runs for a tab that names its directory.
        manager.createTerminalTab(
            relativeTo: paneManager.activePaneID,
            workingDirectory: FileManager.default.temporaryDirectory
        )
        let tab = try #require(manager.allTerminalTabs.first)

        tab.configureWorkingDirectoryValidation { _ in false }
        tab.terminalView.frame = NSRect(x: 0, y: 0, width: 640, height: 320)
        tab.startIfNeeded()
        for _ in 0..<200 where tab.isStartValidationPendingForTesting {
            try? await Task.sleep(for: .milliseconds(2))
        }
        #expect(tab.processStartAdmissionRefused)

        // A relayout re-runs `startIfNeeded`; an admitting validator now
        // lets the shell through and the mark must not outlive it.
        tab.configureWorkingDirectoryValidation { _ in true }
        tab.startIfNeeded()
        for _ in 0..<200 where tab.isStartValidationPendingForTesting {
            try? await Task.sleep(for: .milliseconds(2))
        }
        for _ in 0..<200 where !tab.isProcessRunning {
            try? await Task.sleep(for: .milliseconds(5))
        }

        #expect(tab.isProcessRunning)
        #expect(!tab.processStartAdmissionRefused)
        manager.terminateAll()
    }

    @Test("re-arming the validator clears a standing refusal")
    @MainActor
    func rearmingValidatorClearsRefusal() async throws {
        let (paneManager, manager) = Self.makeManager()
        manager.createTerminalTab(
            relativeTo: paneManager.activePaneID,
            workingDirectory: FileManager.default.temporaryDirectory
        )
        let tab = try #require(manager.allTerminalTabs.first)

        tab.configureWorkingDirectoryValidation { _ in false }
        tab.terminalView.frame = NSRect(x: 0, y: 0, width: 640, height: 320)
        tab.startIfNeeded()
        for _ in 0..<200 where tab.isStartValidationPendingForTesting {
            try? await Task.sleep(for: .milliseconds(2))
        }
        #expect(tab.processStartAdmissionRefused)

        // A re-admitted project installs a fresh validator; the old refusal
        // must not fast-fail a launch that the new rules would admit.
        tab.configureWorkingDirectoryValidation { _ in true }
        #expect(!tab.processStartAdmissionRefused)
        manager.terminateAll()
    }

    // MARK: - launchAgentInNewTerminal wait behaviour

    @Test("launch fast-fails when the shell start is refused by admission")
    @MainActor
    func launchFastFailsOnAdmissionRefusal() async throws {
        // The pane must stay alive for the whole launch: TerminalManager
        // holds it weakly.
        let (paneManager, manager) = Self.makeManager()
        _ = paneManager
        var waits = 0
        let result = await manager.launchAgentInNewTerminal(
            "claude",
            descriptor: try Self.claudeDescriptor(),
            workingDirectory: FileManager.default.temporaryDirectory,
            maximumAttempts: 25,
            waitForNextAttempt: {
                waits += 1
                if waits == 1, let tab = manager.allTerminalTabs.first {
                    tab.configureWorkingDirectoryValidation { _ in false }
                    tab.terminalView.frame = NSRect(
                        x: 0, y: 0, width: 640, height: 320
                    )
                    tab.startIfNeeded()
                }
                await Task.yield()
            }
        )

        #expect(result == .rejected)
        // The refusal is a dead end: the remaining budget must not be spent
        // polling a tab that has already been told "no".
        #expect(waits <= 3)
        manager.terminateAll()
    }

    @Test("launch fast-fails when the terminal dies before its shell starts")
    @MainActor
    func launchFastFailsOnTerminatedTab() async throws {
        // The pane must stay alive for the whole launch: TerminalManager
        // holds it weakly.
        let (paneManager, manager) = Self.makeManager()
        _ = paneManager
        var waits = 0
        let result = await manager.launchAgentInNewTerminal(
            "claude",
            descriptor: try Self.claudeDescriptor(),
            workingDirectory: FileManager.default.temporaryDirectory,
            maximumAttempts: 25,
            waitForNextAttempt: {
                waits += 1
                if waits == 1, let tab = manager.allTerminalTabs.first {
                    tab.stop()
                }
                await Task.yield()
            }
        )

        #expect(result == .rejected)
        #expect(waits == 1)
        manager.terminateAll()
    }

    @Test("launch waits past the old three-second budget for a slow shell")
    @MainActor
    func launchWaitsPastOldBudgetForSlowShell() async throws {
        // The pane must stay alive for the whole launch: TerminalManager
        // holds it weakly.
        let (paneManager, manager) = Self.makeManager()
        _ = paneManager
        var waits = 0
        // 150 waits is already past the entire old budget of 120 attempts,
        // which used to reject the launch and orphan the worktree.
        let result = await manager.launchAgentInNewTerminal(
            "claude",
            descriptor: try Self.claudeDescriptor(),
            workingDirectory: FileManager.default.temporaryDirectory,
            waitForNextAttempt: {
                waits += 1
                if waits == 150, let tab = manager.allTerminalTabs.first {
                    tab.terminalView.frame = NSRect(
                        x: 0, y: 0, width: 640, height: 320
                    )
                    tab.startIfNeeded()
                }
                try? await Task.sleep(for: .milliseconds(5))
            }
        )

        #expect(result != .rejected)
        // The shell came up on wait 150 — past the entire old budget — and
        // `process.running` is set by the fork itself, so the wait that
        // started it can also be the last one counted.
        #expect(waits >= 150)
        #expect(manager.allTerminalTabs.first?.isProcessRunning == true)
        manager.terminateAll()
    }

    @Test("the default wait budget stays far above the old 120 attempts")
    func defaultBudgetExceedsOldCeiling() {
        #expect(TerminalManager.agentLaunchProcessStartAttempts >= 800)
    }
}

@Suite("Agent worktree session retention")
struct AgentWorktreeSessionRetentionTests {

    private static let noOpProcessRunner: ProcessRunner = { _, _, _, _ in
        ProcessRunResult(stdout: "", stderr: "", exitCode: 0, timedOut: false)
    }

    @MainActor
    private final class Fixture {
        let root: URL
        let project: URL
        let managedRoot: URL
        let worktreeRoot: URL
        let defaults: UserDefaults
        private let suiteName: String

        /// `worktreeOnDisk` decides whether the checkout exists, which is the
        /// one fact that separates retention from eviction (issue #1590).
        init(worktreeOnDisk: Bool) throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "Pine-AgentLaunchResilience-\(UUID().uuidString)",
                    isDirectory: true
                )
            project = root.appendingPathComponent(
                "Repository",
                isDirectory: true
            )
            managedRoot = root.appendingPathComponent(
                "Managed",
                isDirectory: true
            )
            worktreeRoot = managedRoot.appendingPathComponent(
                "616166cb-6a92-4735-aaf8-d7fa15e9b7ae",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: project,
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: managedRoot,
                withIntermediateDirectories: true
            )
            if worktreeOnDisk {
                try FileManager.default.createDirectory(
                    at: worktreeRoot,
                    withIntermediateDirectories: true
                )
            }
            suiteName = "AgentLaunchResilienceTests.\(UUID().uuidString)"
            defaults = try #require(UserDefaults(suiteName: suiteName))
            defaults.removePersistentDomain(forName: suiteName)
        }

        func makeRegistry() -> ProjectRegistry {
            ProjectRegistry(
                defaults: defaults,
                agentDetectionProcessRunner:
                    AgentWorktreeSessionRetentionTests.noOpProcessRunner,
                agentDetectionPollInterval: 3_600,
                backgroundReclamationInterval: .seconds(3_600)
            )
        }

        func makeWorktree() -> AgentManagedWorktree {
            // A proof that matches nothing on disk: the registry must refuse
            // to admit this worktree, which is the failure under test.
            AgentManagedWorktree(
                taskID: UUID(),
                repositoryRoot: project,
                managedRoot: managedRoot,
                worktreeRoot: worktreeRoot,
                branchName: "pine/agent/codex/12345678",
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

        func makeSession(
            worktree: AgentManagedWorktree
        ) -> ProjectWindowSession {
            let digest = SHA256.hash(data: Data(
                project.standardizedFileURL.path.utf8
            ))
            let suffix = digest.prefix(16).map {
                String(format: "%02x", $0)
            }.joined()
            struct PersistedFixture: Codable {
                let version: Int
                let projectURLs: [URL]
                let worktrees: [AgentManagedWorktree]
                let activeURL: URL
            }
            defaults.set(
                try? JSONEncoder().encode(PersistedFixture(
                    version: 1,
                    projectURLs: [project],
                    worktrees: [worktree],
                    activeURL: project
                )),
                forKey: "projectWindowSession.\(suffix)"
            )
            return ProjectWindowSession(
                initialProjectURL: project,
                defaults: defaults
            )
        }

        func cleanup() {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }
    }

    @Test("a refused activation keeps a worktree whose root is still on disk")
    @MainActor
    func refusedActivationKeepsLiveWorktree() async throws {
        let fixture = try Fixture(worktreeOnDisk: true)
        defer { fixture.cleanup() }
        let registry = fixture.makeRegistry()
        let worktree = fixture.makeWorktree()
        let session = fixture.makeSession(worktree: worktree)
        _ = await session.restoreIfNeeded(registry: registry)
        #expect(session.managedWorktrees.count == 1)

        await session.activate(worktree.worktreeRoot, registry: registry)

        // The activation was refused, yet the checkout exists: the session
        // must keep the entry switchable instead of evicting it forever.
        #expect(session.managedWorktrees.count == 1)
        let alert = try #require(session.alertMessage)
        #expect(alert.contains("codex/12345678"))
        #expect(alert.contains("Repository"))
        #expect(!alert.contains("616166cb-6a92-4735-aaf8-d7fa15e9b7ae"))
    }

    @Test("a refused activation evicts a worktree whose root is gone")
    @MainActor
    func refusedActivationEvictsMissingWorktree() async throws {
        let fixture = try Fixture(worktreeOnDisk: false)
        defer { fixture.cleanup() }
        let registry = fixture.makeRegistry()
        let worktree = fixture.makeWorktree()
        let session = fixture.makeSession(worktree: worktree)
        _ = await session.restoreIfNeeded(registry: registry)
        #expect(session.managedWorktrees.count == 1)

        await session.activate(worktree.worktreeRoot, registry: registry)

        #expect(session.managedWorktrees.isEmpty)
        #expect(session.alertMessage != nil)
        #expect(session.projectURLs.count == 1)
    }

    @Test("a plain project that cannot open still reports and leaves")
    @MainActor
    func plainProjectFailureStillEvicts() async throws {
        let fixture = try Fixture(worktreeOnDisk: true)
        defer { fixture.cleanup() }
        let registry = fixture.makeRegistry()
        let worktree = fixture.makeWorktree()
        let session = fixture.makeSession(worktree: worktree)
        _ = await session.restoreIfNeeded(registry: registry)

        let missing = fixture.root.appendingPathComponent(
            "Vanished",
            isDirectory: true
        )
        await session.activate(missing, registry: registry)

        // The non-worktree path is unchanged: report the folder name and
        // drop the target from the session.
        let alert = try #require(session.alertMessage)
        #expect(alert.contains("Vanished"))
        #expect(session.managedWorktrees.count == 1)
    }
}

@Suite("Agent worktree open-failure text")
struct AgentWorktreeOpenFailureTextTests {

    @Test("the text names the branch and the project, never the raw UUID")
    func textNamesBranchAndProject() {
        for locale in [Locale(identifier: "en_US"), Locale(identifier: "ru_RU")] {
            let text = Strings.projectSwitcherWorktreeOpenFailureText(
                "codex/12345678",
                projectName: "pine",
                locale: locale
            )
            #expect(text.contains("codex/12345678"))
            #expect(text.contains("pine"))
            #expect(!text.contains("%@"))
        }
    }
}
