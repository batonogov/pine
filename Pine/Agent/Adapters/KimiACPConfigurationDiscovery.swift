import Foundation

/// Maps only observations made on the pinned Kimi Code CLI 2.6.2 ACP
/// connection (#1765). `session/new|load|resume|fork` return dynamic
/// `configOptions`; the documented option set is `model`, `thinking` and
/// `mode` (the session permission mode), with `session/set_config_option` as
/// the unified picker dispatcher. Pine never calls
/// `session/set_config_option` in this slice, so no overridable scope is
/// claimed and no apply/readback cycle is advertised.
///
/// The version floor is documented at the pin (re-probed 2026-11-17:
/// `session/new` is auth-gated, so nothing is observed there); an observed
/// session response promotes a setting to probed. Unknown option IDs,
/// non-select types, and malformed payloads degrade to the floor, never to a
/// manufactured capability.
nonisolated enum KimiACPConfigurationDiscovery {
    /// Launch-boundary observation the session can attribute: the validated
    /// executable (when the owner supplies it) and the environment provenance.
    struct Input: Sendable {
        let selectedExecutable: URL?
        let environmentProvenance: AgentTaskLaunchEnvironmentProvenance
    }

    /// Documented at the pinned 2.6.2, not observed by Pine before a live
    /// session: dynamic `configOptions` (`model`/`thinking`/`mode`) from the
    /// session setup response.
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
        requiresAuthentication: Bool,
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
            // The initialize gate admitted the exact pinned version before
            // the session was created; this is a confirmed observation.
            version = .supported(try DetectedVendorVersion(KimiACPCapabilities.pinnedCLIVersion))
            transport = .negotiated(
                transport: .ownedStandardIO, capabilities: try KimiACPSession.profile()
            )
            hasExecutable = true
        } else {
            identity = .unknown
            version = .unknown
            transport = .unknown
            hasExecutable = false
        }
        // Without a resolved executable the report cannot attribute effective
        // values, so they stay unknown even when options were observed.
        return try AgentTaskDiscoveryReport(
            contractVersion: AgentTaskExecutionContract.currentVersion,
            agentID: AgentID(migratingLegacyStableIdentifier: "kimiCode"),
            environmentProvenance: input?.environmentProvenance ?? .inheritedPineProcess,
            executableIdentity: identity,
            executableVersion: version,
            transport: transport,
            authentication: authentication(requiresAuthentication: requiresAuthentication),
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
            guard !observed.contains(key) else { throw KimiACPWireError.invalidProtocol }
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

    /// Documented pinned-version option IDs and their Pine setting keys. The
    /// `mode` option is Kimi's session permission mode (ask / never-ask /
    /// plan), not a primary agent: it maps to `.permissions`. Unknown IDs,
    /// non-select types, and boolean values are skipped, not mapped.
    static func mappedOptions(
        sessionConfigOptions: AgentEventJSON?
    ) throws -> [(key: AgentTaskConfigurationSettingKey, option: MappedOption)] {
        guard let sessionConfigOptions, sessionConfigOptions != .null else { return [] }
        guard case .array(let options) = sessionConfigOptions else {
            throw KimiACPWireError.invalidProtocol
        }
        guard options.count <= 32 else { throw KimiACPWireError.capacity }
        var result: [(key: AgentTaskConfigurationSettingKey, option: MappedOption)] = []
        for value in options {
            let fields = try KimiACPWire.object(value)
            let id = try KimiACPWire.boundedString(fields["id"], maximum: 256)
            let key: AgentTaskConfigurationSettingKey
            switch id {
            case "model": key = .model
            case "thinking": key = .reasoningEffort
            case "mode": key = .permissions
            default: continue
            }
            let type = try KimiACPWire.boundedString(fields["type"], maximum: 64)
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
        guard case .array(let values) = value else { throw KimiACPWireError.invalidProtocol }
        guard values.count <= 128 else { throw KimiACPWireError.capacity }
        var result: [MappedOption.Choice] = []
        for value in values {
            let option = try KimiACPWire.object(value)
            if option["group"] != nil {
                result.append(contentsOf: try groupedOptions(option["options"]))
                continue
            }
            let detail: String?
            if let description = option["description"], description != .null {
                detail = try KimiACPWire.boundedString(description, maximum: 1_024)
            } else {
                detail = nil
            }
            result.append(MappedOption.Choice(
                value: try KimiACPWire.boundedString(option["value"], maximum: 256),
                name: try KimiACPWire.boundedString(option["name"], maximum: 256),
                detail: detail
            ))
            guard result.count <= 128 else { throw KimiACPWireError.capacity }
        }
        return result
    }

    private static func groupedOptions(
        _ value: AgentEventJSON?
    ) throws -> [MappedOption.Choice] {
        guard case .array(let values) = value else { throw KimiACPWireError.invalidProtocol }
        guard values.count <= 128 else { throw KimiACPWireError.capacity }
        var result: [MappedOption.Choice] = []
        for value in values {
            let option = try KimiACPWire.object(value)
            let detail: String?
            if let description = option["description"], description != .null {
                detail = try KimiACPWire.boundedString(description, maximum: 1_024)
            } else {
                detail = nil
            }
            result.append(MappedOption.Choice(
                value: try KimiACPWire.boundedString(option["value"], maximum: 256),
                name: try KimiACPWire.boundedString(option["name"], maximum: 256),
                detail: detail
            ))
        }
        guard result.count <= 128 else { throw KimiACPWireError.capacity }
        return result
    }

    static func authentication(
        requiresAuthentication: Bool
    ) -> AgentTaskDiscoveryReport.AuthenticationObservation {
        guard requiresAuthentication else { return .unknown }
        // Non-empty `authMethods` plus a passed account gate: the CLI's own
        // terminal-auth store is the verified credential source. No label or
        // token is retained.
        return .authenticated(origin: .inheritNative, accountLabel: nil)
    }
}
