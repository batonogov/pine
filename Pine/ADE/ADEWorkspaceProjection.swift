//
//  ADEWorkspaceProjection.swift
//  Pine
//
//  The project's task list, derived from the existing Inbox rows (#1760).
//

import Foundation

/// The one indicator a task row carries. Each case is projected from the
/// task lifecycle and the Inbox row; none is a new stored state.
nonisolated enum ADETaskIndicator: CaseIterable, Sendable {
    /// An actionable decision or a pending question waits for the user.
    case needsDecision
    /// The attempt succeeded with current verification.
    case ready
    /// A live run has not settled.
    case running
    case failed
    case cancelled
    /// Everything else: unverified, superseded, never started, or stale.
    case unverified
}

/// One project task as the leading column lists it.
nonisolated struct ADETaskRow: Identifiable, Equatable, Sendable {
    let inbox: AgentInboxRow
    let indicator: ADETaskIndicator

    var id: UUID { inbox.id }
}

/// Pure projections for the project window's task list.
@MainActor
enum ADEWorkspaceProjection {
    /// The project's tasks: every project-backed Inbox row owned by
    /// `projectPath`, attention-worthy rows first, then the most recent.
    static func rows(
        from tasks: [AgentTask],
        projectPath: String,
        accuracyPolicy: AgentLifecycleAccuracyPolicy
    ) -> [ADETaskRow] {
        let owner = URL(fileURLWithPath: projectPath).standardizedFileURL.path
        let byID = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return AgentInboxSnapshot(tasks: tasks, accuracyPolicy: accuracyPolicy).rows
            .filter { $0.surface.isProjectBacked && $0.projectPath == owner }
            .compactMap { row in
                byID[row.id].map { ADETaskRow(inbox: row, indicator: indicator(for: row, task: $0)) }
            }
            .sorted(by: precedes)
    }

    /// A decision outranks everything, from the Inbox's own attention
    /// projection. Everything else is the #1756 transition table — the same
    /// classification that decides whether a task may continue — folded from
    /// ten phases onto the six states a row can show.
    static func indicator(for row: AgentInboxRow, task: AgentTask) -> ADETaskIndicator {
        if row.section == .needsAttention || row.needsDecision { return .needsDecision }
        switch AgentTaskContinuation.phase(for: task) {
        case .ready, .accepted: return .ready
        case .working: return .running
        case .failed: return .failed
        case .cancelled: return .cancelled
        case .none, .revisionPending, .settledAwaitingVerification, .restoredStale, .unknown:
            return .unverified
        }
    }

    /// Needs-decision and Ready rows come first; everything else keeps the
    /// Inbox order (unread, then newest) so rows only move when their state does.
    static func precedes(_ lhs: ADETaskRow, _ rhs: ADETaskRow) -> Bool {
        let left = attentionRank(lhs.indicator), right = attentionRank(rhs.indicator)
        if left != right { return left < right }
        if lhs.inbox.isUnread != rhs.inbox.isUnread { return lhs.inbox.isUnread }
        if lhs.inbox.startedAt != rhs.inbox.startedAt {
            return lhs.inbox.startedAt > rhs.inbox.startedAt
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func attentionRank(_ indicator: ADETaskIndicator) -> Int {
        switch indicator {
        case .needsDecision: 0
        case .ready: 1
        case .running, .failed, .cancelled, .unverified: 2
        }
    }
}

extension ADETaskRow {
    /// What the row is titled by: its goal when one was recorded.
    var goal: String { inbox.title ?? inbox.agentName }

    /// `true` for a task that never produced an observed run.
    var neverStarted: Bool { inbox.state == nil }
}

extension ADETaskIndicator {
    /// Whether the row asks for the user. Only these states warrant attention
    /// and are spoken when a task enters them.
    var warrantsAttention: Bool {
        self == .needsDecision || self == .ready
    }

    /// The row's state text. It reuses the task-result vocabulary so the list
    /// and the result never disagree about what a task is.
    @MainActor
    func title(neverStarted: Bool, locale: Locale = .current) -> String {
        switch self {
        case .needsDecision: Strings.agentResult(.needsDecisionTitle, locale: locale)
        case .ready: Strings.agentResult(.readyTitle, locale: locale)
        case .running: Strings.agentResult(.workingTitle, locale: locale)
        case .failed: Strings.openCodeTaskFailedText(locale: locale)
        case .cancelled: Strings.agentResult(.cancelled, locale: locale)
        case .unverified:
            if neverStarted {
                Strings.workspaceStateNotStartedText(locale: locale)
            } else {
                Strings.agentResult(.unverifiedTitle, locale: locale)
            }
        }
    }

    /// Shape carries the state as well as color, so the rows stay readable
    /// without color and under Increase Contrast.
    var symbol: String {
        switch self {
        case .needsDecision: "questionmark.circle.fill"
        case .ready: "checkmark.circle.fill"
        case .running: "circle.fill"
        case .failed: "xmark.circle.fill"
        case .cancelled: "minus.circle.fill"
        case .unverified: "circle.dashed"
        }
    }
}
