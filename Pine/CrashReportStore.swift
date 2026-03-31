//
//  CrashReportStore.swift
//  Pine
//
//  Persists crash reports to disk for display on next launch.
//

import AppKit
import Foundation
import os

/// Persists crash reports as JSON files in the Application Support directory.
/// Reports are stored individually for atomic read/write and easy cleanup.
///
/// Thread-safe: all file I/O is serialized on an internal serial queue.
/// Safe to call from MetricKit callbacks (arbitrary threads) and from the main thread.
final class CrashReportStore {
    /// Shared singleton instance.
    static let shared = CrashReportStore()

    /// Directory where crash reports are stored.
    let storageDirectory: URL

    private let logger = Logger(subsystem: "com.pine.editor", category: "CrashReportStore")

    /// Serial queue that serializes all disk I/O for thread safety.
    private let queue = DispatchQueue(label: "com.pine.crash-report-store")

    /// Maximum number of reports to keep on disk.
    static let maxReports = 50

    /// File extension for crash report files.
    static let fileExtension = "crashreport"

    init(storageDirectory: URL? = nil) {
        if let dir = storageDirectory {
            self.storageDirectory = dir
        } else if let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first {
            self.storageDirectory = appSupport.appendingPathComponent("Pine/CrashReports")
        } else {
            self.storageDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("Pine/CrashReports")
        }
        try? FileManager.default.createDirectory(at: self.storageDirectory, withIntermediateDirectories: true)
    }

    /// Saves a crash report to disk.
    func save(_ report: CrashReport) {
        queue.sync {
            _save(report)
        }
    }

    /// Loads all stored crash reports, sorted by timestamp (newest first).
    func loadAll() -> [CrashReport] {
        queue.sync {
            _loadAll()
        }
    }

    /// Removes a specific crash report by ID.
    func remove(id: UUID) {
        queue.sync {
            _remove(id: id)
        }
    }

    /// Removes all stored crash reports.
    func removeAll() {
        queue.sync {
            _removeAll()
        }
    }

    /// Returns the number of stored reports (directory listing only, no JSON decoding).
    var count: Int {
        queue.sync {
            _count()
        }
    }

    /// Whether the store has no reports (directory listing only, no JSON decoding).
    var isEmpty: Bool {
        queue.sync {
            _count() == 0
        }
    }

    /// Reveals the crash reports directory in Finder.
    func revealInFinder() {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: storageDirectory.path)
    }

    /// Copies all crash reports as JSON to the clipboard.
    /// Returns the number of reports copied.
    @discardableResult
    func copyAllToClipboard() -> Int {
        let reports = loadAll()
        guard !reports.isEmpty else { return 0 }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        guard let data = try? encoder.encode(reports),
              let jsonString = String(data: data, encoding: .utf8) else {
            return 0
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(jsonString, forType: .string)
        return reports.count
    }

    // MARK: - Private (must be called on self.queue)

    private func _save(_ report: CrashReport) {
        let fileName = "\(report.id.uuidString).\(Self.fileExtension)"
        let fileURL = storageDirectory.appendingPathComponent(fileName)

        do {
            let data = try JSONEncoder().encode(report)
            try data.write(to: fileURL, options: .atomic)
            _pruneOldReports()
        } catch {
            logger.error("Failed to save crash report: \(error.localizedDescription)")
        }
    }

    private func _loadAll() -> [CrashReport] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: storageDirectory, includingPropertiesForKeys: nil) else {
            return []
        }

        let reports: [CrashReport] = files
            .filter { $0.pathExtension == Self.fileExtension }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url),
                      let report = try? JSONDecoder().decode(CrashReport.self, from: data) else {
                    return nil
                }
                return report
            }
            .sorted { $0.timestamp > $1.timestamp }

        return reports
    }

    private func _remove(id: UUID) {
        let fileName = "\(id.uuidString).\(Self.fileExtension)"
        let fileURL = storageDirectory.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func _removeAll() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: storageDirectory, includingPropertiesForKeys: nil) else {
            return
        }
        for file in files where file.pathExtension == Self.fileExtension {
            try? fm.removeItem(at: file)
        }
    }

    private func _count() -> Int {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: storageDirectory, includingPropertiesForKeys: nil) else {
            return 0
        }
        return files.filter { $0.pathExtension == Self.fileExtension }.count
    }

    /// Prunes old reports if count exceeds the maximum.
    private func _pruneOldReports() {
        let reports = _loadAll()
        guard reports.count > Self.maxReports else { return }

        let toRemove = reports.suffix(from: Self.maxReports)
        for report in toRemove {
            _remove(id: report.id)
        }
    }
}
