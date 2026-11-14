import CryptoKit
import Darwin
import Foundation

/// A locally inspected Git snapshot bound to the validated repository. The
/// binding owner must compute it with sanitized Git environment/configuration;
/// provider-reported paths, commit IDs or hashes never construct authority.
nonisolated struct AgentVerificationGitSnapshot: Equatable, Sendable {
    let headCommit: String?
    let indexFingerprint: String
    let trackedPaths: Set<String>
    let untrackedPaths: Set<String>
    /// Nested Git control entries are accepted only for locally inspected,
    /// contained submodules; every submodule's index/HEAD feeds indexFingerprint.
    var submodulePaths: Set<String> = []
    /// Runtime race witnesses, excluded from content identity and persistence.
    var rootWitnesses: [String: String] = [:]
}

/// Conservative content capture. No ignored content is silently excluded.
/// Unsupported external symlinks, uninspected nested repositories, special
/// files, concurrent mutation or an exceeded budget refuse verification.
/// This may reject a build that writes inside its tree; projects should put
/// non-input build outputs outside that tree under an explicit command grant.
nonisolated struct AgentVerificationFilesystemFingerprint: Sendable {
    struct Limits: Sendable {
        var maximumEntries = 100_000
        var maximumBytes = 256 * 1_024 * 1_024
        var maximumFileBytes = 32 * 1_024 * 1_024
        var maximumDepth = 128
        var timeout: TimeInterval = 15
    }

    private static let captureSlots = DispatchSemaphore(value: 4)
    let lease: RecentAgentTaskFilesystemValidationLease
    let limits: Limits
    let policy: AgentVerificationCapturePolicy
    let editor: AgentVerificationEditorPreflight
    let cancellation: GitCommandCancellationToken
    let gitSnapshot: @Sendable () throws -> AgentVerificationGitSnapshot
    var didReadFile: (@Sendable (String) -> Void)?

    func capture() throws -> AgentTaskCodeStateIdentity {
        precondition(!Thread.isMainThread, "Verification fingerprints must be captured off-main")
        guard !cancellation.isCancelled else { throw Failure.cancelled }
        guard Self.captureSlots.wait(timeout: .now()) == .success else { throw Failure.capacity }
        defer { Self.captureSlots.signal() }
        guard !cancellation.isCancelled else { throw Failure.cancelled }
        guard policy.isValid, lease.revalidate(), limits.maximumEntries > 0, limits.maximumBytes > 0,
              limits.maximumFileBytes > 0, limits.maximumDepth > 0,
              limits.timeout.isFinite, limits.timeout > 0 else { throw Failure.unavailable }
        let deadline = ContinuousClock.now.advanced(by: .seconds(limits.timeout))
        guard case .available(let buffers, let editorIsCurrent) = editor else { throw Failure.editorUnavailable }
        guard editorIsCurrent(), buffers.count <= 256,
              Set(buffers.map(\.relativePath)).count == buffers.count,
              buffers.reduce(0, { $0 + $1.saveBytes.count }) <= limits.maximumBytes,
              buffers.allSatisfy({
                  AgentVerificationCapturePolicy.validRelativePath($0.relativePath)
                      && $0.saveBytes.count <= limits.maximumFileBytes && !policy.excludes($0.relativePath)
              }) else { throw Failure.unsavedBuffer }
        let before = try normalized(try gitSnapshot())
        guard Self.validSnapshot(before),
              !before.trackedPaths.contains(where: policy.excludes) else { throw Failure.unavailable }
        let root = lease.canonicalWorktree.path
        let descriptor = Darwin.open(root, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw Failure.unavailable }
        defer { Darwin.close(descriptor) }
        var state = CaptureState(
            snapshot: before, root: root, rootDescriptor: descriptor, limits: limits, policy: policy,
            buffers: buffers, cancellation: cancellation, didReadFile: didReadFile, deadline: deadline
        )
        // Every initial witness precedes every payload read; every final
        // witness follows them. Their unchanged intervals therefore overlap,
        // rather than accepting unrelated per-file read intervals.
        try state.run(descriptor: descriptor, phase: .inventory)
        try state.run(descriptor: descriptor, phase: .read)
        try state.run(descriptor: descriptor, phase: .validate)
        guard state.unmatchedBuffers.isEmpty else { throw Failure.unsavedBuffer }
        guard policy.requiredIgnoredInputs.isSubset(of: state.encountered) else { throw Failure.missingInput }
        guard !cancellation.isCancelled else { throw Failure.cancelled }
        guard ContinuousClock.now < deadline else { throw Failure.budget }
        guard editorIsCurrent(), lease.revalidate(), try normalized(try gitSnapshot()) == before else {
            throw Failure.changed
        }
        return AgentTaskCodeStateIdentity(
            headCommit: before.headCommit,
            trackedFingerprint: state.tracked.finish(),
            untrackedFingerprint: state.untracked.finish(),
            ignoredRelevantFingerprint: state.ignored.finish()
        )
    }

    private func normalized(_ snapshot: AgentVerificationGitSnapshot) throws -> AgentVerificationGitSnapshot {
        guard !snapshot.trackedPaths.contains(where: policy.excludes) else { throw Failure.invalidPolicy }
        return AgentVerificationGitSnapshot(
            headCommit: snapshot.headCommit, indexFingerprint: snapshot.indexFingerprint,
            trackedPaths: snapshot.trackedPaths,
            untrackedPaths: snapshot.untrackedPaths.filter { !policy.excludes($0) },
            submodulePaths: snapshot.submodulePaths, rootWitnesses: snapshot.rootWitnesses
        )
    }

    private static func validSnapshot(_ snapshot: AgentVerificationGitSnapshot) -> Bool {
        guard AgentTaskMetadataStore.validLowerHex(snapshot.indexFingerprint, length: 64),
              snapshot.trackedPaths.count <= 100_000, snapshot.untrackedPaths.count <= 100_000,
              snapshot.trackedPaths.allSatisfy(AgentVerificationCapturePolicy.validRelativePath),
              snapshot.untrackedPaths.allSatisfy(AgentVerificationCapturePolicy.validRelativePath),
              snapshot.submodulePaths.count <= 32,
              snapshot.submodulePaths.allSatisfy(AgentVerificationCapturePolicy.validRelativePath),
              snapshot.trackedPaths.isDisjoint(with: snapshot.untrackedPaths) else { return false }
        return snapshot.headCommit.map {
            AgentTaskMetadataStore.validLowerHex($0, length: 40) || AgentTaskMetadataStore.validLowerHex($0, length: 64)
        } ?? true
    }

    private struct CaptureState {
        let snapshot: AgentVerificationGitSnapshot
        let root: String
        let rootDescriptor: Int32
        let limits: Limits
        let policy: AgentVerificationCapturePolicy
        let cancellation: GitCommandCancellationToken
        let didReadFile: (@Sendable (String) -> Void)?
        let deadline: ContinuousClock.Instant
        var unmatchedBuffers: [String: Data]
        var encountered: Set<String> = []
        enum Phase: Equatable { case inventory, read, validate }
        var witnesses: [String: stat] = [:]
        var visited: Set<String> = []
        var entries = 0
        var bytes = 0
        var tracked = AgentVerificationCanonicalHasher(domain: "pine.ade.code.tracked.v2")
        var untracked = AgentVerificationCanonicalHasher(domain: "pine.ade.code.untracked.v2")
        var ignored = AgentVerificationCanonicalHasher(domain: "pine.ade.code.ignored-inputs.v2")

        init(
            snapshot: AgentVerificationGitSnapshot, root: String, rootDescriptor: Int32, limits: Limits,
            policy: AgentVerificationCapturePolicy, buffers: [AgentVerificationUnsavedInput],
            cancellation: GitCommandCancellationToken, didReadFile: (@Sendable (String) -> Void)?,
            deadline: ContinuousClock.Instant
        ) {
            self.snapshot = snapshot
            self.root = root
            self.rootDescriptor = rootDescriptor
            self.limits = limits
            self.policy = policy
            self.cancellation = cancellation
            self.didReadFile = didReadFile
            unmatchedBuffers = Dictionary(uniqueKeysWithValues: buffers.map { ($0.relativePath, $0.saveBytes) })
            self.deadline = deadline
            tracked.append("policy", policy.fingerprint)
            untracked.append("policy", policy.fingerprint)
            ignored.append("policy", policy.fingerprint)
            tracked.append("index", snapshot.indexFingerprint)
            for path in AgentVerificationCapturePolicy.sorted(snapshot.trackedPaths) { tracked.append("path", path) }
            for path in AgentVerificationCapturePolicy.sorted(snapshot.untrackedPaths) { untracked.append("path", path) }
        }

        mutating func run(descriptor: Int32, phase: Phase) throws {
            entries = 0
            visited = []
            try walk(descriptor: descriptor, path: "", depth: 0, phase: phase)
            guard visited == Set(witnesses.keys) else { throw Failure.changed }
        }

        private mutating func witness(_ path: String, _ info: stat, phase: Phase) throws {
            visited.insert(path)
            if let expected = witnesses[path] {
                guard Self.same(expected, info) else { throw Failure.changed }
            } else {
                guard phase == .inventory else { throw Failure.changed }
                witnesses[path] = info
            }
        }

        private mutating func walk(descriptor: Int32, path: String, depth: Int, phase: Phase) throws {
            try checkBudget()
            guard depth <= limits.maximumDepth else { throw Failure.budget }
            var before = stat()
            guard fstat(descriptor, &before) == 0 else { throw Failure.unavailable }
            try witness(path, before, phase: phase)
            let names = try directoryNames(descriptor)
            guard Set(names).count == names.count else { throw Failure.unsupportedFile }
            for name in names.sorted(by: { $0.utf8.lexicographicallyPrecedes($1.utf8) }) {
                try checkBudget()
                if name == ".git" {
                    guard path.isEmpty || snapshot.submodulePaths.contains(path) else { throw Failure.unsupportedRepository }
                    continue
                }
                entries += 1
                guard entries <= limits.maximumEntries else { throw Failure.budget }
                let relative = path.isEmpty ? name : path + "/" + name
                guard AgentVerificationCapturePolicy.validRelativePath(relative) else { throw Failure.unavailable }
                var info = stat()
                guard fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw Failure.changed }
                let kind = info.st_mode & S_IFMT
                if policy.excludes(relative) {
                    guard kind == S_IFDIR || kind == S_IFREG else { throw Failure.invalidPolicy }
                    continue
                }
                try witness(relative, info, phase: phase)
                if phase == .inventory { encountered.insert(relative) }
                let fingerprint: String
                if kind == S_IFDIR {
                    let child = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                    guard child >= 0 else { throw Failure.changed }
                    defer { Darwin.close(child) }
                    var opened = stat()
                    guard fstat(child, &opened) == 0, Self.same(info, opened) else { throw Failure.changed }
                    try walk(descriptor: child, path: relative, depth: depth + 1, phase: phase)
                    fingerprint = "directory"
                } else if kind == S_IFREG {
                    fingerprint = phase == .read
                        ? try regularFile(parent: descriptor, name: name, relative: relative, expected: info) : ""
                } else if kind == S_IFLNK {
                    fingerprint = phase == .read
                        ? try symbolicLink(parent: descriptor, name: name, relative: relative) : ""
                } else {
                    throw Failure.unsupportedFile
                }
                var after = stat()
                guard fstatat(descriptor, name, &after, AT_SYMLINK_NOFOLLOW) == 0,
                      Self.same(info, after) else { throw Failure.changed }
                guard phase == .read else { continue }
                var record = AgentVerificationCanonicalHasher(domain: "pine.ade.code.entry.v2")
                record.append("path", relative)
                record.append("mode", String(info.st_mode))
                record.append("uid", String(info.st_uid))
                record.append("gid", String(info.st_gid))
                record.append("content-or-target", fingerprint)
                let digest = record.finish()
                if snapshot.trackedPaths.contains(relative) {
                    tracked.append("entry", digest)
                } else if snapshot.untrackedPaths.contains(relative) {
                    untracked.append("entry", digest)
                } else {
                    ignored.append("entry", digest)
                }
            }
            var after = stat()
            guard fstat(descriptor, &after) == 0, Self.same(before, after) else { throw Failure.changed }
        }

        private func directoryNames(_ descriptor: Int32) throws -> [String] {
            let duplicate = Darwin.fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
            guard duplicate >= 0 else { throw Failure.unavailable }
            guard let directory = fdopendir(duplicate) else {
                Darwin.close(duplicate)
                throw Failure.unavailable
            }
            defer { closedir(directory) }
            // dup shares the original open-file offset. The held root is
            // enumerated again in every phase, so reset its directory stream.
            rewinddir(directory)
            var names: [String] = []
            errno = 0
            while let entry = readdir(directory) {
                let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                    pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { characters in
                        String(data: Data(bytes: characters, count: strlen(characters)), encoding: .utf8)
                    }
                }
                guard let name else { throw Failure.unsupportedFile }
                if name != "." && name != ".." { names.append(name) }
                guard names.count <= limits.maximumEntries else { throw Failure.budget }
                try checkBudget()
                errno = 0
            }
            guard errno == 0 else { throw Failure.changed }
            return names
        }

        private mutating func regularFile(parent: Int32, name: String, relative: String, expected: stat) throws -> String {
            guard expected.st_mode & 0o444 != 0 else { throw Failure.unavailable }
            guard expected.st_size >= 0, expected.st_size <= limits.maximumFileBytes else { throw Failure.budget }
            let file = openat(parent, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            guard file >= 0 else { throw Failure.changed }
            defer { Darwin.close(file) }
            var before = stat()
            guard fstat(file, &before) == 0, Self.same(expected, before) else { throw Failure.changed }
            var hasher = SHA256()
            var buffer = [UInt8](repeating: 0, count: 65_536)
            var captured = 0
            while true {
                try checkBudget()
                let count = buffer.withUnsafeMutableBufferPointer { Darwin.read(file, $0.baseAddress, $0.count) }
                if count < 0, errno == EINTR { continue }
                guard count >= 0 else { throw Failure.changed }
                if count == 0 { break }
                captured += count
                bytes += count
                guard captured <= limits.maximumFileBytes, bytes <= limits.maximumBytes else { throw Failure.budget }
                hasher.update(data: Data(buffer.prefix(count)))
            }
            var after = stat()
            guard fstat(file, &after) == 0, Self.same(before, after), captured == after.st_size else {
                throw Failure.changed
            }
            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            didReadFile?(relative)
            if let buffer = unmatchedBuffers.removeValue(forKey: relative) {
                let editorDigest = SHA256.hash(data: buffer).map { String(format: "%02x", $0) }.joined()
                guard editorDigest == digest else { throw Failure.unsavedBuffer }
            }
            return digest
        }

        private func symbolicLink(parent: Int32, name: String, relative: String) throws -> String {
            var buffer = [UInt8](repeating: 0, count: 16_384)
            let count = buffer.withUnsafeMutableBufferPointer { readlinkat(parent, name, $0.baseAddress, $0.count) }
            guard count > 0, count < buffer.count,
                  let target = String(bytes: buffer.prefix(count), encoding: .utf8) else { throw Failure.unsupportedFile }
            // Lexical normalization before following a link is unsound:
            // alias/../secret may escape even when its normalized string does
            // not. Parent traversal is unsupported, including after a symlink.
            guard !target.split(separator: "/").contains("..") else { throw Failure.externalLink }
            let components: [String]
            if target.hasPrefix("/") {
                guard target == root || target.hasPrefix(root + "/") else { throw Failure.externalLink }
                components = target == root ? [] : String(target.dropFirst(root.count + 1))
                    .split(separator: "/").map(String.init)
            } else {
                components = relative.split(separator: "/").dropLast().map(String.init)
                    + target.split(separator: "/").map(String.init)
            }
            try validateCoveredTarget(components.filter { $0 != "." })
            return target
        }

        /// Every actual endpoint/ancestor must be an included inventory entry
        /// and match its no-follow descriptor witness. A case alias absent from
        /// the inventory, skipped .git entry, disposable output, or intermediate
        /// symlink cannot manufacture payload coverage. A missing edge may be
        /// proven beneath a witnessed included directory without following it.
        private func validateCoveredTarget(_ components: [String]) throws {
            guard components.count <= limits.maximumDepth else { throw Failure.budget }
            let targetPath = components.joined(separator: "/")
            guard targetPath.isEmpty || AgentVerificationCapturePolicy.validRelativePath(targetPath),
                  !policy.excludes(targetPath) else { throw Failure.invalidPolicy }
            var descriptor = Darwin.fcntl(rootDescriptor, F_DUPFD_CLOEXEC, 0)
            guard descriptor >= 0 else { throw Failure.unavailable }
            defer { Darwin.close(descriptor) }
            var rootInfo = stat()
            guard let expectedRoot = witnesses[""], fstat(descriptor, &rootInfo) == 0,
                  Self.same(expectedRoot, rootInfo) else { throw Failure.changed }
            var path = ""
            for (offset, component) in components.enumerated() {
                try checkBudget()
                path = path.isEmpty ? component : path + "/" + component
                guard AgentVerificationCapturePolicy.validRelativePath(path),
                      !policy.excludes(path) else { throw Failure.invalidPolicy }
                guard let expected = witnesses[path] else {
                    var missing = stat()
                    // Absence is covered by this included parent's unchanged
                    // inventory witness. An actual alias/excluded entry exists
                    // and must refuse rather than pretending it is dangling.
                    guard fstatat(descriptor, component, &missing, AT_SYMLINK_NOFOLLOW) == -1,
                          errno == ENOENT else { throw Failure.invalidPolicy }
                    return
                }
                let kind = expected.st_mode & S_IFMT
                let last = offset == components.count - 1
                guard kind == S_IFDIR || (last && kind == S_IFREG) else { throw Failure.unsupportedFile }
                var live = stat()
                guard fstatat(descriptor, component, &live, AT_SYMLINK_NOFOLLOW) == 0,
                      Self.same(expected, live) else { throw Failure.changed }
                let flags = O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK | (kind == S_IFDIR ? O_DIRECTORY : 0)
                let child = openat(descriptor, component, flags)
                guard child >= 0 else { throw Failure.changed }
                var opened = stat()
                guard fstat(child, &opened) == 0, Self.same(expected, opened) else {
                    Darwin.close(child)
                    throw Failure.changed
                }
                Darwin.close(descriptor)
                descriptor = child
            }
        }

        private func checkBudget() throws {
            guard !cancellation.isCancelled else { throw Failure.cancelled }
            guard ContinuousClock.now < deadline else { throw Failure.budget }
        }

        private static func same(_ lhs: stat, _ rhs: stat) -> Bool {
            lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && lhs.st_gen == rhs.st_gen
                && lhs.st_mode == rhs.st_mode && lhs.st_uid == rhs.st_uid && lhs.st_gid == rhs.st_gid
                && lhs.st_size == rhs.st_size
                && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
                && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
                && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
                && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
                && lhs.st_birthtimespec.tv_sec == rhs.st_birthtimespec.tv_sec
                && lhs.st_birthtimespec.tv_nsec == rhs.st_birthtimespec.tv_nsec
        }
    }

    enum Failure: Error {
        case unavailable, changed, budget, capacity, cancelled, invalidPolicy, unsavedBuffer, editorUnavailable, missingInput
        case unsupportedFile, unsupportedRepository, externalLink
    }
}
