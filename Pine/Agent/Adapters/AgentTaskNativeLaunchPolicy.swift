import Foundation

/// Shared contract version for the execution-settings model types.
nonisolated enum AgentTaskExecutionContract {
    static let currentVersion = PineAdapterContractVersion(major: 1, minor: 0)
}

/// Native CLI configuration scopes. Inheritance reads all of them; the CLI
/// resolves its own precedence. An explicit override records the scope where
/// it must take effect.
nonisolated enum AgentTaskNativeConfigurationScope: String, Hashable, Sendable, CaseIterable {
    case session, directory, process, account, global
}

/// Where requested credentials come from. Never a token or payload; the
/// CLI/provider keeps the credential.
nonisolated enum AgentTaskAuthenticationOrigin: String, Hashable, Sendable {
    /// The CLI's own credential store.
    case inheritNative
    /// A credential carried in the launch environment, which can change
    /// connection and billing provenance.
    case launchEnvironment
}

/// Honest provenance of the spawn environment. A GUI launched from Finder
/// does not inherit shell PATH; a separate server may use another environment
/// entirely.
nonisolated enum AgentTaskLaunchEnvironmentProvenance: String, Hashable, Sendable {
    case inheritedPineProcess
    case explicitExternal
}

/// The launch-boundary provenance facts the intent records: where the
/// credentials come from and where the launch environment comes from. Both
/// are required — a default would assert a fact the consumer never decided
/// (a credential in the launch environment can change connection and billing
/// provenance).
nonisolated struct AgentTaskLaunchProvenance: Equatable, Sendable {
    let authenticationOrigin: AgentTaskAuthenticationOrigin
    let environmentProvenance: AgentTaskLaunchEnvironmentProvenance
}

/// One native setting's launch intent. "Use agent settings" (`.inherited`)
/// is a real policy, not a fabricated selection: it carries no value and no
/// scope. Explicit values stay native labels; Pine never normalizes them to
/// a universal scale.
nonisolated struct AgentTaskNativeSettingSelection: Equatable, Sendable {
    enum Provenance: String, Equatable, Sendable { case inherited, explicit }

    let provenance: Provenance
    /// The native label the adapter must apply; `nil` exactly when inherited.
    let nativeValue: String?
    /// Where an explicit override takes effect; `nil` exactly when inherited.
    let scope: AgentTaskNativeConfigurationScope?

    /// The "use agent settings" inheritance policy.
    init() {
        provenance = .inherited
        nativeValue = nil
        scope = nil
    }

    private init(provenance: Provenance, nativeValue: String?, scope: AgentTaskNativeConfigurationScope?) {
        self.provenance = provenance
        self.nativeValue = nativeValue
        self.scope = scope
    }

    /// A task option must not rewrite global CLI configuration or switch
    /// accounts globally, so `.global` is not a requestable override scope.
    static func explicit(
        nativeValue: String,
        scope: AgentTaskNativeConfigurationScope
    ) throws -> AgentTaskNativeSettingSelection {
        guard scope != .global else { throw AgentTaskNativeSettingSelectionError.globalScopeForbidden }
        let value = try AdapterIdentifierValidation.displayText(nativeValue)
        return AgentTaskNativeSettingSelection(provenance: .explicit, nativeValue: value, scope: scope)
    }
}

nonisolated enum AgentTaskNativeSettingSelectionError: Error, Equatable, Sendable {
    case globalScopeForbidden
}

/// Value-only execution-settings intent for a native-inheritance launch.
/// It is never launch authority, authentication, or readiness: the consumer
/// owns live binding/executable/environment validation before spawn, explicit
/// execution authority and the source/process/task join.
///
/// The intent is an immutable per-run snapshot. Changing a project default
/// mints a new intent for future tasks; it never mutates an in-flight intent
/// or its reviewer.
nonisolated struct AgentTaskNativeLaunchPolicy: Equatable, Sendable {
    enum RequestedSettings: Equatable, Sendable {
        case inheritNativeConfiguration
        case overrides
    }
    enum BlockedReason: Equatable, Sendable {
        case missingSelection
        case inconsistentSelection
        case capabilityUnavailable(AgentTaskConfigurationSettingKey)
    }
    enum Eligibility: Equatable, Sendable {
        case eligible(AgentTaskNativeLaunchPolicy)
        case blocked(BlockedReason)
    }

    /// A selected path, not proof that its contents implement this runtime.
    struct Selection: Equatable, Sendable {
        let agentID: AgentID
        let selectedExecutable: URL
    }

    let contractVersion: PineAdapterContractVersion
    let taskID: UUID
    /// Current logical attempt, not the environment's original reservationRunID.
    let runID: UUID
    let bindingID: UUID
    let agentID: AgentID
    let selectedExecutable: URL
    /// Requested model, reasoning effort, and permissions; each is either
    /// inherited from the CLI or an explicit native-labeled override.
    let model: AgentTaskNativeSettingSelection
    let reasoningEffort: AgentTaskNativeSettingSelection
    let permissions: AgentTaskNativeSettingSelection
    let authenticationOrigin: AgentTaskAuthenticationOrigin
    let environmentProvenance: AgentTaskLaunchEnvironmentProvenance

    /// Inheritance deliberately reads every native scope. Executable version
    /// is an observation, not an intent: it is unknown until a supported
    /// launch or probe establishes it (see `AgentTaskDiscoveryReport`).
    var inheritedConfigurationScopes: Set<AgentTaskNativeConfigurationScope> {
        Set(AgentTaskNativeConfigurationScope.allCases)
    }

    var requestedSettings: RequestedSettings {
        [model, reasoningEffort, permissions].contains(where: { $0.provenance == .explicit })
            ? .overrides : .inheritNativeConfiguration
    }

    private init(
        taskID: UUID,
        runID: UUID,
        bindingID: UUID,
        selection: Selection,
        model: AgentTaskNativeSettingSelection,
        reasoningEffort: AgentTaskNativeSettingSelection,
        permissions: AgentTaskNativeSettingSelection,
        authenticationOrigin: AgentTaskAuthenticationOrigin,
        environmentProvenance: AgentTaskLaunchEnvironmentProvenance
    ) {
        contractVersion = AgentTaskExecutionContract.currentVersion
        self.taskID = taskID
        self.runID = runID
        self.bindingID = bindingID
        agentID = selection.agentID
        selectedExecutable = selection.selectedExecutable
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.permissions = permissions
        self.authenticationOrigin = authenticationOrigin
        self.environmentProvenance = environmentProvenance
    }

    /// Absolute local file identity only; PATH lookup is not a resolution.
    /// Bounded to PATH_MAX so an unbounded path cannot ride into persisted
    /// intents or reports.
    static func isValidAbsoluteLocalExecutable(_ url: URL) -> Bool {
        let path = url.path(percentEncoded: false)
        return url.isFileURL && url.baseURL == nil
            && (url.host == nil || url.host == "")
            && url.user == nil && url.password == nil && url.port == nil
            && url.query == nil && url.fragment == nil
            && path.hasPrefix("/") && path != "/"
            && path.utf8.count <= 1_024
            && !url.hasDirectoryPath
            && !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    /// Deterministic representability only: no discovery, probes or config
    /// reads. Setting selections are already validated at construction.
    ///
    /// `provenance` is required because the intent records the
    /// launch-boundary facts: a default would assert a provenance the
    /// consumer never decided (a credential in the launch environment can
    /// change connection and billing provenance).
    static func evaluate(
        taskID: UUID,
        runID: UUID,
        bindingID: UUID,
        selection: Selection?,
        model: AgentTaskNativeSettingSelection = AgentTaskNativeSettingSelection(),
        reasoningEffort: AgentTaskNativeSettingSelection = AgentTaskNativeSettingSelection(),
        permissions: AgentTaskNativeSettingSelection = AgentTaskNativeSettingSelection(),
        configurationCapabilities: AgentTaskConfigurationCapabilities = .unknown,
        provenance: AgentTaskLaunchProvenance
    ) -> Eligibility {
        guard let selection else { return .blocked(.missingSelection) }
        guard isValidAbsoluteLocalExecutable(selection.selectedExecutable) else {
            return .blocked(.inconsistentSelection)
        }
        let requested = [
            (AgentTaskConfigurationSettingKey.model, model),
            (.reasoningEffort, reasoningEffort),
            (.permissions, permissions),
        ]
        for (key, setting) in requested where setting.provenance == .explicit {
            let state = configurationCapabilities[key].state
            guard state != .unsupported && state != .unknown else {
                return .blocked(.capabilityUnavailable(key))
            }
        }
        return .eligible(Self(
            taskID: taskID, runID: runID, bindingID: bindingID, selection: selection,
            model: model, reasoningEffort: reasoningEffort, permissions: permissions,
            authenticationOrigin: provenance.authenticationOrigin,
            environmentProvenance: provenance.environmentProvenance
        ))
    }
}
