//
//  RecoveryTerminationSweepTests.swift
//  PineTests
//
//  #1503: Escape in the crash-recovery sheet now means "later", not "delete".
//  "Later" is only honest if the snapshots survive the clean-quit sweep that
//  `applicationWillTerminate` runs when nothing is unsaved — and the sweep
//  used to empty the whole recovery directory, so quitting with the sheet on
//  screen destroyed the very files it was offering. The sweep is now scoped to
//  the snapshots belonging to the session's open tabs; these tests pin that
//  boundary, from both sides.
//

import AppKit
import Foundation
import Testing

@testable import Pine

// `.serialized`: several tests here drive a real `AppDelegate` against a real
// `ProjectRegistry`, and one of them is `async` — without serialisation its
// suspension is a window in which another test's delegate can touch the same
// process-global singletons.
@Suite(
    "The clean-quit sweep only takes what this session owns",
    .serialized
)
@MainActor
struct RecoveryTerminationSweepTests {

    // MARK: - Core contract

    @Test("Crash snapshots nobody decided about survive the sweep")
    func undecidedSnapshotsSurviveTheSweep() throws {
        let dir = try Self.makeTempDir()
        defer { Self.cleanup(dir) }
        let manager = RecoveryManager(recoveryDirectory: dir)
        manager.snapshotDirtyTabs([
            Self.dirtyTab(path: "/tmp/a.swift"),
            Self.dirtyTab(path: "/tmp/b.swift"),
        ])
        let ids = Set(manager.pendingRecoveryEntries().map(\.0))
        #expect(ids.count == 2)

        // A crash snapshot belongs to no open tab — that is exactly what makes
        // it a crash snapshot. Quitting cleanly must leave it alone.
        manager.deleteSnapshotsOfOpenTabs([])

        #expect(Set(manager.pendingRecoveryEntries().map(\.0)) == ids)
    }

    @Test("Snapshots of this session's open tabs are swept")
    func openTabSnapshotsAreSwept() throws {
        let dir = try Self.makeTempDir()
        defer { Self.cleanup(dir) }
        let manager = RecoveryManager(recoveryDirectory: dir)
        let tabs = [
            Self.dirtyTab(path: "/tmp/a.swift"),
            Self.dirtyTab(path: "/tmp/b.swift"),
        ]
        manager.snapshotDirtyTabs(tabs)
        #expect(manager.pendingRecoveryEntries().count == 2)

        manager.deleteSnapshotsOfOpenTabs(tabs.map(\.id))

        #expect(manager.pendingRecoveryEntries().isEmpty)
    }

    @Test("The sweep takes the tabs it is given and nothing beside them")
    func theSweepIsScopedToTheTabsItIsGiven() throws {
        let dir = try Self.makeTempDir()
        defer { Self.cleanup(dir) }
        let manager = RecoveryManager(recoveryDirectory: dir)
        let openTab = Self.dirtyTab(path: "/tmp/open.swift")
        manager.snapshotDirtyTabs([openTab])
        let crashTab = Self.dirtyTab(path: "/tmp/from-the-crash.swift")
        manager.snapshotDirtyTabs([crashTab])
        #expect(manager.pendingRecoveryEntries().count == 2)

        manager.deleteSnapshotsOfOpenTabs([openTab.id])

        #expect(manager.pendingRecoveryEntries().map(\.0) == [crashTab.id])
    }

    @Test("A superseded crash snapshot leaves with the tab that replaced it")
    func aSupersededSnapshotGoesWithItsOpenTab() throws {
        let dir = try Self.makeTempDir()
        defer { Self.cleanup(dir) }
        let manager = RecoveryManager(recoveryDirectory: dir)
        let crashTab = Self.dirtyTab(path: "/tmp/crashed.swift")
        manager.snapshotDirtyTabs([crashTab])
        let runtimeTab = Self.dirtyTab(path: "/tmp/crashed.swift")

        // Block the destination so the migration cannot write the runtime
        // snapshot: the old crash file stays on disk and is recorded against
        // the runtime tab instead of being orphaned.
        let blocked = dir.appendingPathComponent("\(runtimeTab.id.uuidString).json")
        try FileManager.default.createDirectory(
            at: blocked,
            withIntermediateDirectories: false
        )
        #expect(
            manager.migrateRecoverySnapshot(
                from: crashTab.id,
                to: runtimeTab
            ) == false
        )
        try FileManager.default.removeItem(at: blocked)
        #expect(manager.pendingRecoveryEntries().map(\.0) == [crashTab.id])

        // Sweeping the runtime tab must take the crash file it inherited…
        manager.deleteSnapshotsOfOpenTabs([runtimeTab.id])
        #expect(manager.pendingRecoveryEntries().isEmpty)
    }

    @Test("A superseded crash snapshot stays when its tab is not swept")
    func aSupersededSnapshotStaysWithoutItsOpenTab() throws {
        let dir = try Self.makeTempDir()
        defer { Self.cleanup(dir) }
        let manager = RecoveryManager(recoveryDirectory: dir)
        let crashTab = Self.dirtyTab(path: "/tmp/crashed.swift")
        manager.snapshotDirtyTabs([crashTab])
        let runtimeTab = Self.dirtyTab(path: "/tmp/crashed.swift")
        let blocked = dir.appendingPathComponent("\(runtimeTab.id.uuidString).json")
        try FileManager.default.createDirectory(
            at: blocked,
            withIntermediateDirectories: false
        )
        _ = manager.migrateRecoverySnapshot(from: crashTab.id, to: runtimeTab)
        try FileManager.default.removeItem(at: blocked)

        // …and only then. A sweep that was handed no tabs takes nothing.
        manager.deleteSnapshotsOfOpenTabs([])
        #expect(manager.pendingRecoveryEntries().map(\.0) == [crashTab.id])
    }

    @Test("Entries the restorer could not restore survive the sweep")
    func retainedEntriesSurviveTheSweep() async throws {
        let dir = try Self.makeTempDir()
        defer { Self.cleanup(dir) }
        let manager = RecoveryManager(recoveryDirectory: dir)

        // Two crash snapshots: one restores, one the user backs out of at the
        // large-file prompt. The second is the clearest case of "undecided" —
        // the user asked to recover and did not get to finish — so the sweep
        // must not finish the job by deleting it.
        let restoredURL = dir.appendingPathComponent("restored.swift")
        try "on disk".write(to: restoredURL, atomically: true, encoding: .utf8)
        let cancelledURL = dir.appendingPathComponent("cancelled.swift")
        let huge = String(
            repeating: "c",
            count: TabManager.largeFileThreshold + 1
        )
        try huge.write(to: cancelledURL, atomically: true, encoding: .utf8)
        let restoredCrashTab = EditorTab(
            url: restoredURL,
            content: "recovered",
            savedContent: "on disk"
        )
        let cancelledCrashTab = EditorTab(
            url: cancelledURL,
            content: "still undecided",
            savedContent: huge
        )
        manager.snapshotDirtyTabs([restoredCrashTab, cancelledCrashTab])

        let tabManager = TabManager()
        tabManager.largeFileAlertPresenter = { _, _, _ in .abort }
        let retained = await manager.restorePendingEntries(
            manager.pendingRecoveryEntries(),
            in: tabManager,
            context: .unscoped
        )
        #expect(retained.map { $0.0 } == [cancelledCrashTab.id])

        let openTabIDs: [UUID] = tabManager.tabs.map(\.id)
        manager.deleteSnapshotsOfOpenTabs(openTabIDs)

        #expect(
            manager.pendingRecoveryEntries().map(\.0)
                == [cancelledCrashTab.id]
        )
    }

    // MARK: - Repetition and degenerate input

    @Test("Sweeping twice is the same as sweeping once")
    func theSweepIsIdempotent() throws {
        let dir = try Self.makeTempDir()
        defer { Self.cleanup(dir) }
        let manager = RecoveryManager(recoveryDirectory: dir)
        let openTab = Self.dirtyTab(path: "/tmp/open.swift")
        let crashTab = Self.dirtyTab(path: "/tmp/crash.swift")
        manager.snapshotDirtyTabs([openTab])
        manager.snapshotDirtyTabs([crashTab])

        for _ in 0..<3 {
            manager.deleteSnapshotsOfOpenTabs([openTab.id, openTab.id])
            #expect(manager.pendingRecoveryEntries().map(\.0) == [crashTab.id])
        }
    }

    @Test("Sweeping IDs with no file on disk destroys nothing")
    func sweepingUnknownIDsDestroysNothing() throws {
        let dir = try Self.makeTempDir()
        defer { Self.cleanup(dir) }
        let manager = RecoveryManager(recoveryDirectory: dir)
        manager.snapshotDirtyTabs([Self.dirtyTab(path: "/tmp/a.swift")])
        let ids = manager.pendingRecoveryEntries().map(\.0)

        manager.deleteSnapshotsOfOpenTabs([UUID(), UUID()])

        #expect(manager.pendingRecoveryEntries().map(\.0) == ids)
    }

    @Test("The sweep leaves files that are not recovery snapshots")
    func theSweepLeavesForeignFiles() throws {
        let dir = try Self.makeTempDir()
        defer { Self.cleanup(dir) }
        let manager = RecoveryManager(recoveryDirectory: dir)
        let openTab = Self.dirtyTab(path: "/tmp/open.swift")
        manager.snapshotDirtyTabs([openTab])
        let junk = dir.appendingPathComponent("not-a-uuid.json")
        try Data("{}".utf8).write(to: junk)
        let sidecar = dir.appendingPathComponent("notes.txt")
        try Data("keep me".utf8).write(to: sidecar)

        manager.deleteSnapshotsOfOpenTabs([openTab.id])

        // Neither was ever this session's to delete. The stale sweep collects
        // orphaned JSON — including the undecodable kind, which used to be
        // immortal — once the filesystem agrees it is old enough; nothing
        // collects a foreign extension.
        #expect(FileManager.default.fileExists(atPath: junk.path))
        #expect(FileManager.default.fileExists(atPath: sidecar.path))
    }

    @Test("A sweep against a missing directory does not crash")
    func theSweepToleratesAMissingDirectory() {
        let missing = URL(
            fileURLWithPath: "/tmp/pine-missing-\(UUID().uuidString)"
        )
        let manager = RecoveryManager(recoveryDirectory: missing)

        manager.deleteSnapshotsOfOpenTabs([UUID()])

        #expect(manager.pendingRecoveryEntries().isEmpty)
    }

    @Test("One project's sweep cannot reach another project's snapshots")
    func theSweepIsScopedToItsOwnProject() throws {
        let dirA = try Self.makeTempDir()
        let dirB = try Self.makeTempDir()
        defer {
            Self.cleanup(dirA)
            Self.cleanup(dirB)
        }
        let managerA = RecoveryManager(recoveryDirectory: dirA)
        let managerB = RecoveryManager(recoveryDirectory: dirB)
        let tabA = Self.dirtyTab(path: "/tmp/a.swift")
        managerA.snapshotDirtyTabs([tabA])
        managerB.snapshotDirtyTabs([Self.dirtyTab(path: "/tmp/b.swift")])

        managerB.deleteSnapshotsOfOpenTabs([tabA.id])

        #expect(managerA.pendingRecoveryEntries().count == 1)
        #expect(managerB.pendingRecoveryEntries().count == 1)
    }

    // MARK: - Nothing collects a snapshot by age (#1760)

    @Test("No launch sweep is wired into app startup any more")
    func noStartupPathCollectsSnapshots() throws {
        // The sweep existed to bound "Later"; since #1760 there is no bound,
        // so the launch path must not delete anything. Reading the source is
        // the assertion here: a silent reintroduction compiles fine and would
        // pass every behaviour test that seeds fresh snapshots.
        let appSource = try String(
            contentsOf: Self.repositoryRoot()
                .appendingPathComponent("Pine/PineApp.swift"),
            encoding: .utf8
        )
        #expect(
            !appSource.contains("cleanupAllStaleEntries"),
            "The age-based launch sweep is back in app startup (#1760)"
        )
        #expect(
            !appSource.contains("staleEntryRetentionDays"),
            "The launch path still reads the retired retention window"
        )
    }

    @Test("The sheet promises that the work is kept, not that it expires")
    func theSheetSaysTheWorkIsKept() throws {
        // `keepNoticeIsLocalizedEverywhere` only proves the string exists in
        // the catalog. Deleting the `Text` from the sheet's `body` breaks
        // nothing else — the sheet is sized by `minWidth`, so it does not even
        // change shape — and #1760's central promise, that Later is safe
        // without a deadline and the list comes back, silently becomes false
        // with the whole suite green.
        let source = try String(
            contentsOf: Self.repositoryRoot()
                .appendingPathComponent("Pine/RecoveryDialogView.swift"),
            encoding: .utf8
        )

        #expect(
            source.contains("Strings.recoveryKeepNotice"),
            "The recovery sheet no longer tells the user the work is kept"
        )
        #expect(
            !source.contains("recoveryRetentionNotice"),
            """
            The sheet still prints a retention deadline the app no longer \
            enforces
            """
        )
    }

    @Test("A snapshot a year old is still offered")
    func anAncientSnapshotIsStillOffered() throws {
        // The retired sweep collected a snapshot a week after the crash the
        // user never answered. Nothing does now: age is not a decision about
        // anybody's work (#1760).
        let dir = try Self.makeTempDir()
        defer { Self.cleanup(dir) }
        let manager = RecoveryManager(recoveryDirectory: dir)
        let ancient = try Self.writeSnapshot(daysOld: 365, in: dir)

        #expect(
            manager.pendingRecoveryEntries().map(\.0) == [ancient],
            "A snapshot was collected by its age"
        )
        #expect(Self.snapshotIDs(in: dir) == [ancient])
    }

    @Test("An undecodable snapshot is left on disk, not aged out")
    func anUndecodableSnapshotStaysOnDisk() throws {
        // A file truncated by the crash that was happening while it was
        // written cannot be decoded or offered — and since nothing collects
        // by age, it cannot be deleted behind the user's back either. It
        // stays until a decision names it.
        let dir = try Self.makeTempDir()
        defer { Self.cleanup(dir) }
        let manager = RecoveryManager(recoveryDirectory: dir)
        let garbage = try Self.writeRawSnapshot(
            "{\"schemaVersion\": 2, \"content\": 3",
            daysOld: 10,
            in: dir
        )

        #expect(manager.pendingRecoveryEntries().isEmpty)
        #expect(
            Self.snapshotIDs(in: dir) == [garbage],
            "An undecodable snapshot was deleted without a decision"
        )
    }

    @Test("A future-dated snapshot is offered, not anchored for a sweep")
    func aFutureDatedSnapshotIsStillOffered() throws {
        // The retired sweep restamped future-dated files so it could age them
        // out later. There is no later any more: a broken clock must not hide
        // the file from the list either.
        let dir = try Self.makeTempDir()
        defer { Self.cleanup(dir) }
        let manager = RecoveryManager(recoveryDirectory: dir)
        let id = try Self.writeSnapshot(daysOld: -365, in: dir)

        #expect(manager.pendingRecoveryEntries().map(\.0) == [id])
    }

    // MARK: - Not offering the same sheet twice in one session

    @Test("An answered offer stops coming back while the files stay")
    func answeringTheOfferSuppressesItWithoutDeletingAnything() async throws {
        let dir = try Self.makeTempDir()
        defer { Self.cleanupProject(dir) }
        let registry = ProjectRegistry()
        let project = try #require(registry.projectManager(for: dir))
        project.recoveryManager?.snapshotDirtyTabs([Self.crashedTab(in: dir)])

        #expect(await project.pendingRecoveryOffer().count == 1)

        project.markRecoveryOfferAnswered()

        // The sheet does not come back — SwiftUI re-runs the scene's `.task`
        // on restoration and on window close/reopen, and the project outlives
        // both, which is the whole reason the flag lives here.
        #expect(await project.pendingRecoveryOffer().isEmpty)
        #expect(await project.pendingRecoveryOffer().isEmpty)
        // …but nothing was deleted, so the next launch still gets the offer.
        #expect(
            project.recoveryManager?.pendingRecoveryEntries().count == 1
        )
        await project.workspace.waitForLoadingComplete()
    }

    @Test("A restore in flight suppresses the offer without answering it")
    func anInFlightRestoreSuppressesTheOffer() async throws {
        // Restoring is not instantaneous. A snapshot past the large-file
        // threshold parks the whole restore on a native sheet, and the sheet's
        // own state was already cleared synchronously — so a scene `.task`
        // re-running in that window (restoration, or the window closed and
        // reopened) finds both crash files still on disk, owned by no open
        // tab, and `didAnswerRecoveryOffer` still false. It builds the same
        // sheet again. A second restore then migrates the same entries a
        // second time: the parked restore resumes against a detached
        // `TabManager`, and the migration writes a snapshot under a runtime ID
        // no window owns, which comes back on the next launch as a phantom
        // "recovered file" nobody can account for.
        let dir = try Self.makeTempDir()
        defer { Self.cleanupProject(dir) }
        let registry = ProjectRegistry()
        let project = try #require(registry.projectManager(for: dir))
        project.recoveryManager?.snapshotDirtyTabs([Self.crashedTab(in: dir)])
        #expect(await project.pendingRecoveryOffer().count == 1)

        project.beginRecoveryRestore()

        #expect(
            await project.pendingRecoveryOffer().isEmpty,
            """
            A second sheet can be built from the same crash entries while the \
            first restore is still parked (#1503)
            """
        )
        // …and this is not an answer. Nothing was deleted, nothing was
        // marked, and when the restore finishes the offer is available again
        // for whatever it hands back.
        #expect(project.recoveryManager?.pendingRecoveryEntries().count == 1)

        project.endRecoveryRestore()

        #expect(
            await project.pendingRecoveryOffer().count == 1,
            """
            Suppressing the offer during a restore outlived the restore. \
            "Being handled" and "answered" are different claims, and only the \
            second one is allowed to survive the `defer`
            """
        )
        await project.workspace.waitForLoadingComplete()
    }

    @Test("An unanswered offer keeps being offered")
    func anUnansweredOfferKeepsComingBack() async throws {
        let dir = try Self.makeTempDir()
        defer { Self.cleanupProject(dir) }
        let registry = ProjectRegistry()
        let project = try #require(registry.projectManager(for: dir))
        // A snapshot from the session that crashed: its ID names a tab that no
        // longer exists. Writing this with an *open* tab's ID instead would
        // pin the opposite of what the sheet should do — see
        // `theOfferNeverContainsATabTheUserHasOpen`.
        project.recoveryManager?.snapshotDirtyTabs([Self.crashedTab(in: dir)])

        for _ in 0..<3 {
            #expect(await project.pendingRecoveryOffer().count == 1)
        }
        await project.workspace.waitForLoadingComplete()
    }

    @Test("The offer never contains a tab the user has open")
    func theOfferNeverContainsATabTheUserHasOpen() async throws {
        // No crash needed to reach this. Open a project, edit a file, close
        // the window: the project is held alive because it has dirty tabs, and
        // `suspendEditorServices` deliberately writes snapshots for them.
        // Reopen it and `checkForRecovery()` runs against the same
        // `ProjectManager`, asking `pendingRecoveryEntries()`, which only
        // knows "there is a JSON file named after a UUID".
        //
        // Offering those back is not cosmetic. Discard would delete the crash
        // protection of tabs the user is looking at, and restoring would
        // clone each one and then have `migrateRecoverySnapshot` unlink the
        // original's live snapshot. A snapshot whose ID is an open tab's ID is
        // by definition not a crash leftover.
        let dir = try Self.makeTempDir()
        defer { Self.cleanupProject(dir) }
        let registry = ProjectRegistry()
        let project = try #require(registry.projectManager(for: dir))
        let file = dir.appendingPathComponent("dirty.swift")
        try "original".write(to: file, atomically: true, encoding: .utf8)
        project.primaryTabManager.autoSavePreferenceProvider = { false }
        project.primaryTabManager.openTab(url: file)
        project.primaryTabManager.updateContent("modified")
        project.recoveryManager?.snapshotDirtyTabs(project.allTabs)

        // The snapshot exists — the crash protection is doing its job…
        #expect(project.recoveryManager?.pendingRecoveryEntries().count == 1)
        // …and it is not an offer, because its tab is on screen.
        #expect(await project.pendingRecoveryOffer().isEmpty)
        await project.workspace.waitForLoadingComplete()
    }

    @Test("The directory listing runs off the main actor")
    func theListingRunsOffTheMainActor() async throws {
        // `pendingRecoveryEntries()` opens and fully decodes every file in the
        // directory, and each one is a whole unsaved buffer with no size cap —
        // `snapshotDirtyTabs` selects on `isDirty && kind == .text`, and the
        // 1 MB large-file threshold is not applied to it. Before this branch
        // the directory was emptied on every clean quit, so a launch paid for
        // it at most once, after a crash. Since #1760 snapshots are held until
        // the user decides, and the scene `.task` re-runs on restoration and
        // on close/reopen, which would put three 40 MB buffers in front of
        // the window on every launch and every reopen, indefinitely.
        // AGENTS.md: never block the main thread with file I/O.
        //
        // This test does not compile at all unless the listing is
        // `nonisolated` — that is half the assertion — and the thread check is
        // the other half.
        let dir = try Self.makeTempDir()
        defer { Self.cleanup(dir) }
        let manager = RecoveryManager(recoveryDirectory: dir)
        manager.snapshotDirtyTabs([
            Self.dirtyTab(path: "/tmp/a.swift"),
            Self.dirtyTab(path: "/tmp/b.swift"),
        ])

        let observed = await Task.detached(priority: .userInitiated) {
            (
                count: RecoveryManager.readEntries(in: dir).count,
                onMain: pthread_main_np() != 0
            )
        }.value

        #expect(observed.count == 2)
        #expect(
            observed.onMain == false,
            "The snapshot listing is still running on the main thread"
        )
    }

    @Test("An offer answered while the directory is read is not delivered")
    func answeringDuringTheListingSuppressesTheOffer() async throws {
        // The suspension `pendingRecoveryOffer()` gained is a window, and the
        // two flags it checks are exactly what that window can invalidate: a
        // restore can begin, or the user can answer the sheet, between the
        // listing starting and its results coming back. Checking only before
        // the `await` would let a stale listing repopulate `recoveryEntries`
        // and put a second sheet on screen over the answer that was just given
        // (#1503).
        let dir = try Self.makeTempDir()
        defer { Self.cleanupProject(dir) }
        let registry = ProjectRegistry()
        let project = try #require(registry.projectManager(for: dir))
        project.recoveryManager?.snapshotDirtyTabs([Self.crashedTab(in: dir)])
        #expect(await project.pendingRecoveryOffer().count == 1)

        // A gate, not a `Task.yield()`. Yielding only asks the scheduler to
        // run the task; it does not stop the task from running *past* the
        // listing, and on a loaded machine it regularly did — the listing
        // finished, the offer was delivered, and the answer below arrived too
        // late to suppress anything. That is how this test failed one run in
        // three on CI (#1518). The seam parks the task exactly where the race
        // it describes lives: after the listing, before the flags are re-read.
        let gate = RecoveryListingGate()
        project.recoveryOfferListingSeam = { await gate.pause() }

        let inFlight = Task { @MainActor in
            await project.pendingRecoveryOffer()
        }
        await gate.waitUntilPaused()
        project.markRecoveryOfferAnswered()
        await gate.release()

        #expect(
            await inFlight.value.isEmpty,
            """
            A listing that started before the offer was answered still \
            delivered its entries
            """
        )
        // …and the files are all still there, so the next launch offers them.
        #expect(project.recoveryManager?.pendingRecoveryEntries().count == 1)
        await project.workspace.waitForLoadingComplete()
    }

    @Test("A live tab's snapshot is filtered out, a crash snapshot is not")
    func theOfferKeepsCrashSnapshotsAndDropsLiveOnes() async throws {
        let dir = try Self.makeTempDir()
        defer { Self.cleanupProject(dir) }
        let registry = ProjectRegistry()
        let project = try #require(registry.projectManager(for: dir))
        let file = dir.appendingPathComponent("dirty.swift")
        try "original".write(to: file, atomically: true, encoding: .utf8)
        project.primaryTabManager.autoSavePreferenceProvider = { false }
        project.primaryTabManager.openTab(url: file)
        project.primaryTabManager.updateContent("modified")
        let crashed = Self.crashedTab(in: dir)
        project.recoveryManager?.snapshotDirtyTabs(project.allTabs + [crashed])

        #expect(project.recoveryManager?.pendingRecoveryEntries().count == 2)
        #expect(await project.pendingRecoveryOffer().map(\.0) == [crashed.id])
        await project.workspace.waitForLoadingComplete()
    }

    // MARK: - File ▸ Recover Unsaved Work… (#1760)

    @Test("Work put off with Later stays reachable through the menu")
    func theMenuListsWhatLaterLeftBehind() async throws {
        // "Later" silences the launch offer, and since #1760 nothing ever
        // collects the files by age — so the menu, not the next launch, is
        // the only way back. An answered flag that made the menu lie would
        // turn "Later" into a soft deletion.
        let dir = try Self.makeTempDir()
        defer { Self.cleanupProject(dir) }
        let registry = ProjectRegistry()
        let project = try #require(registry.projectManager(for: dir))
        let crashed = Self.crashedTab(in: dir)
        project.recoveryManager?.snapshotDirtyTabs([crashed])
        #expect(await project.pendingRecoveryOffer().count == 1)

        project.markRecoveryOfferAnswered()
        #expect(await project.pendingRecoveryOffer().isEmpty)

        // The menu asks the project directly and does not consult the flag.
        let listed = await project.recoveryEntriesForMenu()
        #expect(listed.map(\.0) == [crashed.id])
        // …and nothing was deleted by any of this: the relaunch that follows
        // a crash or a quit finds the same file on disk.
        #expect(
            project.recoveryManager?.pendingRecoveryEntries().count == 1
        )
        await project.workspace.waitForLoadingComplete()
    }

    @Test("The menu never lists a snapshot the user is looking at")
    func theMenuNeverListsAnOpenTabsSnapshot() async throws {
        let dir = try Self.makeTempDir()
        defer { Self.cleanupProject(dir) }
        let registry = ProjectRegistry()
        let project = try #require(registry.projectManager(for: dir))
        let file = dir.appendingPathComponent("dirty.swift")
        try "original".write(to: file, atomically: true, encoding: .utf8)
        project.primaryTabManager.autoSavePreferenceProvider = { false }
        project.primaryTabManager.openTab(url: file)
        project.primaryTabManager.updateContent("modified")
        project.recoveryManager?.snapshotDirtyTabs(project.allTabs)

        #expect(
            await project.recoveryEntriesForMenu().isEmpty,
            """
            The menu offered the crash protection of a buffer the user is \
            looking at; Discard there would delete it
            """
        )
        await project.workspace.waitForLoadingComplete()
    }

    // MARK: - Helpers

    private static func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PineRecoverySweepTests-\(UUID().uuidString)"
            )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }

    private static func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Removes a project directory *and* the recovery subdirectory Pine
    /// created for it under Application Support.
    ///
    /// Any test that builds a real `ProjectManager` gets a real
    /// `RecoveryManager` rooted at `RecoveryManager.directory(for:)` — a
    /// SHA-256 of the project path under the user's own Application Support,
    /// not under the temporary directory the test cleans up. Removing only the
    /// project left one subdirectory per test run behind. (Nothing in the app
    /// collects these any more — #1760 removed the launch sweep — so a test
    /// suite certainly may not lean on that.)
    private static func cleanupProject(_ projectURL: URL) {
        cleanup(projectURL)
        cleanup(RecoveryManager.directory(for: projectURL))
    }

    private static func dirtyTab(path: String) -> EditorTab {
        EditorTab(
            url: URL(fileURLWithPath: path),
            content: "unsaved",
            savedContent: "saved"
        )
    }

    /// A dirty tab that belongs to no window: the shape of what a crash leaves
    /// behind, and the only shape that should ever become an offer.
    private static func crashedTab(in dir: URL) -> EditorTab {
        EditorTab(
            url: dir.appendingPathComponent("crashed.swift"),
            content: "unsaved",
            savedContent: "saved"
        )
    }

    /// Writes a snapshot the way production writes one: the entry's timestamp
    /// and the file's modification date are the same moment, because a single
    /// write sets both. Tests that fabricate an old entry inside a
    /// just-written file are describing a file the app cannot produce.
    ///
    /// A negative `daysOld` puts the snapshot in the future.
    @discardableResult
    private static func writeSnapshot(
        id: UUID = UUID(),
        daysOld: Double,
        schemaVersion: Int? = RecoveryEntry.currentSchemaVersion,
        in dir: URL
    ) throws -> UUID {
        let when = Date().addingTimeInterval(-daysOld * 24 * 3600)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let entry = RecoveryEntry(
            schemaVersion: schemaVersion,
            originalPath: "/tmp/\(id.uuidString).swift",
            content: "unsaved",
            timestamp: when,
            encoding: .utf8
        )
        let url = dir.appendingPathComponent("\(id.uuidString).json")
        try encoder.encode(entry).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: when],
            ofItemAtPath: url.path
        )
        return id
    }

    /// Writes an arbitrary JSON body under a snapshot's name, with a matching
    /// modification date. For shapes this build's `RecoveryEntry` cannot
    /// decode, which is the interesting half of schema versioning.
    @discardableResult
    private static func writeRawSnapshot(
        _ json: String,
        daysOld: Double,
        in dir: URL
    ) throws -> UUID {
        let id = UUID()
        let when = Date().addingTimeInterval(-daysOld * 24 * 3600)
        let url = dir.appendingPathComponent("\(id.uuidString).json")
        try Data(json.utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: when],
            ofItemAtPath: url.path
        )
        return id
    }

    /// Read through `FileManager`, not `URL.resourceValues`: a `URL` caches
    /// the resource values it has been asked for, so re-reading the same
    /// `URL` after a sweep hands back the date from before it.
    private static func modificationDate(of url: URL) throws -> Date {
        try #require(
            FileManager.default.attributesOfItem(atPath: url.path)[
                .modificationDate
            ] as? Date
        )
    }

    /// Every snapshot file in the directory, readable or not — the sweep's
    /// own view, which `pendingRecoveryEntries()` cannot give.
    private static func snapshotIDs(in dir: URL) -> Set<UUID> {
        let names = (try? FileManager.default.contentsOfDirectory(
            atPath: dir.path
        )) ?? []
        return Set(
            names
                .filter { $0.hasSuffix(".json") }
                .compactMap { UUID(uuidString: String($0.dropLast(5))) }
        )
    }
}

/// Parks whoever calls ``pause()`` until ``release()``, and lets the test wait
/// for that to have happened.
private actor RecoveryListingGate {
    private var isPaused = false
    private var pausedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func pause() async {
        isPaused = true
        let waiters = pausedWaiters
        pausedWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilPaused() async {
        guard !isPaused else { return }
        await withCheckedContinuation { continuation in
            pausedWaiters.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
