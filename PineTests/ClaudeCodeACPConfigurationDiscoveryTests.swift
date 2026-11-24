import Foundation
import Testing
@testable import Pine

/// Fail-closed capability truth for the pinned
/// `@agentclientprotocol/claude-agent-acp` 0.109.1 adapter (#1765): the
/// version floor is researched (source-reviewed at the pin), an observed
/// session-setup `configOptions` array promotes the documented
/// id+category pairs to probed, and `agent`/`fast_mode`/`ultracode` options
/// never map to a Pine setting.
struct ClaudeCodeACPConfigurationDiscoveryTests {
    private let executable = URL(fileURLWithPath: "/opt/homebrew/bin/claude-agent-acp", isDirectory: false)
    private var input: ClaudeCodeACPConfigurationDiscovery.Input {
        .init(selectedExecutable: executable, environmentProvenance: .inheritedPineProcess)
    }

    private var fixtureOptions: AgentEventJSON {
        .array([
            .object([
                "id": .string("model"), "name": .string("Model"),
                "description": .string("AI model to use"),
                "category": .string("model"), "type": .string("select"),
                "currentValue": .string("default"),
                "options": .array([
                    .object(["value": .string("default"), "name": .string("Default")]),
                    .object([
                        "value": .string("sonnet"), "name": .string("Sonnet"),
                        "description": .string("Balanced"),
                    ]),
                ]),
            ]),
            .object([
                "id": .string("effort"), "name": .string("Effort"),
                "category": .string("thought_level"), "type": .string("select"),
                "currentValue": .string("default"),
                "options": .array([
                    .object(["value": .string("default"), "name": .string("Default")]),
                    .object(["value": .string("high"), "name": .string("High")]),
                ]),
            ]),
            // The session permission mode: it maps to .permissions.
            .object([
                "id": .string("mode"), "name": .string("Mode"),
                "description": .string("Session permission mode"),
                "category": .string("mode"), "type": .string("select"),
                "currentValue": .string("auto"),
                "options": .array([
                    .object(["value": .string("default"), "name": .string("Manual")]),
                    .object(["value": .string("auto"), "name": .string("Auto")]),
                ]),
            ]),
            // Not a Pine setting: never mapped.
            .object([
                "id": .string("agent"), "name": .string("Agent"),
                "type": .string("select"), "currentValue": .string("default"),
                "options": .array([.object(["value": .string("default"), "name": .string("Default")])]),
            ]),
            .object([
                "id": .string("fast_mode"), "name": .string("Fast mode"),
                "type": .string("boolean"), "currentValue": .bool(false),
            ]),
        ])
    }

    @Test func absentOptionsKeepTheDocumentedResearchFloor() throws {
        for options in [AgentEventJSON?.none, AgentEventJSON.null, AgentEventJSON.array([])] {
            let capabilities = try ClaudeCodeACPConfigurationDiscovery.configurationCapabilities(
                sessionConfigOptions: options
            )
            #expect(capabilities.model.state == .researched)
            #expect(capabilities.reasoningEffort.state == .researched)
            #expect(capabilities.permissions.state == .researched)
            #expect(capabilities.model.overridableScopes.isEmpty)
        }
    }

    @Test func observedSetupOptionsBecomeProbedWithEffectiveReadback() throws {
        let capabilities = try ClaudeCodeACPConfigurationDiscovery.configurationCapabilities(
            sessionConfigOptions: fixtureOptions
        )
        #expect(capabilities.model.state == .probed)
        #expect(capabilities.reasoningEffort.state == .probed)
        #expect(capabilities.permissions.state == .probed)
        #expect(capabilities.model.effectiveReadback)
        #expect(capabilities.model.enumeratedOptions.map(\.nativeValue) == ["default", "sonnet"])
        #expect(capabilities.model.enumeratedOptions[1].detail == "Balanced")
        #expect(capabilities.reasoningEffort.enumeratedOptions.map(\.nativeValue)
                == ["default", "high"])
        let effective = try ClaudeCodeACPConfigurationDiscovery.effectiveSettings(
            sessionConfigOptions: fixtureOptions
        )
        #expect(effective.model == .confirmed("default"))
        #expect(effective.reasoningEffort == .confirmed("default"))
        #expect(effective.permissions == .confirmed("auto"))
    }

    @Test func idAndCategoryMustBothMatchTheDocumentedPair() throws {
        // model under thought_level, effort under model, mode without its
        // category: none of these promote a Pine setting.
        for (id, category) in [("model", "thought_level"), ("effort", "model"),
                               ("mode", nil), ("agent", "mode")] {
            var fields: [String: AgentEventJSON] = [
                "id": .string(id), "name": .string("Option"), "type": .string("select"),
                "currentValue": .string("v"),
                "options": .array([.object(["value": .string("v"), "name": .string("V")])]),
            ]
            if let category { fields["category"] = .string(category) }
            let capabilities = try ClaudeCodeACPConfigurationDiscovery.configurationCapabilities(
                sessionConfigOptions: .array([.object(fields)])
            )
            #expect(capabilities.model.state == .researched)
            #expect(capabilities.reasoningEffort.state == .researched)
            #expect(capabilities.permissions.state == .researched)
        }
    }

    @Test func duplicateMappedOptionFailsClosed() {
        let option = AgentEventJSON.object([
            "id": .string("mode"), "name": .string("Mode"), "category": .string("mode"),
            "type": .string("select"), "currentValue": .string("auto"),
            "options": .array([.object(["value": .string("auto"), "name": .string("Auto")])]),
        ])
        #expect(throws: ClaudeCodeACPError.self) {
            _ = try ClaudeCodeACPConfigurationDiscovery.configurationCapabilities(
                sessionConfigOptions: .array([option, option])
            )
        }
    }

    @Test func reportAttributesObservationsOnlyWithAResolvedExecutable() throws {
        let attributed = try ClaudeCodeACPConfigurationDiscovery.report(
            input: input,
            sessionConfigOptions: fixtureOptions,
            sessionStarted: true
        )
        #expect(attributed.executableIdentity == .resolved(executable))
        #expect(attributed.executableVersion == .supported(
            try DetectedVendorVersion(ClaudeCodeACPSession.pinnedVersion)
        ))
        #expect(attributed.transport
                == .negotiated(transport: .ownedStandardIO,
                               capabilities: try ClaudeCodeACPSession.profile()))
        // The adapter's auth pushes carry no Pine authentication evidence.
        #expect(attributed.authentication == .unknown)
        #expect(attributed.effectiveModel == .confirmed("default"))
        #expect(attributed.effectivePermissions == .confirmed("auto"))
        #expect(attributed.sessionStart == .started)

        let unattributed = try ClaudeCodeACPConfigurationDiscovery.report(
            input: nil,
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
}
