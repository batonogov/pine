//
//  AgentHistoryStore.swift
//  Pine
//
//  Owns the persistent history of finished AI-agent sessions (vision #933,
//  Phase 2 — Visibility, issue #1073). Each finished session becomes an
//  `AgentHistoryEntry` appended to `.pine/agent-log.json`, so a user can
//  review observed activity after the process exits.
//
//  Architecture: the observable state (`entries`, `projectRoot`) lives on the
//  main actor so SwiftUI views observe it directly; all disk I/O is delegated
//  to a separate `nonisolated` `AgentHistoryLogWriter` that owns the serial
//  write queue. This split is required by Pine's `check_nonisolated.py` guard
//  (see issue #693): a `@MainActor` type that itself owns a background
//  `DispatchQueue` is the crash pattern that took down #613/#693/
//  SyntaxHighlighter — the queue's async closure inherits MainActor isolation
//  and traps on `dispatch_assert_queue`. Making the *writer* `nonisolated`
//  (mirroring `FileSystemWatcher`) keeps the guard green and the queue safe.
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
    /// Safety reason when the entry was rejected before any mutation.
    let blockedReason: AgentHistoryUndoUnavailableReason?

    init(
        allSucceeded: Bool,
        fileResults: [GitFileRevertResult],
        blockedReason: AgentHistoryUndoUnavailableReason? = nil
    ) {
        self.allSucceeded = allSucceeded
        self.fileResults = fileResults
        self.blockedReason = blockedReason
    }
}

/// Persistent, observable log of finished AI-agent sessions, backed by
/// `.pine/agent-log.json` under the project root.
///
/// `@MainActor` + `@Observable` so SwiftUI views (`AgentHistoryView`) observe
/// `entries` directly. The in-memory `entries` array is the source of truth
/// that mutations update synchronously; disk writes trail asynchronously via
/// the owned `AgentHistoryLogWriter`.
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

    /// Owns the serial disk-write queue. `nonisolated` so the guard accepts it
    /// (see class doc). The store only hands it value-type snapshots.
    private let writer = AgentHistoryLogWriter()

    /// Cap on retained entries to bound `.pine/agent-log.json` growth. Older
    /// entries are trimmed first (FIFO) on append.
    private let maxEntries = 500

    init(projectRoot: URL? = nil) {
        self.projectRoot = projectRoot
        loadFromDisk()
    }

    // MARK: - Project root / loading

    /// Sets the project root and reloads the on-disk log, so the store picks
    /// up an existing `.pine/agent-log.json` as soon as the project opens
    /// (the root is unknown at `ProjectManager.init` time). Calling with a new
    /// root resets in-memory state and reloads.
    func updateProjectRoot(_ root: URL?) {
        projectRoot = root
        entries = []
        loggedSessionIDs = []
        loadFromDisk()
    }

    /// Loads `.pine/agent-log.json` if present and valid. Tolerates a missing
    /// file (nothing to load) and a corrupt file (logs + starts empty) so a
    /// bad log never blocks project open. Runs synchronously in `init` because
    /// the in-memory `entries` must be populated before the first UI render.
    private func loadFromDisk() {
        guard let root = projectRoot else { return }
        let logURL = root.appendingPathComponent(".pine", isDirectory: true)
            .appendingPathComponent("agent-log.json", isDirectory: false)
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

    // MARK: - Recording

    /// Finalizes a finished agent session into a durable log entry.
    ///
    /// - Parameters:
    ///   - session: The finished `AgentSession` (typically `.done`).
    ///   - summary: Caller-computed summary, e.g. "5 files".
    ///   - affectedRelativePaths: Relative paths (from project root) of files
    ///     the session modified. Each is validated via `isValidRelativePath`;
    ///     invalid entries (traversal/absolute) are dropped.
    func finalize(
        session: AgentSession,
        summary: String,
        affectedRelativePaths: [String],
        attribution: AgentHistoryAttribution = .heuristic
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
            attribution: attribution,
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

    /// Rejects undo until an entry carries a verified, checked inverse change
    /// set. The current history format stores paths but no such change set, so
    /// this method has no working-tree mutation path at all (#1183). The guard
    /// lives here as well as in the UI so a stale row, direct caller, or future
    /// presentation bug cannot bypass it.
    ///
    /// - Parameter entry: The entry to revert. Compared by `id` against
    ///   `entries`; passing a stale copy is safe (no-op if not found).
    /// - Returns: A blocked result for every current entry. `fileResults` is
    ///   empty because no file operation is attempted.
    func revert(entry: AgentHistoryEntry) async -> AgentHistoryRevertResult {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else {
            return AgentHistoryRevertResult(allSucceeded: false, fileResults: [])
        }

        // Never revert an already-reverted entry.
        guard !entries[index].reverted else {
            return AgentHistoryRevertResult(allSucceeded: false, fileResults: [])
        }

        let reason: AgentHistoryUndoUnavailableReason
        switch entries[index].undoAvailability {
        case .available:
            // `.available` is reserved for a future exact inverse-change-set
            // format. Until its checked apply operation exists, even that
            // state must fail closed instead of falling back to whole-file git.
            reason = .missingVerifiedReversibleChangeSet
        case .unavailable(let unavailableReason):
            reason = unavailableReason
        }
        return AgentHistoryRevertResult(
            allSucceeded: false,
            fileResults: [],
            blockedReason: reason
        )
    }

    // MARK: - Persistence

    /// Schedules an atomic write of the current `entries` to disk via the
    /// nonisolated writer. Fire-and-forget from the main actor.
    private func persist() {
        writer.persist(snapshot: entries, root: projectRoot)
    }

    /// Blocks the calling (main) thread until every pending disk write has
    /// completed. Called from `applicationWillTerminate` so a session finalized
    /// at quit is guaranteed to reach `.pine/agent-log.json` before the OS
    /// reclaims the process — without this the feature's core durability
    /// promise ("a finished agent run is never lost") would be racy.
    func flush() {
        writer.flush()
    }

    // MARK: - Codable helpers

    /// Builds a decoder matching the encoder (ISO8601 dates, so the long-lived
    /// `.pine/agent-log.json` is human-readable and portable). Both sides MUST
    /// use the same date strategy or a round-trip silently fails to decode and
    /// the log appears empty on reload.
    nonisolated static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Builds the matching encoder.
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

    /// Builds a default summary when the caller did not supply one.
    private static func defaultSummary(fileCount: Int) -> String {
        fileCount == 1 ? "1 file" : "\(fileCount) files"
    }
}

// MARK: - AgentHistoryLogWriter

/// Serial, off-main writer for `.pine/agent-log.json`.
///
/// `nonisolated` (not `@MainActor`) because it owns a background
/// `DispatchQueue` — the canonical Pine pattern for background-queue owners
/// (see `FileSystemWatcher`, and issue #693 / the `check_nonisolated.py`
/// guard). `AgentHistoryStore` is `@MainActor` and observable, so it cannot
/// itself own the queue without tripping the guard's crash-class detector.
/// Instead it hands this writer immutable `[AgentHistoryEntry]` snapshots.
///
/// Writes are atomic (temp file + `FileManager.replaceItem`) so a crash
/// mid-write never leaves a truncated log. The serial queue guarantees writes
/// land in submission order, so the last snapshot for a burst always wins —
/// sufficient for this low-frequency log (written on session finalize / revert,
/// not on every keystroke).
nonisolated final class AgentHistoryLogWriter {
    private let writeQueue = DispatchQueue(label: "com.pine.agent-history", qos: .utility)

    /// Schedules an atomic write of `snapshot` to `<root>/.pine/agent-log.json`.
    /// A `nil` root (no project open) is a no-op — the in-memory log suffices.
    func persist(snapshot: [AgentHistoryEntry], root: URL?) {
        writeQueue.async { [weak self] in
            self?.write(snapshot: snapshot, root: root)
        }
    }

    /// Blocks the calling thread until all queued writes have completed. Used
    /// on app termination to guarantee durability. Safe because the queue never
    /// calls back onto its own thread (writes are fire-and-forget from main).
    func flush() {
        writeQueue.sync {}
    }

    private func write(snapshot: [AgentHistoryEntry], root: URL?) {
        guard let root else { return }
        let pineDir = root.appendingPathComponent(".pine", isDirectory: true)
        let logURL = pineDir.appendingPathComponent("agent-log.json", isDirectory: false)

        guard let data = try? AgentHistoryStore.makeEncoder().encode(snapshot) else { return }

        // Create .pine/ if missing (the store may persist after a fresh clone).
        if !FileManager.default.fileExists(atPath: pineDir.path) {
            do {
                try FileManager.default.createDirectory(at: pineDir, withIntermediateDirectories: true)
            } catch {
                NSLog("AgentHistoryLogWriter: failed to create .pine during persist. \(error.localizedDescription)")
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
                    options: []
                )
            } else {
                try FileManager.default.moveItem(at: tempURL, to: logURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            NSLog("AgentHistoryLogWriter: failed to persist agent-log.json. \(error.localizedDescription)")
        }
    }
}
