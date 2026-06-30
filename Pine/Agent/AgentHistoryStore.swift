//
//  AgentHistoryStore.swift
//  Pine
//
//  Owns the persistent, replayable audit log of finished AI-agent sessions
//  (vision #933, Phase 2 — Visibility, issue #1073). Each finished session
//  becomes an `AgentHistoryEntry` appended to `.pine/agent-log.json`, so a
//  user can review what an agent did and revert it long after the process exits.
//
//  Persistence is atomic and off-main: a background `DispatchQueue` serialises
//  the write (temp file + `FileManager.replaceItem`), guarded by a generation
//  token — the same stale-write protection pattern as `FileSystemWatcher`. This
//  guarantees a write scheduled before a newer mutation never clobbers it.
//
//  `init` is tolerant: a missing or corrupt `.pine/agent-log.json` yields an
//  empty log and never crashes on project open. The store never writes outside
//  the project root and never logs file contents — only relative paths + a
//  summary string.
//

import Foundation

/// Outcome of a revert operation for a single history entry.
struct AgentHistoryRevertResult: Sendable, Equatable {
    /// Whether every affected file was restored to HEAD.
    let allSucceeded: Bool
    /// Per-file results (path + success/error), in entry order.
    let fileResults: [GitFileRevertResult]
}

/// Persistent, observable log of finished AI-agent sessions, backed by
/// `.pine/agent-log.json` under the project root.
///
/// `@MainActor` + `@Observable` so SwiftUI views (`AgentHistoryView`) observe
/// `entries` directly. All file I/O is dispatched off the main thread; the
/// in-memory `entries` array is the source of truth that mutations update
/// synchronously, with disk writes trailing asynchronously.
@MainActor
@Observable
final class AgentHistoryStore {
    /// All recorded entries, newest-last (append order). Persisted to disk.
    private(set) var entries: [AgentHistoryEntry] = []

    /// Session IDs that have already been logged, to avoid double-logging a
    /// session finalized more than once (e.g. on both detection and termination).
    private var loggedSessionIDs: Set<UUID> = []

    /// Project root whose `.pine/` directory holds the log. `nil` when no
    /// project is open (e.g. the Welcome window); in that state the store is
    /// in-memory only and `finalize`/`revert` persist nothing. Set via
    /// `updateProjectRoot(_:)` once `WorkspaceManager` resolves the root.
    private(set) var projectRoot: URL?

    /// Sets the project root and reloads the on-disk log, so the store picks
    /// up an existing `.pine/agent-log.json` as soon as the project opens
    /// (the root is unknown at `ProjectManager.init` time). Safe to call once;
    /// calling with a new root resets in-memory state and reloads.
    func updateProjectRoot(_ root: URL?) {
        projectRoot = root
        entries = []
        loggedSessionIDs = []
        loadFromDisk()
    }

    /// Serial queue that owns all disk writes, mirroring `FileSystemWatcher`.
    private let writeQueue = DispatchQueue(label: "com.pine.agent-history", qos: .utility)

    /// Generation token incremented before each persist. A queued write
    /// captures the token and skips itself if a newer write superseded it,
    /// preventing a stale write from clobbering newer data.
    nonisolated(unsafe) private var writeGeneration = 0

    /// Cap on retained entries to bound `.pine/agent-log.json` growth. Older
    /// entries are trimmed first (FIFO) on append.
    private let maxEntries = 500

    init(projectRoot: URL? = nil) {
        self.projectRoot = projectRoot
        loadFromDisk()
    }

    // MARK: - Loading

    /// Loads `.pine/agent-log.json` if present and valid. Tolerates a missing
    /// file (nothing to load) and a corrupt file (logs + starts empty) so a
    /// bad log never blocks project open. Runs synchronously in `init` because
    /// the in-memory `entries` must be populated before the first UI render.
    private func loadFromDisk() {
        guard let logURL else { return }
        guard FileManager.default.fileExists(atPath: logURL.path) else { return }
        do {
            let data = try Data(contentsOf: logURL)
            // Tolerate an empty file (treat as no entries).
            guard !data.isEmpty else { return }
            entries = try Self.makeDecoder().decode([AgentHistoryEntry].self, from: data)
            loggedSessionIDs = Set(entries.map(\.sessionID))
        } catch {
            // Corrupt or unreadable log: never crash — start empty and log.
            // The damaged file is left in place; the next successful persist
            // overwrites it atomically.
            NSLog("AgentHistoryStore: failed to decode agent-log.json — starting empty. \(error.localizedDescription)")
            entries = []
            loggedSessionIDs = []
        }
    }

    /// Resolves `.pine/agent-log.json` under the project root, creating the
    /// `.pine/` directory if needed. Returns `nil` when no project is open.
    private var logURL: URL? {
        guard let projectRoot else { return nil }
        let pineDir = projectRoot.appendingPathComponent(".pine", isDirectory: true)
        if !FileManager.default.fileExists(atPath: pineDir.path) {
            do {
                try FileManager.default.createDirectory(at: pineDir, withIntermediateDirectories: true)
            } catch {
                NSLog("AgentHistoryStore: failed to create .pine directory. \(error.localizedDescription)")
                return nil
            }
        }
        return pineDir.appendingPathComponent("agent-log.json", isDirectory: false)
    }

    // MARK: - Recording

    /// Finalizes a finished agent session into a durable log entry.
    ///
    /// - Parameters:
    ///   - session: The finished `AgentSession` (typically `.done`).
    ///   - summary: Caller-computed summary, e.g. "5 files, +142/-38 lines".
    ///   - affectedRelativePaths: Relative paths (from project root) of files
    ///     the session modified. Each is validated via `isValidRelativePath`;
    ///     invalid entries (traversal/absolute) are dropped.
    func finalize(
        session: AgentSession,
        summary: String,
        affectedRelativePaths: [String]
    ) {
        // Avoid double-logging a session finalized twice (detection + termination).
        guard !loggedSessionIDs.contains(session.id) else { return }
        loggedSessionIDs.insert(session.id)

        let safePaths = affectedRelativePaths.filter(Self.isValidRelativePath)
        let entry = AgentHistoryEntry(
            sessionID: session.id,
            agentTypeRaw: session.agentType.stableIdentifier,
            startedAt: session.startedAt,
            endedAt: Date(),
            affectedFiles: safePaths,
            summary: summary.isEmpty
                ? Self.defaultSummary(fileCount: safePaths.count)
                : summary
        )
        append(entry)
    }

    /// Appends an entry directly (used by tests and restore), trims to
    /// `maxEntries`, and schedules an asynchronous persist.
    func append(_ entry: AgentHistoryEntry) {
        entries.append(entry)
        if entries.count > maxEntries {
            let surplus = entries.count - maxEntries
            entries.removeFirst(surplus)
        }
        persist()
    }

    // MARK: - Revert

    /// Reverts an entry's affected files to their committed state via
    /// `git checkout -- <file>`. Does **not** show UI; the caller confirms with
    /// the user first. A no-op for an already-reverted entry. Mutates the entry
    /// in place (`reverted = true`) only when at least one file succeeds.
    ///
    /// - Parameter entry: The entry to revert. Compared by `id` against
    ///   `entries`; passing a stale copy is safe (no-op if not found).
    /// - Returns: Per-file results and whether all succeeded. `.allSucceeded`
    ///   is `false` if `projectRoot` is nil, no git repo, or any file failed.
    func revert(entry: AgentHistoryEntry) -> AgentHistoryRevertResult {
        guard let projectRoot,
              let index = entries.firstIndex(where: { $0.id == entry.id })
        else {
            return AgentHistoryRevertResult(allSucceeded: false, fileResults: [])
        }

        // Never revert an already-reverted entry.
        guard !entries[index].reverted else {
            return AgentHistoryRevertResult(allSucceeded: false, fileResults: [])
        }

        guard !entries[index].affectedFiles.isEmpty else {
            entries[index].reverted = true
            persist()
            return AgentHistoryRevertResult(allSucceeded: true, fileResults: [])
        }

        // Revert runs off-main (git process); results applied back on main.
        // Captured by value; the entry's id+paths are immutable.
        let paths = entries[index].affectedFiles
        let root = projectRoot
        let results = nonisolatedRevert(paths: paths, root: root)

        let allSucceeded = results.allSucceed
        if allSucceeded {
            entries[index].reverted = true
            persist()
        }
        return AgentHistoryRevertResult(allSucceeded: allSucceeded, fileResults: results.results)
    }

    /// Runs `git checkout --` off the main thread. Isolated away from
    /// `@MainActor` so the blocking git process never stalls the UI. Returns
    /// a tuple to keep the `nonisolated` boundary simple.
    nonisolated private func nonisolatedRevert(
        paths: [String],
        root: URL
    ) -> (allSucceed: Bool, results: [GitFileRevertResult]) {
        let results = GitFileRevert.revert(relativePaths: paths, in: root)
        return (results.allSatisfy(\.success), results)
    }

    // MARK: - Persistence

    /// Schedules an atomic write of `entries` to `.pine/agent-log.json`,
    /// guarded by `writeGeneration` so a stale write can never overwrite newer
    /// data. The serialisation + write happen on `writeQueue`.
    private func persist() {
        // Increment + read under the write queue's lock so the counter is
        // never raced between the main actor and the write queue.
        let generation = writeQueue.sync { writeGeneration += 1; return writeGeneration }
        let snapshot = entries
        let root = projectRoot

        writeQueue.async { [weak self] in
            guard let self else { return }
            // If a newer write was scheduled, skip this one.
            guard self.isActive(generation: generation) else { return }
            self.write(snapshot: snapshot, root: root, generation: generation)
        }
    }

    /// Thread-safe staleness check, matching `FileSystemWatcher.isActive`.
    ///
    /// Reads `writeGeneration` directly because this is only ever called from
    /// within `writeQueue` (the async block in `persist` and from `write`). A
    /// `writeQueue.sync` here would deadlock: it would run `dispatch_sync` on a
    /// queue already owned by the current thread. Because the queue is serial
    /// and `writeGeneration` is mutated only via `writeQueue.sync` (from the
    /// main actor), reading it here is race-free.
    nonisolated private func isActive(generation: Int) -> Bool {
        writeGeneration == generation
    }

    /// Encodes the snapshot to JSON and writes it atomically via a temp file +
    /// `FileManager.replaceItem`. Runs on `writeQueue`. A `nil` root (no
    /// project) is a no-op — the in-memory log is sufficient.
    nonisolated private func write(snapshot: [AgentHistoryEntry], root: URL?, generation: Int) {
        guard let root else { return }
        guard isActive(generation: generation) else { return }

        let pineDir = root.appendingPathComponent(".pine", isDirectory: true)
        let logURL = pineDir.appendingPathComponent("agent-log.json", isDirectory: false)
        let encoder = Self.makeEncoder()

        guard let data = try? encoder.encode(snapshot) else { return }

        // Create .pine/ if missing (the store may persist after a fresh clone).
        if !FileManager.default.fileExists(atPath: pineDir.path) {
            do {
                try FileManager.default.createDirectory(at: pineDir, withIntermediateDirectories: true)
            } catch {
                NSLog("AgentHistoryStore: failed to create .pine during persist. \(error.localizedDescription)")
                return
            }
        }

        // Atomic write: temp file in the same directory, then replace the
        // destination so a crash mid-write never leaves a truncated log.
        let tempURL = pineDir.appendingPathComponent(".agent-log.json.tmp", isDirectory: false)
        do {
            try data.write(to: tempURL, options: [.atomic])
            if FileManager.default.fileExists(atPath: logURL.path) {
                _ = try FileManager.default.replaceItemAt(
                    logURL,
                    withItemAt: tempURL,
                    backupItemName: nil,
                    options: [.usingNewMetadataOnly]
                )
            } else {
                try FileManager.default.moveItem(at: tempURL, to: logURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            NSLog("AgentHistoryStore: failed to persist agent-log.json. \(error.localizedDescription)")
        }
    }

    /// Builds a decoder matching the encoder in `write` (ISO8601 dates, so the
    /// long-lived `.pine/agent-log.json` is human-readable and portable). Both
    /// sides MUST use the same date strategy or a round-trip silently fails to
    /// decode and the log appears empty on reload.
    nonisolated static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Builds a default encoder. Kept here so callers writing test fixtures use
    /// the same strategy as `write`.
    nonisolated static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    // MARK: - Path safety

    /// Validates that a relative path is safe to record and later revert: it
    /// must be relative (not absolute) and must not escape the project root via
    /// `..` components. Rejects empty paths too.
    static func isValidRelativePath(_ path: String) -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        // Absolute paths are rejected outright.
        guard trimmed.first != "/" else { return false }
        // Reject any traversal component. Splitting on "/" matches both "../x"
        // and "a/../../b".
        let components = trimmed.split(separator: "/", omittingEmptySubsequences: true)
        return !components.contains("..")
    }

    /// Builds a default summary when the caller did not compute a line diff.
    private static func defaultSummary(fileCount: Int) -> String {
        fileCount == 1 ? "1 file" : "\(fileCount) files"
    }
}
