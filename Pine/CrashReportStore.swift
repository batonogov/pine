//
//  CrashReportStore.swift
//  Pine
//
//  Persists crash reports as JSON files in Application Support/Pine/CrashReports/.
//  On the next launch, pending reports can be loaded and shown to the user
//  for optional submission.
//

import Foundation

struct CrashReportStore {

    let directory: URL

    /// Default store location in Application Support.
    static var `default`: CrashReportStore {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        let dir = appSupport
            .appending(path: "Pine", directoryHint: .isDirectory)
            .appending(path: "CrashReports", directoryHint: .isDirectory)
        return CrashReportStore(directory: dir)
    }

    /// Saves a crash report to disk. Creates the directory if needed.
    func save(_ report: CrashReport) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let filename = "crash-\(UUID().uuidString).json"
        let fileURL = directory.appending(path: filename)
        let data = try JSONEncoder().encode(report)
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
