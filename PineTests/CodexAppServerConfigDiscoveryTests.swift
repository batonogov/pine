import Foundation
import Testing
@testable import Pine

/// Fail-closed capability truth for the pinned Codex 0.169.0 app-server
/// (#1765): the version floor is researched (documented at the pin), observed
/// `model/list`/`config/read` promote to probed, and every malformed
/// observation degrades back to the floor.
struct CodexAppServerConfigDiscoveryTests {
    private let executable = URL(fileURLWithPath: "/opt/homebrew/bin/codex", isDirectory: false)

    private var modelListResult: AgentEventJSON {
        .object([
            "data": .array([
                .object([
                    "id": .string("gpt-6.1-sol"),
                    "model": .string("gpt-6.1-sol"),
                    "displayName": .string("GPT 6.1 Sol"),
                    "description": .string("Native model"),
                    "hidden": .bool(false),
                    "supportedReasoningEfforts": .array([
                        .object([
                            "reasoningEffort": .string("medium"),
                            "description": .string("Balances speed and depth"),
                        ]),
                        .object(["reasoningEffort": .string("high")]),
                    ]),
                    "defaultReasoningEffort": .string("medium"),
                    "isDefault": .bool(true),
                ]),
            ]),
            "nextCursor": .null,
        ])
    }

    private var configReadResult: AgentEventJSON {
        .object([
            "config": .object([
                "model": .string("gpt-6.1-sol"),
                "model_reasoning_effort": .string("medium"),
                "approval_policy": .string("on-request"),
                "sandbox_mode": .string("workspace-write"),
            ]),
            "origins": .object([:]),
        ])
    }

    @Test func noObservationsKeepTheDocumentedResearchFloor() throws {
        let report = try CodexAppServerConfigurationDiscovery.report(
            selectedExecutable: executable,
            environmentProvenance: .inheritedPineProcess,
            accountState: .unknown
        )
        let capabilities = report.configurationCapabilities
        #expect(capabilities.model.state == .researched)
        #expect(capabilities.reasoningEffort.state == .researched)
        #expect(capabilities.permissions.state == .researched)
        #expect(capabilities.model.overridableScopes.isEmpty)
        #expect(report.effectiveModel == .unknown)
        #expect(report.effectiveReasoningEffort == .unknown)
        #expect(report.effectivePermissions == .unknown)
        #expect(report.authentication == .unknown)
        #expect(report.sessionStart == .notAttempted)
        #expect(report.executableVersion == .supported(
            try DetectedVendorVersion(CodexAppServerExecutableIdentity.supportedVersion)
        ))
    }

    @Test func observedCatalogAndConfigBecomeProbedWithEffectiveReadback() throws {
        let report = try CodexAppServerConfigurationDiscovery.report(
            selectedExecutable: executable,
            environmentProvenance: .inheritedPineProcess,
            accountState: .credentialsConfigured,
            modelList: modelListResult,
            configRead: configReadResult,
            sessionStarted: true
        )
        let capabilities = report.configurationCapabilities
        #expect(capabilities.model.state == .probed)
        #expect(capabilities.reasoningEffort.state == .probed)
        #expect(capabilities.permissions.state == .probed)
        #expect(capabilities.model.enumeratedOptions.map(\.nativeValue) == ["gpt-6.1-sol"])
        #expect(capabilities.model.enumeratedOptions.first?.title == "GPT 6.1 Sol")
        #expect(capabilities.reasoningEffort.enumeratedOptions.map(\.nativeValue) == ["medium", "high"])
        #expect(capabilities.reasoningEffort.enumeratedOptions[0].detail
                == "Balances speed and depth")
        #expect(capabilities.model.effectiveReadback)
        #expect(capabilities.reasoningEffort.effectiveReadback)
        #expect(capabilities.permissions.effectiveReadback)
        #expect(report.effectiveModel == .confirmed("gpt-6.1-sol"))
        #expect(report.effectiveReasoningEffort == .confirmed("medium"))
        #expect(report.effectivePermissions == .confirmed("on-request, sandbox workspace-write"))
        #expect(report.authentication
                == .authenticated(origin: .inheritNative, accountLabel: nil))
        #expect(report.sessionStart == .started)
        #expect(report.transport
                == .negotiated(transport: .ownedStandardIO,
                               capabilities: try CodexAppServerNativeFactory.profile()))
    }

    @Test func catalogWithoutConfigStaysProbedWithoutReadback() throws {
        let report = try CodexAppServerConfigurationDiscovery.report(
            selectedExecutable: executable,
            environmentProvenance: .inheritedPineProcess,
            accountState: .unknown,
            modelList: modelListResult
        )
        let capabilities = report.configurationCapabilities
        #expect(capabilities.model.state == .probed)
        #expect(capabilities.model.effectiveReadback == false)
        #expect(capabilities.reasoningEffort.state == .probed)
        // No config/read: the documented floor remains, no effective values.
        #expect(capabilities.permissions.state == .researched)
        #expect(report.effectiveModel == .unknown)
        #expect(report.effectiveReasoningEffort == .unknown)
        #expect(report.effectivePermissions == .unknown)
    }

    @Test func malformedObservationsDegradeBackToTheFloor() throws {
        for (modelList, configRead) in [
            (.object(["data": .object([:])]), configReadResult),
            (.array([modelListResult]), configReadResult),
            (modelListResult, .object(["config": .string("nope")])),
            (modelListResult, .string("nope")),
            (nil, .object(["config": .object(["model": .number("1")])])),
        ] {
            let capabilities = try CodexAppServerConfigurationDiscovery.configurationCapabilities(
                modelList: modelList, configRead: configRead
            )
            #expect(capabilities.model.state == .researched)
            #expect(capabilities.permissions.state == .researched)
        }
        let empty = try CodexAppServerConfigurationDiscovery.configurationCapabilities(
            modelList: .object(["data": .array([]), "nextCursor": .null]),
            configRead: nil
        )
        let expected = try AgentTaskConfigurationCapabilities(
            transportAdvertised: [], versionFloor: try CodexAppServerConfigurationDiscovery.versionFloors()
        )
        #expect(empty == expected)
    }

    @Test func granularApprovalPolicyStaysANativeLabel() throws {
        let configRead = AgentEventJSON.object([
            "config": .object([
                "approval_policy": .object(["granular": .object(["bash": .bool(true)])]),
                "sandbox_mode": .string("read-only"),
            ]),
            "origins": .object([:]),
        ])
        let effective = try CodexAppServerConfigurationDiscovery.effectiveSettings(configRead: configRead)
        #expect(effective.permissions == .confirmed("granular, sandbox read-only"))
        #expect(effective.model == .unknown)
    }

    @Test func accountStatesMapToConservativeObservations() {
        #expect(CodexAppServerConfigurationDiscovery.authentication(.signInRequired) == .loginRequired)
        #expect(CodexAppServerConfigurationDiscovery.authentication(.credentialsConfigured)
                == .authenticated(origin: .inheritNative, accountLabel: nil))
        // Configured credentials are not proof of provider authentication.
        #expect(CodexAppServerConfigurationDiscovery.authentication(.externalProviderUnverified)
                == .unknown)
        #expect(CodexAppServerConfigurationDiscovery.authentication(.unknown) == .unknown)
    }

    @Test func oversizedCatalogFailsClosed() {
        let models = (0..<65).map { index in
            AgentEventJSON.object(["id": .string("model-\(index)"), "displayName": .string("M \(index)")])
        }
        #expect(throws: CodexAppServerWireError.capacityExceeded) {
            _ = try CodexAppServerConfigurationDiscovery.modelCatalog(
                .object(["data": .array(models)])
            )
        }
    }
}
