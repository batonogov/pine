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
//  Precise attribution requires explicit structured provenance. The
//  conservative heuristic here marks a file change as inferred when exactly
//  one live session could match and preserves every candidate when several
//  sessions make ownership ambiguous. It never selects one candidate as the
//  owner of overlapping work.
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
        guard last.attribution == action.attribution,
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

    /// Actions associated with the given session, in chronological order.
    ///
    /// Ambiguous actions are returned for every candidate session. Callers
    /// must inspect `action.attribution` rather than treating this query as
    /// proof that the requested session owns the action.
    func actions(forSession sessionID: UUID) -> [AgentAction] {
        actions.filter { $0.attribution.contains(sessionID: sessionID) }
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
    /// requires explicit structured provenance):
    /// - **No active session** → ignored (return).
    /// - **Exactly one candidate session** → marked as inferred.
    /// - **Multiple candidate sessions** → recorded as ambiguous with every
    ///   candidate, in deterministic order. No owner is selected.
    ///
    /// - Parameters:
    ///   - url: The file URL reported by the file-system watcher.
    ///   - activeSessions: Non-`.done` agent sessions, typically
    ///     `TerminalManager.agentDetector.activeSessions`.
    func noteFileSystemChange(at url: URL, activeSessions: [AgentSession]) {
        // attribution-heuristic: only attribute to live (non-.done) sessions.
        let live = activeSessions.filter { $0.state != .done }
        guard let attribution = resolveAttribution(in: live) else { return }

        record(
            AgentAction(
                attribution: attribution,
                kind: .fileWrite,
                status: .completed,
                fileURL: url,
                summary: Strings.agentActivityFileChanged(url.lastPathComponent)
            )
        )
    }

    /// Produces a stable, duplicate-free candidate set. Stable ordering makes
    /// dedupe independent of detector enumeration order. A malformed snapshot
    /// that repeats one UUID with conflicting agent types remains ambiguous
    /// rather than arbitrarily choosing either representation.
    private func resolveAttribution(
        in sessions: [AgentSession]
    ) -> AgentActionAttribution? {
        let sorted = sessions.sorted { lhs, rhs in
            let lhsID = lhs.id.uuidString
            let rhsID = rhs.id.uuidString
            if lhsID != rhsID { return lhsID < rhsID }
            return stableAgentTypeKey(lhs.agentType) < stableAgentTypeKey(rhs.agentType)
        }

        var candidates: [AgentActionCandidate] = []
        for session in sorted {
            let candidate = AgentActionCandidate(
                sessionID: session.id,
                agentType: session.agentType
            )
            if !candidates.contains(candidate) {
                candidates.append(candidate)
            }
        }

        guard let onlyCandidate = candidates.first else { return nil }
        if candidates.count == 1 {
            return .inferred(onlyCandidate)
        }
        return .ambiguous(candidates: candidates)
    }

    private func stableAgentTypeKey(_ agentType: AgentType) -> String {
        switch agentType {
        case .claudeCode:
            "claude-code"
        case .codex:
            "codex"
        case .aider:
            "aider"
        case .copilot:
            "copilot"
        case .pi:
            "pi"
        case .generic(let name):
            "generic:\(name)"
        }
    }
}
