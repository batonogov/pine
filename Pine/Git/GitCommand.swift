//
//  GitCommand.swift
//  Pine
//
//  Low-level git process execution. No business logic, no state.
//

import Darwin
import Foundation

/// Result of a git command invocation.
nonisolated struct GitCommandResult: Sendable {
    let output: String
    let errorOutput: String
    let exitCode: Int32
    let timedOut: Bool
    let cancelled: Bool
    let outputTruncated: Bool
    let errorOutputTruncated: Bool
    let outputCaptureComplete: Bool
    let errorOutputCaptureComplete: Bool
    let outputReadError: Int32?
    let errorOutputReadError: Int32?

    /// True when the child process itself completed successfully. Use this
    /// for mutating commands whose side effect is authoritative even if a
    /// verbose hook overflowed the bounded diagnostic capture.
    var completedSuccessfully: Bool {
        exitCode == 0 && !timedOut && !cancelled
    }

    /// True only when the process exited successfully and both captured
    /// streams are complete. Use this when parsing stdout or stderr.
    var succeeded: Bool {
        completedSuccessfully
            && !outputTruncated
            && !errorOutputTruncated
            && outputCaptureComplete
            && errorOutputCaptureComplete
    }
}

/// Thread-safe cancellation authority for a single command invocation.
///
/// The async API owns one token and flips it from its task cancellation
/// handler. Keeping the token independent from a Swift task is important:
/// process I/O runs on a GCD worker where `Task.isCancelled` is not inherited.
nonisolated final class GitCommandCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

nonisolated enum GitCommandStream: Sendable {
    case standardOutput
    case standardError
}

/// Injectable POSIX seam for deterministic lifecycle and I/O failure tests.
nonisolated struct GitCommandSystemCalls: @unchecked Sendable {
    let read: @Sendable (
        GitCommandStream,
        Int32,
        UnsafeMutableRawPointer?,
        Int
    ) -> Int
    let waitpid: @Sendable (pid_t, UnsafeMutablePointer<Int32>?, Int32) -> pid_t
    let kill: @Sendable (pid_t, Int32) -> Int32

    init(
        read: @escaping @Sendable (
            GitCommandStream,
            Int32,
            UnsafeMutableRawPointer?,
            Int
        ) -> Int = { _, descriptor, buffer, count in
            Darwin.read(descriptor, buffer, count)
        },
        waitpid: @escaping @Sendable (
            pid_t,
            UnsafeMutablePointer<Int32>?,
            Int32
        ) -> pid_t = { processIdentifier, status, options in
            Darwin.waitpid(processIdentifier, status, options)
        },
        kill: @escaping @Sendable (pid_t, Int32) -> Int32 = { processIdentifier, signal in
            Darwin.kill(processIdentifier, signal)
        }
    ) {
        self.read = read
        self.waitpid = waitpid
        self.kill = kill
    }

    static let live = GitCommandSystemCalls()
}

/// Runs git commands as subprocesses with timeout support.
nonisolated enum GitCommand {

    /// Default timeout for git commands (30 seconds).
    static let defaultTimeout: TimeInterval = 30.0
    /// Maximum number of bytes retained from either output stream.
    static let defaultCaptureLimit = 4 * 1_024 * 1_024

    /// Grace period between SIGTERM and the SIGKILL fallback.
    private static let terminationGracePeriod: TimeInterval = 0.25
    /// Bounded interval for draining final output and reaping after SIGKILL.
    private static let killCleanupPeriod: TimeInterval = 0.25
    /// Maximum sleep between lifecycle observations.
    private static let pollIntervalMilliseconds: Int32 = 20
    private static let readBufferSize = 16 * 1_024
    private static let maximumDrainBytesPerPass = 64 * 1_024

    /// Executes `git` with the given arguments in the specified directory.
    ///
    /// - Parameters:
    ///   - arguments: Git subcommand and arguments (e.g. `["status", "--porcelain"]`).
    ///   - directory: Working directory for the git process.
    ///   - timeout: Maximum time to wait before terminating the process.
    ///   - captureLimit: Maximum bytes retained from each output stream.
    /// - Returns: Captured output, exit status, and whether the timeout fired.
    static func run(
        _ arguments: [String],
        at directory: URL,
        timeout: TimeInterval = defaultTimeout,
        captureLimit: Int = defaultCaptureLimit
    ) -> GitCommandResult {
        runExecutable(
            URL(fileURLWithPath: "/usr/bin/git"),
            arguments: arguments,
            at: directory,
            timeout: timeout,
            captureLimit: captureLimit
        )
    }

    /// Executes git without blocking the caller's cooperative executor.
    ///
    /// Cancelling the calling task cancels the subprocess process group using
    /// the same TERM/grace/KILL lifecycle as a timeout.
    static func runAsync(
        _ arguments: [String],
        at directory: URL,
        timeout: TimeInterval = defaultTimeout,
        captureLimit: Int = defaultCaptureLimit
    ) async -> GitCommandResult {
        await runExecutableAsync(
            URL(fileURLWithPath: "/usr/bin/git"),
            arguments: arguments,
            at: directory,
            timeout: timeout,
            captureLimit: captureLimit
        )
    }

    /// Process-execution seam used by deterministic lifecycle tests.
    ///
    /// Production callers use ``run(_:at:timeout:)`` so the executable remains
    /// fixed to `/usr/bin/git`.
    static func runExecutable(
        _ executableURL: URL,
        arguments: [String],
        at directory: URL,
        timeout: TimeInterval = defaultTimeout,
        captureLimit: Int = defaultCaptureLimit,
        cancellationToken: GitCommandCancellationToken? = nil,
        systemCalls: GitCommandSystemCalls = .live
    ) -> GitCommandResult {
        if cancellationToken?.isCancelled == true {
            return cancelledBeforeLaunchResult()
        }

        let startedAt = DispatchTime.now()
        let commandDeadline = startedAt + normalizedTimeout(timeout)

        let child: GitCommandChild
        switch spawn(
            executableURL,
            arguments: arguments,
            directory: directory
        ) {
        case let .success(spawnedChild):
            child = spawnedChild
        case let .failure(error):
            return GitCommandResult(
                output: "",
                errorOutput: error.message,
                exitCode: -1,
                timedOut: false,
                cancelled: false,
                outputTruncated: false,
                errorOutputTruncated: false,
                outputCaptureComplete: false,
                errorOutputCaptureComplete: false,
                outputReadError: nil,
                errorOutputReadError: nil
            )
        }

        var standardOutput = GitCommandCapture(limit: captureLimit)
        var standardError = GitCommandCapture(limit: captureLimit)
        var stdoutDescriptor = child.stdoutDescriptor
        var stderrDescriptor = child.stderrDescriptor
        var rawWaitStatus: Int32?
        var phase = GitCommandTerminationPhase.running
        var terminalCause: GitCommandTerminalCause?
        var phaseDeadline = commandDeadline
        var readBuffer = [UInt8](repeating: 0, count: readBufferSize)

        lifecycleLoop: while true {
            drain(
                stream: .standardOutput,
                descriptor: &stdoutDescriptor,
                into: &standardOutput,
                buffer: &readBuffer,
                systemCalls: systemCalls
            )
            drain(
                stream: .standardError,
                descriptor: &stderrDescriptor,
                into: &standardError,
                buffer: &readBuffer,
                systemCalls: systemCalls
            )
            let streamsAreClosed = stdoutDescriptor == -1
                && stderrDescriptor == -1
            if shouldAttemptReap(
                phase: phase,
                streamsAreClosed: streamsAreClosed
            ) {
                reap(
                    processIdentifier: child.processIdentifier,
                    rawStatus: &rawWaitStatus,
                    systemCalls: systemCalls
                )
            }

            if rawWaitStatus != nil,
               streamsAreClosed {
                break
            }

            let now = DispatchTime.now()
            if terminalCause == nil {
                if cancellationToken?.isCancelled == true {
                    terminalCause = .cancelled
                    signalProcessGroup(
                        child.processIdentifier,
                        signal: SIGTERM,
                        systemCalls: systemCalls
                    )
                    phase = .terminating
                    phaseDeadline = DispatchTime.now()
                        + terminationGracePeriod
                    continue
                }
                if now >= commandDeadline {
                    terminalCause = .timedOut
                    signalProcessGroup(
                        child.processIdentifier,
                        signal: SIGTERM,
                        systemCalls: systemCalls
                    )
                    phase = .terminating
                    // Start the grace period from the actual signal attempt. A
                    // delayed worker must not collapse TERM and KILL together.
                    phaseDeadline = DispatchTime.now()
                        + terminationGracePeriod
                    continue
                }
            }

            switch phase {
            case .terminating where now >= phaseDeadline:
                signalProcessGroup(
                    child.processIdentifier,
                    signal: SIGKILL,
                    systemCalls: systemCalls
                )
                phase = .killing
                phaseDeadline = DispatchTime.now() + killCleanupPeriod
                continue
            case .killing where now >= phaseDeadline:
                closeDescriptor(&stdoutDescriptor)
                closeDescriptor(&stderrDescriptor)
                if rawWaitStatus == nil {
                    GitCommandDeferredReaper(
                        processIdentifier: child.processIdentifier,
                        waitpid: systemCalls.waitpid
                    ).start()
                }
                break lifecycleLoop
            default:
                break
            }

            poll(
                stdoutDescriptor: stdoutDescriptor,
                stderrDescriptor: stderrDescriptor,
                until: phaseDeadline
            )
        }

        closeDescriptor(&stdoutDescriptor)
        closeDescriptor(&stderrDescriptor)

        let timedOut = terminalCause == .timedOut
        let cancelled = terminalCause == .cancelled
        let exitCode: Int32
        if let rawWaitStatus {
            let decodedCode = decodedExitCode(rawWaitStatus)
            if timedOut, decodedCode == 0 {
                exitCode = ETIMEDOUT
            } else if cancelled, decodedCode == 0 {
                exitCode = ECANCELED
            } else {
                exitCode = decodedCode
            }
        } else if timedOut {
            exitCode = SIGKILL
        } else if cancelled {
            exitCode = ECANCELED
        } else {
            exitCode = -1
        }

        // A byte cap can split a multi-byte scalar. Preserve the valid prefix
        // plus a replacement scalar instead of discarding the entire stream.
        // swiftlint:disable:next optional_data_string_conversion
        let output = String(decoding: standardOutput.data, as: UTF8.self)
        // swiftlint:disable:next optional_data_string_conversion
        let errorOutput = String(decoding: standardError.data, as: UTF8.self)
        return GitCommandResult(
            output: output,
            errorOutput: errorOutput,
            exitCode: exitCode,
            timedOut: timedOut,
            cancelled: cancelled,
            outputTruncated: standardOutput.truncated,
            errorOutputTruncated: standardError.truncated,
            outputCaptureComplete: standardOutput.captureComplete,
            errorOutputCaptureComplete: standardError.captureComplete,
            outputReadError: standardOutput.readError,
            errorOutputReadError: standardError.readError
        )
    }

    /// Testable async executable seam used by ``runAsync(_:at:timeout:)``.
    static func runExecutableAsync(
        _ executableURL: URL,
        arguments: [String],
        at directory: URL,
        timeout: TimeInterval = defaultTimeout,
        captureLimit: Int = defaultCaptureLimit,
        systemCalls: GitCommandSystemCalls = .live
    ) async -> GitCommandResult {
        let cancellationToken = GitCommandCancellationToken()
        return await withTaskCancellationHandler {
            if Task.isCancelled {
                cancellationToken.cancel()
            }
            // `runOnBackground` wraps the process I/O in an autorelease pool
            // (#1509) — the raw global-queue dispatch it replaces had none
            // (#1548) and let git output temporaries pile up on the worker
            // thread until it was torn down.
            return await runOnBackground(qos: .utility) {
                runExecutable(
                    executableURL,
                    arguments: arguments,
                    at: directory,
                    timeout: timeout,
                    captureLimit: captureLimit,
                    cancellationToken: cancellationToken,
                    systemCalls: systemCalls
                )
            }
        } onCancel: {
            cancellationToken.cancel()
        }
    }

    private static func cancelledBeforeLaunchResult() -> GitCommandResult {
        GitCommandResult(
            output: "",
            errorOutput: "",
            exitCode: ECANCELED,
            timedOut: false,
            cancelled: true,
            outputTruncated: false,
            errorOutputTruncated: false,
            outputCaptureComplete: false,
            errorOutputCaptureComplete: false,
            outputReadError: nil,
            errorOutputReadError: nil
        )
    }

    /// A wait consumes the zombie and releases its PID for reuse. Preserve the
    /// process-group leader until no more group signal can be sent, unless all
    /// captured streams are closed and the invocation can return immediately.
    static func shouldAttemptReap(
        phase: GitCommandTerminationPhase,
        streamsAreClosed: Bool
    ) -> Bool {
        if streamsAreClosed {
            return true
        }
        if case .killing = phase {
            return true
        }
        return false
    }

    private static func spawn(
        _ executableURL: URL,
        arguments: [String],
        directory: URL
    ) -> Result<GitCommandChild, GitCommandLaunchError> {
        guard var stdoutPipe = makePipe() else {
            return .failure(GitCommandLaunchError(code: errno))
        }
        defer { stdoutPipe.closeAll() }

        guard var stderrPipe = makePipe() else {
            return .failure(GitCommandLaunchError(code: errno))
        }
        defer { stderrPipe.closeAll() }

        var fileActions: posix_spawn_file_actions_t?
        let fileActionsError = posix_spawn_file_actions_init(&fileActions)
        guard fileActionsError == 0 else {
            return .failure(GitCommandLaunchError(code: fileActionsError))
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        let stdinError = "/dev/null".withCString { nullDevicePath in
            posix_spawn_file_actions_addopen(
                &fileActions,
                STDIN_FILENO,
                nullDevicePath,
                O_RDONLY,
                0
            )
        }
        guard stdinError == 0 else {
            return .failure(GitCommandLaunchError(code: stdinError))
        }
        let stdoutDupError = posix_spawn_file_actions_adddup2(
            &fileActions,
            stdoutPipe.writeDescriptor,
            STDOUT_FILENO
        )
        guard stdoutDupError == 0 else {
            return .failure(GitCommandLaunchError(code: stdoutDupError))
        }
        let stderrDupError = posix_spawn_file_actions_adddup2(
            &fileActions,
            stderrPipe.writeDescriptor,
            STDERR_FILENO
        )
        guard stderrDupError == 0 else {
            return .failure(GitCommandLaunchError(code: stderrDupError))
        }

        for descriptor in [
            stdoutPipe.readDescriptor,
            stdoutPipe.writeDescriptor,
            stderrPipe.readDescriptor,
            stderrPipe.writeDescriptor
        ] {
            let closeError = posix_spawn_file_actions_addclose(
                &fileActions,
                descriptor
            )
            guard closeError == 0 else {
                return .failure(GitCommandLaunchError(code: closeError))
            }
        }

        let chdirError = directory.path.withCString { directoryPath in
            posix_spawn_file_actions_addchdir(&fileActions, directoryPath)
        }
        guard chdirError == 0 else {
            return .failure(GitCommandLaunchError(code: chdirError))
        }

        var attributes: posix_spawnattr_t?
        let attributesError = posix_spawnattr_init(&attributes)
        guard attributesError == 0 else {
            return .failure(GitCommandLaunchError(code: attributesError))
        }
        defer { posix_spawnattr_destroy(&attributes) }

        // Do not inherit the host's signal handling. Test runners and GUI
        // launchers may ignore or block SIGTERM; POSIX shells then preserve
        // that ignored disposition and cannot install a TERM trap. Reset all
        // catchable signals and clear the signal mask so TERM/grace/KILL has
        // the same semantics regardless of Pine's parent process.
        var defaultSignals = sigset_t()
        guard sigfillset(&defaultSignals) == 0,
              sigdelset(&defaultSignals, SIGKILL) == 0,
              sigdelset(&defaultSignals, SIGSTOP) == 0 else {
            return .failure(GitCommandLaunchError(code: errno))
        }
        let signalDefaultsError = posix_spawnattr_setsigdefault(
            &attributes,
            &defaultSignals
        )
        guard signalDefaultsError == 0 else {
            return .failure(GitCommandLaunchError(code: signalDefaultsError))
        }

        var signalMask = sigset_t()
        guard sigemptyset(&signalMask) == 0 else {
            return .failure(GitCommandLaunchError(code: errno))
        }
        let signalMaskError = posix_spawnattr_setsigmask(
            &attributes,
            &signalMask
        )
        guard signalMaskError == 0 else {
            return .failure(GitCommandLaunchError(code: signalMaskError))
        }

        let attributeFlags = Int16(
            POSIX_SPAWN_SETPGROUP
                | POSIX_SPAWN_CLOEXEC_DEFAULT
                | POSIX_SPAWN_SETSIGDEF
                | POSIX_SPAWN_SETSIGMASK
        )
        let flagsError = posix_spawnattr_setflags(
            &attributes,
            attributeFlags
        )
        guard flagsError == 0 else {
            return .failure(GitCommandLaunchError(code: flagsError))
        }
        // Darwin defines spawn-pgroup 0 as a new group whose ID is the child
        // PID. This avoids the post-launch setpgid race entirely.
        let groupError = posix_spawnattr_setpgroup(&attributes, 0)
        guard groupError == 0 else {
            return .failure(GitCommandLaunchError(code: groupError))
        }

        let argumentStrings = [executableURL.path] + arguments
        let environmentStrings = ProcessInfo.processInfo.environment.map {
            "\($0.key)=\($0.value)"
        }
        var processIdentifier: pid_t = 0
        let spawnError = withMutableCStringArray(argumentStrings) { argv in
            withMutableCStringArray(environmentStrings) { environment in
                executableURL.path.withCString { executablePath in
                    posix_spawn(
                        &processIdentifier,
                        executablePath,
                        &fileActions,
                        &attributes,
                        argv,
                        environment
                    )
                }
            }
        }
        guard spawnError == 0 else {
            return .failure(GitCommandLaunchError(code: spawnError))
        }

        stdoutPipe.closeWrite()
        stderrPipe.closeWrite()
        let child = GitCommandChild(
            processIdentifier: processIdentifier,
            stdoutDescriptor: stdoutPipe.takeReadDescriptor(),
            stderrDescriptor: stderrPipe.takeReadDescriptor()
        )
        return .success(child)
    }

    private static func makePipe() -> GitCommandPipe? {
        var descriptors = [Int32](repeating: -1, count: 2)
        let pipeResult = descriptors.withUnsafeMutableBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else {
                return Int32(-1)
            }
            return Darwin.pipe(baseAddress)
        }
        guard pipeResult == 0 else { return nil }

        var pipe = GitCommandPipe(
            readDescriptor: descriptors[0],
            writeDescriptor: descriptors[1]
        )
        guard moveAboveStandardDescriptors(&pipe.readDescriptor),
              moveAboveStandardDescriptors(&pipe.writeDescriptor),
              setCloseOnExec(pipe.readDescriptor),
              setCloseOnExec(pipe.writeDescriptor),
              setNonBlocking(pipe.readDescriptor) else {
            let savedError = errno
            pipe.closeAll()
            errno = savedError
            return nil
        }
        return pipe
    }

    private static func moveAboveStandardDescriptors(
        _ descriptor: inout Int32
    ) -> Bool {
        guard descriptor <= STDERR_FILENO else { return true }
        let duplicated = Darwin.fcntl(
            descriptor,
            F_DUPFD_CLOEXEC,
            STDERR_FILENO + 1
        )
        guard duplicated != -1 else { return false }
        Darwin.close(descriptor)
        descriptor = duplicated
        return true
    }

    private static func setCloseOnExec(_ descriptor: Int32) -> Bool {
        Darwin.fcntl(descriptor, F_SETFD, FD_CLOEXEC) != -1
    }

    private static func setNonBlocking(_ descriptor: Int32) -> Bool {
        let flags = Darwin.fcntl(descriptor, F_GETFL)
        guard flags != -1 else { return false }

        return Darwin.fcntl(
            descriptor,
            F_SETFL,
            flags | O_NONBLOCK
        ) != -1
    }

    private static func drain(
        stream: GitCommandStream,
        descriptor: inout Int32,
        into capture: inout GitCommandCapture,
        buffer: inout [UInt8],
        systemCalls: GitCommandSystemCalls
    ) {
        guard descriptor != -1 else { return }
        var drainedBytes = 0

        while drainedBytes < maximumDrainBytesPerPass {
            let bytesRead = buffer.withUnsafeMutableBytes { bytes in
                systemCalls.read(
                    stream,
                    descriptor,
                    bytes.baseAddress,
                    bytes.count
                )
            }
            if bytesRead > 0 {
                capture.append(buffer, count: bytesRead)
                drainedBytes += bytesRead
                continue
            }
            if bytesRead == 0 {
                capture.markEndOfFile()
                closeDescriptor(&descriptor)
                return
            }
            if errno == EINTR {
                return
            }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                return
            }
            capture.markReadFailure(errno)
            closeDescriptor(&descriptor)
            return
        }
    }

    private static func reap(
        processIdentifier: pid_t,
        rawStatus: inout Int32?,
        systemCalls: GitCommandSystemCalls
    ) {
        guard rawStatus == nil else { return }
        var status: Int32 = 0
        let result = systemCalls.waitpid(
            processIdentifier,
            &status,
            WNOHANG
        )

        if result == processIdentifier {
            rawStatus = status
        } else if result == -1 && errno == ECHILD {
            rawStatus = unknownWaitStatus
        }
    }

    private static func poll(
        stdoutDescriptor: Int32,
        stderrDescriptor: Int32,
        until deadline: DispatchTime
    ) {
        let timeout = pollTimeout(until: deadline)
        var descriptors: [pollfd] = []
        let events = Int16(POLLIN | POLLHUP | POLLERR)
        if stdoutDescriptor != -1 {
            descriptors.append(
                pollfd(fd: stdoutDescriptor, events: events, revents: 0)
            )
        }
        if stderrDescriptor != -1 {
            descriptors.append(
                pollfd(fd: stderrDescriptor, events: events, revents: 0)
            )
        }

        guard !descriptors.isEmpty else {
            Darwin.poll(nil, 0, timeout)
            return
        }
        descriptors.withUnsafeMutableBufferPointer { buffer in
            _ = Darwin.poll(
                buffer.baseAddress,
                nfds_t(buffer.count),
                timeout
            )
        }
    }

    private static func pollTimeout(until deadline: DispatchTime) -> Int32 {
        let now = DispatchTime.now()
        guard now < deadline else { return 0 }
        let remainingNanoseconds = deadline.uptimeNanoseconds
            - now.uptimeNanoseconds
        let wholeMilliseconds = remainingNanoseconds / 1_000_000
        let roundedMilliseconds = wholeMilliseconds
            + (remainingNanoseconds.isMultiple(of: 1_000_000) ? 0 : 1)
        return Int32(
            min(
                UInt64(pollIntervalMilliseconds),
                max(roundedMilliseconds, 1)
            )
        )
    }

    private static func signalProcessGroup(
        _ processIdentifier: pid_t,
        signal: Int32,
        systemCalls: GitCommandSystemCalls
    ) {
        guard processIdentifier > 0 else { return }
        _ = systemCalls.kill(-processIdentifier, signal)
    }

    private static func closeDescriptor(_ descriptor: inout Int32) {
        guard descriptor != -1 else { return }
        _ = Darwin.close(descriptor)
        descriptor = -1
    }

    private static func decodedExitCode(_ status: Int32) -> Int32 {
        guard status != unknownWaitStatus else { return -1 }
        let signal = status & 0x7f
        if signal == 0 {
            return (status >> 8) & 0xff
        }
        return signal
    }

    private static func normalizedTimeout(_ timeout: TimeInterval) -> TimeInterval {
        guard timeout.isFinite else { return defaultTimeout }
        return max(timeout, 0)
    }

    private static func withMutableCStringArray<Result>(
        _ strings: [String],
        body: (
            UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
        ) -> Result
    ) -> Result {
        var pointers = strings.map { strdup($0) }
        pointers.append(nil)
        defer {
            for case let pointer? in pointers {
                free(pointer)
            }
        }
        return pointers.withUnsafeMutableBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else {
                preconditionFailure("C string array must contain a terminator")
            }
            return body(baseAddress)
        }
    }

    private static let unknownWaitStatus = Int32.min
}

nonisolated private struct GitCommandChild {
    let processIdentifier: pid_t
    let stdoutDescriptor: Int32
    let stderrDescriptor: Int32
}

nonisolated private struct GitCommandLaunchError: Error {
    let code: Int32

    var message: String {
        guard let description = strerror(code) else {
            return "Process launch failed (\(code))"
        }
        return String(cString: description)
    }
}

nonisolated private struct GitCommandPipe {
    var readDescriptor: Int32
    var writeDescriptor: Int32

    mutating func closeAll() {
        closeRead()
        closeWrite()
    }

    mutating func closeRead() {
        guard readDescriptor != -1 else { return }
        _ = Darwin.close(readDescriptor)
        readDescriptor = -1
    }

    mutating func closeWrite() {
        guard writeDescriptor != -1 else { return }
        _ = Darwin.close(writeDescriptor)
        writeDescriptor = -1
    }

    mutating func takeReadDescriptor() -> Int32 {
        let descriptor = readDescriptor
        readDescriptor = -1
        return descriptor
    }
}

nonisolated private struct GitCommandCapture {
    let limit: Int
    private(set) var data = Data()
    private(set) var truncated = false
    private(set) var reachedEndOfFile = false
    private(set) var readError: Int32?

    var captureComplete: Bool {
        reachedEndOfFile && readError == nil && !truncated
    }

    init(limit: Int) {
        self.limit = max(limit, 0)
    }

    mutating func append(_ bytes: [UInt8], count: Int) {
        let retainedCount = min(count, max(limit - data.count, 0))
        if retainedCount > 0 {
            data.append(contentsOf: bytes.prefix(retainedCount))
        }
        if retainedCount < count {
            truncated = true
        }
    }

    mutating func markEndOfFile() {
        reachedEndOfFile = true
    }

    mutating func markReadFailure(_ error: Int32) {
        readError = error
    }
}

nonisolated enum GitCommandTerminationPhase {
    case running
    case terminating
    case killing
}

nonisolated private enum GitCommandTerminalCause {
    case timedOut
    case cancelled
}

/// A final nonblocking reaper for the extremely small window where SIGKILL has
/// been sent but the kernel has not yet made the direct child waitable.
///
/// One process-exit source replaces periodic retry work. The source holds the
/// unreaped direct child identity until NOTE_EXIT, so its PID cannot be reused
/// while this owner still needs to wait for it.
nonisolated private final class GitCommandDeferredReaper: @unchecked Sendable {
    private let processIdentifier: pid_t
    private let waitpid: @Sendable (
        pid_t,
        UnsafeMutablePointer<Int32>?,
        Int32
    ) -> pid_t
    private let queue: DispatchQueue
    private var source: DispatchSourceProcess?

    init(
        processIdentifier: pid_t,
        waitpid: @escaping @Sendable (
            pid_t,
            UnsafeMutablePointer<Int32>?,
            Int32
        ) -> pid_t
    ) {
        self.processIdentifier = processIdentifier
        self.waitpid = waitpid
        self.queue = DispatchQueue(
            label: "com.pine.git-command-reaper.\(processIdentifier)",
            qos: .utility
        )
    }

    func start() {
        queue.async {
            if self.reapIfExited() {
                return
            }

            let source = DispatchSource.makeProcessSource(
                identifier: self.processIdentifier,
                eventMask: .exit,
                queue: self.queue
            )
            self.source = source
            source.setEventHandler {
                _ = source.data
                self.reapAfterExitEvent()
                source.cancel()
                self.source = nil
            }
            source.resume()

            // Close the registration race where the child exits after the
            // first WNOHANG observation but before the process source starts.
            if self.reapIfExited() {
                source.cancel()
                self.source = nil
            }
        }
    }

    private func reapIfExited() -> Bool {
        var status: Int32 = 0
        let result = waitpid(processIdentifier, &status, WNOHANG)
        return result == processIdentifier
            || (result == -1 && errno == ECHILD)
    }

    private func reapAfterExitEvent() {
        while true {
            var status: Int32 = 0
            // NOTE_EXIT has already established that a blocking wait cannot
            // wait on a live child.
            let result = waitpid(processIdentifier, &status, 0)
            if result == processIdentifier
                || (result == -1 && errno == ECHILD) {
                return
            }
            if result == -1 && errno == EINTR {
                continue
            }
            return
        }
    }
}
