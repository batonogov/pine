//
//  ExternalFileFormatter.swift
//  Pine
//

import Darwin
import Foundation

/// Result of running an external process.
nonisolated struct ProcessRunResult: Sendable {
    let stdout: String
    let stderr: String
    let exitCode: Int32
    let timedOut: Bool
    let outputLimitExceeded: Bool

    init(
        stdout: String,
        stderr: String,
        exitCode: Int32,
        timedOut: Bool,
        outputLimitExceeded: Bool = false
    ) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
        self.timedOut = timedOut
        self.outputLimitExceeded = outputLimitExceeded
    }
}

/// Byte limits applied while capturing a subprocess's output. Formatters only
/// operate on Pine's in-memory document contents, so these bounds comfortably
/// cover normal and large-file edits while preventing a broken tool from
/// consuming memory without limit.
nonisolated struct ProcessOutputLimits: Sendable {
    let stdoutBytes: Int
    let stderrBytes: Int

    static let formatter = ProcessOutputLimits(
        stdoutBytes: 16 * 1_024 * 1_024,
        stderrBytes: 1 * 1_024 * 1_024
    )
}

nonisolated private final class ExternalProcessSpawnLock: @unchecked Sendable {
    static let shared = ExternalProcessSpawnLock()

    let value = NSLock()
}

private typealias Pipe2Function = @convention(c) (
    UnsafeMutablePointer<Int32>?,
    Int32
) -> Int32

/// Signature for running an external process. Closure-based so tests can inject
/// behaviour without implementing a protocol — there is only ever one real impl.
typealias ProcessRunner = @Sendable (
    _ executablePath: String,
    _ arguments: [String],
    _ stdin: String,
    _ timeout: TimeInterval
) -> ProcessRunResult

/// Default `ProcessRunner` that spawns a real `Process` with stdin/stdout piping
/// and a timeout.
///
/// **Important:** This blocks the calling thread until the process exits or
/// times out. Must be called from a background queue — never from the main thread.
@Sendable
nonisolated func runRealProcess(
    executablePath: String,
    arguments: [String],
    stdin: String,
    timeout: TimeInterval
) -> ProcessRunResult {
    precondition(!Thread.isMainThread, "runRealProcess() must not be called on the main thread")
    guard timeout.isFinite, timeout > 0 else {
        return ProcessRunResult(
            stdout: "",
            stderr: "Process deadline expired",
            exitCode: -1,
            timedOut: true
        )
    }
    return runSpawnedProcess(
        executablePath: executablePath,
        arguments: arguments,
        stdin: Data(stdin.utf8),
        timeout: timeout,
        outputLimits: .formatter
    )
}

/// Internal overload used by focused process-runner tests to exercise output
/// and deadline boundaries without allocating the production-sized limits.
@Sendable
nonisolated func runRealProcess(
    executablePath: String,
    arguments: [String],
    stdin: String,
    timeout: TimeInterval,
    outputLimits: ProcessOutputLimits
) -> ProcessRunResult {
    precondition(!Thread.isMainThread, "runRealProcess() must not be called on the main thread")
    guard timeout.isFinite, timeout > 0 else {
        return ProcessRunResult(
            stdout: "",
            stderr: "Process deadline expired",
            exitCode: -1,
            timedOut: true
        )
    }
    return runSpawnedProcess(
        executablePath: executablePath,
        arguments: arguments,
        stdin: Data(stdin.utf8),
        timeout: timeout,
        outputLimits: outputLimits
    )
}

nonisolated private func runSpawnedProcess(
    executablePath: String,
    arguments: [String],
    stdin: Data,
    timeout: TimeInterval,
    outputLimits: ProcessOutputLimits
) -> ProcessRunResult {
    let start = DispatchTime.now().uptimeNanoseconds
    let requestedNanoseconds = timeout * 1_000_000_000
    let maximumBudget = UInt64.max - start
    let budget = requestedNanoseconds >= Double(maximumBudget)
        ? maximumBudget
        : UInt64(requestedNanoseconds)
    let hardDeadline = start + budget
    let desiredGrace = min(100_000_000, max(10_000_000, budget / 5))
    let grace = min(budget, desiredGrace)
    let softDeadline = hardDeadline - grace

    // `pipe2(O_CLOEXEC)` is atomic, but its declaration is absent from the
    // macOS 26 SDK. Resolve the macOS 27 symbol dynamically so this source
    // continues to compile with Xcode 26. The fallback serializes Pine's
    // process runners across the short pipe()+fcntl()+spawn window.
    let pipe2 = resolvedPipe2()
    let requiresSpawnLock = pipe2 == nil
    if requiresSpawnLock {
        ExternalProcessSpawnLock.shared.value.lock()
    }
    var holdsSpawnLock = requiresSpawnLock
    defer {
        if holdsSpawnLock {
            ExternalProcessSpawnLock.shared.value.unlock()
        }
    }

    var inputPipe = [Int32](repeating: -1, count: 2)
    var outputPipe = [Int32](repeating: -1, count: 2)
    var errorPipe = [Int32](repeating: -1, count: 2)
    let inputPipeResult = makeCloseOnExecPipe(&inputPipe, pipe2: pipe2)
    let outputPipeResult = inputPipeResult == 0
        ? makeCloseOnExecPipe(&outputPipe, pipe2: pipe2)
        : inputPipeResult
    let errorPipeResult = outputPipeResult == 0
        ? makeCloseOnExecPipe(&errorPipe, pipe2: pipe2)
        : outputPipeResult
    guard errorPipeResult == 0 else {
        closeDescriptors(inputPipe + outputPipe + errorPipe)
        return processLaunchFailure(errorPipeResult)
    }

    var fileActions: posix_spawn_file_actions_t?
    var attributes: posix_spawnattr_t?
    guard posix_spawn_file_actions_init(&fileActions) == 0,
          posix_spawnattr_init(&attributes) == 0 else {
        closeDescriptors(inputPipe + outputPipe + errorPipe)
        return processLaunchFailure(errno)
    }
    defer {
        posix_spawn_file_actions_destroy(&fileActions)
        posix_spawnattr_destroy(&attributes)
    }

    let childMappings = [
        (inputPipe[0], STDIN_FILENO),
        (outputPipe[1], STDOUT_FILENO),
        (errorPipe[1], STDERR_FILENO),
    ]
    for (source, destination) in childMappings {
        guard posix_spawn_file_actions_adddup2(
            &fileActions,
            source,
            destination
        ) == 0 else {
            closeDescriptors(inputPipe + outputPipe + errorPipe)
            return processLaunchFailure(errno)
        }
    }
    for descriptor in inputPipe + outputPipe + errorPipe {
        guard posix_spawn_file_actions_addclose(
            &fileActions,
            descriptor
        ) == 0 else {
            closeDescriptors(inputPipe + outputPipe + errorPipe)
            return processLaunchFailure(errno)
        }
    }
    guard posix_spawnattr_setflags(
        &attributes,
        Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)
    ) == 0,
          posix_spawnattr_setpgroup(&attributes, 0) == 0 else {
        closeDescriptors(inputPipe + outputPipe + errorPipe)
        return processLaunchFailure(errno)
    }

    let environment = ProcessInfo.processInfo.environment.map {
        "\($0.key)=\($0.value)"
    }
    var childPID: pid_t = 0
    let spawnResult = withMutableCStringArray(
        [executablePath] + arguments
    ) { argumentVector in
        withMutableCStringArray(environment) { environmentVector in
            posix_spawn(
                &childPID,
                executablePath,
                &fileActions,
                &attributes,
                argumentVector,
                environmentVector
            )
        }
    }
    guard spawnResult == 0 else {
        closeDescriptors(inputPipe + outputPipe + errorPipe)
        return processLaunchFailure(spawnResult)
    }

    if holdsSpawnLock {
        ExternalProcessSpawnLock.shared.value.unlock()
        holdsSpawnLock = false
    }

    Darwin.close(inputPipe[0])
    Darwin.close(outputPipe[1])
    Darwin.close(errorPipe[1])
    var inputDescriptor = inputPipe[1]
    var outputDescriptor = outputPipe[0]
    var errorDescriptor = errorPipe[0]
    setNonblocking(inputDescriptor)
    setNonblocking(outputDescriptor)
    setNonblocking(errorDescriptor)
    _ = Darwin.fcntl(inputDescriptor, F_SETNOSIGPIPE, 1)

    var sentTermination = false
    var terminationDeadline = hardDeadline
    var didTimeOut = false
    var outputLimitExceeded = false
    var processStatus: Int32?
    var inputOffset = 0
    var output = Data()
    var errors = Data()

    while true {
        let streamsAreClosed = outputDescriptor < 0 && errorDescriptor < 0
        if formatterShouldAttemptReap(
            terminationStarted: sentTermination,
            streamsAreClosed: streamsAreClosed
        ) {
            reapIfExited(childPID, status: &processStatus)
        }
        let drainDeadline = sentTermination ? terminationDeadline : softDeadline
        let outputDrain = drainPipe(
            &outputDescriptor,
            into: &output,
            byteLimit: max(0, outputLimits.stdoutBytes),
            deadline: drainDeadline
        )
        let errorDrain = drainPipe(
            &errorDescriptor,
            into: &errors,
            byteLimit: max(0, outputLimits.stderrBytes),
            deadline: drainDeadline
        )
        writePipe(
            &inputDescriptor,
            data: stdin,
            offset: &inputOffset
        )
        if outputDrain == .limitExceeded || errorDrain == .limitExceeded {
            outputLimitExceeded = true
            closeDescriptor(&inputDescriptor)
            closeDescriptor(&outputDescriptor)
            closeDescriptor(&errorDescriptor)
            if !sentTermination {
                sentTermination = true
                let now = DispatchTime.now().uptimeNanoseconds
                terminationDeadline = min(
                    hardDeadline,
                    addingWithoutOverflow(now, grace)
                )
                _ = Darwin.kill(-childPID, SIGTERM)
            }
        }
        if processStatus != nil,
           outputDescriptor < 0,
           errorDescriptor < 0 {
            break
        }

        let now = DispatchTime.now().uptimeNanoseconds
        if !sentTermination, now >= softDeadline {
            didTimeOut = true
            sentTermination = true
            terminationDeadline = hardDeadline
            closeDescriptor(&inputDescriptor)
            _ = Darwin.kill(-childPID, SIGTERM)
        }
        if sentTermination, now >= terminationDeadline {
            if !outputLimitExceeded {
                didTimeOut = true
            }
            _ = Darwin.kill(-childPID, SIGKILL)
            closeDescriptor(&inputDescriptor)
            closeDescriptor(&outputDescriptor)
            closeDescriptor(&errorDescriptor)
            reapIfExited(childPID, status: &processStatus)
            if processStatus == nil {
                let reapingPID = childPID
                DispatchQueue.global(qos: .utility).async {
                    var status: Int32 = 0
                    while Darwin.waitpid(reapingPID, &status, 0) < 0,
                          errno == EINTR {}
                }
            }
            break
        }

        var pollDescriptors = makePollDescriptors(
            input: inputDescriptor,
            wantsInput: inputOffset < stdin.count,
            output: outputDescriptor,
            error: errorDescriptor
        )
        let nextBoundary = sentTermination ? terminationDeadline : softDeadline
        let remaining = nextBoundary > now ? nextBoundary - now : 0
        let waitMilliseconds = Int32(
            min(10, max(1, remaining / 1_000_000))
        )
        _ = Darwin.poll(
            &pollDescriptors,
            nfds_t(pollDescriptors.count),
            waitMilliseconds
        )
    }

    closeDescriptor(&inputDescriptor)
    closeDescriptor(&outputDescriptor)
    closeDescriptor(&errorDescriptor)
    return ProcessRunResult(
        stdout: String(bytes: output, encoding: .utf8) ?? "",
        stderr: String(bytes: errors, encoding: .utf8) ?? "",
        exitCode: processStatus.map(processExitCode) ?? -1,
        timedOut: didTimeOut,
        outputLimitExceeded: outputLimitExceeded
    )
}

nonisolated private func makeCloseOnExecPipe(
    _ descriptors: inout [Int32],
    pipe2: Pipe2Function?
) -> Int32 {
    if let pipe2 {
        let result = descriptors.withUnsafeMutableBufferPointer { buffer in
            pipe2(buffer.baseAddress, O_CLOEXEC)
        }
        return result == 0 ? 0 : errno
    }

    guard Darwin.pipe(&descriptors) == 0 else { return errno }
    for descriptor in descriptors {
        let flags = Darwin.fcntl(descriptor, F_GETFD)
        guard flags >= 0,
              Darwin.fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) == 0 else {
            let failure = errno
            closeDescriptors(descriptors)
            descriptors = [-1, -1]
            return failure
        }
    }
    return 0
}

/// Returns the atomic macOS 27 pipe creator without making Xcode 26 resolve a
/// declaration that does not exist in its SDK.
nonisolated private func resolvedPipe2() -> Pipe2Function? {
    guard #available(macOS 27.0, *),
          let handle = Darwin.dlopen(nil, RTLD_LAZY | RTLD_LOCAL) else {
        return nil
    }
    defer { Darwin.dlclose(handle) }
    guard let symbol = Darwin.dlsym(handle, "pipe2") else { return nil }
    return unsafeBitCast(symbol, to: Pipe2Function.self)
}

/// Consuming a zombie releases its PID/PGID for reuse. During termination the
/// group leader must therefore remain unreaped until after Pine has sent its
/// final group signal, even when a descendant keeps a captured pipe open.
nonisolated func formatterShouldAttemptReap(
    terminationStarted: Bool,
    streamsAreClosed: Bool
) -> Bool {
    !terminationStarted && streamsAreClosed
}

nonisolated private func addingWithoutOverflow(
    _ lhs: UInt64,
    _ rhs: UInt64
) -> UInt64 {
    let (value, overflow) = lhs.addingReportingOverflow(rhs)
    return overflow ? UInt64.max : value
}

nonisolated private func withMutableCStringArray<Result>(
    _ strings: [String],
    body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Result
) -> Result {
    let allocated = strings.map { strdup($0) }
    defer { allocated.forEach { free($0) } }
    var pointers = allocated
    pointers.append(nil)
    return pointers.withUnsafeMutableBufferPointer { buffer in
        guard let baseAddress = buffer.baseAddress else {
            preconditionFailure("CString vector must contain its terminator")
        }
        return body(baseAddress)
    }
}

nonisolated private func makePollDescriptors(
    input: Int32,
    wantsInput: Bool,
    output: Int32,
    error: Int32
) -> [pollfd] {
    var descriptors: [pollfd] = []
    if input >= 0, wantsInput {
        descriptors.append(pollfd(fd: input, events: Int16(POLLOUT), revents: 0))
    }
    if output >= 0 {
        descriptors.append(pollfd(fd: output, events: Int16(POLLIN), revents: 0))
    }
    if error >= 0 {
        descriptors.append(pollfd(fd: error, events: Int16(POLLIN), revents: 0))
    }
    return descriptors
}

nonisolated private func setNonblocking(_ descriptor: Int32) {
    let flags = Darwin.fcntl(descriptor, F_GETFL)
    if flags >= 0 {
        _ = Darwin.fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
    }
}

nonisolated private func writePipe(
    _ descriptor: inout Int32,
    data: Data,
    offset: inout Int
) {
    guard descriptor >= 0 else { return }
    if offset >= data.count {
        closeDescriptor(&descriptor)
        return
    }
    let result = data.withUnsafeBytes { bytes in
        guard let baseAddress = bytes.baseAddress else { return -1 }
        return Darwin.write(
            descriptor,
            baseAddress.advanced(by: offset),
            bytes.count - offset
        )
    }
    if result > 0 {
        offset += result
    } else if result < 0, errno != EINTR, errno != EAGAIN {
        closeDescriptor(&descriptor)
    }
}

nonisolated private enum PipeDrainResult: Equatable {
    case drained
    case deadlineReached
    case limitExceeded
}

nonisolated private func drainPipe(
    _ descriptor: inout Int32,
    into data: inout Data,
    byteLimit: Int,
    deadline: UInt64
) -> PipeDrainResult {
    guard descriptor >= 0 else { return .drained }
    var buffer = [UInt8](repeating: 0, count: 16_384)
    // A fixed quantum prevents a continuously-writing child from monopolizing
    // this loop. The monotonic check before every read enforces the same
    // deadline even when the pipe never reaches EAGAIN.
    var remainingQuantum = 64 * 1_024
    while remainingQuantum > 0 {
        guard DispatchTime.now().uptimeNanoseconds < deadline else {
            return .deadlineReached
        }
        let remainingCapacity = max(0, byteLimit - data.count)
        let overflowDetectingCapacity = remainingCapacity == Int.max
            ? Int.max
            : remainingCapacity + 1
        let requestedCount = min(
            min(buffer.count, remainingQuantum),
            overflowDetectingCapacity
        )
        let count = Darwin.read(descriptor, &buffer, requestedCount)
        if count > 0 {
            let acceptedCount = min(count, remainingCapacity)
            if acceptedCount > 0 {
                data.append(buffer, count: acceptedCount)
            }
            if count > remainingCapacity {
                return .limitExceeded
            }
            remainingQuantum -= count
        } else if count == 0 {
            closeDescriptor(&descriptor)
            return .drained
        } else if errno == EINTR {
            continue
        } else if errno == EAGAIN {
            return .drained
        } else {
            closeDescriptor(&descriptor)
            return .drained
        }
    }
    return .drained
}

nonisolated private func reapIfExited(
    _ processID: pid_t,
    status: inout Int32?
) {
    guard status == nil else { return }
    var candidate: Int32 = 0
    let result = Darwin.waitpid(processID, &candidate, WNOHANG)
    if result == processID {
        status = candidate
    }
}

nonisolated private func processExitCode(_ status: Int32) -> Int32 {
    let signal = status & 0x7f
    return signal == 0 ? (status >> 8) & 0xff : 128 + signal
}

nonisolated private func closeDescriptors(_ descriptors: [Int32]) {
    for descriptor in descriptors where descriptor >= 0 {
        Darwin.close(descriptor)
    }
}

nonisolated private func closeDescriptor(_ descriptor: inout Int32) {
    guard descriptor >= 0 else { return }
    Darwin.close(descriptor)
    descriptor = -1
}

nonisolated private func processLaunchFailure(
    _ code: Int32
) -> ProcessRunResult {
    ProcessRunResult(
        stdout: "",
        stderr: String(cString: strerror(code)),
        exitCode: -1,
        timedOut: false
    )
}

/// A file formatter that delegates to an external CLI tool via stdin/stdout.
///
/// Falls back to the original content on any failure: tool not found, non-zero exit,
/// timeout, or empty output. This guarantees save never blocks on a broken tool.
///
/// **Threading:** `format()` blocks the calling thread while the external process runs.
/// Must be called from a background queue — never from the main thread.
nonisolated final class ExternalFileFormatter: FileFormatter, Sendable {

    /// Display name of the tool (e.g. "terraform", "shfmt", "prettier").
    let toolName: String

    /// File extensions this formatter handles (lowercase, without dot).
    let extensions: Set<String>

    /// Arguments to pass to the tool (the content comes via stdin).
    let arguments: [String]

    /// Maximum time to wait for the tool to finish.
    let timeout: TimeInterval

    /// Resolved path to the executable, or nil if not found.
    let toolPath: String?

    private let processRunner: ProcessRunner

    /// Creates an external file formatter that auto-resolves the tool from PATH.
    ///
    /// - Parameters:
    ///   - toolName: Name of the tool binary.
    ///   - extensions: File extensions to handle (without dot, case-insensitive).
    ///   - arguments: Arguments to pass to the tool.
    ///   - processRunner: Closure that runs the external process. Defaults to
    ///     `runRealProcess`; tests inject their own.
    ///   - timeout: Maximum execution time (default 5 seconds).
    init(
        toolName: String,
        extensions: [String],
        arguments: [String],
        processRunner: @escaping ProcessRunner = runRealProcess,
        timeout: TimeInterval = 5.0
    ) {
        self.toolName = toolName
        self.extensions = Set(extensions.map { $0.lowercased() })
        self.arguments = arguments
        self.processRunner = processRunner
        self.timeout = timeout
        self.toolPath = ExternalToolResolver.fromEnvironment().resolve(tool: toolName)
    }

    /// Creates an external file formatter with an explicit tool path (skips resolution).
    ///
    /// - Parameters:
    ///   - toolPath: Absolute path to the tool binary, or nil if tool is unavailable.
    ///   - toolName: Display name of the tool.
    ///   - extensions: File extensions to handle (without dot, case-insensitive).
    ///   - arguments: Arguments to pass to the tool.
    ///   - processRunner: Closure that runs the external process. Defaults to
    ///     `runRealProcess`; tests inject their own.
    ///   - timeout: Maximum execution time (default 5 seconds).
    init(
        toolPath: String?,
        toolName: String,
        extensions: [String],
        arguments: [String],
        processRunner: @escaping ProcessRunner = runRealProcess,
        timeout: TimeInterval = 5.0
    ) {
        self.toolName = toolName
        self.extensions = Set(extensions.map { $0.lowercased() })
        self.arguments = arguments
        self.processRunner = processRunner
        self.timeout = timeout
        self.toolPath = toolPath
    }

    func canFormat(url: URL) -> Bool {
        guard toolPath != nil else { return false }
        let ext = url.pathExtension.lowercased()
        return extensions.contains(ext)
    }

    func format(_ content: String, url: URL) -> String {
        format(content, url: url, maximumDuration: timeout)
    }

    func format(
        _ content: String,
        url: URL,
        maximumDuration: TimeInterval
    ) -> String {
        guard let executablePath = toolPath else {
            return content
        }
        let effectiveTimeout = min(timeout, maximumDuration)
        guard effectiveTimeout > 0 else { return content }

        // Interactive saves prepare content on a worker queue before their
        // main-actor revision check. Keep the formatter synchronous on that
        // worker so there is no nested dispatch or main-thread wait.
        let result = processRunner(
            executablePath,
            arguments,
            content,
            effectiveTimeout
        )

        // Fall back to original on any failure
        guard !result.timedOut,
              !result.outputLimitExceeded,
              result.exitCode == 0,
              !result.stdout.isEmpty else {
            return content
        }

        return result.stdout
    }
}
