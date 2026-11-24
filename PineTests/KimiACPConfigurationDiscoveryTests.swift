import Foundation
import Testing
@testable import Pine

/// Fail-closed capability truth for the pinned Kimi Code CLI 2.6.2 ACP
/// adapter (#1765): the version floor is researched (documented at the pin,
/// re-probed auth-gated), an observed session-setup `configOptions` array
/// promotes the mapped options to probed, and unknown IDs, non-select types,
/// and malformed payloads never manufacture a capability.
struct KimiACPConfigurationDiscoveryTests {
    private let executable = URL(fileURLWithPath: "/opt/homebrew/bin/kimi", isDirectory: false)
    private var input: KimiACPConfigurationDiscovery.Input {
        .init(selectedExecutable: executable, environmentProvenance: .inheritedPineProcess)
    }

    private var fixtureOptions: AgentEventJSON {
        .array([
            .object([
                "id": .string("model"), "name": .string("Model"),
                "type": .string("select"), "currentValue": .string("kimi-code/kimi-for-coding"),
                "options": .array([
                    .object([
                        "value": .string("kimi-code/kimi-for-coding"),
                        "name": .string("Kimi for Coding"),
                        "description": .string("Native model"),
                    ]),
                    .object(["value": .string("kimi-code/kimi-for-reasoning"), "name": .string("Kimi for Reasoning")]),
                ]),
            ]),
            .object([
                "id": .string("thinking"), "name": .string("Thinking"),
                "type": .string("select"), "currentValue": .string("high"),
                "options": .array([
                    .object(["value": .string("low"), "name": .string("Low")]),
                    .object(["value": .string("high"), "name": .string("High")]),
                ]),
            ]),
            // The Kimi session permission mode (ask / never-ask / plan),
            // never a primary agent: it maps to .permissions.
            .object([
                "id": .string("mode"), "name": .string("Session Mode"),
                "type": .string("select"), "currentValue": .string("ask"),
                "options": .array([
                    .object(["value": .string("ask"), "name": .string("Ask")]),
                    .object(["value": .string("neverAsk"), "name": .string("Never Ask")]),
                ]),
            ]),
            // Unknown future types are parsed, retained, and never mapped.
            .object([
                "id": .string("future"), "name": .string("Future"),
                "type": .string("pine_future_type"), "currentValue": .string("x"),
            ]),
        ])
    }

    @Test func absentOptionsKeepTheDocumentedResearchFloor() throws {
        for options in [AgentEventJSON?.none, AgentEventJSON.null, AgentEventJSON.array([])] {
            let capabilities = try KimiACPConfigurationDiscovery.configurationCapabilities(
                sessionConfigOptions: options
            )
            #expect(capabilities.model.state == .researched)
            #expect(capabilities.reasoningEffort.state == .researched)
            #expect(capabilities.permissions.state == .researched)
            #expect(capabilities.model.overridableScopes.isEmpty)
        }
    }

    @Test func observedSessionOptionsBecomeProbedWithEffectiveReadback() throws {
        let capabilities = try KimiACPConfigurationDiscovery.configurationCapabilities(
            sessionConfigOptions: fixtureOptions
        )
        #expect(capabilities.model.state == .probed)
        #expect(capabilities.reasoningEffort.state == .probed)
        #expect(capabilities.permissions.state == .probed)
        #expect(capabilities.model.effectiveReadback)
        #expect(capabilities.model.enumeratedOptions.map(\.nativeValue)
                == ["kimi-code/kimi-for-coding", "kimi-code/kimi-for-reasoning"])
        #expect(capabilities.model.enumeratedOptions[0].title == "Kimi for Coding")
        #expect(capabilities.model.enumeratedOptions[0].detail == "Native model")
        #expect(capabilities.permissions.enumeratedOptions.map(\.nativeValue) == ["ask", "neverAsk"])
        let effective = try KimiACPConfigurationDiscovery.effectiveSettings(
            sessionConfigOptions: fixtureOptions
        )
        #expect(effective.model == .confirmed("kimi-code/kimi-for-coding"))
        #expect(effective.reasoningEffort == .confirmed("high"))
        #expect(effective.permissions == .confirmed("ask"))
    }

    @Test func nonSelectAndUnknownTypesAreSkippedNeverMapped() throws {
        let options = AgentEventJSON.array([
            .object([
                "id": .string("model"), "name": .string("Model"),
                "type": .string("boolean"), "currentValue": .bool(true),
            ]),
            .object([
                "id": .string("thinking"), "name": .string("Thinking"),
                "type": .string("select"), "currentValue": .bool(true),
            ]),
            .object([
                "id": .string("mode"), "name": .string("Session Mode"),
                "type": .string("pine_future_type"), "currentValue": .string("ask"),
            ]),
        ])
        let capabilities = try KimiACPConfigurationDiscovery.configurationCapabilities(
            sessionConfigOptions: options
        )
        #expect(capabilities.model.state == .researched)
        #expect(capabilities.reasoningEffort.state == .researched)
        #expect(capabilities.permissions.state == .researched)
    }

    @Test func duplicateMappedOptionFailsClosed() {
        let options = AgentEventJSON.array([
            .object([
                "id": .string("model"), "name": .string("A"), "type": .string("select"),
                "currentValue": .string("a"),
                "options": .array([.object(["value": .string("a"), "name": .string("A")])]),
            ]),
            .object([
                "id": .string("model"), "name": .string("B"), "type": .string("select"),
                "currentValue": .string("b"),
                "options": .array([.object(["value": .string("b"), "name": .string("B")])]),
            ]),
        ])
        #expect(throws: KimiACPWireError.self) {
            _ = try KimiACPConfigurationDiscovery.configurationCapabilities(
                sessionConfigOptions: options
            )
        }
    }

    @Test func oversizedOptionListFailsClosed() throws {
        let options = (0...32).map { index in
            AgentEventJSON.object(["id": .string("x\(index)"), "type": .string("select")])
        }
        #expect(throws: KimiACPWireError.capacity) {
            _ = try KimiACPConfigurationDiscovery.configurationCapabilities(
                sessionConfigOptions: .array(options)
            )
        }
    }

    @Test func reportAttributesObservationsOnlyWithAResolvedExecutable() throws {
        let attributed = try KimiACPConfigurationDiscovery.report(
            input: input,
            requiresAuthentication: true,
            sessionConfigOptions: fixtureOptions,
            sessionStarted: true
        )
        #expect(attributed.executableIdentity == .resolved(executable))
        #expect(attributed.executableVersion == .supported(
            try DetectedVendorVersion(KimiACPCapabilities.pinnedCLIVersion)
        ))
        #expect(attributed.transport
                == .negotiated(transport: .ownedStandardIO, capabilities: try KimiACPSession.profile()))
        #expect(attributed.authentication
                == .authenticated(origin: .inheritNative, accountLabel: nil))
        #expect(attributed.effectiveModel == .confirmed("kimi-code/kimi-for-coding"))
        #expect(attributed.sessionStart == .started)
        #expect(attributed.configurationCapabilities.model.state == .probed)

        // Without the launch-boundary input the session cannot attribute the
        // observation to an executable: identity, version, transport, and
        // effective values stay unknown even though options were observed.
        // The shared model likewise forbids authentication evidence without
        // an attributed identity, so the unattributed input reports none.
        let unattributed = try KimiACPConfigurationDiscovery.report(
            input: nil,
            requiresAuthentication: false,
            sessionConfigOptions: fixtureOptions,
            sessionStarted: true
        )
        #expect(unattributed.executableIdentity == .unknown)
        #expect(unattributed.executableVersion == .unknown)
        #expect(unattributed.transport == .unknown)
        #expect(unattributed.effectiveModel == .unknown)
        #expect(unattributed.effectivePermissions == .unknown)
        #expect(unattributed.configurationCapabilities.model.state == .probed)
    }

    @Test func agentWithoutManagedAccountReportsNoAuthentication() throws {
        let report = try KimiACPConfigurationDiscovery.report(
            input: input, requiresAuthentication: false, sessionStarted: true
        )
        #expect(report.authentication == .unknown)
    }

    // MARK: - Session wiring

    @Test func sessionStartProducesTheDiscoveryReportFromObservedOptions() async throws {
        let fixture = try await KimiTestFixture.make(
            options: KimiFixtureOptions(discovery: input),
            ingest: { _ in .accepted }
        )
        defer { await fixture.session.stop(deadline: .now.advanced(by: .seconds(2))) }
        try await fixture.session.start()
        let report = await fixture.concrete.discoveryReport
        #expect(report != nil)
        #expect(report?.sessionStart == .started)
        #expect(report?.configurationCapabilities.model.state == .researched)
        // The fixture session/new advertises only `mode` (select) and an
        // unknown future type: permissions promotes, the rest keeps the floor.
        #expect(report?.configurationCapabilities.permissions.state == .probed)
        #expect(report?.configurationCapabilities.reasoningEffort.state == .researched)
        #expect(report?.effectivePermissions == .confirmed("ask"))
        #expect(report?.executableIdentity == .resolved(executable))
    }
}
