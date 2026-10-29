//
//  RecoveryManager.swift
//  Pine
//

import CommonCrypto
import Foundation
import os

/// Manages crash recovery snapshots of unsaved editor content.
///
/// Periodically writes dirty tab content to a recovery directory so it can
/// be restored after a crash, force quit, or power loss.
/// Each project gets its own subdirectory to avoid mixing recovery files.
@MainActor
final class RecoveryManager {

    /// `nonisolated` so the off-main-actor listing in ``readEntries(in:)`` can
    /// report what it skipped.
    nonisolated private static let logger = Logger.app

    /// Root recovery directory under Application Support.
    nonisolated static var rootDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pine/Recovery")
    }

    /// Returns a per-project recovery subdirectory based on a SHA-256 hash of the project path.
    nonisolated static func directory(for projectURL: URL) -> URL {
        let path = projectURL.resolvingSymlinksInPath().path
        let hash = sha256(path)
        return rootDirectory.appendingPathComponent(hash)
    }

    /// Periodic snapshot interval in seconds.
    nonisolated static let periodicInterval: TimeInterval = 30

    /// Debounce delay for edit-triggered snapshots.
    nonisolated static let debounceDelay: TimeInterval = 5

    /// How long a snapshot nobody has decided about survives before the
    /// launch-time sweep collects it.
    ///
    /// The recovery sheet prints this number, so closing the sheet without
    /// choosing is a bounded promise the user can read rather than a silent
    /// expiry on the eighth day (#1503). Both the sweep in
    /// `AppDelegate.applicationDidFinishLaunching` and the sheet's footnote
    /// read it from here so the two cannot drift.
    nonisolated static let staleEntryRetentionDays = 7

    /// Multiple of ``staleEntryRetentionDays`` granted to a snapshot written
    /// by a schema this build cannot read.
    ///
    /// The normal horizon bounds files the user was *shown* and chose to leave
    /// alone. A snapshot from a newer build — a beta wrote `schemaVersion: 2`
    /// and they went back to a release — has had no such decision made about
    /// it: either it decoded and was offered on a build that will be replaced
    /// again by the newer one, or it did not decode and could not be shown at
    /// all. Long enough to survive a downgrade and a return, finite so a
    /// permanently orphaned file still leaves and its project subdirectory can
    /// be collected.
    ///
    /// This buys time; it does not decide visibility.
    /// ``readEntries(in:)`` offers every snapshot that decodes, whatever its
    /// stamp says, precisely so no path can delete a buffer this build could
    /// read but refused to show (#1503).
    nonisolated static let unsupportedSchemaRetentionMultiplier = 4

    /// How far ahead of the sweep's own clock a date may sit before it is
    /// treated as a broken clock rather than as jitter.
    ///
    /// NTP steps, a network volume with its own idea of the time, and a
    /// snapshot written in the same second the sweep runs all produce dates a
    /// hair in the future. Re-anchoring on a zero tolerance would rewrite the
    /// modification date of a file the user is actively editing, and that date
    /// is the only record of when an undecodable snapshot was written.
    nonisolated static let futureDateTolerance: TimeInterval = 60

    private let recoveryDirectory: URL
    private let faultInjector: PersistenceFaultInjector
    private var periodicTimer: Timer?
    private var snapshotDebouncer: Debouncer?
    /// Old crash IDs whose recovered buffers now live under a runtime tab ID.
    ///
    /// A failed write of the runtime snapshot leaves the old file in place
    /// and records it here. A later successful periodic snapshot, save, or
    /// close then removes the superseded file as well.
    private var supersededRecoveryIDsByRuntimeID: [UUID: Set<UUID>] = [:]

    /// Tabs provider — set by ProjectManager so periodic snapshots can access current tabs.
    var tabsProvider: (() -> [EditorTab])?

    init(
        recoveryDirectory: URL,
        faultInjector: PersistenceFaultInjector = .processEnvironment
    ) {
        self.recoveryDirectory = recoveryDirectory
        self.faultInjector = faultInjector
    }

    /// Convenience initializer for a specific project.
    convenience init(projectURL: URL) {
        self.init(recoveryDirectory: Self.directory(for: projectURL))
    }

    // MARK: - Snapshot

    /// Writes a recovery file for each dirty tab. Clean/preview tabs are skipped.
    func snapshotDirtyTabs(_ tabs: [EditorTab]) {
        let dirtyTabs = tabs.filter { $0.isDirty && $0.kind == .text }
        guard !dirtyTabs.isEmpty else { return }
        guard ensureDirectoryExists() else { return }
        let encoder = makeRecoveryEncoder()

        for tab in dirtyTabs {
            _ = writeRecoverySnapshot(for: tab, encoder: encoder)
        }
    }

    // MARK: - Delete

    /// Removes the recovery file for a specific tab (e.g., after save or clean close).
    func deleteRecoveryFile(for tabID: UUID) {
        _ = removeRecoveryFileOnly(for: tabID)
        deleteSupersededRecoveryFiles(for: tabID)
    }

    /// Removes exactly the recovery IDs it is given and nothing linked to
    /// them.
    ///
    /// Used by the recovery sheet's Discard action so successfully migrated
    /// runtime snapshots in the same project directory remain intact.
    ///
    /// Named apart from ``deleteSnapshotsOfOpenTabs(_:)`` on purpose. The two
    /// used to differ by one argument label while differing by their entire
    /// blast radius: this one takes crash IDs the user just looked at, that
    /// one takes live tab IDs and also collects whatever crash file each tab
    /// superseded. Passing one's argument to the other is a silent data-loss
    /// bug, so there is no shared base name to autocomplete into.
    func deleteSnapshots(withRecoveryIDs recoveryIDs: [UUID]) {
        for recoveryID in Set(recoveryIDs)
        where removeRecoveryFileOnly(for: recoveryID) {
            forgetSupersededReference(to: recoveryID)
        }
    }

    /// Removes the snapshots this session is answerable for: one per open tab,
    /// plus any superseded crash-ID file still linked to it. Used by the
    /// clean-quit sweep in `AppDelegate.applicationWillTerminate`.
    ///
    /// Deliberately scoped instead of emptying the directory. Everything in
    /// there that no open tab accounts for is crash payload nobody has decided
    /// about yet — the entries the recovery sheet is showing right now, the
    /// ones a user closed the sheet on without choosing, and the ones
    /// ``restorePendingEntries(_:in:context:)`` handed back because they could
    /// not be restored. A directory-wide sweep deletes exactly the work the
    /// recovery sheet exists to protect, and `ProjectManager.hasUnsavedChanges`
    /// cannot veto it because recovery snapshots are not tabs (#1503).
    ///
    /// The one thing this leaves behind is a snapshot for a tab closed earlier
    /// in the session whose unlink failed. That is collected by
    /// ``cleanupAllStaleEntries(olderThan:)`` — offering a stale file once is
    /// recoverable, deleting an undecided one is not.
    func deleteSnapshotsOfOpenTabs(_ tabIDs: [UUID]) {
        for tabID in Set(tabIDs) {
            deleteRecoveryFile(for: tabID)
        }
    }

    // MARK: - Read

    /// Returns all pending recovery entries as (tabID, entry) pairs.
    /// Corrupted or non-JSON files are logged and skipped.
    ///
    /// Synchronous, and it reads and decodes every snapshot in the directory.
    /// The path a launching window takes is
    /// ``pendingRecoveryEntriesOffMainActor()`` — see that method for why the
    /// main actor must not do this work.
    func pendingRecoveryEntries() -> [(UUID, RecoveryEntry)] {
        Self.readEntries(in: recoveryDirectory)
    }

    /// The same listing, performed off the main actor.
    ///
    /// `pendingRecoveryEntries()` opens and fully decodes every snapshot in
    /// the directory, and a snapshot is a whole unsaved buffer — nothing
    /// bounds its size, because ``snapshotDirtyTabs(_:)`` selects on
    /// `isDirty && kind == .text` and the 1 MB large-file threshold is not
    /// applied to it. Before this branch the directory was emptied on every
    /// clean quit, so the cost was paid at most once, on the launch after a
    /// crash. Now snapshots are held for ``staleEntryRetentionDays`` after a
    /// "Later", and the discovery runs from a scene `.task` that SwiftUI
    /// re-runs on scene restoration and on closing and reopening the window:
    /// three 40 MB buffers left for later would otherwise block the main
    /// thread on ~120 MB of reading and decoding before the window draws,
    /// every launch and every reopen, for a week (AGENTS.md: never block the
    /// main thread with file I/O).
    ///
    /// Only the listing moves. The decision about what is worth offering stays
    /// on the main actor in ``ProjectManager/pendingRecoveryOffer()``, which
    /// needs the live tab IDs to filter against.
    func pendingRecoveryEntriesOffMainActor() async -> [(UUID, RecoveryEntry)] {
        let directory = recoveryDirectory
        return await Task.detached(priority: .userInitiated) {
            Self.readEntries(in: directory)
        }.value
    }

    /// Reads and decodes every snapshot in `directory`.
    ///
    /// `nonisolated` and taking the directory as a parameter so it can run on
    /// a background executor. It touches no instance state — the recovery
    /// directory is the whole input.
    ///
    /// **Every entry that decodes is returned, whatever its schema stamp
    /// says.** An unsupported stamp used to be a `continue` here, and that
    /// combination is a trap: a purely additive `schemaVersion: 2` written by
    /// a beta decodes into today's `RecoveryEntry` with real `content`, a real
    /// `originalPath` and a real `timestamp`, and the release build the user
    /// went back to would refuse to show it — while
    /// ``cleanupStaleEntries(olderThan:)`` deleted it after
    /// ``unsupportedSchemaRetentionMultiplier`` × the window. A build that can
    /// read a buffer must not both hide it and eventually destroy it; the
    /// whole point of this branch is that nothing deletes work the user was
    /// never given the chance to decide about (#1503). ``RecoveryEntry/hasSupportedSchema``
    /// stays as a signal — it is logged here, and it still buys the longer
    /// retention horizon in the sweep — but it no longer suppresses the offer.
    ///
    /// What cannot be *decoded* is still not offered, and that is not the same
    /// thing: a file this build cannot turn into content is not content it
    /// could have shown.
    nonisolated static func readEntries(
        in directory: URL
    ) -> [(UUID, RecoveryEntry)] {
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            )
        } catch {
            logger.warning("Cannot list recovery directory: \(error)")
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var results: [(UUID, RecoveryEntry)] = []
        for file in files where file.pathExtension == "json" {
            let name = file.deletingPathExtension().lastPathComponent
            guard let uuid = UUID(uuidString: name) else { continue }
            do {
                let data = try Data(contentsOf: file)
                let entry = try decoder.decode(RecoveryEntry.self, from: data)
                if !entry.hasSupportedSchema {
                    let stamp = entry.schemaVersion ?? -1
                    logger.warning(
                        "Recovery entry \(name) carries schema \(stamp), which this build does not know; offering it anyway because it decoded"
                    )
                }
                results.append((uuid, entry))
            } catch {
                logger.error("Failed to read recovery entry \(name): \(error)")
            }
        }
        return results
    }

    /// Restores crash snapshots into `tabManager`, waiting for any interactive
    /// large-file decision before applying the recovered content.
    ///
    /// A snapshot is deleted only after its tab actually opens and the
    /// recovered buffer has been installed. Cancelled or otherwise unresolved
    /// entries stay on disk for a later recovery attempt.
    ///
    /// - Returns: Entries that could not be restored.
    func restorePendingEntries(
        _ entries: [(UUID, RecoveryEntry)],
        in tabManager: TabManager,
        context: DialogPresentationContext
    ) async -> [(UUID, RecoveryEntry)] {
        var retainedEntries: [(UUID, RecoveryEntry)] = []

        for (recoveryID, entry) in entries {
            if entry.originalPath.isEmpty {
                let result = tabManager.appendRecoveredUntitledTab(
                    displayName: entry.untitledName
                        ?? Strings.recoveryUntitled,
                    content: entry.content,
                    encoding: entry.encoding
                )
                guard case .appended(let recoveredTabID) = result,
                      let recoveredTab = tabManager.tabs.first(where: {
                          $0.id == recoveredTabID
                      }) else {
                    retainedEntries.append((recoveryID, entry))
                    continue
                }
                _ = migrateRecoverySnapshot(
                    from: recoveryID,
                    to: recoveredTab
                )
                continue
            }

            let url = URL(fileURLWithPath: entry.originalPath)
            guard tabManager.canRestoreRecoveryEntry(for: url) else {
                retainedEntries.append((recoveryID, entry))
                continue
            }

            let result = await withCheckedContinuation { continuation in
                tabManager.openTab(
                    url: url,
                    context: context,
                    completion: { continuation.resume(returning: $0) }
                )
            }

            guard case .opened(let tabID) = result,
                  tabManager.tabs.contains(where: { $0.id == tabID }) else {
                retainedEntries.append((recoveryID, entry))
                continue
            }

            let recoveredTabID: UUID
            switch tabManager.appendRecoveredTab(
                basedOn: tabID,
                content: entry.content,
                encoding: entry.encoding
            ) {
            case .appended(let tabID):
                recoveredTabID = tabID
            case .capacityReached, .sourceMissing:
                retainedEntries.append((recoveryID, entry))
                continue
            }

            guard let recoveredTab = tabManager.tabs.first(where: {
                $0.id == recoveredTabID
            }) else {
                retainedEntries.append((recoveryID, entry))
                continue
            }

            // Persist the runtime-ID snapshot before removing the crash-ID
            // snapshot. On failure the old file remains durable and is linked
            // to the runtime tab for cleanup after a later snapshot/save.
            _ = migrateRecoverySnapshot(
                from: recoveryID,
                to: recoveredTab
            )
        }

        return retainedEntries
    }

    /// Replaces an old crash-ID snapshot with the restored runtime tab's
    /// snapshot without creating a durability gap.
    ///
    /// - Returns: `true` when the restored state is durably represented under
    ///   the runtime ID (or is clean and needs no snapshot). `false` means the
    ///   destination write failed and the old snapshot was intentionally kept.
    @discardableResult
    func migrateRecoverySnapshot(
        from recoveryID: UUID,
        to restoredTab: EditorTab
    ) -> Bool {
        guard restoredTab.isDirty && restoredTab.kind == .text else {
            if !removeRecoveryFileOnly(for: recoveryID),
               recoveryID != restoredTab.id {
                recordSupersededRecoveryID(
                    recoveryID,
                    for: restoredTab.id
                )
            }
            return true
        }

        guard ensureDirectoryExists(),
              writeRecoverySnapshot(for: restoredTab) else {
            if recoveryID != restoredTab.id {
                recordSupersededRecoveryID(
                    recoveryID,
                    for: restoredTab.id
                )
            }
            return false
        }

        // When both identities are the same, the atomic write above replaced
        // the old contents in place. Deleting here would remove the only new
        // snapshot.
        guard recoveryID != restoredTab.id else { return true }
        if !removeRecoveryFileOnly(for: recoveryID) {
            recordSupersededRecoveryID(
                recoveryID,
                for: restoredTab.id
            )
        }
        return true
    }

    /// Whether there are any pending recovery files.
    /// More efficient than `pendingRecoveryEntries()` — returns as soon as one valid file is found.
    var hasPendingRecovery: Bool {
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(
                at: recoveryDirectory,
                includingPropertiesForKeys: nil
            )
        } catch {
            return false
        }
        return files.contains { $0.pathExtension == "json" }
    }

    // MARK: - Stale cleanup

    /// Removes recovery files with timestamps older than the given number of days
    /// across *all* project subdirectories, then collects the subdirectories
    /// that hold nothing worth keeping.
    ///
    /// Collecting the per-project subdirectory is load-bearing since #1503:
    /// the clean-quit sweep no longer empties a project's directory, so a
    /// directory is now expected to outlive the project's session and the only
    /// thing that ever removes it is this pass.
    static func cleanupAllStaleEntries(olderThan days: Int) {
        cleanupAllStaleEntries(in: rootDirectory, olderThan: days)
    }

    /// The body of ``cleanupAllStaleEntries(olderThan:)``, against an explicit
    /// root so it can be exercised without writing into the real Application
    /// Support directory.
    static func cleanupAllStaleEntries(in root: URL, olderThan days: Int) {
        let fm = FileManager.default
        let subdirs: [URL]
        do {
            subdirs = try fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey]
            )
        } catch {
            logger.warning("Cannot list recovery root directory: \(error)")
            return
        }

        for subdir in subdirs {
            // `.isDirectoryKey` was prefetched here and then never consulted,
            // so a stray regular file at the root — `.DS_Store` above all —
            // was handed to a `RecoveryManager` as if it were a project
            // directory, and every listing of it failed and logged.
            let isDirectory = (try? subdir.resourceValues(
                forKeys: [.isDirectoryKey]
            ).isDirectory) ?? false
            guard isDirectory else { continue }

            let manager = RecoveryManager(recoveryDirectory: subdir)
            manager.cleanupStaleEntries(olderThan: days)

            do {
                let remaining = try fm.contentsOfDirectory(atPath: subdir.path)
                // Not `remaining.isEmpty`. Snapshots are written with
                // `Data.write(options: .atomic)`, which stages a hidden
                // temporary beside the destination; a crash between the
                // staging and the rename leaves that temporary behind forever.
                // It is not a `.json`, so the sweep above cannot see it — but
                // an emptiness test does, and one orphaned temporary used to
                // pin its project's directory open for the life of the
                // machine. `.DS_Store` did the same. Anything hidden here is
                // leftovers by construction: this directory holds nothing but
                // `<uuid>.json` files that Pine itself writes.
                guard remaining.allSatisfy({ $0.hasPrefix(".") }) else {
                    continue
                }
                do {
                    // Recursive, because the leftovers go with it.
                    try fm.removeItem(at: subdir)
                } catch {
                    logger.error("Failed to remove empty recovery subdir: \(error)")
                }
            } catch {
                logger.warning("Cannot list recovery subdir \(subdir.lastPathComponent): \(error)")
            }
        }
    }

    /// Removes recovery files older than the given number of days.
    ///
    /// **Stats before it reads.** This runs on the main actor from
    /// `applicationDidFinishLaunching`, and since #1503 the directory
    /// deliberately *keeps* crash payload nobody has decided about instead of
    /// being emptied on every clean quit — so the cost of opening every file
    /// to read one `Date` now scales with how much unrecovered work the user
    /// is holding, and a snapshot carries a whole unsaved buffer (Pine's own
    /// large-file threshold is 1MB, and nothing caps a snapshot at it).
    /// `AGENTS.md` forbids blocking the main thread with file I/O. A file
    /// whose modification date is inside the window can only be kept, so one
    /// `stat` settles it, and in steady state — where everything on disk is
    /// younger than the window — nothing is read at all. The date is read
    /// through `includingPropertiesForKeys:` so the values are already
    /// prefetched by the directory enumeration.
    ///
    /// **Which date decides.** The entry's own `timestamp` is the authority
    /// whenever it is usable. The filesystem date only stands in for a file
    /// that has no usable one, and it is never a second opinion that can
    /// overrule a timestamp *into* a deletion: taking the earlier of the two
    /// would let anything that moves an mtime backwards — a sync client, a
    /// restore tool, `touch -t`, a volume with coarser timestamps — delete
    /// undecided work on the filesystem's word against the file's own.
    ///
    /// **Three kinds of file used to be immortal here.** Each was `continue`d
    /// past without ever being reconsidered, so its project's subdirectory
    /// could never be collected by ``cleanupAllStaleEntries(olderThan:)`` long
    /// after the project itself was gone, and it logged an error on every
    /// single launch:
    ///
    /// - **Undecodable.** Truncated by the crash that was happening while it
    ///   was being written, or corrupted since. It ages out on the
    ///   filesystem's own evidence at the normal horizon. This does not weaken
    ///   "never delete a snapshot nobody has decided about": a file that
    ///   cannot be decoded is not content that could have been offered, so
    ///   there was never a decision to make. *Unreadable* is a different
    ///   thing and is not treated as evidence of age at all — see below.
    /// - **A schema this build does not support.** This one *is* the user's
    ///   work, so it gets ``unsupportedSchemaRetentionMultiplier`` times the
    ///   horizon rather than the same one — see that constant. The version
    ///   stamp is probed on its own, before the full decode, because a schema
    ///   change is exactly what makes `RecoveryEntry.init(from:)` throw before
    ///   the version is ever read; deciding the horizon from a successful
    ///   decode would grant the longer window only to purely additive
    ///   schemas, which are the ones that least need it. If it decodes, it is
    ///   also *offered* — ``readEntries(in:)`` does not consult the stamp — so
    ///   the longer horizon covers a file the user has seen and put off, not
    ///   one being destroyed behind their back.
    /// - **Dated in the future.** A clock moved forward, a restored backup, a
    ///   VM snapshot: `timestamp < cutoff` can never come true, so the file
    ///   outlived every sweep. If any date it carries is usable it is judged
    ///   by that one; if every date is in the future by more than
    ///   ``futureDateTolerance`` the file is restamped to now, which gives it
    ///   a real anchor to age from — this sweep's first sighting — instead of
    ///   waiting for the calendar to catch up with a wrong clock.
    ///
    /// A file that cannot be *read* is kept, whatever its dates say. Launch is
    /// when every language server, file-system watcher and terminal in the app
    /// is starting at once, so `EIO` and `EMFILE` are live possibilities here,
    /// and a file the process could not open has not told anybody how old it
    /// is.
    func cleanupStaleEntries(olderThan days: Int) {
        let now = Date()
        let day = 24.0 * 3600
        let cutoff = now.addingTimeInterval(-Double(days) * day)
        let unsupportedCutoff = now.addingTimeInterval(
            -Double(days * Self.unsupportedSchemaRetentionMultiplier) * day
        )
        // The latest moment a date may claim and still be believed.
        let believable = now.addingTimeInterval(Self.futureDateTolerance)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(
                at: recoveryDirectory,
                includingPropertiesForKeys: [.contentModificationDateKey]
            )
        } catch {
            Self.logger.warning("Cannot list recovery directory for cleanup: \(error)")
            return
        }

        for file in files where file.pathExtension == "json" {
            let modified = Self.modificationDate(of: file)
            // Inside the window by the filesystem's reckoning: keep it without
            // reading it. A date well in the future is not "inside the
            // window", it is a date to distrust, so it does not take this path.
            if let modified, modified >= cutoff, modified <= believable {
                continue
            }

            guard let data = try? Data(contentsOf: file) else {
                Self.logger.error(
                    "Cannot read recovery file during cleanup, keeping it: \(file.lastPathComponent)"
                )
                continue
            }

            // Probed separately and first: see the docstring.
            let probe = try? decoder.decode(
                RecoveryEntry.SchemaProbe.self,
                from: data
            )
            let horizon = RecoveryEntry.isSupportedSchema(probe?.schemaVersion)
                ? cutoff
                : unsupportedCutoff

            var recorded: Date?
            do {
                recorded = try decoder
                    .decode(RecoveryEntry.self, from: data)
                    .timestamp
            } catch {
                Self.logger.error(
                    "Undecodable recovery file, ageing it out by its modification date \(file.lastPathComponent): \(error)"
                )
            }

            let age: Date
            if let recorded, recorded <= believable {
                // The file's own account of itself, believed over the
                // filesystem's in both directions.
                age = recorded
            } else if let modified, modified <= believable {
                // No usable timestamp — either the entry has none or the one
                // it has is from a broken clock — so the filesystem stands in.
                age = modified
            } else if recorded != nil || modified != nil {
                Self.restampAsSeenNow(file, at: now)
                continue
            } else {
                // Nothing to judge it by, and guessing would mean guessing at
                // a deletion.
                continue
            }

            guard age < horizon else { continue }
            do {
                try FileManager.default.removeItem(at: file)
            } catch {
                Self.logger.error("Failed to remove stale recovery file \(file.lastPathComponent): \(error)")
            }
        }
    }

    /// The file's modification date, or `nil` if the filesystem will not say.
    private static func modificationDate(of file: URL) -> Date? {
        try? file.resourceValues(
            forKeys: [.contentModificationDateKey]
        ).contentModificationDate
    }

    /// Anchors a file whose every recorded date lies in the future to this
    /// sweep, so the next one can age it out normally.
    ///
    /// Touching the metadata and not the content: the snapshot itself stays
    /// byte-for-byte what the user's editor wrote, and only the clock claim
    /// that made it un-collectable is replaced.
    ///
    /// It is still destructive in one respect, which is why it is fenced off
    /// behind ``futureDateTolerance`` rather than firing on any date past
    /// `now`: for a snapshot whose JSON cannot be decoded, the modification
    /// date is the *only* surviving record of when it was written, and this
    /// overwrites it. The trade is deliberate — a date nothing can reach is a
    /// file no sweep can ever collect — but it is a one-way loss of the one
    /// piece of provenance such a file has left.
    private static func restampAsSeenNow(_ file: URL, at now: Date) {
        do {
            try FileManager.default.setAttributes(
                [.modificationDate: now],
                ofItemAtPath: file.path
            )
        } catch {
            logger.error(
                "Cannot restamp future-dated recovery file \(file.lastPathComponent): \(error)"
            )
        }
    }

    // MARK: - Timer

    /// Starts the periodic snapshot timer (every 30 seconds).
    func startPeriodicSnapshots() {
        stopPeriodicSnapshots()
        periodicTimer = Timer.scheduledTimer(
            withTimeInterval: Self.periodicInterval,
            repeats: true
        ) { [weak self] _ in
            // Timer.scheduledTimer fires on the main run loop; assert main
            // actor isolation to cross the @Sendable timer boundary.
            MainActor.assumeIsolated {
                guard let self, let tabs = self.tabsProvider?() else { return }
                self.snapshotDirtyTabs(tabs)
            }
        }
    }

    /// Stops the periodic snapshot timer.
    func stopPeriodicSnapshots() {
        periodicTimer?.invalidate()
        periodicTimer = nil
    }

    /// Internal lifecycle observability for project suspend/resume tests.
    var isPeriodicSnapshotting: Bool { periodicTimer != nil }

    /// Schedules a debounced snapshot (5 seconds after last edit).
    func scheduleSnapshot() {
        // Lazily create the debouncer (captures self weakly).
        if snapshotDebouncer == nil {
            snapshotDebouncer = Debouncer(delay: Self.debounceDelay) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let tabs = self.tabsProvider?() else { return }
                    self.snapshotDirtyTabs(tabs)
                }
            }
        }
        snapshotDebouncer?.schedule()
    }

    /// Cancels any pending debounced snapshot.
    func cancelScheduledSnapshot() {
        snapshotDebouncer?.cancel()
    }

    // MARK: - Private

    private func recoveryFileURL(for tabID: UUID) -> URL {
        recoveryDirectory.appendingPathComponent("\(tabID.uuidString).json")
    }

    /// Atomically writes one runtime snapshot and returns whether it reached
    /// its destination. Superseded crash IDs are removed only after success.
    private func writeRecoverySnapshot(for tab: EditorTab) -> Bool {
        writeRecoverySnapshot(for: tab, encoder: makeRecoveryEncoder())
    }

    private func writeRecoverySnapshot(
        for tab: EditorTab,
        encoder: JSONEncoder
    ) -> Bool {
        let entry = RecoveryEntry(
            originalPath: tab.fileURL?.path ?? "",
            untitledName: tab.isUntitled ? tab.fileName : nil,
            content: tab.content,
            encoding: tab.encoding
        )

        do {
            try faultInjector.checkpoint(
                store: .recovery,
                phase: .beforeWrite
            )
            let data = try encoder.encode(entry)
            try faultInjector.checkpoint(
                store: .recovery,
                phase: .afterTemporaryWrite
            )
            try faultInjector.checkpoint(
                store: .recovery,
                phase: .beforeSync
            )
            try faultInjector.checkpoint(
                store: .recovery,
                phase: .beforeAtomicReplace
            )
            try data.write(
                to: recoveryFileURL(for: tab.id),
                options: .atomic
            )
            do {
                try faultInjector.checkpoint(
                    store: .recovery,
                    phase: .afterAtomicReplace
                )
            } catch {
                let tabName = tab.fileName
                Self.logger.error(
                    "Recovery snapshot replaced but durability is unknown for tab \(tabName): \(error)"
                )
                return false
            }
        } catch {
            Self.logger.error(
                "Failed to write recovery file for tab \(tab.fileName): \(error)"
            )
            return false
        }

        deleteSupersededRecoveryFiles(for: tab.id)
        return true
    }

    private func makeRecoveryEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    @discardableResult
    private func removeRecoveryFileOnly(for tabID: UUID) -> Bool {
        let fileURL = recoveryFileURL(for: tabID)
        do {
            try FileManager.default.removeItem(at: fileURL)
            return true
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
            && error.code == NSFileNoSuchFileError {
            return true
        } catch {
            Self.logger.error(
                "Failed to delete recovery file \(tabID.uuidString): \(error)"
            )
            return false
        }
    }

    private func recordSupersededRecoveryID(
        _ recoveryID: UUID,
        for runtimeID: UUID
    ) {
        guard recoveryID != runtimeID else { return }
        supersededRecoveryIDsByRuntimeID[runtimeID, default: []]
            .insert(recoveryID)
    }

    private func deleteSupersededRecoveryFiles(for runtimeID: UUID) {
        guard let recoveryIDs = supersededRecoveryIDsByRuntimeID[runtimeID] else {
            return
        }
        let failed = Set(recoveryIDs.filter {
            !removeRecoveryFileOnly(for: $0)
        })
        if failed.isEmpty {
            supersededRecoveryIDsByRuntimeID.removeValue(forKey: runtimeID)
        } else {
            supersededRecoveryIDsByRuntimeID[runtimeID] = failed
        }
    }

    private func forgetSupersededReference(to recoveryID: UUID) {
        for runtimeID in Array(supersededRecoveryIDsByRuntimeID.keys) {
            supersededRecoveryIDsByRuntimeID[runtimeID]?.remove(recoveryID)
            if supersededRecoveryIDsByRuntimeID[runtimeID]?.isEmpty == true {
                supersededRecoveryIDsByRuntimeID.removeValue(
                    forKey: runtimeID
                )
            }
        }
    }

    @discardableResult
    private func ensureDirectoryExists() -> Bool {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(
            atPath: recoveryDirectory.path,
            isDirectory: &isDirectory
        ) {
            return isDirectory.boolValue
        }

        do {
            try FileManager.default.createDirectory(
                at: recoveryDirectory,
                withIntermediateDirectories: true
            )
            return true
        } catch {
            Self.logger.error("Failed to create recovery directory: \(error)")
            return false
        }
    }

    /// Returns a hex-encoded SHA-256 hash of the given string.
    nonisolated private static func sha256(_ string: String) -> String {
        let data = Data(string.utf8)
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(buffer.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}
