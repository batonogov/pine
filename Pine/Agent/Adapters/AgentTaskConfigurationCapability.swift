import Foundation

/// The only native execution settings for which Pine can hold an explicit
/// override. Provider-specific options retain their native meaning.
nonisolated enum AgentTaskConfigurationSettingKey: String, CaseIterable, Sendable {
    case model, reasoningEffort, permissions
}

/// Evidence for one provider setting at a particular pinned executable version.
/// `.unknown` is a real state: missing evidence is neither support nor refusal
/// by the provider.
nonisolated struct AgentTaskConfigurationCapability: Equatable, Sendable {
    enum State: String, Equatable, Sendable {
        /// Documented, but not observed at the pinned version.
        case researched
        /// Observed at the pinned version, without an apply/readback check.
        case probed
        /// Applying an override and reading back its effective value passed.
        case supported
        case unsupported
        case unknown
    }

    /// A provider-native choice. In particular, effort values are never
    /// normalized to a shared low/medium/high scale.
    struct Option: Equatable, Sendable {
        let nativeValue: String
        let title: String
        let detail: String?

        init(nativeValue: String, title: String, detail: String? = nil) throws {
            self.nativeValue = try AdapterIdentifierValidation.displayText(nativeValue)
            self.title = try AdapterIdentifierValidation.displayText(title)
            if let detail {
                self.detail = try AdapterIdentifierValidation.displayText(detail)
            } else {
                self.detail = nil
            }
        }
    }

    let key: AgentTaskConfigurationSettingKey
    let state: State
    let overridableScopes: Set<AgentTaskNativeConfigurationScope>
    let enumeratedOptions: [Option]
    let effectiveReadback: Bool

    init(
        key: AgentTaskConfigurationSettingKey,
        state: State,
        overridableScopes: Set<AgentTaskNativeConfigurationScope> = [],
        enumeratedOptions: [Option] = [],
        effectiveReadback: Bool = false
    ) throws {
        guard !overridableScopes.contains(.global) else {
            throw AgentTaskConfigurationCapabilityError.globalScopeForbidden
        }
        guard state != .supported || effectiveReadback else {
            throw AgentTaskConfigurationCapabilityError.supportedWithoutEffectiveReadback
        }
        self.key = key
        self.state = state
        self.overridableScopes = overridableScopes
        self.enumeratedOptions = enumeratedOptions
        self.effectiveReadback = effectiveReadback
    }

    static func unknown(_ key: AgentTaskConfigurationSettingKey) -> Self {
        Self(key: key, state: .unknown, validated: ())
    }

    private init(
        key: AgentTaskConfigurationSettingKey,
        state: State,
        validated: Void
    ) {
        self.key = key
        self.state = state
        overridableScopes = []
        enumeratedOptions = []
        effectiveReadback = false
    }
}

nonisolated enum AgentTaskConfigurationCapabilityError: Error, Equatable, Sendable {
    case globalScopeForbidden
    case supportedWithoutEffectiveReadback
    case duplicateSetting(AgentTaskConfigurationSettingKey)
    case mismatchedSetting(expected: AgentTaskConfigurationSettingKey, actual: AgentTaskConfigurationSettingKey)
}

/// Complete per-provider observation. Transport evidence wins over the
/// provider's version-floor table; a setting absent from both stays unknown.
nonisolated struct AgentTaskConfigurationCapabilities: Equatable, Sendable {
    static let unknown = Self(
        uncheckedModel: .unknown(.model),
        reasoningEffort: .unknown(.reasoningEffort),
        permissions: .unknown(.permissions)
    )

    let model: AgentTaskConfigurationCapability
    let reasoningEffort: AgentTaskConfigurationCapability
    let permissions: AgentTaskConfigurationCapability

    init(
        model: AgentTaskConfigurationCapability = .unknown(.model),
        reasoningEffort: AgentTaskConfigurationCapability = .unknown(.reasoningEffort),
        permissions: AgentTaskConfigurationCapability = .unknown(.permissions)
    ) throws {
        for (expected, capability) in [
            (AgentTaskConfigurationSettingKey.model, model),
            (.reasoningEffort, reasoningEffort),
            (.permissions, permissions),
        ] where capability.key != expected {
            throw AgentTaskConfigurationCapabilityError.mismatchedSetting(
                expected: expected, actual: capability.key
            )
        }
        self.init(
            uncheckedModel: model, reasoningEffort: reasoningEffort, permissions: permissions
        )
    }

    private init(
        uncheckedModel model: AgentTaskConfigurationCapability,
        reasoningEffort: AgentTaskConfigurationCapability,
        permissions: AgentTaskConfigurationCapability
    ) {
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.permissions = permissions
    }

    init(
        transportAdvertised: [AgentTaskConfigurationCapability] = [],
        versionFloor: [AgentTaskConfigurationCapability] = []
    ) throws {
        let transport = try Self.indexed(transportAdvertised)
        let floor = try Self.indexed(versionFloor)
        try self.init(
            model: transport[.model] ?? floor[.model] ?? .unknown(.model),
            reasoningEffort: transport[.reasoningEffort] ?? floor[.reasoningEffort] ?? .unknown(.reasoningEffort),
            permissions: transport[.permissions] ?? floor[.permissions] ?? .unknown(.permissions)
        )
    }

    subscript(key: AgentTaskConfigurationSettingKey) -> AgentTaskConfigurationCapability {
        switch key {
        case .model: model
        case .reasoningEffort: reasoningEffort
        case .permissions: permissions
        }
    }

    private static func indexed(
        _ capabilities: [AgentTaskConfigurationCapability]
    ) throws -> [AgentTaskConfigurationSettingKey: AgentTaskConfigurationCapability] {
        var result: [AgentTaskConfigurationSettingKey: AgentTaskConfigurationCapability] = [:]
        for capability in capabilities {
            guard result[capability.key] == nil else {
                throw AgentTaskConfigurationCapabilityError.duplicateSetting(capability.key)
            }
            result[capability.key] = capability
        }
        return result
    }
}
