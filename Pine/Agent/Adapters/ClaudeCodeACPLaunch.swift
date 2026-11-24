import CryptoKit
import Darwin
import Foundation

/// Pinned runtime identity of the user-selected official `claude-agent-acp`
/// executable. Selection is application configuration, never a provider-supplied
/// path. A filesystem pin is not a sandbox or proof against malicious same-user
/// process injection.
nonisolated struct ClaudeCodeACPExecutableIdentity: Equatable, Sendable,
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
            size = Int64(info.st_size)
            mode = UInt16(truncatingIfNeeded: info.st_mode)
            modifiedSeconds = Int64(info.st_mtimespec.tv_sec)
            modifiedNanoseconds = Int64(info.st_mtimespec.tv_nsec)
            changedSeconds = Int64(info.st_ctimespec.tv_sec)
            changedNanoseconds = Int64(info.st_ctimespec.tv_nsec)
        }
    }

    /// Tagged v0.109.1 source prints only packageJson.version for `--version`.
    /// The matching ACP initialize agentInfo has the same exact version.
    static var supportedVersion: String { ClaudeCodeACPSession.pinnedVersion }
    /// The standalone binary serves ACP on stdio without a subcommand.
    static let acpArguments: [String] = []

    private let selectedURL: URL
    let canonicalURL: URL
    let sha256: String
    private let stamp: Stamp

    var description: String { "<redacted:claude-code-executable>" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["value": description]) }

    /// Final inexpensive slot check on the same background path as spawn. The
    /// full hash was already captured/recomputed; metadata changes refuse use.
    func validateMetadataSynchronously() throws {
        guard selectedURL.resolvingSymlinksInPath().standardizedFileURL == canonicalURL else {
            throw ClaudeCodeACPLaunchError.changed
        }
        var info = stat()
        guard lstat(canonicalURL.path, &info) == 0, Stamp(info) == stamp else {
            throw ClaudeCodeACPLaunchError.changed
        }
    }

    static func capture(selectedURL: URL, deadline: ContinuousClock.Instant) async throws -> Self {
        try await runOnBackground { try captureSynchronously(selectedURL: selectedURL, deadline: deadline) }
    }

    func revalidate(deadline: ContinuousClock.Instant) async throws {
        let current = try await Self.capture(selectedURL: selectedURL, deadline: deadline)
        guard current == self else { throw ClaudeCodeACPLaunchError.changed }
    }

    /// Synchronous image check used by the owned-process receipt off-main.
    func validateProcessImageSynchronously(processID: pid_t, incarnation: UserTaskProcessIdentity) throws {
        guard UserTaskProcessInspector.identity(for: processID) == incarnation else {
            throw ClaudeCodeACPLaunchError.changed
        }
        var path = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let count = path.withUnsafeMutableBytes {
            proc_pidpath(processID, $0.baseAddress, UInt32($0.count))
        }
        guard count > 0, let end = path.firstIndex(of: 0),
              let value = String(bytes: path[..<end], encoding: .utf8) else {
            throw ClaudeCodeACPLaunchError.unavailable
        }
        var info = stat()
        guard value == canonicalURL.path, lstat(value, &info) == 0, Stamp(info) == stamp,
              UserTaskProcessInspector.identity(for: processID) == incarnation else {
            throw ClaudeCodeACPLaunchError.changed
        }
    }

    func probeVersion(at directory: URL, deadline: ContinuousClock.Instant,
                      probeRunner: (@Sendable (URL, [String], URL, TimeInterval) async -> (Bool, String))? = nil) async throws {
        try await revalidate(deadline: deadline)
        let remaining = ContinuousClock.now.duration(to: deadline).components
        let timeout = Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18
        guard timeout > 0 else { throw ClaudeCodeACPLaunchError.unavailable }
        let result: (succeeded: Bool, output: String)
        if let probeRunner {
            result = await probeRunner(canonicalURL, ["--version"], directory, min(timeout, 5))
        } else {
            result = await runOnBackground {
                let executed = GitCommand.runExecutable(canonicalURL, arguments: ["--version"], at: directory,
                                                        timeout: min(timeout, 5), captureLimit: 4_096)
                return (executed.succeeded, executed.output)
            }
        }
        guard result.succeeded else { throw ClaudeCodeACPLaunchError.unavailable }
        guard result.output.trimmingCharacters(in: .whitespacesAndNewlines) == Self.supportedVersion else {
            throw ClaudeCodeACPLaunchError.unsupportedVersion
        }
        try await revalidate(deadline: deadline)
    }

    private static func captureSynchronously(selectedURL: URL, deadline: ContinuousClock.Instant) throws -> Self {
        guard selectedURL.isFileURL, ContinuousClock.now < deadline else { throw ClaudeCodeACPLaunchError.unavailable }
        let canonical = selectedURL.resolvingSymlinksInPath().standardizedFileURL
        let descriptor = Darwin.open(canonical.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw ClaudeCodeACPLaunchError.unavailable }
        defer { Darwin.close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG,
              before.st_mode & (S_IXUSR | S_IXGRP | S_IXOTH) != 0,
              before.st_size >= 4, before.st_size <= 512 * 1_024 * 1_024 else {
            throw ClaudeCodeACPLaunchError.unsupportedBinary
        }
        let expected = Stamp(before)
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 256 * 1_024)
        var total = 0
        while true {
            guard ContinuousClock.now < deadline else { throw ClaudeCodeACPLaunchError.unavailable }
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw ClaudeCodeACPLaunchError.unavailable
            }
            if total == 0 {
                let magic = Array(buffer.prefix(4))
                guard [[0xCF, 0xFA, 0xED, 0xFE], [0xFE, 0xED, 0xFA, 0xCF],
                       [0xCA, 0xFE, 0xBA, 0xBE], [0xBE, 0xBA, 0xFE, 0xCA]].contains(magic) else {
                    throw ClaudeCodeACPLaunchError.unsupportedBinary
                }
            }
            total += count
            guard total <= before.st_size else { throw ClaudeCodeACPLaunchError.changed }
            hasher.update(data: Data(buffer.prefix(count)))
        }
        var after = stat()
        var currentPath = stat()
        guard fstat(descriptor, &after) == 0, lstat(canonical.path, &currentPath) == 0,
              Stamp(after) == expected, Stamp(currentPath) == expected, total == before.st_size else {
            throw ClaudeCodeACPLaunchError.changed
        }
        return Self(selectedURL: selectedURL.standardizedFileURL, canonicalURL: canonical,
                    sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined(), stamp: expected)
    }
}

nonisolated enum ClaudeCodeACPLaunchError: Error, Equatable {
    case unavailable, unsupportedBinary, changed, unsupportedVersion
}

/// Exactly one supervised `claude-agent-acp` child over Pine-owned stdio.
/// The adapter owns the bundled or `CLAUDE_CODE_EXECUTABLE`-selected Claude
/// CLI and all provider authentication/configuration. Neither this value nor
/// a successful handshake proves provider authentication.
nonisolated struct ClaudeCodeACPOwnedChild: Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable {
    var description: String { "<redacted:claude-code-owned-child>" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["value": description]) }
    let channel: CodexAppServerStdioChannel
    let processIdentity: UserTaskProcessIdentity?
    /// Synchronous, non-blocking close/fence hook supplied by the process owner.
    /// Production closes the pipes; process-group TERM/KILL remains in `stop`.
    let close: @Sendable () -> Void
    /// Bounded owner stop: close plus wait for the group to disappear plus
    /// reap. Idempotent.
    let stop: @Sendable (ContinuousClock.Instant) async -> Void

    init(channel: CodexAppServerStdioChannel, processIdentity: UserTaskProcessIdentity? = nil,
         close: @escaping @Sendable () -> Void,
         stop: @escaping @Sendable (ContinuousClock.Instant) async -> Void) {
        self.channel = channel
        self.processIdentity = processIdentity
        self.close = close
        self.stop = stop
    }
}

#if PINE_TEST_HOST
/// Fixture-only launch boundary. Production uses ClaudeCodeACPNativeSpawner and
/// the existing native-child stop/reap path instead of a second process owner.
nonisolated enum ClaudeCodeACPLaunch {
    /// Revalidates the pinned executable, then spawns one owned child with
    /// literal argv in the bound working directory.
    ///
    /// `deadline` bounds the spawn window; `drainUntil` is the session
    /// lifetime that owns the stderr drain and must outlive every turn. A
    /// drain loss at `drainUntil` (or on channel death) tears down the whole
    /// child — it never orphans a live agent process.
    static func launch(
        executable: ClaudeCodeACPExecutableIdentity,
        workingDirectory: URL,
        deadline: ContinuousClock.Instant,
        drainUntil: ContinuousClock.Instant
    ) async throws -> ClaudeCodeACPOwnedChild {
        try await executable.revalidate(deadline: deadline)
        return try await spawn(executableURL: executable.canonicalURL,
                               workingDirectory: workingDirectory, deadline: deadline,
                               drainUntil: drainUntil)
    }

    /// Spawns one supervised child. The executable is used as-is; identity
    /// and binding validation remain the caller's responsibility. The default
    /// argv is empty: the standalone executable is itself the ACP entry point.
    ///
    /// `deadline` bounds the spawn itself; `drainUntil` (the session
    /// lifetime) owns the stderr drain. Do NOT pass the spawn deadline as
    /// `drainUntil`: a healthy turn longer than the launch window would be
    /// fenced and the child torn down mid-turn.
    static func spawn(
        executableURL: URL,
        workingDirectory: URL,
        deadline: ContinuousClock.Instant,
        drainUntil: ContinuousClock.Instant,
        arguments: [String] = ClaudeCodeACPExecutableIdentity.acpArguments
    ) async throws -> ClaudeCodeACPOwnedChild {
        try await runOnBackground {
            guard ContinuousClock.now < deadline,
                  drainUntil > deadline,
                  workingDirectory.isFileURL, workingDirectory.path.hasPrefix("/"),
                  !workingDirectory.path.utf8.contains(0),
                  arguments.count <= 256,
                  arguments.reduce(0, { $0 + $1.utf8.count }) <= 65_536,
                  arguments.allSatisfy({ !$0.utf8.contains(0) }) else {
                throw ClaudeCodeACPLaunchError.unavailable
            }
            var info = stat()
            guard lstat(workingDirectory.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
                throw ClaudeCodeACPLaunchError.unavailable
            }
            let subprocess = try UserTaskSubprocess(
                executableURL: executableURL,
                arguments: arguments,
                workingDirectory: workingDirectory
            )
            let channel: CodexAppServerStdioChannel
            do {
                channel = try CodexAppServerStdioChannel(
                    standardInput: subprocess.standardInput,
                    standardOutput: subprocess.standardOutput,
                    standardError: subprocess.standardError,
                    requireJSONRPCVersion: true
                )
            } catch {
                subprocess.processGroup.requestTermination()
                throw ClaudeCodeACPLaunchError.unavailable
            }
            let group = subprocess.processGroup
            let processIdentity = UserTaskProcessInspector.identity(for: group.identifier)
            // Bounded wait for the group, then reap. Idempotent: waitpid is
            // atomic and requestTermination is guarded, so stop and a
            // concurrent drain-loss teardown can both run safely.
            let finishTeardown: @Sendable () async -> Void = {
                await runOnBackground {
                    _ = group.waitForRequestedTermination()
                    ClaudeCodeACPNativeSpawner.transferFailedSpawn(
                        poll: subprocess.pollExit(),
                        groupIsAlive: { group.isAlive },
                        reap: { subprocess.reapInBackground() },
                        finishDeferredCleanup: { group.finishDeferredCleanup() }
                    )
                }
            }
            let close: @Sendable () -> Void = {
                channel.close()
                group.requestTermination()
                Task.detached { await finishTeardown() }
            }
            let stop: @Sendable (ContinuousClock.Instant) async -> Void = { _ in
                close()
                await finishTeardown()
            }
            // Stderr can contain secrets: drain bounded chunks, retain none.
            // The drain is owned by the session lifetime (drainUntil), not
            // the spawn window; a lost drain tears down the whole child so a
            // live agent with native auth is never orphaned.
            let drainTask = Task {
                do {
                    try await channel.drainStandardError(until: drainUntil)
                } catch {
                    close()
                    await finishTeardown()
                }
            }
            return ClaudeCodeACPOwnedChild(channel: channel, processIdentity: processIdentity,
                                          close: {
                drainTask.cancel()
                close()
            }, stop: stop)
        }
    }
}
#endif
