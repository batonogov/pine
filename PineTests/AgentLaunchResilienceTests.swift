//
//  AgentLaunchResilienceTests.swift
//  PineTests
//
//  Issue #1590: the agent launch chain used to die inside a fixed
//  three-second PTY budget and evict healthy worktrees from the window
//  session after a single refused activation. These tests pin the wait
//  behaviour, the fast-fail on deterministic dead ends, the re-arm after a
//  transient refusal, and the retention rule for worktrees whose root is
//  still on disk.
//
//  Terminal tests spawn real PTY children, so this suite is serialized and
//  injects a no-op detection runner — forking `/bin/ps` from a test host is
//  the documented macos-26 hang (#1060), and these tests outlive the
//  coordinator's first poll.
//

import AppKit
import CryptoKit
import Foundation
import Testing

@testable import Pine

/// Polls a condition on a wall-clock deadline and reports a distinguishable
/// expectation failure when the deadline hits, so triage reads "deadline
/// exhausted", not a silent wrong predicate.
@MainActor
private func waitUntil(
    _ what: String,
    within limit: ContinuousClock.Duration,
    condition: () -> Bool
) async {
    let deadline = ContinuousClock.now + limit
    while ContinuousClock.now < deadline {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(2))
    }
    #expect(condition(), "deadline exhausted waiting for \(what)")
}

/// A sendable first-call-only switch: the first evaluation reads `false`,
/// every later one `true`. Used to model an admission that refuses once —
/// the transient miss this suite has to survive — and admits afterwards.
nonisolated private final class RefuseOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    func validator() -> Bool {
        lock.withLock {
            calls += 1
            return calls > 1
        }
    }
}

@Suite("Agent launch resilience", .serialized)
struct AgentLaunchResilienceTests {

    private static let noOpProcessRunner: ProcessRunner = { _, _, _, _ in
        ProcessRunResult(stdout: "", stderr: "", exitCode: 0, timedOut: false)
    }

    private static func claudeDescriptor() throws -> AgentDescriptor {
        try #require(TerminalManager.exactAgentLaunchDescriptor(for: "claude"))
    }

    private static func makeManager() -> (PaneManager, TerminalManager) {
        let paneManager = PaneManager()
        // TerminalManager holds the pane weakly; the caller must keep it
        // alive for the whole launch.
        let manager = TerminalManager(
            agentDetectionProcessRunner: noOpProcessRunner
        )
        manager.paneManager = paneManager
        return (paneManager, manager)
    }

    /// A process that never exits and never reads stdin: the PTY write the
    /// launch performs lands in the tty line discipline (echo) and nowhere
    /// else, so no command of the user's environment ever executes.
    private static let inertProcess = TerminalInitialProcess(
        executablePath: "/bin/sleep",
        arguments: ["60"]
    )

    // MARK: - Admission refusal is observable on the tab

    @Test("a refused working-directory admission marks the tab and never spawns")
    @MainActor
    func refusedAdmissionMarksTabWithoutSpawning() async throws {
        let (paneManager, manager) = Self.makeManager()
        defer { manager.terminateAll() }
        // The validator only runs for a tab that names its working
        // directory, so the tab must carry a real one.
        manager.createTerminalTab(
            relativeTo: paneManager.activePaneID,
            workingDirectory: FileManager.default.temporaryDirectory
        )
        let tab = try #require(manager.allTerminalTabs.first)

        tab.configureWorkingDirectoryValidation { _ in false }
        tab.terminalView.frame = NSRect(x: 0, y: 0, width: 640, height: 320)
        tab.startIfNeeded()
        await waitUntil(
            "the validation task to conclude",
            within: .milliseconds(400)
        ) { [weak tab] in tab?.isStartValidationPendingForTesting == false }

        #expect(tab.processStartAdmissionRefused)
        #expect(!tab.isProcessRunning)
    }

    @Test("a later successful start clears the refusal mark")
    @MainActor
    func successfulStartClearsRefusalMark() async throws {
        let (paneManager, manager) = Self.makeManager()
        defer { manager.terminateAll() }
        manager.createTerminalTab(
            relativeTo: paneManager.activePaneID,
            workingDirectory: FileManager.default.temporaryDirectory
        )
        let tab = try #require(manager.allTerminalTabs.first)

        tab.configureWorkingDirectoryValidation { _ in false }
        tab.terminalView.frame = NSRect(x: 0, y: 0, width: 640, height: 320)
        tab.startIfNeeded()
        await waitUntil(
            "the first validation task to conclude",
            within: .milliseconds(400)
        ) { [weak tab] in tab?.isStartValidationPendingForTesting == false }
        #expect(tab.processStartAdmissionRefused)

        // A relayout re-runs `startIfNeeded`; an admitting validator now
        // lets the process through and the mark must not outlive it.
        tab.configure(
            workingDirectory: FileManager.default.temporaryDirectory,
            initialProcess: Self.inertProcess
        )
        tab.configureWorkingDirectoryValidation { _ in true }
        tab.startIfNeeded()
        await waitUntil(
            "the second validation task to conclude",
            within: .milliseconds(400)
        ) { [weak tab] in tab?.isStartValidationPendingForTesting == false }
        await waitUntil(
            "the inert process to spawn",
            within: .seconds(2)
        ) { [weak tab] in tab?.isProcessRunning == true }

        #expect(tab.isProcessRunning)
        #expect(!tab.processStartAdmissionRefused)
    }

    @Test("re-arming the validator clears a standing refusal")
    @MainActor
    func rearmingValidatorClearsRefusal() async throws {
        let (paneManager, manager) = Self.makeManager()
        defer { manager.terminateAll() }
        manager.createTerminalTab(
            relativeTo: paneManager.activePaneID,
            workingDirectory: FileManager.default.temporaryDirectory
        )
        let tab = try #require(manager.allTerminalTabs.first)

        tab.configureWorkingDirectoryValidation { _ in false }
        tab.terminalView.frame = NSRect(x: 0, y: 0, width: 640, height: 320)
        tab.startIfNeeded()
        await waitUntil(
            "the validation task to conclude",
            within: .milliseconds(400)
        ) { [weak tab] in tab?.isStartValidationPendingForTesting == false }
        #expect(tab.processStartAdmissionRefused)

        // A re-admitted project installs a fresh validator; the old refusal
        // must not fast-fail a launch that the new rules would admit.
        tab.configureWorkingDirectoryValidation { _ in true }
        #expect(!tab.processStartAdmissionRefused)
    }

    @Test("rebinding the working directory clears a standing refusal")
    @MainActor
    func rebindingDirectoryClearsRefusal() async throws {
        let (paneManager, manager) = Self.makeManager()
        defer { manager.terminateAll() }
        manager.createTerminalTab(
            relativeTo: paneManager.activePaneID,
            workingDirectory: FileManager.default.temporaryDirectory
        )
        let tab = try #require(manager.allTerminalTabs.first)

        tab.configureWorkingDirectoryValidation { _ in false }
        tab.terminalView.frame = NSRect(x: 0, y: 0, width: 640, height: 320)
        tab.startIfNeeded()
        await waitUntil(
            "the validation task to conclude",
            within: .milliseconds(400)
        ) { [weak tab] in tab?.isStartValidationPendingForTesting == false }
        #expect(tab.processStartAdmissionRefused)

        // A rebound directory is a new admission question (#1590 review):
        // the mark recorded against the previous directory must not survive.
        tab.configure(
            workingDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("rebound", isDirectory: true),
            initialProcess: Self.inertProcess
        )
        #expect(!tab.processStartAdmissionRefused)
    }

    // MARK: - launchAgentInNewTerminal wait behaviour

    @Test("launch fast-fails when the shell start is refused again after a re-arm")
    @MainActor
    func launchFastFailsOnRepeatedAdmissionRefusal() async throws {
        // The pane must stay alive for the whole launch: TerminalManager
        // holds it weakly.
        let (paneManager, manager) = Self.makeManager()
        _ = paneManager
        defer { manager.terminateAll() }
        var waits = 0
        let result = await manager.launchAgentInNewTerminal(
            "claude",
            descriptor: try Self.claudeDescriptor(),
            workingDirectory: FileManager.default.temporaryDirectory,
            maximumAttempts: 25,
            waitForNextAttempt: {
                waits += 1
                if waits == 1, let tab = manager.allTerminalTabs.first {
                    // Always refuse: both the first attempt and each
                    // re-armed one must be told "no", so the launch can
                    // only conclude by fast-fail, never by spawning.
                    tab.configureWorkingDirectoryValidation { _ in false }
                    tab.terminalView.frame = NSRect(
                        x: 0, y: 0, width: 640, height: 320
                    )
                    tab.startIfNeeded()
                }
                // Hand control back only once no validation is in flight:
                // the loop's next look at the mark then reflects a
                // concluded outcome, not a task parked on another
                // executor that a yield would not wake (SE-0338).
                if let tab = manager.allTerminalTabs.first {
                    let deadline = ContinuousClock.now + .milliseconds(400)
                    while tab.isStartValidationPendingForTesting,
                          ContinuousClock.now < deadline {
                        try? await Task.sleep(for: .milliseconds(2))
                    }
                }
            }
        )

        #expect(result == .rejected)
        // One initial wait plus one per re-arm (two allowed): a tab that
        // has now thrice been told "no" must not consume the budget.
        #expect(waits == 3)
    }

    @Test("launch fast-fails when the terminal dies before its shell starts")
    @MainActor
    func launchFastFailsOnTerminatedTab() async throws {
        // The pane must stay alive for the whole launch: TerminalManager
        // holds it weakly.
        let (paneManager, manager) = Self.makeManager()
        _ = paneManager
        defer { manager.terminateAll() }
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
    }

    @Test("launch re-arms once after a transient admission refusal")
    @MainActor
    func launchRecoversFromTransientRefusal() async throws {
        // The pane must stay alive for the whole launch: TerminalManager
        // holds it weakly.
        let (paneManager, manager) = Self.makeManager()
        _ = paneManager
        defer { manager.terminateAll() }
        var waits = 0
        let result = await manager.launchAgentInNewTerminal(
            "claude",
            descriptor: try Self.claudeDescriptor(),
            workingDirectory: FileManager.default.temporaryDirectory,
            maximumAttempts: 400,
            waitForNextAttempt: {
                waits += 1
                if waits == 1, let tab = manager.allTerminalTabs.first {
                    // The first validation refuses (a transient miss); the
                    // re-armed second one admits: the launch must proceed,
                    // not die on the first "no" (#1590 review).
                    let refuseOnce = RefuseOnce()
                    tab.configureWorkingDirectoryValidation { _ in
                        refuseOnce.validator()
                    }
                    tab.configure(
            workingDirectory: FileManager.default.temporaryDirectory,
            initialProcess: Self.inertProcess
        )
                    tab.terminalView.frame = NSRect(
                        x: 0, y: 0, width: 640, height: 320
                    )
                    tab.startIfNeeded()
                }
                try? await Task.sleep(for: .milliseconds(2))
            }
        )

        // No registry is installed, so an acknowledged write reports as a
        // sent-without-reservation — the launch got past the wait.
        #expect(result == .sentWithoutReservation)
        #expect(manager.allTerminalTabs.first?.isProcessRunning == true)
    }

    @Test("launch keeps waiting past the old three-second budget")
    @MainActor
    func launchWaitsPastOldBudgetForSlowStart() async throws {
        // The pane must stay alive for the whole launch: TerminalManager
        // holds it weakly.
        let (paneManager, manager) = Self.makeManager()
        _ = paneManager
        defer { manager.terminateAll() }
        var waits = 0
        // The PTY fork itself is synchronous, so "slow" here is the loop's
        // patience, not the fork: the process is armed on wait 150 — past
        // the entire old budget of 120 attempts, which used to reject the
        // launch and orphan the worktree.
        let result = await manager.launchAgentInNewTerminal(
            "claude",
            descriptor: try Self.claudeDescriptor(),
            workingDirectory: FileManager.default.temporaryDirectory,
            waitForNextAttempt: {
                waits += 1
                if waits == 150, let tab = manager.allTerminalTabs.first {
                    tab.configure(
            workingDirectory: FileManager.default.temporaryDirectory,
            initialProcess: Self.inertProcess
        )
                    tab.terminalView.frame = NSRect(
                        x: 0, y: 0, width: 640, height: 320
                    )
                    tab.startIfNeeded()
                }
                try? await Task.sleep(for: .milliseconds(5))
            }
        )

        #expect(result == .sentWithoutReservation)
        #expect(waits >= 150)
        #expect(manager.allTerminalTabs.first?.isProcessRunning == true)
    }

    @Test("the default wait budget is the documented 20-second ceiling")
    func defaultBudgetMatchesDocumentedCeiling() {
        #expect(TerminalManager.agentLaunchProcessStartAttempts == 800)
    }
}

@Suite("Agent worktree session retention")
struct AgentWorktreeSessionRetentionTests {

    private static let noOpProcessRunner: ProcessRunner = { _, _, _, _ in
        ProcessRunResult(stdout: "", stderr: "", exitCode: 0, timedOut: false)
    }

    /// A real repository with a real linked worktree: the refusal these
    /// tests need has to come from the admission chain, not from a fixture
    /// that is not a git repository at all.
    @MainActor
    private final class Fixture {
        let root: URL
        let project: URL
        let managedRoot: URL
        let worktreeRoot: URL
        let defaults: UserDefaults
        private let suiteName: String

        /// `worktreeOnDisk` decides whether the checkout exists, which is
        /// the one fact that separates retention from eviction (#1590).
        /// `worktreeIsFile` replaces the checkout with a regular file.
        init(worktreeOnDisk: Bool, worktreeIsFile: Bool = false) throws {
            let rootDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "Pine-AgentLaunchResilience-\(UUID().uuidString)",
                    isDirectory: true
                )
            var didCompleteSetup = false
            defer {
                if !didCompleteSetup {
                    try? FileManager.default.removeItem(at: rootDirectory)
                }
            }
            root = rootDirectory
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
            try Self.git(["init", "--initial-branch=main"], at: project)
            try Self.git(
                ["config", "user.name", "Agent Launch Tests"],
                at: project
            )
            try Self.git(
                ["config", "user.email", "agent-launch-tests@pine.invalid"],
                at: project
            )
            try Data("seed".utf8).write(
                to: project.appendingPathComponent("seed.txt")
            )
            try Self.git(["add", "seed.txt"], at: project)
            try Self.git(["commit", "-m", "seed"], at: project)
            try Self.git(
                [
                    "worktree", "add", "--no-track", "-b",
                    "pine/agent/codex/12345678", "--", worktreeRoot.path,
                ],
                at: project
            )
            if worktreeIsFile {
                try FileManager.default.removeItem(at: worktreeRoot)
                try Data("not a directory".utf8).write(
                    to: URL(fileURLWithPath: worktreeRoot.path)
                )
            } else if !worktreeOnDisk {
                try Self.git(
                    [
                        "worktree", "remove", "--force", "--",
                        worktreeRoot.path,
                    ],
                    at: project
                )
            }
            suiteName = "AgentLaunchResilienceTests.\(UUID().uuidString)"
            defaults = try #require(UserDefaults(suiteName: suiteName))
            defaults.removePersistentDomain(forName: suiteName)
            didCompleteSetup = true
        }

        private static func git(
            _ arguments: [String],
            at directory: URL
        ) throws {
            let result = GitCommand.run(arguments, at: directory, timeout: 5)
            guard result.succeeded else {
                throw FixtureError.gitFailed(
                    arguments: arguments,
                    diagnostics: result.errorOutput
                )
            }
        }

        private enum FixtureError: Error {
            case gitFailed(arguments: [String], diagnostics: String)
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
            // The repository and worktree are real, but the recorded proof
            // matches nothing on disk, so admission fails the way it does
            // for a healthy worktree after a repository-identity change.
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

        struct PersistedFixture: Codable {
            let version: Int
            let projectURLs: [URL]
            let worktrees: [AgentManagedWorktree]
            let activeURL: URL?
        }

        private var persistenceKey: String {
            let digest = SHA256.hash(data: Data(
                project.standardizedFileURL.path.utf8
            ))
            let suffix = digest.prefix(16).map {
                String(format: "%02x", $0)
            }.joined()
            return "projectWindowSession.\(suffix)"
        }

        func persist(
            worktree: AgentManagedWorktree,
            activeURL: URL
        ) throws {
            let data = try JSONEncoder().encode(PersistedFixture(
                version: 1,
                projectURLs: [project],
                worktrees: [worktree],
                activeURL: activeURL
            ))
            defaults.set(data, forKey: persistenceKey)
        }

        func makeSession() -> ProjectWindowSession {
            ProjectWindowSession(
                initialProjectURL: project,
                defaults: defaults
            )
        }

        func persistedActiveURL() throws -> URL? {
            let data = try #require(defaults.data(forKey: persistenceKey))
            return try JSONDecoder().decode(
                PersistedFixture.self,
                from: data
            ).activeURL
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
        let registry = fixture.makeRegistry()
        defer { fixture.cleanup() }
        let worktree = fixture.makeWorktree()
        try fixture.persist(worktree: worktree, activeURL: fixture.project)
        let session = fixture.makeSession()
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
        let registry = fixture.makeRegistry()
        defer { fixture.cleanup() }
        let worktree = fixture.makeWorktree()
        try fixture.persist(worktree: worktree, activeURL: fixture.project)
        let session = fixture.makeSession()
        _ = await session.restoreIfNeeded(registry: registry)
        #expect(session.managedWorktrees.count == 1)

        await session.activate(worktree.worktreeRoot, registry: registry)

        #expect(session.managedWorktrees.isEmpty)
        #expect(session.alertMessage != nil)
        #expect(
            session.projectURLs == [fixture.project.standardizedFileURL]
        )
    }

    @Test("a worktree root replaced by a file evicts too")
    @MainActor
    func refusedActivationEvictsFileRoot() async throws {
        let fixture = try Fixture(worktreeOnDisk: true, worktreeIsFile: true)
        let registry = fixture.makeRegistry()
        defer { fixture.cleanup() }
        let worktree = fixture.makeWorktree()
        try fixture.persist(worktree: worktree, activeURL: fixture.project)
        let session = fixture.makeSession()
        _ = await session.restoreIfNeeded(registry: registry)
        #expect(session.managedWorktrees.count == 1)

        await session.activate(worktree.worktreeRoot, registry: registry)

        // A regular file where the checkout should be is not a worktree
        // the user can retry into.
        #expect(session.managedWorktrees.isEmpty)
    }

    @Test("a plain project that cannot open still reports and leaves")
    @MainActor
    func plainProjectFailureStillEvicts() async throws {
        let fixture = try Fixture(worktreeOnDisk: true)
        let registry = fixture.makeRegistry()
        defer { fixture.cleanup() }
        let worktree = fixture.makeWorktree()
        try fixture.persist(worktree: worktree, activeURL: fixture.project)
        let session = fixture.makeSession()
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

    @Test("a refused restore rewrites the remembered active URL")
    @MainActor
    func refusedRestoreHealsRememberedActiveURL() async throws {
        let fixture = try Fixture(worktreeOnDisk: true)
        let registry = fixture.makeRegistry()
        defer { fixture.cleanup() }
        let worktree = fixture.makeWorktree()
        // The window was showing the worktree when it closed; on relaunch
        // admission refuses it. The refusal keeps the entry (the root
        // exists) but must not leave the dead active URL remembered, or
        // every relaunch would dismiss the scene back to Welcome.
        try fixture.persist(
            worktree: worktree,
            activeURL: worktree.worktreeRoot
        )
        let session = fixture.makeSession()
        _ = await session.restoreIfNeeded(registry: registry)
        #expect(session.managedWorktrees.count == 1)

        let remembered = try fixture.persistedActiveURL()
        #expect(remembered == fixture.project.standardizedFileURL)

        // The next relaunch restores normally instead of wedging.
        let second = fixture.makeSession()
        let result = await second.restoreIfNeeded(registry: registry)
        if case .restored = result {} else {
            Issue.record("second restore did not complete: \(result)")
        }
    }
}

@Suite("Agent worktree open-failure text")
struct AgentWorktreeOpenFailureTextTests {

    private static let locales = [
        "en_US", "de_DE", "es_ES", "fr_FR", "ja_JP", "ko_KR", "pt_BR",
        "ru_RU", "zh_Hans_CN",
    ]

    @Test("every locale names the branch first, then the project, once each")
    func textNamesBranchAndProjectInOrder() {
        for identifier in Self.locales {
            let text = Strings.projectSwitcherWorktreeOpenFailureText(
                "codex/12345678",
                projectName: "fixture-project",
                locale: Locale(identifier: identifier)
            )
            guard let branch = text.range(of: "codex/12345678"),
                  let project = text.range(of: "fixture-project") else {
                Issue.record(
                    "\(identifier): an argument went unresolved in \(text)"
                )
                continue
            }
            #expect(
                branch.lowerBound < project.lowerBound,
                "\(identifier): the branch must precede the project — got \(text)"
            )
            #expect(
                !text.contains("%@"),
                "\(identifier): unresolved format specifier in \(text)"
            )
        }
    }
}
