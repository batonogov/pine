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
final class RecoveryManager {

    private static let logger = Logger(subsystem: "com.pine.editor", category: "RecoveryManager")

    /// Root recovery directory under Application Support.
    static var rootDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pine/Recovery")
    }

    /// Returns a per-project recovery subdirectory based on a SHA-256 hash of the project path.
    static func directory(for projectURL: URL) -> URL {
        let path = projectURL.resolvingSymlinksInPath().path
        let hash = sha256(path)
        return rootDirectory.appendingPathComponent(hash)
    }

    /// Periodic snapshot interval in seconds.
    static let periodicInterval: TimeInterval = 30

    /// Debounce delay for edit-triggered snapshots.
    static let debounceDelay: TimeInterval = 5

    private let recoveryDirectory: URL
    private var periodicTimer: Timer?
    private var debounceWorkItem: DispatchWorkItem?

    /// Tabs provider — set by ProjectManager so periodic snapshots can access current tabs.
    var tabsProvider: (() -> [EditorTab])?

    init(recoveryDirectory: URL) {
        self.recoveryDirectory = recoveryDirectory
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

        ensureDirectoryExists()

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        for tab in dirtyTabs {
            let entry = RecoveryEntry(
                originalPath: tab.url.path,
                content: tab.content,
                encoding: tab.encoding
            )
            do {
                let data = try encoder.encode(entry)
                let fileURL = recoveryFileURL(for: tab.id)
                do {
                    try data.write(to: fileURL, options: .atomic)
                } catch {
                    Self.logger.error("Failed to write recovery file for tab \(tab.url.lastPathComponent): \(error)")
                }
            } catch {
                Self.logger.error("Failed to encode recovery entry for \(tab.url.lastPathComponent): \(error)")
            }
        }
    }

    // MARK: - Delete

    /// Removes the recovery file for a specific tab (e.g., after save or clean close).
    func deleteRecoveryFile(for tabID: UUID) {
        let fileURL = recoveryFileURL(for: tabID)
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
            && error.code == NSFileNoSuchFileError {
            // File already deleted — not an error
        } catch {
            Self.logger.error("Failed to delete recovery file \(tabID.uuidString): \(error)")
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
                results.append((uuid, entry))
            } catch {
                Self.logger.error("Failed to read recovery entry \(name): \(error)")
            }
        }
        return results
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
            do {
                try FileManager.default.createDirectory(
                    at: recoveryDirectory,
                    withIntermediateDirectories: true
                )
            } catch {
                Self.logger.error("Failed to create recovery directory: \(error)")
            }
        }
    }

    /// Returns a hex-encoded SHA-256 hash of the given string.
    private static func sha256(_ string: String) -> String {
        let data = Data(string.utf8)
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(buffer.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}
