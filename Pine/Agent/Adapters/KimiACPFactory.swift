import Foundation

/// Exact version pin and the structured capabilities shipped for the Kimi
/// Code CLI ACP adapter. Every enabled capability is pinned to the exact CLI
/// version whose documented capability matrix was verified against the
/// protocol references; a different version is admitted only through a fresh
/// pinned observation (see `KimiACPFactory`).
nonisolated enum KimiACPCapabilities {
    /// Pinned (and observed) Kimi Code CLI version, exact. `kimi --version`
    /// prints the bare number; the ACP surface is the documented matrix of
    /// this release (ACP protocol major 1, `@agentclientprotocol` 0.23-line
    /// method set). Re-probed 2026-11-17 (artifact
    /// $TMPDIR/opencode/pine-1732-reprobe/): `--version` and ACP
    /// `initialize` observed at this version; `session/new` is auth-gated.
    static let pinnedCLIVersion = "2.6.2"
    static let agentName = "Kimi Code CLI"
    static let protocolVersion = 1

    /// Capability → pinned CLI version for the structured surface shipped in
    /// this slice. The values are recorded evidence, not a compatibility
    /// promise: the real-version smoke remains the final gate.
    static let versionFloors: [String: String] = [
        "initialize-capability-matrix": pinnedCLIVersion,
        "session-new": pinnedCLIVersion,
        "session-prompt-text": pinnedCLIVersion,
        "session-prompt-image": pinnedCLIVersion,
        "session-prompt-text-resource": pinnedCLIVersion,
        "session-load-history-replay": pinnedCLIVersion,
        "session-resume-no-replay": pinnedCLIVersion,
        "session-fork": pinnedCLIVersion,
        "session-cancel": pinnedCLIVersion,
        "session-request-permission": pinnedCLIVersion,
        "elicitation-form": pinnedCLIVersion,
        "additional-directories-new-only": pinnedCLIVersion,
        "config-options-dynamic-parse": pinnedCLIVersion,
    ]

    /// Documented Kimi drops/warnings that Pine must handle before
    /// submission instead of discovering after the fact.
    static let blobResourcesDropped = "Kimi drops blob resources (no text) with a warn only; Pine rejects them before submission."
    static let forkIgnoresEnvironment =
        "session/fork ignores supplied cwd, additionalDirectories, and mcpServers; Pine sends only the source session ID."
    static let additionalDirectoriesNewOnly = "additionalDirectories is honored on session/new only; Pine never sends it on load/resume/fork."

    /// Kimi methods that return methodNotFound and Pine therefore never
    /// calls: `providers/*`, `nes/*`, `document/*`, `elicitation/complete`.
    static let unimplementedAgentMethods = ["providers", "nes", "document", "elicitation/complete"]

    /// Reverse-RPC methods Pine must reject with methodNotFound because it
    /// does not implement their ownership, authorization, bounds,
    /// cancellation, and teardown.
    static let reverseRPCsNotOwned = [
        "fs/read_text_file", "fs/write_text_file",
        "terminal/create", "terminal/output", "terminal/release",
        "terminal/kill", "terminal/wait_for_exit",
    ]

    /// Terminal authentication (`authMethods` type `terminal`, `kimi acp
    /// --login`) is owned by a separate auth UI; the adapter only observes a
    /// verified outcome through its account gate.
    static let terminalAuthSeparate = true
}

/// Admission is supplied by the shared task/environment/native-process owner.
/// None of these values or a successful ACP handshake substitutes for its
/// grant: the launch closure must spawn the validated executable with the
/// `KimiACPLaunchArguments.subcommand` vector, bind the single-task
/// environment, and revoke ownership on any failure. The owner MUST also run
/// `channel.drainStandardError(until:)` for the full child lifetime: a chatty
/// kimi will block on a full stderr pipe otherwise (the shared channel only
/// provides the seam, draining is the owner's obligation).
nonisolated struct KimiACPAdmission: Sendable {
    let launch: @Sendable (ContinuousClock.Instant) async throws -> any KimiACPTransport
    let cwd: String
    let deadline: ContinuousClock.Instant
    let action: KimiACPSessionAction
    let beforeStartWrite: @Sendable () throws -> Void
    let revokeOwnership: @Sendable () -> Void
    let sessionBound: @Sendable (VendorReference) async throws -> Void
    let promptResponded: @Sendable (KimiACPSession.State) async throws -> KimiACPSession.ResponseDisposition
    let accountGate: @Sendable () throws -> Bool
}

/// Registry factory for the Kimi Code CLI ACP adapter. The pinned
/// observation keeps the adapter unavailable until an authorized, version-
/// exact observation exists; a `nil` observation means not admitted.
nonisolated struct KimiACPFactory: AgentAdapterReviewingFactory {
    /// ACP session creation does not disable the model's built-in write tools.
    /// Do not turn this into an enforced claim without proving that boundary.
    let reviewerControl: AgentTaskReviewerControl = .promptOnly
    let id: AdapterFactoryID
    let observation: AdapterProbeResult?
    /// Launch-boundary observation for the session's discovery report; nil
    /// until the task-owner wiring supplies the validated executable.
    var discovery: KimiACPConfigurationDiscovery.Input? = nil
    let admit: @Sendable (AgentAdapterSessionRequest) async throws -> KimiACPAdmission

    func probe() async throws -> AdapterProbeResult {
        try Task.checkCancellation()
        guard let observation,
              observation.detectedVendorVersion.value == KimiACPCapabilities.pinnedCLIVersion,
              observation.offeredProfiles == [try KimiACPSession.profile()] else {
            throw AdapterProbeError.unavailable(.permanent)
        }
        return observation
    }

    func makeSession(_ request: AgentAdapterSessionRequest) async throws -> any AgentAdapterSession {
        try Task.checkCancellation()
        _ = try await probe()
        guard request.resumeFrom == nil else { throw AdapterSessionError.checkpointNotSupported }
        let admission = try await admit(request)
        do {
            try Task.checkCancellation()
            let session = try KimiACPSession(
                request: request, launch: admission.launch, cwd: admission.cwd,
                deadline: admission.deadline, action: admission.action,
                beforeStartWrite: admission.beforeStartWrite,
                revokeOwnership: admission.revokeOwnership,
                sessionBound: admission.sessionBound,
                promptResponded: admission.promptResponded,
                accountGate: admission.accountGate,
                discovery: discovery
            )
            try Task.checkCancellation()
            return session
        } catch {
            admission.revokeOwnership()
            throw error
        }
    }
}
