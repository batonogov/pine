import CryptoKit
import Darwin
import Foundation

/// Owned bounded Git inspection. The environment is rebuilt for fixed system
/// binaries so inherited GIT_DIR/INDEX/WORK_TREE/CONFIG/TRACING cannot redirect
/// a proof or execute an ambient helper. Repository hooks/fsmonitor are disabled.
nonisolated struct AgentVerificationGitInspector: Sendable {
    let lease: RecentAgentTaskFilesystemValidationLease
    let cancellation: GitCommandCancellationToken
    let deadline: ContinuousClock.Instant
    var maximumPathBytes = 8 * 1_024 * 1_024

    func capture() throws -> AgentVerificationGitSnapshot {
        precondition(!Thread.isMainThread)
        guard lease.revalidate(), maximumPathBytes > 0 else { throw Failure.unavailable }
        var state = State(inspector: self)
        let head = try state.inspectRoot(relative: "", depth: 0)
        guard lease.revalidate() else { throw Failure.changed }
        return AgentVerificationGitSnapshot(
            headCommit: head, indexFingerprint: state.index.finish(),
            trackedPaths: state.tracked, untrackedPaths: state.untracked,
            submodulePaths: state.submodules, rootWitnesses: state.witnesses
        )
    }

    private func query(_ arguments: [String], directory: URL, allowAbsent: Bool = false) throws -> GitCommandResult {
        guard !cancellation.isCancelled else { throw Failure.cancelled }
        guard ContinuousClock.now < deadline else { throw Failure.budget }
        let remaining = ContinuousClock.now.duration(to: deadline).components
        let seconds = Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18
        var environment = [
            "-i", "PATH=/usr/bin:/bin", "LC_ALL=C", "HOME=/var/empty",
            "GIT_CONFIG_NOSYSTEM=1", "GIT_CONFIG_GLOBAL=/dev/null", "GIT_ATTR_NOSYSTEM=1",
            "GIT_TERMINAL_PROMPT=0", "GIT_OPTIONAL_LOCKS=0",
        ]
        // Apple command-line shims need the explicitly selected toolchain;
        // this value selects tools, not a shell command or executable argument.
        if let developer = ProcessInfo.processInfo.environment["DEVELOPER_DIR"],
           developer.hasPrefix("/"), !developer.utf8.contains(0) {
            environment.append("DEVELOPER_DIR=" + developer)
        }
        environment += [
            "/usr/bin/git", "--no-optional-locks", "-c", "core.fsmonitor=false",
            "-c", "core.untrackedCache=false", "-c", "core.hooksPath=/dev/null",
        ]
        let result = GitCommand.runExecutable(
            URL(fileURLWithPath: "/usr/bin/env"), arguments: environment + arguments,
            at: directory, timeout: min(seconds, 2), captureLimit: maximumPathBytes,
            cancellationToken: cancellation
        )
        guard !cancellation.isCancelled else { throw Failure.cancelled }
        guard ContinuousClock.now < deadline else { throw Failure.budget }
        guard result.outputIsValidUTF8, !result.outputTruncated, !result.errorOutputTruncated,
              result.outputCaptureComplete, result.errorOutputCaptureComplete,
              !result.timedOut, !result.cancelled,
              result.exitCode == 0 || (allowAbsent && result.exitCode == 1 && result.errorOutput.isEmpty) else {
            throw Failure.unavailable
        }
        return result
    }

    private struct State {
        let inspector: AgentVerificationGitInspector
        var tracked: Set<String> = []
        var untracked: Set<String> = []
        var submodules: Set<String> = []
        var witnesses: [String: String] = [:]
        var pathBytes = 0
        var inspectedRoots = 0
        var index = AgentVerificationCanonicalHasher(domain: "pine.ade.git-indexes.v2")

        mutating func inspectRoot(relative: String, depth: Int) throws -> String? {
            guard depth <= 16, inspectedRoots < 33 else { throw Failure.budget }
            inspectedRoots += 1
            let directory = relative.isEmpty ? inspector.lease.canonicalWorktree
                : inspector.lease.canonicalWorktree.appendingPathComponent(relative)
            let descriptor = try openContained(relative)
            defer { Darwin.close(descriptor) }
            var root = stat()
            guard fstat(descriptor, &root) == 0 else { throw Failure.unavailable }
            try validateEffectiveWorktree(directory: directory, expected: root)
            var control = stat()
            guard fstatat(descriptor, ".git", &control, AT_SYMLINK_NOFOLLOW) == 0,
                  (control.st_mode & S_IFMT) == S_IFDIR || (control.st_mode & S_IFMT) == S_IFREG,
                  let proof = RecentAgentTaskFilesystemValidator.repositoryProof(forRepository: directory) else {
                throw Failure.unavailable
            }
            witnesses["root:" + relative] = Self.witness(root: root, proof: proof)
            witnesses["control:" + relative] = AgentVerificationMetadataWitness.signature(control)
            let metadataBefore = try metadata(directory: directory)
            let format = try inspector.query(["rev-parse", "--show-object-format"], directory: directory)
                .output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard format == "sha1" || format == "sha256" else { throw Failure.unavailable }
            let length = format == "sha1" ? 40 : 64
            // Includes need their own explicitly scoped input witnesses. Until
            // that coverage exists, never claim the effective config is fenced.
            let includes = try inspector.query(
                ["config", "--no-includes", "--get-regexp", "^(include|includeif\\..*)\\.path$"],
                directory: directory, allowAbsent: true
            )
            guard includes.exitCode == 1 else { throw Failure.unavailable }
            let head = try readHead(directory: directory, length: length)
            index.append("repository", relative)
            index.append("format", format)
            index.append("head", head ?? "unborn")
            let stage = try inspector.query(["ls-files", "--stage", "-z"], directory: directory).output
            index.append("stage", stage)
            let config = try inspector.query(["config", "--list", "--null", "--no-includes"], directory: directory).output
            index.append("local-config", config)
            var childModules: Set<String> = []
            for line in stage.split(separator: "\0", omittingEmptySubsequences: true) {
                guard let tab = line.firstIndex(of: "\t") else { throw Failure.unavailable }
                let fields = line[..<tab].split(separator: " ")
                let path = String(line[line.index(after: tab)...])
                guard fields.count == 3, fields[0].allSatisfy({ ("0"..."7").contains(String($0)) }),
                      fields[0].count == 6,
                      AgentTaskMetadataStore.validLowerHex(String(fields[1]), length: length),
                      ["0", "1", "2", "3"].contains(fields[2]),
                      AgentVerificationCapturePolicy.validRelativePath(path) else { throw Failure.unavailable }
                let complete = relative.isEmpty ? path : relative + "/" + path
                try account(complete)
                tracked.insert(complete)
                if fields[0] == "160000" {
                    guard fields[2] == "0" else { throw Failure.unavailable }
                    childModules.insert(complete)
                }
            }
            let others = try inspector.query(["ls-files", "--others", "--exclude-standard", "-z"], directory: directory).output
            for path in others.split(separator: "\0", omittingEmptySubsequences: true) {
                guard AgentVerificationCapturePolicy.validRelativePath(String(path)) else { throw Failure.unavailable }
                let complete = relative.isEmpty ? String(path) : relative + "/" + path
                try account(complete)
                untracked.insert(complete)
            }
            for child in AgentVerificationCapturePolicy.sorted(childModules) {
                guard submodules.count < 32 else { throw Failure.budget }
                submodules.insert(child)
                _ = try inspectRoot(relative: child, depth: depth + 1)
            }
            try validateEffectiveWorktree(directory: directory, expected: root)
            let metadataAfter = try metadata(directory: directory)
            guard metadataBefore == metadataAfter else { throw Failure.changed }
            for (path, witness) in metadataBefore { witnesses["metadata:" + path] = witness }
            var controlAfter = stat()
            guard fstatat(descriptor, ".git", &controlAfter, AT_SYMLINK_NOFOLLOW) == 0,
                  AgentVerificationMetadataWitness.signature(control) == AgentVerificationMetadataWitness.signature(controlAfter)
            else { throw Failure.changed }
            guard let after = RecentAgentTaskFilesystemValidator.repositoryProof(forRepository: directory),
                  proof.identifiesSameRepository(as: after) else { throw Failure.changed }
            var current = stat()
            guard lstat(directory.path, &current) == 0, current.st_dev == root.st_dev,
                  current.st_ino == root.st_ino, current.st_gen == root.st_gen else { throw Failure.changed }
            return head
        }

        /// Sanitizing inherited Git variables does not neutralize a local
        /// core.worktree setting. Inspect Git's effective root and prove it is
        /// the exact opened directory before and after collecting any paths.
        private func validateEffectiveWorktree(directory: URL, expected: stat) throws {
            let raw = try inspector.query(["rev-parse", "--show-toplevel"], directory: directory).output
            let path = try absolutePath(raw)
            var descriptor = Darwin.open("/", O_SEARCH | O_CLOEXEC)
            guard descriptor >= 0 else { throw Failure.unavailable }
            defer { Darwin.close(descriptor) }
            for component in path.split(separator: "/") {
                guard !inspector.cancellation.isCancelled else { throw Failure.cancelled }
                guard ContinuousClock.now < inspector.deadline else { throw Failure.budget }
                guard component != ".", component != ".." else { throw Failure.unavailable }
                let child = openat(descriptor, String(component), O_SEARCH | O_CLOEXEC | O_NOFOLLOW)
                guard child >= 0 else { throw Failure.unavailable }
                Darwin.close(descriptor)
                descriptor = child
            }
            var effective = stat()
            guard fstat(descriptor, &effective) == 0, effective.st_mode & S_IFMT == S_IFDIR,
                  effective.st_dev == expected.st_dev, effective.st_ino == expected.st_ino,
                  effective.st_gen == expected.st_gen,
                  effective.st_birthtimespec.tv_sec == expected.st_birthtimespec.tv_sec,
                  effective.st_birthtimespec.tv_nsec == expected.st_birthtimespec.tv_nsec else {
                throw Failure.unavailable
            }
        }

        private mutating func account(_ path: String) throws {
            guard AgentVerificationCapturePolicy.validRelativePath(path) else { throw Failure.unavailable }
            pathBytes += path.utf8.count
            guard pathBytes <= inspector.maximumPathBytes, tracked.count + untracked.count < 100_000 else {
                throw Failure.budget
            }
        }

        private func readHead(directory: URL, length: Int) throws -> String? {
            let symbolic = try inspector.query(["symbolic-ref", "--quiet", "HEAD"], directory: directory, allowAbsent: true)
            if symbolic.exitCode == 0 {
                let reference = symbolic.output.trimmingCharacters(in: .whitespacesAndNewlines)
                guard reference.hasPrefix("refs/heads/"), reference.utf8.count <= 1_024,
                      AgentVerificationCapturePolicy.validRelativePath(reference) else { throw Failure.unavailable }
                let present = try inspector.query(["show-ref", "--verify", "--quiet", "--", reference],
                                                  directory: directory, allowAbsent: true)
                if present.exitCode == 1 { return nil }
            }
            let head = try inspector.query(["rev-parse", "--verify", "HEAD"], directory: directory)
                .output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard AgentTaskMetadataStore.validLowerHex(head, length: length) else { throw Failure.unavailable }
            return head
        }

        private func metadata(directory: URL) throws -> [String: String] {
            let gitDirectory = try inspector.query(["rev-parse", "--absolute-git-dir"], directory: directory).output
            let commonDirectory = try inspector.query(
                ["rev-parse", "--path-format=absolute", "--git-common-dir"], directory: directory
            ).output
            var result: [String: String] = [:]
            for raw in Set([gitDirectory, commonDirectory]) {
                let path = try absolutePath(raw)
                for name in ["HEAD", "index", "config", "config.worktree", "commondir", "packed-refs"] {
                    let file = path + "/" + name
                    result[file] = try fileWitness(file)
                }
            }
            let symbolic = try inspector.query(["symbolic-ref", "--quiet", "HEAD"], directory: directory, allowAbsent: true)
            if symbolic.exitCode == 0 {
                guard symbolic.output.hasSuffix("\n") else { throw Failure.unavailable }
                let reference = String(symbolic.output.dropLast())
                guard reference.hasPrefix("refs/heads/"), reference.utf8.count <= 1_024,
                      AgentVerificationCapturePolicy.validRelativePath(reference) else { throw Failure.unavailable }
                let raw = try inspector.query(
                    ["rev-parse", "--path-format=absolute", "--git-path", reference], directory: directory
                ).output
                let path = try absolutePath(raw)
                result[path] = try fileWitness(path)
            }
            return result
        }

        private func absolutePath(_ raw: String) throws -> String {
            guard raw.hasSuffix("\n") else { throw Failure.unavailable }
            let path = String(raw.dropLast())
            guard path.hasPrefix("/"), !path.utf8.contains(0), path.utf8.count <= 16_384 else {
                throw Failure.unavailable
            }
            return path
        }

        /// Witness missing edges too (unborn HEAD, packed loose refs, no index).
        /// Parent ctime makes create/delete/restore observable without retaining
        /// unbounded open descriptors, or following a replaced intermediate link.
        private func fileWitness(_ path: String) throws -> String {
            var descriptor = Darwin.open("/", O_SEARCH | O_CLOEXEC)
            guard descriptor >= 0 else { throw Failure.unavailable }
            defer { Darwin.close(descriptor) }
            let components = path.split(separator: "/")
            for (offset, component) in components.enumerated() {
                guard !inspector.cancellation.isCancelled else { throw Failure.cancelled }
                guard ContinuousClock.now < inspector.deadline else { throw Failure.budget }
                guard component != ".", component != ".." else { throw Failure.unavailable }
                var info = stat()
                if fstatat(descriptor, String(component), &info, AT_SYMLINK_NOFOLLOW) == -1 {
                    guard errno == ENOENT else { throw Failure.unavailable }
                    var parent = stat()
                    guard fstat(descriptor, &parent) == 0 else { throw Failure.unavailable }
                    return "absent:" + AgentVerificationMetadataWitness.signature(parent)
                }
                if offset == components.count - 1 {
                    guard info.st_mode & S_IFMT == S_IFREG else { throw Failure.unavailable }
                    return AgentVerificationMetadataWitness.signature(info)
                }
                guard info.st_mode & S_IFMT == S_IFDIR else { throw Failure.unavailable }
                let child = openat(descriptor, String(component), O_SEARCH | O_CLOEXEC | O_NOFOLLOW)
                guard child >= 0 else { throw Failure.unavailable }
                var opened = stat()
                guard fstat(child, &opened) == 0,
                      AgentVerificationMetadataWitness.signature(info) == AgentVerificationMetadataWitness.signature(opened)
                else { Darwin.close(child); throw Failure.changed }
                Darwin.close(descriptor)
                descriptor = child
            }
            throw Failure.unavailable
        }

        private func openContained(_ relative: String) throws -> Int32 {
            var descriptor = Darwin.open(inspector.lease.canonicalWorktree.path,
                                         O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            guard descriptor >= 0 else { throw Failure.unavailable }
            for component in relative.split(separator: "/") {
                let child = openat(descriptor, String(component), O_SEARCH | O_CLOEXEC | O_NOFOLLOW)
                Darwin.close(descriptor)
                guard child >= 0 else { throw Failure.changed }
                descriptor = child
            }
            return descriptor
        }

        private static func witness(root: stat, proof: RecentAgentTaskRepositoryProof) -> String {
            "\(root.st_dev):\(root.st_ino):\(root.st_gen):\(root.st_birthtimespec.tv_sec):\(root.st_birthtimespec.tv_nsec)"
                + ":\(proof.commonDirectoryDevice):\(proof.commonDirectoryInode):\(proof.commonDirectoryGeneration)"
                + ":\(proof.commonDirectoryBirthSeconds):\(proof.commonDirectoryBirthNanoseconds)"
        }
    }

    enum Failure: Error { case unavailable, changed, cancelled, budget }
}
