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

    // MARK: - The line in `applicationWillTerminate` itself

    @Test("Quitting cleanly takes this session's snapshots and keeps the crash ones")
    func cleanTerminationSweepsOnlyTheOpenTabs() throws {
        // Everything above drives `deleteSnapshotsOfOpenTabs(_:)` directly.
        // That leaves the one production line that decides what a clean quit
        // destroys — the `pm.allTabs.map(\.id)` in
        // `AppDelegate.applicationWillTerminate` — executed by nothing. A
        // plausible tidy-up:
        //
        //     pm.recoveryManager?.deleteSnapshotsOfOpenTabs(
        //         (pm.recoveryManager?.pendingRecoveryEntries() ?? []).map(\.0)
        //     )
        //
        // compiles, reads like a simplification, and restores the original
        // bug in full: quitting with the recovery sheet on screen unlinks
        // every snapshot it was offering. So this drives the real delegate.
        //
        // Two open tabs, in two different panes, because the line under test
        // says `pm.allTabs` and a single tab in `primaryTabManager` cannot
        // tell that apart from `pm.primaryTabManager.tabs`. With the split,
        // the narrower spelling leaves the second pane's snapshot on disk —
        // a file this session is answerable for, coming back on the next
        // launch as a "recovered file" for a buffer that was saved.
        let dir = try Self.makeTempDir()
        defer { Self.cleanupProject(dir) }
        let registry = ProjectRegistry()
        let project = try #require(registry.projectManager(for: dir))
        let manager = try #require(project.recoveryManager)

        // A snapshot belonging to a tab that is open and — by the time we
        // quit — saved. This session is answerable for it.
        let file = dir.appendingPathComponent("open.swift")
        try "original".write(to: file, atomically: true, encoding: .utf8)
        project.primaryTabManager.autoSavePreferenceProvider = { false }
        project.primaryTabManager.openTab(url: file)
        project.primaryTabManager.updateContent("modified")

        // …and the same thing again in a second editor pane.
        let split = dir.appendingPathComponent("split.swift")
        try "original".write(to: split, atomically: true, encoding: .utf8)
        let secondPaneID = try #require(
            project.paneManager.splitPane(
                project.paneManager.activePaneID,
                axis: .horizontal
            )
        )
        let secondPane = try #require(
            project.paneManager.tabManager(for: secondPaneID)
        )
        secondPane.autoSavePreferenceProvider = { false }
        secondPane.openTab(url: split)
        secondPane.updateContent("modified")

        manager.snapshotDirtyTabs(project.allTabs)
        project.primaryTabManager.updateContent("original")
        secondPane.updateContent("original")
        let openTabIDs = Set(project.allTabs.map(\.id))
        #expect(
            openTabIDs.count == 2,
            "The fixture needs a tab in each pane for `allTabs` to matter"
        )
        #expect(
            project.primaryTabManager.tabs.count == 1,
            """
            Both tabs ended up in the primary pane, so this test can no \
            longer see the difference between `allTabs` and \
            `primaryTabManager.tabs`
            """
        )

        // …and a snapshot from the crash, belonging to no tab at all.
        let crashed = Self.crashedTab(in: dir)
        manager.snapshotDirtyTabs([crashed])

        #expect(!project.hasUnsavedChanges, "The clean-quit branch must run")
        #expect(
            Set(manager.pendingRecoveryEntries().map(\.0))
                == openTabIDs.union([crashed.id])
        )

        let delegate = AppDelegate()
        delegate.registry = registry
        delegate.applicationWillTerminate(
            Notification(name: NSApplication.willTerminateNotification)
        )

        #expect(
            manager.pendingRecoveryEntries().map(\.0) == [crashed.id],
            """
            A clean quit did not leave exactly the undecided crash snapshot \
            behind. Deleting it is #1503: the user quits Pine with the \
            recovery sheet open, or after closing it with Escape, and the \
            work it was offering is gone (#1503)
            """
        )
    }

    @Test("Quitting with unsaved work leaves every snapshot alone")
    func terminationWithUnsavedWorkSweepsNothing() throws {
        // The other side of the same `if`: the sweep is gated on the session
        // having nothing unsaved, and a dirty tab's snapshot is the crash
        // protection for work that is still on screen.
        //
        // The unsaved buffer is deliberately in the *second* pane, with the
        // primary holding a saved one. Both the gate (`hasUnsavedChanges`) and
        // the sweep's argument (`pm.allTabs`) walk every pane, and with a
        // single tab in `primaryTabManager` a narrowing of either to the
        // primary pane is invisible: here it opens the gate on a session that
        // has unsaved work and unlinks the crash protection of a buffer the
        // user is looking at.
        let dir = try Self.makeTempDir()
        defer { Self.cleanupProject(dir) }
        let registry = ProjectRegistry()
        let project = try #require(registry.projectManager(for: dir))
        let manager = try #require(project.recoveryManager)

        let file = dir.appendingPathComponent("saved.swift")
        try "original".write(to: file, atomically: true, encoding: .utf8)
        project.primaryTabManager.autoSavePreferenceProvider = { false }
        project.primaryTabManager.openTab(url: file)
        project.primaryTabManager.updateContent("modified")

        let split = dir.appendingPathComponent("dirty.swift")
        try "original".write(to: split, atomically: true, encoding: .utf8)
        let secondPaneID = try #require(
            project.paneManager.splitPane(
                project.paneManager.activePaneID,
                axis: .horizontal
            )
        )
        let secondPane = try #require(
            project.paneManager.tabManager(for: secondPaneID)
        )
        secondPane.autoSavePreferenceProvider = { false }
        secondPane.openTab(url: split)
        secondPane.updateContent("modified")

        manager.snapshotDirtyTabs(project.allTabs)
        // Only the primary pane's buffer goes back to its saved contents.
        project.primaryTabManager.updateContent("original")
        let crashed = Self.crashedTab(in: dir)
        manager.snapshotDirtyTabs([crashed])
        let before = Set(manager.pendingRecoveryEntries().map(\.0))
        #expect(before.count == 3)
        #expect(project.hasUnsavedChanges)
        #expect(
            !project.primaryTabManager.hasUnsavedChanges,
            """
            The unsaved buffer has to live outside the primary pane, or a \
            gate narrowed to `primaryTabManager` still reads "dirty" and this \
            test proves nothing
            """
        )

        let delegate = AppDelegate()
        delegate.registry = registry
        delegate.applicationWillTerminate(
            Notification(name: NSApplication.willTerminateNotification)
        )

        #expect(Set(manager.pendingRecoveryEntries().map(\.0)) == before)
    }

    // MARK: - The published retention window

    @Test("The sheet's footnote and the launch sweep read the same number")
    func retentionWindowIsASingleNumber() throws {
        // "Later" is safe but not unlimited, and the sheet says how long.
        // Two literals would let the promise drift from the behaviour.
        #expect(RecoveryManager.staleEntryRetentionDays == 7)
        let source = try String(
            contentsOf: Self.repositoryRoot()
                .appendingPathComponent("Pine/PineApp.swift"),
            encoding: .utf8
        )
        #expect(
            !source.contains("cleanupAllStaleEntries(olderThan: 7)"),
            "The launch sweep hardcodes its own retention window again"
        )
    }

    @Test("The sheet still prints the retention window it promises")
    func theSheetStatesTheRetentionWindow() throws {
        // `retentionNoticeIsLocalizedEverywhere` only proves the string exists
        // in the catalog. Deleting the `Text` from the sheet's `body` breaks
        // nothing else — the sheet is sized by `minWidth`, so it does not even
        // change shape — and this branch's central claim, that "Later" is a
        // bounded promise the user can read, silently becomes false with the
        // whole suite green. The literal is banned here as well as in
        // `PineApp.swift`: the sheet is the surface the number is *read* on,
        // so it is the one place a drifting copy does its damage.
        let source = try String(
            contentsOf: Self.repositoryRoot()
                .appendingPathComponent("Pine/RecoveryDialogView.swift"),
            encoding: .utf8
        )

        #expect(
            source.contains("Strings.recoveryRetentionNotice("),
            "The recovery sheet no longer tells the user how long Later lasts"
        )
        #expect(
            source.contains("RecoveryManager.staleEntryRetentionDays"),
            "The sheet's footnote no longer reads the sweep's own constant"
        )
        #expect(
            !source.contains("days: 7"),
            "The sheet hardcodes a retention window that can drift from the sweep"
        )
    }

    @Test("A snapshot older than the retention window is collected")
    func snapshotsExpireAtTheStatedBoundary() throws {
        let dir = try Self.makeTempDir()
        defer { Self.cleanup(dir) }
        let manager = RecoveryManager(recoveryDirectory: dir)
        let days = Double(RecoveryManager.staleEntryRetentionDays)

        let fresh = try Self.writeSnapshot(daysOld: days - 1, in: dir)
        try Self.writeSnapshot(daysOld: days + 1, in: dir)

        manager.cleanupStaleEntries(
            olderThan: RecoveryManager.staleEntryRetentionDays
        )

        #expect(manager.pendingRecoveryEntries().map(\.0) == [fresh])
    }

    @Test("A file the filesystem calls fresh is kept without being decoded")
    func aFreshModificationDateKeepsTheFileWhateverItClaims() throws {
        // The launch sweep runs on the main actor and a snapshot carries a
        // whole unsaved buffer, so it now settles a file by its modification
        // date whenever it can and only decodes what that leaves undecided —
        // in steady state, nothing (AGENTS.md: never block the main thread
        // with file I/O). The fast path is observable exactly here: an entry
        // dated outside the window in a file written moments ago is kept.
        //
        // One write sets both dates, so production cannot make them disagree;
        // a restored backup can, and the disagreement is resolved toward
        // keeping the file, never toward deleting it.
        let dir = try Self.makeTempDir()
        defer { Self.cleanup(dir) }
        let manager = RecoveryManager(recoveryDirectory: dir)
        let id = try Self.writeSnapshot(daysOld: 30, in: dir)
        try FileManager.default.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: dir.appendingPathComponent("\(id.uuidString).json").path
        )

        manager.cleanupStaleEntries(olderThan: 7)

        #expect(manager.pendingRecoveryEntries().map(\.0) == [id])
    }

    // MARK: - The files that used to be immortal

    @Test("An unreadable snapshot is collected instead of living forever")
    func anUndecodableSnapshotIsCollected() throws {
        // Truncated by the crash that was happening while it was written.
        // `pendingRecoveryEntries()` cannot show it and the sweep used to
        // `continue` past it, so the user could neither see it nor delete it,
        // it kept its project's directory alive forever, and it logged an
        // error on every launch. It is not content anybody could have decided
        // about, so ageing it out is not a decision taken on their behalf.
        let dir = try Self.makeTempDir()
        defer { Self.cleanup(dir) }
        let manager = RecoveryManager(recoveryDirectory: dir)
        let url = dir.appendingPathComponent("\(UUID().uuidString).json")
        try Data("{\"originalPath\": \"/tmp/a.swift\", tru".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-8 * 24 * 3600)],
            ofItemAtPath: url.path
        )

        manager.cleanupStaleEntries(olderThan: 7)

        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("A recent unreadable snapshot is left alone")
    func aRecentUndecodableSnapshotIsKept() throws {
        let dir = try Self.makeTempDir()
        defer { Self.cleanup(dir) }
        let manager = RecoveryManager(recoveryDirectory: dir)
        let url = dir.appendingPathComponent("\(UUID().uuidString).json")
        try Data("not json at all".utf8).write(to: url)

        manager.cleanupStaleEntries(olderThan: 7)

        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("A snapshot from a newer schema outlives the normal window")
    func anUnsupportedSchemaGetsALongerHorizon() throws {
        // The real producer: a beta wrote `schemaVersion: 2` and the user went
        // back to a release build. The normal window bounds files a user was
        // shown and left alone for a week; a stamp from a build that is not
        // running right now says nothing about whether they have decided, so
        // it gets a multiple of the window — and still leaves eventually, so
        // a permanently orphaned file cannot pin its project's directory
        // open. These two decode, so they are also offered (#1503): the
        // longer horizon buys time, it does not decide visibility.
        let dir = try Self.makeTempDir()
        defer { Self.cleanup(dir) }
        let manager = RecoveryManager(recoveryDirectory: dir)
        let days = RecoveryManager.staleEntryRetentionDays
        let multiplier = RecoveryManager.unsupportedSchemaRetentionMultiplier
        #expect(multiplier > 1)

        let survivor = try Self.writeSnapshot(
            daysOld: Double(days) + 1,
            schemaVersion: RecoveryEntry.currentSchemaVersion + 1,
            in: dir
        )
        let expired = try Self.writeSnapshot(
            daysOld: Double(days * multiplier) + 1,
            schemaVersion: RecoveryEntry.currentSchemaVersion + 1,
            in: dir
        )

        manager.cleanupStaleEntries(olderThan: days)

        #expect(Self.snapshotIDs(in: dir) == [survivor])
        #expect(!Self.snapshotIDs(in: dir).contains(expired))
        // …and what survived is offered, not silently held. A build that can
        // read a buffer must not both hide it and eventually delete it, which
        // is what the old "unsupported schema is not shown" rule amounted to
        // on precisely this file (#1503).
        #expect(manager.pendingRecoveryEntries().map(\.0) == [survivor])
    }

    @Test("A future-dated snapshot is anchored to the sweep, then collected")
    func aFutureDatedSnapshotStopsBeingImmortal() throws {
        // A clock moved forward, a restored VM snapshot, a bad RTC. Judged by
        // `timestamp < cutoff` alone the comparison can never come true, so
        // the file outlived every sweep there would ever be. The first sweep
        // that sees it gives it a real anchor — now — and the next one that
        // finds that anchor old collects it.
        let dir = try Self.makeTempDir()
        defer { Self.cleanup(dir) }
        let manager = RecoveryManager(recoveryDirectory: dir)
        let id = try Self.writeSnapshot(daysOld: -365, in: dir)
        let url = dir.appendingPathComponent("\(id.uuidString).json")

        manager.cleanupStaleEntries(olderThan: 7)

        // Kept — a date nobody can trust is not a reason to delete work…
        #expect(FileManager.default.fileExists(atPath: url.path))
        // Through `FileManager`, not `URL.resourceValues`: a `URL` caches the
        // resource values it has been asked for, so re-reading the same `URL`
        // after the sweep hands back the date from before it.
        let stamped = try #require(
            FileManager.default.attributesOfItem(atPath: url.path)[
                .modificationDate
            ] as? Date
        )
        #expect(
            abs(stamped.timeIntervalSinceNow) < 60,
            """
            The sweep left the file's date where it was (\(stamped)) instead \
            of anchoring it to this run. A date the sweep cannot reach is a \
            file the sweep can never collect
            """
        )

        // …and it is no longer immortal: the anchor ages like any other date.
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-8 * 24 * 3600)],
            ofItemAtPath: url.path
        )
        manager.cleanupStaleEntries(olderThan: 7)

        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("A snapshot a few seconds ahead of the clock is not restamped")
    func aSlightlyFutureDateIsToleratedRatherThanRewritten() throws {
        // Re-anchoring is a one-way loss: for a snapshot whose JSON cannot be
        // decoded, the modification date is the only surviving record of when
        // it was written, and restamping overwrites it. Firing on any date
        // past `now` would do that to ordinary files — an NTP step, a network
        // volume a second ahead, a snapshot written in the same second the
        // sweep runs. `futureDateTolerance` is the fence.
        let dir = try Self.makeTempDir()
        defer { Self.cleanup(dir) }
        let manager = RecoveryManager(recoveryDirectory: dir)
        #expect(RecoveryManager.futureDateTolerance > 0)
        let id = try Self.writeSnapshot(daysOld: -10.0 / 86_400, in: dir)
        let url = dir.appendingPathComponent("\(id.uuidString).json")
        let before = try Self.modificationDate(of: url)

        manager.cleanupStaleEntries(olderThan: 7)

        let after = try Self.modificationDate(of: url)
        #expect(
            abs(after.timeIntervalSince(before)) < 1,
            """
            A snapshot ten seconds ahead of the sweep's clock was re-anchored \
            (\(before) became \(after)). Clock jitter is not a broken clock, \
            and the date it destroys is provenance nothing else records
            """
        )
        #expect(manager.pendingRecoveryEntries().map(\.0) == [id])
    }

    @Test("An old snapshot with a future modification date still expires")
    func aFutureModificationDateDoesNotProtectAnOldEntry() throws {
        let dir = try Self.makeTempDir()
        defer { Self.cleanup(dir) }
        let manager = RecoveryManager(recoveryDirectory: dir)
        let id = try Self.writeSnapshot(daysOld: 30, in: dir)
        let url = dir.appendingPathComponent("\(id.uuidString).json")
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(365 * 24 * 3600)],
            ofItemAtPath: url.path
        )

        manager.cleanupStaleEntries(olderThan: 7)

        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("A modification date older than the entry cannot delete it")
    func anOlderModificationDateCannotDeleteAFreshEntry() throws {
        // The mirror of `aFreshModificationDateKeepsTheFileWhateverItClaims`,
        // and the direction nothing pinned. Taking the earlier of the two
        // dates reads like caution and is the opposite: it lets the
        // filesystem's word delete a snapshot the entry itself says is a day
        // old. Anything that moves an mtime backwards produces it — a sync
        // client, a restore tool, `touch -t`, a volume whose timestamps are
        // coarser than those of the one the file came from (SMB, exFAT).
        let dir = try Self.makeTempDir()
        defer { Self.cleanup(dir) }
        let manager = RecoveryManager(recoveryDirectory: dir)
        let id = try Self.writeSnapshot(daysOld: 1, in: dir)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-30 * 24 * 3600)],
            ofItemAtPath: dir
                .appendingPathComponent("\(id.uuidString).json").path
        )

        manager.cleanupStaleEntries(olderThan: 7)

        #expect(
            manager.pendingRecoveryEntries().map(\.0) == [id],
            """
            A backdated modification date deleted a snapshot whose own \
            timestamp is a day old. The filesystem date is allowed to keep a \
            file, never to condemn one (#1503)
            """
        )
    }

    @Test("A newer schema that changed shape also gets the longer horizon")
    func aNonAdditiveSchemaGetsALongerHorizon() throws {
        // `anUnsupportedSchemaGetsALongerHorizon` writes `schemaVersion + 1`
        // into an otherwise current entry — a purely additive change, and the
        // one case where the whole `RecoveryEntry` still decodes so the
        // version can be read off the decoded value. The schema changes that
        // actually motivate a version stamp do not decode: rename a field,
        // change its type, add a required one, and `init(from:)` throws before
        // it ever reaches `schemaVersion`. Deciding the horizon from a
        // successful decode grants the long window to exactly the files that
        // least need it, and deletes this user's unrecoverable work — which
        // this build refuses to show them — on the seventh day.
        let dir = try Self.makeTempDir()
        defer { Self.cleanup(dir) }
        let manager = RecoveryManager(recoveryDirectory: dir)
        let days = RecoveryManager.staleEntryRetentionDays
        let multiplier = RecoveryManager.unsupportedSchemaRetentionMultiplier
        // `body` where this build wants `content`, and a numeric `timestamp`.
        let json = """
            {"schemaVersion": \(RecoveryEntry.currentSchemaVersion + 1), \
            "originalPath": "/tmp/a.swift", "body": "unsaved", \
            "timestamp": 776000000, "encodingRawValue": 4}
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(throws: (any Error).self) {
            try decoder.decode(RecoveryEntry.self, from: Data(json.utf8))
        }

        let survivor = try Self.writeRawSnapshot(
            json,
            daysOld: Double(days) + 1,
            in: dir
        )
        let expired = try Self.writeRawSnapshot(
            json,
            daysOld: Double(days * multiplier) + 1,
            in: dir
        )

        manager.cleanupStaleEntries(olderThan: days)

        #expect(
            Self.snapshotIDs(in: dir) == [survivor],
            """
            A snapshot from a schema this build cannot decode was collected \
            at the normal horizon. The version stamp has to be read before \
            the full decode, or the constant that exists for this file never \
            applies to it (#1503)
            """
        )
        #expect(!Self.snapshotIDs(in: dir).contains(expired))
    }

    @Test("A file the sweep cannot read is kept, not aged out")
    func anUnreadableSnapshotIsKept() throws {
        // Launch is when every language server, file-system watcher and
        // terminal in the app is starting at once, so a transient `EIO` or
        // `EMFILE` here is a live possibility. A file the process could not
        // open has not told anybody how old it is, and ageing it out by its
        // modification date means deleting undecided work on the strength of
        // a read that failed.
        let dir = try Self.makeTempDir()
        defer { Self.cleanup(dir) }
        let manager = RecoveryManager(recoveryDirectory: dir)
        let id = try Self.writeSnapshot(daysOld: 30, in: dir)
        let url = dir.appendingPathComponent("\(id.uuidString).json")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0],
            ofItemAtPath: url.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        }
        guard (try? Data(contentsOf: url)) == nil else {
            // Root, or a filesystem that ignores mode bits: the premise
            // cannot be established, so there is nothing here to assert.
            return
        }

        manager.cleanupStaleEntries(olderThan: 7)

        #expect(
            FileManager.default.fileExists(atPath: url.path),
            """
            An unreadable snapshot was deleted by its modification date. \
            Unreadable is not evidence of age (#1503)
            """
        )
    }

    // MARK: - Collecting the per-project subdirectories

    @Test("A subdirectory holding nothing but leftovers is collected")
    func aSubdirectoryWithOnlyLeftoversIsCollected() throws {
        // Snapshots are written with `Data.write(options: .atomic)`, which
        // stages a hidden temporary beside the destination. A crash between
        // the staging and the rename leaves it behind — and it is not a
        // `.json`, so the stale sweep cannot see it, while an emptiness test
        // can. One orphaned temporary used to pin its project's directory
        // open for the life of the machine, long after the project was gone.
        let root = try Self.makeTempDir()
        defer { Self.cleanup(root) }
        let orphaned = root.appendingPathComponent("orphaned")
        let live = root.appendingPathComponent("live")
        for dir in [orphaned, live] {
            try FileManager.default.createDirectory(
                at: dir,
                withIntermediateDirectories: true
            )
        }
        try Data("half a snapshot".utf8).write(
            to: orphaned.appendingPathComponent(".dat.nosync0f12.QwErTy")
        )
        try Data("".utf8).write(to: orphaned.appendingPathComponent(".DS_Store"))
        try Self.writeSnapshot(daysOld: 0, in: live)

        RecoveryManager.cleanupAllStaleEntries(in: root, olderThan: 7)

        #expect(
            !FileManager.default.fileExists(atPath: orphaned.path),
            "A directory holding only leftovers was kept forever"
        )
        #expect(
            FileManager.default.fileExists(atPath: live.path),
            "A directory with a live snapshot in it was collected"
        )
    }

    @Test("A stray file at the recovery root is not swept as a project")
    func aStrayFileAtTheRootIsNotAProject() throws {
        // `.isDirectoryKey` was prefetched here and never consulted, so a
        // `.DS_Store` at the root was handed to a `RecoveryManager` as a
        // project directory and logged a failure on every launch.
        let root = try Self.makeTempDir()
        defer { Self.cleanup(root) }
        let stray = root.appendingPathComponent(".DS_Store")
        try Data("not a project".utf8).write(to: stray)
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(
            at: project,
            withIntermediateDirectories: true
        )
        let old = try Self.writeSnapshot(daysOld: 30, in: project)

        RecoveryManager.cleanupAllStaleEntries(in: root, olderThan: 7)

        #expect(FileManager.default.fileExists(atPath: stray.path))
        #expect(!Self.snapshotIDs(in: project).contains(old))
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
        // Recover All is not instantaneous. A snapshot past the large-file
        // threshold parks the whole restore on a native sheet, and the sheet's
        // own state was already cleared synchronously — so a scene `.task`
        // re-running in that window (restoration, or the window closed and
        // reopened) finds both crash files still on disk, owned by no open
        // tab, and `didAnswerRecoveryOffer` still false. It builds the same
        // sheet again. A second Recover All then migrates the same entries a
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
        // protection of tabs the user is looking at, and Recover All would
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
        // it at most once, after a crash. Now snapshots are held for
        // `staleEntryRetentionDays` after a "Later" and the scene `.task`
        // re-runs on restoration and on close/reopen, which would put three
        // 40 MB buffers in front of the window on every launch and every
        // reopen for a week. AGENTS.md: never block the main thread with file
        // I/O.
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
        // Recover All can begin, or the user can answer the sheet, between the
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

        let inFlight = Task { @MainActor in
            await project.pendingRecoveryOffer()
        }
        // Hands the main actor to the task above, which runs as far as its own
        // suspension — the off-actor listing — and stops there.
        await Task.yield()
        project.markRecoveryOfferAnswered()

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
    /// project left one subdirectory per test run behind. (Since #1503 the
    /// launch sweep does eventually collect them, leftovers and all, but a
    /// test suite should not be leaning on that.)
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
