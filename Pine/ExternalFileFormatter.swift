//
//  ExternalFileFormatter.swift
//  Pine
//

import Darwin
import Foundation

/// Result of running an external process.
struct ProcessRunResult: Sendable {
    let stdout: String
    let stderr: String
    let exitCode: Int32
    let timedOut: Bool
}

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
        timeout: timeout
    )
}

nonisolated private func runSpawnedProcess(
    executablePath: String,
    arguments: [String],
    stdin: Data,
    timeout: TimeInterval
) -> ProcessRunResult {
    var inputPipe = [Int32](repeating: -1, count: 2)
    var outputPipe = [Int32](repeating: -1, count: 2)
    var errorPipe = [Int32](repeating: -1, count: 2)
    guard Darwin.pipe(&inputPipe) == 0,
          Darwin.pipe(&outputPipe) == 0,
          Darwin.pipe(&errorPipe) == 0 else {
        closeDescriptors(inputPipe + outputPipe + errorPipe)
        return processLaunchFailure(errno)
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
        Int16(POSIX_SPAWN_SETPGROUP)
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

    let start = DispatchTime.now().uptimeNanoseconds
    let budget = UInt64(timeout * 1_000_000_000)
    let hardDeadline = start &+ budget
    let grace = min(100_000_000, max(10_000_000, budget / 5))
    let softDeadline = hardDeadline &- grace
    var sentTermination = false
    var didTimeOut = false
    var processStatus: Int32?
    var inputOffset = 0
    var output = Data()
    var errors = Data()

    while true {
        reapIfExited(childPID, status: &processStatus)
        drainPipe(&outputDescriptor, into: &output)
        drainPipe(&errorDescriptor, into: &errors)
        writePipe(
            &inputDescriptor,
            data: stdin,
            offset: &inputOffset
        )
        if processStatus != nil,
           outputDescriptor < 0,
           errorDescriptor < 0 {
            break
        }

        let now = DispatchTime.now().uptimeNanoseconds
        if !sentTermination, now >= softDeadline {
            didTimeOut = true
            sentTermination = true
            closeDescriptor(&inputDescriptor)
            _ = Darwin.kill(-childPID, SIGTERM)
        }
        if now >= hardDeadline {
            didTimeOut = true
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
        let nextBoundary = sentTermination ? hardDeadline : softDeadline
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
        timedOut: didTimeOut
    )
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

nonisolated private func drainPipe(
    _ descriptor: inout Int32,
    into data: inout Data
) {
    guard descriptor >= 0 else { return }
    var buffer = [UInt8](repeating: 0, count: 16_384)
    while true {
        let count = Darwin.read(descriptor, &buffer, buffer.count)
        if count > 0 {
            data.append(buffer, count: count)
        } else if count == 0 {
            closeDescriptor(&descriptor)
            return
        } else if errno == EINTR {
            continue
        } else if errno == EAGAIN {
            return
        } else {
            closeDescriptor(&descriptor)
            return
        }
    }
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

        // Dispatch to a background queue so runRealProcess's main-thread
        // precondition is satisfied. The caller (trySaveTab) runs on main;
        // DispatchGroup.wait() blocks it briefly while the process executes.
        nonisolated(unsafe) var result = ProcessRunResult(
            stdout: "", stderr: "", exitCode: -1, timedOut: true
        )
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            result = self.processRunner(
                executablePath,
                self.arguments,
                content,
                effectiveTimeout
            )
            group.leave()
        }
        group.wait()

        // Fall back to original on any failure
        guard !result.timedOut,
              result.exitCode == 0,
              !result.stdout.isEmpty else {
            return content
        }

        return result.stdout
    }
}
