import Darwin
import Foundation

nonisolated enum AgentTaskReservedWorktreeSetupResult: Sendable, Equatable {
    case inProgress, blocked, reconciliationRequired, adopted
}

/// Deterministic Git setup, not a recipe runner or provider/execution grant.
/// Every uncertain mutation is fenced by a durable intent before dispatch.
actor AgentTaskReservedWorktreeSetup {
    typealias Persist = @Sendable (AgentTaskReservedWorktreeCheckpoint) async throws -> Bool

    private let lease: AgentTaskEnvironmentSetupLease
    private let bindings: AgentTaskEnvironmentBindings
    private let calls: GitCommandSystemCalls
    private let timeout: TimeInterval
    private let revocation = GitCommandCancellationToken()
    private var checkpoint: AgentTaskReservedWorktreeCheckpoint?
    private var checkpointDurable: Bool
    private var result: AgentTaskReservedWorktreeSetupResult?
    private var binding: AgentTaskEnvironmentBinding?
    private var busy = false

    init(
        lease: AgentTaskEnvironmentSetupLease,
        bindings: AgentTaskEnvironmentBindings,
        recovering checkpoint: AgentTaskReservedWorktreeCheckpoint? = nil,
        systemCalls: GitCommandSystemCalls = .live,
        timeout: TimeInterval = 15
    ) {
        self.lease = lease
        self.bindings = bindings
        self.checkpoint = checkpoint
        self.checkpointDurable = checkpoint != nil
        self.calls = systemCalls
        self.timeout = timeout.isFinite ? min(max(timeout, 0.1), 15) : 15
        if checkpoint != nil { result = .reconciliationRequired }
    }

    nonisolated var isRevoked: Bool { revocation.isCancelled }
    nonisolated func revokeAuthority() {
        revocation.cancel()
        lease.revokeAuthority()
    }

    func releaseRevokedReservation() async {
        guard isRevoked else { return }
        await bindings.revoke(lease)
    }

    /// persist must return true ONLY for the current exact checkpoint's
    /// durably-saved CAS receipt, never for publishedButDurabilityUnknown.
    func create(persist: Persist) async -> AgentTaskReservedWorktreeSetupResult {
        guard !isRevoked else { return .reconciliationRequired }
        if let result { return result }
        guard !busy, !isRevoked, !Task.isCancelled, lease.claimCreationAttempt() else { return .reconciliationRequired }
        busy = true
        result = .inProgress
        defer { busy = false }
        let lease = self.lease
        let calls = self.calls
        let base: String? = await runOnBackground {
            guard lease.revalidate() else { return nil }
            let head = Self.git(["rev-parse", "--verify", "--end-of-options", "HEAD^{commit}"],
                at: lease.project, calls: calls, validate: { lease.revalidate() })
            let value = head.output.trimmingCharacters(in: .whitespacesAndNewlines)
            let listing = Self.git(["worktree", "list", "--porcelain", "-z"],
                at: lease.project, calls: calls, validate: { lease.revalidate() })
            guard head.succeeded, head.outputIsValidUTF8, Self.validCommit(value),
                  listing.succeeded, listing.outputIsValidUTF8, listing.output.hasSuffix("\0\0"),
                  !AgentWorktreeListParser.entries(inPorcelainOutput: listing.output).contains(where: {
                      let path = URL(fileURLWithPath: $0.path)
                      return path.deletingLastPathComponent().resolvingSymlinksInPath()
                          .appendingPathComponent(path.lastPathComponent).path == lease.expectedWorktree.path
                  }), lease.revalidate() else { return nil }
            return value
        }
        guard let base, !Task.isCancelled else { result = .blocked; return .blocked }
        let intent = AgentTaskReservedWorktreeCheckpoint(
            reservation: lease.snapshot, baseCommit: base, phase: .creationIntent, worktreeProof: nil
        )
        guard await save(intent, persist: persist) else { return .reconciliationRequired }
        let cancellation = revocation
        let timeout = self.timeout
        let created = await withTaskCancellationHandler {
            if Task.isCancelled { cancellation.cancel() }
            return await runOnBackground {
                Self.git([
                    "worktree", "add", "--no-checkout", "--no-track", "--no-guess-remote",
                    "-b", AgentTaskEnvironmentBindings.branchName(taskID: lease.taskID, runID: lease.reservationRunID),
                    "--", lease.expectedWorktree.path, base
                ], at: lease.project, calls: calls, cancellation: cancellation, timeout: timeout, validate: { lease.revalidate() })
            }
        } onCancel: { cancellation.cancel() }
        guard created.succeeded, !Task.isCancelled else {
            result = .reconciliationRequired
            return .reconciliationRequired
        }
        do {
            _ = try await finish(persist: persist)
            result = .adopted
            return .adopted
        } catch {
            result = .reconciliationRequired
            return .reconciliationRequired
        }
    }

    /// Explicit recovery never issues worktree add. An already-dispatched
    /// population is verified, never repeated; incomplete artifacts stay put.
    func reconcile(persist: Persist) async throws -> AgentTaskEnvironmentBinding {
        guard !busy, !isRevoked else { throw AgentTaskEnvironmentBindingError.unavailableEnvironment }
        busy = true
        result = .reconciliationRequired
        defer { busy = false }
        let value = try await finish(persist: persist)
        result = .adopted
        return value
    }

    private func save(_ value: AgentTaskReservedWorktreeCheckpoint, persist: Persist) async -> Bool {
        guard !isRevoked else { result = .reconciliationRequired; return false }
        // Fence locally BEFORE awaiting persistence: an unknown publication
        // must not let this owner retry the effect from an older phase.
        checkpoint = value
        checkpointDurable = false
        do {
            guard try await persist(value), !Task.isCancelled, !isRevoked else {
                result = .reconciliationRequired
                return false
            }
            checkpointDurable = true
            return true
        } catch {
            result = .reconciliationRequired
            return false
        }
    }

    private func finish(persist: Persist) async throws -> AgentTaskEnvironmentBinding {
        guard let checkpoint else { throw AgentTaskEnvironmentBindingError.unavailableEnvironment }
        let phaseIsValid = checkpoint.phase == .creationIntent
            ? checkpoint.worktreeProof == nil : checkpoint.worktreeProof?.hasExactWorktreeInstance == true
        guard checkpoint.scheme == AgentTaskReservedWorktreeCheckpoint.currentScheme,
              phaseIsValid, Self.validCommit(checkpoint.baseCommit),
              checkpoint.reservation.taskID == lease.taskID,
              checkpoint.reservation.reservationRunID == lease.reservationRunID,
              checkpoint.reservation.project.path == lease.project.path,
              checkpoint.reservation.expectedWorktree.path == lease.expectedWorktree.path,
              checkpoint.reservation.repositoryProof.identifiesSameRepository(as: lease.snapshot.repositoryProof),
              checkpoint.reservation.projectRoot.identifiesSameObject(as: lease.snapshot.projectRoot),
              checkpoint.reservation.parentRoot.identifiesSameObject(as: lease.snapshot.parentRoot) else {
            throw AgentTaskEnvironmentBindingError.unavailableEnvironment
        }
        let lease = self.lease
        let calls = self.calls
        let existingBinding = binding
        let boundFilesystem: RecentAgentTaskFilesystemValidationLease? =
            if let existingBinding { try await bindings.revalidate(existingBinding) } else { nil }
        let view = try await runOnBackground {
            guard let filesystem = boundFilesystem ?? lease.createdFilesystemLease(),
                  let proof = filesystem.proof,
                  checkpoint.worktreeProof.map({ proof.identifiesSameWorktreeInstance(as: $0) }) ?? true else {
                throw AgentTaskEnvironmentBindingError.unavailableEnvironment
            }
            return try IsolatedGitView(lease: lease, filesystem: filesystem, binding: existingBinding,
                base: checkpoint.baseCommit, calls: calls)
        }
        let alreadyPopulated = await runOnBackground { view.verify() }
        if !alreadyPopulated {
            guard checkpoint.phase == .creationIntent else { throw AgentTaskEnvironmentBindingError.unavailableEnvironment }
            let population = checkpoint.advancing(to: .populationIntent, proof: view.proof)
            guard await save(population, persist: persist) else { throw AgentTaskEnvironmentBindingError.unavailableEnvironment }
            let cancellation = revocation
            let timeout = self.timeout
            let populated = await withTaskCancellationHandler {
                if Task.isCancelled { cancellation.cancel() }
                return await runOnBackground { view.populate(cancellation: cancellation, timeout: timeout) }
            } onCancel: { cancellation.cancel() }
            guard populated, !Task.isCancelled,
                  await runOnBackground({ view.verify() }) else { throw AgentTaskEnvironmentBindingError.unavailableEnvironment }
        }
        try Task.checkCancellation()
        if checkpoint.phase != .populated || !checkpointDurable {
            guard await save(checkpoint.advancing(to: .populated, proof: view.proof), persist: persist) else {
                throw AgentTaskEnvironmentBindingError.unavailableEnvironment
            }
        }
        let adopted: AgentTaskEnvironmentBinding
        if let binding {
            adopted = binding
        } else {
            adopted = try await bindings.adopt(taskID: lease.taskID, runID: lease.reservationRunID, candidates: [lease.expectedWorktree])
            binding = adopted
        }
        let finalLease = try await bindings.revalidate(adopted)
        let head = await runOnBackground {
            Self.git(["rev-parse", "--verify", "HEAD"], at: lease.expectedWorktree, calls: calls, validate: {
                finalLease.revalidate() && (try? adopted.validateAuthority()) != nil
            })
        }
        guard finalLease.proof?.identifiesSameWorktreeInstance(as: view.proof) == true,
              head.succeeded, head.output.trimmingCharacters(in: .whitespacesAndNewlines) == checkpoint.baseCommit else {
            throw AgentTaskEnvironmentBindingError.staleBinding
        }
        return adopted
    }

    nonisolated static func arguments(_ command: [String], environment: [String] = []) -> [String] {
        [
            "-i", "PATH=/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM=1", "GIT_CONFIG_GLOBAL=/dev/null",
            "GIT_ATTR_NOSYSTEM=1", "GIT_NO_LAZY_FETCH=1", "GIT_TERMINAL_PROMPT=0", "GIT_OPTIONAL_LOCKS=0"
        ] + environment + [
            "/usr/bin/git", "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false",
            "-c", "core.attributesFile=/dev/null", "-c", "submodule.recurse=false",
            "-c", "gc.auto=0", "-c", "maintenance.auto=false", "-c", "protocol.allow=never"
        ] + command
    }

    nonisolated private static func validCommit(_ value: String) -> Bool {
        [40, 64].contains(value.utf8.count)
            && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    nonisolated private static func git(
        _ command: [String], at directory: URL, calls: GitCommandSystemCalls,
        environment: [String] = [], cancellation: GitCommandCancellationToken? = nil, timeout: TimeInterval = 15,
        validate: @escaping @Sendable () -> Bool
    ) -> GitCommandResult {
        let guarded = GitCommandSystemCalls(read: calls.read, waitpid: calls.waitpid, kill: calls.kill) { executable, argv, directory in
            guard cancellation?.isCancelled != true, validate(),
                  let env = RecentAgentTaskFilesystemValidator.selectedFileLease(for: executable),
                  let git = RecentAgentTaskFilesystemValidator.selectedFileLease(for: URL(fileURLWithPath: "/usr/bin/git")),
                  env.revalidate(), git.revalidate(), validate() else {
                return .failure(GitCommandLaunchError(code: ECANCELED))
            }
            return calls.spawn(executable, argv, directory)
        }
        return GitCommand.runExecutable(URL(fileURLWithPath: "/usr/bin/env"),
            arguments: arguments(command, environment: environment), at: directory, timeout: timeout,
            captureLimit: 4 * 1_024 * 1_024, cancellationToken: cancellation, systemCalls: guarded)
    }

    /// A private Git directory with only Pine-written configuration and an
    /// alternate object store. Never reuse a persisted view or read user config.
    nonisolated private struct IsolatedGitView: Sendable {
        let lease: AgentTaskEnvironmentSetupLease
        let filesystem: RecentAgentTaskFilesystemValidationLease
        let binding: AgentTaskEnvironmentBinding?
        let proof: RecentAgentTaskRepositoryProof
        let gitDirectory: URL
        let directory: URL
        let directoryLease: RecentAgentTaskFilesystemValidationLease
        let objectsLease: RecentAgentTaskFilesystemValidationLease
        let base: String
        let emptyTree: String
        let calls: GitCommandSystemCalls

        init(
            lease: AgentTaskEnvironmentSetupLease, filesystem: RecentAgentTaskFilesystemValidationLease,
            binding: AgentTaskEnvironmentBinding?, base: String, calls: GitCommandSystemCalls
        ) throws {
            guard let proof = filesystem.proof else { throw AgentTaskEnvironmentBindingError.unavailableEnvironment }
            let validate: @Sendable () -> Bool = {
                filesystem.revalidate() && (binding.map { (try? $0.validateAuthority()) != nil } ?? lease.revalidateOrigin())
            }
            func metadata(_ args: [String], at root: URL) throws -> String {
                let result = AgentTaskReservedWorktreeSetup.git(args, at: root, calls: calls, validate: validate)
                guard result.succeeded, result.outputIsValidUTF8 else { throw AgentTaskEnvironmentBindingError.unavailableEnvironment }
                return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let head = try metadata(["rev-parse", "--verify", "HEAD"], at: lease.expectedWorktree)
            let branch = try metadata(["symbolic-ref", "--short", "HEAD"], at: lease.expectedWorktree)
            guard head == base, branch == AgentTaskEnvironmentBindings.branchName(taskID: lease.taskID, runID: lease.reservationRunID) else {
                throw AgentTaskEnvironmentBindingError.unavailableEnvironment
            }
            let gitDirectory = URL(fileURLWithPath: try metadata(["rev-parse", "--absolute-git-dir"], at: lease.expectedWorktree))
            var gitInfo = stat()
            guard lstat(gitDirectory.path, &gitInfo) == 0,
                  proof.worktreeGitDirectory?.identifiesSameObject(as: RecentAgentTaskFilesystemObjectProof(
                    device: UInt64(truncatingIfNeeded: gitInfo.st_dev), inode: UInt64(gitInfo.st_ino), generation: UInt64(gitInfo.st_gen),
                    birthSeconds: Int64(gitInfo.st_birthtimespec.tv_sec), birthNanoseconds: Int64(gitInfo.st_birthtimespec.tv_nsec), kind: S_IFDIR
                  )) == true, Self.unlocked(gitDirectory) else { throw AgentTaskEnvironmentBindingError.unavailableEnvironment }
            let common = URL(fileURLWithPath: try metadata(["rev-parse", "--path-format=absolute", "--git-common-dir"], at: lease.project))
            var info = stat()
            guard lstat(common.path, &info) == 0,
                  RecentAgentTaskRepositoryProof(commonDirectoryDevice: UInt64(truncatingIfNeeded: info.st_dev),
                    commonDirectoryInode: UInt64(info.st_ino), commonDirectoryGeneration: UInt64(info.st_gen),
                    commonDirectoryBirthSeconds: Int64(info.st_birthtimespec.tv_sec),
                    commonDirectoryBirthNanoseconds: Int64(info.st_birthtimespec.tv_nsec)).identifiesSameRepository(as: proof) else {
                throw AgentTaskEnvironmentBindingError.unavailableEnvironment
            }
            let objects = common.appendingPathComponent("objects").standardizedFileURL
            guard objects.resolvingSymlinksInPath().path == objects.path,
                  !objects.path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  let objectsLease = Self.directoryLease(objects) else { throw AgentTaskEnvironmentBindingError.unavailableEnvironment }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PineReservedGitView-\(UUID())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try FileManager.default.createDirectory(at: directory.appendingPathComponent("objects/info"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: directory.appendingPathComponent("refs"), withIntermediateDirectories: false)
            let format = base.count == 64 ? "1\n[extensions]\nobjectFormat=sha256\n" : "0\n"
            for (name, value) in [
                ("HEAD", "ref: refs/heads/pine-setup\n"),
                ("config", "[core]\nbare=false\nfileMode=true\nsymlinks=true\nrepositoryformatversion=\(format)"),
                ("objects/info/alternates", objects.path + "\n")
            ] {
                try Data(value.utf8).write(to: directory.appendingPathComponent(name), options: .withoutOverwriting)
            }
            guard let directoryLease = Self.directoryLease(directory) else { throw AgentTaskEnvironmentBindingError.unavailableEnvironment }
            let empty = AgentTaskReservedWorktreeSetup.git(["--git-dir=\(directory.path)", "mktree"], at: directory, calls: calls,
                validate: { validate() && objectsLease.revalidate() && directoryLease.revalidate() })
            let emptyTree = empty.output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard empty.succeeded, validCommit(emptyTree) else { throw AgentTaskEnvironmentBindingError.unavailableEnvironment }
            self.lease = lease
            self.filesystem = filesystem
            self.binding = binding
            self.proof = proof
            self.gitDirectory = gitDirectory
            self.directory = directory
            self.directoryLease = directoryLease
            self.objectsLease = objectsLease
            self.base = base
            self.emptyTree = emptyTree
            self.calls = calls
            // shortcut: gitlinks and oversized trees fail closed, add scoped setup when those projects require it.
            let tree = run(["ls-tree", "-r", "--full-tree", "--long", "-z", base])
            var total = 0
            let entries = tree.output.split(separator: "\0")
            guard tree.succeeded, tree.outputIsValidUTF8, entries.count <= 20_000 else {
                throw AgentTaskEnvironmentBindingError.unavailableEnvironment
            }
            for entry in entries {
                let header = entry.prefix { $0 != "\t" }.split(whereSeparator: { $0 == " " })
                guard header.count == 4, ["100644", "100755", "120000"].contains(String(header[0])),
                      header[1] == "blob", let size = Int(header[3]), size >= 0, size <= 64 * 1_024 * 1_024,
                      total <= 512 * 1_024 * 1_024 - size else { throw AgentTaskEnvironmentBindingError.unavailableEnvironment }
                total += size
            }
        }

        func validate() -> Bool {
            filesystem.revalidate() && directoryLease.revalidate() && objectsLease.revalidate()
                && Self.unlocked(gitDirectory)
                && (binding.map { (try? $0.validateAuthority()) != nil } ?? lease.revalidateOrigin())
        }

        func run(_ command: [String], environment: [String] = [], cancellation: GitCommandCancellationToken? = nil,
                 timeout: TimeInterval = 15, extraValidation: @escaping @Sendable () -> Bool = { true }) -> GitCommandResult {
            AgentTaskReservedWorktreeSetup.git([
                "--attr-source=\(emptyTree)", "--git-dir=\(directory.path)", "--work-tree=\(lease.expectedWorktree.path)"
            ] + command, at: directory, calls: calls, environment: environment, cancellation: cancellation, timeout: timeout,
                validate: { validate() && extraValidation() })
        }

        func indexPath() -> URL? {
            validate() ? gitDirectory.appendingPathComponent("index") : nil
        }

        func populate(cancellation: GitCommandCancellationToken, timeout: TimeInterval) -> Bool {
            guard let index = indexPath() else { return false }
            let emptyTarget: @Sendable () -> Bool = {
                var info = stat()
                return lstat(index.path, &info) == -1 && errno == ENOENT
                    && (try? FileManager.default.contentsOfDirectory(atPath: lease.expectedWorktree.path)) == [".git"]
            }
            guard emptyTarget() else { return false }
            // No reset/force: even an unexpected untracked collision must fail
            // rather than overwrite. Git preserves blob bytes/modes/symlinks.
            return run(["read-tree", "-m", "-u", base], environment: ["GIT_INDEX_FILE=\(index.path)"],
                cancellation: cancellation, timeout: timeout, extraValidation: emptyTarget).succeeded
        }

        func verify() -> Bool {
            guard let index = indexPath(),
                  let indexLease = RecentAgentTaskFilesystemValidator.selectedFileLease(for: index),
                  run(["diff", "--cached", "--quiet", "--no-ext-diff", "--no-textconv", "--no-renames", base, "--"],
                    environment: ["GIT_INDEX_FILE=\(index.path)"], extraValidation: { indexLease.revalidate() }).succeeded else { return false }
            // A fresh private index has no trusted worktree stat cache. This
            // comparison reads actual bytes, not a prior command's success.
            guard run(["read-tree", base]).succeeded else { return false }
            let untracked = run(["ls-files", "--others", "-z", "--"])
            return untracked.succeeded && untracked.output.isEmpty
                && run(["diff", "--quiet", "--no-ext-diff", "--no-textconv", "--no-renames", base, "--"]).succeeded
                && indexLease.revalidate() && validate()
        }

        static func directoryLease(_ url: URL) -> RecentAgentTaskFilesystemValidationLease? {
            RecentAgentTaskFilesystemValidator.validationLease(
                for: AgentTaskProjectIdentity(canonicalProjectPath: url.path, canonicalWorktreePath: url.path), expectedProof: nil
            )
        }

        static func unlocked(_ gitDirectory: URL) -> Bool {
            // Git marks in-progress worktree initialization and index writes.
            // Never interpret those live/uncertain artifacts as adoptable.
            ["locked", "index.lock"].allSatisfy {
                var info = stat()
                return lstat(gitDirectory.appendingPathComponent($0).path, &info) == -1 && errno == ENOENT
            }
        }
    }
}
