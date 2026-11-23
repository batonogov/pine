import Foundation

/// Admission is supplied by the shared task/environment/native-process owner.
/// None of these values or a successful ACP handshake substitutes for its grant.
nonisolated struct ClaudeCodeACPAdmission: Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable {
    var description: String { "<redacted:claude-code-acp-admission>" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["value": description]) }
    /// Launches the owned child. The supplied deadline bounds the SPAWN
    /// window only; the owner must pass the session lifetime separately as
    /// `ClaudeCodeACPLaunch`'s `drainUntil` so a healthy long turn is never
    /// fenced by the stderr drain deadline.
    let launch: @Sendable (ContinuousClock.Instant) async throws -> any ClaudeCodeACPTransport
    let cwd: String
    /// Outer cap for the bounded launch/bootstrap windows only. Session I/O
    /// keeps per-operation bounds and outlives this instant.
    let deadline: ContinuousClock.Instant
    let loadSession: VendorReference?
    let beforeStartWrite: @Sendable () throws -> Void
    let revokeOwnership: @Sendable () -> Void
    let sessionBound: @Sendable (VendorReference) async throws -> Void
    let promptResponded: @Sendable (ClaudeCodeACPSession.State) async throws -> ClaudeCodeACPSession.ResponseDisposition
    /// Hands the exact concrete owner to the existing task/session owner, not a
    /// second registry. UI consumes ClaudeCodeACPTaskRuntime, never this actor directly.
    let sessionCreated: @Sendable (ClaudeCodeACPSession) async -> Void
}

nonisolated struct ClaudeCodeACPFactory: AgentAdapterFactory {
    let id: AdapterFactoryID
    /// Nil keeps this adapter unavailable until an authorized pinned observation.
    let observation: AdapterProbeResult?
    let admit: @Sendable (AgentAdapterSessionRequest) async throws -> ClaudeCodeACPAdmission

    func probe() async throws -> AdapterProbeResult {
        try Task.checkCancellation()
        guard let observation, observation.detectedVendorVersion.value == ClaudeCodeACPSession.pinnedVersion,
              observation.offeredProfiles == [try ClaudeCodeACPSession.profile()] else {
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
            let session = try ClaudeCodeACPSession(
                request: request, launch: admission.launch, cwd: admission.cwd,
                deadline: admission.deadline, loadSession: admission.loadSession,
                beforeStartWrite: admission.beforeStartWrite, revokeOwnership: admission.revokeOwnership,
                sessionBound: admission.sessionBound, promptResponded: admission.promptResponded
            )
            await admission.sessionCreated(session)
            try Task.checkCancellation()
            return session
        } catch {
            admission.revokeOwnership()
            throw error
        }
    }
}
