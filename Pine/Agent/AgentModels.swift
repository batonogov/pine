//
//  AgentModels.swift
//  Pine
//
//  Foundation data models for AI agent tracking (vision #933, Phase 1 — Awareness).
//  Pure models: no detection logic, no UI. Consumed by AgentDetector (#950),
//  terminal tab badges (#951), and the status bar agent summary (#952).
//

import AppKit
import Foundation

/// Identifies a known AI coding agent CLI tool.
///
/// `cliNames` is the set of process/command names an `AgentDetector` matches
/// against (e.g. from `ps` output or terminal prompts). `color` drives UI
/// color-coding for agent badges and indicators.
enum AgentType: Equatable, Sendable {
    /// Anthropic Claude Code (`claude`).
    case claudeCode
    /// OpenAI Codex CLI (`codex`).
    case codex
    /// Aider (`aider`).
    case aider
    /// GitHub Copilot CLI (`github-copilot-cli`).
    case copilot
    /// pi coding agent (`pi`).
    case pi
    /// Any other/unrecognised agent, identified by a free-form name.
    case generic(name: String)

    /// Human-readable name for display (status bar, badges).
    var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .aider: "Aider"
        case .copilot: "Copilot"
        case .pi: "Pi"
        case .generic(let name): name
        }
    }

    /// Process/command names an `AgentDetector` matches against for this agent.
    /// Lowercased to allow case-insensitive matching.
    var cliNames: Set<String> {
        switch self {
        case .claudeCode: ["claude"]
        case .codex: ["codex"]
        case .aider: ["aider"]
        case .copilot: ["github-copilot-cli", "copilot"]
        case .pi: ["pi"]
        case .generic: []
        }
    }

    /// Semantic system color used for UI color-coding of this agent.
    var color: NSColor {
        switch self {
        case .claudeCode: .systemOrange
        case .codex: .systemGreen
        case .aider: .systemPurple
        case .copilot: .systemBlue
        case .pi: .systemTeal
        case .generic: .systemGray
        }
    }

    /// Resolves an `AgentType` from a process/command name (case-insensitive).
    /// Returns the first known agent whose `cliNames` contains the name, or
    /// `.generic(name:)` for an unrecognised name. An empty name resolves to
    /// `nil`.
    static func resolve(fromProcessName name: String) -> AgentType? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lowered = trimmed.lowercased()

        let known: [AgentType] = [.claudeCode, .codex, .aider, .copilot, .pi]
        for agent in known where agent.cliNames.contains(lowered) {
            return agent
        }
        return .generic(name: trimmed)
    }
}

/// Liveness of an agent session — whether the backing terminal process
/// is still observed, its evidence is stale, or it has terminated (vision
/// #933, Phase 4 — Multi-agent UX).
///
/// `AgentState` tracks the agent's *logical* lifecycle (idle/thinking/…);
/// `AgentLiveness` describes the freshness of Pine's process evidence. It
/// deliberately does not claim that a process is responsive: a successful
/// `ps` observation can prove presence, not application-level health.
nonisolated enum AgentLiveness: Sendable, Equatable {
    /// The backing process was present in a recent successful observation.
    case live
    /// Pine has not completed a successful process observation recently.
    /// The process may still exist; the UI must present this as uncertainty.
    case stale
    /// A successful process observation established that the process ended.
    case terminated

    /// Localized label for badges and accessibility.
    @MainActor
    var displayName: String {
        switch self {
        case .live: Strings.agentLivenessLive
        case .stale: Strings.agentLivenessStale
        case .terminated: Strings.agentLivenessTerminated
        }
    }

    /// SF Symbol name for the evidence indicator, or `nil` while live.
    var glyphName: String? {
        switch self {
        case .live: nil
        case .stale: "clock"
        case .terminated: "xmark"
        }
    }

    /// `true` when current process presence is no longer established.
    var isStale: Bool {
        self == .stale || self == .terminated
    }
}

/// Lifecycle state of an agent session within a terminal tab.
enum AgentState: Equatable, Sendable {
    case idle
    case thinking
    case executing
    case waitingInput
    case done

    /// Human-readable label for display (status bar, activity indicators).
    var displayName: String {
        switch self {
        case .idle: "Idle"
        case .thinking: "Thinking"
        case .executing: "Executing"
        case .waitingInput: "Waiting for input"
        case .done: "Done"
        }
    }

    /// `true` when the agent is doing work — thinking or executing a tool.
    /// Drives the pulsing animation on terminal-tab badges (#1048).
    var isActive: Bool {
        self == .thinking || self == .executing
    }

    /// `true` when the agent is blocked waiting for the user — a permission
    /// prompt or a reply. Drives the global "needs attention" indicator and
    /// the amber per-tab glyph (#1112, cf. agterm's blocked status).
    var needsAttention: Bool {
        self == .waitingInput
    }

    /// SF Symbol name for per-tab / attention-list status glyphs, or `nil`
    /// when no glyph should be shown (idle). Active states share one ellipsis
    /// glyph (the per-agent color still distinguishes them via the dot);
    /// `waitingInput` is an amber exclamation, `done` a green check (#1112).
    var glyphName: String? {
        switch self {
        case .idle: nil
        case .thinking, .executing: "ellipsis"
        case .waitingInput: "exclamationmark"
        case .done: "checkmark"
        }
    }
}

/// Tracks a single AI agent session running within a terminal tab.
///
/// Identity semantics: an `AgentSession` represents one run of one agent in one
/// terminal tab. `id` is stable for the session lifetime; mutable properties
/// (`state`, `currentTask`, `filesModified`, `filesRead`) are updated by an
/// `AgentDetector` as the session progresses.
@MainActor @Observable
final class AgentSession: Identifiable {
    /// Stable identifier for this session.
    let id: UUID

    /// Which agent this session is running.
    let agentType: AgentType

    /// Current lifecycle state of the session.
    var state: AgentState

    /// Freshness of Pine's evidence for the backing process. This property is
    /// the single source of truth consumed by terminal and status-bar UI.
    /// Mutations are owned by `AgentSessionLivenessTracker`.
    private(set) var liveness: AgentLiveness

    /// Most recent successful process-list observation containing this
    /// session. Staleness is measured from this timestamp, never from
    /// `startedAt`.
    private(set) var lastObservedAt: Date

    /// When the session started.
    let startedAt: Date

    /// Optional human-readable description of the task the agent is working on.
    var currentTask: String?

    /// Files the agent has modified during this session.
    var filesModified: [URL]

    /// Files the agent has read during this session.
    var filesRead: [URL]

    init(
        id: UUID = UUID(),
        agentType: AgentType,
        state: AgentState = .idle,
        startedAt: Date = Date(),
        liveness: AgentLiveness = .live,
        lastObservedAt: Date? = nil,
        currentTask: String? = nil,
        filesModified: [URL] = [],
        filesRead: [URL] = []
    ) {
        self.id = id
        self.agentType = agentType
        self.state = state
        self.startedAt = startedAt
        self.liveness = liveness
        self.lastObservedAt = lastObservedAt ?? startedAt
        self.currentTask = currentTask
        self.filesModified = filesModified
        self.filesRead = filesRead
    }

    /// Records a successful observation. Kept internal to centralize mutable
    /// liveness state on the session while allowing the tracker to own policy.
    func recordObservation(at date: Date) {
        lastObservedAt = date
        liveness = .live
    }

    /// Applies a tracker assessment without exposing a public setter.
    func applyLiveness(_ value: AgentLiveness) {
        liveness = value
    }
}

extension AgentSession: Equatable {
    nonisolated static func == (lhs: AgentSession, rhs: AgentSession) -> Bool {
        lhs.id == rhs.id
    }
}

extension AgentSession: Hashable {
    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
