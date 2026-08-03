//
//  AgentCompletionBrief.swift
//  Pine
//
//  Evidence-first completion summaries for finished agent work (#1308).
//

import Foundation

/// Attribution shown beside every completion-brief fact.
///
/// The cases are deliberately not ordered. In particular, several inferred
/// observations never combine into a verified claim.
nonisolated enum AgentCompletionEvidenceLevel: String, Sendable, Equatable {
    case verified
    case inferred
    case ambiguous
    case observed
    case agentReported
}

nonisolated enum AgentCompletionChangeKind: String, Sendable, Equatable {
    case modified
    case created
    case deleted
    case renamed
    case unknown
}

nonisolated struct AgentCompletionDiffStatistics: Sendable, Equatable {
    let addedLineCount: Int
    let removedLineCount: Int
}

nonisolated struct AgentCompletionChange: Identifiable, Sendable, Equatable {
    var id: String { relativePath }

    let relativePath: String
    let kind: AgentCompletionChangeKind
    let statistics: AgentCompletionDiffStatistics?
    let attribution: AgentCompletionEvidenceLevel
    let hasOverlappingEdits: Bool
    let hasVerifiedDiff: Bool
}

nonisolated enum AgentCompletionCommandKind: String, Sendable, Equatable {
    case command
    case build
    case test
}

nonisolated enum AgentCompletionCommandOutcome: Sendable, Equatable {
    case succeeded
    case failed(exitStatus: Int32)
    case unknown
}

nonisolated struct AgentCompletionCommand: Identifiable, Sendable, Equatable {
    let id: UUID
    let command: String
    let kind: AgentCompletionCommandKind
    let outcome: AgentCompletionCommandOutcome
    let attribution: AgentCompletionEvidenceLevel
    let source: String
}

nonisolated enum AgentCompletionGap: Sendable, Equatable {
    case provenanceUnavailable
    case provenanceRecoveredWithLoss
    case noVerifiedChanges
    case noStructuredCommands
    case noVerifiedTests
    case diffStatisticsUnavailable(paths: [String])
    case overlappingEdits(paths: [String])
}

nonisolated struct AgentCompletionNarrative: Sendable, Equatable {
    let text: String
    let attribution: AgentCompletionEvidenceLevel

    init(text: String) {
        self.text = text
        attribution = .agentReported
    }
}

/// Read-only links. Their targets are resolved again by the presentation
/// layer; neither value grants terminal access or mutation authority.
nonisolated struct AgentCompletionEvidenceLinks: Sendable, Equatable {
    let terminalID: UUID?
    let diffPaths: [String]
}

nonisolated struct AgentCompletionBrief: Sendable, Equatable, Identifiable {
    let id: UUID
    let sessionID: UUID
    let agentTypeRaw: String
    let startedAt: Date
    let endedAt: Date?
    let changes: [AgentCompletionChange]
    let commands: [AgentCompletionCommand]
    let gaps: [AgentCompletionGap]
    let narrative: AgentCompletionNarrative?
    let links: AgentCompletionEvidenceLinks

    var verifiedTestCount: Int {
        commands.lazy.filter {
            $0.kind == .test
                && $0.attribution == .verified
                && $0.outcome == .succeeded
        }.count
    }
}

/// Bounded inputs used by the pure builder. Integrity travels together with
/// the provenance rows so a recovered or unavailable journal cannot be
/// presented as complete evidence.
@MainActor
struct AgentCompletionBriefEvidence: Equatable {
    let provenanceIntegrity: AgentEventStoreIntegrity?
    let events: [StoredAgentEvent]
    let activities: [AgentAction]
    let verifiedUndoPreview: AgentHistoryUndoPreviewModel?
    let agentReportedNarrative: String?
    let overlappingPaths: Set<String>

    init(
        provenanceIntegrity: AgentEventStoreIntegrity? = nil,
        events: [StoredAgentEvent] = [],
        activities: [AgentAction] = [],
        verifiedUndoPreview: AgentHistoryUndoPreviewModel? = nil,
        agentReportedNarrative: String? = nil,
        overlappingPaths: Set<String> = []
    ) {
        self.provenanceIntegrity = provenanceIntegrity
        self.events = events
        self.activities = activities
        self.verifiedUndoPreview = verifiedUndoPreview
        self.agentReportedNarrative = agentReportedNarrative
        self.overlappingPaths = overlappingPaths
    }
}

@MainActor
enum AgentCompletionBriefBuilder {
    private static let maximumEventCount = 10_000
    private static let maximumActivityCount = 10_000
    private static let maximumNarrativeBytes = 64 * 1_024

    static func build(
        entry: AgentHistoryEntry,
        evidence: AgentCompletionBriefEvidence
    ) -> AgentCompletionBrief {
        let events = Array(evidence.events.lazy
            .filter { $0.envelope.sessionID == entry.sessionID }
            .prefix(maximumEventCount))
        let activities = Array(evidence.activities.lazy
            .filter { $0.attribution.contains(sessionID: entry.sessionID) }
            .prefix(maximumActivityCount))
        var previewByPath: [String: AgentHistoryUndoPreviewOperation] = [:]
        for operation in evidence.verifiedUndoPreview?.operations ?? []
        where previewByPath[operation.relativePath] == nil {
            previewByPath[operation.relativePath] = operation
        }
        let verifiedKinds = verifiedChangeKinds(entry.verifiedChangeSet)
        let eventPaths = events.compactMap { record -> String? in
            guard case .fileChange(let change) = record.envelope.payload else {
                return nil
            }
            return change.relativePath
        }
        var activityPathsByID: [UUID: String] = [:]
        for action in activities where activityPathsByID[action.id] == nil {
            activityPathsByID[action.id] = action.fileURL.flatMap {
                relativePath(for: $0, entry: entry, events: events)
            }
        }
        let activityPaths = activities.compactMap { activityPathsByID[$0.id] }
        let allPaths = stableUnique(
            entry.affectedFiles
                + verifiedKinds.keys
                + eventPaths
                + activityPaths
        )
        let overlapPaths = overlappingPaths(
            explicit: evidence.overlappingPaths,
            activities: activities,
            pathsByActivityID: activityPathsByID
        )

        let changes = allPaths.map { path in
            let preview = previewByPath[path]
            return AgentCompletionChange(
                relativePath: path,
                kind: verifiedKinds[path] ?? changeKind(from: preview),
                statistics: preview.map { operation in
                    // The preview is an inverse. Lines removed by the inverse
                    // were added by the agent, and vice versa.
                    AgentCompletionDiffStatistics(
                        addedLineCount: operation.removedLineCount,
                        removedLineCount: operation.addedLineCount
                    )
                },
                attribution: attribution(
                    path: path,
                    entry: entry,
                    events: events,
                    activities: activities,
                    pathsByActivityID: activityPathsByID
                ),
                hasOverlappingEdits: overlapPaths.contains(path),
                hasVerifiedDiff: preview != nil
            )
        }

        let commands = structuredCommands(events)
            + observedCommands(activities, excluding: events)
        var gaps = integrityGaps(evidence.provenanceIntegrity)
        if !changes.contains(where: { $0.attribution == .verified }) {
            gaps.append(.noVerifiedChanges)
        }
        if !commands.contains(where: { $0.attribution == .verified }) {
            gaps.append(.noStructuredCommands)
        }
        if !commands.contains(where: {
            $0.kind == .test && $0.attribution == .verified
        }) {
            gaps.append(.noVerifiedTests)
        }
        let pathsWithoutStats = changes.compactMap {
            $0.statistics == nil ? $0.relativePath : nil
        }
        if !pathsWithoutStats.isEmpty {
            gaps.append(.diffStatisticsUnavailable(paths: pathsWithoutStats))
        }
        let orderedOverlapPaths = allPaths.filter(overlapPaths.contains)
        if !orderedOverlapPaths.isEmpty {
            gaps.append(.overlappingEdits(paths: orderedOverlapPaths))
        }

        let narrative = boundedNarrative(evidence.agentReportedNarrative)
            .map(AgentCompletionNarrative.init)
        let terminalID = events.first?.envelope.process.terminalID

        return AgentCompletionBrief(
            id: entry.id,
            sessionID: entry.sessionID,
            agentTypeRaw: entry.agentTypeRaw,
            startedAt: entry.startedAt,
            endedAt: entry.endedAt,
            changes: changes,
            commands: commands,
            gaps: gaps,
            narrative: narrative,
            links: AgentCompletionEvidenceLinks(
                terminalID: terminalID,
                diffPaths: changes.filter(\.hasVerifiedDiff).map(\.relativePath)
            )
        )
    }

    private static func verifiedChangeKinds(
        _ changeSet: VerifiedAgentChangeSet?
    ) -> [String: AgentCompletionChangeKind] {
        guard let changeSet else { return [:] }
        var result: [String: AgentCompletionChangeKind] = [:]
        for change in changeSet.changes {
            let kind: AgentCompletionChangeKind = switch change.operation {
            case .modify: .modified
            case .create: .created
            case .delete: .deleted
            case .rename: .renamed
            case .symlink, .unsupported: .unknown
            }
            if result[change.relativePath] == nil {
                result[change.relativePath] = kind
            }
        }
        return result
    }

    private static func changeKind(
        from preview: AgentHistoryUndoPreviewOperation?
    ) -> AgentCompletionChangeKind {
        guard let preview else { return .unknown }
        return switch preview.kind {
        case .restoreModifiedFile: .modified
        case .removeCreatedFile: .created
        case .restoreDeletedFile: .deleted
        }
    }

    private static func attribution(
        path: String,
        entry: AgentHistoryEntry,
        events: [StoredAgentEvent],
        activities: [AgentAction],
        pathsByActivityID: [UUID: String]
    ) -> AgentCompletionEvidenceLevel {
        if entry.attribution == .verified,
           entry.verifiedChangeSet?.changes.contains(where: {
               $0.relativePath == path
           }) == true {
            return .verified
        }
        let pathEvents = events.filter { record in
            guard case .fileChange(let change) = record.envelope.payload else {
                return false
            }
            return change.relativePath == path
        }
        if pathEvents.contains(where: {
            $0.envelope.source == .explicitAgentEvent
                && $0.envelope.trustLevel == .verified
        }) {
            return .verified
        }
        let pathActions = activities.filter {
            pathsByActivityID[$0.id] == path
        }
        if pathActions.contains(where: {
            if case .ambiguous = $0.attribution { return true }
            return false
        }) {
            return .ambiguous
        }
        if !pathActions.isEmpty || entry.affectedFiles.contains(path) {
            return .inferred
        }
        return .observed
    }

    private static func structuredCommands(
        _ events: [StoredAgentEvent]
    ) -> [AgentCompletionCommand] {
        events.compactMap { record in
            guard case .commandResult(let result) = record.envelope.payload else {
                return nil
            }
            let isVerified = record.envelope.source == .explicitAgentEvent
                && record.envelope.trustLevel == .verified
            return AgentCompletionCommand(
                id: record.envelope.id,
                command: result.command,
                kind: commandKind(result.command),
                outcome: result.exitStatus == 0
                    ? .succeeded
                    : .failed(exitStatus: result.exitStatus),
                attribution: isVerified ? .verified : .inferred,
                source: record.envelope.source.stableIdentifier
            )
        }
    }

    private static func observedCommands(
        _ activities: [AgentAction],
        excluding events: [StoredAgentEvent]
    ) -> [AgentCompletionCommand] {
        let structuredCommands = Set(events.compactMap { record -> String? in
            guard case .commandResult(let result) = record.envelope.payload else {
                return nil
            }
            return result.command
        })
        return activities.compactMap { action in
            guard action.kind == .command,
                  !structuredCommands.contains(action.summary) else {
                return nil
            }
            return AgentCompletionCommand(
                id: action.id,
                command: action.summary,
                kind: commandKind(action.summary),
                outcome: .unknown,
                attribution: activityEvidence(action.attribution),
                source: "activity"
            )
        }
    }

    private static func activityEvidence(
        _ attribution: AgentActionAttribution
    ) -> AgentCompletionEvidenceLevel {
        switch attribution {
        case .verified: .verified
        case .inferred, .session: .inferred
        case .ambiguous: .ambiguous
        }
    }

    private static func commandKind(
        _ command: String
    ) -> AgentCompletionCommandKind {
        let normalized = command.lowercased()
        let testMarkers = [
            "xcodebuild test", "swift test", "npm test", "npm run test",
            "pnpm test", "yarn test", "cargo test", "go test", "pytest"
        ]
        if testMarkers.contains(where: normalized.contains) {
            return .test
        }
        let buildMarkers = [
            "xcodebuild build", "swift build", "npm run build",
            "pnpm build", "yarn build", "cargo build", "go build"
        ]
        if buildMarkers.contains(where: normalized.contains) {
            return .build
        }
        return .command
    }

    private static func integrityGaps(
        _ integrity: AgentEventStoreIntegrity?
    ) -> [AgentCompletionGap] {
        switch integrity {
        case .healthy: []
        case .recovered: [.provenanceRecoveredWithLoss]
        case .unavailable, nil: [.provenanceUnavailable]
        }
    }

    private static func overlappingPaths(
        explicit: Set<String>,
        activities: [AgentAction],
        pathsByActivityID: [UUID: String]
    ) -> Set<String> {
        var result = explicit
        for action in activities {
            guard case .ambiguous = action.attribution,
                  let path = pathsByActivityID[action.id] else { continue }
            result.insert(path)
        }
        return result
    }

    private static func relativePath(
        for fileURL: URL,
        entry: AgentHistoryEntry,
        events: [StoredAgentEvent]
    ) -> String? {
        if let root = events.first?.envelope.location.worktreePath {
            let path = fileURL.standardizedFileURL.path
            let prefix = root.hasSuffix("/") ? root : root + "/"
            if path.hasPrefix(prefix) {
                return String(path.dropFirst(prefix.count))
            }
        }
        return entry.affectedFiles.first {
            URL(fileURLWithPath: $0).lastPathComponent
                == fileURL.lastPathComponent
        }
    }

    private static func stableUnique(_ paths: [String]) -> [String] {
        var seen: Set<String> = []
        return paths.filter { path in
            AgentHistoryUndoPreflight.isCanonicalRelativePath(path)
                && seen.insert(path).inserted
        }
    }

    private static func boundedNarrative(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.utf8.count <= maximumNarrativeBytes,
              !trimmed.utf8.contains(0) else {
            return nil
        }
        return trimmed
    }
}
