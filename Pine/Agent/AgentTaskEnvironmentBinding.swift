import Darwin
import Foundation
import Synchronization

/// A runtime pin of the origin repository, existing parent, and missing target
/// before setup. It is not a command grant. Revalidate on a background path
/// immediately before an explicitly authorized probe/launch/setup approval.
nonisolated struct AgentTaskEnvironmentSetupLease: Sendable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let snapshot: AgentTaskEnvironmentSetupSnapshot
    var taskID: UUID { snapshot.taskID }
    var reservationRunID: UUID { snapshot.reservationRunID }
    var expectedWorktree: URL { snapshot.expectedWorktree }
    var project: URL { snapshot.project }
    fileprivate let projectLease: RecentAgentTaskFilesystemValidationLease
    fileprivate let parentLease: RecentAgentTaskFilesystemValidationLease
    fileprivate let validity: AgentTaskSetupLeaseValidity
    var description: String { "<redacted:task-environment-setup>" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["value": description]) }
    func revalidateOrigin() -> Bool {
        validity.isSetupActive && projectLease.revalidate() && parentLease.revalidate()
            && RecentAgentTaskFilesystemValidator.repositoryProof(forRepository: project)?
                .identifiesSameRepository(as: snapshot.repositoryProof) == true
    }
    func revalidate() -> Bool {
        guard revalidateOrigin() else { return false }
        var info = stat()
        return lstat(expectedWorktree.path, &info) == -1 && errno == ENOENT && validity.isSetupActive
    }

    /// Shared by every copy/owner of this lease. An uncertain dispatch never
    /// becomes a fresh creation grant, even when its target still looks absent.
    func claimCreationAttempt() -> Bool {
        validity.claimCreationAttempt()
    }

    func revokeAuthority() { validity.invalidate() }

    /// Intermediate metadata observation before file population; this is not
    /// adoption and cannot authorize a provider launch.
    func createdFilesystemLease() -> RecentAgentTaskFilesystemValidationLease? {
        let identity = AgentTaskProjectIdentity(canonicalProjectPath: project.path, canonicalWorktreePath: expectedWorktree.path)
        guard revalidateOrigin(),
              let proof = RecentAgentTaskFilesystemValidator.repositoryProof(for: identity),
              proof.identifiesSameRepository(as: snapshot.repositoryProof),
              let lease = RecentAgentTaskFilesystemValidator.validationLease(for: identity, expectedProof: proof),
              revalidateOrigin(), lease.revalidate() else { return nil }
        return lease
    }
}

nonisolated private final class AgentTaskSetupLeaseValidity: Sendable, Hashable {
    private struct State: Sendable {
        var active = true
        var setupFinished = false
        var creationAttempted = false
    }
    private let state = Mutex(State())
    var isActive: Bool { state.withLock { $0.active } }
    var isSetupActive: Bool { state.withLock { $0.active && !$0.setupFinished } }
    func invalidate() { state.withLock { $0.active = false } }
    func finishSetup() -> Bool {
        state.withLock {
            guard $0.active, !$0.setupFinished else { return false }
            $0.setupFinished = true
            return true
        }
    }
    func claimCreationAttempt() -> Bool {
        state.withLock {
            guard $0.active, !$0.setupFinished, !$0.creationAttempted else { return false }
            $0.creationAttempted = true
            return true
        }
    }
    static func == (lhs: AgentTaskSetupLeaseValidity, rhs: AgentTaskSetupLeaseValidity) -> Bool { lhs === rhs }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

/// Runtime-only capability; possession alone is not an execution grant. The
/// owner must revalidate it immediately before launch/check/review/result use.
nonisolated struct AgentTaskEnvironmentBinding: Hashable, Sendable {
    let id: UUID
    let taskID: UUID
    /// Pine-observed roots at adoption, not a provider-reported cwd.
    let identity: AgentTaskProjectIdentity
    /// Original environment-creation reservation, distinct from later logical
    /// attempts that reuse this environment and provider process.
    let reservationRunID: UUID
    private let validity: AgentTaskSetupLeaseValidity

    /// Current runtime ownership only; filesystem evidence is not a grant.
    /// Shared revocation synchronously fences consumers of cached leases.
    func validateAuthority() throws {
        guard validity.isActive else { throw AgentTaskEnvironmentBindingError.staleBinding }
    }
    fileprivate func invalidate() { validity.invalidate() }

    fileprivate init(taskID: UUID, runID: UUID, identity: AgentTaskProjectIdentity, validity: AgentTaskSetupLeaseValidity) {
        id = UUID()
        self.taskID = taskID
        self.identity = identity
        reservationRunID = runID
        self.validity = validity
    }

    #if PINE_TEST_HOST
    /// Fake-backed native admission tests; production still revalidates through
    /// AgentTaskEnvironmentBindings and its exact adopted-worktree proofs.
    static func nativeBindingForTesting(taskID: UUID, runID: UUID) -> Self {
        let path = "/tmp/pine-native/\(taskID.uuidString)/\(runID.uuidString)"
        return Self(
            taskID: taskID,
            runID: runID,
            identity: AgentTaskProjectIdentity(canonicalProjectPath: path, canonicalWorktreePath: path),
            validity: AgentTaskSetupLeaseValidity()
        )
    }
    #endif
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
        let snapshot: AgentTaskEnvironmentSetupSnapshot
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
        try await reserve(taskID: taskID, runID: runID, canonicalProject: canonicalProject, expectedWorktree: expectedWorktree, restoring: nil)
    }

    /// Cold recovery permits an existing target but NEVER a fresh creation.
    /// Original repository, project and parent instances must still match.
    func restore(_ snapshot: AgentTaskEnvironmentSetupSnapshot) async throws -> AgentTaskEnvironmentSetupLease {
        try await reserve(taskID: snapshot.taskID, runID: snapshot.reservationRunID,
            canonicalProject: snapshot.project, expectedWorktree: snapshot.expectedWorktree, restoring: snapshot)
    }

    private func reserve(
        taskID: UUID, runID: UUID, canonicalProject: URL, expectedWorktree: URL,
        restoring: AgentTaskEnvironmentSetupSnapshot?
    ) async throws -> AgentTaskEnvironmentSetupLease {
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
                  let proof = RecentAgentTaskFilesystemValidator.repositoryProof(forRepository: canonicalProject),
                  let projectRoot = Self.directoryProof(canonicalProject),
                  let parentRoot = Self.directoryProof(parent) else { return nil }
            var info = stat()
            if let restoring {
                guard restoring.project.path == canonicalProject.path, restoring.expectedWorktree.path == expected.path,
                      restoring.projectRoot.identifiesSameObject(as: projectRoot),
                      restoring.parentRoot.identifiesSameObject(as: parentRoot),
                      restoring.repositoryProof.identifiesSameRepository(as: proof) else { return nil }
            } else {
                guard lstat(expected.path, &info) == -1, errno == ENOENT else { return nil }
            }
            guard projectLease.revalidate(), parentLease.revalidate() else { return nil }
            let snapshot = AgentTaskEnvironmentSetupSnapshot(taskID: taskID, reservationRunID: runID,
                project: canonicalProject, expectedWorktree: expected, repositoryProof: proof, projectRoot: projectRoot, parentRoot: parentRoot)
            return CapturedReservation(snapshot: snapshot, projectLease: projectLease, parentLease: parentLease, expectedWorktree: expected)
        }
        try Task.checkCancellation()
        guard pendingReservations[taskID]?.token == token else {
            throw AgentTaskEnvironmentBindingError.staleBinding
        }
        guard let captured else { throw AgentTaskEnvironmentBindingError.unavailableEnvironment }
        guard !reservations.values.contains(where: { $0.expectedWorktree == captured.expectedWorktree }) else {
            throw AgentTaskEnvironmentBindingError.ambiguousEnvironment
        }
        let setupLease = AgentTaskEnvironmentSetupLease(snapshot: captured.snapshot,
            projectLease: captured.projectLease, parentLease: captured.parentLease, validity: AgentTaskSetupLeaseValidity())
        if restoring != nil { _ = setupLease.claimCreationAttempt() }
        reservations[taskID] = Reservation(
            runID: runID, project: canonicalProject, repositoryProof: captured.snapshot.repositoryProof,
            projectLease: captured.projectLease, expectedParentLease: captured.parentLease,
            expectedWorktree: captured.expectedWorktree, expectedBranch: Self.branchName(taskID: taskID, runID: runID), setupLease: setupLease
        )
        return setupLease
    }

    nonisolated private static func directoryProof(_ url: URL) -> RecentAgentTaskFilesystemObjectProof? {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { return nil }
        return RecentAgentTaskFilesystemObjectProof(
            device: UInt64(truncatingIfNeeded: info.st_dev), inode: UInt64(info.st_ino), generation: UInt64(info.st_gen),
            birthSeconds: Int64(info.st_birthtimespec.tv_sec), birthNanoseconds: Int64(info.st_birthtimespec.tv_nsec), kind: S_IFDIR
        )
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
        guard reservation.setupLease.validity.isSetupActive else { throw AgentTaskEnvironmentBindingError.staleBinding }
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
        // Adoption ends setup, not ownership. The retained binding shares the
        // exact reservation token so owner revocation remains synchronous.
        guard current.setupLease.validity.finishSetup() else { throw AgentTaskEnvironmentBindingError.staleBinding }
        let binding = AgentTaskEnvironmentBinding(
            taskID: taskID, runID: runID, identity: captured.identity, validity: current.setupLease.validity
        )
        var bound = current
        bound.binding = binding
        bound.identity = captured.identity
        bound.worktreeProof = captured.proof
        reservations[taskID] = bound
        return binding
    }

    /// The returned descriptor-backed lease must be revalidated on the same
    /// background path immediately before performing the authorized operation.
    /// No filesystem lease grants permission to execute a command.
    func revalidate(
        _ binding: AgentTaskEnvironmentBinding
    ) async throws -> RecentAgentTaskFilesystemValidationLease {
        try binding.validateAuthority()
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
        try binding.validateAuthority()
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

    /// Retiring an old owner must not revoke a newer cold-restored lease that
    /// happens to carry the same durable task/run identity.
    func revoke(_ lease: AgentTaskEnvironmentSetupLease) {
        guard reservations[lease.taskID]?.setupLease.validity === lease.validity else { return }
        revoke(taskID: lease.taskID, runID: lease.reservationRunID)
    }
}
