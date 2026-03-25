//
//  ContextFileWriter.swift
//  Pine
//

import Foundation

/// Writes a `.pine-context.json` file to the project root containing current
/// editor context (active file, cursor position). Terminal sessions and external
/// tools can read this file to know what the user is working on.
///
/// The file is written atomically with a 500ms debounce to avoid excessive I/O
/// during rapid cursor movement. The file is deleted when the project closes.
///
/// - Note: Writing the context file triggers an FSEvents notification in the
///   project directory. `FileSystemWatcher` will pick this up and refresh the
///   file tree. This is harmless — the file is hidden (dot-prefixed) and listed
///   in `.gitignore`, so it does not affect the sidebar or git status.
actor ContextFileWriter {

    /// Name of the context file written to the project root.
    static let fileName = ".pine-context.json"

    /// File permissions: owner read/write only (0600).
    private static let filePermissions: [FileAttributeKey: Any] = [
        .posixPermissions: NSNumber(value: 0o600)
    ]

    // MARK: - Internal state (visible for testing)

    /// The project root directory. Set via `setProjectRoot(_:)`.
    private(set) var projectRoot: URL?

    /// Debounce interval in seconds. Exposed for testing.
    private(set) var debounceInterval: TimeInterval = 0.5

    /// Tracks whether a write is pending (for testing).
    private(set) var hasPendingWrite = false

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
    func setProjectRoot(_ url: URL?) {
        projectRoot = url
    }

    /// Sets a custom debounce interval. Intended for tests only.
    func setDebounceInterval(_ interval: TimeInterval) {
        debounceInterval = interval
    }

    /// Schedules a debounced write of the editor context to `.pine-context.json`.
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

    /// Deletes the `.pine-context.json` file from the project root.
    /// Called when the project window closes.
    func cleanup() {
        debounceTask?.cancel()
        debounceTask = nil
        hasPendingWrite = false
        lastWrittenContext = nil

        guard let projectRoot else { return }
        let fileURL = projectRoot.appendingPathComponent(Self.fileName)
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Returns the URL of the context file for the current project root, or nil.
    var contextFileURL: URL? {
        projectRoot.map { $0.appendingPathComponent(Self.fileName) }
    }

    // MARK: - Private helpers

    private func writeContext(_ payload: Payload) {
        guard let projectRoot else { return }

        // Skip redundant writes
        if payload == lastWrittenContext { return }

        let fileURL = projectRoot.appendingPathComponent(Self.fileName)

        guard let data = try? encoder.encode(payload) else { return }

        // Append trailing newline for POSIX-friendly output
        var output = data
        output.append(contentsOf: [0x0A]) // '\n'

        do {
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
    /// The JSON structure written to `.pine-context.json`.
    struct Payload: Codable, Equatable, Sendable {
        let currentFile: String?
        let cursorLine: Int?
        let cursorColumn: Int?
    }
}
