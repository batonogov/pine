import Foundation

nonisolated enum FirstPartyAgentSupportTier: Int, Comparable, Sendable {
    case generic = 1
    case detected = 2
    case attentionAware = 3
    case structured = 4

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

nonisolated enum FirstPartyAgentEventSource: String, Sendable {
    case processSnapshot
    case documentedStructuredInterface
}

nonisolated enum FirstPartyAgentTrustLevel: String, Sendable {
    case observedProcessGeneration
    case authenticatedAdapter
}

nonisolated enum FirstPartyAgentLaunchCapability: String, Sendable {
    case manualTerminal
    case directArgumentVector
}

nonisolated enum FirstPartyAgentResumeCapability: String, Sendable {
    case newSessionOnly
    case documentedOpaqueSessionID
}

nonisolated enum FirstPartyAgentNotificationAccuracy: String, Codable, Sendable {
    case processTerminationOnly
    case verifiedLifecycleTransitions

    /// Whether evidence at this accuracy may drive user-facing lifecycle
    /// claims such as "Waiting for input". Process observation proves only
    /// presence and termination; CPU inactivity is not a prompt signal.
    var permitsUserFacingLifecycleTransitions: Bool {
        self == .verifiedLifecycleTransitions
    }
}

/// The single fail-closed accuracy policy shared by detection, durable tasks,
/// presentation, and notification delivery. Production resolves declarations
/// from the compatibility catalog; tests may inject a future verified catalog
/// without weakening current first-party records.
nonisolated struct AgentLifecycleAccuracyPolicy: Sendable {
    private let declaredAccuracy: @Sendable (
        String
    ) -> FirstPartyAgentNotificationAccuracy

    static let production = AgentLifecycleAccuracyPolicy { identifier in
        FirstPartyAgentCompatibilityCatalog.record(
            stableIdentifier: identifier
        )?.notificationAccuracy ?? .processTerminationOnly
    }

    init(
        declaredAccuracy: @escaping @Sendable (
            String
        ) -> FirstPartyAgentNotificationAccuracy
    ) {
        self.declaredAccuracy = declaredAccuracy
    }

    func accuracy(
        for stableIdentifier: String
    ) -> FirstPartyAgentNotificationAccuracy {
        declaredAccuracy(stableIdentifier)
    }

    func boundedAccuracy(
        for stableIdentifier: String,
        evidence: FirstPartyAgentNotificationAccuracy
    ) -> FirstPartyAgentNotificationAccuracy {
        Self.boundedAccuracy(
            declared: accuracy(for: stableIdentifier),
            evidence: evidence
        )
    }

    func permitsUserFacingAttention(
        for stableIdentifier: String,
        evidence: FirstPartyAgentNotificationAccuracy
    ) -> Bool {
        boundedAccuracy(
            for: stableIdentifier,
            evidence: evidence
        ).permitsUserFacingLifecycleTransitions
    }

    /// Bounds per-run evidence by the compatibility claim. Both the adapter
    /// declaration and the concrete transition must be verified; either side
    /// being process-only makes the result process-only.
    static func boundedAccuracy(
        declared: FirstPartyAgentNotificationAccuracy,
        evidence: FirstPartyAgentNotificationAccuracy
    ) -> FirstPartyAgentNotificationAccuracy {
        guard declared.permitsUserFacingLifecycleTransitions,
              evidence.permitsUserFacingLifecycleTransitions else {
            return .processTerminationOnly
        }
        return .verifiedLifecycleTransitions
    }
}

/// The checked-in, security-conservative compatibility claim for one agent.
///
/// A record is intentionally data-only. It cannot grant adapter capabilities:
/// those remain negotiated by `AgentAdapterRegistry`. Process observation is
/// therefore represented at the detected tier and never upgraded from timing
/// or terminal presentation heuristics.
nonisolated struct FirstPartyAgentCompatibilityRecord: Sendable {
    let schemaVersion: UInt16
    let stableIdentifier: String
    let displayName: String
    let executableAliases: Set<String>
    let upstreamURL: String
    let testedVersions: [String]
    let supportTier: FirstPartyAgentSupportTier
    let eventSource: FirstPartyAgentEventSource
    let trustLevel: FirstPartyAgentTrustLevel
    let launchCapability: FirstPartyAgentLaunchCapability
    let resumeCapability: FirstPartyAgentResumeCapability
    let notificationAccuracy: FirstPartyAgentNotificationAccuracy
    let limitations: String
}

nonisolated enum FirstPartyAgentCompatibilityCatalog {
    static let schemaVersion: UInt16 = 1

    static let records: [FirstPartyAgentCompatibilityRecord] = [
        record(
            id: "pi",
            name: "Pi",
            aliases: ["pi"],
            upstream: "https://github.com/badlogic/pi-mono",
            versions: ["0.83.0"]
        ),
        record(
            id: "codex",
            name: "Codex",
            aliases: ["codex"],
            upstream: "https://github.com/openai/codex",
            versions: ["0.146.0"]
        ),
        record(
            id: "claudeCode",
            name: "Claude Code",
            aliases: ["claude"],
            upstream: "https://github.com/anthropics/claude-code",
            versions: ["2.1.220"]
        ),
        record(
            id: "openCode",
            name: "OpenCode",
            aliases: ["opencode"],
            upstream: "https://github.com/anomalyco/opencode",
            versions: ["1.18.10"]
        ),
        record(
            id: "copilot",
            name: "GitHub Copilot CLI",
            aliases: ["github-copilot-cli", "copilot"],
            upstream: "https://github.com/github/copilot-cli",
            versions: ["1.0.77"]
        ),
        record(
            id: "aider",
            name: "Aider",
            aliases: ["aider"],
            upstream: "https://github.com/Aider-AI/aider",
            versions: ["0.86.0"]
        ),
        record(
            id: "gemini",
            name: "Gemini CLI",
            aliases: ["gemini"],
            upstream: "https://github.com/google-gemini/gemini-cli",
            versions: ["0.53.1"]
        ),
        reviewedRecord(
            id: "amp",
            name: "Amp",
            aliases: ["amp"],
            source: ("https://ampcode.com/manual", ["0.0.1785747753-g51f676"]),
            interface: "--execute --stream-json / --stream-json-input"
        ),
        reviewedRecord(
            id: "cursorAgent",
            name: "Cursor Agent",
            aliases: ["cursor-agent"],
            source: ("https://docs.cursor.com/en/cli/overview", ["2026.07.23-e383d2b"]),
            interface: "--print --output-format json|stream-json"
        ),
        reviewedRecord(
            id: "goose",
            name: "Goose",
            aliases: ["goose"],
            source: ("https://github.com/aaif-goose/goose", ["1.45.0"]),
            interface: "ACP over stdio"
        ),
        reviewedRecord(
            id: "qwenCode",
            name: "Qwen Code",
            aliases: ["qwen"],
            source: ("https://github.com/QwenLM/qwen-code", ["0.21.4"]),
            interface: "--output-format json|stream-json"
        ),
        reviewedRecord(
            id: "crush",
            name: "Crush",
            aliases: ["crush"],
            source: ("https://github.com/charmbracelet/crush", ["0.88.0"]),
            interface: "experimental workspace SSE"
        ),
    ]

    static func record(stableIdentifier: String) -> FirstPartyAgentCompatibilityRecord? {
        records.first { $0.stableIdentifier == stableIdentifier }
    }

    static func record(executableAlias: String) -> FirstPartyAgentCompatibilityRecord? {
        records.first { $0.executableAliases.contains(executableAlias.lowercased()) }
    }

    private static func record(
        id: String,
        name: String,
        aliases: Set<String>,
        upstream: String,
        versions: [String]
    ) -> FirstPartyAgentCompatibilityRecord {
        FirstPartyAgentCompatibilityRecord(
            schemaVersion: schemaVersion,
            stableIdentifier: id,
            displayName: name,
            executableAliases: aliases,
            upstreamURL: upstream,
            testedVersions: versions,
            supportTier: .detected,
            eventSource: .processSnapshot,
            trustLevel: .observedProcessGeneration,
            launchCapability: .manualTerminal,
            resumeCapability: .newSessionOnly,
            notificationAccuracy: .processTerminationOnly,
            limitations: "No documented structured event channel is enabled; attention and completion remain unverified."
        )
    }

    private static func reviewedRecord(
        id: String,
        name: String,
        aliases: Set<String>,
        source: (upstream: String, versions: [String]),
        interface: String
    ) -> FirstPartyAgentCompatibilityRecord {
        FirstPartyAgentCompatibilityRecord(
            schemaVersion: schemaVersion,
            stableIdentifier: id,
            displayName: name,
            executableAliases: aliases,
            upstreamURL: source.upstream,
            testedVersions: source.versions,
            supportTier: .detected,
            eventSource: .processSnapshot,
            trustLevel: .observedProcessGeneration,
            launchCapability: .manualTerminal,
            resumeCapability: .newSessionOnly,
            notificationAccuracy: .processTerminationOnly,
            limitations: "Reviewed \(interface) is not enabled until Pine can authenticate and bind "
                + "its transport; malformed, reordered, oversized, future-schema, and ambient events fail closed."
        )
    }
}
