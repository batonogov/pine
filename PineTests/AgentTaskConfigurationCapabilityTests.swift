import Testing
@testable import Pine

struct AgentTaskConfigurationCapabilityTests {
    @Test func missingEvidenceIsUnknownNotUnsupported() {
        let capabilities = AgentTaskConfigurationCapabilities.unknown
        for key in AgentTaskConfigurationSettingKey.allCases {
            #expect(capabilities[key].key == key)
            #expect(capabilities[key].state == .unknown)
            #expect(capabilities[key].state != .unsupported)
            #expect(capabilities[key].overridableScopes.isEmpty)
            #expect(capabilities[key].enumeratedOptions.isEmpty)
            #expect(!capabilities[key].effectiveReadback)
        }
    }

    @Test func transportEvidencePrecedesVersionFloorThenUnknown() throws {
        let documentedModel = try AgentTaskConfigurationCapability(
            key: .model, state: .researched, overridableScopes: [.process]
        )
        let observedModel = try AgentTaskConfigurationCapability(
            key: .model, state: .probed, overridableScopes: [.session], effectiveReadback: true
        )
        let documentedEffort = try AgentTaskConfigurationCapability(
            key: .reasoningEffort, state: .researched, overridableScopes: [.session]
        )
        let capabilities = try AgentTaskConfigurationCapabilities(
            transportAdvertised: [observedModel],
            versionFloor: [documentedModel, documentedEffort]
        )
        #expect(capabilities.model == observedModel)
        #expect(capabilities.reasoningEffort == documentedEffort)
        #expect(capabilities.permissions.state == .unknown)
    }

    @Test func nativeOptionSemanticsAndSupportedReadbackAreRetained() throws {
        let option = try AgentTaskConfigurationCapability.Option(
            nativeValue: "openai/gpt-6.1-sol/xhigh",
            title: "Extra high",
            detail: "Provider-specific reasoning variant"
        )
        let capability = try AgentTaskConfigurationCapability(
            key: .reasoningEffort,
            state: .supported,
            overridableScopes: [.session, .directory, .process, .account],
            enumeratedOptions: [option],
            effectiveReadback: true
        )
        #expect(capability.enumeratedOptions == [option])
        #expect(option.nativeValue == "openai/gpt-6.1-sol/xhigh")
        #expect(option.title == "Extra high")
        #expect(option.detail == "Provider-specific reasoning variant")
        #expect(capability.effectiveReadback)
    }

    @Test func supportedRequiresEffectiveReadbackVerification() throws {
        #expect(throws: AgentTaskConfigurationCapabilityError.supportedWithoutEffectiveReadback) {
            _ = try AgentTaskConfigurationCapability(
                key: .model, state: .supported, effectiveReadback: false
            )
        }
    }

    @Test func namedSlotsRejectMismatchedSettingKeys() throws {
        let effort = try AgentTaskConfigurationCapability(key: .reasoningEffort, state: .probed)
        #expect(throws: AgentTaskConfigurationCapabilityError.mismatchedSetting(
            expected: .model, actual: .reasoningEffort
        )) {
            _ = try AgentTaskConfigurationCapabilities(model: effort)
        }
    }

    @Test func globalOverridesAndAmbiguousEvidenceAreRejected() throws {
        #expect(throws: AgentTaskConfigurationCapabilityError.globalScopeForbidden) {
            _ = try AgentTaskConfigurationCapability(
                key: .model, state: .probed, overridableScopes: [.global]
            )
        }
        let first = try AgentTaskConfigurationCapability(key: .model, state: .researched)
        let second = try AgentTaskConfigurationCapability(key: .model, state: .probed)
        #expect(throws: AgentTaskConfigurationCapabilityError.duplicateSetting(.model)) {
            _ = try AgentTaskConfigurationCapabilities(transportAdvertised: [first, second])
        }
    }
}
