import Foundation
import Testing
@testable import Pine

struct OpenCodeACPConfigurationDiscoveryTests {
    private let executable = URL(fileURLWithPath: "/opt/homebrew/bin/opencode", isDirectory: false)

    private func admission(version: String = OpenCodeACPSession.pinnedVersion) throws -> AdapterProbeResult {
        try AdapterProbeResult(
            detectedVendorVersion: DetectedVendorVersion(version),
            detectedSchema: nil,
            offeredProfiles: [OpenCodeACPSession.profile()],
            offeredContractVersions: PineAdapterContractVersionRange(
                minimum: .init(major: 1, minor: 1), maximum: .init(major: 1, minor: 1)
            )
        )
    }

    @Test func versionProbeAndFactoryAdmissionAloneLeaveSettingsUnknown() throws {
        let version = try DetectedVendorVersion(OpenCodeACPSession.pinnedVersion)
        let report = try OpenCodeACPConfigurationDiscovery.report(
            selectedExecutable: executable,
            versionProbe: version,
            factoryAdmission: admission()
        )
        #expect(report.executableVersion == .supported(version))
        #expect(report.configurationCapabilities == .unknown)
        #expect(report.sessionStart == .notAttempted)
        #expect(report.readiness.unconfirmed == [.authentication])
    }

    @Test func pinnedSessionOptionsBecomeProbedNativeSessionCapabilities() throws {
        let options = AgentEventJSON.array([
            .object([
                "id": .string("model"), "name": .string("Model"),
                "category": .string("model"), "type": .string("select"),
                "currentValue": .string("openai/gpt-6.1-sol"),
                "options": .array([
                    .object([
                        "value": .string("openai/gpt-6.1-sol"), "name": .string("GPT 6.1 Sol"),
                        "description": .string("Native model detail"),
                    ]),
                ]),
            ]),
            .object([
                "id": .string("effort"), "name": .string("Reasoning effort"),
                "category": .string("thought_level"), "type": .string("select"),
                "currentValue": .string("xhigh"),
                "options": .array([
                    .object([
                        "group": .string("variants"), "name": .string("Variants"),
                        "options": .array([
                            .object(["value": .string("default"), "name": .string("Default")]),
                            .object([
                                "value": .string("xhigh"), "name": .string("Extra high"),
                                "description": .string("OpenCode reasoning variant"),
                            ]),
                        ]),
                    ]),
                ]),
            ]),
            // OpenCode mode is a primary agent, never a permissions override.
            .object([
                "id": .string("mode"), "name": .string("Primary agent"),
                "category": .string("mode"), "type": .string("select"),
                "currentValue": .string("build"),
                "options": .array([.object(["value": .string("build"), "name": .string("Build")])]),
            ]),
        ])
        let report = try OpenCodeACPConfigurationDiscovery.report(
            selectedExecutable: executable,
            versionProbe: DetectedVendorVersion(OpenCodeACPSession.pinnedVersion),
            factoryAdmission: admission(),
            sessionConfigOptions: options,
            sessionStarted: true
        )
        #expect(report.sessionStart == .started)
        #expect(report.configurationCapabilities.model.state == .probed)
        #expect(report.configurationCapabilities.reasoningEffort.state == .probed)
        #expect(report.configurationCapabilities.permissions.state == .unknown)
        #expect(report.configurationCapabilities.model.overridableScopes == [.session])
        #expect(report.configurationCapabilities.model.effectiveReadback)
        #expect(report.configurationCapabilities.model.enumeratedOptions.map(\.nativeValue) == [
            "openai/gpt-6.1-sol",
        ])
        #expect(report.configurationCapabilities.reasoningEffort.enumeratedOptions.map(\.nativeValue) == [
            "default", "xhigh",
        ])
        #expect(report.configurationCapabilities.reasoningEffort.enumeratedOptions[1].title == "Extra high")
        #expect(report.configurationCapabilities.reasoningEffort.enumeratedOptions[1].detail ==
                "OpenCode reasoning variant")
        #expect(report.effectiveModel == .unknown)
        #expect(report.effectiveReasoningEffort == .unknown)
    }

    @Test func absentOrEmptyOptionsAreUnknownRatherThanUnsupported() throws {
        let empty = try OpenCodeACPConfigurationDiscovery.configurationCapabilities(
            admitted: true, sessionConfigOptions: .array([])
        )
        let missing = try OpenCodeACPConfigurationDiscovery.configurationCapabilities(
            admitted: true, sessionConfigOptions: nil
        )
        #expect(empty == .unknown)
        #expect(missing == .unknown)
    }

    @Test func missingNullAndNonStringCategoriesStayUnknown() throws {
        let categories: [AgentEventJSON?] = [nil, .null, .number("1")]
        for category in categories {
            var option: [String: AgentEventJSON] = [
                "id": .string("model"), "name": .string("Model"), "type": .string("select"),
                "currentValue": .string("native/model"),
                "options": .array([
                    .object(["value": .string("native/model"), "name": .string("Native model")]),
                ]),
            ]
            option["category"] = category
            let capabilities = try OpenCodeACPConfigurationDiscovery.configurationCapabilities(
                admitted: true, sessionConfigOptions: .array([.object(option)])
            )
            #expect(capabilities == .unknown)
        }
    }

    @Test func wrongStringCategoryStaysUnknown() throws {
        // A wrong string category must not promote to probed either: model
        // under thought_level and effort under model are both unknown.
        for (id, category) in [("model", "thought_level"), ("thought_level", "model")] {
            let option = AgentEventJSON.object([
                "id": .string(id), "name": .string("Option"), "type": .string("select"),
                "category": .string(category), "currentValue": .string("native/\(id)"),
                "options": .array([
                    .object(["value": .string("native/\(id)"), "name": .string("Native")]),
                ]),
            ])
            let capabilities = try OpenCodeACPConfigurationDiscovery.configurationCapabilities(
                admitted: true, sessionConfigOptions: .array([option])
            )
            #expect(capabilities == .unknown)
        }
    }

    @Test func groupedOptionsCannotBypassAggregateBound() throws {
        let leaves = (0..<128).map { index in
            AgentEventJSON.object([
                "value": .string("model-\(index)"), "name": .string("Model \(index)"),
            ])
        }
        let groups = (0..<2).map { index in
            AgentEventJSON.object([
                "group": .string("group-\(index)"), "name": .string("Group \(index)"),
                "options": .array(leaves),
            ])
        }
        let option = AgentEventJSON.object([
            "id": .string("model"), "name": .string("Model"),
            "category": .string("model"), "type": .string("select"),
            "currentValue": .string("model-0"), "options": .array(groups),
        ])
        #expect(throws: OpenCodeACPError.capacity) {
            _ = try OpenCodeACPConfigurationDiscovery.configurationCapabilities(
                admitted: true, sessionConfigOptions: .array([option])
            )
        }
    }

    @Test func unpinnedVersionOrMissingAdmissionCannotPromoteOptions() throws {
        let options = AgentEventJSON.array([
            .object([
                "id": .string("model"), "name": .string("Model"),
                "category": .string("model"), "type": .string("select"),
                "currentValue": .string("native/model"),
                "options": .array([
                    .object(["value": .string("native/model"), "name": .string("Native model")]),
                ]),
            ]),
        ])
        let oldVersion = try DetectedVendorVersion("2.3.1")
        let oldReport = try OpenCodeACPConfigurationDiscovery.report(
            selectedExecutable: executable,
            versionProbe: oldVersion,
            factoryAdmission: admission(version: "2.3.1"),
            sessionConfigOptions: options,
            sessionStarted: true
        )
        #expect(oldReport.executableVersion == .unsupported(oldVersion))
        #expect(oldReport.configurationCapabilities == .unknown)
        let unadmitted = try OpenCodeACPConfigurationDiscovery.report(
            selectedExecutable: executable,
            versionProbe: DetectedVendorVersion(OpenCodeACPSession.pinnedVersion),
            factoryAdmission: nil,
            sessionConfigOptions: options,
            sessionStarted: true
        )
        #expect(unadmitted.configurationCapabilities == .unknown)
        #expect(unadmitted.sessionStart == .notAttempted)
    }
}
