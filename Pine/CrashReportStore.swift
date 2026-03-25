//
//  CrashReportStore.swift
//  Pine
//
//  Persists crash reports as JSON files in Application Support/Pine/CrashReports/.
//  On the next launch, pending reports can be loaded and shown to the user
//  for optional submission.
//

import Foundation

struct CrashReportStore: Sendable {

    let directory: URL

    /// Default store location in Application Support.
    static let `default`: CrashReportStore = {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else {
            return CrashReportStore(directory: FileManager.default.temporaryDirectory
                .appending(path: "Pine", directoryHint: .isDirectory)
                .appending(path: "CrashReports", directoryHint: .isDirectory))
        }
        let dir = appSupport
            .appending(path: "Pine", directoryHint: .isDirectory)
            .appending(path: "CrashReports", directoryHint: .isDirectory)
        return CrashReportStore(directory: dir)
    }()

    /// Ensures the storage directory exists. Called before any write operation.
    func ensureDirectoryExists() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Saves a crash report to disk. Creates the directory if needed.
    func save(_ report: CrashReport) throws {
        try ensureDirectoryExists()

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970

        let filename = "crash-\(UUID().uuidString).json"
        let fileURL = directory.appending(path: filename)
        let data = try encoder.encode(report)
        try data.write(to: fileURL, options: .atomic)
    }

    /// Loads all pending (unsent) crash reports.
    func loadPending() throws -> [CrashReport] {
        guard FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) else {
            return []
        }

        let contents = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        )

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970

        return contents
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(CrashReport.self, from: data)
            }
    }

    /// Deletes all pending crash reports.
    func deleteAll() throws {
        guard FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) else {
            return
        }

        let contents = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        )

        for url in contents where url.pathExtension == "json" {
            try FileManager.default.removeItem(at: url)
        }
    }
}
