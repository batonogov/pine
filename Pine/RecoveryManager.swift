//
//  RecoveryManager.swift
//  Pine
//

import Foundation

/// Manages crash recovery snapshots of unsaved editor content.
///
/// Periodically writes dirty tab content to a recovery directory so it can
/// be restored after a crash, force quit, or power loss.
final class RecoveryManager {

    /// Default recovery directory under Application Support.
    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pine/Recovery")
    }

    /// Periodic snapshot interval in seconds.
    static let periodicInterval: TimeInterval = 30

    /// Debounce delay for edit-triggered snapshots.
    static let debounceDelay: TimeInterval = 5

    private let recoveryDirectory: URL
    private var periodicTimer: Timer?
    private var debounceWorkItem: DispatchWorkItem?

    /// Tabs provider — set by TabManager so periodic snapshots can access current tabs.
    var tabsProvider: (() -> [EditorTab])?

    init(recoveryDirectory: URL? = nil) {
        self.recoveryDirectory = recoveryDirectory ?? Self.defaultDirectory
    }

    // MARK: - Snapshot

    /// Writes a recovery file for each dirty tab. Clean/preview tabs are skipped.
    func snapshotDirtyTabs(_ tabs: [EditorTab]) {
        let dirtyTabs = tabs.filter { $0.isDirty && $0.kind == .text }
        guard !dirtyTabs.isEmpty else { return }

        ensureDirectoryExists()

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        for tab in dirtyTabs {
            let entry = RecoveryEntry(
                originalPath: tab.url.path,
                content: tab.content,
                encoding: tab.encoding
            )
            guard let data = try? encoder.encode(entry) else { continue }
            let fileURL = recoveryFileURL(for: tab.id)
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    // MARK: - Delete

    /// Removes the recovery file for a specific tab (e.g., after save or clean close).
    func deleteRecoveryFile(for tabID: UUID) {
        let fileURL = recoveryFileURL(for: tabID)
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Removes all recovery files (e.g., on clean quit).
    func deleteAllRecoveryFiles() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: recoveryDirectory,
            includingPropertiesForKeys: nil
        ) else { return }

        for file in files where file.pathExtension == "json" {
            try? FileManager.default.removeItem(at: file)
        }
    }

    // MARK: - Read

    /// Returns all pending recovery entries as (tabID, entry) pairs.
    /// Corrupted or non-JSON files are silently skipped.
    func pendingRecoveryEntries() -> [(UUID, RecoveryEntry)] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: recoveryDirectory,
            includingPropertiesForKeys: nil
        ) else { return [] }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var results: [(UUID, RecoveryEntry)] = []
        for file in files where file.pathExtension == "json" {
            let name = file.deletingPathExtension().lastPathComponent
            guard let uuid = UUID(uuidString: name),
                  let data = try? Data(contentsOf: file),
                  let entry = try? decoder.decode(RecoveryEntry.self, from: data)
            else { continue }
            results.append((uuid, entry))
        }
        return results
    }

    /// Whether there are any pending recovery files.
    var hasPendingRecovery: Bool {
        !pendingRecoveryEntries().isEmpty
    }

    // MARK: - Stale cleanup

    /// Removes recovery files with timestamps older than the given number of days.
    func cleanupStaleEntries(olderThan days: Int) {
        let cutoff = Date().addingTimeInterval(-Double(days) * 24 * 3600)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        guard let files = try? FileManager.default.contentsOfDirectory(
            at: recoveryDirectory,
            includingPropertiesForKeys: nil
        ) else { return }

        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let entry = try? decoder.decode(RecoveryEntry.self, from: data),
                  entry.timestamp < cutoff
            else { continue }
            try? FileManager.default.removeItem(at: file)
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
            guard let self, let tabs = self.tabsProvider?() else { return }
            self.snapshotDirtyTabs(tabs)
        }
    }

    /// Stops the periodic snapshot timer.
    func stopPeriodicSnapshots() {
        periodicTimer?.invalidate()
        periodicTimer = nil
    }

    /// Schedules a debounced snapshot (5 seconds after last edit).
    func scheduleSnapshot() {
        debounceWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, let tabs = self.tabsProvider?() else { return }
            self.snapshotDirtyTabs(tabs)
        }
        debounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounceDelay, execute: workItem)
    }

    /// Cancels any pending debounced snapshot.
    func cancelScheduledSnapshot() {
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
    }

    // MARK: - Private

    private func recoveryFileURL(for tabID: UUID) -> URL {
        recoveryDirectory.appendingPathComponent("\(tabID.uuidString).json")
    }

    private func ensureDirectoryExists() {
        if !FileManager.default.fileExists(atPath: recoveryDirectory.path) {
            try? FileManager.default.createDirectory(
                at: recoveryDirectory,
                withIntermediateDirectories: true
            )
        }
    }
}
