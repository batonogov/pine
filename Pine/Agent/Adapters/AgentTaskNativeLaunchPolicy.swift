import Foundation

/// Value-only settings intent, never launch, authentication, or Ready authority.
/// Inheritance reads native configuration scopes; it promises neither isolation
/// from external changes nor that a particular account or billing path is active.
nonisolated struct AgentTaskNativeLaunchPolicy: Equatable, Sendable {
    enum RequestedSettings: Equatable, Sendable {
        case inheritNativeConfiguration
        case overrides
    }
    enum SettingsScope: Equatable, Sendable { case nativeConfiguration }
    enum Observation: Equatable, Sendable { case unknown }

    /// A selected path, not proof that its contents implement this runtime.
    struct Selection: Equatable, Sendable {
        let agentID: AgentID
        let selectedExecutable: URL
    }

    enum BlockedReason: Equatable, Sendable {
        case missingSelection
        case inconsistentSelection
    }
    enum UnsupportedReason: Equatable, Sendable { case requestedOverrides }
    enum Eligibility: Equatable, Sendable {
        case eligible(AgentTaskNativeLaunchPolicy)
        case blocked(BlockedReason)
        case unsupported(UnsupportedReason)
    }

    let taskID: UUID
    /// Current logical attempt, not the environment's original reservationRunID.
    let runID: UUID
    let bindingID: UUID
    let agentID: AgentID
    let selectedExecutable: URL
    let requestedSettings: RequestedSettings = .inheritNativeConfiguration
    let settingsScope: SettingsScope = .nativeConfiguration
    let effectiveConfiguration: Observation = .unknown
    let authentication: Observation = .unknown
    let connection: Observation = .unknown
    let billing: Observation = .unknown

    private init(taskID: UUID, runID: UUID, bindingID: UUID, selection: Selection) {
        self.taskID = taskID
        self.runID = runID
        self.bindingID = bindingID
        agentID = selection.agentID
        selectedExecutable = selection.selectedExecutable
    }

    /// Deterministic representability only: no discovery, probes or config reads.
    /// The consumer owns live binding/executable/environment validation before
    /// spawn, explicit execution authority and the source/process/task join.
    static func evaluate(
        taskID: UUID,
        runID: UUID,
        bindingID: UUID,
        selection: Selection?,
        requestedSettings: RequestedSettings = .inheritNativeConfiguration
    ) -> Eligibility {
        guard requestedSettings == .inheritNativeConfiguration else { return .unsupported(.requestedOverrides) }
        guard let selection else { return .blocked(.missingSelection) }
        let executable = selection.selectedExecutable
        let path = executable.path(percentEncoded: false)
        guard executable.isFileURL, executable.baseURL == nil,
              executable.host == nil || executable.host == "",
              executable.user == nil, executable.password == nil, executable.port == nil,
              executable.query == nil, executable.fragment == nil,
              path.hasPrefix("/"), path != "/",
              !executable.hasDirectoryPath,
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return .blocked(.inconsistentSelection) }
        return .eligible(Self(taskID: taskID, runID: runID, bindingID: bindingID, selection: selection))
    }
}
