//
//  AgentDetector.swift
//  Pine
//
//  Detects running AI agent CLI processes from process snapshots and tracks
//  them as `AgentSession`s (vision #933, Phase 1 — Awareness).
//
//  This implementation covers ONLY process-name matching: the executable name
//  extracted from a process command line is resolved against
//  `AgentType.cliNames`. Output-pattern matching, file-system event
//  correlation, and terminal-tab wiring are intentionally out of scope and
//  tracked as separate issues (see #950 Out of scope, #951, #952).
//

import Foundation

/// A single process entry in a snapshot handed to `AgentDetector`.
///
/// Callers (e.g. a future terminal coordinator) produce these by shelling out
/// to `ps` off the main thread. The detector never shells out itself — it
/// consumes injected snapshots — which keeps the detection logic pure and
/// trivially unit-testable.
///
/// `cwd` is carried for future file-system correlation (Phase 2) but is NOT
/// used for matching in this implementation.
///
/// Marked `nonisolated` so the memberwise init is callable from a
/// `nonisolated` context (`AgentDetectionCoordinator.parsePsOutput` runs
/// off the main thread on a background dispatch queue). Without this, the
/// project-wide `-default-isolation=MainActor` flag would make the init
/// MainActor-isolated and break the off-main `ps` parsing path.
nonisolated struct DetectedProcess: Sendable, Equatable {
    /// Operating-system process id.
    let pid: Int32
    /// Full command line as reported by `ps -o command=` (executable + args).
    let command: String
    /// Working directory of the process, if known. Reserved for Phase 2
    /// (file-system correlation); not consulted for matching in this PR.
    let cwd: URL?

    init(pid: Int32, command: String, cwd: URL? = nil) {
        self.pid = pid
        self.command = command
        self.cwd = cwd
    }
}

/// Detects AI agent CLI processes from injected process snapshots and tracks
/// their lifecycle as `AgentSession`s.
///
/// The detector is `@MainActor` + `@Observable` so SwiftUI consumers
/// (terminal-tab badges #951, status-bar agent summary #952) can observe
/// `detectedSessions` / `activeSessions` directly. All mutation happens on
/// the main thread; callers dispatch the `ps` snapshot capture off-main and
/// hand the result back via `processSnapshotDidUpdate(_:)`.
///
/// **Scope (issue #950, narrowed):** only process-name matching is
/// implemented here. A process is recognised as an agent iff the executable
/// name (last path component of the first command token) resolves to a
/// known, non-generic `AgentType`. Unknown commands — `bash`, `ls`, `git`,
/// `vim`, etc. — are never tracked, which keeps false positives at zero.
///
/// **Lifecycle:** a newly recognised agent pid creates an `AgentSession` in
/// `.idle` state (we know the process is alive but, without output-pattern
/// matching, cannot tell what it is doing). When a pid disappears from the
/// snapshot the corresponding session transitions to `.done` and is
/// disassociated from the pid so that a future pid reuse creates a fresh
/// session rather than resurrecting a finished one.
@MainActor
@Observable
final class AgentDetector {
    /// All sessions the detector has ever recognised, in detection order,
    /// including finished ones (`.done`). Consumers that only want live
    /// agents should read `activeSessions`.
    private(set) var detectedSessions: [AgentSession] = []

    /// Active sessions keyed by pid for O(1) lookup during reconciliation.
    /// A session is removed from this map (but kept in `detectedSessions`)
    /// once its pid is no longer observed.
    private var sessionsByPID: [Int32: AgentSession] = [:]

    /// Sessions whose state is not `.done`.
    var activeSessions: [AgentSession] {
        detectedSessions.filter { $0.state != .done }
    }

    /// Returns the active (non-`.done`) session tracking the given pid, or
    /// `nil` if no agent with that pid is currently tracked.
    ///
    /// Used by `AgentDetectionCoordinator` to map a terminal tab's foreground
    /// process to its agent session for badge display (#951).
    func session(forPID pid: Int32) -> AgentSession? {
        guard let session = sessionsByPID[pid], session.state != .done else { return nil }
        return session
    }

    /// Convenience accessor for the number of currently-active agent sessions.
    var activeCount: Int { activeSessions.count }

    /// Processes a full process snapshot: recognises new agent processes,
    /// and reconciles (marks `.done`) sessions whose pids are absent.
    ///
    /// Idempotent for a given snapshot: feeding the same snapshot twice does
    /// not duplicate sessions — the second call only runs reconciliation,
    /// which is a no-op when nothing changed.
    ///
    /// - Parameter processes: the full process list as captured by the
    ///   caller (e.g. via `ps -eo pid=,command=`). Order is not significant.
    func processSnapshotDidUpdate(_ processes: [DetectedProcess]) {
        let snapshotPIDs = Set(processes.map(\.pid))

        // 1. Detect: create sessions for newly-recognised agent pids.
        for process in processes {
            let executableName = Self.extractExecutableName(from: process.command)
            guard let resolved = AgentType.resolve(fromProcessName: executableName),
                  !Self.isGeneric(resolved) else { continue }

            // Already tracked and still active — nothing to do in this PR.
            // State refinement (thinking / executing / waitingInput) requires
            // output-pattern matching, which is out of scope.
            if sessionsByPID[process.pid] != nil { continue }

            let session = AgentSession(agentType: resolved, state: .idle)
            sessionsByPID[process.pid] = session
            detectedSessions.append(session)
        }

        // 2. Reconcile: mark sessions for pids no longer present as done.
        reconcile(activePIDs: snapshotPIDs)
    }

    /// Marks every tracked session whose pid is not in `activePIDs` as
    /// `.done` and disassociates it from its pid.
    ///
    /// Also called internally by `processSnapshotDidUpdate(_:)`. Exposed so a
    /// caller that receives a single process-exit signal (e.g. `SIGCHLD`)
    /// can reconcile without producing a full snapshot.
    func reconcile(activePIDs: Set<Int32>) {
        let trackedPIDs = Array(sessionsByPID.keys)
        for pid in trackedPIDs where !activePIDs.contains(pid) {
            markDone(pid: pid)
        }
    }

    /// Removes all `.done` sessions from `detectedSessions`, freeing memory.
    /// Active sessions are never removed. Useful for periodic cleanup by the
    /// owner of the detector.
    func clearFinishedSessions() {
        detectedSessions.removeAll { $0.state == .done }
    }

    // MARK: - Internal

    /// Transitions the session for `pid` to `.done` and removes the pid
    /// mapping so that pid reuse later creates a fresh session.
    private func markDone(pid: Int32) {
        guard let session = sessionsByPID.removeValue(forKey: pid) else { return }
        session.state = .done
    }

    /// Returns true if `type` is the `.generic` case.
    ///
    /// Generic agents have no registered `cliNames` and must not be tracked
    /// by process-name matching alone — doing so would track every unknown
    /// process (`bash`, `ls`, ...) and cause constant false positives.
    private static func isGeneric(_ type: AgentType) -> Bool {
        if case .generic = type { return true }
        return false
    }

    /// Extracts the executable name from a `ps -o command=` string.
    ///
    /// Handles these shapes:
    /// - `claude` → `claude`
    /// - `/usr/local/bin/claude` → `claude`
    /// - `/usr/local/bin/claude --verbose` → `claude`
    /// - `node /opt/homebrew/bin/pi` → `pi`  (interpreter-wrapper form)
    /// - `node /usr/local/lib/.../claude.js` → `claude`  (script extension stripped)
    ///
    /// Many agent CLIs ship as script files launched through an interpreter
    /// (`pi`, `claude`, `aider`, …). Homebrew's `pi`, for example, is a
    /// `node` script, so `ps` reports it as `node /opt/homebrew/bin/pi`. The
    /// bare first token (`node`) resolves to a generic name and would never
    /// match. When the first token is a known interpreter, we therefore treat
    /// the *second* token as the real CLI, resolving its basename and stripping
    /// a common script extension. A second token that is not a known agent
    /// (e.g. `server.js`) still resolves to `.generic` and is not tracked.
    static func extractExecutableName(from command: String) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let tokens = trimmed.split(separator: " ", omittingEmptySubsequences: true)
        guard let firstToken = tokens.first else { return "" }
        let firstBase = (String(firstToken) as NSString).lastPathComponent

        // Interpreter-wrapper form: `node /path/pi`, `python3 …/aider`, …
        // The second token is the real CLI; resolve its basename and strip a
        // common script extension so `claude.js` → `claude`.
        if Self.interpreterWrappers.contains(firstBase.lowercased()), tokens.count >= 2 {
            let scriptBase = (String(tokens[1]) as NSString).lastPathComponent
            return Self.strippingScriptExtension(scriptBase)
        }
        return firstBase
    }

    /// Interpreter executable basenames that wrap a script CLI. When the first
    /// token of a command is one of these, the second token holds the real CLI.
    /// Lowercased; compared case-insensitively.
    private static let interpreterWrappers: Set<String> = [
        "node", "node.exe",
        "python", "python3", "python3.exe",
        "ruby", "ruby.exe",
        "bun", "bun.exe",
        "deno", "deno.exe",
        "tsx", "tsx.exe",
        "npx",
    ]

    /// Script-file extensions stripped from a wrapped script's basename so
    /// `node …/claude.js` resolves to `claude`.
    private static let scriptExtensions: Set<String> = [
        "js", "mjs", "cjs", "ts", "mts", "cts",
    ]

    /// Returns `name` with a single trailing script extension removed (if any),
    /// preserving the original casing of the stem.
    private static func strippingScriptExtension(_ name: String) -> String {
        let lower = name.lowercased()
        for ext in scriptExtensions where lower.hasSuffix("." + ext) {
            return String(name.dropLast(ext.count + 1))
        }
        return name
    }
}
