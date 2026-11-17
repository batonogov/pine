import Foundation

/// Provider-neutral discovery and readiness observation contract (#1765).
///
/// Observations are separate honest facts: executable identity/version,
/// negotiated transport/capabilities, authentication, and session-start
/// result. Each stays unknown until actually observed. Readiness is derived
/// conservatively from confirmed observations and never fabricated from an
/// absence. A passive discovery (no paid generation, no session start) is a
/// complete and sufficient input to the readiness derivation.
nonisolated struct AgentTaskDiscoveryReport: Equatable, Sendable {
    let contractVersion: PineAdapterContractVersion
    let agentID: AgentID
    /// The launch environment the executable observations apply to; a
    /// Finder-launched GUI does not inherit shell PATH.
    let environmentProvenance: AgentTaskLaunchEnvironmentProvenance
    let executableIdentity: ExecutableIdentityObservation
    let executableVersion: ExecutableVersionObservation
    let transport: TransportObservation
    let authentication: AuthenticationObservation
    let sessionStart: SessionStartObservation
    /// Confirmed effective model / reasoning effort / permissions, distinct
    /// from the requested values in the launch intent. Bounded: exactly
    /// these three overridable settings.
    let effectiveModel: AgentTaskEffectiveSettingObservation
    let effectiveReasoningEffort: AgentTaskEffectiveSettingObservation
    let effectivePermissions: AgentTaskEffectiveSettingObservation
    /// Login flows the adapter declares it can run; empty when unsupported
    /// or unobserved. Launching one is an explicit supported path, see
    /// `AgentLoginFlowRequest`.
    let supportedLoginFlows: Set<AgentLoginFlowKind>

    init(
        contractVersion: PineAdapterContractVersion,
        agentID: AgentID,
        environmentProvenance: AgentTaskLaunchEnvironmentProvenance,
        executableIdentity: ExecutableIdentityObservation,
        executableVersion: ExecutableVersionObservation,
        transport: TransportObservation,
        authentication: AuthenticationObservation,
        sessionStart: SessionStartObservation = .notAttempted,
        effectiveModel: AgentTaskEffectiveSettingObservation = .unknown,
        effectiveReasoningEffort: AgentTaskEffectiveSettingObservation = .unknown,
        effectivePermissions: AgentTaskEffectiveSettingObservation = .unknown,
        supportedLoginFlows: Set<AgentLoginFlowKind> = []
    ) throws {
        guard contractVersion == AgentTaskExecutionContract.currentVersion else {
            throw AgentTaskDiscoveryReportError.unsupportedContractVersion
        }
        switch executableIdentity {
        case .resolved(let url):
            guard AgentTaskNativeLaunchPolicy.isValidAbsoluteLocalExecutable(url) else {
                throw AgentTaskDiscoveryReportError.invalidExecutablePath
            }
        case .unknown, .missing:
            break
        }
        switch executableVersion {
        case .unknown:
            break
        case .supported, .unsupported:
            guard case .resolved = executableIdentity else {
                throw AgentTaskDiscoveryReportError.versionWithoutResolvedExecutable
            }
        }
        switch authentication {
        case .unknown:
            break
        case .loginRequired, .authenticated, .accountUnavailable, .expiredCredentials:
            guard case .resolved = executableIdentity else {
                throw AgentTaskDiscoveryReportError.authenticationWithoutResolvedExecutable
            }
        }
        switch transport {
        case .negotiated:
            guard case .resolved = executableIdentity else {
                throw AgentTaskDiscoveryReportError.transportWithoutResolvedExecutable
            }
        case .unknown, .unsupported:
            break
        }
        switch sessionStart {
        case .notAttempted:
            break
        case .started, .failed:
            guard case .negotiated = transport else {
                throw AgentTaskDiscoveryReportError.sessionStartWithoutNegotiatedTransport
            }
        }
        if !supportedLoginFlows.isEmpty {
            guard case .negotiated = transport else {
                throw AgentTaskDiscoveryReportError.loginFlowsWithoutNegotiatedTransport
            }
        }
        for effective in [effectiveModel, effectiveReasoningEffort, effectivePermissions] {
            guard case .unknown = effective else {
                guard case .resolved = executableIdentity else {
                    throw AgentTaskDiscoveryReportError.effectiveSettingWithoutResolvedExecutable
                }
            }
            try Self.validateEffectiveSetting(effective)
        }
        self.contractVersion = contractVersion
        self.agentID = agentID
        self.environmentProvenance = environmentProvenance
        self.executableIdentity = executableIdentity
        self.executableVersion = executableVersion
        self.transport = transport
        self.authentication = authentication
        self.sessionStart = sessionStart
        self.effectiveModel = effectiveModel
        self.effectiveReasoningEffort = effectiveReasoningEffort
        self.effectivePermissions = effectivePermissions
        self.supportedLoginFlows = supportedLoginFlows
    }

    private static func validateEffectiveSetting(_ observation: AgentTaskEffectiveSettingObservation) throws {
        switch observation {
        case .unknown:
            break
        case .confirmed(let nativeValue):
            _ = try AdapterIdentifierValidation.displayText(nativeValue)
        case .rejected(let reason):
            _ = try AdapterIdentifierValidation.displayText(reason)
        case .fallback(let from):
            _ = try AdapterIdentifierValidation.displayText(from)
        }
    }

    var readiness: AgentTaskDiscoveryReadiness { AgentTaskDiscoveryReadiness(report: self) }

    /// Identity and version are separate observations: resolving a wrapper
    /// does not establish the version, and the version probe belongs to an
    /// explicit supported launch, not to a badge.
    enum ExecutableIdentityObservation: Equatable, Sendable {
        case unknown
        case missing
        case resolved(URL)
    }

    enum ExecutableVersionObservation: Equatable, Sendable {
        case unknown
        case supported(DetectedVendorVersion)
        case unsupported(DetectedVendorVersion)
    }

    enum TransportObservation: Equatable, Sendable {
        case unknown
        case unsupported
        case negotiated(transport: AdapterTransport, capabilities: AdapterCapabilityProfile)
    }

    /// "Signed in" does not promise the next request will succeed:
    /// entitlement, quota, and model availability stay unconfirmed until a
    /// request settles them.
    enum AuthenticationObservation: Equatable, Sendable {
        case unknown
        case loginRequired
        /// `origin` and `accountLabel` are optional redacted metadata; either
        /// may stay nil (unknown) even when authentication is confirmed.
        case authenticated(origin: AgentTaskAuthenticationOrigin?, accountLabel: AgentAccountLabel?)
        case accountUnavailable
        case expiredCredentials
    }

    /// Absence of a session-start observation is not a failure and never
    /// blocks readiness: no paid generation or started session is required
    /// to render the badge.
    enum SessionStartObservation: Equatable, Sendable {
        case notAttempted
        case started
        case failed(Failure)

        enum Failure: Equatable, Sendable {
            case offline
            case quotaOrRateLimit
            case modelUnavailable
            case loginRequired
            case accountUnavailable
            case expiredCredentials
            case other
        }
    }
}

/// The CONFIRMED effective value of one overridable native setting,
/// distinct from the requested value in the launch intent: a native
/// fallback, a rejected override, or the effective value once the adapter
/// confirms it. Populated by adapter observation (#1811+ owns the adapters);
/// `.unknown` until then. Native labels are not normalized by Pine.
nonisolated enum AgentTaskEffectiveSettingObservation: Equatable, Sendable {
    case unknown
    case confirmed(String)
    case rejected(String)
    case fallback(String)
}

/// Optional redacted account metadata. The adapter is responsible for the
/// redaction; Pine only bounds and displays it. Unknown stays `nil`.
nonisolated struct AgentAccountLabel: Hashable, Sendable, CustomStringConvertible {
    let value: String
    init(_ value: String) throws {
        self.value = try AdapterIdentifierValidation.displayText(value)
    }
    var description: String { value }
}

/// Explicit supported path for login. Pine models the contract only: it does
/// not implement provider logins, does not hold credentials, and does not
/// persist tokens or raw authentication payloads in task metadata. The
/// outcome arrives as a refreshed discovery report.
nonisolated enum AgentLoginFlowKind: String, Hashable, Sendable, CaseIterable {
    case native, browser, device
}

nonisolated struct AgentLoginFlowRequest: Equatable, Sendable {
    let agentID: AgentID
    let flow: AgentLoginFlowKind

    /// Only flows the adapter declared supported may be offered.
    func isSupported(by report: AgentTaskDiscoveryReport) -> Bool {
        report.agentID == agentID && report.supportedLoginFlows.contains(flow)
    }
}

nonisolated enum AgentTaskDiscoveryReportError: Error, Equatable, Sendable {
    case unsupportedContractVersion
    case invalidExecutablePath
    case versionWithoutResolvedExecutable
    case authenticationWithoutResolvedExecutable
    case transportWithoutResolvedExecutable
    case sessionStartWithoutNegotiatedTransport
    case loginFlowsWithoutNegotiatedTransport
    case effectiveSettingWithoutResolvedExecutable
}

/// Conservative derivation from confirmed observations. `isReady` states
/// confirmed facts; it is not a promise of next-request success. Quota,
/// entitlement, and model availability remain unconfirmed until a request
/// settles.
nonisolated struct AgentTaskDiscoveryReadiness: Equatable, Sendable {
    enum Component: String, CaseIterable, Sendable {
        case executableIdentity, executableVersion, transportCapabilities, authentication
    }
    enum Blocker: String, CaseIterable, Sendable {
        case missingExecutable, unsupportedVersion, transportUnsupported
        case loginRequired, accountUnavailable, expiredCredentials
        case offline, quotaOrRateLimit, modelUnavailable
        case sessionStartFailed
    }

    let isReady: Bool
    let blockers: [Blocker]
    let unconfirmed: [Component]

    init(report: AgentTaskDiscoveryReport) {
        var blockers: [Blocker] = []
        var unconfirmed: [Component] = []
        func addBlocker(_ blocker: Blocker) {
            if !blockers.contains(blocker) { blockers.append(blocker) }
        }
        switch report.executableIdentity {
        case .resolved:
            break
        case .missing:
            addBlocker(.missingExecutable)
        case .unknown:
            unconfirmed.append(.executableIdentity)
        }
        switch report.executableVersion {
        case .supported:
            break
        case .unsupported:
            addBlocker(.unsupportedVersion)
        case .unknown:
            unconfirmed.append(.executableVersion)
        }
        switch report.transport {
        case .negotiated:
            break
        case .unsupported:
            addBlocker(.transportUnsupported)
        case .unknown:
            unconfirmed.append(.transportCapabilities)
        }
        switch report.authentication {
        case .authenticated:
            break
        case .loginRequired:
            addBlocker(.loginRequired)
        case .accountUnavailable:
            addBlocker(.accountUnavailable)
        case .expiredCredentials:
            addBlocker(.expiredCredentials)
        case .unknown:
            unconfirmed.append(.authentication)
        }
        if case let .failed(failure) = report.sessionStart {
            let failureBlocker: Blocker = switch failure {
            case .offline: .offline
            case .quotaOrRateLimit: .quotaOrRateLimit
            case .modelUnavailable: .modelUnavailable
            case .loginRequired: .loginRequired
            case .accountUnavailable: .accountUnavailable
            case .expiredCredentials: .expiredCredentials
            case .other: .sessionStartFailed
            }
            addBlocker(failureBlocker)
        }
        isReady = blockers.isEmpty && unconfirmed.isEmpty
        self.blockers = blockers
        self.unconfirmed = unconfirmed
    }
}
