//
//  CrashReportStore.swift
//  Pine
//
//  Persists crash reports to disk for display on next launch.
//

import Foundation
import os

/// Persists crash reports as JSON files in the Application Support directory.
/// Reports are stored individually for atomic read/write and easy cleanup.
final class CrashReportStore {
    /// Shared singleton instance.
    static let shared = CrashReportStore()

    /// Directory where crash reports are stored.
    let storageDirectory: URL

    private let logger = Logger(subsystem: "com.pine.editor", category: "CrashReportStore")

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
        let fileName = "\(report.id.uuidString).\(Self.fileExtension)"
        let fileURL = storageDirectory.appendingPathComponent(fileName)

        do {
            let data = try JSONEncoder().encode(report)
            try data.write(to: fileURL, options: .atomic)
            pruneOldReports()
        } catch {
            logger.error("Failed to save crash report: \(error.localizedDescription)")
        }
    }

    /// Loads all stored crash reports, sorted by timestamp (newest first).
    func loadAll() -> [CrashReport] {
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

    /// Removes a specific crash report by ID.
    func remove(id: UUID) {
        let fileName = "\(id.uuidString).\(Self.fileExtension)"
        let fileURL = storageDirectory.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Removes all stored crash reports.
    func removeAll() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: storageDirectory, includingPropertiesForKeys: nil) else {
            return
        }
        for file in files where file.pathExtension == Self.fileExtension {
            try? fm.removeItem(at: file)
        }
    }

    /// Returns the number of stored reports.
    var count: Int {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: storageDirectory, includingPropertiesForKeys: nil) else {
            return 0
        }
        return files.filter { $0.pathExtension == Self.fileExtension }.count
    }

    /// Prunes old reports if count exceeds the maximum.
    private func pruneOldReports() {
        let reports = loadAll()
        guard reports.count > Self.maxReports else { return }

        let toRemove = reports.suffix(from: Self.maxReports)
        for report in toRemove {
            remove(id: report.id)
        }
    }
}
