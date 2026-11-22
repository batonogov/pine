import Foundation

/// Maps only observations made by the pinned OpenCode launch/admission path.
/// A version probe and factory admission establish no setting capability by
/// themselves. OpenCode's ACP `mode` is a primary agent, not permissions, and
/// is deliberately not mapped to `AgentTaskConfigurationSettingKey.permissions`.
nonisolated enum OpenCodeACPConfigurationDiscovery {
    static func report(
        selectedExecutable: URL,
        versionProbe: DetectedVendorVersion?,
        factoryAdmission: AdapterProbeResult?,
        sessionConfigOptions: AgentEventJSON? = nil,
        sessionStarted: Bool = false,
        environmentProvenance: AgentTaskLaunchEnvironmentProvenance = .inheritedPineProcess
    ) throws -> AgentTaskDiscoveryReport {
        let pinned = versionProbe?.value == OpenCodeACPSession.pinnedVersion
        let pinnedProfile = try OpenCodeACPSession.profile()
        let admitted = pinned && factoryAdmission?.detectedVendorVersion.value == OpenCodeACPSession.pinnedVersion
            && factoryAdmission?.offeredProfiles == [pinnedProfile]
        let version: AgentTaskDiscoveryReport.ExecutableVersionObservation
        if let versionProbe {
            version = pinned ? .supported(versionProbe) : .unsupported(versionProbe)
        } else {
            version = .unknown
        }
        let transport: AgentTaskDiscoveryReport.TransportObservation = if admitted,
            let profile = factoryAdmission?.offeredProfiles.first {
            .negotiated(transport: .ownedStandardIO, capabilities: profile)
        } else {
            .unknown
        }
        return try AgentTaskDiscoveryReport(
            contractVersion: AgentTaskExecutionContract.currentVersion,
            agentID: AgentID(migratingLegacyStableIdentifier: "openCode"),
            environmentProvenance: environmentProvenance,
            executableIdentity: .resolved(selectedExecutable),
            executableVersion: version,
            transport: transport,
            authentication: .unknown,
            sessionStart: admitted && sessionStarted ? .started : .notAttempted,
            configurationCapabilities: configurationCapabilities(
                admitted: admitted, sessionConfigOptions: sessionConfigOptions
            )
        )
    }

    static func configurationCapabilities(
        admitted: Bool,
        sessionConfigOptions: AgentEventJSON?
    ) throws -> AgentTaskConfigurationCapabilities {
        guard admitted, let sessionConfigOptions, sessionConfigOptions != .null else { return .unknown }
        guard case .array(let options) = sessionConfigOptions else { throw OpenCodeACPError.invalidProtocol }
        guard options.count <= 32 else { throw OpenCodeACPError.capacity }

        var advertised: [AgentTaskConfigurationCapability] = []
        var observed: Set<AgentTaskConfigurationSettingKey> = []
        for value in options {
            let option = try OpenCodeACPWire.object(value)
            let id = try OpenCodeACPWire.string(option["id"])
            let key: AgentTaskConfigurationSettingKey
            let expectedCategory: String
            switch id {
            case "model":
                key = .model
                expectedCategory = "model"
            case "effort":
                key = .reasoningEffort
                expectedCategory = "thought_level"
            default:
                continue
            }
            guard case .string(let category) = option["category"], category == expectedCategory else {
                continue
            }
            // Missing/unknown categories and unknown option types degrade to
            // unknown; neither can manufacture a capability for a known ID.
            guard try OpenCodeACPWire.string(option["type"]) == "select" else { continue }
            guard !observed.contains(key) else { throw OpenCodeACPError.invalidProtocol }
            let currentValue = try OpenCodeACPWire.string(option["currentValue"])
            _ = try AdapterIdentifierValidation.displayText(currentValue)
            advertised.append(try AgentTaskConfigurationCapability(
                key: key,
                state: .probed,
                overridableScopes: [.session],
                enumeratedOptions: try nativeOptions(option["options"]),
                // ACP currentValue is readback evidence only. No apply/readback
                // cycle is claimed, and effective values remain deferred.
                effectiveReadback: true
            ))
            observed.insert(key)
        }
        return try AgentTaskConfigurationCapabilities(transportAdvertised: advertised)
    }

    private static func nativeOptions(
        _ value: AgentEventJSON?,
        allowGroups: Bool = true
    ) throws -> [AgentTaskConfigurationCapability.Option] {
        guard case .array(let values) = value else { throw OpenCodeACPError.invalidProtocol }
        guard values.count <= 128 else { throw OpenCodeACPError.capacity }
        var result: [AgentTaskConfigurationCapability.Option] = []
        for value in values {
            let option = try OpenCodeACPWire.object(value)
            if allowGroups, option["group"] != nil {
                result.append(contentsOf: try nativeOptions(option["options"], allowGroups: false))
                guard result.count <= 128 else { throw OpenCodeACPError.capacity }
                continue
            }
            let detail: String?
            if let description = option["description"], description != .null {
                detail = try OpenCodeACPWire.string(description)
            } else {
                detail = nil
            }
            result.append(try AgentTaskConfigurationCapability.Option(
                nativeValue: OpenCodeACPWire.string(option["value"]),
                title: OpenCodeACPWire.string(option["name"]),
                detail: detail
            ))
            guard result.count <= 128 else { throw OpenCodeACPError.capacity }
        }
        return result
    }
}
