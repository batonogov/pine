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

    private static let logger = Logger.app

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

    /// Removes only the explicitly displayed recovery IDs.
    ///
    /// Used by the recovery sheet's Discard action so successfully migrated
    /// runtime snapshots in the same project directory remain intact.
    func deleteRecoveryFiles(for tabIDs: [UUID]) {
        for tabID in Set(tabIDs) where removeRecoveryFileOnly(for: tabID) {
            forgetSupersededReference(to: tabID)
        }
    }

    /// Removes all recovery files for this project (e.g., on clean quit).
    func deleteAllRecoveryFiles() {
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(
                at: recoveryDirectory,
                includingPropertiesForKeys: nil
            )
        } catch {
            Self.logger.warning("Cannot list recovery directory: \(error)")
            return
        }

        for file in files where file.pathExtension == "json" {
            do {
                try FileManager.default.removeItem(at: file)
            } catch {
                Self.logger.error("Failed to delete recovery file \(file.lastPathComponent): \(error)")
            }
        }
    }

    // MARK: - Read

    /// Returns all pending recovery entries as (tabID, entry) pairs.
    /// Corrupted or non-JSON files are logged and skipped.
    func pendingRecoveryEntries() -> [(UUID, RecoveryEntry)] {
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(
                at: recoveryDirectory,
                includingPropertiesForKeys: nil
            )
        } catch {
            Self.logger.warning("Cannot list recovery directory: \(error)")
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
                guard entry.hasSupportedSchema else {
                    Self.logger.error(
                        "Refusing unsupported recovery schema in \(name)"
                    )
                    continue
                }
                results.append((uuid, entry))
            } catch {
                Self.logger.error("Failed to read recovery entry \(name): \(error)")
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
    /// across *all* project subdirectories.
    static func cleanupAllStaleEntries(olderThan days: Int) {
        let fm = FileManager.default
        let subdirs: [URL]
        do {
            subdirs = try fm.contentsOfDirectory(
                at: rootDirectory,
                includingPropertiesForKeys: [.isDirectoryKey]
            )
        } catch {
            logger.warning("Cannot list recovery root directory: \(error)")
            return
        }

        for subdir in subdirs {
            let manager = RecoveryManager(recoveryDirectory: subdir)
            manager.cleanupStaleEntries(olderThan: days)

            // Remove empty subdirectories
            do {
                let remaining = try fm.contentsOfDirectory(atPath: subdir.path)
                if remaining.isEmpty {
                    do {
                        try fm.removeItem(at: subdir)
                    } catch {
                        logger.error("Failed to remove empty recovery subdir: \(error)")
                    }
                }
            } catch {
                logger.warning("Cannot list recovery subdir \(subdir.lastPathComponent): \(error)")
            }
        }
    }

    /// Removes recovery files with timestamps older than the given number of days.
    func cleanupStaleEntries(olderThan days: Int) {
        let cutoff = Date().addingTimeInterval(-Double(days) * 24 * 3600)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(
                at: recoveryDirectory,
                includingPropertiesForKeys: nil
            )
        } catch {
            Self.logger.warning("Cannot list recovery directory for cleanup: \(error)")
            return
        }

        for file in files where file.pathExtension == "json" {
            do {
                let data = try Data(contentsOf: file)
                let entry = try decoder.decode(RecoveryEntry.self, from: data)
                guard entry.hasSupportedSchema else {
                    Self.logger.error(
                        "Refusing unsupported recovery schema during cleanup"
                    )
                    continue
                }
                if entry.timestamp < cutoff {
                    do {
                        try FileManager.default.removeItem(at: file)
                    } catch {
                        Self.logger.error("Failed to remove stale recovery file \(file.lastPathComponent): \(error)")
                    }
                }
            } catch {
                Self.logger.error("Failed to read recovery file for cleanup \(file.lastPathComponent): \(error)")
            }
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
