import Foundation
import Testing
@testable import Pine

/// Unit-level presentation contract for the contextual "How to run" surface
/// (#1765): the report projects to confirmed native values, inherited
/// agent-settings states, or honest "the CLI controls this" rows — never a
/// fabricated selection.
struct AgentTaskHowToRunTests {
    private let resolvedPath = URL(fileURLWithPath: "/usr/local/bin/agent", isDirectory: false)

    private func profile() throws -> AdapterCapabilityProfile {
        try AdapterCapabilityProfile(
            transport: .ownedStandardIO,
            lifecycle: AdapterLifecycleCapabilities(
                signals: [.init(scope: .session, phase: .settled)], evidence: []
            ),
            delivery: AdapterDeliverySemantics(ordering: .ordered, minimumAuthentication: .ownedChildPipe)
        )
    }

    private func report(
        model: AgentTaskConfigurationCapability,
        reasoningEffort: AgentTaskConfigurationCapability,
        permissions: AgentTaskConfigurationCapability,
        effectiveModel: AgentTaskEffectiveSettingObservation = .unknown,
        effectiveReasoningEffort: AgentTaskEffectiveSettingObservation = .unknown,
        effectivePermissions: AgentTaskEffectiveSettingObservation = .unknown,
        authentication: AgentTaskDiscoveryReport.AuthenticationObservation = .unknown,
        version: AgentTaskDiscoveryReport.ExecutableVersionObservation = .unknown
    ) throws -> AgentTaskDiscoveryReport {
        try AgentTaskDiscoveryReport(
            contractVersion: AgentTaskExecutionContract.currentVersion,
            agentID: try AgentID(validating: "opencode"),
            environmentProvenance: .inheritedPineProcess,
            executableIdentity: .resolved(resolvedPath),
            executableVersion: version,
            transport: .negotiated(transport: .ownedStandardIO, capabilities: try profile()),
            authentication: authentication,
            sessionStart: .started,
            configurationCapabilities: try AgentTaskConfigurationCapabilities(
                model: model, reasoningEffort: reasoningEffort, permissions: permissions
            ),
            effectiveModel: effectiveModel,
            effectiveReasoningEffort: effectiveReasoningEffort,
            effectivePermissions: effectivePermissions
        )
    }

    private func capability(
        _ key: AgentTaskConfigurationSettingKey, _ state: AgentTaskConfigurationCapability.State
    ) throws -> AgentTaskConfigurationCapability {
        try AgentTaskConfigurationCapability(
            key: key, state: state,
            effectiveReadback: state == .supported
        )
    }

    @Test func absentReportProjectsToNoLines() {
        #expect(AgentTaskHowToRun.lines(report: nil).isEmpty)
    }

    @Test func confirmedEffectiveValuesProjectToNativeLabels() throws {
        let report = try report(
            model: try capability(.model, .probed),
            reasoningEffort: try capability(.reasoningEffort, .probed),
            permissions: try capability(.permissions, .probed),
            effectiveModel: .confirmed("openai/gpt-6.1-sol"),
            effectiveReasoningEffort: .confirmed("xhigh"),
            effectivePermissions: .confirmed("ask"),
            version: .supported(DetectedVendorVersion("2.3.2"))
        )
        let lines = AgentTaskHowToRun.lines(report: report)
        #expect(lines.map(\.kind) == [.agent, .account, .model, .reasoningEffort, .permissions])
        #expect(lines[0].agentVersion == "2.3.2")
        #expect(lines[2].setting == .confirmed("openai/gpt-6.1-sol"))
        #expect(lines[3].setting == .confirmed("xhigh"))
        #expect(lines[4].setting == .confirmed("ask"))
        #expect(lines[1].account == .unknown)
    }

    @Test func observedButUnconfirmedSettingsProjectToAgentSettings() throws {
        let report = try report(
            model: try capability(.model, .probed),
            reasoningEffort: try capability(.reasoningEffort, .researched),
            permissions: try capability(.permissions, .supported)
        )
        let lines = AgentTaskHowToRun.lines(report: report)
        #expect(lines[2].setting == .agentSettings)
        #expect(lines[3].setting == .agentSettings)
        #expect(lines[4].setting == .agentSettings)
    }

    @Test func unknownOrUnsupportedCapabilitiesProjectToCLIControls() throws {
        let report = try report(
            model: try capability(.model, .unknown),
            reasoningEffort: try capability(.reasoningEffort, .unsupported),
            permissions: try capability(.permissions, .unknown)
        )
        let lines = AgentTaskHowToRun.lines(report: report)
        #expect(lines[2].setting == .cliControls)
        #expect(lines[3].setting == .cliControls)
        #expect(lines[4].setting == .cliControls)
    }

    @Test func accountObservationsProjectTruthfully() throws {
        for (authentication, expected) in [
            (.unknown as AgentTaskDiscoveryReport.AuthenticationObservation,
             AgentTaskHowToRunLine.AccountObservation.unknown),
            (.loginRequired, .loginRequired),
            (.accountUnavailable, .accountUnavailable),
            (.expiredCredentials, .expiredCredentials),
            (.authenticated(origin: .inheritNative, accountLabel: nil),
             .authenticated(label: nil)),
            (.authenticated(
                origin: .inheritNative,
                accountLabel: try AgentAccountLabel("redacted@example.com")),
             .authenticated(label: "redacted@example.com")),
        ] {
            let report = try report(
                model: try capability(.model, .researched),
                reasoningEffort: try capability(.reasoningEffort, .researched),
                permissions: try capability(.permissions, .researched),
                authentication: authentication
            )
            let lines = AgentTaskHowToRun.lines(report: report)
            #expect(lines[1].account == expected, "\(expected)")
        }
    }

    @Test func unconfirmedVersionProjectsToNilAgentVersion() throws {
        let report = try report(
            model: try capability(.model, .researched),
            reasoningEffort: try capability(.reasoningEffort, .researched),
            permissions: try capability(.permissions, .researched)
        )
        let lines = AgentTaskHowToRun.lines(report: report)
        #expect(lines[0].agentVersion == nil)
    }
}
