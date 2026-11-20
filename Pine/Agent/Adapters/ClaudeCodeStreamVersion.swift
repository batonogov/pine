import Foundation

nonisolated enum ClaudeCodeStreamError: Error, Equatable, Sendable {
    case invalidVersion
    case invalidEnvelope
    case unsupportedTokenSource(String)
}

/// Validated Claude Code CLI version. Parsing is strict; a version that does
/// not fit is unavailable data, never a guess.
nonisolated struct ClaudeCodeCLIVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    fileprivate init(exact major: Int, _ minor: Int, _ patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    init(_ major: Int, _ minor: Int, _ patch: Int) throws {
        guard (0...65_535).contains(major), (0...65_535).contains(minor), (0...65_535).contains(patch) else {
            throw ClaudeCodeStreamError.invalidVersion
        }
        self.init(exact: major, minor, patch)
    }

    init(_ raw: String) throws {
        let parts = raw.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts.allSatisfy({ part in !part.isEmpty && part.allSatisfy(\.isASCII) && part.allSatisfy(\.isNumber) })
        else {
            throw ClaudeCodeStreamError.invalidVersion
        }
        guard let major = Int(parts[0]), let minor = Int(parts[1]), let patch = Int(parts[2]) else {
            throw ClaudeCodeStreamError.invalidVersion
        }
        try self.init(major, minor, patch)
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    var description: String { "\(major).\(minor).\(patch)" }
}

/// Feature-specific version floors for the Pine-owned stream-json/control
/// slice. The floor table records the documented minimum for each recovery or
/// cancellation capability Pine may rely on; it is not a compatibility claim
/// for versions Pine has not exercised.
nonisolated enum ClaudeCodeStreamFeature: String, CaseIterable, Sendable {
    /// `system/init` carries the open `capabilities` array.
    case capabilitiesField
    /// `interrupt` control request resolves with a pending-queue receipt.
    case interruptReceipt
    /// `interrupt` honors `cancel_queued`, cancelling queued user messages.
    case interruptCancelQueued
    /// `--system-prompt-snapshot off` rebuilds prompts instead of reusing the
    /// recorded first-request snapshot.
    case systemPromptSnapshotOff
    /// `--permission-prompts host|none` selects the permission answerer.
    case permissionPrompts
    /// A successful `initialize` response carries `pending_permission_requests`;
    /// a missing field means an older CLI, not "no pending requests".
    case pendingPermissionRequests
    /// `initialize` response carries `claude_code_version`.
    case claudeCodeVersionField

    /// Documented minimum CLI version for this feature.
    var minimumVersion: ClaudeCodeCLIVersion {
        switch self {
        case .capabilitiesField, .interruptReceipt: ClaudeCodeCLIVersion(exact: 2, 1, 205)
        case .interruptCancelQueued: ClaudeCodeCLIVersion(exact: 2, 1, 219)
        case .systemPromptSnapshotOff: ClaudeCodeCLIVersion(exact: 2, 1, 257)
        case .permissionPrompts: ClaudeCodeCLIVersion(exact: 2, 1, 259)
        case .pendingPermissionRequests: ClaudeCodeCLIVersion(exact: 2, 1, 268)
        case .claudeCodeVersionField: ClaudeCodeCLIVersion(exact: 2, 1, 296)
        }
    }

    /// Observed capability name from `system/init`/`initialize`, when the
    /// feature is advertised by name. Presence in the observed array is the
    /// preferred signal; the version floor applies when the array is absent.
    var capabilityName: String? {
        switch self {
        case .interruptReceipt: "interrupt_receipt_v1"
        case .interruptCancelQueued: "interrupt_cancel_queued_v1"
        case .capabilitiesField, .systemPromptSnapshotOff, .permissionPrompts,
             .pendingPermissionRequests, .claudeCodeVersionField: nil
        }
    }
}

nonisolated enum ClaudeCodeStreamFeatureAvailability: Equatable, Sendable {
    case available
    case unavailable
    /// The CLI neither advertises the capability nor reports a parseable
    /// version. Absence of evidence is never treated as absence of state.
    case unknown
}

/// Feature detection prefers the observed `capabilities` array (documented
/// open set; unrecognized values are ignored) and falls back to the recorded
/// version floor. A missing `capabilities` field with no usable version is
/// `unknown`, not `unavailable`.
nonisolated enum ClaudeCodeStreamFeatureDetection {
    static func availability(
        of feature: ClaudeCodeStreamFeature,
        reportedVersion: String?,
        observedCapabilities: [String]?
    ) -> ClaudeCodeStreamFeatureAvailability {
        if let capabilities = observedCapabilities {
            guard let name = feature.capabilityName else {
                // The field exists, so the CLI is at the capabilitiesField
                // floor; a version-only feature is available from its floor.
                return versionAvailability(of: feature, reportedVersion)
            }
            return capabilities.contains(name) ? .available : .unavailable
        }
        return versionAvailability(of: feature, reportedVersion)
    }

    private static func versionAvailability(
        of feature: ClaudeCodeStreamFeature,
        _ reportedVersion: String?
    ) -> ClaudeCodeStreamFeatureAvailability {
        guard let raw = reportedVersion, let version = try? ClaudeCodeCLIVersion(raw) else {
            return .unknown
        }
        return version >= feature.minimumVersion ? .available : .unavailable
    }
}

/// The pinned executable identity for the first owned stream-json/control
/// slice. `verified` records the machine-observed version the floors below
/// were exercised against; it is not an upper bound.
nonisolated enum ClaudeCodeStreamPins {
    static let verified = ClaudeCodeCLIVersion(exact: 2, 1, 311)
    /// Minimum CLI for the enabled recovery/cancellation feature set:
    /// pending-request recovery, interrupt receipts, and version evidence.
    static var structuredSliceMinimum: ClaudeCodeCLIVersion {
        let floors = [
            ClaudeCodeStreamFeature.pendingPermissionRequests,
            .interruptReceipt,
            .claudeCodeVersionField,
        ].map(\.minimumVersion)
        var maximum = floors[0]
        for floor in floors.dropFirst() where floor > maximum {
            maximum = floor
        }
        return maximum
    }

    static func supportsStructuredSlice(_ version: ClaudeCodeCLIVersion) -> Bool {
        version >= structuredSliceMinimum && version <= verified
    }
}

/// Account observation from the `initialize` response. This is separate from
/// owned-pipe transport authentication and proves nothing about the next
/// provider call. No account ID, e-mail, token, or plan detail is retained.
nonisolated struct ClaudeCodeStreamAccountState: Equatable, Sendable {
    enum TokenSource: Equatable, Sendable {
        case none
        case apiKey
        case oauth
        case apiKeyHelper
        case thirdParty
        case unknown(String)

        init?(tokenSource: String?) {
            switch tokenSource {
            case nil, "none": self = .none
            case "api_key", "apiKey": self = .apiKey
            case "oauth", "oauth_token", "claude.ai": self = .oauth
            case "api_key_helper": self = .apiKeyHelper
            case "third_party": self = .thirdParty
            case let value?:
                guard value.utf8.count <= 64,
                      value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
                    return nil
                }
                self = .unknown(value)
            }
        }
    }

    enum Provider: Equatable, Sendable {
        case firstParty
        case bedrock
        case vertex
        case foundry
        case unknown(String)

        init?(apiProvider: String?) {
            switch apiProvider {
            case nil, "firstParty": self = .firstParty
            case "bedrock": self = .bedrock
            case "vertex": self = .vertex
            case "foundry": self = .foundry
            case let value?:
                guard value.utf8.count <= 64,
                      value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
                    return nil
                }
                self = .unknown(value)
            }
        }
    }

    let tokenSource: TokenSource
    let provider: Provider

    /// Nil when the `account` field is absent or unparseable; absence is an
    /// observation gap, not "no credentials".
    static func observe(_ account: AgentEventJSON?) -> ClaudeCodeStreamAccountState? {
        guard case .object(let fields) = account,
              case .string(let token) = fields["tokenSource"] ?? .null,
              let tokenSource = TokenSource(tokenSource: token),
              let providerRaw = fields["apiProvider"], case .string(let provider) = providerRaw,
              let providerValue = Provider(apiProvider: provider) else {
            return nil
        }
        return ClaudeCodeStreamAccountState(tokenSource: tokenSource, provider: providerValue)
    }
}
