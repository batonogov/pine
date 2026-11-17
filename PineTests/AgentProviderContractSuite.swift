import Foundation
import Testing

/// Shared structure for the provider contract-test suite that runs against
/// every structured ADE adapter (OpenCode, Codex, Kimi, Claude). Each
/// provider side runs the same scenario table against its own wire codec,
/// connection, and task mapper, and reports contract-level outcomes.
///
/// Capability differences are first-class: a scenario a provider transport
/// cannot implement is reported as `.unsupported(reason)`, never silently
/// skipped, and the reason must name the exact transport limitation.
nonisolated struct AgentProviderContractScenario: Identifiable, Sendable {
    let id: String
    let name: String
    let summary: String
}

nonisolated enum AgentProviderContractOutcome: Equatable, Sendable {
    /// The shared contract holds for this provider at the codec/model level.
    case pass
    /// The provider violated a shared contract; the reason names the
    /// violated invariant.
    case fail(String)
    /// The provider transport cannot implement the scenario; the reason
    /// names the documented capability difference.
    case unsupported(String)
}

nonisolated enum AgentProviderContractSuite {
    static let scenarios: [AgentProviderContractScenario] = [
        AgentProviderContractScenario(
            id: "question", name: "Question",
            summary: "A provider question surfaces as shared question state, is answerable exactly once, never settles the task."
        ),
        AgentProviderContractScenario(
            id: "approval", name: "Approval",
            summary: "A permission request surfaces as shared approval state; the one-shot response is idempotent under redelivery."
        ),
        AgentProviderContractScenario(
            id: "continuation", name: "Continuation",
            summary: "After a main-turn end (Stop), a new authorized submission starts a new turn on the same session."
        ),
        AgentProviderContractScenario(
            id: "cancellation", name: "Cancellation",
            summary: "Cancellation stays requested until confirmed; queued input is never auto-resent; late completion is a race, never success."
        ),
        AgentProviderContractScenario(
            id: "malformed-duplicate-stale", name: "Malformed, duplicate, stale",
            summary: "Malformed frames fence ingress; duplicates replay the remembered response; stale or foreign traffic never creates state."
        ),
        AgentProviderContractScenario(
            id: "reconnect", name: "Reconnect",
            summary: "After a transport gap, pending-request recovery restores approval state or keeps it unknown, never 'no pending'."
        ),
        AgentProviderContractScenario(
            id: "relaunch", name: "Relaunch",
            summary: "A new process is a new Pine attempt/source namespace; native resume never runs automatically."
        ),
        AgentProviderContractScenario(
            id: "evidence-fencing", name: "Evidence fencing",
            summary: "Provider events are fenced to the exact source, attempt, session, and request; payloads never leak into shared references."
        ),
        AgentProviderContractScenario(
            id: "backpressure", name: "Backpressure",
            summary: "Pending requests, remembered responses, and buffered traffic are bounded; exceeding a bound fails closed."
        ),
        AgentProviderContractScenario(
            id: "secret-bearing-payloads", name: "Secret-bearing payloads",
            summary: "Prompts, tool inputs, assistant text, and transcripts are not retained by codec, mapper, or references."
                + " The control_response error string is the only retained text: in-memory only, bounded at 256 bytes."
        )
    ]

    /// Every scenario must have an explicit, documented outcome for the
    /// provider under test. Missing or unknown scenario IDs are failures.
    static func validate(
        provider: String,
        table: [String: AgentProviderContractOutcome]
    ) -> [String: AgentProviderContractOutcome] {
        var validated = table
        for scenario in scenarios where validated[scenario.id] == nil {
            validated[scenario.id] = .fail("missing outcome for \(provider)")
        }
        let known = Set(scenarios.map(\.id))
        for key in table.keys where !known.contains(key) {
            validated[key] = .fail("unknown scenario id")
        }
        return validated
    }
}

/// Records the suite outcome as test failures for any non-pass result that
/// was not explicitly declared unsupported.
nonisolated func expectProviderContractOutcomes(
    _ table: [String: AgentProviderContractOutcome],
    provider: String,
    fileID: StaticString = #fileID,
    line: UInt = #line
) {
    let validated = AgentProviderContractSuite.validate(provider: provider, table: table)
    for scenario in AgentProviderContractSuite.scenarios {
        guard let outcome = validated[scenario.id] else { continue }
        switch outcome {
        case .pass, .unsupported: break
        case let .fail(reason):
            Issue.record("Provider contract '\(scenario.name)' failed for \(provider): \(reason)",
                         fileID: fileID, line: line)
        }
    }
}
