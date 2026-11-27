//
//  RecoveryManager.swift
//  Pine
//

import CommonCrypto
import Foundation
import os

/// What `Save a Copy…` refuses, each with its own sentence for the user.
nonisolated enum RecoveryCopyFailure: Error, Equatable {
    /// The chosen destination is the file the snapshot was taken from.
    case originalFile
    /// The text cannot be written back in the snapshot's own encoding.
    case cannotEncode
}

/// Manages crash recovery snapshots of unsaved editor content.
///
/// Periodically writes dirty tab content to a recovery directory so it can
/// be restored after a crash, force quit, or power loss.
/// Each project gets its own subdirectory to avoid mixing recovery files.
///
/// A snapshot nobody has decided about is never collected by age (#1760):
/// it stays in the recovery list until the user restores or discards it.
@MainActor
final class RecoveryManager {

    /// `nonisolated` so the off-main-actor listing in ``readEntries(in:)`` can
    /// report what it skipped.
    nonisolated private static let logger = Logger.app

    /// Root recovery directory under Application Support.
    nonisolated static var rootDirectory: URL {
        PineStorageContext.applicationSupportDirectory
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
    /// - Returns: the IDs whose file could not be unlinked. A missing file
    /// counts as removed; EACCES, EIO and friends do not. The caller must
    /// keep these rows in the recovery list: a discard the filesystem
    /// refused must not be reported as done, or the sheet claims work was
    /// destroyed while the file survives on disk (#1760).
    ///
    /// Named apart from ``deleteSnapshotsOfOpenTabs(_:)`` on purpose. The two
    /// used to differ by one argument label while differing by their entire
    /// blast radius: this one takes crash IDs the user just looked at, that
    /// one takes live tab IDs and also collects whatever crash file each tab
    /// superseded. Passing one's argument to the other is a silent data-loss
    /// bug, so there is no shared base name to autocomplete into.
    @discardableResult
    func deleteSnapshots(withRecoveryIDs recoveryIDs: [UUID]) -> Set<UUID> {
        var undeleted: Set<UUID> = []
        for recoveryID in Set(recoveryIDs) {
            if removeRecoveryFileOnly(for: recoveryID) {
                forgetSupersededReference(to: recoveryID)
            } else {
                undeleted.insert(recoveryID)
            }
        }
        return undeleted
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
    /// in the session whose unlink failed. Nothing collects it by age
    /// (#1760): it comes back in the recovery list, where the user decides.
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
    /// applied to it. The directory used to be emptied on every clean quit,
    /// so the cost was paid at most once, on the launch after a crash. Now
    /// snapshots are held until the user decides (#1760), and the discovery
    /// runs from a scene `.task` that SwiftUI re-runs on scene restoration
    /// and on closing and reopening the window: three 40 MB buffers left for
    /// later would otherwise block the main thread on ~120 MB of reading and
    /// decoding before the window draws, on every launch and every reopen
    /// (AGENTS.md: never block the main thread with file I/O).
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
    /// went back to would refuse to show it while the launch sweep deleted it
    /// on a schedule. A build that can read a buffer must not both hide it
    /// and eventually destroy it; nothing deletes work the user was never
    /// given the chance to decide about (#1503), and since #1760 nothing
    /// deletes a snapshot on a schedule at all. ``RecoveryEntry/hasSupportedSchema``
    /// stays as a signal — it is logged here — but it does not suppress the
    /// offer.
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

    // MARK: - Save a copy (#1760)

    /// Name the save panel offers: `main.swift` becomes
    /// `main.recovered.swift`, an untitled buffer `Untitled.recovered.txt`.
    ///
    /// Never the original name. The panel opens in the file's own folder, so
    /// the original name would make its default answer "replace the file I
    /// was editing".
    static func saveCopyFileName(for entry: RecoveryEntry) -> String {
        guard !entry.originalPath.isEmpty else {
            return "\(entry.untitledName ?? Strings.recoveryUntitled).recovered.txt"
        }
        let name = (entry.originalPath as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty else { return "\(name).recovered" }
        return (name as NSString).deletingPathExtension + ".recovered." + ext
    }

    /// Folder the save panel opens in: the file's own, while it still exists,
    /// otherwise Documents. An untitled buffer has no folder and starts in
    /// Documents.
    nonisolated static func saveCopyDirectory(for entry: RecoveryEntry) -> URL {
        guard !entry.originalPath.isEmpty else { return documentsDirectory }
        let parent = URL(fileURLWithPath: entry.originalPath)
            .deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(
            atPath: parent.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue {
            return parent
        }
        return documentsDirectory
    }

    nonisolated private static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// Writes the buffer to `destination` in its own encoding, or throws
    /// ``RecoveryCopyFailure`` and writes nothing.
    ///
    /// - Parameter replacing: Whether the save panel already asked about a
    ///   file at `destination`. Without it an existing file is never
    ///   replaced, whatever appeared there since the panel closed.
    ///
    /// `nonisolated`: file I/O, so the caller keeps it off the main actor.
    ///
    /// The original file is never the destination, whatever was typed into
    /// the panel: a snapshot is taken while the file is being edited, and
    /// the panel's replace confirmation is one reflex Return away. Paths are
    /// compared case-insensitively because the system volume is, and
    /// canonicalized on both sides first because APFS is
    /// normalization-insensitive: Finder writes decomposed names (NFD),
    /// IMEs and dead keys compose them (NFC), and without this step the
    /// panel's "Replace?" would really resolve to the file the snapshot was
    /// taken from.
    nonisolated static func writeCopy(
        of entry: RecoveryEntry,
        to destination: URL,
        replacing: Bool
    ) throws {
        let original = URL(fileURLWithPath: entry.originalPath)
            .standardizedFileURL.path
            .precomposedStringWithCanonicalMapping
        let destinationPath = destination.standardizedFileURL.path
            .precomposedStringWithCanonicalMapping
        if !entry.originalPath.isEmpty,
           destinationPath.caseInsensitiveCompare(original) == .orderedSame {
            throw RecoveryCopyFailure.originalFile
        }
        // Refused before anything is written: the write below would fail the
        // same way, but only this check can say why.
        guard let data = entry.content.data(
            using: entry.encoding,
            allowLossyConversion: false
        ) else {
            throw RecoveryCopyFailure.cannotEncode
        }
        if !replacing,
           FileManager.default.fileExists(atPath: destination.path) {
            // `Data.write(options: .withoutOverwriting)` asserts instead of
            // throwing when the destination exists on this OS (S3's crash
            // forensics, 2026-11-26), so the refusal is explicit and
            // catchable.
            throw CocoaError(.fileWriteFileExists)
        }
        try data.write(to: destination, options: [.atomic])
    }

    // MARK: - Project resolution

    /// Name of this project's snapshot directory — the hash
    /// ``directory(for:)`` derives from the project path.
    var recoveryDirectoryName: String {
        recoveryDirectory.lastPathComponent
    }

    /// The project a snapshot directory belongs to: the first of
    /// `candidates` whose path hashes to the directory's name.
    ///
    /// An untitled buffer records no path, so the hashed directory is the
    /// only trace of the project it was open in. `nil` when none of the
    /// candidates matches.
    nonisolated static func project(
        matchingRecoveryDirectoryName directoryName: String,
        among candidates: [URL]
    ) -> URL? {
        candidates.first {
            directory(for: $0).lastPathComponent == directoryName
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

#if PINE_TEST_HOST
// MARK: - UI test fixture (`--ui-test-recovery-entry`)

extension RecoveryManager {

    /// Writes one snapshot nobody has decided about, `daysOld` days old, into
    /// `projectURL`'s recovery directory. Its modification date is set to
    /// match: one write sets both in production.
    ///
    /// On the main thread on purpose. It runs once, at launch, before the
    /// project window lists the directory — and only in the test host.
    @discardableResult
    static func seedUITestSnapshot(
        daysOld: Int,
        fileName: String = "crashed.swift",
        for projectURL: URL?
    ) -> Bool {
        guard let projectURL else { return false }
        let directory = Self.directory(for: projectURL)
        let when = Date().addingTimeInterval(-Double(daysOld) * 24 * 3600)
        let entry = RecoveryEntry(
            originalPath: projectURL.appendingPathComponent(fileName).path,
            content: "// unsaved work from a session that crashed\n",
            timestamp: when
        )
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let file = directory.appendingPathComponent("\(UUID().uuidString).json")
            try makeEncoder().encode(entry).write(to: file, options: .atomic)
            try FileManager.default.setAttributes(
                [.modificationDate: when],
                ofItemAtPath: file.path
            )
            return true
        } catch {
            Self.logger.error("Could not seed the UI-test recovery snapshot: \(error)")
            return false
        }
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
#endif
