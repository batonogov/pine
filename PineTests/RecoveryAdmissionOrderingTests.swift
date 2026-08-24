//
//  RecoveryAdmissionOrderingTests.swift
//  PineTests
//
//  The ordering the crash-recovery offer depends on (#1512).
//

import Foundation
import Testing

@testable import Pine

/// #1512 reported that a cold open can miss the crash-recovery offer, because
/// the project scene's `.task` asks for pending entries while
/// `setupRecovery` has not run yet — an optional chain that yields nothing and
/// never retries.
///
/// That race is **not reachable on `main`**, and these tests are why it stays
/// that way. `ProjectRegistry` publishes a manager into `openProjects` only
/// after `loadDirectory` — and therefore `setupRecovery` — has returned, and
/// `ProjectWindowView` mounts `ContentView` only for a manager it found in
/// `openProjects`. So by the time any scene task runs, recovery is set up.
///
/// Nothing stated that ordering, though: it is a property of the sequence of
/// two statements in `ProjectRegistry` plus one lookup in `PineApp`, in
/// different files, none of them mentioning the offer they keep alive. A
/// refactor that publishes the manager first, or that moves `setupRecovery`
/// behind an `await`, would reintroduce #1512 with every existing test still
/// green. These tests fail instead.
@Suite("Recovery admission ordering", .serialized)
@MainActor
struct RecoveryAdmissionOrderingTests {
    /// The exact sequence a cold open performs: admit the project, then ask
    /// the question the scene task asks — with nothing in between, which is
    /// the worst case the race would have.
    @Test("an admitted project can already answer the recovery offer")
    func admittedProjectAnswersTheOfferImmediately() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let project = try fixture.makeProjectDirectory(named: "alpha")
        let seeded = try fixture.seedSnapshot(for: project, content: "unsaved")

        let manager = try #require(fixture.registry.projectManager(for: project))
        let offer = await manager.pendingRecoveryOffer()

        #expect(manager.recoveryManager != nil)
        #expect(offer.map(\.0) == [seeded])
        #expect(offer.first?.1.content == "unsaved")
    }

    /// The same question asked through the lookup the window really uses.
    /// `ContentView` is mounted for whatever `projectManagerIfAdmitted`
    /// returns, so that is the object whose readiness matters — not the one
    /// the admission call happened to hand back.
    @Test("the registry never publishes a project before recovery is ready")
    func publishedProjectIsAlwaysRecoveryReady() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        for name in ["alpha", "beta", "gamma"] {
            let project = try fixture.makeProjectDirectory(named: name)
            let seeded = try fixture.seedSnapshot(for: project, content: name)
            _ = fixture.registry.projectManager(for: project)

            let published = try #require(
                fixture.registry.projectManagerIfAdmitted(for: project),
                "\(name) must be admitted"
            )
            #expect(published.recoveryManager != nil)
            #expect(await published.pendingRecoveryOffer().map(\.0) == [seeded])
        }
    }

    /// Reopening an already-admitted project takes the `existing` branch,
    /// which does not call `loadDirectory` again. The offer must survive that
    /// path too — the user who dismissed a window and came back through Open
    /// Recent has the same unsaved work on disk.
    @Test("reopening an admitted project keeps its recovery manager")
    func reopeningKeepsRecoverySetUp() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let project = try fixture.makeProjectDirectory(named: "alpha")
        let seeded = try fixture.seedSnapshot(for: project, content: "unsaved")

        let first = try #require(fixture.registry.projectManager(for: project))
        let second = try #require(fixture.registry.projectManager(for: project))

        #expect(first === second)
        #expect(second.recoveryManager != nil)
        #expect(await second.pendingRecoveryOffer().map(\.0) == [seeded])
    }

    /// Why the ordering is load-bearing rather than incidental: a manager that
    /// has not loaded a directory answers "nothing pending" and does not
    /// retry. That is the observable shape of #1512, pinned here so the
    /// consequence of publishing a manager too early is written down rather
    /// than rediscovered.
    @Test("a project that never loaded a directory silently offers nothing")
    func unloadedProjectOffersNothingAndDoesNotRetry() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let project = try fixture.makeProjectDirectory(named: "alpha")
        let seeded = try fixture.seedSnapshot(for: project, content: "unsaved")

        // Not admitted through the registry: no `loadDirectory`, so no
        // `setupRecovery` — the state #1512 feared the scene task could see.
        let manager = ProjectManager()
        #expect(manager.recoveryManager == nil)
        #expect(await manager.pendingRecoveryOffer().isEmpty)

        // And nothing recovers on its own: the entry only becomes visible once
        // setup actually happens. Asking twice changes nothing.
        #expect(await manager.pendingRecoveryOffer().isEmpty)

        manager.setupRecovery(projectURL: project)
        #expect(await manager.pendingRecoveryOffer().map(\.0) == [seeded])
    }

    /// The offer survives the background round trip. A project suspended into
    /// the background and resumed keeps taking snapshots, so a crash after the
    /// user comes back still has something to offer.
    @Test("a resumed project keeps snapshotting for the next crash")
    func resumedProjectResumesPeriodicSnapshots() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let project = try fixture.makeProjectDirectory(named: "alpha")
        let manager = try #require(fixture.registry.projectManager(for: project))
        let recovery = try #require(manager.recoveryManager)

        #expect(recovery.isPeriodicSnapshotting)

        manager.suspendEditorServices()
        #expect(!recovery.isPeriodicSnapshotting)

        manager.resumeEditorServices()
        #expect(recovery.isPeriodicSnapshotting)
        #expect(manager.recoveryManager === recovery)
    }

    // MARK: - Fixture

    @MainActor
    private final class Fixture {
        let registry: ProjectRegistry
        private let root: URL
        private let suiteName: String
        private let defaults: UserDefaults
        private var recoveryDirectories: [URL] = []

        init() throws {
            root = FileManager.default.temporaryDirectory
                .resolvingSymlinksInPath()
                .appendingPathComponent(
                    "PineRecoveryOrdering-\(UUID().uuidString)",
                    isDirectory: true
                )
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true
            )
            suiteName = "RecoveryAdmissionOrderingTests.\(UUID().uuidString)"
            defaults = try #require(UserDefaults(suiteName: suiteName))
            defaults.removePersistentDomain(forName: suiteName)
            registry = ProjectRegistry(
                defaults: defaults,
                agentTasks: AgentTaskRegistry(),
                // No `ps` polling: this suite is about admission ordering.
                agentDetectionProcessRunner: { _, _, _, _ in
                    ProcessRunResult(
                        stdout: "",
                        stderr: "",
                        exitCode: 0,
                        timedOut: false
                    )
                },
                agentDetectionPollInterval: 3_600,
                agentDetectionInitialPollDelay: 3_600
            )
            registry.recentProjects = []
        }

        func makeProjectDirectory(named name: String) throws -> URL {
            let url = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true
            )
            return url
        }

        /// Writes one snapshot exactly where a crash would have left it: the
        /// per-project recovery directory the production hash resolves to.
        @discardableResult
        func seedSnapshot(for project: URL, content: String) throws -> UUID {
            let directory = RecoveryManager.directory(for: project)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            recoveryDirectories.append(directory)
            let tabID = UUID()
            let entry = RecoveryEntry(
                originalPath: project
                    .appendingPathComponent("draft.swift").path,
                content: content
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(entry).write(
                to: directory.appendingPathComponent("\(tabID.uuidString).json")
            )
            return tabID
        }

        func cleanup() {
            for directory in recoveryDirectories {
                try? FileManager.default.removeItem(at: directory)
            }
            recoveryDirectories.removeAll()
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }
    }
}
