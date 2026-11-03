import Darwin
import Foundation

/// The project log is a projection, not authority. Never follow project-owned
/// links, truncate a shared inode, or replace another writer's stale snapshot.
nonisolated enum AgentHistoryLogPersistence {
    private static let logName = "agent-log.json"
    private static let lockName = ".agent-log.lock"
    private static let maximumLogBytes = 16 * 1_024 * 1_024

    private enum Failure: Error {
        case posix(Int32, line: Int = #line)
        case unsafeStorage
        case identityConflict
        case lockTimedOut
    }

    static func persist(
        snapshot: [AgentHistoryEntry], root: URL,
        lockDeadline: DispatchTime = .now() + .seconds(2)
    ) throws {
        let project = try openProject(root)
        defer { close(project) }
        if mkdirat(project, ".pine", 0o700) == 0 {
            guard fsync(project) == 0 else { throw Failure.posix(errno) }
        } else if errno != EEXIST {
            throw Failure.posix(errno)
        }
        let directory = openat(project, ".pine", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw Failure.posix(errno) }
        defer { close(directory) }
        let lock = try openLock(directory: directory)
        defer { close(lock) }
        try validateRegular(lock)
        while flock(lock, LOCK_EX | LOCK_NB) != 0 {
            let failure = errno
            guard failure == EINTR || failure == EWOULDBLOCK else { throw Failure.posix(failure) }
            guard DispatchTime.now() < lockDeadline else { throw Failure.lockTimedOut }
            if failure != EINTR { usleep(10_000) }
        }
        defer { flock(lock, LOCK_UN) }
        // The persistent lock inode is never unlinked by Pine. Refuse a lock
        // or directory replaced while waiting instead of splitting writers.
        try validateLink(lock, parent: directory, name: lockName)
        try validateLink(directory, parent: project, name: ".pine")
        let disk = try readLog(directory: directory)
        let merged = try merge(disk: disk, snapshot: snapshot)
        let data = try AgentHistoryStore.makeEncoder().encode(merged)
        guard data.count <= maximumLogBytes else { throw Failure.unsafeStorage }
        try replace(data, directory: directory)
    }

    /// Canonicalize dates through the *persisted* ISO8601 representation before
    /// comparing immutable rows or ordering eviction. In-memory fractional dates
    /// must not outrank the exact same rows read back at whole-second precision.
    private static func merge(
        disk: [AgentHistoryEntry], snapshot: [AgentHistoryEntry]
    ) throws -> [AgentHistoryEntry] {
        let canonical = try AgentHistoryStore.makeDecoder().decode(
            [AgentHistoryEntry].self,
            from: AgentHistoryStore.makeEncoder().encode(snapshot)
        )
        for rows in [disk, canonical] {
            guard AgentHistoryStore.quarantiningDuplicateIdentities(rows).count == rows.count else {
                throw Failure.identityConflict
            }
        }
        var combined = disk
        var indices = Dictionary(uniqueKeysWithValues: disk.enumerated().map { ($0.element.id, $0.offset) })
        for incoming in canonical {
            if let index = indices[incoming.id] {
                var existing = combined[index]
                let wasReverted = existing.reverted
                existing.reverted = incoming.reverted
                guard existing == incoming else { throw Failure.identityConflict }
                existing.reverted = wasReverted || incoming.reverted
                combined[index] = existing
            } else {
                indices[incoming.id] = combined.count
                combined.append(incoming)
            }
        }
        guard AgentHistoryStore.quarantiningDuplicateIdentities(combined).count == combined.count else {
            throw Failure.identityConflict
        }
        guard combined.count > 500 else { return combined }
        let retained = Set(combined.sorted { lhs, rhs in
            let left = lhs.endedAt ?? lhs.startedAt
            let right = rhs.endedAt ?? rhs.startedAt
            if left != right { return left < right }
            return lhs.id.uuidString < rhs.id.uuidString
        }.suffix(500).map(\.id))
        // Keep append order for presentation; the retained *set* has a stable
        // total ordering, independent of stale snapshots and date round trips.
        return combined.filter { retained.contains($0.id) }
    }

    private static func openProject(_ root: URL) throws -> Int32 {
        // Resolve the caller's project URL (including normal /var aliases) once,
        // then walk its canonical components without following further links.
        guard root.isFileURL, let resolved = realpath(root.path, nil) else {
            throw Failure.unsafeStorage
        }
        defer { free(resolved) }
        let components = String(cString: resolved).split(separator: "/")
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw Failure.posix(errno) }
        do {
            for component in components {
                let component = String(component)
                let child = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else { throw Failure.posix(errno) }
                close(descriptor)
                descriptor = child
            }
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    private static func openLock(directory: Int32) throws -> Int32 {
        let flags = O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
        // Separate existing-open from exclusive-create: Darwin can return
        // ENOENT for racing O_CREAT|O_NOFOLLOW opens of the same absent name.
        // Never unlink the persistent lock, and bound hostile namespace churn.
        for _ in 0..<8 {
            let existing = openat(directory, lockName, flags)
            if existing >= 0 { return existing }
            guard errno == ENOENT else { throw Failure.posix(errno) }
            let created = openat(directory, lockName, flags | O_CREAT | O_EXCL, mode_t(0o600))
            if created >= 0 { return created }
            guard errno == EEXIST else { throw Failure.posix(errno) }
        }
        throw Failure.unsafeStorage
    }

    private static func readLog(directory: Int32) throws -> [AgentHistoryEntry] {
        let file = openat(directory, logName, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else {
            if errno == ENOENT { return [] }
            throw Failure.posix(errno)
        }
        defer { close(file) }
        try validateRegular(file)
        var info = stat()
        guard fstat(file, &info) == 0, info.st_size >= 0,
              info.st_size <= maximumLogBytes else { throw Failure.unsafeStorage }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(file, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw Failure.posix(errno)
            }
            if count == 0 { break }
            guard data.count + count <= maximumLogBytes else { throw Failure.unsafeStorage }
            data.append(contentsOf: buffer.prefix(count))
        }
        if data.isEmpty { return [] }
        return try AgentHistoryStore.makeDecoder().decode([AgentHistoryEntry].self, from: data)
    }

    private static func replace(_ data: Data, directory: Int32) throws {
        let name = ".agent-log.\(UUID().uuidString).tmp"
        let file = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard file >= 0 else { throw Failure.posix(errno) }
        defer {
            close(file)
            unlinkat(directory, name, 0)
        }
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
        try validateLink(file, parent: directory, name: name)
        // renameat replaces a destination symlink itself; it never follows it.
        guard renameat(directory, name, directory, logName) == 0,
              fsync(directory) == 0 else { throw Failure.posix(errno) }
    }

    private static func validateRegular(_ descriptor: Int32) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else {
            throw Failure.unsafeStorage
        }
    }

    private static func validateLink(_ descriptor: Int32, parent: Int32, name: String) throws {
        var opened = stat()
        var linked = stat()
        guard fstat(descriptor, &opened) == 0,
              fstatat(parent, name, &linked, AT_SYMLINK_NOFOLLOW) == 0,
              opened.st_dev == linked.st_dev, opened.st_ino == linked.st_ino else {
            throw Failure.unsafeStorage
        }
    }
}
