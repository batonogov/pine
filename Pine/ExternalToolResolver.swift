//
//  ExternalToolResolver.swift
//  Pine
//

import Foundation

/// Discovers external CLI tools by searching PATH directories and well-known
/// install locations. Caches results for the lifetime of the resolver instance.
///
/// Thread-safe: uses a serial queue to protect the cache dictionary.
nonisolated final class ExternalToolResolver: Sendable {

    /// Well-known directories that are always searched, even if not in PATH.
    /// Order matters — earlier entries are checked first.
    nonisolated static let wellKnownDirectories: [String] = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin"
    ]

    /// Ordered, deduplicated list of directories to search.
    let searchDirectories: [String]

    private let cacheQueue = DispatchQueue(label: "com.pine.tool-resolver-cache")
    nonisolated(unsafe) private var cache: [String: String?] = [:]

    /// Creates a resolver with the given PATH string.
    ///
    /// - Parameters:
    ///   - pathString: Colon-separated PATH string (e.g. from `ProcessInfo.processInfo.environment["PATH"]`).
    ///                 If nil, only well-known directories are searched.
    init(pathString: String? = nil) {
        var seen = Set<String>()
        var dirs: [String] = []

        // 1. Directories from PATH
        if let pathString, !pathString.isEmpty {
            for dir in pathString.split(separator: ":").map(String.init) {
                let clean = dir.trimmingCharacters(in: .whitespaces)
                guard !clean.isEmpty, !seen.contains(clean) else { continue }
                seen.insert(clean)
                dirs.append(clean)
            }
        }

        // 2. Well-known directories (appended if not already present)
        for dir in Self.wellKnownDirectories where !seen.contains(dir) {
            seen.insert(dir)
            dirs.append(dir)
        }

        self.searchDirectories = dirs
    }

    /// Creates a resolver using the current process's PATH environment variable.
    static func fromEnvironment() -> ExternalToolResolver {
        let path = ProcessInfo.processInfo.environment["PATH"]
        return ExternalToolResolver(pathString: path)
    }

    /// Resolves the path to a CLI tool by name.
    ///
    /// If `tool` is an absolute path (starts with `/`), it is validated directly.
    /// Otherwise, searches `searchDirectories` in order.
    ///
    /// Returns the absolute path to the executable, or nil if not found.
    /// Results are cached.
    func resolve(tool: String) -> String? {
        // Single atomic cache read — use index(forKey:) to distinguish
        // "key absent" from "key present with nil value"
        let cachedResult: (found: Bool, value: String?) = cacheQueue.sync {
            if let idx = cache.index(forKey: tool) {
                return (true, cache[idx].value)
            }
            return (false, nil)
        }

        if cachedResult.found {
            return cachedResult.value
        }

        let result: String?

        if tool.hasPrefix("/") {
            // Absolute path — validate directly
            result = isExecutableFile(tool) ? tool : nil
        } else {
            // Search PATH directories
            result = searchInDirectories(tool)
        }

        cacheQueue.sync {
            cache[tool] = result
        }
        return result
    }

    /// Clears the cached tool paths.
    func clearCache() {
        cacheQueue.sync {
            cache.removeAll()
        }
    }

    // MARK: - Private

    private func searchInDirectories(_ tool: String) -> String? {
        for dir in searchDirectories {
            let candidate = (dir as NSString).appendingPathComponent(tool)
            if isExecutableFile(candidate) {
                return candidate
            }
        }
        return nil
    }

    private func isExecutableFile(_ path: String) -> Bool {
        let fileManager = FileManager.default
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else {
            return false
        }
        return fileManager.isExecutableFile(atPath: path)
    }
}
