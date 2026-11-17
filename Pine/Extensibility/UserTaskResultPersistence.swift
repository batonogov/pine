import CryptoKit
import Darwin
import Foundation

/// Metadata by default; output requires explicit per-run consent (#1784).
/// Never encode commands, labels, prompts, stdin, or environment values.
nonisolated struct UserTaskResultRecord: Codable, Equatable, Sendable {
    static let maximumResults = 25
    static let maximumStreamBytes = 64 * 1_024
    // Inactive project files are physically pruned on next access.
    static let lifetime: TimeInterval = 7 * 24 * 60 * 60

    let id: UUID
    let commandIdentity: String
    let taskIdentity: String
    let startedAt: Date
    let finishedAt: Date
    let state: UserTaskRunState
    let exitCode: Int32?
    let processExitCode: Int32?
    let outputCaptureSucceeded: Bool
    let preSpawnRejected: Bool
    let timedOut: Bool
    let cleanupSucceeded: Bool
    let standardInputCompleted: Bool
    var output: Output?

    struct Output: Codable, Equatable, Sendable {
        let stdout: String
        let stderr: String
        let stdoutTruncated: Bool
        let stderrTruncated: Bool

        init(stdout: String, stderr: String) {
            let out = UserTaskResultRecord.boundedStream(stdout)
            let err = UserTaskResultRecord.boundedStream(stderr)
            self.stdout = out.text
            self.stderr = err.text
            stdoutTruncated = out.truncated
            stderrTruncated = err.truncated
        }
    }

    var expiresAt: Date { finishedAt.addingTimeInterval(Self.lifetime) }

    static func identity(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func boundedStream(_ text: String) -> (text: String, truncated: Bool) {
        var bytes = Data(text.utf8.prefix(maximumStreamBytes))
        // A byte cut can split only the final scalar; never add replacement text.
        while String(data: bytes, encoding: .utf8) == nil { bytes.removeLast() }
        return (String(data: bytes, encoding: .utf8) ?? "", text.utf8.count > bytes.count)
    }

    static func retained(_ records: [Self], now: Date) -> [Self] {
        Array(records.filter { $0.expiresAt > now }.sorted {
            if $0.finishedAt != $1.finishedAt { return $0.finishedAt > $1.finishedAt }
            return $0.id.uuidString < $1.id.uuidString
        }.prefix(maximumResults))
    }
}

/// Owner-private storage using AgentHistoryLogPersistence's descriptor-relative,
/// fsynced temporary-file/rename pattern. Revision CAS includes durable Clear.
nonisolated final class UserTaskResultPersistence: Sendable {
    struct Workspace: Codable, Equatable, Sendable {
        let identity: String
        let device: UInt64
        let inode: UInt64
    }

    struct Snapshot: Codable, Equatable, Sendable {
        let version: Int
        let workspace: Workspace
        let revision: UUID?
        let records: [UserTaskResultRecord]
    }

    enum Failure: Error {
        case unsafeStorage
        case conflict
        /// The project directory does not exist. Expected and terminal: a
        /// recreated directory receives a new workspace identity, so the
        /// durable file for this root can never be reached again.
        case rootMissing
        case posix(Int32)
    }

    struct WriteFailure: Error {
        let observedRevision: UUID?
    }

    private struct StoredResult {
        let snapshot: Snapshot
        let identity: stat
        let digest: SHA256.Digest
    }

    private let directory: URL?
    private let beforeWrite: (@Sendable () throws -> Void)?
    private static let maximumFileBytes = 24 * 1_024 * 1_024

    init(directory: URL? = nil, beforeWrite: (@Sendable () throws -> Void)? = nil) {
        self.directory = directory
        self.beforeWrite = beforeWrite
    }

    func load(root: URL) async throws -> Snapshot {
        try await runOnBackground(qos: .utility) { [self] in
            try withStorage(root: root) { directory, name, workspace in
                try read(directory: directory, name: name, workspace: workspace)?.snapshot
                    ?? Snapshot(version: 1, workspace: workspace, revision: nil, records: [])
            }
        }
    }

    func save(
        _ snapshot: Snapshot, root: URL, replacing revision: UUID?,
        recovering attemptedRevision: UUID? = nil
    ) async throws -> Snapshot {
        try await runOnBackground(qos: .utility) { [self] in
            var observedRevision: UUID?
            var admittedWrite = false
            do {
                return try withStorage(root: root) { directory, name, workspace in
                    guard workspace == snapshot.workspace else { throw Failure.conflict }
                    guard snapshot.version == 1, snapshot.revision != nil,
                          Set(snapshot.records.map(\.id)).count == snapshot.records.count,
                          snapshot.records.allSatisfy(validRecord) else { throw Failure.unsafeStorage }
                    let disk = try read(directory: directory, name: name, workspace: workspace)
                    guard disk?.snapshot.revision == revision
                            || (attemptedRevision != nil && disk?.snapshot.revision == attemptedRevision) else {
                        throw Failure.conflict
                    }
                    observedRevision = disk?.snapshot.revision
                    admittedWrite = true
                    try beforeWrite?()
                    let saved = Snapshot(
                        version: 1, workspace: workspace, revision: snapshot.revision,
                        records: UserTaskResultRecord.retained(snapshot.records, now: Date())
                    )
                    try replace(
                        JSONEncoder().encode(saved), directory: directory, name: name,
                        workspace: workspace, admitted: disk
                    )
                    return saved
                }
            } catch {
                // Failure after rename does not mean "nothing written".
                if admittedWrite { throw WriteFailure(observedRevision: observedRevision) }
                throw error
            }
        }
    }

    private func withStorage<T>(
        root: URL,
        _ operation: (Int32, String, Workspace) throws -> T
    ) throws -> T {
        guard root.isFileURL else { throw Failure.unsafeStorage }
        let canonical = root.resolvingSymlinksInPath()
        guard !canonical.path.utf8.contains(0) else { throw Failure.unsafeStorage }
        let project = open(canonical.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard project >= 0 else {
            if errno == ENOENT { throw Failure.rootMissing }
            throw Failure.posix(errno)
        }
        defer { close(project) }
        var info = stat()
        guard fstat(project, &info) == 0 else { throw Failure.posix(errno) }
        let workspace = Workspace(
            identity: UserTaskResultRecord.identity("\(canonical.path)\0\(info.st_dev)\0\(info.st_ino)"),
            device: UInt64(info.st_dev), inode: UInt64(info.st_ino)
        )
        let base = directory ?? PineStorageContext.applicationSupportDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("Pine")
            .appendingPathComponent("CommandResults")
        let storage = try openDirectory(base)
        defer { close(storage) }
        let name = workspace.identity + ".json"
        let lockName = workspace.identity + ".lock"
        let lock = try openLock(directory: storage, name: lockName)
        defer { close(lock) }
        try validateFile(lock)
        let deadline = DispatchTime.now() + .seconds(2)
        while flock(lock, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR,
                  DispatchTime.now() < deadline else { throw Failure.posix(errno) }
            usleep(10_000)
        }
        defer { flock(lock, LOCK_UN) }
        try validateLink(lock, parent: storage, name: lockName)
        try validatePrivateDirectory(storage)
        try validateFile(lock)
        let result = try operation(storage, name, workspace)
        try validatePrivateDirectory(storage)
        try validateFile(lock)
        try validateLink(lock, parent: storage, name: lockName)
        try validatePath(project, path: canonical.path)
        try validatePath(storage, path: base.path)
        return result
    }

    private func openDirectory(_ url: URL) throws -> Int32 {
        guard url.isFileURL else { throw Failure.unsafeStorage }
        let components = url.path.split(separator: "/").map(String.init)
        guard !components.isEmpty else { throw Failure.unsafeStorage }
        let privateDepth = directory == nil ? 2 : 1
        var parent = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parent >= 0 else { throw Failure.posix(errno) }
        do {
            for (index, component) in components.enumerated() {
                var child = openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if child < 0, errno == ENOENT {
                    guard index >= components.count - privateDepth else { throw Failure.unsafeStorage }
                    let created = mkdirat(parent, component, 0o700)
                    guard created == 0 || errno == EEXIST else { throw Failure.posix(errno) }
                    child = openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard child >= 0 else { throw Failure.posix(errno) }
                // Retry also syncs an entry left by an earlier failed mkdir acknowledgement.
                if index >= components.count - privateDepth, fsync(parent) != 0 {
                    let failure = errno
                    close(child)
                    throw Failure.posix(failure)
                }
                close(parent)
                parent = child
                if index == components.count - 1 { try validatePrivateDirectory(child) }
            }
            return parent
        } catch {
            close(parent)
            throw error
        }
    }

    private func openLock(directory: Int32, name: String) throws -> Int32 {
        let flags = O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
        for _ in 0..<8 {
            let existing = openat(directory, name, flags)
            if existing >= 0 { return existing }
            guard errno == ENOENT else { throw Failure.posix(errno) }
            let created = openat(directory, name, flags | O_CREAT | O_EXCL, 0o600)
            if created >= 0 {
                guard descriptorHasNoExtendedACL(created) else {
                    close(created)
                    throw Failure.unsafeStorage
                }
                guard fchmod(created, 0o600) == 0, fsync(created) == 0, fsync(directory) == 0 else {
                    let failure = errno
                    close(created)
                    throw Failure.posix(failure)
                }
                return created
            }
            guard errno == EEXIST else { throw Failure.posix(errno) }
        }
        throw Failure.unsafeStorage
    }

    private func read(directory: Int32, name: String, workspace: Workspace) throws -> StoredResult? {
        let file = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else {
            if errno == ENOENT { return nil }
            throw Failure.posix(errno)
        }
        defer { close(file) }
        try validateFile(file)
        var info = stat()
        guard fstat(file, &info) == 0, info.st_size > 0,
              info.st_size <= Self.maximumFileBytes else { throw Failure.unsafeStorage }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(file, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0, data.count + count <= Self.maximumFileBytes else { throw Failure.unsafeStorage }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
        try validateFile(file)
        try validateLink(file, parent: directory, name: name)
        var finalIdentity = stat()
        guard fstat(file, &finalIdentity) == 0, sameFileState(info, finalIdentity) else {
            throw Failure.conflict
        }
        // Unknown fields (including null) cannot silently disappear in a rewrite.
        let original = try JSONSerialization.jsonObject(with: data) as? NSDictionary
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? NSDictionary
        guard original == encoded, snapshot.version == 1, snapshot.revision != nil,
              snapshot.workspace == workspace,
              snapshot.records.count <= UserTaskResultRecord.maximumResults,
              Set(snapshot.records.map(\.id)).count == snapshot.records.count,
              snapshot.records.allSatisfy(validRecord) else { throw Failure.unsafeStorage }
        return StoredResult(snapshot: snapshot, identity: finalIdentity, digest: SHA256.hash(data: data))
    }

    private func sameFileState(_ first: stat, _ second: stat) -> Bool {
        first.st_dev == second.st_dev && first.st_ino == second.st_ino
            && first.st_mode == second.st_mode && first.st_uid == second.st_uid
            && first.st_gid == second.st_gid && first.st_nlink == second.st_nlink
            && first.st_size == second.st_size
            && first.st_mtimespec.tv_sec == second.st_mtimespec.tv_sec
            && first.st_mtimespec.tv_nsec == second.st_mtimespec.tv_nsec
            && first.st_ctimespec.tv_sec == second.st_ctimespec.tv_sec
            && first.st_ctimespec.tv_nsec == second.st_ctimespec.tv_nsec
            && first.st_birthtimespec.tv_sec == second.st_birthtimespec.tv_sec
            && first.st_birthtimespec.tv_nsec == second.st_birthtimespec.tv_nsec
    }

    private func revalidateDestination(
        directory: Int32, name: String, workspace: Workspace, admitted: StoredResult?
    ) throws {
        let current = try read(directory: directory, name: name, workspace: workspace)
        switch (admitted, current) {
        case (nil, nil):
            return
        case (let previous?, let live?):
            guard sameFileState(previous.identity, live.identity),
                  previous.digest == live.digest,
                  previous.snapshot.revision == live.snapshot.revision else { throw Failure.conflict }
        default:
            throw Failure.conflict
        }
    }

    private func validRecord(_ record: UserTaskResultRecord) -> Bool {
        func validHash(_ hash: String) -> Bool {
            hash.utf8.count == 64 && hash.utf8.allSatisfy {
                (48...57).contains($0) || (97...102).contains($0)
            }
        }
        return validHash(record.commandIdentity) && validHash(record.taskIdentity)
            && !record.state.isActive
            && (record.state != .succeeded || (
                record.exitCode == 0 && !record.timedOut && record.cleanupSucceeded
                    && record.standardInputCompleted && record.outputCaptureSucceeded && !record.preSpawnRejected
            ))
            && (Date.distantPast...Date.distantFuture).contains(record.startedAt)
            && (Date.distantPast...Date().addingTimeInterval(300)).contains(record.finishedAt)
            && (record.output?.stdout.utf8.count ?? 0) <= UserTaskResultRecord.maximumStreamBytes
            && (record.output?.stderr.utf8.count ?? 0) <= UserTaskResultRecord.maximumStreamBytes
    }

    private func replace(
        _ data: Data, directory: Int32, name: String, workspace: Workspace, admitted: StoredResult?
    ) throws {
        guard data.count <= Self.maximumFileBytes else { throw Failure.unsafeStorage }
        try validatePrivateDirectory(directory)
        let temporary = ".\(UUID().uuidString).tmp"
        let file = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw Failure.posix(errno) }
        defer { close(file); unlinkat(directory, temporary, 0) }
        guard descriptorHasNoExtendedACL(file) else { throw Failure.unsafeStorage }
        guard fchmod(file, 0o600) == 0 else { throw Failure.posix(errno) }
        try validateFile(file)
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(file, bytes.baseAddress?.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw Failure.posix(errno) }
                offset += count
            }
        }
        guard fsync(file) == 0 else { throw Failure.posix(errno) }
        try validateFile(file)
        try validatePrivateDirectory(directory)
        try validateLink(file, parent: directory, name: temporary)
        try revalidateDestination(directory: directory, name: name, workspace: workspace, admitted: admitted)
        // Cooperative locking in a private directory, not a kernel CAS against same-user edits.
        let installed: Int32
        if case .none = admitted {
            installed = renameatx_np(directory, temporary, directory, name, UInt32(RENAME_EXCL))
        } else {
            installed = renameat(directory, temporary, directory, name)
        }
        guard installed == 0, fsync(directory) == 0 else { throw Failure.posix(errno) }
        try validateFile(file)
        try validateLink(file, parent: directory, name: name)
    }

    private func validateFile(_ file: Int32) throws {
        var info = stat()
        guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(), info.st_nlink == 1,
              info.st_mode & 0o777 == 0o600,
              descriptorHasNoExtendedACL(file) else { throw Failure.unsafeStorage }
    }

    private func validatePrivateDirectory(_ directory: Int32) throws {
        var info = stat()
        guard fstat(directory, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == geteuid(), info.st_mode & 0o777 == 0o700,
              descriptorHasNoExtendedACL(directory) else { throw Failure.unsafeStorage }
    }

    private func descriptorHasNoExtendedACL(_ descriptor: Int32) -> Bool {
        errno = 0
        guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
            return errno == 0 || errno == ENOENT
        }
        _ = acl_free(UnsafeMutableRawPointer(acl))
        return false
    }

    private func validatePath(_ file: Int32, path: String) throws {
        var opened = stat()
        var linked = stat()
        guard fstat(file, &opened) == 0, lstat(path, &linked) == 0,
              opened.st_dev == linked.st_dev, opened.st_ino == linked.st_ino else {
            throw Failure.unsafeStorage
        }
    }

    private func validateLink(_ file: Int32, parent: Int32, name: String) throws {
        var opened = stat()
        var linked = stat()
        guard fstat(file, &opened) == 0,
              fstatat(parent, name, &linked, AT_SYMLINK_NOFOLLOW) == 0,
              opened.st_dev == linked.st_dev, opened.st_ino == linked.st_ino else {
            throw Failure.unsafeStorage
        }
    }
}
