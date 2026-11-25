import Foundation

/// One row of the contextual "How to run" surface (#1765): a confirmed
/// observation of how this task actually runs, with its provenance. The
/// surface is display-only: it never offers an override the adapter cannot
/// apply, and it never fabricates a value the adapter did not report.
nonisolated struct AgentTaskHowToRunLine: Equatable, Sendable, Identifiable {
    enum Kind: String, CaseIterable, Equatable, Sendable {
        case agent, account, model, reasoningEffort, permissions
    }
    enum AccountObservation: Equatable, Sendable {
        case unknown
        case loginRequired
        case accountUnavailable
        case expiredCredentials
        case authenticated(label: String?)
    }
    enum SettingObservation: Equatable, Sendable {
        /// The adapter confirmed this native value as the effective one.
        case confirmed(String)
        /// The setting exists in the agent's native configuration; the task
        /// inherits it and Pine does not know its current value.
        case agentSettings
        /// No capability evidence: the CLI controls the value and Pine says
        /// so instead of guessing.
        case cliControls
    }

    let kind: Kind
    var id: Kind { kind }
    /// `kind == .agent`: the observed executable version, when confirmed.
    let agentVersion: String?
    /// `kind == .account`: the observed connection/account state.
    let account: AccountObservation?
    /// `kind == .model|.reasoningEffort|.permissions`: the setting state.
    let setting: SettingObservation?
}

nonisolated enum AgentTaskHowToRun {
    /// Projects one discovery report into display rows. An absent report
    /// (the session has not produced its observation yet) projects to nothing:
    /// the control stays hidden rather than claiming a state.
    static func lines(
        report: AgentTaskDiscoveryReport?
    ) -> [AgentTaskHowToRunLine] {
        guard let report else { return [] }
        let version: String?
        if case let .supported(observed) = report.executableVersion {
            version = observed.value
        } else {
            version = nil
        }
        return [
            AgentTaskHowToRunLine(
                kind: .agent,
                agentVersion: version,
                account: nil,
                setting: nil
            ),
            AgentTaskHowToRunLine(
                kind: .account,
                agentVersion: nil,
                account: account(report.authentication),
                setting: nil
            ),
            AgentTaskHowToRunLine(
                kind: .model,
                agentVersion: nil,
                account: nil,
                setting: setting(report, key: .model, effective: report.effectiveModel)
            ),
            AgentTaskHowToRunLine(
                kind: .reasoningEffort,
                agentVersion: nil,
                account: nil,
                setting: setting(report, key: .reasoningEffort, effective: report.effectiveReasoningEffort)
            ),
            AgentTaskHowToRunLine(
                kind: .permissions,
                agentVersion: nil,
                account: nil,
                setting: setting(report, key: .permissions, effective: report.effectivePermissions)
            ),
        ]
    }

    private static func account(
        _ observation: AgentTaskDiscoveryReport.AuthenticationObservation
    ) -> AgentTaskHowToRunLine.AccountObservation {
        switch observation {
        case .authenticated(let origin, let label):
            // The origin is part of the provenance fact: a launch-environment
            // credential can change connection and billing provenance.
            _ = origin
            return .authenticated(label: label?.value)
        case .loginRequired:
            return .loginRequired
        case .accountUnavailable:
            return .accountUnavailable
        case .expiredCredentials:
            return .expiredCredentials
        case .unknown:
            return .unknown
        }
    }

    private static func setting(
        _ report: AgentTaskDiscoveryReport,
        key: AgentTaskConfigurationSettingKey,
        effective: AgentTaskEffectiveSettingObservation
    ) -> AgentTaskHowToRunLine.SettingObservation {
        if case let .confirmed(value) = effective {
            return .confirmed(value)
        }
        switch report.configurationCapabilities[key].state {
        case .researched, .probed, .supported:
            return .agentSettings
        case .unknown, .unsupported:
            return .cliControls
        }
    }
}
