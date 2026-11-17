import Foundation
import Testing
@testable import Pine

struct AgentTaskDiscoveryReportTests {
    private let resolvedPath = URL(fileURLWithPath: "/usr/local/bin/codex", isDirectory: false)

    private func negotiatedProfile() throws -> AdapterCapabilityProfile {
        try AdapterCapabilityProfile(
            transport: .ownedStandardIO,
            lifecycle: AdapterLifecycleCapabilities(
                signals: [
                    .init(scope: .session, phase: .settled), .init(scope: .turn, phase: .started)
                ],
                evidence: []
            ),
            delivery: AdapterDeliverySemantics(ordering: .ordered, minimumAuthentication: .ownedChildPipe)
        )
    }

    private func report(
        identity: AgentTaskDiscoveryReport.ExecutableIdentityObservation = .unknown,
        version: AgentTaskDiscoveryReport.ExecutableVersionObservation = .unknown,
        transport: AgentTaskDiscoveryReport.TransportObservation = .unknown,
        authentication: AgentTaskDiscoveryReport.AuthenticationObservation = .unknown,
        sessionStart: AgentTaskDiscoveryReport.SessionStartObservation = .notAttempted,
        effectiveModel: AgentTaskEffectiveSettingObservation = .unknown,
        effectiveReasoningEffort: AgentTaskEffectiveSettingObservation = .unknown,
        effectivePermissions: AgentTaskEffectiveSettingObservation = .unknown,
        loginFlows: Set<AgentLoginFlowKind> = [],
        environment: AgentTaskLaunchEnvironmentProvenance = .inheritedPineProcess
    ) throws -> AgentTaskDiscoveryReport {
        try AgentTaskDiscoveryReport(
            contractVersion: AgentTaskExecutionContract.currentVersion,
            agentID: try AgentID(validating: "codex"),
            environmentProvenance: environment,
            executableIdentity: identity,
            executableVersion: version,
            transport: transport,
            authentication: authentication,
            sessionStart: sessionStart,
            effectiveModel: effectiveModel,
            effectiveReasoningEffort: effectiveReasoningEffort,
            effectivePermissions: effectivePermissions,
            supportedLoginFlows: loginFlows
        )
    }

    /// All four passive observations confirmed, no session attempted.
    private func readyBase(
        effectiveModel: AgentTaskEffectiveSettingObservation = .unknown,
        effectiveReasoningEffort: AgentTaskEffectiveSettingObservation = .unknown,
        effectivePermissions: AgentTaskEffectiveSettingObservation = .unknown
    ) throws -> AgentTaskDiscoveryReport {
        try report(
            identity: .resolved(resolvedPath),
            version: .supported(try DetectedVendorVersion("1.2.3")),
            transport: .negotiated(
                transport: .ownedStandardIO, capabilities: try negotiatedProfile()
            ),
            authentication: .authenticated(origin: .inheritNative, accountLabel: nil),
            effectiveModel: effectiveModel,
            effectiveReasoningEffort: effectiveReasoningEffort,
            effectivePermissions: effectivePermissions
        )
    }

    @Test func allUnknownReportConfirmsNothing() throws {
        let readiness = try report().readiness
        #expect(!readiness.isReady)
        #expect(readiness.blockers.isEmpty)
        #expect(Set(readiness.unconfirmed) == Set(AgentTaskDiscoveryReadiness.Component.allCases))
    }

    @Test func passiveObservationsAloneAreReadyWithoutSessionStart() throws {
        let readiness = try readyBase().readiness
        #expect(readiness.isReady)
        #expect(readiness.blockers.isEmpty)
        #expect(readiness.unconfirmed.isEmpty)
    }

    @Test func signedInDoesNotPromiseReadiness() throws {
        let readiness = try report(
            identity: .resolved(resolvedPath),
            authentication: .authenticated(origin: .inheritNative, accountLabel: nil)
        ).readiness
        #expect(!readiness.isReady)
        #expect(readiness.blockers.isEmpty)
        #expect(Set(readiness.unconfirmed) == [
            .executableVersion, .transportCapabilities
        ])
    }

    @Test func eachConfirmedNegativeObservationIsItsOwnBlocker() throws {
        let cases: [(AgentTaskDiscoveryReport, AgentTaskDiscoveryReadiness.Blocker)] = [
            (try report(identity: .missing), .missingExecutable),
            (
                try report(
                    identity: .resolved(resolvedPath),
                    version: .unsupported(try DetectedVendorVersion("0.1.0"))
                ),
                .unsupportedVersion
            ),
            (try report(transport: .unsupported), .transportUnsupported),
            (
                try report(
                    identity: .resolved(resolvedPath),
                    authentication: .loginRequired
                ),
                .loginRequired
            ),
            (
                try report(
                    identity: .resolved(resolvedPath),
                    authentication: .accountUnavailable
                ),
                .accountUnavailable
            ),
            (
                try report(
                    identity: .resolved(resolvedPath),
                    authentication: .expiredCredentials
                ),
                .expiredCredentials
            )
        ]
        for (candidate, expectedBlocker) in cases {
            let readiness = candidate.readiness
            #expect(!readiness.isReady)
            #expect(readiness.blockers.contains(expectedBlocker))
        }
    }

    @Test func sessionStartFailuresBlockReadinessWithTheirOwnKind() throws {
        let transport = AgentTaskDiscoveryReport.TransportObservation.negotiated(
            transport: .ownedStandardIO, capabilities: try negotiatedProfile()
        )
        let failures: [(AgentTaskDiscoveryReport.SessionStartObservation.Failure,
                        AgentTaskDiscoveryReadiness.Blocker)] = [
            (.offline, .offline),
            (.quotaOrRateLimit, .quotaOrRateLimit),
            (.modelUnavailable, .modelUnavailable),
            (.loginRequired, .loginRequired),
            (.accountUnavailable, .accountUnavailable),
            (.expiredCredentials, .expiredCredentials),
            (.other, .sessionStartFailed)
        ]
        for (failure, expectedBlocker) in failures {
            let readiness = try report(
                identity: .resolved(resolvedPath),
                version: .supported(try DetectedVendorVersion("1.2.3")),
                transport: transport,
                authentication: .authenticated(origin: nil, accountLabel: nil),
                sessionStart: .failed(failure)
            ).readiness
            #expect(!readiness.isReady)
            #expect(readiness.blockers.contains(expectedBlocker))
        }
    }

    @Test func aStartedSessionStartsNoFalseReadiness() throws {
        let transport = AgentTaskDiscoveryReport.TransportObservation.negotiated(
            transport: .ownedStandardIO, capabilities: try negotiatedProfile()
        )
        // Auth unknown even though a session started: readiness must not be
        // fabricated from the session alone.
        let readiness = try report(
            identity: .resolved(resolvedPath),
            version: .supported(try DetectedVendorVersion("1.2.3")),
            transport: transport,
            sessionStart: .started
        ).readiness
        #expect(!readiness.isReady)
        #expect(readiness.blockers.isEmpty)
        #expect(readiness.unconfirmed == [.authentication])
    }

    @Test func observationsCannotBeConstructedWithoutTheExecutableTheyDependOn() throws {
        let version = AgentTaskDiscoveryReport.ExecutableVersionObservation.supported(
            try DetectedVendorVersion("1.2.3")
        )
        #expect(throws: AgentTaskDiscoveryReportError.versionWithoutResolvedExecutable) {
            _ = try report(version: version)
        }
        #expect(throws: AgentTaskDiscoveryReportError.authenticationWithoutResolvedExecutable) {
            _ = try report(authentication: .authenticated(origin: nil, accountLabel: nil))
        }
        #expect(throws: AgentTaskDiscoveryReportError.transportWithoutResolvedExecutable) {
            _ = try report(
                transport: .negotiated(
                    transport: .ownedStandardIO, capabilities: try negotiatedProfile()
                )
            )
        }
        #expect(throws: AgentTaskDiscoveryReportError.sessionStartWithoutNegotiatedTransport) {
            _ = try report(
                identity: .resolved(resolvedPath),
                sessionStart: .started
            )
        }
        // A trailing slash is the only directory form detectable without a
        // filesystem probe; stat-based checks belong to the launch lease.
        for text in ["https://example.com/codex", "file:///bin/"] {
            let url = try #require(URL(string: text))
            #expect(throws: AgentTaskDiscoveryReportError.invalidExecutablePath) {
                _ = try report(identity: .resolved(url))
            }
        }
    }

    @Test func unknownContractVersionIsRejected() throws {
        #expect(throws: AgentTaskDiscoveryReportError.unsupportedContractVersion) {
            _ = try AgentTaskDiscoveryReport(
                contractVersion: PineAdapterContractVersion(major: 99, minor: 0),
                agentID: try AgentID(validating: "codex"),
                environmentProvenance: .inheritedPineProcess,
                executableIdentity: .unknown,
                executableVersion: .unknown,
                transport: .unknown,
                authentication: .unknown
            )
        }
    }

    @Test func loginFlowsAreOfferedOnlyWhenDeclaredByTheAdapter() throws {
        let declared = try readyBase()
        let agentID = try AgentID(validating: "codex")
        let browserRequest = AgentLoginFlowRequest(agentID: agentID, flow: .browser)
        #expect(!browserRequest.isSupported(by: declared))

        let withFlows = try AgentTaskDiscoveryReport(
            contractVersion: AgentTaskExecutionContract.currentVersion,
            agentID: agentID,
            environmentProvenance: .inheritedPineProcess,
            executableIdentity: .resolved(resolvedPath),
            executableVersion: .supported(try DetectedVendorVersion("1.2.3")),
            transport: .negotiated(
                transport: .ownedStandardIO, capabilities: try negotiatedProfile()
            ),
            authentication: .authenticated(origin: .inheritNative, accountLabel: nil),
            supportedLoginFlows: [.browser, .device]
        )
        #expect(browserRequest.isSupported(by: withFlows))
        #expect(AgentLoginFlowRequest(agentID: agentID, flow: .native).isSupported(by: withFlows) == false)
        // A flow declared for one agent is not offered to another.
        let kimiID = try AgentID(validating: "kimi")
        #expect(AgentLoginFlowRequest(agentID: kimiID, flow: .browser).isSupported(by: withFlows) == false)
        #expect(throws: AgentTaskDiscoveryReportError.loginFlowsWithoutNegotiatedTransport) {
            _ = try report(loginFlows: [.native])
        }
    }

    @Test func accountLabelIsOptionalRedactedMetadataAndUnknownStaysUnknown() throws {
        let withoutLabel = try report(
            identity: .resolved(resolvedPath),
            authentication: .authenticated(origin: nil, accountLabel: nil)
        )
        #expect(!withoutLabel.readiness.isReady)

        let label = try AgentAccountLabel("jdo***@example.com")
        let withLabel = try report(
            identity: .resolved(resolvedPath),
            version: .supported(try DetectedVendorVersion("1.2.3")),
            transport: .negotiated(
                transport: .ownedStandardIO, capabilities: try negotiatedProfile()
            ),
            authentication: .authenticated(origin: .inheritNative, accountLabel: label)
        )
        #expect(withLabel.readiness.isReady)
        #expect(withLabel.authentication == .authenticated(origin: .inheritNative, accountLabel: label))
        #expect(label.description == "jdo***@example.com")

        #expect(throws: AdapterValueError.self) {
            _ = try AgentAccountLabel(String(repeating: "a", count: 129))
        }
        #expect(throws: AdapterValueError.self) {
            _ = try AgentAccountLabel("bad\0label")
        }
    }

    @Test func environmentProvenanceRoundTripsWhenExplicitlyProvided() throws {
        let gui = try report(
            identity: .resolved(resolvedPath),
            environment: .inheritedPineProcess
        )
        let server = try report(
            identity: .resolved(resolvedPath),
            environment: .explicitExternal
        )
        #expect(gui.environmentProvenance == .inheritedPineProcess)
        #expect(server.environmentProvenance == .explicitExternal)
        #expect(gui.readiness.blockers.isEmpty)
    }

    @Test func duplicateBlockersCollapseToOne() throws {
        let transport = AgentTaskDiscoveryReport.TransportObservation.negotiated(
            transport: .ownedStandardIO, capabilities: try negotiatedProfile()
        )
        let readiness = try report(
            identity: .resolved(resolvedPath),
            version: .supported(try DetectedVendorVersion("1.2.3")),
            transport: transport,
            authentication: .loginRequired,
            sessionStart: .failed(.loginRequired)
        ).readiness
        #expect(!readiness.isReady)
        #expect(readiness.blockers == [.loginRequired])
    }

    @Test func effectiveSettingsAreConfirmedRejectionFallbackOrUnknown() throws {
        let withObservations = try readyBase(
            effectiveModel: .confirmed("gpt-5.xhigh"),
            effectiveReasoningEffort: .rejected("effort not supported by this account"),
            effectivePermissions: .fallback("default")
        )
        #expect(withObservations.effectiveModel == .confirmed("gpt-5.xhigh"))
        #expect(withObservations.effectiveReasoningEffort == .rejected("effort not supported by this account"))
        #expect(withObservations.effectivePermissions == .fallback("default"))
        #expect(withObservations.readiness.isReady)

        let unobserved = try readyBase()
        #expect(unobserved.effectiveModel == .unknown)
        #expect(unobserved.effectiveReasoningEffort == .unknown)
        #expect(unobserved.effectivePermissions == .unknown)
    }

    @Test func effectiveSettingsCannotBeConfirmedWithoutAResolvedExecutable() throws {
        #expect(throws: AgentTaskDiscoveryReportError.effectiveSettingWithoutExecutable) {
            _ = try report(effectiveModel: .confirmed("gpt-5.xhigh"))
        }
        #expect(throws: AdapterValueError.self) {
            _ = try report(
                identity: .resolved(resolvedPath),
                effectiveModel: .confirmed(String(repeating: "m", count: 129))
            )
        }
    }
}
