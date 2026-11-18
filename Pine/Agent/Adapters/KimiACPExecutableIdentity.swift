import CryptoKit
import Darwin
import Foundation

nonisolated enum KimiACPExecutableError: Error, Equatable, Sendable {
    case unavailable, unsupportedBinary, changed, unsupportedVersion
}

/// Runtime-only identity of a user-selected native Kimi Code CLI entry point.
/// Selection is application configuration, never a provider-supplied path. A
/// filesystem pin is not a sandbox or proof against malicious same-user
/// process injection.
///
/// Kimi Code CLI ships as a Node.js shebang entry (re-probed 2026-11-17,
/// artifact $TMPDIR/opencode/pine-1732-reprobe/) rather than a single Mach-O
/// image, so identity pins the entry file and, for script entries, the
/// interpreter the kernel will actually execute.
nonisolated struct KimiACPExecutableIdentity: Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    enum Kind: Equatable, Sendable { case nativeImage, shebangScript }

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

    /// Exact pin, re-probed 2026-11-17 ($TMPDIR/opencode/pine-1732-reprobe/).
    static let supportedVersion = "2.6.2"
    private static let maximumEntryBytes = 1_024 * 1_024
    private let kind: Kind
    private let selectedURL: URL
    let canonicalURL: URL
    let sha256: String
    private let stamp: Stamp
    /// Interpreter path for shebang-script entries; the child's process image
    /// is this file, not the entry script.
    private let interpreterPath: String?
    private let interpreterStamp: Stamp?

    var description: String { "<redacted:kimi-executable>" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["value": description]) }

    /// Final inexpensive slot check on the same background path as spawn. The
    /// full hash was already captured/recomputed; metadata changes refuse use.
    func validateMetadataSynchronously() throws {
        guard selectedURL.resolvingSymlinksInPath().standardizedFileURL == canonicalURL else {
            throw KimiACPExecutableError.changed
        }
        var info = stat()
        guard lstat(canonicalURL.path, &info) == 0, Stamp(info) == stamp else {
            throw KimiACPExecutableError.changed
        }
        guard let interpreterPath, let interpreterStamp else { return }
        var interpreterInfo = stat()
        guard lstat(interpreterPath, &interpreterInfo) == 0,
              Stamp(interpreterInfo) == interpreterStamp else {
            throw KimiACPExecutableError.changed
        }
    }

    static func capture(selectedURL: URL, deadline: ContinuousClock.Instant) async throws -> Self {
        try await runOnBackground {
            try captureSynchronously(selectedURL: selectedURL, deadline: deadline)
        }
    }

    func revalidate(deadline: ContinuousClock.Instant) async throws {
        let current = try await Self.capture(selectedURL: selectedURL, deadline: deadline)
        guard current == self else { throw KimiACPExecutableError.changed }
    }

    /// `kimi --version` prints the bare version number and exits without
    /// touching provider state.
    func probeVersion(at directory: URL, deadline: ContinuousClock.Instant) async throws {
        try await revalidate(deadline: deadline)
        let remaining = ContinuousClock.now.duration(to: deadline).components
        let timeout = Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18
        guard timeout > 0 else { throw KimiACPExecutableError.unavailable }
        let result = await runOnBackground {
            GitCommand.runExecutable(canonicalURL, arguments: ["--version"], at: directory,
                                      timeout: min(timeout, 5), captureLimit: 4_096)
        }
        guard result.succeeded else { throw KimiACPExecutableError.unavailable }
        guard result.output.trimmingCharacters(in: .whitespacesAndNewlines) == Self.supportedVersion else {
            throw KimiACPExecutableError.unsupportedVersion
        }
        try await revalidate(deadline: deadline)
    }

    func validateProcessImage(processID: pid_t, incarnation: UserTaskProcessIdentity) async throws {
        try await runOnBackground {
            guard UserTaskProcessInspector.identity(for: processID) == incarnation else {
                throw KimiACPExecutableError.changed
            }
            // libproc's macro is (4 * MAXPATHLEN), unavailable to Swift.
            var path = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
            let count = path.withUnsafeMutableBytes {
                proc_pidpath(processID, $0.baseAddress, UInt32($0.count))
            }
            guard count > 0, let end = path.firstIndex(of: 0),
                  let value = String(bytes: path[..<end], encoding: .utf8) else {
                throw KimiACPExecutableError.unavailable
            }
            var info = stat()
            let matches: Bool
            if kind == .nativeImage {
                matches = lstat(value, &info) == 0 && value == canonicalURL.path
                    && Stamp(info) == stamp
            } else {
                // The kernel execs the interpreter for shebang entries.
                guard let interpreterPath else {
                    throw KimiACPExecutableError.changed
                }
                matches = lstat(value, &info) == 0 && value == interpreterPath
                    && interpreterStamp.map { Stamp(info) == $0 } ?? false
            }
            guard matches, UserTaskProcessInspector.identity(for: processID) == incarnation else {
                throw KimiACPExecutableError.changed
            }
        }
    }

    private static func captureSynchronously(selectedURL: URL, deadline: ContinuousClock.Instant)
        throws -> Self {
        guard selectedURL.isFileURL, ContinuousClock.now < deadline else {
            throw KimiACPExecutableError.unavailable
        }
        let canonical = selectedURL.resolvingSymlinksInPath().standardizedFileURL
        let descriptor = Darwin.open(canonical.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw KimiACPExecutableError.unavailable }
        defer { Darwin.close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG,
              before.st_mode & (S_IXUSR | S_IXGRP | S_IXOTH) != 0,
              before.st_size >= 4, before.st_size <= maximumEntryBytes else {
            throw KimiACPExecutableError.unsupportedBinary
        }
        var buffer = [UInt8](repeating: 0, count: Int(min(before.st_size, 2 + 512 + 1)))
        guard read(descriptor, &buffer, buffer.count) == buffer.count else {
            throw KimiACPExecutableError.unavailable
        }
        let kind: Kind
        let interpreter: (path: String, stamp: Stamp)?
        if buffer[0] == 35, buffer[1] == 33 {
            // Shebang entry: pin the interpreter the kernel will exec.
            let line = String(bytes: buffer.prefix { $0 != 10 && $0 != 13 }, encoding: .utf8) ?? ""
            let parts = line.dropFirst(2).split(separator: " ", omittingEmptySubsequences: true)
            guard let first = parts.first, first.first?.isASCII == true,
                  first.utf8.count >= 2, first.utf8.count <= 512 else {
                throw KimiACPExecutableError.unsupportedBinary
            }
            let path = String(first)
            guard path.hasPrefix("/"),
                  !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw KimiACPExecutableError.unsupportedBinary
            }
            var interpreterInfo = stat()
            guard lstat(path, &interpreterInfo) == 0,
                  (interpreterInfo.st_mode & S_IFMT) == S_IFREG else {
                throw KimiACPExecutableError.unsupportedBinary
            }
            kind = .shebangScript
            // shortcut: interpreter pinned by stat stamp only (no full hash);
            // upgrade to a full interpreter hash if runtime-tamper evidence is
            // required beyond replacement detection.
            interpreter = (path: path, stamp: Stamp(interpreterInfo))
        } else {
            let magic = Array(buffer.prefix(4))
            guard [[0xCF, 0xFA, 0xED, 0xFE], [0xFE, 0xED, 0xFA, 0xCF],
                   [0xCA, 0xFE, 0xBA, 0xBE], [0xBE, 0xBA, 0xFE, 0xCA]].contains(magic) else {
                throw KimiACPExecutableError.unsupportedBinary
            }
            kind = .nativeImage
            interpreter = nil
        }
        let expected = Stamp(before)
        var hasher = SHA256()
        hasher.update(data: Data(buffer))
        var chunk = [UInt8](repeating: 0, count: 256 * 1_024)
        var total = buffer.count
        while true {
            guard ContinuousClock.now < deadline else { throw KimiACPExecutableError.unavailable }
            let count = Darwin.read(descriptor, &chunk, chunk.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw KimiACPExecutableError.unavailable
            }
            total += count
            guard total <= before.st_size else { throw KimiACPExecutableError.changed }
            hasher.update(data: Data(chunk.prefix(count)))
        }
        var after = stat()
        var currentPath = stat()
        guard fstat(descriptor, &after) == 0, lstat(canonical.path, &currentPath) == 0,
              Stamp(after) == expected, Stamp(currentPath) == expected, total == before.st_size else {
            throw KimiACPExecutableError.changed
        }
        if let interpreter {
            var rechecked = stat()
            guard lstat(interpreter.path, &rechecked) == 0, Stamp(rechecked) == interpreter.stamp else {
                throw KimiACPExecutableError.changed
            }
        }
        return Self(kind: kind, selectedURL: selectedURL.standardizedFileURL, canonicalURL: canonical,
                    sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined(),
                    stamp: expected,
                    interpreterPath: interpreter?.path,
                    interpreterStamp: interpreter?.stamp)
    }
}
