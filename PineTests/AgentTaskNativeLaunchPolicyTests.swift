import Foundation
import Testing
@testable import Pine

struct AgentTaskNativeLaunchPolicyTests {
    @Test func inheritanceCapturesOnlyIntentAndExistingIdentities() throws {
        let taskID = UUID()
        let runID = UUID()
        let bindingID = UUID()
        let selection = AgentTaskNativeLaunchPolicy.Selection(
            agentID: try AgentID(validating: "codex"),
            selectedExecutable: URL(fileURLWithPath: "/not-installed/codex", isDirectory: false)
        )
        let result = AgentTaskNativeLaunchPolicy.evaluate(
            taskID: taskID, runID: runID, bindingID: bindingID, selection: selection,
            authenticationOrigin: .inheritNative,
            environmentProvenance: .inheritedPineProcess
        )
        guard case .eligible(let policy) = result else {
            Issue.record("Native inheritance must be representable without inspecting the executable")
            return
        }
        #expect(policy.contractVersion == AgentTaskExecutionContract.currentVersion)
        #expect(policy.taskID == taskID)
        #expect(policy.runID == runID)
        #expect(policy.bindingID == bindingID)
        #expect(policy.agentID == selection.agentID)
        #expect(policy.selectedExecutable == selection.selectedExecutable)
        #expect(policy.requestedSettings == .inheritNativeConfiguration)
        #expect(policy.model.provenance == .inherited)
        #expect(policy.reasoningEffort.provenance == .inherited)
        #expect(policy.permissions.provenance == .inherited)
        #expect(policy.model.nativeValue == nil)
        #expect(policy.model.scope == nil)
        #expect(policy.authenticationOrigin == .inheritNative)
        #expect(policy.environmentProvenance == .inheritedPineProcess)
        #expect(policy.inheritedConfigurationScopes == Set(AgentTaskNativeConfigurationScope.allCases))
    }

    @Test func missingSelectionIsBlockedAndExplicitOverrideIsEligibleWithProvenance() throws {
        let taskID = UUID()
        let runID = UUID()
        let bindingID = UUID()
        let selection = AgentTaskNativeLaunchPolicy.Selection(
            agentID: try AgentID(validating: "codex"),
            selectedExecutable: URL(fileURLWithPath: "/selected/codex", isDirectory: false)
        )
        #expect(AgentTaskNativeLaunchPolicy.evaluate(
            taskID: taskID, runID: runID, bindingID: bindingID, selection: nil,
            authenticationOrigin: .inheritNative,
            environmentProvenance: .inheritedPineProcess
        ) == .blocked(.missingSelection))

        let modelOverride = try AgentTaskNativeSettingSelection.explicit(
            nativeValue: "gpt-5.xhigh", scope: .session
        )
        guard case .eligible(let policy) = AgentTaskNativeLaunchPolicy.evaluate(
            taskID: taskID, runID: runID, bindingID: bindingID, selection: selection,
            model: modelOverride,
            authenticationOrigin: .inheritNative,
            environmentProvenance: .inheritedPineProcess
        ) else {
            Issue.record("An explicit session-scoped override must be a representable intent")
            return
        }
        #expect(policy.requestedSettings == .overrides)
        #expect(policy.model == modelOverride)
        #expect(policy.model.nativeValue == "gpt-5.xhigh")
        #expect(policy.model.scope == .session)
        #expect(policy.reasoningEffort.provenance == .inherited)
        #expect(policy.permissions.provenance == .inherited)
    }

    @Test func inheritedPolicyNeverCarriesAFabricatedSelection() {
        let selection = AgentTaskNativeSettingSelection()
        #expect(selection.provenance == .inherited)
        #expect(selection.nativeValue == nil)
        #expect(selection.scope == nil)
    }

    @Test func globalScopeIsNotARequestableOverrideScope() {
        #expect(throws: AgentTaskNativeSettingSelectionError.globalScopeForbidden) {
            _ = try AgentTaskNativeSettingSelection.explicit(nativeValue: "model", scope: .global)
        }
    }

    @Test func explicitOverridesRejectNativeValuesOutsideDisplayBounds() {
        #expect(throws: AdapterValueError.self) {
            _ = try AgentTaskNativeSettingSelection.explicit(nativeValue: "", scope: .session)
        }
        #expect(throws: AdapterValueError.self) {
            _ = try AgentTaskNativeSettingSelection.explicit(
                nativeValue: String(repeating: "m", count: 129), scope: .session
            )
        }
    }

    @Test func nonLocalOrAmbiguousExecutableSelectionsAreBlocked() throws {
        let agentID = try AgentID(validating: "codex")
        let invalidURLs = [
            "https://example.com/codex", "file://remote/bin/codex",
            "file:///bin/codex?profile=other", "file:///bin/codex#other",
            "file:///", "file:///bin/", "file:///bin/codex%00",
        ]
        for text in invalidURLs {
            let executable = try #require(URL(string: text))
            #expect(AgentTaskNativeLaunchPolicy.evaluate(
                taskID: UUID(), runID: UUID(), bindingID: UUID(),
                selection: .init(agentID: agentID, selectedExecutable: executable),
                authenticationOrigin: .inheritNative,
                environmentProvenance: .inheritedPineProcess
            ) == .blocked(.inconsistentSelection))
        }
        // PATH_MAX: an overlong path is not a representable executable identity.
        let overlong = URL(fileURLWithPath: "/bin/" + String(repeating: "a", count: 1020))
        #expect(AgentTaskNativeLaunchPolicy.evaluate(
            taskID: UUID(), runID: UUID(), bindingID: UUID(),
            selection: .init(agentID: agentID, selectedExecutable: overlong),
            authenticationOrigin: .inheritNative,
            environmentProvenance: .inheritedPineProcess
        ) == .blocked(.inconsistentSelection))
    }

    @Test func concurrentAttemptsKeepIndependentImmutableSelections() throws {
        let taskID = UUID()
        let bindingID = UUID()
        let firstRun = UUID()
        let secondRun = UUID()
        let firstSelection = AgentTaskNativeLaunchPolicy.Selection(
            agentID: try AgentID(validating: "codex"),
            selectedExecutable: URL(fileURLWithPath: "/selected/codex", isDirectory: false)
        )
        let secondSelection = AgentTaskNativeLaunchPolicy.Selection(
            agentID: try AgentID(validating: "kimi"),
            selectedExecutable: URL(fileURLWithPath: "/selected/kimi", isDirectory: false)
        )
        let first = AgentTaskNativeLaunchPolicy.evaluate(
            taskID: taskID, runID: firstRun, bindingID: bindingID, selection: firstSelection,
            authenticationOrigin: .inheritNative,
            environmentProvenance: .inheritedPineProcess
        )
        let second = AgentTaskNativeLaunchPolicy.evaluate(
            taskID: taskID, runID: secondRun, bindingID: bindingID, selection: secondSelection,
            authenticationOrigin: .inheritNative,
            environmentProvenance: .inheritedPineProcess
        )
        #expect(first != second)
        #expect(first == AgentTaskNativeLaunchPolicy.evaluate(
            taskID: taskID, runID: firstRun, bindingID: bindingID, selection: firstSelection,
            authenticationOrigin: .inheritNative,
            environmentProvenance: .inheritedPineProcess
        ))
    }

    @Test func aChangedProjectDefaultMintsNewIntentsForFutureTasksOnly() throws {
        let taskID = UUID()
        let futureTaskID = UUID()
        let bindingID = UUID()
        let selection = AgentTaskNativeLaunchPolicy.Selection(
            agentID: try AgentID(validating: "codex"),
            selectedExecutable: URL(fileURLWithPath: "/selected/codex", isDirectory: false)
        )
        let inFlight = AgentTaskNativeLaunchPolicy.evaluate(
            taskID: taskID, runID: UUID(), bindingID: bindingID, selection: selection,
            authenticationOrigin: .inheritNative,
            environmentProvenance: .inheritedPineProcess
        )
        let futureDefault = try AgentTaskNativeSettingSelection.explicit(
            nativeValue: "new-default-model", scope: .directory
        )
        let nextTask = AgentTaskNativeLaunchPolicy.evaluate(
            taskID: futureTaskID, runID: UUID(), bindingID: bindingID, selection: selection,
            model: futureDefault,
            authenticationOrigin: .inheritNative,
            environmentProvenance: .inheritedPineProcess
        )
        guard case .eligible(let inFlightPolicy) = inFlight else {
            Issue.record("In-flight intent must remain eligible")
            return
        }
        #expect(inFlightPolicy.requestedSettings == .inheritNativeConfiguration)
        #expect(nextTask != inFlight)
        guard case .eligible(let nextPolicy) = nextTask else {
            Issue.record("A changed project default must mint a new representable intent")
            return
        }
        #expect(nextPolicy.model == futureDefault)
        #expect(nextPolicy.taskID != inFlightPolicy.taskID)
        #expect(nextPolicy.runID != inFlightPolicy.runID)
    }

    @Test func launchEnvironmentAndAuthenticationProvenanceAreRecordedHonest() throws {
        let selection = AgentTaskNativeLaunchPolicy.Selection(
            agentID: try AgentID(validating: "codex"),
            selectedExecutable: URL(fileURLWithPath: "/selected/codex", isDirectory: false)
        )
        guard case .eligible(let policy) = AgentTaskNativeLaunchPolicy.evaluate(
            taskID: UUID(), runID: UUID(), bindingID: UUID(), selection: selection,
            authenticationOrigin: .launchEnvironment,
            environmentProvenance: .explicitExternal
        ) else {
            Issue.record("Explicit external environment provenance must be representable")
            return
        }
        #expect(policy.authenticationOrigin == .launchEnvironment)
        #expect(policy.environmentProvenance == .explicitExternal)
    }
}
