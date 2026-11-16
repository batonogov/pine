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
            taskID: taskID, runID: runID, bindingID: bindingID, selection: selection
        )
        guard case .eligible(let policy) = result else {
            Issue.record("Native inheritance must be representable without inspecting the executable")
            return
        }
        #expect(policy.taskID == taskID)
        #expect(policy.runID == runID)
        #expect(policy.bindingID == bindingID)
        #expect(policy.agentID == selection.agentID)
        #expect(policy.selectedExecutable == selection.selectedExecutable)
        #expect(policy.requestedSettings == .inheritNativeConfiguration)
        #expect(policy.settingsScope == .nativeConfiguration)
        #expect(policy.effectiveConfiguration == .unknown)
        #expect(policy.authentication == .unknown)
        #expect(policy.connection == .unknown)
        #expect(policy.billing == .unknown)
    }

    @Test func missingSelectionAndOverridesHaveTypedNonEligibleResults() {
        let taskID = UUID()
        let runID = UUID()
        let bindingID = UUID()
        #expect(AgentTaskNativeLaunchPolicy.evaluate(
            taskID: taskID, runID: runID, bindingID: bindingID, selection: nil
        ) == .blocked(.missingSelection))
        #expect(AgentTaskNativeLaunchPolicy.evaluate(
            taskID: taskID, runID: runID, bindingID: bindingID, selection: nil,
            requestedSettings: .overrides
        ) == .unsupported(.requestedOverrides))
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
                selection: .init(agentID: agentID, selectedExecutable: executable)
            ) == .blocked(.inconsistentSelection))
        }
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
            taskID: taskID, runID: firstRun, bindingID: bindingID, selection: firstSelection
        )
        let second = AgentTaskNativeLaunchPolicy.evaluate(
            taskID: taskID, runID: secondRun, bindingID: bindingID, selection: secondSelection
        )
        #expect(first != second)
        #expect(first == AgentTaskNativeLaunchPolicy.evaluate(
            taskID: taskID, runID: firstRun, bindingID: bindingID, selection: firstSelection
        ))
    }
}
