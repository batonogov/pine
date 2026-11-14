import Darwin
import Foundation
import Synchronization

/// A runtime pin of the origin repository, existing parent, and missing target
/// before setup. It is not a command grant. Revalidate on a background path
/// immediately before an explicitly authorized probe/launch/setup approval.
nonisolated struct AgentTaskEnvironmentSetupLease: Sendable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let taskID: UUID
    let reservationRunID: UUID
    let expectedWorktree: URL
    fileprivate let project: URL
    fileprivate let repositoryProof: RecentAgentTaskRepositoryProof
    fileprivate let projectLease: RecentAgentTaskFilesystemValidationLease
    fileprivate let parentLease: RecentAgentTaskFilesystemValidationLease
    fileprivate let validity: AgentTaskSetupLeaseValidity
    var description: String { "<redacted:task-environment-setup>" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["value": description]) }
    func revalidate() -> Bool {
        guard validity.isActive, projectLease.revalidate(), parentLease.revalidate(),
              RecentAgentTaskFilesystemValidator.repositoryProof(forRepository: project) == repositoryProof else { return false }
        var info = stat()
        return lstat(expectedWorktree.path, &info) == -1 && errno == ENOENT && validity.isActive
    }
}

nonisolated private final class AgentTaskSetupLeaseValidity: Sendable, Hashable {
    private let active = Mutex(true)
    var isActive: Bool { active.withLock { $0 } }
    func invalidate() { active.withLock { $0 = false } }
    static func == (lhs: AgentTaskSetupLeaseValidity, rhs: AgentTaskSetupLeaseValidity) -> Bool { lhs === rhs }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

/// Runtime-only capability; possession alone is not an execution grant. The
/// owner must revalidate it immediately before launch/check/review/result use.
nonisolated struct AgentTaskEnvironmentBinding: Hashable, Sendable {
    let id: UUID
    let taskID: UUID
    /// Original environment-creation reservation, distinct from later logical
    /// attempts that reuse this environment and provider process.
    let reservationRunID: UUID
    private let validity = AgentTaskSetupLeaseValidity()

    /// Current runtime ownership only; filesystem and execution grants are
    /// separate. Revocation fences cached filesystem leases synchronously.
    func validateAuthority() throws {
        guard validity.isActive else { throw AgentTaskEnvironmentBindingError.staleBinding }
    }
    fileprivate func invalidate() { validity.invalidate() }

    fileprivate init(taskID: UUID, runID: UUID) {
        id = UUID()
        self.taskID = taskID
        reservationRunID = runID
    }
}

nonisolated enum AgentTaskEnvironmentBindingError: Error, Equatable {
    case capacityExceeded, alreadyReserved, missingReservation
    case ambiguousEnvironment, unavailableEnvironment, staleBinding
}

/// Reserves ownership before an agent starts, then adopts an existing linked
/// worktree. It never creates a worktree. Filesystem proofs are Pine-observed;
/// provider-supplied cwd strings or hashes are never accepted as proofs.
///
/// Worktrees supply routing and identity, not a security sandbox. This first
/// single-task implementation refuses sharing a task's environment with a
/// second active task; concurrent scheduling is owned by #1728.
actor AgentTaskEnvironmentBindings {
    private struct Reservation: Sendable {
        let generation = UUID()
        let runID: UUID
        let project: URL
        let repositoryProof: RecentAgentTaskRepositoryProof
        let projectLease: RecentAgentTaskFilesystemValidationLease
        let expectedParentLease: RecentAgentTaskFilesystemValidationLease
        let expectedWorktree: URL
        let expectedBranch: String
        let setupLease: AgentTaskEnvironmentSetupLease
        var binding: AgentTaskEnvironmentBinding?
        var identity: AgentTaskProjectIdentity?
        var worktreeProof: RecentAgentTaskRepositoryProof?
    }

    private struct CapturedEnvironment: Sendable {
        let identity: AgentTaskProjectIdentity
        let proof: RecentAgentTaskRepositoryProof
    }

    private struct CapturedReservation: Sendable {
        let proof: RecentAgentTaskRepositoryProof
        let projectLease: RecentAgentTaskFilesystemValidationLease
        let parentLease: RecentAgentTaskFilesystemValidationLease
        let expectedWorktree: URL
    }

    nonisolated static func branchName(taskID: UUID, runID: UUID) -> String {
        "pine/task/\(taskID.uuidString.lowercased())/\(runID.uuidString.lowercased())"
    }

    static let maximumReservations = 32
    private var reservations: [UUID: Reservation] = [:]
    private var pendingReservations: [UUID: (runID: UUID, token: UUID)] = [:]

    deinit {
        for reservation in reservations.values {
            reservation.setupLease.validity.invalidate()
            reservation.binding?.invalidate()
        }
    }

    @discardableResult
    func reserve(taskID: UUID, runID: UUID, canonicalProject: URL, expectedWorktree: URL) async throws -> AgentTaskEnvironmentSetupLease {
        guard reservations[taskID] == nil, pendingReservations[taskID] == nil else {
            throw AgentTaskEnvironmentBindingError.alreadyReserved
        }
        guard reservations.count + pendingReservations.count < Self.maximumReservations else {
            throw AgentTaskEnvironmentBindingError.capacityExceeded
        }
        let token = UUID()
        pendingReservations[taskID] = (runID, token)
        defer {
            if pendingReservations[taskID]?.token == token {
                pendingReservations.removeValue(forKey: taskID)
            }
        }
        let captured: CapturedReservation? = await runOnBackground {
            guard canonicalProject.isFileURL, expectedWorktree.isFileURL else { return nil }
            let identity = AgentTaskProjectIdentity(
                canonicalProjectPath: canonicalProject.path,
                canonicalWorktreePath: canonicalProject.path
            )
            let parent = expectedWorktree.deletingLastPathComponent().resolvingSymlinksInPath()
            let expected = parent.appending(path: expectedWorktree.lastPathComponent).standardizedFileURL
            let parentIdentity = AgentTaskProjectIdentity(
                canonicalProjectPath: parent.path, canonicalWorktreePath: parent.path
            )
            guard let projectLease = RecentAgentTaskFilesystemValidator.validationLease(for: identity, expectedProof: nil),
                  let parentLease = RecentAgentTaskFilesystemValidator.validationLease(for: parentIdentity, expectedProof: nil),
                  let proof = RecentAgentTaskFilesystemValidator.repositoryProof(forRepository: canonicalProject) else { return nil }
            var info = stat()
            guard lstat(expected.path, &info) == -1, errno == ENOENT,
                  projectLease.revalidate(), parentLease.revalidate() else { return nil }
            return CapturedReservation(proof: proof, projectLease: projectLease, parentLease: parentLease, expectedWorktree: expected)
        }
        try Task.checkCancellation()
        guard pendingReservations[taskID]?.token == token else {
            throw AgentTaskEnvironmentBindingError.staleBinding
        }
        guard let captured else { throw AgentTaskEnvironmentBindingError.unavailableEnvironment }
        guard !reservations.values.contains(where: { $0.expectedWorktree == captured.expectedWorktree }) else {
            throw AgentTaskEnvironmentBindingError.ambiguousEnvironment
        }
        let setupLease = AgentTaskEnvironmentSetupLease(taskID: taskID, reservationRunID: runID,
            expectedWorktree: captured.expectedWorktree, project: canonicalProject, repositoryProof: captured.proof,
            projectLease: captured.projectLease, parentLease: captured.parentLease, validity: AgentTaskSetupLeaseValidity())
        reservations[taskID] = Reservation(
            runID: runID, project: canonicalProject, repositoryProof: captured.proof,
            projectLease: captured.projectLease, expectedParentLease: captured.parentLease,
            expectedWorktree: captured.expectedWorktree, expectedBranch: Self.branchName(taskID: taskID, runID: runID), setupLease: setupLease
        )
        return setupLease
    }

    /// Discovery must yield exactly one candidate. Ambiguous reporting is not
    /// resolved by picking a path or asking the agent to create another tree.
    func adopt(
        taskID: UUID,
        runID: UUID,
        candidates: [URL]
    ) async throws -> AgentTaskEnvironmentBinding {
        guard let reservation = reservations[taskID], reservation.runID == runID else {
            throw AgentTaskEnvironmentBindingError.missingReservation
        }
        guard reservation.binding == nil else { throw AgentTaskEnvironmentBindingError.alreadyReserved }
        guard candidates.count == 1, let worktree = candidates.first else {
            throw AgentTaskEnvironmentBindingError.ambiguousEnvironment
        }
        let captured: CapturedEnvironment? = await runOnBackground {
            guard reservation.projectLease.revalidate(), reservation.expectedParentLease.revalidate() else { return nil }
            let project = reservation.project.resolvingSymlinksInPath()
            let candidate = worktree.resolvingSymlinksInPath()
            let identity = AgentTaskProjectIdentity(
                canonicalProjectPath: project.path,
                canonicalWorktreePath: candidate.path
            )
            var info = stat()
            // Resolving a now-existing directory adds URL's directory marker;
            // the missing reserved leaf had none. Compare canonical paths,
            // then require the independently observed filesystem proofs below.
            guard candidate.path == reservation.expectedWorktree.path,
                  lstat(candidate.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
                  identity.canonicalProjectPath != identity.canonicalWorktreePath,
                  let proof = RecentAgentTaskFilesystemValidator.repositoryProof(for: identity),
                  proof.hasExactWorktreeInstance,
                  let projectRoot = proof.projectRoot, let worktreeRoot = proof.worktreeRoot,
                  !projectRoot.identifiesSameObject(as: worktreeRoot) else { return nil }
            let branch = AgentTaskGitInspection.branch(at: candidate)
            guard branch.succeeded,
                  branch.output.trimmingCharacters(in: .whitespacesAndNewlines) == reservation.expectedBranch,
                  reservation.projectLease.revalidate(), reservation.expectedParentLease.revalidate() else { return nil }
            return CapturedEnvironment(identity: identity, proof: proof)
        }
        try Task.checkCancellation()
        guard let current = reservations[taskID], current.generation == reservation.generation,
              current.runID == runID, current.binding == nil else {
            throw AgentTaskEnvironmentBindingError.staleBinding
        }
        guard let captured,
              captured.proof.identifiesSameRepository(as: reservation.repositoryProof),
              let worktreeRoot = captured.proof.worktreeRoot else {
            throw AgentTaskEnvironmentBindingError.unavailableEnvironment
        }
        // Paths alone are insufficient: symlink aliases and alternative path
        // spellings must not let two tasks acquire the same filesystem object.
        guard !reservations.values.contains(where: {
            $0.worktreeProof?.worktreeRoot?.identifiesSameObject(as: worktreeRoot) == true
        }) else { throw AgentTaskEnvironmentBindingError.ambiguousEnvironment }
        let binding = AgentTaskEnvironmentBinding(taskID: taskID, runID: runID)
        var bound = current
        bound.binding = binding
        bound.identity = captured.identity
        bound.worktreeProof = captured.proof
        current.setupLease.validity.invalidate()
        reservations[taskID] = bound
        return binding
    }

    /// The returned descriptor-backed lease must be revalidated on the same
    /// background path immediately before performing the authorized operation.
    /// No filesystem lease grants permission to execute a command.
    func revalidate(
        _ binding: AgentTaskEnvironmentBinding
    ) async throws -> RecentAgentTaskFilesystemValidationLease {
        guard let reservation = reservations[binding.taskID],
              reservation.binding == binding,
              let identity = reservation.identity,
              let proof = reservation.worktreeProof else {
            throw AgentTaskEnvironmentBindingError.staleBinding
        }
        let lease = await runOnBackground {
            guard reservation.projectLease.revalidate(), reservation.expectedParentLease.revalidate(),
                  let lease = RecentAgentTaskFilesystemValidator.validationLease(for: identity, expectedProof: proof) else {
                return nil as RecentAgentTaskFilesystemValidationLease?
            }
            let branch = AgentTaskGitInspection.branch(at: lease.canonicalWorktree)
            guard branch.succeeded,
                  branch.output.trimmingCharacters(in: .whitespacesAndNewlines) == reservation.expectedBranch,
                  lease.revalidate(), reservation.projectLease.revalidate(), reservation.expectedParentLease.revalidate() else { return nil }
            return lease
        }
        try Task.checkCancellation()
        guard reservations[binding.taskID]?.binding == binding, let lease else {
            throw AgentTaskEnvironmentBindingError.staleBinding
        }
        return lease
    }

    func revoke(taskID: UUID, runID: UUID) {
        if pendingReservations[taskID]?.runID == runID {
            pendingReservations.removeValue(forKey: taskID)
        }
        guard reservations[taskID]?.runID == runID else { return }
        reservations[taskID]?.binding?.invalidate()
        reservations[taskID]?.setupLease.validity.invalidate()
        reservations.removeValue(forKey: taskID)
    }
}
