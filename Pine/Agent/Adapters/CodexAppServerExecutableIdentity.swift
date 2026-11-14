import CryptoKit
import Darwin
import Foundation

nonisolated enum CodexAppServerExecutableError: Error, Equatable {
    case unavailable, unsupportedBinary, changed, unsupportedVersion
}

/// Runtime-only identity of a user-selected native Codex executable. Selection
/// is application configuration, never a provider-supplied path. A filesystem
/// pin is not a sandbox or proof against malicious same-user process injection.
nonisolated struct CodexAppServerExecutableIdentity: Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private struct Stamp: Equatable, Sendable {
        let device: UInt64
        let inode: UInt64
        let generation: UInt64
        let size: Int64
        let mode: UInt16
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let changedSeconds: Int64
        let changedNanoseconds: Int64

        init(_ info: stat) {
            device = UInt64(truncatingIfNeeded: info.st_dev)
            inode = UInt64(info.st_ino)
            generation = UInt64(info.st_gen)
            size = info.st_size
            mode = info.st_mode
            modifiedSeconds = Int64(info.st_mtimespec.tv_sec)
            modifiedNanoseconds = Int64(info.st_mtimespec.tv_nsec)
            changedSeconds = Int64(info.st_ctimespec.tv_sec)
            changedNanoseconds = Int64(info.st_ctimespec.tv_nsec)
        }
    }

    static let supportedVersion = "codex-cli 0.169.0"
    private let selectedURL: URL
    let canonicalURL: URL
    let sha256: String
    private let stamp: Stamp

    var description: String { "<redacted:codex-executable>" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["value": description]) }

    #if DEBUG
    /// Exercises the same stamp conversion with synthetic kernel metadata.
    static func filesystemDeviceIdentityForTesting(_ device: dev_t) -> UInt64 {
        var info = stat()
        info.st_dev = device
        return Stamp(info).device
    }
    #endif

    /// Final inexpensive slot check on the same background path as spawn. The
    /// full hash was already captured/recomputed; metadata changes refuse use.
    func validateMetadataSynchronously() throws {
        guard selectedURL.resolvingSymlinksInPath().standardizedFileURL == canonicalURL else {
            throw CodexAppServerExecutableError.changed
        }
        var info = stat()
        guard lstat(canonicalURL.path, &info) == 0, Stamp(info) == stamp else {
            throw CodexAppServerExecutableError.changed
        }
    }

    static func capture(selectedURL: URL, deadline: ContinuousClock.Instant) async throws -> Self {
        try await runOnBackground { try captureSynchronously(selectedURL: selectedURL, deadline: deadline) }
    }

    func revalidate(deadline: ContinuousClock.Instant) async throws {
        let current = try await Self.capture(selectedURL: selectedURL, deadline: deadline)
        guard current == self else { throw CodexAppServerExecutableError.changed }
    }

    func probeVersion(at directory: URL, deadline: ContinuousClock.Instant) async throws {
        try await revalidate(deadline: deadline)
        let remaining = ContinuousClock.now.duration(to: deadline).components
        let timeout = Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18
        guard timeout > 0 else { throw CodexAppServerExecutableError.unavailable }
        let result = await runOnBackground {
            GitCommand.runExecutable(canonicalURL, arguments: ["--version"], at: directory,
                                     timeout: min(timeout, 5), captureLimit: 4_096)
        }
        guard result.succeeded else { throw CodexAppServerExecutableError.unavailable }
        guard result.output.trimmingCharacters(in: .whitespacesAndNewlines) == Self.supportedVersion else {
            throw CodexAppServerExecutableError.unsupportedVersion
        }
        try await revalidate(deadline: deadline)
    }

    func validateProcessImage(processID: pid_t, incarnation: UserTaskProcessIdentity) async throws {
        try await runOnBackground {
            guard UserTaskProcessInspector.identity(for: processID) == incarnation else {
                throw CodexAppServerExecutableError.changed
            }
            // libproc's macro is (4 * MAXPATHLEN), unavailable to Swift.
            var path = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
            let count = path.withUnsafeMutableBytes { proc_pidpath(processID, $0.baseAddress, UInt32($0.count)) }
            guard count > 0, let end = path.firstIndex(of: 0),
                  let value = String(bytes: path[..<end], encoding: .utf8) else {
                throw CodexAppServerExecutableError.unavailable
            }
            var info = stat()
            guard lstat(value, &info) == 0, Stamp(info) == stamp,
                  UserTaskProcessInspector.identity(for: processID) == incarnation else {
                throw CodexAppServerExecutableError.changed
            }
        }
    }

    private static func captureSynchronously(selectedURL: URL, deadline: ContinuousClock.Instant) throws -> Self {
        guard selectedURL.isFileURL, ContinuousClock.now < deadline else { throw CodexAppServerExecutableError.unavailable }
        let canonical = selectedURL.resolvingSymlinksInPath().standardizedFileURL
        let descriptor = Darwin.open(canonical.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw CodexAppServerExecutableError.unavailable }
        defer { Darwin.close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG,
              before.st_mode & (S_IXUSR | S_IXGRP | S_IXOTH) != 0,
              before.st_size >= 4, before.st_size <= 512 * 1_024 * 1_024 else {
            throw CodexAppServerExecutableError.unsupportedBinary
        }
        let expected = Stamp(before)
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 256 * 1_024)
        var total = 0
        while true {
            guard ContinuousClock.now < deadline else { throw CodexAppServerExecutableError.unavailable }
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw CodexAppServerExecutableError.unavailable
            }
            if total == 0 {
                let magic = Array(buffer.prefix(4))
                guard [[0xCF, 0xFA, 0xED, 0xFE], [0xFE, 0xED, 0xFA, 0xCF],
                       [0xCA, 0xFE, 0xBA, 0xBE], [0xBE, 0xBA, 0xFE, 0xCA]].contains(magic) else {
                    throw CodexAppServerExecutableError.unsupportedBinary
                }
            }
            total += count
            guard total <= before.st_size else { throw CodexAppServerExecutableError.changed }
            hasher.update(data: Data(buffer.prefix(count)))
        }
        var after = stat()
        var currentPath = stat()
        guard fstat(descriptor, &after) == 0, lstat(canonical.path, &currentPath) == 0,
              Stamp(after) == expected, Stamp(currentPath) == expected, total == before.st_size else {
            throw CodexAppServerExecutableError.changed
        }
        return Self(selectedURL: selectedURL.standardizedFileURL, canonicalURL: canonical,
                    sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined(), stamp: expected)
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
