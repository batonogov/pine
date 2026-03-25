//
//  ContextFileWriter.swift
//  Pine
//
//  Created by Claude on 25.03.2026.
//

import Foundation

/// Writes a `.pine-context.json` file to the project root containing current
/// editor context (active file, cursor position). Terminal sessions and external
/// tools can read this file to know what the user is working on.
///
/// The file is written atomically with a 500ms debounce to avoid excessive I/O
/// during rapid cursor movement. The file is deleted when the project closes.
@Observable
final class ContextFileWriter {

    /// Name of the context file written to the project root.
    static let fileName = ".pine-context.json"

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
    private var lastWrittenContext: ContextPayload?

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
        let payload = ContextPayload(
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
            guard let self, !Task.isCancelled else { return }
            self.writeContext(payload)
            self.hasPendingWrite = false
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

    private func writeContext(_ payload: ContextPayload) {
        guard let projectRoot else { return }

        // Skip redundant writes
        if payload == lastWrittenContext { return }

        let fileURL = projectRoot.appendingPathComponent(Self.fileName)

        // Build JSON manually for a clean, minimal output
        var json = "{"
        if let file = payload.currentFile {
            let escaped = file.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            json += "\"currentFile\":\"\(escaped)\""
        } else {
            json += "\"currentFile\":null"
        }
        if let line = payload.cursorLine {
            json += ",\"cursorLine\":\(line)"
        } else {
            json += ",\"cursorLine\":null"
        }
        if let col = payload.cursorColumn {
            json += ",\"cursorColumn\":\(col)"
        } else {
            json += ",\"cursorColumn\":null"
        }
        json += "}\n"

        guard let data = json.data(using: .utf8) else { return }

        // Atomic write via temporary file
        let tempURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent(".\(Self.fileName).tmp")
        do {
            try data.write(to: tempURL)
            // Use replaceItemAt for atomic rename
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tempURL)
        } catch {
            // replaceItemAt may fail if the target doesn't exist yet
            try? FileManager.default.moveItem(at: tempURL, to: fileURL)
        }

        lastWrittenContext = payload
    }
}

// MARK: - Payload model

/// The JSON structure written to `.pine-context.json`.
struct ContextPayload: Codable, Equatable {
    let currentFile: String?
    let cursorLine: Int?
    let cursorColumn: Int?
}
