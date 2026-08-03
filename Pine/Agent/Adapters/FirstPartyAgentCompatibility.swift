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

nonisolated enum FirstPartyAgentNotificationAccuracy: String, Sendable {
    case processTerminationOnly
    case verifiedLifecycleTransitions
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
}
