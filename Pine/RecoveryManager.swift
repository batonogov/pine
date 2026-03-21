//
//  RecoveryManager.swift
//  Pine
//
//  Created by Claude on 21.03.2026.
//

import Foundation

/// Manages crash-recovery snapshots for dirty editor tabs.
///
/// Recovery files are stored as `{tab-uuid}.recovery` JSON files in
/// `~/Library/Application Support/Pine/Recovery/`. On clean save or close
/// the file is deleted immediately. On launch, leftover files are offered
/// to the user via the recovery dialog.
///
/// Snapshot lifecycle:
/// - `snapshot(...)` — called by `TabManager` after a debounced content change
/// - `deleteRecovery(for:)` — called on clean save or tab close
/// - `deleteAllRecoveries()` — called on clean app quit
/// - `pendingRecoveries()` — scans the directory and returns all valid files
/// - `cleanupStaleRecoveries()` — removes files older than 7 days (called on launch)
final class RecoveryManager {

    // MARK: - Shared instance

    static let shared = RecoveryManager()

    // MARK: - Configuration

    /// Maximum age of a recovery file before it is considered stale.
    static let staleThreshold: TimeInterval = 7 * 24 * 3600 // 7 days

    // MARK: - Storage

    /// The directory where recovery files are stored.
    let recoveryDirectory: URL

    // MARK: - Init

    /// Designated initialiser. Accepts a custom directory for unit testing.
    init(recoveryDirectory: URL? = nil) {
        if let dir = recoveryDirectory {
            self.recoveryDirectory = dir
        } else {
            let appSupport = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first ?? FileManager.default.temporaryDirectory
            self.recoveryDirectory = appSupport.appendingPathComponent("Pine/Recovery")
        }
        createDirectoryIfNeeded()
    }

    // MARK: - Directory management

    private func createDirectoryIfNeeded() {
        try? FileManager.default.createDirectory(
            at: recoveryDirectory,
            withIntermediateDirectories: true
        )
    }

    // MARK: - Snapshot

    /// Atomically writes a recovery snapshot for a dirty tab.
    ///
    /// The write is atomic: content goes to a `.tmp` file first, then the
    /// file is renamed into place so a partial write can never corrupt an
    /// existing valid recovery file.
    ///
    /// - Parameters:
    ///   - tabID: The tab's runtime UUID.
    ///   - url: The file's URL, or nil for untitled buffers.
    ///   - content: Current unsaved content.
    ///   - encoding: The file's character encoding.
    func snapshot(tabID: UUID, url: URL?, content: String, encoding: String.Encoding) {
        let data = RecoveryFileData(
            tabID: tabID,
            originalURLPath: url?.path,
            content: content,
            timestamp: Date(),
            encodingRawValue: encoding.rawValue
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let encoded = try? encoder.encode(data) else { return }

        let destination = recoveryFileURL(for: tabID)
        let temp = recoveryDirectory.appendingPathComponent(tabID.uuidString + ".recovery.tmp")

        do {
            try encoded.write(to: temp, options: .atomic)
            // Replace destination atomically (handles the case where destination already exists)
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try? FileManager.default.replaceItemAt(destination, withItemAt: temp)
            } else {
                try FileManager.default.moveItem(at: temp, to: destination)
            }
        } catch {
            try? FileManager.default.removeItem(at: temp)
        }
    }

    // MARK: - Delete

    /// Removes the recovery file for a specific tab.
    /// Called when a tab is cleanly saved or closed.
    func deleteRecovery(for tabID: UUID) {
        try? FileManager.default.removeItem(at: recoveryFileURL(for: tabID))
    }

    /// Removes all recovery files.
    /// Called on a clean application quit (after the user has saved or dismissed
    /// the unsaved-changes dialog).
    func deleteAllRecoveries() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: recoveryDirectory,
            includingPropertiesForKeys: nil
        ) else { return }
        for file in files where file.pathExtension == "recovery" {
            try? FileManager.default.removeItem(at: file)
        }
    }

    // MARK: - Load

    /// Scans the recovery directory and returns all valid recovery files,
    /// sorted by timestamp (newest first).
    func pendingRecoveries() -> [RecoveryFileData] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: recoveryDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return [] }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        return files
            .filter { $0.pathExtension == "recovery" }
            .compactMap { fileURL -> RecoveryFileData? in
                guard let raw = try? Data(contentsOf: fileURL),
                      let recovery = try? decoder.decode(RecoveryFileData.self, from: raw)
                else { return nil }
                return recovery
            }
            .sorted { $0.timestamp > $1.timestamp }
    }

    /// Returns a dictionary mapping original file path → RecoveryFileData
    /// for fast URL-based lookup when matching against open tabs.
    func recoveryByURL() -> [String: RecoveryFileData] {
        var result: [String: RecoveryFileData] = [:]
        for recovery in pendingRecoveries() {
            if let path = recovery.originalURLPath {
                // If multiple recoveries exist for the same URL, keep the newest
                if result[path] == nil {
                    result[path] = recovery
                }
            }
        }
        return result
    }

    // MARK: - Stale cleanup

    /// Deletes recovery files older than `staleThreshold`. Called once on launch.
    func cleanupStaleRecoveries() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: recoveryDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }

        let cutoff = Date().addingTimeInterval(-Self.staleThreshold)
        for file in files where file.pathExtension == "recovery" {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
                  let modDate = attrs[.modificationDate] as? Date,
                  modDate < cutoff
            else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    // MARK: - Helpers

    /// Returns the URL for a tab's recovery file.
    func recoveryFileURL(for tabID: UUID) -> URL {
        recoveryDirectory.appendingPathComponent(tabID.uuidString + ".recovery")
    }
}
