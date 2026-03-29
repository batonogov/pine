//
//  ContextFileWriter.swift
//  Pine
//

import CryptoKit
import Foundation

/// Writes the editor context JSON to `~/Library/Application Support/Pine/contexts/`.
///
/// Each project gets a unique file name derived from a SHA-256 hash of the project
/// root path. This avoids polluting the project directory with dot-files and
/// prevents FSEvents churn from context file writes.
///
/// The file is written atomically with a 500ms debounce to avoid excessive I/O
/// during rapid cursor movement. The file is deleted when the project closes.
actor ContextFileWriter {

    /// Legacy file name that was previously written to the project root.
    static let legacyFileName = ".pine-context.json"

    /// The directory inside Application Support where context files are stored.
    static let contextsDirName = "Pine/contexts"

    /// File permissions: owner read/write only (0600).
    nonisolated(unsafe) private static let filePermissions: [FileAttributeKey: Any] = [
        .posixPermissions: NSNumber(value: 0o600)
    ]

    // MARK: - Internal state (visible for testing)

    /// The project root directory. Set via `setProjectRoot(_:)`.
    private(set) var projectRoot: URL?

    /// Debounce interval in seconds. Exposed for testing.
    private(set) var debounceInterval: TimeInterval = 0.5

    /// Tracks whether a write is pending (for testing).
    private(set) var hasPendingWrite = false

    /// Override for the contexts directory. Used by tests.
    private var contextsDirOverride: URL?

    // MARK: - Private

    private var debounceTask: Task<Void, Never>?

    /// The last context that was written to disk, to avoid redundant writes.
    private var lastWrittenContext: Payload?

    /// Shared encoder instance — no need to recreate on each write.
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    // MARK: - Public API

    /// Sets the project root directory. Must be called before `update(...)`.
    /// Also removes the legacy `.pine-context.json` from the project root if present.
    func setProjectRoot(_ url: URL?) {
        projectRoot = url
        removeLegacyFileIfNeeded()
    }

    /// Sets a custom debounce interval. Intended for tests only.
    func setDebounceInterval(_ interval: TimeInterval) {
        debounceInterval = interval
    }

    /// Overrides the contexts directory. Intended for tests only.
    func setContextsDirectory(_ url: URL) {
        contextsDirOverride = url
    }

    /// Schedules a debounced write of the editor context.
    /// Duplicate writes (same file/line/column) are skipped.
    func update(currentFile: String?, cursorLine: Int?, cursorColumn: Int?) {
        let payload = Payload(
            currentFile: currentFile,
            cursorLine: cursorLine,
            cursorColumn: cursorColumn
        )

        debounceTask?.cancel()
        hasPendingWrite = true

        let interval = debounceInterval
        debounceTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(interval))
            } catch {
                return // Cancelled
            }
            guard let self else { return }
            await self.writeContext(payload)
        }
    }

    /// Deletes the context file from Application Support.
    /// Called when the project window closes.
    func cleanup() {
        debounceTask?.cancel()
        debounceTask = nil
        hasPendingWrite = false
        lastWrittenContext = nil

        guard let fileURL = contextFileURL else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Returns the URL of the context file for the current project root, or nil.
    var contextFileURL: URL? {
        guard let projectRoot else { return nil }
        let dir = contextsDirectory
        let fileName = Self.hashedFileName(for: projectRoot)
        return dir.appendingPathComponent(fileName)
    }

    // MARK: - Path computation

    /// Computes a deterministic file name from a project root URL using SHA-256.
    static func hashedFileName(for rootURL: URL) -> String {
        let hash = SHA256.hash(data: Data(rootURL.path.utf8))
        let hex = hash.prefix(16).map { String(format: "%02x", $0) }.joined()
        return "\(hex).json"
    }

    /// The directory where context files are stored.
    var contextsDirectory: URL {
        if let override = contextsDirOverride { return override }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Self.contextsDirName)
    }

    // MARK: - Private helpers

    private func writeContext(_ payload: Payload) {
        guard let fileURL = contextFileURL else { return }

        // Skip redundant writes
        if payload == lastWrittenContext { return }

        guard let data = try? encoder.encode(payload) else { return }

        // Append trailing newline for POSIX-friendly output
        var output = data
        output.append(contentsOf: [0x0A]) // '\n'

        do {
            // Ensure contexts directory exists
            let dir = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

            try output.write(to: fileURL, options: .atomic)
            // Set restrictive permissions atomically via FileManager
            try FileManager.default.setAttributes(
                Self.filePermissions,
                ofItemAtPath: fileURL.path
            )
        } catch {
            return
        }

        lastWrittenContext = payload
        hasPendingWrite = false
    }

    /// Removes the legacy `.pine-context.json` from the project root if it exists.
    private func removeLegacyFileIfNeeded() {
        guard let projectRoot else { return }
        let legacyURL = projectRoot.appendingPathComponent(Self.legacyFileName)
        try? FileManager.default.removeItem(at: legacyURL)
    }

    // MARK: - Relative path computation

    /// Computes the relative path of a file URL within a project root.
    /// If the file is outside the project, returns `lastPathComponent`.
    static func relativePath(fileURL: URL?, rootURL: URL) -> String? {
        guard let fileURL else { return nil }
        // Normalize root path to always end without trailing slash
        let rootPath = rootURL.path.hasSuffix("/")
            ? String(rootURL.path.dropLast())
            : rootURL.path
        let prefix = rootPath + "/"
        return fileURL.path.hasPrefix(prefix)
            ? String(fileURL.path.dropFirst(prefix.count))
            : fileURL.lastPathComponent
    }
}

// MARK: - Payload model

extension ContextFileWriter {
    /// The JSON structure written to the context file.
    struct Payload: Codable, Equatable, Sendable {
        let currentFile: String?
        let cursorLine: Int?
        let cursorColumn: Int?
    }
}
