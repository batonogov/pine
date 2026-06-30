//
//  AgentActivityStore.swift
//  Pine
//
//  `@MainActor @Observable` store holding a chronological, capped feed of
//  `AgentAction`s for the Agent Activity Panel (vision #933, Phase 2 —
//  Visibility, issue #1072).
//
//  The store is the single source of truth for the Activity Panel UI. It
//  deduplicates near-identical consecutive actions, caps memory at
//  `maxActions`, and provides a minimal real data source: correlating
//  `FileSystemWatcher` change signals with active agent sessions.
//
//  Precise attribution (parsing terminal output to know exactly which agent
//  wrote which file) is intentionally out of scope (#1072 Out of scope). The
//  conservative heuristic here attributes a file change to the single active
//  agent when unambiguous, and to the most-recently-active session otherwise.
//

import Foundation

@MainActor
@Observable
final class AgentActivityStore {
    /// Chronological actions, newest-last. Capped to `maxActions`.
    private(set) var actions: [AgentAction] = []

    /// Maximum number of actions retained; oldest are dropped beyond this.
    static let maxActions = 1000

    /// Window within which two identical actions are considered duplicates and
    /// collapsed into one (seconds).
    private static let dedupeWindow: TimeInterval = 1.0

    init() {}

    // MARK: - Recording

    /// Appends an action unless it duplicates the most recent action (same
    /// session, kind, file URL, and summary) within the dedupe window. Keeps
    /// the feed capped at `maxActions`.
    func record(_ action: AgentAction) {
        if isDuplicateOfLast(action) { return }
        actions.append(action)
        trimToCapacity()
    }

    /// Returns `true` when `action` matches the last recorded action in every
    /// dedupe-relevant field and happened within `dedupeWindow`.
    private func isDuplicateOfLast(_ action: AgentAction) -> Bool {
        guard let last = actions.last else { return false }
        guard last.sessionID == action.sessionID,
              last.kind == action.kind,
              last.fileURL == action.fileURL,
              last.summary == action.summary else { return false }
        return action.timestamp.timeIntervalSince(last.timestamp) <= Self.dedupeWindow
    }

    /// Drops the oldest actions while `actions.count > maxActions`.
    private func trimToCapacity() {
        let overflow = actions.count - Self.maxActions
        guard overflow > 0 else { return }
        actions.removeFirst(overflow)
    }

    // MARK: - Queries

    /// Actions belonging to the given session, in chronological order.
    func actions(forSession sessionID: UUID) -> [AgentAction] {
        actions.filter { $0.sessionID == sessionID }
    }

    /// Actions filtered by an optional kind and/or status.
    func filtered(kind: AgentActionKind? = nil, status: AgentActionStatus? = nil) -> [AgentAction] {
        actions.filter { action in
            (kind == nil || action.kind == kind)
                && (status == nil || action.status == status)
        }
    }

    /// Clears all actions (used on project switch / teardown).
    func clear() {
        actions.removeAll()
    }

    // MARK: - File-system correlation (minimal real data source)

    /// Records a `.fileWrite` action for a file-system change attributed to an
    /// active agent session.
    ///
    /// Attribution heuristic (deliberately conservative — precise attribution
    /// requires terminal-output parsing, out of scope for #1072):
    /// - **No active session** → ignored (return).
    /// - **Exactly one active session** → attributed to it.
    /// - **Multiple active sessions** → attributed to the most-recently-active
    ///   session (by `startedAt`). This is an approximation; the action's
    ///   summary is suffixed with an ambiguity marker.
    ///
    /// - Parameters:
    ///   - url: The file URL reported by the file-system watcher.
    ///   - activeSessions: Non-`.done` agent sessions, typically
    ///     `TerminalManager.agentDetector.activeSessions`.
    func noteFileSystemChange(at url: URL, activeSessions: [AgentSession]) {
        // attribution-heuristic: only attribute to live (non-.done) sessions.
        let live = activeSessions.filter { $0.state != .done }
        guard let target = resolveAttribution(in: live) else { return }

        record(
            AgentAction(
                sessionID: target.id,
                agentType: target.agentType,
                kind: .fileWrite,
                status: .completed,
                fileURL: url,
                summary: summary(for: url, ambiguous: live.count > 1)
            )
        )
    }

    /// Picks the session to attribute a change to, or `nil` when there is no
    /// active session. With exactly one session attribution is unambiguous;
    /// with several, the most-recently-started wins.
    private func resolveAttribution(in sessions: [AgentSession]) -> AgentSession? {
        guard let first = sessions.first else { return nil }
        guard sessions.count > 1 else { return first }
        // attribution-heuristic (ambiguous): most-recently-active by startedAt.
        return sessions.max(by: { $0.startedAt < $1.startedAt })
    }

    /// One-line summary for a file-write action. The file name keeps the row
    /// readable; the ambiguity marker flags heuristic attribution.
    private func summary(for url: URL, ambiguous: Bool) -> String {
        let name = url.lastPathComponent
        return ambiguous ? "Wrote \(name) (ambiguous)" : "Wrote \(name)"
    }
}
