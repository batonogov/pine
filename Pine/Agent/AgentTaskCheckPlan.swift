import Foundation

/// Ephemeral projection of a locally selected recipe, shared with #1757.
/// Not Codable: literal arguments can contain secrets and must not reach task
/// metadata, logs, or provider evidence. Selection itself grants no execution.
nonisolated struct AgentTaskCheckCommand: Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let id: String
    let required: Bool
    let executable: URL
    let arguments: [String]
    /// Empty means the validated task root; all other paths are root-relative.
    let workingDirectory: String
    let timeout: TimeInterval

    var description: String { "<redacted:check-command>" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["value": description]) }

    var isValid: Bool {
        let path = executable.path(percentEncoded: false)
        guard executable.isFileURL, executable.baseURL == nil,
              executable.host == nil || executable.host == "",
              executable.user == nil, executable.password == nil, executable.port == nil,
              executable.query == nil, executable.fragment == nil,
              path.hasPrefix("/"), path != "/", !executable.hasDirectoryPath,
              path.utf8.count <= 16_384,
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return false }
        return !id.isEmpty && id.utf8.count <= 128 && !id.utf8.contains(0)
            && arguments.count <= 256 && arguments.allSatisfy {
                $0.utf8.count <= 16_384 && !$0.utf8.contains(0)
            }
            && arguments.reduce(0, { $0 + $1.utf8.count }) <= 65_536
            && (workingDirectory.isEmpty || AgentVerificationCapturePolicy.validRelativePath(workingDirectory))
            && timeout.isFinite && timeout > 0 && timeout <= 3_600
    }

    var fingerprint: String {
        var hash = AgentVerificationCanonicalHasher(domain: "pine.ade.check-command.v1")
        hash.append("id", id)
        hash.append("required", required ? "true" : "false")
        hash.append("executable", executable.absoluteString)
        for argument in arguments { hash.append("argument", argument) }
        hash.append("working-directory", workingDirectory)
        hash.append("timeout-bits", String(timeout.bitPattern))
        return hash.finish()
    }
}

/// An ordered selected check set. Recipe identity is a content fingerprint,
/// not a display name or a provider-reported version.
nonisolated struct AgentTaskCheckPlan: Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    static let currentScheme: UInt8 = 1
    let scheme: UInt8
    let recipeFingerprint: String
    let commands: [AgentTaskCheckCommand]
    let capturePolicy: AgentVerificationCapturePolicy
    /// Configuration files relative to the validated task root.
    let configurationFiles: Set<String>

    var description: String { "<redacted:check-plan>" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["value": description]) }

    var isValid: Bool {
        scheme == Self.currentScheme && Self.validFingerprint(recipeFingerprint)
            && !commands.isEmpty && commands.count <= 32
            && commands.allSatisfy(\.isValid)
            && Set(commands.map(\.id)).count == commands.count
            && commands.contains(where: \.required)
            && capturePolicy.isValid && configurationFiles.count <= 128
            && configurationFiles.allSatisfy(AgentVerificationCapturePolicy.validRelativePath)
            && !configurationFiles.contains(where: capturePolicy.excludes)
    }

    var fingerprint: String {
        var hash = AgentVerificationCanonicalHasher(domain: "pine.ade.check-plan.v1")
        hash.append("scheme", String(scheme))
        hash.append("recipe", recipeFingerprint)
        hash.append("capture-policy", capturePolicy.fingerprint)
        for path in AgentVerificationCapturePolicy.sorted(configurationFiles) {
            hash.append("configuration", path)
        }
        for command in commands { hash.append("command", command.fingerprint) }
        return hash.finish()
    }

    static func validFingerprint(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}

/// Content-free persisted scope of an explicit user command approval.
/// This value is NOT a launch capability. The metadata owner must check its
/// current (not cached) grant/revocation state and the environment lease at the
/// runner's pre-spawn gate. Reverification may reuse this exact scope.
nonisolated struct AgentTaskCheckGrant: Codable, Equatable, Sendable {
    static let currentScheme: UInt8 = 1
    let scheme: UInt8
    let id: UUID
    let taskID: UUID
    let planFingerprint: String
    let environment: AgentTaskEnvironmentIdentity
    let approvedAt: Date
    var revokedAt: Date?

    func matchesScope(
        taskID: UUID, plan: AgentTaskCheckPlan, environment: AgentTaskEnvironmentIdentity
    ) -> Bool {
        scheme == Self.currentScheme && revokedAt == nil
            && approvedAt.timeIntervalSince1970.isFinite
            && self.taskID == taskID && plan.isValid
            && planFingerprint == plan.fingerprint && self.environment == environment
            && AgentTaskMetadataStore.validEnvironment(environment)
    }
}

/// Executor-owned operation inputs for #1753's existing identity capture.
/// A new operation ID identifies each command attempt, never a provider event.
/// `runID` is the current logical attempt, not binding.reservationRunID.
nonisolated struct AgentTaskCheckOperationInputs: Sendable {
    let operationID: UUID
    let taskID: UUID
    let runID: UUID
    let processGeneration: UInt64
    let binding: AgentTaskEnvironmentBinding
    let grantID: UUID
    let plan: AgentTaskCheckPlan
    let commandID: String
    let expected: AgentVerificationIdentitySnapshot
    let capture: AgentVerificationIdentityCapture.Inputs
}

/// Synchronous off-main pre-spawn gate, passed the EXACT environment supplied
/// by UserTaskRunner. It must validate current task/run, selection, grant and
/// binding authority (not cached snapshots), then use #1753 capture with these
/// environment values and compare with `expected`. Throwing prevents spawn.
/// The same validation and capture are needed after cleanup before evidence.
/// This contract supplies no default that silently approves missing authority.
typealias AgentTaskCheckLaunchValidator = @Sendable (
    AgentTaskCheckOperationInputs, [String: String]
) throws -> Void
