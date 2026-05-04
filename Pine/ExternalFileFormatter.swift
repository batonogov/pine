//
//  ExternalFileFormatter.swift
//  Pine
//

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

    let process = Process()
    process.executableURL = URL(fileURLWithPath: executablePath)
    process.arguments = arguments

    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardInput = stdinPipe
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    do {
        try process.run()

        // Write stdin content and close
        if let data = stdin.data(using: .utf8) {
            stdinPipe.fileHandleForWriting.write(data)
        }
        stdinPipe.fileHandleForWriting.closeFile()

        // Schedule timeout with thread-safe flag via NSLock
        // (GCD serial queue .sync crashes under Swift 6 cooperative threading
        //  because swift_task_checkIsolatedSwift triggers dispatch_assert_queue)
        let timedOutLock = NSLock()
        nonisolated(unsafe) var timedOutValue = false

        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler {
            timedOutLock.lock()
            timedOutValue = true
            timedOutLock.unlock()
            if process.isRunning {
                process.terminate()
            }
        }
        timer.resume()

        // Read both pipes concurrently in separate threads to avoid
        // deadlock when stderr pipe buffer fills up (64KB)
        let readGroup = DispatchGroup()
        nonisolated(unsafe) var outData = Data()
        nonisolated(unsafe) var errData = Data()

        readGroup.enter()
        DispatchQueue.global().async {
            outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            readGroup.leave()
        }

        readGroup.enter()
        DispatchQueue.global().async {
            errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            readGroup.leave()
        }

        readGroup.wait()
        process.waitUntilExit()
        timer.cancel()

        timedOutLock.lock()
        let didTimeout = timedOutValue
        timedOutLock.unlock()

        return ProcessRunResult(
            stdout: String(bytes: outData, encoding: .utf8) ?? "",
            stderr: String(bytes: errData, encoding: .utf8) ?? "",
            exitCode: process.terminationStatus,
            timedOut: didTimeout
        )
    } catch {
        return ProcessRunResult(
            stdout: "",
            stderr: error.localizedDescription,
            exitCode: -1,
            timedOut: false
        )
    }
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
        guard let executablePath = toolPath else {
            return content
        }

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
                self.timeout
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
