//
//  AgentWorktreeService.swift
//  Pine
//
//  Explicit, fail-closed Git worktree lifecycle for isolated agent tasks.
//

import CryptoKit
import Darwin
import Foundation

nonisolated struct AgentWorktreeCreateRequest: Sendable, Equatable {
    let taskID: UUID
    let repositoryRoot: URL
    let managedRoot: URL
    let branchName: String
    let startPoint: String
}

nonisolated struct AgentManagedWorktree: Codable, Sendable, Equatable {
    let taskID: UUID
    let repositoryRoot: URL
    let managedRoot: URL
    let worktreeRoot: URL
    let branchName: String
    /// Commit the worktree was created from. Not recoverable from disk, so a
    /// record rebuilt by discovery carries `nil` — no downstream path reads
    /// it (`remove`, `inspectRemoval`, `previewIntegration`, `integrate` all
    /// work from the live refs).
    let baseCommit: String?
    /// Filesystem-instance proof captured by the worktree service before the
    /// managed identity leaves its serialized creation boundary. Consumers
    /// must revalidate it off the main actor before admitting the worktree.
    /// `nil` only for entries discovery rebuilt that the validator cannot
    /// currently vouch for; registry admission fails closed on those.
    let repositoryProof: RecentAgentTaskRepositoryProof?
}

/// One block of `git worktree list --porcelain -z` output (#1563).
nonisolated struct AgentWorktreeListEntry: Equatable, Sendable {
    /// Canonical working-tree path exactly as git printed it.
    let path: String
    /// Branch with the `refs/heads/` prefix stripped. `nil` for detached,
    /// bare, or otherwise branch-less blocks.
    let branch: String?
}

nonisolated enum AgentWorktreeListParser {
    /// Splits porcelain output into one entry per worktree block. Attributes
    /// this consumer ignores (`HEAD`, `locked`, reasons) are skipped; a block
    /// without a `branch` record yields a `nil` branch rather than a guess.
    static func entries(inPorcelainOutput output: String) -> [AgentWorktreeListEntry] {
        var entries: [AgentWorktreeListEntry] = []
        var path: String?
        var branch: String?
        func closeBlock() {
            defer {
                path = nil
                branch = nil
            }
            guard let openPath = path else { return }
            entries.append(
                AgentWorktreeListEntry(path: openPath, branch: branch)
            )
        }
        for record in output.split(separator: "\0", omittingEmptySubsequences: false) {
            let field = String(record)
            if field.isEmpty {
                closeBlock()
            } else if field.hasPrefix("worktree ") {
                closeBlock()
                path = String(field.dropFirst("worktree ".count))
            } else if field.hasPrefix("branch refs/heads/") {
                branch = String(field.dropFirst("branch refs/heads/".count))
            }
        }
        closeBlock()
        return entries
    }

    /// The task UUID a managed directory is named with — the exact
    /// lowercase spelling `create` writes. Anything else (a different case,
    /// a dashed-less blob, a human name) is not a Pine task directory.
    static func taskID(forLowercaseUUIDName name: String) -> UUID? {
        guard name == name.lowercased(),
              let taskID = UUID(uuidString: name) else {
            return nil
        }
        return taskID
    }
}

nonisolated enum AgentWorktreeCreateFailure: Error, Sendable, Equatable {
    case invalidRepository
    case unsafeManagedRoot
    case managedRootInsideRepository
    case invalidBranchName
    case missingStartPoint
    case destinationAlreadyExists(URL)
    case primarySnapshotUnavailable
    case gitRejected(String)
    case creationInterrupted(URL)
    case createdWorktreeInvalid(URL)
    case primaryCheckoutChanged(URL)
}

nonisolated enum AgentWorktreeCreateResult: Sendable, Equatable {
    case created(AgentManagedWorktree)
    case failed(AgentWorktreeCreateFailure)
}

nonisolated struct AgentWorktreeRemovalInspection: Sendable, Equatable {
    let worktree: AgentManagedWorktree
    let dirtyPaths: [String]

    var requiresDestructiveConfirmation: Bool { !dirtyPaths.isEmpty }
}

/// Exact, short-lived user intent. Presentation must show both `worktreeRoot`
/// and every `dirtyPath`, plus the fact that uncommitted data may be lost,
/// before constructing this value.
nonisolated struct AgentWorktreeRemovalConfirmation: Sendable, Equatable {
    let worktreeRoot: URL
    let dirtyPaths: [String]
    let acknowledgesUnrecoverableDataLoss: Bool
}

nonisolated enum AgentWorktreeRemovalFailure: Error, Sendable, Equatable {
    case unsafeWorktree
    case inspectionFailed
    case confirmationRequired(AgentWorktreeRemovalInspection)
    case confirmationMismatch
    case gitRejected(String)
    case removalInterrupted(URL)
}

nonisolated enum AgentWorktreeRemovalResult: Sendable, Equatable {
    case removed
    case failed(AgentWorktreeRemovalFailure)
}

nonisolated struct AgentWorktreeIntegrationPreview: Sendable, Equatable,
    Identifiable {
    let id: UUID
    let worktree: AgentManagedWorktree
    let sourceCommit: String
    let targetRoot: URL
    let targetHead: String
    let targetBranch: String
    let targetIndexDigest: String
    let changedPaths: [String]
    let conflictingPaths: [String]

    var hasConflicts: Bool { !conflictingPaths.isEmpty }
}

nonisolated enum AgentWorktreeIntegrationPreviewFailure: Error, Sendable,
    Equatable {
    case unsafeWorktree
    case sourceBranchChanged
    case sourceWorktreeDirty([String])
    case targetSnapshotUnavailable
    case targetDetached
    case targetCheckoutDirty([String])
    case noChanges
    case gitRejected(String)
}

nonisolated enum AgentWorktreeIntegrationPreviewResult: Sendable, Equatable {
    case ready(AgentWorktreeIntegrationPreview)
    case failed(AgentWorktreeIntegrationPreviewFailure)
}

/// Exact user approval of one immutable preview. Presentation must disclose
/// the source commit, target branch and changed paths before creating it.
nonisolated struct AgentWorktreeIntegrationConfirmation: Sendable, Equatable {
    let previewID: UUID
    let sourceCommit: String
    let targetHead: String
    let targetBranch: String
    let changedPaths: [String]
}

nonisolated enum AgentWorktreeIntegrationFailure: Error, Sendable, Equatable {
    case confirmationMismatch
    case conflictsRequireResolution([String])
    case sourceChanged
    case targetChanged
    case integrationInterrupted(URL)
    case manualRecoveryRequired(String)
}

nonisolated enum AgentWorktreeIntegrationResult: Sendable, Equatable {
    /// The source commit is staged and present in the target worktree, but is
    /// deliberately not committed or pushed by Pine.
    case integratedWithoutCommit
    case failed(AgentWorktreeIntegrationFailure)
}

nonisolated struct AgentWorktreeGitRunner: Sendable {
    let run: @Sendable ([String], URL) async -> GitCommandResult

    static let live = AgentWorktreeGitRunner { arguments, directory in
        await GitCommand.runAsync(arguments, at: directory)
    }
}

/// Serializes Pine-managed worktree mutations and revalidates the primary
/// checkout around every create. Git's own locks remain the cross-process
/// authority; this actor prevents same-process races and ambiguous prompts.
actor AgentWorktreeService {
    private let runner: AgentWorktreeGitRunner
    private let fileManager: FileManager
    private var reservedDestinations: Set<String> = []

    init(
        runner: AgentWorktreeGitRunner = .live,
        fileManager: FileManager = .default
    ) {
        self.runner = runner
        self.fileManager = fileManager
    }

    func create(
        _ request: AgentWorktreeCreateRequest
    ) async -> AgentWorktreeCreateResult {
        guard let repository = await canonicalRepository(
            request.repositoryRoot
        ) else {
            return .failed(.invalidRepository)
        }
        guard let initialRepositoryProof =
                RecentAgentTaskFilesystemValidator.repositoryProof(
                    forRepository: repository
                ) else {
            return .failed(.invalidRepository)
        }
        guard let managedRoot = Self.secureExistingDirectory(
            request.managedRoot,
            fileManager: fileManager
        )
        else {
            return .failed(.unsafeManagedRoot)
        }
        guard !Self.isWithin(managedRoot, root: repository) else {
            return .failed(.managedRootInsideRepository)
        }
        guard await isValidBranch(
            request.branchName,
            repository: repository
        ) else {
            return .failed(.invalidBranchName)
        }
        guard let baseCommit = await resolvedCommit(
            request.startPoint,
            repository: repository
        ) else {
            return .failed(.missingStartPoint)
        }

        let destination = managedRoot.appendingPathComponent(
            request.taskID.uuidString.lowercased(),
            isDirectory: true
        ).standardizedFileURL
        guard destination.deletingLastPathComponent() == managedRoot,
              !fileManager.fileExists(atPath: destination.path) else {
            return .failed(.destinationAlreadyExists(destination))
        }
        guard reservedDestinations.insert(destination.path).inserted else {
            return .failed(.destinationAlreadyExists(destination))
        }
        defer { reservedDestinations.remove(destination.path) }
        guard let before = await primarySnapshot(repository) else {
            return .failed(.primarySnapshotUnavailable)
        }

        let result = await runner.run([
            "worktree", "add", "--no-track", "-b", request.branchName,
            "--", destination.path, baseCommit,
        ], repository)
        if result.timedOut || result.cancelled {
            return .failed(.creationInterrupted(destination))
        }
        guard result.completedSuccessfully else {
            return .failed(.gitRejected(diagnostic(result)))
        }
        guard let createdRoot = await canonicalRepository(destination),
              createdRoot == destination.resolvingSymlinksInPath()
                .standardizedFileURL else {
            return .failed(.createdWorktreeInvalid(destination))
        }
        guard let after = await primarySnapshot(repository),
              before == after else {
            return .failed(.primaryCheckoutChanged(destination))
        }

        let identity = AgentTaskProjectIdentity(
            canonicalProjectPath: repository.path,
            canonicalWorktreePath: destination.path
        )
        guard let finalRepositoryProof =
                RecentAgentTaskFilesystemValidator.repositoryProof(
                    for: identity
                ), finalRepositoryProof.identifiesSameRepository(
                    as: initialRepositoryProof
                ) else {
            return .failed(.createdWorktreeInvalid(destination))
        }
        return .created(AgentManagedWorktree(
            taskID: request.taskID,
            repositoryRoot: repository,
            managedRoot: managedRoot,
            worktreeRoot: destination,
            branchName: request.branchName,
            baseCommit: baseCommit,
            repositoryProof: finalRepositoryProof
        ))
    }

    // MARK: - Discovery (#1563)

    /// Rebuilds managed-worktree records for a repository by asking git what
    /// it still holds, instead of trusting one window's memory.
    ///
    /// A project close drops the window's worktree records on purpose while
    /// the checkouts and their branches survive; this is how those leftovers
    /// become reachable again. Two sources are combined:
    ///
    /// 1. `git worktree list --porcelain -z`, filtered to entries whose
    ///    parent directory is `managedRoot` and whose last path component is
    ///    the lowercase task UUID `create` named the destination with. The
    ///    branch comes from git — a checkout git recognises but that sits
    ///    detached is labelled `detached`, never a fabricated ref;
    ///    `baseCommit` is not recoverable and stays `nil`.
    /// 2. UUID-named directories under `managedRoot` that git says nothing
    ///    about — interrupted or manually broken checkouts. They are reported
    ///    with no branch (their task UUID names the row) and no proof, so
    ///    the manager lists them as unavailable instead of silently hiding
    ///    them.
    ///
    /// Discovery only *adds candidates*; it never admits them. Every
    /// downstream mutation still passes `secureManagedWorktree`, which
    /// rejects anything outside the managed root and every symlinked path
    /// component, exactly as it does for records captured at creation.
    func discoverManagedWorktrees(
        repositoryRoot: URL,
        managedRoot: URL
    ) async -> [AgentManagedWorktree] {
        guard let repository = await canonicalRepository(repositoryRoot) else {
            return []
        }
        let listing = await runner.run(
            ["worktree", "list", "--porcelain", "-z"],
            repository
        )
        guard listing.succeeded else { return [] }
        let output = listing.output
        let suppliedRoot = managedRoot.standardizedFileURL
        return await runOnBackground(qos: .userInitiated) {
            // `FileManager.default` is the thread-safe process singleton the
            // service itself holds; capturing the actor's instance here would
            // cross isolation with a type this SDK does not mark Sendable.
            Self.discoveredWorktrees(
                porcelainOutput: output,
                repository: repository,
                suppliedRoot: suppliedRoot,
                fileManager: .default
            )
        }
    }

    /// Label for a worktree git recognises but that no longer sits on a
    /// branch. Shown verbatim — it is git's own term, not a fabricated ref.
    private static let detachedBranchLabel = "detached"

    /// Pure rebuild over one porcelain listing and one directory scan. Runs
    /// off the actor inside `runOnBackground`'s autorelease pool (#1509).
    private static func discoveredWorktrees(
        porcelainOutput: String,
        repository: URL,
        suppliedRoot: URL,
        fileManager: FileManager
    ) -> [AgentManagedWorktree] {
        // The same admission rule `create` applies: a root that does not
        // exist as a directory, or sits inside the repository, is not a
        // managed root this service would have written.
        guard let root = secureExistingDirectory(
            suppliedRoot,
            fileManager: fileManager
        ), !isWithin(root, root: repository) else {
            return []
        }
        // Git prints canonical paths with symlinks resolved, while records
        // captured at creation keep the spelling the caller supplied. Compare
        // against the resolved root, rebuild with the supplied one, and the
        // discovered twin matches its live record exactly.
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL

        var recognized: [AgentManagedWorktree] = []
        var listedNames = Set<String>()
        for entry in AgentWorktreeListParser.entries(
            inPorcelainOutput: porcelainOutput
        ) {
            let listedRoot = URL(
                fileURLWithPath: entry.path,
                isDirectory: true
            ).standardizedFileURL
            let name = listedRoot.lastPathComponent
            guard listedRoot.deletingLastPathComponent() == resolvedRoot,
                  let taskID = AgentWorktreeListParser.taskID(
                      forLowercaseUUIDName: name
                  ) else { continue }
            listedNames.insert(name)
            // A checkout git recognises but that is detached (or bare) has
            // no branch to recover. It is labelled for exactly what it is —
            // never the task UUID pretending to be a branch name, which the
            // removal confirmation would then quote back as one.
            recognized.append(discoveredWorktree(
                taskID: taskID,
                branchName: entry.branch ?? Self.detachedBranchLabel,
                gitRecognizes: true,
                repository: repository,
                managedRoot: root
            ))
        }

        // UUID-named directories git said nothing about. Shown, not acted
        // on: their rows come back unavailable because no git command will
        // inspect them, and the fail-closed service paths refuse them anyway.
        var unrecognized: [AgentManagedWorktree] = []
        let children = (try? fileManager.contentsOfDirectory(
            atPath: root.path
        )) ?? []
        for name in children.sorted() {
            let child = root.appendingPathComponent(name, isDirectory: true)
            guard let taskID = AgentWorktreeListParser.taskID(
                forLowercaseUUIDName: name
            ), !listedNames.contains(name) else { continue }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(
                atPath: child.path,
                isDirectory: &isDirectory
            ), isDirectory.boolValue else { continue }
            unrecognized.append(discoveredWorktree(
                taskID: taskID,
                branchName: name,
                gitRecognizes: false,
                repository: repository,
                managedRoot: root
            ))
        }

        return recognized + unrecognized
    }

    /// One rebuilt record. `baseCommit` is never invented, and a proof is
    /// only claimed for a worktree git currently recognises — recomputed
    /// live, the same value `create` captured, never a remembered one.
    private static func discoveredWorktree(
        taskID: UUID,
        branchName: String,
        gitRecognizes: Bool,
        repository: URL,
        managedRoot: URL
    ) -> AgentManagedWorktree {
        // The validated directory name is the task UUID, so the rebuilt root
        // is exactly the destination spelling `create` used.
        let worktreeRoot = managedRoot.appendingPathComponent(
            taskID.uuidString.lowercased(),
            isDirectory: true
        ).standardizedFileURL
        let identity = AgentTaskProjectIdentity(
            canonicalProjectPath: repository.path,
            canonicalWorktreePath: worktreeRoot.path
        )
        return AgentManagedWorktree(
            taskID: taskID,
            repositoryRoot: repository,
            managedRoot: managedRoot,
            worktreeRoot: worktreeRoot,
            branchName: branchName,
            baseCommit: nil,
            repositoryProof: gitRecognizes
                ? RecentAgentTaskFilesystemValidator.repositoryProof(
                    for: identity
                )
                : nil
        )
    }

    func inspectRemoval(
        _ worktree: AgentManagedWorktree
    ) async -> Result<AgentWorktreeRemovalInspection, AgentWorktreeRemovalFailure> {
        guard secureManagedWorktree(worktree) else {
            return .failure(.unsafeWorktree)
        }
        let result = await runner.run([
            "status", "--porcelain=v1", "-z", "--untracked-files=all",
        ], worktree.worktreeRoot)
        guard result.succeeded else {
            return .failure(.inspectionFailed)
        }
        return .success(AgentWorktreeRemovalInspection(
            worktree: worktree,
            dirtyPaths: Self.dirtyPaths(result.output)
        ))
    }

    func remove(
        _ worktree: AgentManagedWorktree,
        confirmation: AgentWorktreeRemovalConfirmation? = nil
    ) async -> AgentWorktreeRemovalResult {
        let inspection: AgentWorktreeRemovalInspection
        switch await inspectRemoval(worktree) {
        case .failure(let failure): return .failed(failure)
        case .success(let value): inspection = value
        }

        if inspection.requiresDestructiveConfirmation {
            guard let confirmation else {
                return .failed(.confirmationRequired(inspection))
            }
            guard confirmation.acknowledgesUnrecoverableDataLoss,
                  confirmation.worktreeRoot.standardizedFileURL
                    == worktree.worktreeRoot.standardizedFileURL,
                  confirmation.dirtyPaths == inspection.dirtyPaths else {
                return .failed(.confirmationMismatch)
            }
        } else if confirmation != nil {
            return .failed(.confirmationMismatch)
        }

        var arguments = ["worktree", "remove"]
        if inspection.requiresDestructiveConfirmation {
            arguments.append("--force")
        }
        arguments += ["--", worktree.worktreeRoot.path]
        let result = await runner.run(arguments, worktree.repositoryRoot)
        if result.timedOut || result.cancelled {
            return .failed(.removalInterrupted(worktree.worktreeRoot))
        }
        guard result.completedSuccessfully else {
            return .failed(.gitRejected(diagnostic(result)))
        }
        return .removed
    }

    func previewIntegration(
        _ worktree: AgentManagedWorktree,
        previewID: UUID = UUID()
    ) async -> AgentWorktreeIntegrationPreviewResult {
        guard secureManagedWorktree(worktree) else {
            return .failed(.unsafeWorktree)
        }
        guard let sourceCommit = await currentSourceCommit(worktree) else {
            return .failed(.sourceBranchChanged)
        }
        let sourceStatus = await statusPaths(at: worktree.worktreeRoot)
        guard let sourceStatus else {
            return .failed(.gitRejected("Unable to inspect source worktree"))
        }
        guard sourceStatus.isEmpty else {
            return .failed(.sourceWorktreeDirty(sourceStatus))
        }
        guard let target = await primarySnapshot(worktree.repositoryRoot) else {
            return .failed(.targetSnapshotUnavailable)
        }
        guard let targetBranch = target.branch else {
            return .failed(.targetDetached)
        }
        let targetDirtyPaths = Self.dirtyPaths(target.status)
        guard targetDirtyPaths.isEmpty else {
            return .failed(.targetCheckoutDirty(targetDirtyPaths))
        }

        let changes = await runner.run([
            "diff", "--name-only", "-z",
            "\(target.head)...\(sourceCommit)", "--",
        ], worktree.repositoryRoot)
        guard changes.succeeded else {
            return .failed(.gitRejected(diagnostic(changes)))
        }
        let changedPaths = Self.canonicalNULPaths(changes.output)
        guard !changedPaths.isEmpty else { return .failed(.noChanges) }

        let merge = await runner.run([
            "merge-tree", "--write-tree", "--name-only", "-z",
            target.head, sourceCommit,
        ], worktree.repositoryRoot)
        guard !merge.timedOut,
              !merge.cancelled,
              merge.outputCaptureComplete,
              merge.errorOutputCaptureComplete,
              !merge.outputTruncated,
              !merge.errorOutputTruncated,
              merge.exitCode == 0 || merge.exitCode == 1 else {
            return .failed(.gitRejected(diagnostic(merge)))
        }
        let conflicts = merge.exitCode == 1
            ? Self.mergeTreeConflictPaths(merge.output)
            : []
        guard merge.exitCode == 0 || !conflicts.isEmpty else {
            return .failed(.gitRejected("Git reported an unparseable conflict"))
        }

        return .ready(AgentWorktreeIntegrationPreview(
            id: previewID,
            worktree: worktree,
            sourceCommit: sourceCommit,
            targetRoot: worktree.repositoryRoot,
            targetHead: target.head,
            targetBranch: targetBranch,
            targetIndexDigest: target.indexDigest,
            changedPaths: changedPaths,
            conflictingPaths: conflicts
        ))
    }

    func integrate(
        _ preview: AgentWorktreeIntegrationPreview,
        confirmation: AgentWorktreeIntegrationConfirmation
    ) async -> AgentWorktreeIntegrationResult {
        guard confirmation.previewID == preview.id,
              confirmation.sourceCommit == preview.sourceCommit,
              confirmation.targetHead == preview.targetHead,
              confirmation.targetBranch == preview.targetBranch,
              confirmation.changedPaths == preview.changedPaths else {
            return .failed(.confirmationMismatch)
        }
        guard !preview.hasConflicts else {
            return .failed(.conflictsRequireResolution(
                preview.conflictingPaths
            ))
        }
        guard secureManagedWorktree(preview.worktree),
              await currentSourceCommit(preview.worktree)
                == preview.sourceCommit,
              await statusPaths(at: preview.worktree.worktreeRoot)?.isEmpty
                == true else {
            return .failed(.sourceChanged)
        }
        guard let currentTarget = await primarySnapshot(preview.targetRoot),
              currentTarget.head == preview.targetHead,
              currentTarget.branch == preview.targetBranch,
              currentTarget.indexDigest == preview.targetIndexDigest,
              currentTarget.status.isEmpty else {
            return .failed(.targetChanged)
        }

        let result = await runner.run([
            "merge", "--no-commit", "--no-ff", "--no-edit",
            preview.sourceCommit,
        ], preview.targetRoot)
        if result.timedOut || result.cancelled {
            return .failed(.integrationInterrupted(preview.targetRoot))
        }
        guard result.completedSuccessfully else {
            return .failed(.manualRecoveryRequired(diagnostic(result)))
        }
        return .integratedWithoutCommit
    }

    private func canonicalRepository(_ candidate: URL) async -> URL? {
        guard let directory = Self.secureExistingDirectory(
            candidate,
            fileManager: fileManager
        ) else {
            return nil
        }
        let result = await runner.run([
            "rev-parse", "--path-format=absolute", "--show-toplevel",
        ], directory)
        guard result.succeeded,
              let path = singleLine(result.output) else { return nil }
        let canonical = URL(fileURLWithPath: path, isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        return Self.secureExistingDirectory(canonical, fileManager: fileManager)
    }

    private func isValidBranch(
        _ branch: String,
        repository: URL
    ) async -> Bool {
        guard !branch.isEmpty,
              branch.utf8.count <= 255,
              !branch.utf8.contains(0),
              !branch.hasPrefix("-") else { return false }
        return await runner.run(
            ["check-ref-format", "--branch", branch],
            repository
        ).succeeded
    }

    private func resolvedCommit(
        _ startPoint: String,
        repository: URL
    ) async -> String? {
        guard !startPoint.isEmpty,
              startPoint.utf8.count <= 1_024,
              !startPoint.utf8.contains(0),
              !startPoint.hasPrefix("-") else { return nil }
        let result = await runner.run([
            "rev-parse", "--verify", "--end-of-options",
            "\(startPoint)^{commit}",
        ], repository)
        guard result.succeeded,
              let commit = singleLine(result.output),
              commit.count == 40,
              commit.allSatisfy({ $0.isHexDigit }) else { return nil }
        return commit.lowercased()
    }

    private func primarySnapshot(
        _ repository: URL
    ) async -> AgentWorktreePrimarySnapshot? {
        let head = await runner.run(
            ["rev-parse", "--verify", "HEAD"],
            repository
        )
        let branch = await runner.run(
            ["symbolic-ref", "--quiet", "HEAD"],
            repository
        )
        let status = await runner.run([
            "status", "--porcelain=v1", "-z", "--untracked-files=all",
        ], repository)
        let indexPath = await runner.run([
            "rev-parse", "--path-format=absolute", "--git-path", "index",
        ], repository)
        guard head.succeeded,
              status.succeeded,
              indexPath.succeeded,
              let headValue = singleLine(head.output),
              let indexValue = singleLine(indexPath.output),
              let digest = boundedDigest(URL(fileURLWithPath: indexValue)) else {
            return nil
        }
        return AgentWorktreePrimarySnapshot(
            head: headValue,
            branch: branch.succeeded ? singleLine(branch.output) : nil,
            status: status.output,
            indexDigest: digest
        )
    }

    private func currentSourceCommit(
        _ worktree: AgentManagedWorktree
    ) async -> String? {
        let branch = await runner.run(
            ["symbolic-ref", "--quiet", "HEAD"],
            worktree.worktreeRoot
        )
        guard branch.succeeded,
              singleLine(branch.output) == "refs/heads/\(worktree.branchName)"
        else { return nil }
        return await resolvedCommit("HEAD", repository: worktree.worktreeRoot)
    }

    private func statusPaths(at root: URL) async -> [String]? {
        let status = await runner.run([
            "status", "--porcelain=v1", "-z", "--untracked-files=all",
        ], root)
        guard status.succeeded else { return nil }
        return Self.dirtyPaths(status.output)
    }

    private func boundedDigest(_ fileURL: URL) -> String? {
        guard let attributes = try? fileManager.attributesOfItem(
            atPath: fileURL.path
        ), let size = attributes[.size] as? NSNumber,
              size.int64Value >= 0,
              size.int64Value <= 64 * 1_024 * 1_024,
              let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe)
        else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }
            .joined()
    }

    private func secureManagedWorktree(
        _ worktree: AgentManagedWorktree
    ) -> Bool {
        guard let managedRoot = Self.secureExistingDirectory(
                  worktree.managedRoot,
                  fileManager: fileManager
              ),
              let worktreeRoot = Self.secureExistingDirectory(
                  worktree.worktreeRoot,
                  fileManager: fileManager
              ),
              managedRoot == worktree.managedRoot.standardizedFileURL,
              worktreeRoot == worktree.worktreeRoot.standardizedFileURL,
              worktreeRoot.deletingLastPathComponent() == managedRoot else {
            return false
        }
        return Self.isWithin(worktreeRoot, root: managedRoot)
    }

    /// Rejects every symlink component instead of merely resolving it. This
    /// prevents a managed destination from silently moving between review and
    /// mutation.
    private static func secureExistingDirectory(
        _ url: URL,
        fileManager: FileManager
    ) -> URL? {
        let supplied = url.standardizedFileURL
        guard supplied.isFileURL,
              supplied.path.hasPrefix("/"),
              !supplied.path.utf8.contains(0),
              !isSymbolicLink(supplied.path) else {
            return nil
        }
        // `/var` and `/tmp` are Apple's stable system aliases into `/private`,
        // and Foundation may return either spelling for temporary directories.
        // Every other symlink component remains rejected.
        guard pathComponentsContainNoSymlink(supplied.path, fileManager: fileManager)
        else {
            return nil
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: supplied.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else { return nil }
        return supplied
    }

    private static func isSymbolicLink(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFLNK
    }

    private static func pathComponentsContainNoSymlink(
        _ path: String,
        fileManager: FileManager
    ) -> Bool {
        var current = ""
        for component in URL(fileURLWithPath: path).pathComponents {
            if component == "/" {
                current = "/"
                continue
            }
            current = URL(fileURLWithPath: current, isDirectory: true)
                .appendingPathComponent(component).path
            var info = stat()
            guard lstat(current, &info) == 0 else { return false }
            if (info.st_mode & S_IFMT) == S_IFLNK {
                let destination = try? fileManager.destinationOfSymbolicLink(
                    atPath: current
                )
                let isStableSystemAlias = (current, destination) == (
                    "/var", "private/var"
                ) || (current, destination) == ("/tmp", "private/tmp")
                guard isStableSystemAlias else { return false }
            }
        }
        return true
    }

    private static func isWithin(_ candidate: URL, root: URL) -> Bool {
        let candidatePath = candidate.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        return candidatePath == rootPath
            || candidatePath.hasPrefix(rootPath.hasSuffix("/")
                ? rootPath
                : rootPath + "/")
    }

    private func singleLine(_ output: String) -> String? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains("\n"),
              !trimmed.contains("\r"),
              !trimmed.utf8.contains(0) else { return nil }
        return trimmed
    }

    private func diagnostic(_ result: GitCommandResult) -> String {
        let value = result.errorOutput.isEmpty
            ? result.output
            : result.errorOutput
        return String(value.prefix(1_024))
    }

    private static func dirtyPaths(_ output: String) -> [String] {
        var seen: Set<String> = []
        var paths: [String] = []
        let records = output.split(separator: "\0")
        var index = records.startIndex
        while index < records.endIndex {
            let record = records[index]
            guard record.utf8.count >= 4 else {
                index = records.index(after: index)
                continue
            }
            let status = record.prefix(2)
            appendCanonicalPath(
                String(record.dropFirst(3)),
                seen: &seen,
                paths: &paths
            )
            index = records.index(after: index)
            if status.contains("R") || status.contains("C"),
               index < records.endIndex {
                appendCanonicalPath(
                    String(records[index]),
                    seen: &seen,
                    paths: &paths
                )
                index = records.index(after: index)
            }
        }
        return paths.sorted()
    }

    private static func appendCanonicalPath(
        _ path: String,
        seen: inout Set<String>,
        paths: inout [String]
    ) {
        guard AgentHistoryUndoPreflight.isCanonicalRelativePath(path),
              seen.insert(path).inserted else { return }
        paths.append(path)
    }

    private static func canonicalNULPaths(_ output: String) -> [String] {
        var seen: Set<String> = []
        return output.split(separator: "\0").compactMap { rawPath in
            let path = String(rawPath)
            guard AgentHistoryUndoPreflight.isCanonicalRelativePath(path),
                  seen.insert(path).inserted else { return nil }
            return path
        }.sorted()
    }

    private static func mergeTreeConflictPaths(_ output: String) -> [String] {
        let fields = output.split(
            separator: "\0",
            omittingEmptySubsequences: false
        )
        // `merge-tree --write-tree --name-only -z` emits the tree object,
        // followed by conflict paths, then an empty separator and messages.
        guard fields.count > 2 else { return [] }
        let pathFields = fields.dropFirst().prefix { !$0.isEmpty }
        return canonicalNULPaths(pathFields.map(String.init).joined(
            separator: "\0"
        ))
    }
}

nonisolated private struct AgentWorktreePrimarySnapshot: Equatable {
    let head: String
    let branch: String?
    let status: String
    let indexDigest: String
}
