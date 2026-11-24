import Foundation

/// Maps only observations made on the pinned Codex 0.169.0 app-server
/// connection (#1765). `model/list` and `config/read` are the documented
/// non-mutating discovery calls of the pinned version (verified against the
/// `rust-v0.169.0` protocol sources): `model/list` answers with the model
/// catalog including `supportedReasoningEfforts`, and `config/read` answers
/// with the effective configuration after layering.
///
/// Both the version floor and the transport observations stay fail-closed:
/// a missing or malformed observation keeps the documented floor (researched)
/// or unknown; nothing here manufactures a capability or an effective value.
nonisolated enum CodexAppServerConfigurationDiscovery {
    /// Documented at the pinned 0.169.0, not observed by Pine before a live
    /// session: `model/list` (model + supported reasoning efforts),
    /// `config/read` (effective config), and per-thread
    /// `approvalPolicy`/`sandbox` on `thread/start`. Pine applies no
    /// overrides, so no overridable scope is claimed.
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
        selectedExecutable: URL,
        environmentProvenance: AgentTaskLaunchEnvironmentProvenance,
        accountState: CodexAppServerAccountState,
        modelList: AgentEventJSON? = nil,
        configRead: AgentEventJSON? = nil,
        sessionStarted: Bool = false
    ) throws -> AgentTaskDiscoveryReport {
        let version = try DetectedVendorVersion(CodexAppServerExecutableIdentity.supportedVersion)
        let capabilities = try configurationCapabilities(modelList: modelList, configRead: configRead)
        // The malformed-observation gate floors the capabilities; effective
        // values from the same session must not outlive it.
        let effective = try observationsConform(modelList: modelList, configRead: configRead)
            ? try effectiveSettings(configRead: configRead)
            : (.unknown, .unknown, .unknown)
        return try AgentTaskDiscoveryReport(
            contractVersion: AgentTaskExecutionContract.currentVersion,
            agentID: AgentID(migratingLegacyStableIdentifier: "codex"),
            environmentProvenance: environmentProvenance,
            executableIdentity: .resolved(selectedExecutable),
            executableVersion: .supported(version),
            transport: .negotiated(
                transport: .ownedStandardIO, capabilities: try CodexAppServerNativeFactory.profile()
            ),
            authentication: authentication(accountState),
            sessionStart: sessionStarted ? .started : .notAttempted,
            configurationCapabilities: capabilities,
            effectiveModel: effective.model,
            effectiveReasoningEffort: effective.reasoningEffort,
            effectivePermissions: effective.permissions
        )
    }

    static func configurationCapabilities(
        modelList: AgentEventJSON?,
        configRead: AgentEventJSON?
    ) throws -> AgentTaskConfigurationCapabilities {
        // A present-but-malformed documented read is a negative observation:
        // the peer no longer answers the pinned protocol surface, so nothing
        // observed in this session is promoted above the documented floor.
        guard try observationsConform(modelList: modelList, configRead: configRead) else {
            return try AgentTaskConfigurationCapabilities(
                transportAdvertised: [], versionFloor: try versionFloors()
            )
        }
        var advertised: [AgentTaskConfigurationCapability] = []
        let effective = try effectiveSettings(configRead: configRead)
        let modelReadback = if case .confirmed = effective.model { true } else { false }
        let effortReadback = if case .confirmed = effective.reasoningEffort { true } else { false }
        if let catalog = try modelCatalog(modelList), !catalog.models.isEmpty {
            advertised.append(try AgentTaskConfigurationCapability(
                key: .model,
                state: .probed,
                overridableScopes: [],
                enumeratedOptions: catalog.models.map {
                    try AgentTaskConfigurationCapability.Option(
                        nativeValue: $0.id, title: $0.displayName ?? $0.id
                    )
                },
                // model/list is a catalog, not readback: only `config/read`
                // confirms the effective model.
                effectiveReadback: modelReadback
            ))
            if !catalog.efforts.isEmpty {
                advertised.append(try AgentTaskConfigurationCapability(
                    key: .reasoningEffort,
                    state: .probed,
                    overridableScopes: [],
                    enumeratedOptions: catalog.efforts.map {
                        try AgentTaskConfigurationCapability.Option(
                            nativeValue: $0.effort, title: $0.effort, detail: $0.detail
                        )
                    },
                    effectiveReadback: effortReadback
                ))
            }
        }
        if effective.permissions != .unknown {
            advertised.append(try AgentTaskConfigurationCapability(
                key: .permissions,
                state: .probed,
                overridableScopes: [],
                enumeratedOptions: [],
                effectiveReadback: true
            ))
        }
        return try AgentTaskConfigurationCapabilities(
            transportAdvertised: advertised, versionFloor: try versionFloors()
        )
    }

    /// The effective values `config/read` confirms on the pinned app-server.
    /// `Config` is serialized snake_case: `model`, `model_reasoning_effort`,
    /// `approval_policy`, `sandbox_mode`. Any other shape stays unknown.
    static func effectiveSettings(
        configRead: AgentEventJSON?
    ) throws -> (
        model: AgentTaskEffectiveSettingObservation,
        reasoningEffort: AgentTaskEffectiveSettingObservation,
        permissions: AgentTaskEffectiveSettingObservation
    ) {
        guard let configRead,
              case .object(let fields) = configRead,
              case .object(let config) = fields["config"] else {
            return (.unknown, .unknown, .unknown)
        }
        var model: AgentTaskEffectiveSettingObservation = .unknown
        var effort: AgentTaskEffectiveSettingObservation = .unknown
        var permissions: AgentTaskEffectiveSettingObservation = .unknown
        if case .string(let value) = config["model"] {
            _ = try AdapterIdentifierValidation.displayText(value)
            model = .confirmed(value)
        }
        if case .string(let value) = config["model_reasoning_effort"] {
            _ = try AdapterIdentifierValidation.displayText(value)
            effort = .confirmed(value)
        }
        var approval: String?
        if case .string(let value) = config["approval_policy"] {
            approval = try AdapterIdentifierValidation.displayText(value)
        } else if case .object(let granular) = config["approval_policy"],
                  granular["granular"] != nil {
            approval = "granular"
        }
        if let approval {
            if case .string(let sandbox) = config["sandbox_mode"],
               let checked = try? AdapterIdentifierValidation.displayText(sandbox) {
                permissions = .confirmed("\(approval), sandbox \(checked)")
            } else {
                permissions = .confirmed(approval)
            }
        } else if case .string(let sandbox) = config["sandbox_mode"] {
            _ = try AdapterIdentifierValidation.displayText(sandbox)
            permissions = .confirmed("sandbox \(sandbox)")
        }
        return (model, effort, permissions)
    }

    /// A present-but-malformed documented read no longer conforms to the
    /// pinned protocol surface; an absent read is simply unobserved.
    private static func observationsConform(
        modelList: AgentEventJSON?, configRead: AgentEventJSON?
    ) throws -> Bool {
        if modelList != nil, try modelCatalog(modelList) == nil { return false }
        if configRead != nil {
            guard case .object(let fields) = configRead,
                  case .object = fields["config"] else { return false }
        }
        return true
    }

    struct ModelCatalog: Equatable, Sendable {
        struct Model: Equatable, Sendable {
            let id: String
            let displayName: String?
        }
        struct Effort: Equatable, Sendable {
            let effort: String
            let detail: String?
        }
        let models: [Model]
        let efforts: [Effort]
    }

    /// The pinned `model/list` result: `{"data": [Model], "nextCursor": ...}`.
    /// Bounded and fail-closed; anything unexpected is an unobserved catalog.
    static func modelCatalog(_ value: AgentEventJSON?) throws -> ModelCatalog? {
        guard let value, case .object(let fields) = value,
              case .array(let data) = fields["data"] else { return nil }
        guard data.count <= 64 else { throw CodexAppServerWireError.capacityExceeded }
        var models: [ModelCatalog.Model] = []
        var efforts: [ModelCatalog.Effort] = []
        for value in data {
            let fields = try object(value)
            let id = try string(fields["id"])
            let displayName = try fields["displayName"].flatMap {
                try? string($0)
            }
            models.append(ModelCatalog.Model(id: id, displayName: displayName))
            if case .array(let entries) = fields["supportedReasoningEfforts"] {
                guard entries.count <= 32 else { throw CodexAppServerWireError.capacityExceeded }
                for entry in entries {
                    let entryFields = try object(entry)
                    let effort = try string(entryFields["reasoningEffort"])
                    let detail = try entryFields["description"].flatMap { try? string($0) }
                    if !efforts.contains(where: { $0.effort == effort }) {
                        efforts.append(ModelCatalog.Effort(effort: effort, detail: detail))
                    }
                }
            }
        }
        return ModelCatalog(models: models, efforts: efforts)
    }

    static func authentication(
        _ state: CodexAppServerAccountState
    ) -> AgentTaskDiscoveryReport.AuthenticationObservation {
        switch state {
        case .credentialsConfigured:
            .authenticated(origin: .inheritNative, accountLabel: nil)
        case .signInRequired:
            .loginRequired
        case .externalProviderUnverified, .unknown:
            .unknown
        }
    }

    private static func object(_ value: AgentEventJSON) throws -> [String: AgentEventJSON] {
        guard case .object(let fields) = value else { throw CodexAppServerWireError.invalidEnvelope }
        return fields
    }

    private static func string(_ value: AgentEventJSON?) throws -> String {
        guard case .string(let text) = value,
              let checked = try? AdapterIdentifierValidation.displayText(text) else {
            throw CodexAppServerWireError.invalidEnvelope
        }
        return checked
    }
}
