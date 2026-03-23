//
//  FileNameGenerator.swift
//  Pine
//

import Foundation

/// Utility for generating unique file/folder names with a bounded iteration limit.
enum FileNameGenerator {

    /// Maximum number of candidates to try before giving up.
    static let maxAttempts = 10_000

    /// Generates a Finder-style copy URL: "file copy.ext", "file copy 2.ext", etc.
    /// Returns `nil` if all candidates up to `maxAttempts` are taken.
    /// - Parameter fileExists: Closure that checks whether a path exists. Defaults to `FileManager.default`.
    static func finderCopyURL(
        for url: URL,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> URL? {
        let directory = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let baseName = ext.isEmpty
            ? url.lastPathComponent
            : String(url.lastPathComponent.dropLast(ext.count + 1))

        for counter in 0..<maxAttempts {
            let copyName: String
            if counter == 0 {
                copyName = ext.isEmpty
                    ? "\(baseName) copy"
                    : "\(baseName) copy.\(ext)"
            } else {
                copyName = ext.isEmpty
                    ? "\(baseName) copy \(counter + 1)"
                    : "\(baseName) copy \(counter + 1).\(ext)"
            }
            let candidate = directory.appendingPathComponent(copyName)
            if !fileExists(candidate.path) {
                return candidate
            }
        }
        return nil
    }

    /// Returns a unique name by appending a counter if the name already exists.
    /// Falls back to the last attempted name after `maxAttempts`.
    /// - Parameter fileExists: Closure that checks whether a path exists. Defaults to `FileManager.default`.
    static func uniqueName(
        _ baseName: String,
        in parentURL: URL,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> String {
        if !fileExists(parentURL.appendingPathComponent(baseName).path) {
            return baseName
        }
        for counter in 2...maxAttempts {
            let name = "\(baseName) \(counter)"
            if !fileExists(parentURL.appendingPathComponent(name).path) {
                return name
            }
        }
        return "\(baseName) \(maxAttempts)"
    }
}
