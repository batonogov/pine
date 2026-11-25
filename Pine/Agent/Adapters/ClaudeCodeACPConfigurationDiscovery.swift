import Foundation

/// Maps only observations made on the pinned
/// `@agentclientprotocol/claude-agent-acp` 0.109.1 ACP connection (#1765).
/// The adapter's session setup response carries `configOptions` built from
/// the reviewed v0.109.1 source: `model` (category `model`, present only
/// when the gateway lists models), `effort` (category `thought_level`,
/// present only when the current model supports effort levels), and `mode`
/// (category `mode`, "Session permission mode", always present). The
/// `agent`, `fast_mode`, and `ultracode` options are not Pine settings and
/// are never mapped.
///
/// The version floor is documented at the pin (source-reviewed 2026-11-23;
/// no real adapter handshake is claimed), so it stays researched until a
/// live session response promotes it to probed. Pine never calls
/// `session/set_config_option` in this slice, so no overridable scope is
/// claimed and no apply/readback cycle is advertised.
nonisolated enum ClaudeCodeACPConfigurationDiscovery {
    /// Launch-boundary observation the session can attribute: the validated
    /// executable (when the owner supplies it) and the environment provenance.
    struct Input: Sendable {
        let selectedExecutable: URL?
        let environmentProvenance: AgentTaskLaunchEnvironmentProvenance
    }

    /// Documented at the pinned 0.109.1, not observed by Pine before a live
    /// session: session setup `configOptions` for model/effort/mode.
    static func versionFloors() throws -> [AgentTaskConfigurationCapability] {
        [
            try AgentTaskConfigurationCapability(
                key: .model, state: .researched, overridableScopes: []
            ),
            try AgentTaskConfigurationCapability(
                key: .reasoningEffort, state: .researched, overridableScopes: []
            ),
            try AgentTaskConfigurationCapability(
                key: .permissions, state: .researched, overridableScopes: []
            ),
        ]
    }

    static func report(
        input: Input?,
        sessionConfigOptions: AgentEventJSON? = nil,
        sessionStarted: Bool = false
    ) throws -> AgentTaskDiscoveryReport {
        let capabilities = try configurationCapabilities(sessionConfigOptions: sessionConfigOptions)
        let effective = try effectiveSettings(sessionConfigOptions: sessionConfigOptions)
        let identity: AgentTaskDiscoveryReport.ExecutableIdentityObservation
        let version: AgentTaskDiscoveryReport.ExecutableVersionObservation
        let transport: AgentTaskDiscoveryReport.TransportObservation
        let hasExecutable: Bool
        if let input, let selectedExecutable = input.selectedExecutable {
            identity = .resolved(selectedExecutable)
            // initialize required the exact pinned adapter identity/version
            // before the session was created; this is a confirmed observation.
            version = .supported(try DetectedVendorVersion(ClaudeCodeACPSession.pinnedVersion))
            transport = .negotiated(
                transport: .ownedStandardIO, capabilities: try ClaudeCodeACPSession.profile()
            )
            hasExecutable = true
        } else {
            identity = .unknown
            version = .unknown
            transport = .unknown
            hasExecutable = false
        }
        // The adapter's auth/status_update pushes carry no Pine authentication
        // evidence, so authentication stays unknown. Without a resolved
        // executable the report cannot attribute effective values either.
        return try AgentTaskDiscoveryReport(
            contractVersion: AgentTaskExecutionContract.currentVersion,
            agentID: AgentID(migratingLegacyStableIdentifier: "claudeCode"),
            environmentProvenance: input?.environmentProvenance ?? .inheritedPineProcess,
            executableIdentity: identity,
            executableVersion: version,
            transport: transport,
            authentication: .unknown,
            // A started session cannot be claimed without an attributed
            // negotiated transport; unattributed reports stay .notAttempted.
            sessionStart: (sessionStarted && hasExecutable) ? .started : .notAttempted,
            configurationCapabilities: capabilities,
            effectiveModel: hasExecutable ? effective.model : .unknown,
            effectiveReasoningEffort: hasExecutable ? effective.reasoningEffort : .unknown,
            effectivePermissions: hasExecutable ? effective.permissions : .unknown
        )
    }

    static func configurationCapabilities(
        sessionConfigOptions: AgentEventJSON?
    ) throws -> AgentTaskConfigurationCapabilities {
        var advertised: [AgentTaskConfigurationCapability] = []
        var observed: Set<AgentTaskConfigurationSettingKey> = []
        for (key, option) in try mappedOptions(sessionConfigOptions: sessionConfigOptions) {
            guard !observed.contains(key) else { throw ClaudeCodeACPError.invalidProtocol }
            observed.insert(key)
            advertised.append(try AgentTaskConfigurationCapability(
                key: key,
                state: .probed,
                overridableScopes: [],
                enumeratedOptions: try option.options.map {
                    try AgentTaskConfigurationCapability.Option(
                        nativeValue: $0.value, title: $0.name, detail: $0.detail
                    )
                },
                // ACP `currentValue` is readback evidence only. No apply
                // cycle is claimed; Pine never calls set_config_option here.
                effectiveReadback: true
            ))
        }
        return try AgentTaskConfigurationCapabilities(
            transportAdvertised: advertised, versionFloor: try versionFloors()
        )
    }

    /// The effective values the observed option `currentValue`s confirm.
    static func effectiveSettings(
        sessionConfigOptions: AgentEventJSON?
    ) throws -> (
        model: AgentTaskEffectiveSettingObservation,
        reasoningEffort: AgentTaskEffectiveSettingObservation,
        permissions: AgentTaskEffectiveSettingObservation
    ) {
        var model: AgentTaskEffectiveSettingObservation = .unknown
        var effort: AgentTaskEffectiveSettingObservation = .unknown
        var permissions: AgentTaskEffectiveSettingObservation = .unknown
        for (key, option) in try mappedOptions(sessionConfigOptions: sessionConfigOptions) {
            switch key {
            case .model: model = .confirmed(option.currentValue)
            case .reasoningEffort: effort = .confirmed(option.currentValue)
            case .permissions: permissions = .confirmed(option.currentValue)
            }
        }
        return (model, effort, permissions)
    }

    // MARK: Option mapping

    struct MappedOption: Equatable, Sendable {
        struct Choice: Equatable, Sendable {
            let value: String
            let name: String
            let detail: String?
        }
        let currentValue: String
        let options: [Choice]
    }

    /// The pinned v0.109.1 option IDs with their semantic categories, from
    /// the reviewed adapter source. Both the ID and the category must match
    /// the documented pair; anything else degrades to the floor. The `mode`
    /// option is the session permission mode, never a primary agent.
    static func mappedOptions(
        sessionConfigOptions: AgentEventJSON?
    ) throws -> [(key: AgentTaskConfigurationSettingKey, option: MappedOption)] {
        guard let sessionConfigOptions, sessionConfigOptions != .null else { return [] }
        guard case .array(let options) = sessionConfigOptions else {
            throw ClaudeCodeACPError.invalidProtocol
        }
        guard options.count <= 32 else { throw ClaudeCodeACPError.capacity }
        var result: [(key: AgentTaskConfigurationSettingKey, option: MappedOption)] = []
        for value in options {
            let fields = try ClaudeCodeACPWire.object(value)
            let id = try boundedString(fields["id"])
            // `category` is optional on ACP config options; without it the
            // documented (id, category) pair cannot match, so the option is
            // never mapped.
            let category: String?
            if fields["category"] == nil {
                category = nil
            } else {
                category = try boundedString(fields["category"])
            }
            let key: AgentTaskConfigurationSettingKey
            switch (id, category) {
            case ("model", "model"): key = .model
            case ("effort", "thought_level"): key = .reasoningEffort
            case ("mode", "mode"): key = .permissions
            default: continue
            }
            let type = try boundedString(fields["type"])
            guard type == "select" else { continue }
            guard case .string(let currentValue) = fields["currentValue"] else { continue }
            let checked = try AdapterIdentifierValidation.displayText(currentValue)
            result.append((key, MappedOption(
                currentValue: checked,
                options: try nativeOptions(fields["options"])
            )))
        }
        return result
    }

    private static func nativeOptions(
        _ value: AgentEventJSON?
    ) throws -> [MappedOption.Choice] {
        guard case .array(let values) = value else { throw ClaudeCodeACPError.invalidProtocol }
        guard values.count <= 128 else { throw ClaudeCodeACPError.capacity }
        var result: [MappedOption.Choice] = []
        for value in values {
            let option = try ClaudeCodeACPWire.object(value)
            if option["group"] != nil {
                result.append(contentsOf: try groupedOptions(option["options"]))
                continue
            }
            let detail: String?
            if let description = option["description"], description != .null {
                detail = try boundedString(description)
            } else {
                detail = nil
            }
            result.append(MappedOption.Choice(
                value: try boundedString(option["value"]),
                name: try boundedString(option["name"]),
                detail: detail
            ))
            guard result.count <= 128 else { throw ClaudeCodeACPError.capacity }
        }
        return result
    }

    private static func groupedOptions(
        _ value: AgentEventJSON?
    ) throws -> [MappedOption.Choice] {
        guard case .array(let values) = value else { throw ClaudeCodeACPError.invalidProtocol }
        guard values.count <= 128 else { throw ClaudeCodeACPError.capacity }
        var result: [MappedOption.Choice] = []
        for value in values {
            let option = try ClaudeCodeACPWire.object(value)
            let detail: String?
            if let description = option["description"], description != .null {
                detail = try boundedString(description)
            } else {
                detail = nil
            }
            result.append(MappedOption.Choice(
                value: try boundedString(option["value"]),
                name: try boundedString(option["name"]),
                detail: detail
            ))
        }
        guard result.count <= 128 else { throw ClaudeCodeACPError.capacity }
        return result
    }

    private static func boundedString(_ value: AgentEventJSON?) throws -> String {
        guard case .string(let text) = value,
              let checked = try? AdapterIdentifierValidation.displayText(text) else {
            throw ClaudeCodeACPError.invalidProtocol
        }
        return checked
    }
}
