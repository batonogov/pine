import Foundation
import Synchronization

/// Proof tied to a real literal-argv child, not provider-supplied process data.
/// The bridge keeps exclusive polling/reaping responsibility; this receipt never waits.
nonisolated final class AgentTaskOwnedProcessReceipt: Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable {
    private struct Owner: Sendable { weak var value: AgentTaskNativeOwnership? }
    let identity: UserTaskProcessIdentity
    private let owner: Owner
    private let validateImage: @Sendable (UserTaskProcessIdentity) throws -> Void
    private let inspectIdentity: @Sendable (Int32) -> UserTaskProcessIdentity?
    private let active = Mutex(true)
    var description: String { "<redacted:owned-process-receipt>" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["value": description]) }

    /// Called off-main by the owning native bridge after spawn. The image gate
    /// must validate its pinned selected executable against this exact incarnation.
    convenience init(
        process: UserTaskSubprocess, ownership: AgentTaskNativeOwnership,
        validateImage: @escaping @Sendable (UserTaskProcessIdentity) throws -> Void
    ) throws {
        precondition(!Thread.isMainThread)
        try ownership.validate()
        guard let identity = UserTaskProcessInspector.identity(for: process.processGroup.identifier) else {
            throw AgentTaskNativeAdmissionError.unavailable
        }
        self.init(identity: identity, ownership: ownership, validateImage: validateImage,
                  inspectIdentity: { UserTaskProcessInspector.identity(for: $0) })
        try validateForAdmission()
    }

    private init(
        identity: UserTaskProcessIdentity, ownership: AgentTaskNativeOwnership,
        validateImage: @escaping @Sendable (UserTaskProcessIdentity) throws -> Void,
        inspectIdentity: @escaping @Sendable (Int32) -> UserTaskProcessIdentity?
    ) {
        self.identity = identity
        owner = Owner(value: ownership)
        self.validateImage = validateImage
        self.inspectIdentity = inspectIdentity
    }

    #if PINE_TEST_HOST
    /// Exercises ownership/journal races without launching or inspecting any
    /// process. This is not evidence that the native bridge or kernel works.
    static func nativeReceiptForTesting(
        identity: UserTaskProcessIdentity, ownership: AgentTaskNativeOwnership,
        inspectIdentity: @escaping @Sendable (Int32) -> UserTaskProcessIdentity?
    ) -> Self {
        Self(identity: identity, ownership: ownership, validateImage: { _ in }, inspectIdentity: inspectIdentity)
    }
    #endif

    func belongs(to ownership: AgentTaskNativeOwnership) -> Bool { owner.value === ownership }
    /// Fences this receipt and revokes the owning ownership: a torn-down or
    /// failed child destroys the launch authority, so a new attempt is a new
    /// explicit process, never a replay of this one.
    func revoke() {
        active.withLock { $0 = false }
        owner.value?.revoke()
    }

    private func validateForAdmission() throws {
        precondition(!Thread.isMainThread)
        try active.withLock { guard $0 else { throw AgentTaskNativeAdmissionError.unavailable } }
        guard let ownership = owner.value else { throw AgentTaskNativeAdmissionError.unavailable }
        try ownership.validate()
        guard ownership.filesystem.revalidate(),
              inspectIdentity(identity.processID) == identity else {
            throw AgentTaskNativeAdmissionError.unavailable
        }
        try validateImage(identity)
        try ownership.validate()
        try active.withLock { guard $0 else { throw AgentTaskNativeAdmissionError.unavailable } }
    }

    func revalidate() async -> Bool {
        (try? await runOnBackground { try self.validateForAdmission() }) != nil
    }

    func validateDispatch() throws { try validateForAdmission() }
}
